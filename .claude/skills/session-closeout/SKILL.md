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
5. Linear active count stays under the 250-ticket free-tier cap.

**Health Metrics:**
- Pre-flight discipline: substantive work pending = closeout pauses.
- Three-layer separation: item-level on issues; session-level on Project Updates; orientation (Re-entry Cue only) on CLAUDE.md. Nothing else writes to CLAUDE.md.
- Filing-time lint gate: zero HIGH findings before any new Knowledge page counts complete.
- Load-boundary-as-guard: PU review + hygiene review run as fresh subagents.

**Decision Authority:**
- **Autonomous:** type detection, per-type dispatch, mechanical verifications, current-context hygiene fixes, archive sweep.
- **Escalate via subagent:** ambiguous hygiene patterns, PU body review (both with cap 3).
- **Escalate to operator:** uncertain query-and-file candidates, out-of-scope doc modifications, subagent FAIL after cap.

**Stop Rules:**
- Pre-flight returns "pending" → halt; do the work; re-invoke.
- Empty session → one-line stop message; no mutations.
- Filing-time lint gate FAIL after 3 iterations → escalate.
- Out-of-session-scope doc modification → halt; flag.

## Pre-flight gate

Before classifying session type:

> Is there substantive work I have current session context for that should land BEFORE this closeout?

If **yes** → stop closeout, do the work, re-invoke. For durable-synthesis candidates: NAME them explicitly — a fully-formed synthesis feeds Step 7 query-and-file in this same run; a synthesis still needing work IS a "yes."

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

1. `/project-state read` for the project.
2. **[Inline]** Assess: what changed this session? What's the state now?
3. `/project-state write` with `re_entry_cue` (one sentence if work is mid-flight; "No work in progress" if clean) and `last_updated=today`.
4. `/linear update issues` with item-level mutations: `mark_done`, `comment`, `move_state`, `create`, `update_description` as appropriate. For `mark_done`: supply `validation_type` (choose from `red-team`, `functional`, `conformance`, `smoke` — match to the work done) and `evidence` (structured manifest: list of `{ref, kind, change}` entries — paths, commits, or artifacts with bare change-facts, no narrative). The playbook will spawn a non-author validator; Done is gated on its verdict. If the validator returns REFUTED, the ticket stays In Progress — fix the work and re-invoke, or file a follow-up.
5. `/linear write project-update` with structured body (title, items_worked, what_was_done, decisions_made, health). **This is where current state, waiting-for, and decisions-needed now live** — in the Project Update, not in CLAUDE.md.
6. **[Subagent]** `/linear review project-update` — fresh context, cap 3.
7. **[Inline]** Scope-change check: if the project scope expanded, update the `description` frontmatter in CLAUDE.md (via `update_frontmatter`) AND in Linear via `/linear update project`.
8. `/knowledge-layer hygiene` against touched docs. Ambiguous patterns → spawn `/knowledge-layer hygiene-review` subagents.
9. If session produced durable synthesis: `/knowledge-layer query-and-file`. Filing-time lint gate PASS required.
10. If pages created/renamed/deleted: `/knowledge-layer index-sync`.
11. If project under a hub with shared Knowledge: `/knowledge-layer hub-cross-ref`.
12. `/knowledge-layer scope-lint` with touched vault paths + created-file subset.
13. `/linear archive` with `dry_run=false`, defaults.
14. **[Inline]** Final verification:
   - **Re-entry Cue** is one sentence or absent. Re-invoke `/project-state write` to fix if violated.
   - **Project Update was created** this session (verify via `/linear read narrative` `limit=1`).
   - **Linear issues are immediately executable** — each touched issue in `Todo` or `In Progress` has a concrete next action or falsifiable acceptance criteria.

### Project (multi-project)

Pick a **primary** (most substantive work). Primary: full sequence. Each **incidental**: Steps 4 + abbreviated Step 5 only.

### Knowledge

Skip Steps 1, 4, 7, 11, 14. Run:

- **Step 3** (only if a host project is in scope) — update Re-entry Cue + `last_updated`.
- **Step 5** (only if a host project is in scope) — PU emphasizes what was filed/synthesized.
- **Step 6** — subagent review of any PU written.
- **Step 8** — full hygiene scan.
- **Step 9** — query-and-file (the knowledge flow's primary write surface).
- **Step 10** — index sync.
- **Step 12** — scope-lint.
- **Step 14** — verification scoped to knowledge layer.

### Mixed

Run Project flow, then knowledge Steps 8–12. Fold knowledge work into the project's Step 5 PU.

### Stewardship

For each touched page: bump frontmatter `updated`. No CLAUDE.md edit, no Linear write. Output: brief summary.

## Out-of-vault sessions

Work in `~/bin/dotty`, `~/.claude`, system config → project-shaped. Resolve the host project (almost always System) and run the Project flow.

## Discipline references

- **Three-layer memory** (item / session / re-entry): `[[linear-discipline]]` + `[[sustained-autonomous-agentic-workflows]]`.
- **State on pick-up reciprocal**: `claim` opens the loop (sets In Progress + confirms objective); `mark_done` at closeout closes it (validates + transitions to Done). Both live in `/linear update issues`.
- **Closure form**: `Canceled` (not `Duplicate`); duplication via `duplicate_of` relation.
