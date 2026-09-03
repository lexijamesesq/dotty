
# Playbook: gate

The Evaluator-Optimizer rubric (publishing-gate-architecture.md's framing) — an independent grader scores the target repo's pending change against six pass/fail criteria, in ordering that fails cheap before it spends anything expensive.

## Input

```yaml
target_repo: <abs path>                 # resolved by SKILL.md's trigger handling; every command below runs `-C <target_repo>`
visibility: public | private | unknown  # infer from `git -C <target_repo> remote get-url origin` against the operator's known-repo list; unknown -> ask, don't guess
base_ref: origin/HEAD                   # requires `git remote set-head origin --auto` once per repo (global CLAUDE.md § GitHub)
```

## Ordering + short-circuit

Cheapest first; the two judgment passes (fresh-context critic, LLM security review) are the expensive steps and only run once every mechanical criterion is clean.

1. Scaffold (mechanical, ~instant)
2. Universe conformance — mechanical half (mechanical, fast; runs inside house-qa's `check`)
3. Gitleaks full-change scan (mechanical, fast)
4. House-qa mechanical / `check` (mechanical, fast)
5. **Short-circuit gate:** any HIGH finding in 1–4 → verdict FAIL now; skip 6–7 entirely.
6. House-qa judgment / `review` (judgment, expensive — fresh context)
7. Advisory security review (judgment, expensive — LLM diff read; skipped outright on an empty executable delta — see criterion 6)

**One-script mechanical front.** `scripts/gate-mechanical.sh <target_repo> [--base <ref>] [--visibility public|private]` runs the scaffold sub-checks, the sample placeholder audit, the changed-file universe/fiction scan, and the PII sweep in a single invocation with per-step PASS/FAIL and a non-zero exit on any failure. The PII sweep is gitleaks over tracked HEAD content — semantics documented in the script's shared-sweep header, never a session-improvised pattern list. It's computed once and shared by Step 1's conditional-allowlist check (§ Criteria 1) and Step 4's own verdict. Patterns introduced then scrubbed within the branch live only in history, which is criterion 5's range scan. Gitleaks-over-the-range (criterion 5) and the two judgment passes stay separate invocations by design.

## Criteria

**Codified decision — branch-introduced scoping (criteria 1, 3).** Extends the same principle criterion 5 already codifies for gitleaks: a finding gates only if the branch introduced it. A scaffold or house-qa-mechanical finding that reproduces identically against `origin/HEAD` is PRE-EXISTING DEBT, not a gate failure — reported, never gated.

- **How to compare.** `git -C <target_repo> worktree add <tmp> origin/HEAD` → run the same sub-check against the worktree (scaffold: re-run the failing sub-check; house-qa: re-run `qa.py` against the worktree) → set-diff findings by `(check, file)` against the branch-tip run → `git -C <target_repo> worktree remove <tmp>`. A finding present in both sets is pre-existing debt; a finding only in the branch-tip set is branch-introduced and gates normally.
- **Reporting.** Pre-existing debt is never silently dropped — it's carried in the verdict's `pre_existing_debt` block (see § Verdict schema) on every run until it's dispositioned (fixed, or accepted via a history-rewrite/backlog item), the same discipline criterion 5 already applies to its own historical-findings block.
- **Health metric.** Debt stays visible in every verdict until dispositioned — visibility is preserved, only re-litigation per publish is removed. A gate that stays permanently red on debt it can't act on trains bypassing; that's the capability loss this decision closes.

### 1. Scaffold

All sub-checks run against `git -C <target_repo> ls-files` (tracked files only — untracked scratch is never in scope). Branch-introduced scoping applies to these sub-checks — see the codified decision above.

- **Root-anchored gitignore, actually effective.** `.gitignore` exists at repo root AND no known non-shipping directory is tracked:
  `git -C <target_repo> ls-files | grep -Ei '(^|/)(evals|scratch)(/|$)'` → any hit is a FAIL. (Deliberately plural-only: this repo's own convention treats singular `eval/` as shipped test harness — `.claude/eval/`'s hook tests — and plural `evals/`/`Evals/` as non-shipping experiment output. This is the classified failure that motivated this sub-check: a Wiki-repo `Evals/` dir got tracked and shipped.)
- **Gitleaks allow-list guard, for content-bearing repos — conditional (2026-07-10 ruling).** A repo is content-bearing if `git ls-files` matches `fixtures?/|samples?/|golden|Evals?/` (test fixtures, sample corpora, worked examples — content that can trip pattern scanners on intentional test data). If content-bearing:
  - `grep -q '^\[allowlist\]' <target_repo>/.gitleaks.toml` succeeds → PASS.
  - No `[allowlist]`, but the Step 4 operator-pattern sweep over tracked HEAD content produces zero findings → PASS, noted as "content-bearing, no allowlist needed — tracked content trips no patterns."
  - No `[allowlist]` and the sweep finds something → FAIL — the indistinguishable case the check exists for.

  Rationale: an allowlist exists to keep intentional test literals distinguishable from real leaks. When the sweep trips nothing, there's nothing to distinguish, and forcing an allowlist re-adds the suppression surface the operator removed by ruling on 2026-07-09 — dotty's own `.gitleaks.toml` `[allowlist] paths` block had suppressed zero false positives while hiding true positives. The unconditional form of this check (allowlist required whenever content-bearing, full stop) no longer applies; this conditional form replaces it.
- **LICENSE + README present.** `test -f <target_repo>/LICENSE && test -f <target_repo>/README.md`.
- **Every operator-config referenced by tracked machinery has a `*.sample.*` shape.** A reference is a literal filename matching `CLAUDE\.md`, `settings(\.\w+)*\.json`, or `[\w-]*config\.(json|ya?ml)` found inside a tracked file's text. For each unique reference: PASS if the reference itself is also tracked (already public, needs no sample) OR a `*.sample.*`/`*.example.*` counterpart is tracked whose stripped basename matches — exactly, or as a suffix (prose often refers to a longer sampled name by its tail — a tool's generic conf filename standing for the repo's `<tool>-…example` counterpart). Otherwise FAIL, naming the bare reference. The canonical executable form is `scripts/gate-mechanical.sh` § Step 1 — this playbook does not maintain a second copy.

  Known blind spot (documented, not fixed speculatively — same discipline as `qa.py`'s own gaps list): this is a filename heuristic, not a real reference-graph walk. A config referenced only through an indirection (an env var whose value is the filename) won't be caught.

- **Sample-file audit** (placeholder integrity, folded into this same criterion). For every tracked `*.sample.*` file: `grep -lE 'TODO:|path/to/your|YOUR_VALUE_HERE|<[A-Z_]+>'` must hit at least one placeholder marker. Zero hits on a `*.sample.*` file is a FAIL — a sample with no placeholders is either dead weight or a filled-in copy that leaked real values.

### 2. Universe conformance

Zero WARNING+ `unlisted-fiction-entity` findings and zero HIGH `fiction-continuity-mismatch` findings from house-qa's `check` (criteria 3 below derives this from the same run — this is a stricter bar than house-qa's own default use, where WARNING feeds judgment rather than gating alone; the gate chooses to gate on it). For any new narrative/example content in the change (not just what qa.py's regex catches), load `/sample-universe` directly and confirm one-citation-per-file + universe-only vocabulary.

### 3. House-qa mechanical (`check`)

Branch-introduced scoping applies here too — see the codified decision above.

**Never hand-type `--rosters-path`.** A hand-typed path drifts out of sync with wherever the rosters file actually lives (LEX-718: this exact form, without `--rosters-path`, silently fell back to `qa.py`'s own pre-key default — a vault path deleted since LEX-714 — and failed loud with a misleading "not found" instead of a working check). Source `resolve-references-key.sh` (the same resolver `gate-mechanical.sh` uses) and resolve it live:

```bash
GATE_SCRIPTS="<target_repo>/.claude/skills/publish/scripts"
source "$GATE_SCRIPTS/resolve-references-key.sh"
resolve_references_key_check_yq || exit 2
ROSTERS_PATH="$(resolve_references_key references.tag_taxonomy_rosters)"

python3 <target_repo>/.claude/skills/house-qa/qa.py <target_repo> --git-tracked-only \
  --vault-root "$VAULT_ROOT" --json \
  ${ROSTERS_PATH:+--rosters-path "$ROSTERS_PATH"}
```

PASS if zero HIGH findings outside any path matching `*/tests/fixtures/*` — every skill's own regression fixtures contain literal ticket IDs, vault paths, and roster names by design (that's what they test); a real HIGH anywhere else is not excepted. A HIGH finding that reproduces identically against an `origin/HEAD` worktree is pre-existing debt, not a gate failure — reported in `pre_existing_debt`, never gated.

Consumer repos whose artifact classes don't match dotty's corpus carry a repo-local `.house-qa.json` so size checks grade against the repo's OWN class corpus (shape and resolution order: `qa.py` § `repo_config_exemplars`); `--exemplars` on the CLI still overrides.

### 4. House-qa judgment (`review`)

Invoke `/house-qa review` as `playbooks/review.md` specifies — fresh context, never the authoring session. PASS on verdict `KEEP`, or `SIMPLIFY` once its named edits are applied and the artifact is re-reviewed to `KEEP`. `REWORK`, or a `SIMPLIFY` whose edits were never applied, is FAIL. (house-qa's vocabulary is exactly KEEP/SIMPLIFY/REWORK — no fourth tier; map any looser "ship with edits" framing onto SIMPLIFY-then-reverified, not a new tier.)

### 5. Gitleaks full-change scan

```bash
source ~/bin/dotty/git-hooks/gitleaks-common.sh
cd <target_repo> && gl_preflight .gitleaks.toml && \
  gitleaks detect --source . --log-opts="origin/HEAD..HEAD" --config "$GL_EFFECTIVE_CONFIG" --no-banner --ignore-gitleaks-allow
rm -f "$GL_TMP_CONFIG" 2>/dev/null || true
```

Full branch diff since `origin/HEAD` — broader than pre-commit's staged-only slice, and it also catches secrets introduced then reverted within the branch's own history. Uncommitted working-tree changes: `gl_preflight .gitleaks.toml && gitleaks protect --staged --config "$GL_EFFECTIVE_CONFIG" --ignore-gitleaks-allow` first. PASS on exit 0 with zero leaks.

Two codified decisions:

- **Range scoping: the gate gates on branch-introduced findings only.** The `--log-opts` range above IS the gating scan. On repos with pre-abstraction history, an unscoped `gitleaks detect` surfaces historical findings on every run forever — those are reported separately as an informational block (disposition: a history-rewrite ticket), never as gate findings. A finding gates only if the branch introduced it.
- **Resolve the config through `gl_preflight`, never a bare `--config` load.** `.gitleaks.toml`'s `[extend] path` is a relative token; there is no checkout-relative symlink to resolve it against anymore — the operator ruleset loads from the fixed install path (`git-hooks/gitleaks-common.sh`'s `gl_preflight`/`gl_fixed_rules_path`), same as the real pre-commit hooks. A bare `gitleaks detect --config .gitleaks.toml` FTLs (config-load error, not a leak finding) on any repo whose checkout-relative symlink is gone — which is most of the estate. `cd <target_repo>` first (`gl_preflight` reads the config from there, and the `--source .` form keeps target-repo-as-data intact), then always clean up `$GL_TMP_CONFIG`.

### 6. Advisory security review

Picking the path by where the calling session is rooted:

- Session rooted in `target_repo` → run `/security-review` directly (the tuned built-in skill).
- Any other session root (the common case for `/publish` — it takes a repo path precisely so it isn't cwd-bound) → **do not** call `/security-review`; it would review the wrong repo. Instead: `git -C <target_repo> diff origin/HEAD...` and assess inline for >80%-confidence exploitable findings only (injection, authz bypass, path traversal, unsafe deserialization, hardcoded secrets, data exposure) — same bar as the skill, skip style, denial-of-service, and theoretical issues.

**cwd-independence is REQUIRED here, not optional.** This is the executable-path lesson: `/security-review` diffs `origin/HEAD...` in the session's own cwd with no repo argument, so calling it from any session not rooted in `target_repo` silently reviews the wrong tree — a check that passes from one cwd and is silently absent from another. `/publish` closes that hole structurally by always taking `target_repo` as data and using `git -C`, never relying on the calling session's location.

**Executable-delta short-circuit.** The motivating failure: a near-all-markdown branch spent the gate's heaviest step confirming an input set its own policy excludes. Before spending the review, pre-compute the executable-code delta:

```bash
git -C <target_repo> diff --name-only origin/HEAD...HEAD -- . \
  | grep -vE '\.(md|markdown|txt)$' || echo EMPTY
```

`EMPTY` → skip the review entirely; record `security_review: {status: pass, findings: [], skipped: markdown-only-delta}` in the verdict. A docs-only change has no injection/authz/deserialization surface for this step to find — the review's own policy already excludes markdown, so running it would spend the heaviest step to confirm an empty input set.

PASS if zero >80%-confidence exploitable findings (or the short-circuit recorded).

## Verdict schema

```yaml
verdict: pass | fail
target_repo: <abs path>
short_circuited: <bool>        # true if a mechanical FAIL skipped criteria 4 (judgment) and 6 (security review)
pre_existing_debt: [...]       # informational only, never gates — findings from criteria 1 (scaffold) or 3
                                # (house-qa mechanical) that reproduce identically against an origin/HEAD
                                # worktree (see § Criteria "Codified decision — branch-introduced scoping").
                                # Each entry names criterion + check + file; carried on every verdict until
                                # dispositioned.
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
