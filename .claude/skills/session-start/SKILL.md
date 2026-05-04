---
name: session-start
description: >
  Triggers when the user says "I'm working on [project]", "Let's work on [project]",
  "Starting a session on [project]", or similar session-start phrases. Also triggers
  on "session start" or "/session-start".
user_invokable: true
---

# Session Start Protocol

Load project context and prepare for a working session. This is a universal protocol — it adapts to whatever project structure it finds.

## Instructions

When this skill triggers, extract the **project name** from the user's message and execute the following steps.

### Step 1: Locate and Read the Project CLAUDE.md

Find the project folder under the workspace root (path configured in global CLAUDE.md > Configuration > `workspace_root`). Read its `CLAUDE.md` file, focusing on:

- **Project State** section:
  - Re-entry Cue (what was in progress last session)
  - Current State (component status)
  - Next Actions or pending work
  - Waiting For (external blockers)
  - Decisions Needed (questions blocking progress)
- **Intake** section (if present): note the backlog method and location
- **Capture Note** reference (if present): note the path for Step 4

If the project folder or CLAUDE.md cannot be found, tell the user and ask for clarification.

For the expected Project State structure, see the project template (path configured in global CLAUDE.md > Configuration > `templates.project`).

### Step 2: Read the Progress Log (if one exists)

Look for a progress log file in the project directory (typically named `*-progress.md`).

- Read only the **last ~30 lines** of the file to get the most recent entry
- Do NOT read the full log — older entries are irrelevant for session start
- Only read more if the Re-entry Cue from Step 1 is unclear or missing

### Step 3: Read the Active Backlog (if one exists)

If the project's Intake section specifies a backlog file (typically `*-backlog.json`):

- Read the backlog file
- Focus on **pending** and **in-progress** items only
- Skip completed items — if there are many, note the count but do not enumerate them
- Identify the next actionable item based on priority and dependencies

**Staleness check:** invoke `/lint-backlog --quiet --top 3` on the same project. The skill returns either nothing (no stale items — silent pass) or a short list of items past their staleness threshold. Capture the output for Step 6. If the backlog has no `lint` block, `--quiet` mode skips silently — do not surface a setup hint at session start.

If any of the returned stale items has `overdue` ≥ 2× its threshold, mark the result as **escalated** for use in Step 6 framing.

### Step 4: Knowledge Freshness Scan (if applicable)

If the project has a Knowledge layer (declared in CLAUDE.md Intake `### Knowledge`, or a `Knowledge/` folder exists, or the project root IS the Knowledge layer per a flat variation):

1. Read `Knowledge/index.md` (or root-level `index.md` for flat variants)
2. For each listed page, check its frontmatter `updated` date against the project's freshness threshold (default 90 days from today)
3. Note any stale candidates — include them in Step 6's summary, not as a blocker
4. Check for obvious orphans: pages listed in the index but missing from disk, or pages on disk in Knowledge/ but absent from the index

If the project is a subproject under a hub with shared Knowledge/: also check the hub's `Knowledge/index.md` for stale docs that this session's work might depend on.

This is lightweight — read one index file, check dates. Do not read full Knowledge page content at this step; the Reading posture handles that at point-of-use during the session.

### Step 5: Check for Capture Note (optional)

If the CLAUDE.md contains a `**Capture Note:**` reference:

1. Read the capture note file at the specified path
2. Identify items relevant to this project
3. Ask the user: "Found X items in capture note — want to process these into the backlog?"
4. If confirmed:
   - Migrate items to the project's backlog or Next Actions
   - Remove processed items from the capture note
5. If declined, proceed without processing them

For details on the Capture System, see the protocols reference (path configured in global CLAUDE.md > Configuration > `references.protocols`).

### Step 6: Summarize Context for the User

Present a brief summary covering:

- **Current status** — synthesized from Re-entry Cue and Current State (what was happening, where things stand)
- **Top 2-3 pending items** — from the backlog or Next Actions, in priority order
- **Blockers or decisions needed** — anything that requires human input or is waiting on external dependencies
- **Knowledge freshness** (if Step 4 found stale docs) — list the stale candidates with their `updated` dates so the user can decide whether to validate them during this session or defer

Keep the summary concise. The goal is to get the user oriented in under a minute so they can direct the session.

**Stale debt block (if Step 3 captured lint output):**

Place this as the LAST element of the summary, after Blockers — recency wins; the user reads this last and acts on it before doing other work. Format:

```
**Stale debt — {project name}:**
{Lead sentence per escalation tier below}
{Verbatim lint output: one bullet per item with id, status, title, overdue}
IDs link to backlog.json — open it if a title alone doesn't ring a bell.
```

Lead sentence by escalation tier:
- **Default:** "Stale — decide now: finish, archive, or kill before this session ends."
- **Escalated** (any item ≥ 2× threshold per Step 3): "Overdue by 2x+ — these are rotting. Kill or commit."

If Step 3 returned no lint output (silent pass), omit the entire block. Do not say "0 stale items" or "backlog clean" — silence is the success signal.

---

## Execution Model

Follows the global execution model in `~/.claude/rules/execution-model.md` (auto-loaded every session). See that file for the orchestrator/subagent pattern and task decomposition guidance.
