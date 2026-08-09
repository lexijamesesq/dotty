---
name: session-closeout
description: >
  Triggers when the user says "Close out this session for [project]", "Session closeout",
  "Close this session", or similar closeout phrases. Also triggers on "/session-closeout".
---

# Session Closeout (Orchestrator)

Preserve project state and knowledge artifacts for future session resumption. Composes the three domain skills — `/project-state`, `/linear`, `/knowledge-layer` — and adapts to what the session actually did.

## Intent

**Objective.** State preservation for resumption WITHOUT becoming substantive work.

**Desired outcomes** (observable):
1. Re-entry Cue is one sentence (or absent if nothing is mid-flight) — a future session can act on it immediately.
2. Every Linear issue touched this session reflects reality.
3. A Linear Project Update exists capturing session-level narrative (current state, waiting-for, decisions made — this is where that information lives now).
4. Knowledge docs touched are free of the seven anti-patterns OR have follow-up Linear issues filed.

**Health Metrics:**
- Pre-flight discipline: substantive work pending = closeout pauses.
- Three-layer separation: item-level on issues; session-level on Project Updates; orientation (Re-entry Cue only) on CLAUDE.md. Nothing else writes to CLAUDE.md.
- Filing-time lint gate: zero HIGH findings before any new Knowledge page counts complete.
- Load-boundary-as-guard: PU review + hygiene review run as fresh subagents.

**Decision Authority:**
- **Autonomous:** type detection, per-type dispatch, mechanical verifications, current-context hygiene fixes.
- **Escalate via subagent:** ambiguous hygiene patterns (cap 3), PU body review (single pass).
- **Escalate to operator:** uncertain query-and-file candidates, out-of-scope doc modifications, subagent FAIL after cap.

**Stop Rules:**
- Pre-flight returns "pending" → halt; do the work; re-invoke.
- Empty session → one-line stop message; no mutations.
- Filing-time lint gate FAIL after 3 iterations → escalate.
- Out-of-session-scope doc modification → halt; flag.

## Pre-flight gate

Before classifying session type:

> Is there substantive work I have current session context for that should land BEFORE this closeout?

If **yes** → stop closeout, do the work, re-invoke. For durable-synthesis candidates: NAME them explicitly — a fully-formed synthesis feeds Track B's query-and-file in this same run; a synthesis still needing work IS a "yes."

If **no** → proceed to type detection.

## Trigger handling

- **No argument** → run Session Type Detection.
- **Argument override** (`project`, `knowledge`, `mixed`, `empty`) → skip detection.

## Session Type Detection

Classify by what the session actually produced.

### Signals

- **File mutations:** project folders → project work; `Knowledge/`/`Wiki/` paths → knowledge work; `~/bin/dotty`/`~/.claude`/system config → out-of-vault project work (maps to System); vault notes outside projects → stewardship.
- **MCP/API surface:** `linear_*` writes → project; `obsidian` Knowledge writes → knowledge.
- **Substantive vs. incidental:** a single edit alongside a long knowledge arc is mixed-with-knowledge-primary.

### Types

- **Project** — Linear-tracked work and/or project artifacts.
- **Knowledge** — knowledge-layer pages, methodology synthesis, research filings.
- **Mixed** — both. Project flow first, then knowledge.
- **Empty** — conversation/exploration with no mutations.
- **Stewardship** — vault notes outside any project.

## Per-Type Dispatch

### Empty

Output: `"Session was conversation-only. Nothing to record."` Stop.

### Project (single)

#### Resolve inputs (once, during assessment)

1. `/project-state read` for the project.
2. **[Inline]** Assess what changed this session. Compute these values once and carry them forward — do not re-derive them in later steps:
   - `what_changed` — assessment text
   - `touched_docs[]` — knowledge/reference docs modified this session
   - `touched_paths[]` — all vault paths touched
   - `session_topics[]` — topics the session's findings touched (for hub-cross-ref)
   - `has_synthesis` — did the session produce durable synthesis?
   - `scope_expanded` — did the project scope expand?

#### Track A — Linear + project state

Run these in order. Batch A2's writes in the same turn — they target disjoint systems.

- **A1.** `/project-state write` with `re_entry_cue` (one sentence if work is mid-flight; "No work in progress" if clean) and `last_updated=today`.
- **A2.** Batch together:
  - **Issue updates** via direct MCP calls — `mcp__linear-tactic__linear_updateIssue`, `linear_createComment`, `linear_createIssue` as appropriate — with item-level mutations: `cancel`, `comment`, `move_state`, `create`, `update_description` — `cancel` (reason required) for work that won't be done; canceling a map child for scope reasons pairs it with the map's Out of scope line, invalidation cancels carry the reason only, and surface when unsure. Never `resolve`: for HITL map children that verb belongs to the map session's live exchange, and a `research` child closes only through its researcher's own completion — so an open map child that looks finished at closeout is surfaced for the next map session, not closed here. For a ticket ready to close, invoke `` `@traffic-cone` `` `mark_done`: supply `validation_type` (choose from `red-team`, `functional`, `conformance`, `smoke` — match to the work done) and `evidence`. Read the ticket's dated progress comments first (`linear_getComments`) and derive the `evidence` manifest's `{ref, kind, change}` entries from that accumulated record — add fresh entries only for changes genuinely uncaptured there. `` `@traffic-cone` `` spawns the non-author validator and gates Done on its verdict. If the validator returns REFUTED, the ticket stays In Progress — fix the work and re-invoke, or file a follow-up.
  - **Scope-change check** (if `scope_expanded`): update the `description` frontmatter in CLAUDE.md (via `update_frontmatter`) AND in Linear via `mcp__linear-tactic__linear_updateProject`.
- **A3.** Create a Project Update via `mcp__linear-tactic__linear_createProjectUpdate` with structured body (title, items_worked, what_was_done, decisions_made, health). **This is where current state, waiting-for, and decisions-needed now live** — in the Project Update, not in CLAUDE.md.
- **A4.** **[Background subagent — do not wait]** Spawn `@attack-kitty` with `pu-review` mandate (model override **sonnet**). Pass the PU body verbatim; declare `Caller: L0 orchestrator`. Single pass. Proceed immediately to Track B.

#### Track B — Knowledge layer

No dependency on Track A. Begin as soon as assessment (step 2) is complete. Skip B1–B4 if `touched_docs` is empty and `has_synthesis` is false; B5 (scope-lint) still runs when `touched_paths` is non-empty.

- **B1.** `/knowledge-layer hygiene` against `touched_docs`. Ambiguous patterns → spawn `/knowledge-layer hygiene-review` subagents.
- **B2.** If `has_synthesis`: `/knowledge-layer query-and-file`. Filing-time lint gate PASS required. If not, skip — do not load the playbook.
- **B3.** If pages created/renamed/deleted (including by B2): `/knowledge-layer index-sync`.
- **B4.** If project under a hub with shared Knowledge: `/knowledge-layer hub-cross-ref` with session topics.
- **B5.** `/knowledge-layer scope-lint` with `touched_paths` + created files from B2. Run AFTER B2 so `created_paths` includes anything just filed.

#### Join — final verification

If the A4 subagent notification has not arrived, wait for it here. Then:

- **Re-entry Cue** is one sentence or absent. Re-invoke `/project-state write` to fix if violated.
- **Project Update was created** this session (verify via `mcp__linear-tactic__linear_getProjectUpdates` with `limit=1`).
- **PU review verdict** received — fix cited findings if REVISE.
- **Linear issues are immediately executable** — each touched issue in `Todo` or `In Progress` has a concrete next action or falsifiable acceptance criteria.

### Project (multi-project)

Pick a **primary** (most substantive work). Primary: full sequence (both tracks). Each **incidental**: A2 issue updates + abbreviated A3 PU only.

### Knowledge

Skip Track A's issue updates and scope-change check. Run:

- **Resolve inputs** — `/project-state read` + assessment (only if a host project is in scope).
- **A3** (only if a host project is in scope) — PU emphasizes what was filed/synthesized.
- **A4** — subagent review of any PU written.
- **Track B (skip B4 hub-cross-ref)** — B1 hygiene, B2 query-and-file (the knowledge flow's primary write surface), B3 index sync, B5 scope-lint.
- **Join** — verification scoped to knowledge layer.

### Mixed

Run both tracks as in Project flow. Fold knowledge work into the A3 Project Update.

### Stewardship

For each touched page: bump frontmatter `updated`. No CLAUDE.md edit, no Linear write. Output: brief summary.

## Out-of-vault sessions

Work in `~/bin/dotty`, `~/.claude`, system config → project-shaped. Resolve the host project (almost always System) and run the Project flow.

## Discipline references

- **Three-layer memory** (item / session / re-entry): the `/linear` SKILL.md discipline rules + `[[sustained-autonomous-agentic-workflows]]`.
- **State on pick-up reciprocal**: `claim` opens the loop — the claim lives in the delegate field (the assignee field is the operator's hold), with variant discipline per ticket shape; `` `@traffic-cone` `` `mark_done` closes it through the non-author validation gate; decision-type map children close through `` `@traffic-cone` `` `resolve` — the researcher's own completion for research, the map session's live exchange for HITL types, never closeout's verb; work that won't be done through `cancel`. All per `/linear`'s and `` `@traffic-cone` ``'s Navigation.
- **Closure form**: `Canceled` (not `Duplicate`); duplication via `duplicate_of` relation.
