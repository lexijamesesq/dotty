---
name: session-start
description: >
  Triggers when the user says "I'm working on [project]", "Let's work on [project]",
  "Starting a session on [project]", or similar session-start phrases. Also triggers
  on "session start" or "/session-start".
user_invokable: true
---

# Session Start (Orchestrator)

Load project context and prepare for a working session. Composes the three domain skills — `/project-state`, `/linear`, `/knowledge-layer` — and handles trigger routing inline.

## Intent

**Objective.** Every Claude session pays a context re-derivation tax — rediscovering where the project stands, what's stale, what's next, which decisions block progress. This orchestrator collapses that tax into one composition pass so the user is oriented in under a minute and can direct the session.

**Desired outcomes** (observable):
1. The user knows the Re-entry Cue and the focal item before being asked any clarifying question.
2. The active queue + Waiting/Blocked items are re-evaluated (not just listed) by the time the orchestration completes.
3. Stale-debt past per-priority thresholds is visible LAST in the output, so it's the most recent thing the user reads before directing.
4. For intent-driven invocations, only load-bearing layers are loaded; skipped layers are NAMED explicitly, not silently omitted.

**Health metrics — must NOT degrade.**
- Three-layer memory discipline: CLAUDE.md / Linear issues / Linear Project Updates each loaded only when load-bearing for the intent. Don't collapse layers.
- Silence-is-success for stale-debt: omit empty blocks; do not state "0 stale" or "backlog clean."
- Re-evaluation discipline for Waiting/Blocked at every session-start (has the resolver moved? trigger fired?).

**Strategic context.** Harness-side implementation of the session-bootstrap pattern from `[[sustained-autonomous-agentic-workflows]]`. Read interface to the three-layer memory architecture. Sits at the head of every working session across the operator's project portfolio.

**Constraints.**
- **Hard:** Inviolable floor — CLAUDE.md always loaded, issue-ID always fetches issue + blockers. Cannot be skipped regardless of intent.
- **Steering:** Intent-Driven Sequence skip judgment is heuristic, not lookup — reason about which steps are load-bearing for declared intent rather than mechanically apply a table.

**Decision authority.**
- **Autonomous:** which Universal Protocol steps to skip for intent-driven invocations; output composition + ordering; stale-debt threshold application; silence-vs-surface judgment for optional sections.
- **Escalate:** CLAUDE.md or focal issue cannot be found → ask user for clarification (don't guess). Capture-note processing → user confirmation required before filing items as issues.

**Stop rules.**
- CLAUDE.md not found at resolved path → halt + ask user.
- Focal issue identifier malformed (doesn't match `<TEAM>-<N>`) → halt + ask user.
- Project resolves to type `hub` when caller expected project → halt + ask which sub-project.

## Trigger handling

Inspect the argument:

- **No argument** (bare `/session-start`, "session start", "I'm working on [project-name]") → **Universal Protocol**.
- **Project name** matching a folder under `workspace_root` → **Universal Protocol** scoped to that project.
- **Anything else** — Linear issue identifier (`<TEAM>-N`), free-text describing intent — → **Intent-Driven Sequence**.

Both branches share an **inviolable floor**: load the project's `CLAUDE.md` for orientation and project boundary. The Universal Protocol then loads the full picture; the Intent-Driven Sequence trims by load-bearing relevance.

## Universal Protocol

### Step 1 — Read project state

Invoke `/project-state read` with input `"cwd"` or the project-name argument. Returns structured Project State (Re-entry Cue, Current State, Waiting For, Decisions Needed) + Intake (`linear_project_id`, optional `capture_note_path`, `knowledge_layer_declared`, `knowledge_index_path`).

If the project folder or CLAUDE.md cannot be found, tell the user and ask for clarification.

### Step 2 — Read recent narrative

Invoke `/linear read narrative` with `project_id` from Step 1, `limit=3`. Returns recent Project Updates. The most recent is typically the prior session's closeout.

### Step 3 — Read queue + stale-debt

Invoke `/linear read queue` with `project_id` from Step 1. Returns active issues.

Then invoke `/linear analyze stale-debt` with the queue from above and today's date. Returns the subset past per-priority thresholds. Stale-debt items are "should be moving but aren't" — acceptable outcomes: finish, archive, or kill.

### Step 4 — Knowledge freshness (conditional)

If `knowledge_layer_declared: true` from Step 1, invoke `/knowledge-layer freshness` with `knowledge_index_path` from Step 1.

If the project is a subproject under a hub with shared `Knowledge/`, ALSO invoke `/knowledge-layer freshness` against the hub's index path.

### Step 5 — Capture Note (conditional)

If `capture_note_path` from Step 1 is non-null:

1. Read the capture note file at the specified path.
2. Identify items relevant to this project.
3. Ask the user: "Found X items in capture note — want to file these as Linear issues?"
4. If confirmed:
   - Invoke `/linear update issues` with `action=create_followup` per item.
   - Remove processed items from the capture note.

<!--
TODO: Extract this inline conditional to `/project-intake` per the deferred follow-up ticket
when a second consumer emerges. Today: ~10 lines inline; single consumer.
-->

### Step 6 — Summarize for the user

Compose a brief orientation summary:

- **Current status** — synthesized from Re-entry Cue (Step 1), Current State (Step 1), and the most recent Linear Project Update (Step 2).
- **Top 2-3 pending items** — from the queue (Step 3) ordered by priority and Re-entry Cue alignment.
- **Blockers or decisions needed** — items in `Waiting`/`Blocked` Linear states (per `[[linear-discipline]]`, re-evaluate context on each: has the resolver moved? has the trigger fired? is the wait still warranted?), plus CLAUDE.md `Waiting For` / `Decisions Needed` sections.
- **Knowledge freshness** — if Step 4 returned stale docs, list them with `updated` dates so the user can decide whether to validate during this session or defer.
- **Stale-debt block** — if Step 3 returned items past per-priority thresholds, surface LAST so it's the most recent thing the user reads. Format:

  ```
  **Stale debt:**
  - <TEAM>-N (Urgent, 12d unupdated) — Brief title
  - <TEAM>-M (Normal, 47d unupdated) — Brief title
  Decide before this session ends: finish, archive, or kill.
  ```

If Step 3 returned no stale items, OMIT this block. Silence is the success signal.

- **Loaded-context boundary** — name which layers were loaded AND which were skipped. Don't silently omit; explicit boundary discipline. Example: `"Loaded: CLAUDE.md + <TEAM>-N + blockers. Skipped: queue, narrative, knowledge freshness (intent didn't reference them)."`
- **Orienting close** — end with a question or pointer that lets the user direct. Not a summary that resolves things — an open-ended close.

Keep the summary concise. Get the user oriented in under a minute.

## Intent-Driven Sequence

When the argument is a Linear issue ID, free text describing intent, or anything not matching a project name, treat it as a declared intent and reason about which Universal Protocol steps are load-bearing.

### Inviolable floor

1. Invoke `/project-state read` (always — orientation must exist).
2. If the argument is or contains a Linear issue identifier (`<TEAM>-N` format), invoke `/linear read issue` with `issue_id` + `include_blockers=true`. The issue is item-level memory and is the natural focal point.

### Project resolution

- **Issue ID argument** → fetch the issue (via the floor's step 2), derive the project from `issue.project.id`, invoke `/project-state read` against that project.
- **Free-text argument** → use cwd's project context. If ambiguous, ask which project before proceeding.

### Skip judgment — which Universal Protocol steps to RUN

This is judgment, not a lookup table. Reason about what the declared intent depends on:

- **Recent narrative (Step 2)** — RUN when intent references prior work ("fix yesterday's bug", "review last week"). SKIP when intent is forward-looking and self-contained.
- **Queue + stale-debt (Step 3)** — SKIP almost always. The user already knows what they want to work on.
- **Knowledge freshness (Step 4)** — RUN when intent is research-, brainstorm-, or knowledge-shaped. SKIP for issue-focused implementation work.
- **Capture Note (Step 5)** — SKIP; the user is already directed.

### Examples

- `/session-start <TEAM>-91` → floor + issue fetch only. Skip narrative/queue/stale-debt/knowledge.
- `/session-start brainstorm about voice notes` → floor + knowledge freshness scan (intent is knowledge-shaped). Skip queue/narrative/stale-debt.

### Respect the three-layer memory model

Per `[[linear-discipline]]` and `[[sustained-autonomous-agentic-workflows]]`:
- CLAUDE.md = orientation (always loaded via Step 1).
- Linear issues = item-level (loaded when issue ID given or intent points at an item).
- Linear Project Updates = session-level (loaded only when intent references session history).

Skip layers that aren't load-bearing for the intent — **don't collapse layers**.

### Output

Same shape as Universal Protocol's Step 6 summary, but scoped to what was loaded. Omit sections that weren't loaded — silence is the success signal.

## Execution model

Follows the global execution model rule (auto-loaded). See `~/bin/dotty/.claude/rules/execution-model.md` for orchestrator/subagent patterns.
