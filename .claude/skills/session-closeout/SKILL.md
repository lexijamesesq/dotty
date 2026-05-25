---
name: session-closeout
description: >
  Triggers when the user says "Close out this session for [project]", "Session closeout",
  "Close this session", or similar closeout phrases. Also triggers on "/session-closeout".
user_invokable: true
---

# Session Closeout (Orchestrator)

Preserve project state and knowledge artifacts for future session resumption. Composes the three domain skills — `/project-state`, `/linear`, `/knowledge-layer` — and adapts to what the session actually did.

## Intent

**Objective.** State preservation for resumption WITHOUT becoming substantive work. Without this orchestrator, state rots across sessions: Re-entry Cues stale, Linear issues drift from reality, Project Updates devolve into progress-log sprawl, Knowledge docs accumulate appendix syndrome, and the Linear free-tier cap surprises as a crisis.

**Desired outcomes** (observable):
1. Re-entry Cue is a one-sentence orientation a future session can act on immediately.
2. Every Linear issue touched this session reflects reality (state correct; non-obvious resolution captured in closing comment; in-progress substantive work captured in progress comment; scope changes captured in description).
3. A Linear Project Update exists capturing session-level narrative at project-granularity (not task-granularity).
4. Knowledge docs touched are free of the seven anti-patterns OR have follow-up Linear issues filed for out-of-scope cleanup.
5. Linear active count stays comfortably under the 250-ticket free-tier cap (archive sweep runs as the final closeout step).

**Health metrics — must NOT degrade.**
- Pre-flight discipline: substantive work pending = closeout pauses, never proceeds-anyway.
- Three-layer separation on every write: no item-level narrative bleeds into Project Updates; no "What's next" forward planning bleeds into Project Updates; no Recent Changes / dated changelog content bleeds into CLAUDE.md.
- Filing-validator gate: zero HIGH violations required before any new Knowledge page counts complete.
- Load-boundary-as-guard: PU body review (`/linear review project-update`) + ambiguous-pattern hygiene review (`/knowledge-layer hygiene-review`) run as fresh subagents, never inline self-review.

**Strategic context.** Write interface to the three-layer memory architecture from `[[sustained-autonomous-agentic-workflows]]`. Enforces the discipline `[[linear-discipline]]` codifies on every write surface. Mirror of `/session-start` — they bracket every working session and together preserve the resumption contract that makes multi-session work cheap.

**Constraints.**
- **Hard:** Pre-flight gate (substantive work pending → pause). Filing-validator subagent must PASS before any new Knowledge page counts complete. Type detection drives dispatch (per-type sequences are fixed). Pre-cutoff fallbacks retired — missing Project ID is a data error, not a fallback trigger.
- **Steering:** Step 8 hygiene classification (current-context-fix vs. defer-to-Linear-issue) by current-context-availability, NOT by line count.

**Decision authority.**
- **Autonomous:** type detection and per-type dispatch; mechanical Step 13 verifications; current-context hygiene fixes within session scope; defer-to-Linear-issue filing for out-of-scope items; archive sweep (closeout invocation has dry-run=false by deliberate choice).
- **Escalate via subagent:** ambiguous hygiene-pattern matches → spawn `/knowledge-layer hygiene-review` (fresh context); PU body review findings → spawn `/linear review project-update` (fresh context); both with iteration cap 3.
- **Escalate to operator:** uncertain query-and-file candidates → surface in closeout summary; out-of-session-scope project docs needing modification → flag, don't modify; subagent FAIL after iteration cap.

**Stop rules.**
- Pre-flight returns "pending" → halt; do the substantive work; re-invoke.
- Empty session type → output one-line stop message; no mutations.
- filing-validator FAIL after 3 iterations → escalate to operator (page exists on disk but is not counted complete; orchestrator does not silently accept).
- PU review or hygiene-review subagent FAIL after 3 iterations → escalate to operator with full finding list.
- Out-of-session-scope project doc modification attempted → halt; flag to operator.

## Pre-flight gate (strong prose convention)

Before classifying session type, ask honestly:

> Is there substantive work I have current session context for that should land BEFORE this closeout? E.g., docs that describe systems I just changed, code refactors I deferred, follow-ons to today's commits, knowledge syntheses still in chat.

If **yes** → stop closeout, do the work, then re-invoke. The cost of doing it now (context fresh) is much lower than the cost of deferring (future-you must re-load context to act on a Linear issue, or the work decays in backlog).

If **no** → proceed to type detection.

**Honest framing:** this gate is a strong prose convention, not a structural load-boundary guard (the methodology reserves "structural" for file-level load boundaries that the model cannot bypass). The model is asked to ask itself the question. Convention is reinforced by: (a) the cost framing (doing it now is cheaper), (b) the downstream catches (Step 8 hygiene + Step 13 verification surface escapes), and (c) operator-visibility — closeouts that should have paused but didn't are auditable in the resulting Project Update.

## Trigger handling

- **No argument** → run Session Type Detection.
- **Argument override** (`project`, `knowledge`, `mixed`, `empty`) → skip detection; run per-type flow with declared type.

## Session Type Detection

Classify by what the session actually produced. Cannot rely on whether `/session-start` fired — many sessions begin ad-hoc.

### Signals

- **File mutations:**
  - Project folders (under `workspace_root`) → project work.
  - `Knowledge/` subfolders, `Wiki/` paths, `index.md` files → knowledge work.
  - `~/bin/dotty`, `~/.claude`, `~/bin/dotty-private`, system config → out-of-vault project work (maps to System Linear project).
  - Vault notes outside any project (raw notes, Personal/, Work/) → **stewardship**.
- **MCP/API surface:** `linear_*` writes → project work; `obsidian` reads/writes against Knowledge content → knowledge work; long research arcs (WebSearch/WebFetch with notes filed) → knowledge work.
- **CLAUDE.md files loaded:** which projects came into scope.
- **Substantive vs. incidental:** a single edit alongside a long knowledge research arc is mixed-with-knowledge-primary, not project work.

### Types

- **Project** — primary deliverables are Linear-tracked work and/or project artifacts.
- **Knowledge** — primary deliverables are knowledge-layer pages, methodology synthesis, or research filings. Linear involvement minimal or none.
- **Mixed** — both. Run project flow first (Re-entry Cue stays accurate), then knowledge.
- **Empty** — conversation/exploration that didn't produce mutations.
- **Stewardship** — vault notes outside any project (Personal/, Work/, raw notes).

### Projects in scope

List which projects this session actually touched. One project = single-project flow. Two or more = multi-project flow.

## Per-Type Dispatch

### Empty

Output one line: `"Session was conversation-only. Nothing to record."` Stop.

### Project (single)

Sequence:

1. `/project-state read` for the project.
2. **[Inline]** Assess: what's operational/broken/in-progress? What changed this session that affects project status? Any decisions made that should be recorded?
3. `/project-state write` with `re_entry_cue`, `last_updated=today`, optionally `current_state`, `waiting_for`, `decisions_needed`. Surface any structured WARNINGs.
4. `/linear update issues` with item-level mutations: `mark_done` for completed issues (with closing comment if resolution non-obvious), `comment` for in-progress substantive work, `move_state` to `Waiting`/`Blocked` with resolver-context comment, `create_followup` for follow-ups discovered, `update_description` for materially-changed open issues.
5. `/linear write project-update` with structured body (title, items_worked, what_was_done bullets, decisions_made bullets, health). The write playbook rejects pre-write if three-layer separation is violated.
6. **[Subagent]** After write, spawn a fresh subagent invocation of `/linear review project-update` (loads `project-updates-review.md`) given only the written PU + the rubric. Iteration cap 3. Apply suggested fixes if REVISE; escalate if FAIL.
7. **[Inline]** Scope-change check: did the project scope expand or change this session? If yes, update the project description in CLAUDE.md (re-invoke `/project-state write` with revised `current_state`) AND in Linear via `/linear update project` with the new description.
8. `/knowledge-layer hygiene` against touched docs. Apply current-context fixes. For ambiguous patterns, spawn `/knowledge-layer hygiene-review` subagents (one per ambiguous doc).
9. If session produced durable synthesis: `/knowledge-layer query-and-file` with the synthesis draft. Confirms filing-validator PASS before counting complete.
10. If pages created/renamed/deleted: `/knowledge-layer index-sync` against the affected Knowledge folder(s).
11. If project under a hub with shared Knowledge: `/knowledge-layer hub-cross-ref` with this session's topics + hub index. Act on findings per the relationship × action table.
12. `/linear archive` with `dry_run=false`, defaults (14d grace, both teams). Final closeout step — keeps the 250-ticket cap from becoming a crisis.
13. **[Inline]** Final verification (each checkable concretely):
   - **Re-entry Cue** is exactly one sentence (single `. ! ?` terminal). Re-invoke `/project-state write` to fix if violated.
   - **No "Recent Changes" / changelog-style section** in CLAUDE.md (no dated bullet entries in `current_state` paragraph).
   - **Project Update was created** this session (verify via `/linear read narrative` `limit=1` — most recent should match the PU just written).
   - **Linear issues are immediately executable** — for each issue in `Todo` or `In Progress` state the session touched, verify: (a) description names a concrete next action OR has falsifiable acceptance criteria, (b) is not blocked by an unresolved decision the description doesn't surface, (c) is in the right state given the work done. "Immediately executable" means a fresh session reading the issue can act without re-deriving context. Re-invoke `/linear update issues` for any issue failing this check (typically `comment` or `update_description` action).

### Project (multi-project)

Pick a **primary** (most substantive work, or the project the user is most likely to re-enter next; ask if ambiguous). For primary: full Project (single) sequence. For each **incidental**: Steps 4 + abbreviated Step 5 only (`/linear update issues` + a brief `/linear write project-update` referencing cross-project context). Skip 1, 2, 3, 7, 8, 9, 10, 11, 12, 13 for incidentals.

### Knowledge

Skip Steps 1, 4, 7, 11, 12. Run:

- **Step 3** (only if a host project is in scope) — update Re-entry Cue + `last_updated`. Skip Current State / Waiting For / Decisions Needed unless they actually changed.
- **Step 5** (only if a host project is in scope) — Project Update body emphasizes what was filed/synthesized, not Linear-issue advancement. Skip Step 5 entirely if no host project.
- **Step 6** — subagent review of any PU written.
- **Step 8** — full hygiene scan.
- **Step 9** — query-and-file with filing-validator gate (this is the knowledge flow's primary write surface).
- **Step 10** — index sync.
- **Step 13** — verification scoped to knowledge layer (index synced, frontmatter `updated` bumped, no orphaned new pages).

### Mixed

Run Project flow, then `/knowledge-layer hygiene` (Step 8) with extra emphasis. Don't write a separate Project Update for the knowledge work — fold into the project's Step 5 PU as a "Knowledge artifacts filed" line if relevant.

### Stewardship (vault notes outside any project)

For each touched page: bump frontmatter `updated`. No CLAUDE.md edit, no Linear write. Output: brief summary of what was touched, in case the user wants to file any as a project.

## Out-of-vault sessions

Work in `~/bin/dotty`, `~/.claude`, system config, or other tracked-but-non-vault locations is project-shaped. Resolve the host project (almost always System) and run the Project flow against it. The CLAUDE.md to update lives in the vault even if the work didn't.

## Discipline references

- **Three-layer memory** (item / session / re-entry, no overlap): `[[linear-discipline]]` + `[[sustained-autonomous-agentic-workflows]]`. The orchestrator's job is to route mutations to the right layer.
- **State on pick-up reciprocal**: `mark_done` at closeout closes the loop opened by `In Progress` at start of work.
- **Closure form** per `[[linear-discipline]]`: use `Canceled` (not `Duplicate`) when an issue won't be done; express duplication via `duplicate_of` relation.

## Execution model

Follows the global execution model rule (auto-loaded). Orchestrator/subagent pattern: subagent for any "review" operation (PU review, hygiene review) so the load boundary serves as the structural self-evaluation guard.
