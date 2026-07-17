---
name: session-start
description: >
  Triggers when the user says "I'm working on [project]", "Let's work on [project]",
  "Starting a session on [project]", or similar session-start phrases. Also triggers
  on "session start" or "/session-start".
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

**Health Metrics:**
- Three-layer memory discipline: CLAUDE.md / Linear issues / Linear Project Updates each loaded only when load-bearing for the intent.
- Silence-is-success for stale-debt: omit empty blocks.
- Re-evaluation discipline for Waiting/Blocked at every session-start.

**Decision Authority:**
- **Autonomous:** which steps to skip for intent-driven invocations; output composition + ordering; stale-debt threshold application; silence-vs-surface judgment.
- **Escalate:** CLAUDE.md or focal issue cannot be found → ask user.

**Stop Rules:**
- CLAUDE.md not found → halt + ask user.
- Focal issue identifier malformed → halt + ask user.
- Project resolves to hub → halt + ask which sub-project.

## Trigger handling

Inspect the argument:

- **No argument** → **Universal Protocol**.
- **Project name** matching a folder under `workspace_root` → **Universal Protocol** scoped to that project.
- **Anything else** (Linear issue ID, free-text intent) → **Intent-Driven Sequence**.

Both branches share an **inviolable floor**: the project's `CLAUDE.md` is already loaded as system context. The Universal Protocol builds the full briefing from Linear; the Intent-Driven Sequence trims by load-bearing relevance.

## Universal Protocol

### Step 1 — Read project orientation

Invoke `/project-state read` with input `"cwd"` or the project-name argument. Returns: `re_entry_cue`, `description`, `status`, `linear_project_id`, `linear_project_url`, `knowledge_layer_declared`, `knowledge_index_path`.

Note: CLAUDE.md is already loaded as system context before this skill runs. `/project-state read` parses the frontmatter and Re-entry Cue into structured fields — it doesn't re-load what's already in context.

If the project folder or CLAUDE.md cannot be found, tell the user and ask for clarification.

### Step 2 — Read recent narrative

Invoke `/linear read narrative` with `project_id` from Step 1, `limit=3`. Returns recent Project Updates. The most recent is typically the prior session's closeout — this is where current state, waiting-for, and decisions-needed now live.

### Step 3 — Read queue + stale-debt

Invoke `/linear read queue` with `project_id` from Step 1. Returns active issues.

Then invoke `/linear analyze stale-debt` with the queue and today's date. Returns the subset past per-priority thresholds.

### Step 4 — Knowledge freshness (conditional)

If `knowledge_layer_declared: true` from Step 1, invoke `/knowledge-layer freshness` with `knowledge_index_path` from Step 1.

If the project is a subproject under a hub with shared `Knowledge/`, ALSO invoke `/knowledge-layer freshness` against the hub's index path.

### Step 5 — Summarize for the user

Compose a brief orientation summary:

- **Re-entry Cue** — from Step 1, if work is mid-flight. If null or "No work in progress," say so briefly and move on.
- **Current status** — synthesized from the most recent Linear Project Update (Step 2). This is the session-level narrative; it replaces what was previously read from CLAUDE.md's Current State section.
- **Top 2-3 pending items** — from the queue (Step 3) ordered by priority and Re-entry Cue alignment.
- **Blockers or decisions needed** — items in `Waiting`/`Blocked` Linear states (per `[[linear-discipline]]`, re-evaluate context on each: has the resolver moved? has the trigger fired?).
- **Knowledge freshness** — if Step 4 returned stale docs, list them with `updated` dates.
- **Stale-debt block** — if Step 3 returned items past thresholds, surface LAST:

  ```
  **Stale debt:**
  - <TEAM>-N (Urgent, 12d unupdated) — Brief title
  Decide before this session ends: finish, archive, or kill.
  ```

  If no stale items, OMIT this block. Silence is the success signal.

- **Loaded-context boundary** — name which layers were loaded AND which were skipped.

Keep the summary concise. Get the user oriented in under a minute.

## Intent-Driven Sequence

When the argument is a Linear issue ID, free text describing intent, or anything not matching a project name.

### Inviolable floor

1. Invoke `/project-state read` (always — structured fields needed even though CLAUDE.md is in system context).
2. If the argument contains a Linear issue identifier (`<TEAM>-N`), invoke `/linear read issue` with `issue_id` + `include_blockers=true`.

### Project resolution

- **Issue ID argument** → fetch the issue, derive the project from `issue.project.id`, invoke `/project-state read` against that project.
- **Free-text argument** → use cwd's project context. If ambiguous, ask.

### Skip judgment

Reason about what the declared intent depends on:

- **Recent narrative (Step 2)** — RUN when intent references prior work. SKIP when forward-looking.
- **Queue + stale-debt (Step 3)** — SKIP almost always.
- **Knowledge freshness (Step 4)** — RUN when knowledge-shaped. SKIP for implementation work.

### Output

Same shape as Universal Protocol's Step 5 summary, scoped to what was loaded. Omit sections that weren't loaded.
