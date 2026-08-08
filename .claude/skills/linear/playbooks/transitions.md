# Playbook: transitions

State-change discipline: `move_state` (Needs Input / Blocked / Todo), `cancel`, and the mechanical execution of `mark_done`/`resolve`.

## `move_state`

**Protocol:** `mcp__linear-tactic__linear_updateIssue` with `stateId=<target>`. Target ∈ {`Needs Input`, `Blocked`, `Todo`, `Done`} — use `claim` for `In Progress`, and use `mark_done`/`resolve` below for an ordinary ticket's `Done` (not this action) — with the map lane as the one exception, both directions.

**Park discipline.**
- Moving to **Needs Input** requires a comment naming the specific ask — what the operator needs to decide or provide.
- Moving to **Blocked** requires a checkable condition in a comment — a URL to poll, a version to check, a PR to look up, an API status, a date to wait for — something a session can probe mechanically to determine if the block has resolved.
- **Parks release the claim.** Moving to Needs Input OR Blocked clears the claim (`delegateId: null` via the GraphQL bridge) and posts resume state — the claim marks active work only; a parked ticket is re-claimable by any later session once returned to the frontier. Assignee is untouched by park — the operator's involvement record survives; clearing it is the operator's act. A parked ticket with assignee set stays off the autonomous frontier (`assignee: null` filter), routing it back to an operator session.
- **Todo** returns a park to the frontier — a confirmed un-park. The claim should already be cleared from the park; if not, surface it.
- Optionally surface a WARNING if `move_state` is the only mutation for that issue in a batch.

**Map lane (issues carrying the `map` label only).** `Done` is permitted, guarded on all four conditions — verify each; any missing → refuse:
1. A `[VALIDATION]`-prefixed comment posted by the dispatched non-author e2e eval carrying verdict `CONFIRMED` in the standard vocabulary (any other verdict — including `CONFIRMED-WITH-GAPS` — routes to the operator).
2. Zero open children.
3. The accounting document present.
4. The charter archived.

Park states (`Needs Input`, `Blocked`) are REFUSED for maps — a wedged map is reported by the sweep, never parked; map states are exactly In Progress → Done.

## `cancel`

Closure for work that won't be done.

**Protocol:** `body` (reason) required. `mcp__linear-tactic__linear_updateIssue` with `stateId=<Canceled>` + a reason comment. Optional `related_id` → `duplicate_of` relation.

## `mark_done` / `resolve` — mechanical execution only

These are thin state transitions. The sequencing that decides *when* a ticket is allowed to close — pre-checks, the charter admission test, the non-author validation gate, verdict routing, retry, the cap — is `` `@traffic-cone` ``'s. This playbook fires only once that orchestration has already decided the transition is legal; it does not re-derive that decision. **A caller invoking either action directly without having run `` `@traffic-cone` ``'s gate first is bypassing the gate, not satisfying it.**

**`mark_done`** — Input: `issue_id`, optional `body` (closing comment). Protocol: `mcp__linear-tactic__linear_updateIssue` with `stateId=<Done for issue's team>`. If `body` is provided, also `mcp__linear-tactic__linear_createComment`. Does not re-check `## Objective`/`## Done When`, does not verify a `[VALIDATION]` comment exists, does not spawn a validator.

**`resolve`** — Input: `issue_id`. Protocol: `mcp__linear-tactic__linear_updateIssue` with `stateId=<Done for issue's team>`. Same trust boundary as `mark_done`: does not re-check the decision-type label or verify a findings document / resolution comment exists — `` `@traffic-cone` ``'s `resolve` orchestration does that before ever calling here.

## What this playbook does NOT do

- Does NOT decide whether a transition is legal — pre-checks, the admission test, the validation gate, and verdict routing all live in `` `@traffic-cone` ``'s own playbooks.
- Does NOT spawn `` `@attack-kitty` `` — gate composition and dispatch are orchestration, not mechanical execution.
- Does NOT open the loop — `playbooks/claim.md` precedes every transition here.
- Does NOT close maps — map close is `` `@traffic-cone` ``'s `close-map` orchestration, which calls this playbook's map lane as its final gate.
