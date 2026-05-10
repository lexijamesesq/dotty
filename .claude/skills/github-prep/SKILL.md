---
name: github-prep
description: >
  Triggers when the user says "github prep [path]", "check sharing readiness",
  "is this ready to publish", "/github-prep [path]", or similar evaluation requests
  for Claude Code infrastructure artifacts.
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
  - Bash(~/bin/dotty/.claude/lib/github-policy.sh*)
  - Bash(~/bin/dotty/.claude/lib/resolve-path.sh*)
  - Bash(shasum:*)
---

# /github-prep — Sharing Readiness Evaluation

Evaluate a Claude Code project or artifact for readiness to publish on GitHub. Produces a severity-ordered report and writes a status marker for downstream tools.

## Invocation

```
/github-prep [path]
```

- Optional argument: path to the artifact or project to evaluate
- Default: current working directory
- Accepts: a project directory, skill directory (containing SKILL.md), agent file (.md in agents/), rule file (.md in rules/), or a directory containing multiple artifacts
- Examples: `/github-prep`, `/github-prep path/to/your/project/`, `/github-prep claude/skills/develop/`

## Arguments

### Step 0: Resolve target path (run this Bash command first; use its output for all subsequent steps)

This skill receives its target path through one of two mechanisms, in priority order:

1. **Slash-command path** (user types `/github-prep [path]`) — the path appears in your invocation context as a `<command-args>...</command-args>` block and a trailing `ARGUMENTS: <value>` line. Extract the value yourself.
2. **Sentinel-file path** (another agent calls `Skill(skill: "github-prep")` for you) — the calling orchestrator must have written the absolute target path to `~/.cache/claude/github-prep-target` before invoking. The Skill tool's `args` parameter is **not** delivered to forked sub-agents (<TEAM>-N), so the sentinel file is the only reliable cross-agent channel.

**Do this in order:**

1. If you can see an `ARGUMENTS:` line or `<command-args>` block in your invocation context, capture that value as `<ARG>`. Otherwise, set `<ARG>` to the empty string.
2. Run this Bash command exactly, substituting `<ARG>` with the captured value (empty string is fine — the resolver will fall back to the sentinel file or PWD):

   ```bash
   ~/bin/dotty/.claude/lib/resolve-path.sh "<ARG>" "$HOME/.cache/claude/github-prep-target"
   ```

3. Capture the single-line stdout. That is the canonical "target path" / "evaluated path" referenced in every later step.
4. If the command exits non-zero (`Path not found: ...`), report the error and stop.
5. State the resolved path back to the user before proceeding. The format depends on which precedence tier resolved the path:
   - **Explicit `<ARG>` or sentinel was used** → `Evaluating: <path>`
   - **`$PWD` fallback** (no `<ARG>`, no sentinel file) → `Evaluating: <path> (defaulted to current directory; no target specified)`

   The PWD-fallback annotation is load-bearing: an orchestrator that meant to evaluate a different target will see this, recognize the mismatch, and consult the orchestrator-invocation contract below.

**Resolver precedence:** explicit `<ARG>` wins; otherwise, the sentinel file is consumed (and deleted to prevent stale reuse); otherwise, `$PWD`.

### Orchestrator-invocation contract

If you (an agent) want to call this skill for a target other than your CWD, write the absolute path to the sentinel file before invoking the Skill tool:

```bash
echo "/absolute/path/to/target" > ~/.cache/claude/github-prep-target
```

Then call `Skill(skill: "github-prep")` (no args needed; the args parameter is ignored). The skill consumes and deletes the sentinel on first read.

**Artifact type detection:**

| Signal | Type |
|--------|------|
| Directory with `claude/skills/` or `claude/agents/` inside | Project (evaluate all artifacts) |
| Directory containing a `SKILL.md` | Skill |
| `.md` file inside an `agents/` directory | Agent |
| `.md` file inside a `rules/` directory | Rule |
| A `CLAUDE.md` file | Claude-config |

If the path doesn't exist, report "Path not found: {path}" and exit.

## Execution Flow

Execute these steps in order. Stop and report errors at any step rather than continuing with bad data.

### Step 1: Load Policy and Plan Incremental Scan

Load the per-project policy:

```bash
source ~/bin/dotty/.claude/lib/github-policy.sh
load_policy "$REPO_ROOT"
```

The reader populates `$GH_POLICY_HASH`, `$GH_POLICY_SECRET_SCANNING_BASELINE`, and other accessors. Defaults are conservative (treat as public, prep_required, no force push) when no `.claude/github-policy.yaml` exists.

Read existing `.github-prep-status.json` if present. **Use cached file hashes to skip unchanged files** when:

- `scanner_version` in marker matches current scanner version
- `policy_hash` in marker matches current `$GH_POLICY_HASH`

When either mismatches, scan all files (cache invalidated). When both match, files whose `sha256` content hash matches the cached entry are skipped — copy their findings forward.

**Default-scan-on-missing:** files with no prior hash entry (newly added) are always scanned. Never silently skip new content.

### Step 2: Read Artifact(s)

Based on detected artifact type:

- **Project:** Glob for all `.md` files in `claude/skills/`, `claude/agents/`, and the project root. Also read reference docs, templates, and any other tracked content. Build a manifest of discovered artifacts.
- **Skill:** Read `SKILL.md` and any sibling files in the skill directory
- **Agent:** Read the agent `.md` file
- **Rule:** Read the rule `.md` file
- **Claude-config:** Read the `CLAUDE.md` file

### Step 3: Apply Classification Taxonomy

Scan all content against the taxonomy defined in the agent persona. For each file:

1. **Secrets scan** — Look for API key patterns (`sk-`, `xoxb-`, `ghp_`, `AKIA`), credential assignments, `.env` references with values, connection strings, base64 blobs in assignments
2. **PII scan** — Look for email addresses, phone numbers, internal usernames, Slack member IDs, names of people other than the repo owner
3. **Hardcoded path scan** — Look for `/Users/`, `~/`, absolute paths to specific machines
4. **Internal reference scan** — Look for internal URLs (*.internal, *.corp), Jira project keys, Slack channel references, Confluence links, proprietary product names used as if the reader would know them
5. **Personal context scan** — Look for role titles, team names, org structure, individual preferences, workflow specifics embedded in procedural content
6. **Domain knowledge scan** — Note product/framework/methodology references that assume familiarity

Record each finding with: category, severity, file path, line number or section, the flagged content, and a note about why it's flagged.

### Step 4: Separation of Concerns Check (Skills Only)

For skill artifacts, apply the key distinction test:

- Read each instruction step and ask: "Is this telling the agent *what to do* (procedure) or *who is doing it / why* (context)?"
- Procedural content is expected and clean
- Contextual content should be flagged under "Personal context" with a note that it could be externalized to CLAUDE.md

Common patterns to flag:
- Step instructions that reference specific team names or products by name
- Persona descriptions embedded in skill steps (should be in agent file or CLAUDE.md)
- Hardcoded file paths to personal vault locations
- References to specific people by name in workflow descriptions

### Step 5: Documentation Readiness Check

Check for:
- **README.md** — Does one exist at the project/artifact root? Note presence/absence.
- **CLAUDE.sample.md** — For project-level evaluations, does a sample config exist? Note presence/absence.
- **LICENSE** — Does one exist at the project root? Note presence/absence. Non-blocking but worth flagging.
- **.gitignore** — Does one exist? Does it exclude personal config (CLAUDE.md, settings.local.json) and created content?

### Step 5b: Sample File Drift Check

For every `*.sample.md` file found alongside a real config file (e.g., `CLAUDE.sample.md` next to `CLAUDE.md`, `jira-config.sample.md` next to `jira-config.md`):

1. Read both the real file and the sample
2. Compare the Configuration/config sections — identify fields present in the real file that are missing from the sample
3. Flag any drift as a REVIEW finding: "CLAUDE.md has config field `{field}` not represented in CLAUDE.sample.md"
4. Also flag the reverse: sample fields that no longer exist in the real file (stale placeholders)

This ensures consumers always see the complete configuration surface.

### Step 6: Apply Secret-Scanning Baseline (if configured)

If `$GH_POLICY_SECRET_SCANNING_BASELINE` is non-empty and the named file exists at `$REPO_ROOT/{baseline_path}`:

1. Read the baseline file (JSON array of `{path, line, rule_id, hash_of_match}` entries)
2. For each finding produced in Steps 3-5: if a baseline entry matches (same path, same rule_id, same line ± a few lines, same `hash_of_match`), downgrade the finding's severity from BLOCK to FLAG and annotate with `"baselined": true`
3. Findings not in baseline retain their classified severity

This handles repos with known historical leaks (e.g. HA repo's Amazon OAuth credentials in git history). The baseline records what's already been accepted; new findings still surface as BLOCK/REVIEW.

**Baseline format note:** baseline files travel with public repos. Store `hash_of_match` (sha256 of the matched content), not the raw match — baseline files in public repos must not re-leak the original.

### Step 7: Produce Report

Output findings in severity order:

```
## Sharing Readiness Report: {artifact-name}

**Artifact type:** {project | skill | agent | rule | claude-config}
**Path:** {evaluated path}
**Evaluated:** {timestamp}

### BLOCKS
{findings that must be fixed — secrets, PII}
{Or: "None"}

### REVIEW
{findings requiring human judgment — hardcoded paths, internal references, personal context}
{Or: "None"}

### FLAGS
{awareness items — domain knowledge notes}
{Or: "None"}

### CLEAN
{dimensions checked with no findings}

### Documentation
- README.md: {present | missing}
- CLAUDE.sample.md: {present | missing | n/a}
- LICENSE: {present | missing}
- .gitignore: {present | missing}

---

**Result: {blocked | review-needed | clean}**
**Recommendation:** {one sentence — what to do next}
```

Result logic:
- `blocked` — any BLOCK findings exist
- `review-needed` — no BLOCKs but REVIEW findings exist
- `clean` — only FLAGS or no findings

### Step 8: Generate CLAUDE.sample.md (if missing)

If this is a project-level evaluation and no `CLAUDE.sample.md` exists, generate a draft.

To build the sample:
1. Read the project's `CLAUDE.md` (if it exists) for structure
2. From the skills evaluated in Step 2, identify every reference to CLAUDE.md content — config fields skills read, external paths, sections skills assume exist
3. Build a sample containing:
   - The intent sections (objective, desired outcomes, health metrics, decision authority, stop rules) from the real CLAUDE.md — these are the software's design, they ship as-is
   - A Configuration section with placeholder values for every external path or config field skills reference
   - A File Structure section describing the repo layout
   - An empty Project State template
   - Any other sections skills depend on at runtime
4. Replace all personal paths, operational state, and private data with placeholders and comments explaining what to fill in
5. Write to `CLAUDE.sample.md` at the project root

Report that the sample was generated and should be reviewed by the human.

### Step 9: Write Structured Status Marker

Write `.github-prep-status.json` to the evaluated path's root with the structured verdict shape that `/github-push` consumes:

```json
{
  "evaluated_path": "{absolute path}",
  "evaluated_at": "{ISO 8601 timestamp}",
  "scanner_version": "1.0.0",
  "policy_hash": "{from policy reader, sha256:...}",
  "verdict": "{blocked | review-needed | clean}",
  "artifact_type": "{project | skill | agent | rule | claude-config}",
  "findings": [
    {
      "category": "{Secret | PII | Hardcoded path | Internal reference | Personal context | Domain knowledge | Sample drift}",
      "severity": "{BLOCK | REVIEW | FLAG}",
      "file": "{relative path within evaluated_path}",
      "line": 42,
      "snippet": "{flagged content excerpt}"
    }
  ],
  "file_hashes": {
    "{relative path}": "sha256:..."
  },
  "summary": {
    "blocks": 0,
    "reviews": 0,
    "flags": 0
  }
}
```

**Field semantics:**

| Field | Source | Used by /github-push |
|---|---|---|
| `evaluated_at` | `date -u +"%Y-%m-%dT%H:%M:%SZ"` | TTL check against policy.prep.ttl_hours |
| `scanner_version` | constant in this skill (bump on any taxonomy or pattern change) | invalidates cache + verdict on mismatch |
| `policy_hash` | `$GH_POLICY_HASH` from policy reader | invalidates verdict on mismatch (policy changed since prep) |
| `verdict` | derived from highest-severity finding | gate decision per `policy.prep.strictness` |
| `findings` | structured per-finding list | shown to user on push if non-empty |
| `file_hashes` | `sha256` of each scanned file's content | enables incremental scan on re-run |
| `summary` | counts | quick reference |

**Computing `policy_hash`:** load the per-project policy via the reader before scanning:

```bash
source ~/bin/dotty/.claude/lib/github-policy.sh
load_policy "$REPO_ROOT"
# $GH_POLICY_HASH now populated
```

Marker is gitignored (transient, per-machine). The verdict is structured for /github-push consumption; the human-readable report is the conversation output (Step 5).

## Stop Rules

| Condition | Action |
|-----------|--------|
| No path and no working directory | Report usage and exit |
| Path does not exist | Report "Path not found" and exit |
| No recognized artifact files at path | Report "No Claude Code artifacts found at {path}" and exit |
| Secret or credential found | Include in BLOCKS, set result to "blocked" |

## Error Handling

| Condition | Behavior |
|-----------|----------|
| Path is a file but not a recognized artifact type | Report "Unrecognized artifact type at {path}" and exit |
| Directory contains mix of artifacts and non-artifacts | Evaluate recognized artifacts, note skipped files |
| File read fails | Report which file failed, continue with remaining files |
| Status marker write fails | Report error but still output the evaluation report |
