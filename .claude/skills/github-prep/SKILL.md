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
  - Bash(~/bin/dotty/.claude/lib/prep-cache-check.sh*)
  - Bash(shasum:*)
---

# /github-prep — Sharing Readiness Judge

Judge a Claude Code project or artifact for readiness to publish. Writes a structured marker that `/github-push` consumes.

## Invocation

```
/github-prep [path] [--working-tree | --full-audit | --docs-only | --bypass "<reason>"]
```

Default scope is the **staged** change set (`git diff --cached`). Scope is hard-bounded to the commitable surface via `git ls-files --cached --others --exclude-standard` — gitignored files and anything outside the repo are unreachable by construction.

| Flag | Scope |
|---|---|
| (none) | Staged-only. Multi-session safe — another session's unstaged tree won't pollute your verdict. |
| `--working-tree` | Staged + unstaged + untracked. |
| `--full-audit` | Full commitable surface. TTL-tracked. |
| `--docs-only` | Staged, filtered to `.md` / `.txt` / `LICENSE` / `README`. |
| `--bypass "<reason>"` | Skip prep; log the bypass. Push refuses if `prep.required: true`. |

### Orchestrator-invocation contract

Other agents calling this skill must write a JSON sentinel first (the Skill tool's `args` parameter is not delivered to forked sub-agents):

```bash
NOW_UTC=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
printf '{"path": "/absolute/path/to/target", "created_at": "%s"}\n' "$NOW_UTC" \
  > ~/.cache/claude/github-prep-target
```

Then call `Skill(skill: "github-prep")`. Sentinel TTL: 5 min. Not auto-deleted; clear with `rm` if needed.

### Artifact-type detection

| Signal | Type |
|---|---|
| Directory with `.claude/skills/` or `.claude/agents/` inside | Project |
| Directory containing a `SKILL.md` | Skill |
| `.md` file inside an `agents/` directory | Agent |
| `.md` file inside a `rules/` directory | Rule |
| A `CLAUDE.md` file | Claude-config |

Path doesn't exist → report "Path not found" and exit.

## Execution flow

Execute in order. Stop and report errors rather than continuing with bad data.

### Step 1: Resolve target path

Capture the argument from `ARGUMENTS:` / `<command-args>` (empty if none), then run:

```bash
~/bin/dotty/.claude/lib/resolve-path.sh "<arg-or-empty>" "$HOME/.cache/claude/github-prep-target"
```

The resolver's stdout is the canonical target path. Non-zero exit → report stderr and stop.

Echo the resolved path back to the operator:
- Explicit arg or sentinel was used → `Evaluating: <path>`
- PWD fallback → `Evaluating: <path> (defaulted to current directory — no target argument and no sentinel)`

If you see the PWD-fallback annotation and your CWD isn't obviously the intended repo, stop and ask the operator.

Precedence: explicit arg > sentinel (TTL-bounded, not deleted) > PWD.

### Step 2: Parse invocation flags

Parse the user's invocation for scope flag (`--full-audit`, `--docs-only`, `--bypass`). Default mode is change-set scope.

**Handle `--bypass "<reason>"` immediately:** if specified, append an entry to `$REPO_ROOT/.github-bypass-log` (one line per bypass: `<ISO timestamp> | <reason> | <operator note if available>`), report the bypass to the user, and EXIT 0. Do NOT write a marker (the absence of marker is the signal to `/github-push` that bypass was used; push's policy decides whether to allow bypass).

### Step 3: Load policy

```bash
source ~/bin/dotty/.claude/lib/github-policy.sh
load_policy "$REPO_ROOT"
```

Populates `$GH_POLICY_HASH`, `$GH_POLICY_VISIBILITY`, `$GH_POLICY_TREAT_AS_PUBLIC_FOR_SECRETS`, `$GH_POLICY_SECRET_SCANNING_BASELINE`. Conservative defaults (treat as public, prep_required) when no policy file exists.

Read existing `.github-prep-status.json` if present. If its `marker_schema_version` is anything other than `2` (including absent), discard it and force `--full-audit`.

If `last_full_scan_at` is absent or older than 30 days (configurable via `$GH_POLICY_FULL_SCAN_TTL_DAYS`), auto-upgrade scope to `--full-audit` and note this in `scope_upgrade_reason`.

### Step 3.5: Cache-hit fast path

Run the cache-check guard. On exit 0, the marker is still valid: skip Steps 4-12 and go directly to Step 13.

```bash
GH_SCANNER_VERSION="2.1.0" GH_POLICY_HASH="$GH_POLICY_HASH" \
  ~/bin/dotty/.claude/lib/prep-cache-check.sh "$REPO_ROOT" "<scope>"
```

Exit 1 = cache-miss (reason on stderr); proceed with Steps 4-12.
Exit 2 = script error; treat as cache-miss; proceed.

### Step 4: Determine scope (file list)

```bash
~/bin/dotty/.claude/lib/changed-files.sh "$REPO_ROOT" "<scope>" > /tmp/prep-files-$$.list
```

NUL-separated paths, relative to `$REPO_ROOT`, bounded to the commitable surface.

Empty list:
- `change-set`: report "Nothing to scan." Write marker with `verdict: allow`, empty findings, exit.
- `--full-audit` / `--docs-only`: report "No files in scope." Exit without writing.

### Step 5: Pre-pass

```bash
cat /tmp/prep-files-$$.list | ~/bin/dotty/.claude/lib/github-prep-prepass.sh "$REPO_ROOT" > /tmp/prep-prepass-$$.ndjson
```

NDJSON findings with `source: "prepass"`. Covers Secret + Hardcoded path categories.

### Step 6: LLM-judgment classify

The persona (`agents/github-prep.md`) holds the taxonomy. Pass the file list as scope, tell it to skip Secret + Hardcoded path (handled by pre-pass), and to emit findings as JSON with `category`, `verdict`, `file`, `line`, `snippet`, `reason`, `source: "judgment"`.

### Step 7: Merge findings

Combine pre-pass NDJSON with LLM-judgment findings. On (file, line, category) collision, pre-pass wins.

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

Overall verdict by precedence: Escalate > Revise > Block > Allow.

Always write the marker (refresh `evaluated_at`) even on cache-hit; the marker is the freshness signal `/github-push` reads. Schema is at `lib/contracts/marker-v2.schema.json`:

```json
{
  "marker_schema_version": 2,
  "evaluated_path": "...",
  "evaluated_at": "<ISO 8601 UTC>",
  "scope": "change-set | full-audit | docs-only",
  "last_full_scan_at": "<ISO 8601 UTC or null>",
  "scope_upgrade_reason": "<string or null>",
  "files_scanned_count": 42,
  "scanner_version": "2.1.0",
  "policy_hash": "sha256:...",
  "verdict": "allow | block | revise | escalate",
  "artifact_type": "project | skill | agent | rule | claude-config",
  "findings": [{"category": "...", "verdict": "...", "file": "...", "line": 42, "snippet": "...", "reason": "...", "source": "prepass | judgment | sample-drift | docs-check | baseline"}],
  "acknowledgments": [],
  "file_hashes": {"<path>": "sha256:..."},
  "summary": {"allow": 0, "block": 0, "revise": 0, "escalate": 0}
}
```

`last_full_scan_at` updates only on full-audit scans; preserved across change-set scans. `scope_upgrade_reason` is non-null when scope was upgraded mid-flight (schema mismatch, stale TTL, etc).

Before writing: validate each finding's `file:line:snippet` against actual file content. Drop fabricated findings; report which.

Marker is gitignored.

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
