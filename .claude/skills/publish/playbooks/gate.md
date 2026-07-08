
# Playbook: gate

The Evaluator-Optimizer rubric (publishing-gate-architecture.md's framing) — an independent grader scores the target repo's pending change against six pass/fail criteria, in ordering that fails cheap before it spends anything expensive.

## Input

```yaml
target_repo: <abs path>                 # resolved by SKILL.md's trigger handling; every command below runs `-C <target_repo>`
visibility: public | private | unknown  # infer from `git -C <target_repo> remote get-url origin` against the operator's known-repo list; unknown -> ask, don't guess
base_ref: origin/HEAD                   # requires `git remote set-head origin --auto` once per repo (publishing-workflow.md)
```

## Ordering + short-circuit

Cheapest first; the two judgment passes (fresh-context critic, LLM security review) are the expensive steps and only run once every mechanical criterion is clean.

1. Scaffold (mechanical, ~instant)
2. Universe conformance — mechanical half (mechanical, fast; runs inside house-qa's `check`)
3. Gitleaks full-change scan (mechanical, fast)
4. House-qa mechanical / `check` (mechanical, fast)
5. **Short-circuit gate:** any HIGH finding in 1–4 → verdict FAIL now; skip 6–7 entirely.
6. House-qa judgment / `review` (judgment, expensive — fresh context)
7. Advisory security review (judgment, expensive — LLM diff read)

## Criteria

### 1. Scaffold

All sub-checks run against `git -C <target_repo> ls-files` (tracked files only — untracked scratch is never in scope).

- **Root-anchored gitignore, actually effective.** `.gitignore` exists at repo root AND no known non-shipping directory is tracked:
  `git -C <target_repo> ls-files | grep -Ei '(^|/)(evals|scratch)(/|$)'` → any hit is a FAIL. (Deliberately plural-only: this repo's own convention treats singular `eval/` as shipped test harness — `.claude/eval/`'s hook tests — and plural `evals/`/`Evals/` as non-shipping experiment output. This is the classified failure that motivated this sub-check: a Wiki-repo `Evals/` dir got tracked and shipped.)
- **Gitleaks allow-list guard, for content-bearing repos.** A repo is content-bearing if `git ls-files` matches `fixtures?/|samples?/|golden|Evals?/` (test fixtures, sample corpora, worked examples — content that can trip pattern scanners on intentional test data). If content-bearing: `grep -q '^\[allowlist\]' <target_repo>/.gitleaks.toml` must succeed — an allow-list is how intentional test literals stay distinguishable from real leaks instead of the repo silently suppressing the whole scanner.
- **LICENSE + README present.** `test -f <target_repo>/LICENSE && test -f <target_repo>/README.md`.
- **Every operator-config referenced by tracked machinery has a `*.sample.*` shape.** A reference is a literal filename matching `CLAUDE\.md`, `settings(\.\w+)*\.json`, or `[\w-]*config\.(json|ya?ml)` found inside a tracked file's text. For each unique reference: PASS if the reference itself is also tracked (already public, needs no sample) OR a `*.sample.*` counterpart with the same stripped basename is tracked; otherwise FAIL, naming the bare reference.

  ```bash
  tracked=$(git -C "$target_repo" ls-files)
  tracked_stripped=$(printf '%s\n' "$tracked" | while read -r p; do b=$(basename "$p"); echo "${b#.}"; done | sort -u)
  sample_basenames=$(printf '%s\n' "$tracked" | grep -E '\.sample\.' | while read -r p; do basename "$p"; done | sed -E 's/\.sample(\.[^.]+)$/\1/' | sort -u)
  refs=$(printf '%s\n' "$tracked" | sed "s|^|$target_repo/|" | xargs -I{} cat {} 2>/dev/null \
    | grep -ohE '\bCLAUDE\.md\b|\bsettings(\.[A-Za-z]+)*\.json\b|\b[A-Za-z0-9_-]*config\.(json|ya?ml)\b' \
    | sed -E 's/^\.//' | sort -u)
  missing=""
  while IFS= read -r ref; do
    [ -z "$ref" ] && continue
    case "$ref" in *.sample.*) continue ;; esac
    printf '%s\n' "$tracked_stripped" | grep -qx "$ref" && continue
    printf '%s\n' "$sample_basenames" | grep -qx "$ref" && continue
    missing="$missing $ref"
  done <<< "$refs"
  [ -n "$missing" ] && echo "FAIL:$missing" || echo "PASS"
  ```

  Known blind spot (documented, not fixed speculatively — same discipline as `qa.py`'s own gaps list): this is a filename heuristic, not a real reference-graph walk. A config referenced only through an indirection (an env var whose value is the filename) won't be caught.

- **Sample-file audit** (placeholder integrity, folded into this same criterion). For every tracked `*.sample.*` file: `grep -lE 'TODO:|path/to/your|YOUR_VALUE_HERE|<[A-Z_]+>'` must hit at least one placeholder marker. Zero hits on a `*.sample.*` file is a FAIL — a sample with no placeholders is either dead weight or a filled-in copy that leaked real values.

### 2. Universe conformance

Zero WARNING+ `unlisted-fiction-entity` findings and zero HIGH `fiction-continuity-mismatch` findings from house-qa's `check` (criteria 3 below derives this from the same run — this is a stricter bar than house-qa's own default use, where WARNING feeds judgment rather than gating alone; the gate chooses to gate on it). For any new narrative/example content in the change (not just what qa.py's regex catches), load `/sample-universe` directly and confirm one-citation-per-file + universe-only vocabulary.

### 3. House-qa mechanical (`check`)

```bash
python3 <target_repo>/.claude/skills/house-qa/qa.py <target_repo> --git-tracked-only \
  --vault-root "$VAULT_ROOT" --json
```

PASS if zero HIGH findings outside any path matching `*/tests/fixtures/*` — every skill's own regression fixtures contain literal ticket IDs, vault paths, and roster names by design (that's what they test); a real HIGH anywhere else is not excepted.

### 4. House-qa judgment (`review`)

Invoke `/house-qa review` as `playbooks/review.md` specifies — fresh context, never the authoring session. PASS on verdict `KEEP`, or `SIMPLIFY` once its named edits are applied and the artifact is re-reviewed to `KEEP`. `REWORK`, or a `SIMPLIFY` whose edits were never applied, is FAIL. (house-qa's vocabulary is exactly KEEP/SIMPLIFY/REWORK — no fourth tier; map any looser "ship with edits" framing onto SIMPLIFY-then-reverified, not a new tier.)

### 5. Gitleaks full-change scan

```bash
gitleaks detect --source <target_repo> --log-opts="origin/HEAD..HEAD" --config <target_repo>/.gitleaks.toml --no-banner
```

Full branch diff since `origin/HEAD` — broader than pre-commit's staged-only slice, and it also catches secrets introduced then reverted within the branch's own history. Uncommitted working-tree changes: `gitleaks protect --staged --config <target_repo>/.gitleaks.toml` first. PASS on exit 0 with zero leaks.

### 6. Advisory security review

Per `publishing-workflow.md` § Advisory security review, picking the path by where the calling session is rooted:

- Session rooted in `target_repo` → run `/security-review` directly (the tuned built-in skill).
- Any other session root (the common case for `/publish` — it takes a repo path precisely so it isn't cwd-bound) → **do not** call `/security-review`; it would review the wrong repo. Instead: `git -C <target_repo> diff origin/HEAD...` and assess inline for >80%-confidence exploitable findings only (injection, authz bypass, path traversal, unsafe deserialization, hardcoded secrets, data exposure) — same bar as the skill, skip style, denial-of-service, and theoretical issues.

**cwd-independence is REQUIRED here, not optional.** This is the executable-path lesson: `/security-review` diffs `origin/HEAD...` in the session's own cwd with no repo argument, so calling it from any session not rooted in `target_repo` silently reviews the wrong tree — a check that passes from one cwd and is silently absent from another. `/publish` closes that hole structurally by always taking `target_repo` as data and using `git -C`, never relying on the calling session's location.

PASS if zero >80%-confidence exploitable findings.

## Verdict schema

```yaml
verdict: pass | fail
target_repo: <abs path>
short_circuited: <bool>        # true if a mechanical FAIL skipped criteria 4 (judgment) and 6 (security review)
criteria:
  scaffold: {status: pass|fail, findings: [...]}
  universe_conformance: {status: pass|fail, findings: [...]}
  house_qa_mechanical: {status: pass|fail, findings: [...]}
  house_qa_judgment: {status: pass|fail, verdict: KEEP|SIMPLIFY|REWORK, findings: [...]}
  gitleaks: {status: pass|fail, findings: [...]}
  security_review: {status: pass|fail, findings: [...]}
```

This block is the P3/autonomous consumer's contract (publishing-gate-architecture.md's "verdict-emitting check" requirement) even though nothing consumes it that way today — human mode reads it as the operator's per-criterion report; a future gateway-Pi session would read `verdict` directly as its publish/block decision.

## What this playbook does NOT do

- Does NOT invoke push/PR mechanics — SKILL.md's Push/PR flow section owns that, only on a `pass` verdict.
- Does NOT fix any finding — every criterion here reports; the caller (or the composed skill's own review) edits.
- Does NOT widen Decision Authority — a `pass` verdict here is data for the operator, never a standing authorization to skip her `permissions.ask` prompts.
