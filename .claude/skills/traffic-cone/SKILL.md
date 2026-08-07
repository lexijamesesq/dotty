---
name: traffic-cone
description: Lifecycle orchestrator — mark_done, resolve, close-map, work frontier. Sequences the gate, composes mandates for `@attack-kitty`, and delegates every raw Linear operation to `@linear`. Invoked by conductors, wayfinder map sessions, research resolvers, and frontier-pickup sessions at the point a ticket or map needs to move through its lifecycle.
---

# /traffic-cone

Domain expert for ticket and map lifecycle orchestration — the four verbs a mission record moves through on its way to Done: `mark_done`, `resolve`, `close-map`, `work frontier`. This skill carries the sequencing, the gates, and the mandate composition for `@attack-kitty`; it never executes a Linear mutation directly and never judges its own gate.

## Navigation

| Invocation | Input | Playbook |
|---|---|---|
| `mark_done` | `issue_id` + `validation_type` + `evidence` (+ `charter_doc_id` for `build` tickets) | `playbooks/closing.md` |
| `resolve` | `issue_id` — decision-type map children (research: the researcher itself at contract completion; grilling/prototype/task: HITL with the operator) | `playbooks/closing.md` |
| `close-map` | `map_id` (+ optional `consistency_lens` for system-of-text deliverables) | `playbooks/close-map.md` |
| `work frontier` | `project_id` OR `map_id` — picks, claims, and drives one ticket to Done | `playbooks/work-frontier.md` |

**Invocation convention:** callers use the exact `Invocation` string, same as `/linear`'s. A caller that invokes `/linear mark_done`, `/linear resolve`, or `/linear close-map` directly is routed here — `/linear` retains the mechanical execution these verbs call into, but no longer owns the sequencing.

## Reference

- `playbooks/mutation-record-spec.md` — how mission records may legally be mutated: mutate-in-place vs. append, current-truth vs. evolution mode, foundation-record authorization, the marking scheme. Load before any orchestration step that mutates something other than a fresh append (ticket description edits, map body edits, charter amendments).

## Cross-cutting

### Everything delegates

Every read and every mutation in every playbook here is a delegated `@linear` call. This skill's playbooks name the logical operation (`read comments`, `attach_document`, `move_state`) using `/linear`'s own vocabulary (`playbooks/issue-management.md` in the `linear` skill) — the mechanics, team/stateId resolution, and the GraphQL bridge live there, not here. Gate judgment is always a delegated `@attack-kitty` mandate — this skill composes the mandate inputs per the mandate card's contract; the card itself is `@attack-kitty`'s to carry.

### Mention escaping

Backtick-escape agent names (`@linear`, `@attack-kitty`, `@traffic-cone`) in every comment or description body this skill's orchestration produces or passes through — Linear's mention parser treats a bare `@` as a user lookup and fails the whole write. Always: `` `@linear` ``, `` `@attack-kitty` ``, `` `@traffic-cone` ``.

### Claim orchestration from a background context

Traffic-cone runs `background: true` — a caller dispatches it and continues, rather than holding a live exchange. Two things behave differently here than they would in a foreground session:

**The delegate-set bridge.** `@linear`'s claim action issues the GraphQL `issueUpdate` (delegate-set) through the app token resolved via `secrets.op_read` / `linear.app_token_ref` — an unattended, service-account path with no interactive auth step. It works identically whether the caller invoking `@linear` is a foreground session or a background spawn like this one; the bridge doesn't know or care what invoked it. Nothing about background operation changes the claim mechanics — only the operator-facing decision points below do.

**Operator decision points degrade to a park, not a wait.** A foreground session can put a question to the operator and hold for her answer in the same exchange. A background spawn cannot — there is no live exchange to hold. Every point in this skill's playbooks that would otherwise ask the operator something degrades to the same move: park (Needs Input, with the specific ask in a comment) and stop, exactly as if the operator were merely absent rather than architecturally unreachable. Concretely:

- **Needs Input routing** (claim's deferred Done When, `mark_done`'s missing Objective) — already a park by design; background mode changes nothing here, this was always fire-and-forget.
- **CHARTER-CONFLICT and REFUTED-at-cap** (`closing.md` Step 2) — already route to Needs Input, not a live ask; unchanged in background mode.
- **A non-CONFIRMED map-close verdict** (`close-map.md` Step 3) — already posts `[HANDOFF]` and stops rather than negotiating; unchanged in background mode.

In other words: this skill's gates were already designed to park rather than block on a live operator response, which is precisely what makes them safe to run from `background: true` — there is no decision point in `mark_done`, `resolve`, or `close-map` that assumes a foreground exchange. The one place a live exchange genuinely matters — a HITL decision ticket's resolution — is explicitly out of `resolve`'s scope here (it verifies the resolution comment exists; producing that comment is the map session's live-exchange work, done before `resolve` is ever invoked).

**What can be batched as a pre-claim pose.** Since every decision point already degrades to a park, `work frontier` running unattended can safely chain through the entire pick → claim → (handoff) → close loop for straightforward tickets without any point requiring a synchronous operator response — the Needs Input cap (3 consecutive routings) is the only backstop against a background session grinding against a triage-shaped frontier. Nothing here needs a new pre-claim batching mechanism beyond that existing cap: the architecture already treats "operator not present" as the default case, not an exception background mode has to special-case.

## What this skill does NOT do

- Execute raw Linear mutations or reads — `@linear` does, always by delegation.
- Judge a gate — `@attack-kitty` does, always by delegation, and never on work this skill had a hand in authoring.
- Author ticket content (objectives, done-when, descriptions) — the caller authors; this skill may enforce shape (the admission test, the decision-type guard) but never composes intent.
- Chart maps, cut tickets, or resolve HITL decisions — that's wayfinder's live-exchange work, upstream of everything this skill orchestrates.
- Author or dispatch build-ticket work — that's `/conduct`'s loop; `work frontier` hands off to it and resumes only at closure.
