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

Parse `$ARGUMENTS` to resolve the target path.

**Resolution rules:**

| Input | Behavior |
|-------|----------|
| Empty | Use current working directory |
| Absolute path | Use as-is |
| Relative path | Resolve relative to current working directory |

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

### Step 1: Read Artifact(s)

Based on detected artifact type:

- **Project:** Glob for all `.md` files in `claude/skills/`, `claude/agents/`, and the project root. Also read reference docs, templates, and any other tracked content. Build a manifest of discovered artifacts.
- **Skill:** Read `SKILL.md` and any sibling files in the skill directory
- **Agent:** Read the agent `.md` file
- **Rule:** Read the rule `.md` file
- **Claude-config:** Read the `CLAUDE.md` file

### Step 2: Apply Classification Taxonomy

Scan all content against the taxonomy defined in the agent persona. For each file:

1. **Secrets scan** — Look for API key patterns (`sk-`, `xoxb-`, `ghp_`, `AKIA`), credential assignments, `.env` references with values, connection strings, base64 blobs in assignments
2. **PII scan** — Look for email addresses, phone numbers, internal usernames, Slack member IDs, names of people other than the repo owner
3. **Hardcoded path scan** — Look for `/Users/`, `~/`, absolute paths to specific machines
4. **Internal reference scan** — Look for internal URLs (*.internal, *.corp), Jira project keys, Slack channel references, Confluence links, proprietary product names used as if the reader would know them
5. **Personal context scan** — Look for role titles, team names, org structure, individual preferences, workflow specifics embedded in procedural content
6. **Domain knowledge scan** — Note product/framework/methodology references that assume familiarity

Record each finding with: category, severity, file path, line number or section, the flagged content, and a note about why it's flagged.

### Step 3: Separation of Concerns Check (Skills Only)

For skill artifacts, apply the key distinction test:

- Read each instruction step and ask: "Is this telling the agent *what to do* (procedure) or *who is doing it / why* (context)?"
- Procedural content is expected and clean
- Contextual content should be flagged under "Personal context" with a note that it could be externalized to CLAUDE.md

Common patterns to flag:
- Step instructions that reference specific team names or products by name
- Persona descriptions embedded in skill steps (should be in agent file or CLAUDE.md)
- Hardcoded file paths to personal vault locations
- References to specific people by name in workflow descriptions

### Step 4: Documentation Readiness Check

Check for:
- **README.md** — Does one exist at the project/artifact root? Note presence/absence.
- **CLAUDE.sample.md** — For project-level evaluations, does a sample config exist? Note presence/absence.
- **LICENSE** — Does one exist at the project root? Note presence/absence. Non-blocking but worth flagging.
- **.gitignore** — Does one exist? Does it exclude personal config (CLAUDE.md, settings.local.json) and created content?

### Step 4b: Sample File Drift Check

For every `*.sample.md` file found alongside a real config file (e.g., `CLAUDE.sample.md` next to `CLAUDE.md`, `jira-config.sample.md` next to `jira-config.md`):

1. Read both the real file and the sample
2. Compare the Configuration/config sections — identify fields present in the real file that are missing from the sample
3. Flag any drift as a REVIEW finding: "CLAUDE.md has config field `{field}` not represented in CLAUDE.sample.md"
4. Also flag the reverse: sample fields that no longer exist in the real file (stale placeholders)

This ensures consumers always see the complete configuration surface.

### Step 5: Produce Report

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

### Step 6: Generate CLAUDE.sample.md (if missing)

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

### Step 7: Write Status Marker

Write `.github-prep-status.json` to the evaluated path's root:

```json
{
  "evaluated_path": "{absolute path}",
  "evaluated_at": "{ISO 8601 timestamp}",
  "artifact_type": "{project | skill | agent | rule | claude-config}",
  "result": "{blocked | review-needed | clean}",
  "findings": {
    "blocks": 0,
    "reviews": 0,
    "flags": 0
  }
}
```

Use `Bash(date:*)` to get the current timestamp: `date -u +"%Y-%m-%dT%H:%M:%SZ"`

This marker is checked by `/github-push` as a gate. It should be gitignored.

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
