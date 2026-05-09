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
- **Intake** section: note the Linear project URL, team allocation, any workstream labels
- **Capture Note** reference (if present): note the path for Step 5

If the project folder or CLAUDE.md cannot be found, tell the user and ask for clarification.

For the expected Project State structure, see the project template (path configured in global CLAUDE.md > Configuration > `templates.project`).

### Step 2: Read recent session narrative from Linear

Per the 2026-05-09 cutover, narrative lives in Linear Project Updates (not progress.md).

1. From CLAUDE.md Intake section, get the Linear project URL/ID
2. Query the Linear project's recent updates via `mcp__linear-tactic__linear_getProjectUpdates` (limit 5; sort by createdAt descending)
3. Read the most recent 1-3 updates for re-entry context — the latest is usually the prior session's closeout

**Fallback for older context:** if the recent Linear updates don't carry enough context (e.g., project just migrated, only the migration handoff exists), check for a `progress-archive.md` in the project directory and read its tail (~30 lines). Don't read the full archive; older entries are usually irrelevant.

If the project hasn't migrated yet (no Linear URL in CLAUDE.md Intake), fall back to reading `progress.md` tail from the project directory.

### Step 3: Read the active issue list from Linear

Query the Linear project for currently-actionable work via `mcp__linear-tactic__linear_getProjectIssues` (or equivalent). Focus on:

- Issues in `Todo` and `In Progress` states (and `Waiting`/`Blocked` if context-relevant)
- Skip `Done` and `Canceled` states
- Note priority distribution (High/Normal/Low)
- Identify the natural next-actionable item based on priority + the Next Actions list in CLAUDE.md

**Staleness visibility:** Linear's per-project saved view (typically named "Stale debt" or similar) surfaces overdue items. The session-start skill does NOT compute staleness in-skill — point the user at the saved view if relevant. If the project lacks a stale-debt view, that's a one-time setup task, not a session-start concern.

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
3. Ask the user: "Found X items in capture note — want to file these as Linear issues?"
4. If confirmed:
   - File items as Linear issues in the project via `linear_createIssue`
   - Remove processed items from the capture note
5. If declined, proceed without processing them

For details on the Capture System, see the protocols reference (path configured in global CLAUDE.md > Configuration > `references.protocols`).

### Step 6: Summarize Context for the User

Present a brief summary covering:

- **Current status** — synthesized from Re-entry Cue, Current State, and the most recent Linear Project Update (Step 2)
- **Top 2-3 pending items** — from the Linear active-issue list (Step 3) ordered by priority and CLAUDE.md Next Actions alignment
- **Blockers or decisions needed** — items in `Waiting`/`Blocked` Linear states, plus CLAUDE.md "Waiting For" / "Decisions Needed" sections
- **Knowledge freshness** (if Step 4 found stale docs) — list the stale candidates with their `updated` dates so the user can decide whether to validate them during this session or defer

Keep the summary concise. The goal is to get the user oriented in under a minute so they can direct the session.

**Don't** compute or surface a stale-debt nag in the skill output. Linear's UI saved view is the visibility mechanism — point the user there if they want it.

---

## Pre-cutoff projects (transitional)

For projects that haven't migrated yet, fall back to:
- **Step 2:** read `progress.md` tail (~30 lines)
- **Step 3:** read `backlog.json`, focus on pending/in-progress items
- **Step 6:** same shape, just sourced from local files

This fallback exists because the migration is per-project; some may lag. The trigger for choosing the fallback is whether CLAUDE.md Intake declares a Linear project URL or a backlog.json location.

---

## Execution Model

Follows the global execution model in `~/.claude/rules/execution-model.md` (auto-loaded every session). See that file for the orchestrator/subagent pattern and task decomposition guidance.
