---
name: github-prep
description: >
  Triggers when the user says "github prep [path]", "check sharing readiness",
  "is this ready to publish", "/github-prep [path]", or similar evaluation requests
  for Claude Code infrastructure artifacts. Emits four-way verdicts per finding
  (Allow / Block / Revise / Escalate) and writes a structured marker for /github-push.
argument-hint: [path]
user_invokable: true
context: fork
agent: github-prep
allowed-tools:
  - Read
  - Glob
  - Grep
  - Write
  - Bash(date:*)
  - Bash(source:*)
  - Bash(jq:*)
  - Bash(git:*)
  - Bash(mkdir:*)
  - Bash(echo:*)
  - Bash(cat:*)
  - Bash(~/bin/dotty/.claude/lib/github-policy.sh*)
  - Bash(~/bin/dotty/.claude/lib/resolve-path.sh*)
  - Bash(~/bin/dotty/.claude/lib/changed-files.sh*)
  - Bash(~/bin/dotty/.claude/lib/github-prep-prepass.sh*)
  - Bash(shasum:*)
---

# /github-prep — Sharing Readiness Judge

Judge a Claude Code project or artifact for readiness to publish on GitHub. Produces a verdict report (grouped by Escalate, Revise, Block, Allow) and writes a structured marker that `/github-push` consumes at the action boundary.

Design source: `~/Vaults/Notes/System/Knowledge/github-prep-methodology.md` (editorial only — this skill does not load that doc at runtime; it embodies it).

## Invocation

```
/github-prep [path] [--full-audit | --docs-only | --bypass "<reason>"]
```

- Optional argument: path to the artifact or project to evaluate
- Default: current working directory; default scope is the change set vs the git baseline
- Accepts: a project directory, skill directory, agent file, rule file, CLAUDE.md, or a directory containing multiple artifacts

**Scope flags (mutually exclusive):**

| Flag | Behavior |
|---|---|
| (none — default) | **Staged-only change set.** Scans `git diff --cached --name-only` plus commits ahead of `origin/main`. Excludes unstaged working-tree modifications and untracked files. This is the multi-session-safe default: another session's in-flight working tree does not pollute your verdict. Empty staged set returns empty scope (typically: "nothing to push"). |
| `--working-tree` | **All uncommitted.** Adds unstaged + untracked files to the staged set. Use when you want to scan everything you're sitting on, regardless of whether it's about to be pushed. |
| `--full-audit` | **Full audit.** Scan the entire commitable surface. Required periodically (TTL-tracked in marker). |
| `--docs-only` | **Docs-only.** Staged set filtered to `.md`, `.txt`, `LICENSE`, `README` files. |
| `--bypass "<reason>"` | **Skip prep entirely.** Records the bypass + reason to an audit log. Operator accepts responsibility. `/github-push` will refuse if `prep.required: true` and no marker exists; bypass is for genuinely trivial cases the operator declares (e.g., comment-only edit). |

**Scope is hard-bounded to the commitable surface.** Regardless of flag, files outside the repo root, files in `.git/`, and gitignored files are unreachable by construction (the file list comes from `git ls-files --cached --others --exclude-standard`).

**Why staged-only is the default:** in a multi-session workflow, one operator's unstaged working-tree changes would otherwise show up as findings in another operator's verdict and (because Revise has no ack path) block the second operator's push. Staged-only isolates each operator's actual push surface. `--working-tree` is available when you want to scan everything regardless.

### Orchestrator-invocation contract

If you (another agent) want to call this skill for a target other than your CWD, write a JSON sentinel BEFORE invoking the Skill tool:

```bash
NOW_UTC=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
printf '{"path": "/absolute/path/to/target", "created_at": "%s"}\n' "$NOW_UTC" \
  > ~/.cache/claude/github-prep-target
```

Then call `Skill(skill: "github-prep")` (no args needed; the Skill tool's `args` parameter is NOT delivered to forked sub-agents per <TEAM>-N). The sentinel is TTL-bounded (5 minutes); resolver treats older sentinels as absent. Sentinels are NOT auto-deleted (chained calls survive); operators may clear via `rm ~/.cache/claude/github-prep-target`.

### Artifact-type detection

| Signal | Type |
|---|---|
| Directory with `.claude/skills/` or `.claude/agents/` inside | Project (evaluate all artifacts) |
| Directory containing a `SKILL.md` | Skill |
| `.md` file inside an `agents/` directory | Agent |
| `.md` file inside a `rules/` directory | Rule |
| A `CLAUDE.md` file | Claude-config |

If the path doesn't exist, report "Path not found: {path}" and exit.

## Execution flow

**Execute these steps in order, starting with Step 1. Do not skip Step 1 — every other step depends on the resolved target path.** Stop and report errors at any step rather than continuing with bad data.

### Step 1: Resolve target path (MANDATORY first step — do not skip)

This skill receives its target path through one of two mechanisms, in priority order: explicit arg from the slash-command invocation, then the sentinel file.

**Do exactly this:**

1. **Capture the argument.** If your invocation context contains an `ARGUMENTS:` line or a `<command-args>...</command-args>` block, the value there is the user-supplied path argument. Otherwise the argument is empty.

2. **Run the resolver, substituting the captured argument** (NOT the literal string `<ARG>`). Two cases:

   **Case A — you have a non-empty argument** (e.g., the user typed `/github-prep /Users/lexi/bin/dotty`):
   ```bash
   ~/bin/dotty/.claude/lib/resolve-path.sh "/Users/lexi/bin/dotty" "$HOME/.cache/claude/github-prep-target"
   ```
   Replace `/Users/lexi/bin/dotty` with the actual captured argument.

   **Case B — you have NO argument** (empty — use empty quoted string, NOT the literal `<ARG>` text):
   ```bash
   ~/bin/dotty/.claude/lib/resolve-path.sh "" "$HOME/.cache/claude/github-prep-target"
   ```
   The empty first argument tells the resolver to check the sentinel file, then fall back to `$PWD`.

3. **Capture the resolver's single-line stdout.** That value is the canonical "target path" / "repo root" referenced in every later step. Treat the resolver's output as authoritative; do NOT compute the target path any other way (e.g., do not use `$PWD` directly, do not use the agent's CWD inheritance).

4. **If the resolver exits non-zero**, report the exact stderr (`Path not found: ...`) and STOP. Do not proceed with a fallback path of your own invention.

5. **Echo the resolved path back to the user** before proceeding to Step 2. The format depends on how the path resolved:
   - Explicit argument or sentinel was used → `Evaluating: <path>`
   - PWD fallback (no argument, no sentinel) → `Evaluating: <path> (defaulted to current directory — no target argument and no sentinel)`

**The PWD-fallback annotation is load-bearing.** If you (the agent) see "defaulted to current directory" and your CWD is a multi-repo workspace or anywhere other than the repo the operator intended, you MUST stop and ask the operator to either pass an explicit argument or write the sentinel. Do NOT silently scan the wrong target — that is the v4 mis-route failure mode this Step 1 exists to prevent.

**Resolver precedence:** explicit argument wins; otherwise sentinel (read but NOT deleted — TTL-bounded per <TEAM>-N); otherwise `$PWD`.

### Step 2: Parse invocation flags

Parse the user's invocation for scope flag (`--full-audit`, `--docs-only`, `--bypass`). Default mode is change-set scope.

**Handle `--bypass "<reason>"` immediately:** if specified, append an entry to `$REPO_ROOT/.github-bypass-log` (one line per bypass: `<ISO timestamp> | <reason> | <operator note if available>`), report the bypass to the user, and EXIT 0. Do NOT write a marker (the absence of marker is the signal to `/github-push` that bypass was used; push's policy decides whether to allow bypass).

### Step 3: Load policy + check prior marker

```bash
source ~/bin/dotty/.claude/lib/github-policy.sh
load_policy "$REPO_ROOT"
```

Populates `$GH_POLICY_HASH`, `$GH_POLICY_VISIBILITY`, `$GH_POLICY_TREAT_AS_PUBLIC_FOR_SECRETS`, `$GH_POLICY_SECRET_SCANNING_BASELINE`. Defaults: treat as public, prep_required.

Read existing `.github-prep-status.json` if present.

**Marker-schema-version check (load-bearing):** v5 marker has `marker_schema_version: 2`. If prior marker has no `marker_schema_version`, or `marker_schema_version: 1`, or per-finding `severity` instead of `verdict`: **discard the prior marker entirely** and force `--full-audit` scope. Do not attempt cache reuse from a v1 marker.

**Full-scan TTL check:** the v5 marker carries `last_full_scan_at` (ISO 8601 UTC). If the current scope is change-set and `last_full_scan_at` is absent OR older than 30 days (default; configurable via `$GH_POLICY_FULL_SCAN_TTL_DAYS` if set), auto-upgrade scope to `--full-audit` with an annotation: "Last full scan was N days ago; upgrading to full-audit to ensure coverage."

For matching v2 markers (same `marker_schema_version`, `scanner_version`, `policy_hash`):
- Files whose `sha256` content hash matches the cached entry are skipped — copy their findings forward.
- Files with no prior hash entry (newly added) are always scanned.
- Never silently skip new content.

### Step 4: Determine scope (file list)

Use `changed-files.sh` to produce the file list bounded to the commitable surface. The mode flag passed to it depends on the scope determined in Step 1 (and any TTL-driven upgrade from Step 2):

```bash
# Default (change-set scope, or upgraded to full-audit by TTL):
~/bin/dotty/.claude/lib/changed-files.sh "$REPO_ROOT" change-set > /tmp/prep-files-$$.list

# --full-audit:
~/bin/dotty/.claude/lib/changed-files.sh "$REPO_ROOT" --full-audit > /tmp/prep-files-$$.list

# --docs-only:
~/bin/dotty/.claude/lib/changed-files.sh "$REPO_ROOT" --docs-only > /tmp/prep-files-$$.list
```

Output is a NUL-separated list of file paths relative to `$REPO_ROOT`. All paths are guaranteed to be in the commitable surface (git-tracked or untracked-not-gitignored). Files outside the repo, in `.git/`, or gitignored are filtered out by construction — this is the safety bound, not a policy.

If the list is empty:
- For `change-set` mode: report "No changed files in scope. Nothing to scan." Write a marker with `verdict: allow`, `scope: change-set`, empty findings, and exit.
- For `--full-audit` and `--docs-only`: report "No files in scope." Exit without writing.

### Step 5: Pre-pass — deterministic HIGH-confidence patterns

Pipe the file list into `github-prep-prepass.sh`. The pre-pass detects:

- **Secrets** (verdict: Block): `sk-ant-`, `sk-`, `gh[psour]_`, `xox[abprs]-`, `AKIA`, `AWS_SECRET_ACCESS_KEY=<value>` patterns
- **Hardcoded paths** (verdict: Revise): `/Users/<name>/`, `/home/<name>/`

```bash
cat /tmp/prep-files-$$.list | ~/bin/dotty/.claude/lib/github-prep-prepass.sh "$REPO_ROOT" > /tmp/prep-prepass-$$.ndjson
```

Output is NDJSON — one JSON finding per line, each with `source: "prepass"`. These findings are deterministic (regex-matched against verbatim file content); they do NOT need LLM evaluation.

Pre-pass findings cover Secret and Hardcoded path categories. **The agent persona must NOT re-emit these categories** in Step 5 — the orchestration tells the persona explicitly that these are handled.

### Step 6: LLM-judgment classify (delegate to agent persona)

The persona (`agents/github-prep.md`) defines the verdict model, categories, refuse-by-default + evidence-citation. **Do not duplicate the taxonomy here.**

Tell the persona:
1. The file list (from Step 3) is the scope to evaluate.
2. The pre-pass already covered Secret and Hardcoded path. **Skip those categories** unless the pre-pass missed something contextually obvious (e.g., a credential that doesn't match the regex catalog).
3. Focus on JUDGMENT-tier categories: PII, Internal reference, Personal context, Domain knowledge, Separation of concerns.
4. For each finding, emit JSON with `category`, `verdict`, `file`, `line`, `snippet`, `reason`. Each finding gets `source: "judgment"` in the marker.
5. Each finding's verdict is `Allow`, `Block`, `Revise`, or `Escalate`. The persona defines per-category defaults and the visibility-aware adjustment.
6. Cite evidence per finding — `file`, `line`, `snippet` must be verbatim. Step 8 marker write will fail if citations don't validate.
7. Default to NOT-Allow when uncertain.

### Step 7: Merge findings

Merge the pre-pass NDJSON (Step 4) with the LLM-judgment findings (Step 5) into a single findings list. Deduplication: if a (file, line, category) triple appears in both, keep the pre-pass entry (deterministic wins).

### Step 8: Sample-file drift check

For every `*.sample.md` file found alongside a real config file (e.g., `CLAUDE.sample.md` next to `CLAUDE.md`, `settings.sample.json` next to `settings.json`):

1. Read both the real file and the sample.
2. Identify fields present in the real file that are missing from the sample.
3. Identify hooks/scripts shipped in `.claude/hooks/` not represented in `settings.sample.json`.
4. For each drift: emit a finding with `category: "Sample drift"`, `verdict: "Revise"` (consumers cloning the repo and following the sample will hit gaps — must be fixed in the sample file).
5. Reverse drift (sample fields no longer in the real file) is also `Revise`.

### Step 9: Documentation readiness

Documentation expectations are visibility-aware.

**For `visibility: public`:**
- README.md present → `Allow`. Missing → `Revise` (consumer needs docs).
- CLAUDE.sample.md present (project-level) → `Allow`. Missing → `Revise`.
- LICENSE present → `Allow`. Missing → `Block` (operator may ack if intentional; default is to add one).
- `.gitignore` present + excludes `.github-prep-status.json`, `CLAUDE.md`, `settings.json` → `Allow`. Missing entries → `Revise`.

**For `visibility: private`:**
- README, CLAUDE.sample.md, LICENSE — mark "n/a (private repo)" in the report; no finding. A private dotfiles companion has no consumers.
- `.gitignore` — still required; the `CLAUDE.md` exclusion expectation does NOT apply (non-vault CLAUDE.md in private repos is intentionally committed for backup). Continue requiring exclusion of `.github-prep-status.json` and `settings.local.json`.

### Step 10: Apply secret-scanning baseline (if configured)

If `$GH_POLICY_SECRET_SCANNING_BASELINE` is non-empty and the named file exists at `$REPO_ROOT/{baseline_path}`:

1. Read the baseline file (JSON array of `{path, line, rule_id, hash_of_match}` entries).
2. For each finding produced in Steps 3-5: if a baseline entry matches (same path, same rule_id/category, same line ± a few lines, same `hash_of_match`), downgrade the finding to `verdict: "Allow"` and annotate with `"baselined": true` and `"baselined_from_verdict": "<original>"`.
3. Findings not in baseline retain their classified verdict.

Baseline format: store `hash_of_match` (sha256 of the matched content), not the raw match — baseline files travel with public repos and must not re-leak the original.

### Step 11: Compute overall verdict + write marker

**Overall verdict by precedence:**

- Any `Escalate` finding → overall `escalate`
- Else any `Revise` finding → overall `revise`
- Else any `Block` finding → overall `block`
- Else (only `Allow` findings, or no findings) → overall `allow`

**Always write the marker, even on cache-hit runs.** A cache-hit run (every file's hash matched the prior marker; findings carried forward unchanged) still updates `evaluated_at` to the current invocation time. Without this, `/github-push`'s TTL check would see the timestamp from the LAST PER-FILE CLASSIFICATION rather than the last operator check — making the marker appear stale faster than it actually is. The marker IS the freshness signal; every invocation refreshes it.

For cache-hit runs, the only fields that change vs the prior marker are: `evaluated_at` (refreshed), `scope` (might differ if operator passed a different flag), `scope_upgrade_reason` (might differ). Findings, file_hashes, summary, last_full_scan_at, and acknowledgments are carried forward verbatim.

**Write `.github-prep-status.json` to the evaluated path's root:**

```json
{
  "marker_schema_version": 2,
  "evaluated_path": "{absolute path}",
  "evaluated_at": "{ISO 8601 UTC timestamp}",
  "scope": "{change-set | full-audit | docs-only}",
  "last_full_scan_at": "{ISO 8601 UTC timestamp of most recent full-audit scan; null on first run}",
  "scope_upgrade_reason": "{null, or e.g. 'last_full_scan_at older than 30d; auto-upgraded'}",
  "files_scanned_count": 42,
  "scanner_version": "2.1.0",
  "policy_hash": "{from policy reader, sha256:...}",
  "verdict": "{allow | block | revise | escalate}",
  "artifact_type": "{project | skill | agent | rule | claude-config}",
  "findings": [
    {
      "category": "{Secret | PII | Hardcoded path | Internal reference | Personal context | Domain knowledge | Separation of concerns | Sample drift}",
      "verdict": "{Allow | Block | Revise | Escalate}",
      "file": "{relative path within evaluated_path}",
      "line": 42,
      "snippet": "{verbatim text from that line}",
      "reason": "{1-2 sentences}",
      "source": "{prepass | judgment | sample-drift | docs-check | baseline}"
    }
  ],
  "acknowledgments": [],
  "file_hashes": {
    "{relative path}": "sha256:..."
  },
  "summary": {
    "allow": 0,
    "block": 0,
    "revise": 0,
    "escalate": 0
  }
}
```

**`last_full_scan_at` semantics:**
- Updated to current `evaluated_at` whenever `scope == "full-audit"` (whether operator requested or TTL-upgraded).
- Preserved across change-set scans (so the TTL countdown continues from the last actual full scan).
- Initial null on first run; the first full-audit sets it.

**`scope_upgrade_reason` semantics:**
- Null when the operator's requested scope is honored without change.
- Set to a human-readable explanation when scope changes mid-flight (e.g., "v1 marker present, upgraded to full-audit per schema-upgrade rule"; "last_full_scan_at was 47 days ago, exceeds 30d TTL"; "no marker present and no prior baseline, defaulting to full-audit").

**Field semantics:**

| Field | Source | Used by /github-push |
|---|---|---|
| `marker_schema_version` | constant in this skill (currently `2`) | hard schema check; mismatch → push refuses with "re-run prep" |
| `evaluated_at` | `date -u +"%Y-%m-%dT%H:%M:%SZ"` | TTL check against `policy.prep.ttl_hours` |
| `scope` | from the scope flag (default `change-set`) | push displays so operator knows what was scanned |
| `last_full_scan_at` | updated when scope==full-audit; preserved otherwise | drives auto-upgrade to full-audit when stale |
| `files_scanned_count` | length of file list from Step 3 | operator-visible "you scanned N files" |
| `scanner_version` | constant in this skill (currently `2.1.0`; bump on taxonomy / persona / pre-pass pattern change) | invalidates cache on mismatch |
| `policy_hash` | `$GH_POLICY_HASH` | invalidates verdict on policy change |
| `verdict` | derived above | gate decision at push |
| `findings` | per-finding from Step 3-6 | shown to operator on push if non-Allow |
| `acknowledgments` | initially empty; push appends here on operator ack | carries Block acks forward across re-prep |
| `file_hashes` | `sha256` of each scanned file | incremental scan on re-run |
| `summary` | per-verdict counts | quick reference |

**Evidence validation before write:** for each finding, verify `file:line` exists in the file and `snippet` matches verbatim. If a finding fails validation, emit a marker-write error noting the malformed finding and exclude it from the marker. Fabricated evidence must not silently pass through.

Marker is gitignored (transient, per-machine).

### Step 12: Generate CLAUDE.sample.md (if missing)

If this is a project-level evaluation, `visibility: public`, and no `CLAUDE.sample.md` exists at the project root, generate a draft:

1. Read the project's `CLAUDE.md` for structure.
2. From the skills evaluated in Step 2, identify every reference to CLAUDE.md content — config fields skills read, external paths, sections skills assume exist.
3. Build a sample containing:
   - The intent sections from the real CLAUDE.md (these are the software's design; they ship as-is)
   - A Configuration section with placeholder values for every external path or config field skills reference
   - A File Structure section describing the repo layout
   - An empty Project State template
   - Any other sections skills depend on at runtime
4. Replace personal paths, operational state, and private data with placeholders and explanatory comments.
5. Write to `CLAUDE.sample.md` at the project root.

Report that the sample was generated and should be reviewed by the human.

### Step 13: Produce operator-visible report

After writing the marker, produce a human-readable report grouped in this order:

```
## Sharing Readiness Report: {artifact-name}

**Artifact type:** {project | skill | agent | rule | claude-config}
**Path:** {evaluated path}
**Scope:** {change-set | full-audit | docs-only} — {N files scanned}
{If `scope_upgrade_reason` is non-null, add: **Scope-upgrade note:** {reason}}
**Evaluated:** {timestamp}
**Last full scan:** {last_full_scan_at, or "never (this is the first full scan)"}

### ESCALATE ({n})
{findings the operator must decide on; LLM judge cannot resolve}
{Each: Category — file:line — snippet — reason — "Human judgment needed: <what>"}
{Or: "None"}

### REVISE ({n})
{findings the operator must fix in code; no ack path}
{Each: Category — file:line — snippet — reason — "Suggested fix: <remediation>"}
{Or: "None"}

### BLOCK ({n})
{findings that may be ack-and-proceeded if operator has overriding context}
{Each: Category — file:line — snippet — reason — "Ack available if: <criteria>"}
{Or: "None"}

### ALLOW ({n})
{count only; details in marker — operator does not need to see verbatim Allow findings}

### Documentation
- README.md: {Allow | Revise | n/a (private)}
- CLAUDE.sample.md: {Allow | Revise | n/a (private)}
- LICENSE: {Allow | Block | n/a (private)}
- .gitignore: {Allow | Revise}

---

**Visibility:** {public | private (treat_as_public_for_secrets: {true|false})}
**Overall verdict: {allow | block | revise | escalate}**
**Next action:** {what the operator should do — depends on overall verdict}
```

Next action by verdict:
- `allow` → "Safe to push; `/github-push` will proceed."
- `block` → "Review BLOCK findings. For each: fix the issue, OR ack with exact string if you have overriding context. Then `/github-push` will gate appropriately."
- `revise` → "Fix the REVISE findings in code. Re-run `/github-prep` after fixes. Push will not proceed until these are addressed."
- `escalate` → "Decide on the ESCALATE findings — they require human judgment. If a finding is legitimate, update the policy's known-references list and re-run prep. Otherwise fix the underlying content."

## Stop rules

| Condition | Action |
|---|---|
| No path and no working directory | Report usage and exit |
| Path does not exist | Report "Path not found" and exit |
| No recognized artifact files at path | Report "No Claude Code artifacts found at {path}" and exit |
| Existing marker has incompatible `marker_schema_version` | Discard prior marker; full-scan; report "Marker schema upgraded; full re-scan performed" |
| Finding citation fails verbatim validation | Exclude the malformed finding from marker; report which finding failed |

## Error handling

| Condition | Behavior |
|---|---|
| Path is a file but not a recognized artifact type | Report "Unrecognized artifact type at {path}" and exit |
| Directory contains mix of artifacts and non-artifacts | Evaluate recognized artifacts, note skipped files |
| File read fails | Report which file failed, continue with remaining files |
| Marker write fails | Report error but still output the evaluation report |
| Persona emits malformed finding (missing required field) | Exclude from marker; report the malformation |
