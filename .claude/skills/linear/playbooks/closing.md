# Playbook: closing

The mechanical execution for the closure verbs — `mark_done` and `resolve`. Both are thin state transitions: the sequencing that decides *when* a ticket is allowed to close — pre-checks, the charter admission test, the non-author validation gate, verdict routing, retry, the cap — is `` `@traffic-cone` ``'s (`playbooks/closing.md` in the `traffic-cone` skill). This playbook fires only once that orchestration has already decided the transition is legal; it does not re-derive that decision.

### `mark_done` — transition to Done

**Input:** `issue_id`, optional `body` (closing comment).

**Protocol:** `mcp__linear-tactic__linear_updateIssue` with `stateId=<Done for issue's team>`. If `body` is provided, also `mcp__linear-tactic__linear_createComment`.

This action trusts its caller — it does not re-check `## Objective`/`## Done When`, does not verify a `[VALIDATION]` comment exists, and does not spawn a validator. A caller invoking this action directly without having run `` `@traffic-cone` ``'s gate first is bypassing the gate, not satisfying it — `/linear` SKILL.md's Navigation routes ordinary callers to `` `@traffic-cone` `` for exactly this reason.

### `resolve` — transition to Done (decision-type map children)

**Input:** `issue_id`.

**Protocol:** `mcp__linear-tactic__linear_updateIssue` with `stateId=<Done for issue's team>`.

Same trust boundary as `mark_done`: this action does not re-check the decision-type label or verify a findings document / resolution comment exists — `` `@traffic-cone` ``'s `resolve` orchestration (`playbooks/closing.md`) does that before ever calling here.

## What this playbook does NOT do

- Does NOT decide whether a transition is legal — pre-checks, the admission test, the validation gate, and verdict routing all live in `` `@traffic-cone` ``'s `closing.md`.
- Does NOT spawn `` `@attack-kitty` `` — gate composition and dispatch are orchestration, not mechanical execution.
- Does NOT open the loop — `claim` (this playbook's sibling `issue-management.md`) precedes both verbs.
- Does NOT close maps — map close is `` `@traffic-cone` ``'s `close-map` orchestration, which calls this skill's `move_state` map lane as its final gate.
