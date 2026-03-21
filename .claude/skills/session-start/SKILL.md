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

Find the project folder under `~/Vaults/Notes/Claude/`. Read its `CLAUDE.md` file, focusing on:

- **Project State** section:
  - Re-entry Cue (what was in progress last session)
  - Current State (component status)
  - Next Actions or pending work
  - Waiting For (external blockers)
  - Decisions Needed (questions blocking progress)
- **Intake** section (if present): note the backlog method and location
- **Capture Note** reference (if present): note the path for Step 4

If the project folder or CLAUDE.md cannot be found, tell the user and ask for clarification.

For the expected Project State structure, see `~/Vaults/Notes/Claude/System/project-claude-template.md`.

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

### Step 4: Check for Capture Note (optional)

If the CLAUDE.md contains a `**Capture Note:**` reference:

1. Read the capture note file at the specified path
2. Identify items relevant to this project
3. Ask the user: "Found X items in capture note — want to process these into the backlog?"
4. If confirmed:
   - Migrate items to the project's backlog or Next Actions
   - Remove processed items from the capture note
5. If declined, proceed without processing them

For details on the ADHD Capture System, see `~/Vaults/Notes/Claude/System/protocols-reference.md`.

### Step 5: Summarize Context for the User

Present a brief summary covering:

- **Current status** — synthesized from Re-entry Cue and Current State (what was happening, where things stand)
- **Top 2-3 pending items** — from the backlog or Next Actions, in priority order
- **Blockers or decisions needed** — anything that requires human input or is waiting on external dependencies

Keep the summary concise. The goal is to get the user oriented in under a minute so they can direct the session.

---

## Execution Model

Follows the global execution model in `~/.claude/rules/execution-model.md` (auto-loaded every session). See that file for the orchestrator/subagent pattern and task decomposition guidance.
