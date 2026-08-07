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

### Operator decision points

Traffic-cone is often invoked from contexts where no live operator exchange is available (a conductor's spawn, a frontier session). Every point in this skill's playbooks that would otherwise ask the operator something degrades to a park: Needs Input, with the specific ask in a comment. No decision point in `mark_done`, `resolve`, or `close-map` assumes a live foreground exchange — the architecture treats "operator not present" as the default case. The one place a live exchange genuinely matters — a HITL decision ticket's resolution — is explicitly out of `resolve`'s scope here (it verifies the resolution comment exists; producing that comment is the map session's live-exchange work, done before `resolve` is ever invoked).

## What this skill does NOT do

- Execute raw Linear mutations or reads — `@linear` does, always by delegation.
- Judge a gate — `@attack-kitty` does, always by delegation, and never on work this skill had a hand in authoring.
- Author ticket content (objectives, done-when, descriptions) — the caller authors; this skill may enforce shape (the admission test, the decision-type guard) but never composes intent.
- Chart maps, cut tickets, or resolve HITL decisions — that's wayfinder's live-exchange work, upstream of everything this skill orchestrates.
- Author or dispatch build-ticket work — that's `/implement`'s loop; `work frontier` hands off to it and resumes only at closure.
