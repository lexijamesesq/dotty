---
name: session-start
description: >
  Triggers when the user says "I'm working on [project]", "Let's work on [project]",
  "Starting a session on [project]", or similar session-start phrases. Also triggers
  on "session start" or "/session-start".
user_invokable: true
---

# Session Start Protocol

Load project context and prepare for a working session.

## Trigger Handling

Inspect the argument passed to the skill:

- **No argument** (bare `/session-start`, "session start", "I'm working on [project-name]") → run the **Universal Protocol** below. Default behavior; full project orientation.
- **Argument is a project name** matching a folder under `workspace_root` → run the Universal Protocol scoped to that project. (Existing behavior.)
- **Argument is anything else** — an issue identifier (`<TEAM>-N`), a few words (`brainstorm voice notes`), a sentence describing what the user wants to do — → run the **Intent-Driven Sequence** below.

Both branches share an inviolable floor: load the project's `CLAUDE.md` for orientation and project boundary. The Universal Protocol then loads the full picture; the Intent-Driven Sequence trims based on what the declared intent actually depends on.

## Universal Protocol

### Step 1: Locate and Read the Project CLAUDE.md

Find the project folder under the workspace root (path configured in global CLAUDE.md > Configuration > `workspace_root`). Read its `CLAUDE.md` file, focusing on:

- **Project State** section:
  - Re-entry Cue (what was in progress last session, including any non-issue next-step)
  - Current State (component status)
  - Waiting For (external blockers)
  - Decisions Needed (questions blocking progress)
- **Intake** section: note the Linear project URL, team allocation, any workstream labels
- **Capture Note** reference (if present): note the path for Step 5

If the project folder or CLAUDE.md cannot be found, tell the user and ask for clarification.

For the expected Project State structure, see the project template (path configured in global CLAUDE.md > Configuration > `templates.project`).

### Step 2: Read recent session narrative from Linear

Per the 2026-05-09 cutover, narrative lives in Linear Project Updates (not progress.md).

1. From CLAUDE.md Intake section, read the `**Project ID:**` line (a UUID). If absent (legacy CLAUDE.md), fall back to `linear_getProjects` and match the project name from CLAUDE.md frontmatter or title; the URL slug is NOT a valid `projectId` argument.
2. Query the Linear project's recent updates via `mcp__linear-tactic__linear_getProjectUpdates` (limit 5; sort by createdAt descending)
3. Read the most recent 1-3 updates for re-entry context — the latest is usually the prior session's closeout

**Fallback for older context:** if the recent Linear updates don't carry enough context (e.g., project just migrated, only the migration handoff exists), check for a `progress-archive.md` in the project directory and read its tail (~30 lines). Don't read the full archive; older entries are usually irrelevant.

If the project hasn't migrated yet (no `**Project ID:**` or Linear URL in CLAUDE.md Intake), fall back to reading `progress.md` tail from the project directory.

### Step 3: Read the active issue list from Linear

Query the Linear project for currently-actionable work via `mcp__linear-tactic__linear_getProjectIssues` (or equivalent). Focus on:

- Issues in `Todo` and `In Progress` states (and `Waiting`/`Blocked` if context-relevant)
- Skip `Done` and `Canceled` states
- Note priority distribution (High/Normal/Low)
- Identify the natural next-actionable item from priority + the Re-entry Cue's pointer (the queue is here, not in CLAUDE.md)

**Stale-debt query.** After loading active issues, identify items past a per-priority freshness threshold based on `updatedAt`:

| Linear priority | Threshold (days unupdated) |
|---|---|
| Urgent (1) | 7 |
| High (2) | 14 |
| Normal (3) | 30 |
| Low (4) | 90 |
| No priority (0) | 60 |

This is a simple date-threshold filter on the issue list already loaded — no separate skill, no per-priority scoring algorithm. Capture stale items for Step 6's summary; surface them as the LAST element of the session-start output so they're the most recent thing the user reads before directing the session.

If no items are stale, omit the block entirely. Silence is the success signal — do not say "0 stale items" or "backlog clean."

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
- **Top 2-3 pending items** — from the Linear active-issue list (Step 3) ordered by priority and Re-entry Cue alignment
- **Blockers or decisions needed** — items in `Waiting`/`Blocked` Linear states, plus CLAUDE.md "Waiting For" / "Decisions Needed" sections
- **Knowledge freshness** (if Step 4 found stale docs) — list the stale candidates with their `updated` dates so the user can decide whether to validate them during this session or defer
- **Stale-debt block** (if Step 3 returned items past the per-priority threshold) — place this LAST. Format:

  ```
  **Stale debt:**
  - LEX-N (Urgent, 12d unupdated) — Brief title
  - LEX-M (Normal, 47d unupdated) — Brief title
  Decide before this session ends: finish, archive, or kill.
  ```

  If Step 3 returned no stale items, omit this block entirely. Silence is the success signal.

Keep the summary concise. The goal is to get the user oriented in under a minute so they can direct the session.

---

## Intent-Driven Sequence

When the user provides an argument that isn't a project name, treat it as a declared intent and reason about which steps of the Universal Protocol are load-bearing for that intent. This is judgment, not a lookup table.

### Inviolable floor

Regardless of intent:

1. Load the project's `CLAUDE.md` (orientation, project boundary, current state).
2. If the argument is or contains a Linear issue identifier (`TEAM-NNN` format), fetch that issue and any items in its blocked-by/blocking relationships. The issue is item-level memory and is the natural focal point.

### Resolving the project

- **Issue ID argument** → fetch the issue, derive the project from the issue's `project.id`, then load that project's `CLAUDE.md`.
- **Free-text argument** → use the current working context (cwd's `CLAUDE.md` or already-loaded project). If ambiguous, ask which project before proceeding.

### What to skip vs. keep

The Universal Protocol's other steps (recent Project Updates, full active-issue queue, stale-debt scan, Knowledge freshness, capture note) exist to surface context the user might not know they need. With declared intent, most of that context is unrelated. Reason about what the user is asking for and what they'd need to be effective:

- **Recent Project Updates** — keep when the intent references prior work ("fix yesterday's bug", "review last week"). Skip when the intent is forward-looking and self-contained.
- **Full active-issue queue and stale-debt scan** — skip almost always. The user already knows what they want to work on.
- **Knowledge freshness scan** — keep when the intent is research-, brainstorm-, or knowledge-shaped. Skip for issue-focused implementation work.
- **Capture note** — skip; the user is already directed.

### Respect the three-layer memory model

(2026-05-09 cutover, see `protocols-reference.md` `## Operational Gotchas`.) The reduced sequence still honors:

- **CLAUDE.md** = orientation (always loaded).
- **Linear issues** = item-level (loaded when an issue ID is given or when intent points at a specific item).
- **Linear Project Updates** = session-level (loaded only when intent references session history).

Skip layers that aren't load-bearing for the intent — don't collapse layers.

### Examples (illustrative — not a lookup)

- `/session-start <TEAM>-N` → Load project CLAUDE.md (derived from issue's project). Fetch <TEAM>-N + blockers. Skip Project Updates, queue, stale-debt, Knowledge scan.
- `/session-start brainstorm about voice notes` → Load CLAUDE.md. Search Knowledge layer for voice-note-related docs (intent is knowledge-shaped). Skip queue, stale-debt, Project Updates.
- `/session-start review what we did last week` → Load CLAUDE.md. Fetch ~7 days of Project Updates. Skip queue, Knowledge scan, stale-debt.
- `/session-start fix the bug from yesterday's session` → Load CLAUDE.md. Fetch most recent Project Update. Identify the referenced issue; fetch it. Skip queue, stale-debt.

### Output

Same shape as the Universal Protocol summary but scoped: brief orientation, the focal item or context that was loaded, and what's needed to start work. Omit sections that weren't loaded — silence is the success signal.

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
