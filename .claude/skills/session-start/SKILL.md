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
2. The active queue is loaded; Blocked items are re-evaluated (probed for resolution); Needs Input items are surfaced with what's needed.
3. The operator can direct the session within a minute of the summary.
4. For intent-driven invocations, only load-bearing layers are loaded; skipped layers are NAMED explicitly, not silently omitted.

**Health Metrics:**
- Three-layer memory discipline: CLAUDE.md / Linear issues / Linear Project Updates each loaded only when load-bearing for the intent.
- Re-evaluation discipline for Blocked tickets at every session-start (probe checkable conditions, auto-resolve to Todo when unblocked).
- Silence-is-success: omit empty sections (no Needs Input, no Blocked, no stale knowledge).

**Decision Authority:**
- **Autonomous:** which steps to skip for intent-driven invocations; output composition + ordering; silence-vs-surface judgment.
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

### Step 2 — Read recent narrative (conditional)

Check the Re-entry Cue from Step 1. If it is "No work in progress" (or null/absent), skip this step — there is no trail to pick up.

If work is in progress, invoke `/linear read narrative` with `project_id` from Step 1, `limit=3`. Returns recent Project Updates. The most recent is typically the prior session's closeout — this is where current state, waiting-for, and decisions-needed now live.

### Step 3 — Read queue + check blockers

Invoke `/linear read queue` with `project_id` from Step 1. Returns active issues.

**Needs Input tickets.** From the queue, identify any tickets in Needs Input state. Surface them in Step 5 with what the operator needs to provide (read the ticket description and comments to find the specific ask).

**Blocked ticket re-evaluation.** Fetch Blocked tickets for the project via `/linear read queue` with `state_filter: [Blocked]`. For each, read the ticket description and comments to find the checkable condition (the dependency or trigger that must resolve). Where the condition is mechanically checkable (a URL to poll, a version to check, a PR to look up, an API status), probe it. If resolved: move the ticket to Todo via `/linear update issues` with a comment noting what changed and when. If still blocked or the condition requires human judgment: leave it and surface it in Step 5. This runs in the background alongside the queue read — don't block orientation on it.

### Step 4 — Knowledge freshness (conditional)

If `knowledge_layer_declared: true` from Step 1, invoke `/knowledge-layer freshness` with `knowledge_index_path` from Step 1.

If the project is a subproject under a hub with shared `Knowledge/`, ALSO invoke `/knowledge-layer freshness` against the hub's index path.

### Step 5 — Summarize for the user

Compose a brief orientation summary:

- **Re-entry Cue** — from Step 1, if work is mid-flight. If null or "No work in progress," say so briefly and move on.
- **Current status** — synthesized from the most recent Linear Project Update (Step 2). This is the session-level narrative; it replaces what was previously read from CLAUDE.md's Current State section.
- **Top 2-3 pending items** — from the queue (Step 3) ordered by priority and Re-entry Cue alignment.
- **Needs Input** — items awaiting the operator, with what's needed (from Step 3). Omit if none.
- **Blocked re-evaluation** — from Step 3: which Blocked tickets were auto-resolved to Todo (and why), and which remain blocked. Omit if no Blocked tickets exist.
- **Knowledge freshness** — if Step 4 returned stale docs, list them with `updated` dates.
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
- **Queue + blockers (Step 3)** — SKIP almost always.
- **Knowledge freshness (Step 4)** — RUN when knowledge-shaped. SKIP for implementation work.

### Output

Same shape as Universal Protocol's Step 5 summary, scoped to what was loaded. Omit sections that weren't loaded.
