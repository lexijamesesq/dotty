# Playbook: transitions

Verifies and executes the intermediate lifecycle moves — `park` (→ Needs Input), `block` (→ Blocked), `un-park` (→ Todo), and `cancel`. Traffic-cone reads the ticket itself before every move; the discipline for what each move requires is `/linear`'s `playbooks/transitions.md` — this playbook enforces it and executes directly rather than restating it.

## Park (→ Needs Input)

**Read.** `linear_getIssueById` on the ticket. Confirm it does not carry the `map` label — maps never park; a wedged map is a sweep finding, not a park target.

**Check.** The caller's comment names the specific ask — what the operator needs to decide or provide. A park with no named ask is not a park, it's an abandoned ticket → refuse.

**Execute.**
1. `linear_updateIssue` with `stateId=Needs Input`.
2. Post the ask as a comment (`linear_createComment`) if not already posted.
3. Release the claim: clear `delegateId` via the GraphQL bridge — write the payload to a file, run the bridge (resolved via `secrets.op_read` / `linear.app_token_ref` per CLAUDE.md > Configuration), read back to verify. Assignee is untouched — that's the operator's field to clear, never park's.

## Block (→ Blocked)

**Read.** Same map-label check as Park.

**Check.** The caller's comment names a checkable condition — a URL to poll, a version to check, a PR to look up, a date to wait for. A block with no checkable condition → refuse.

**Execute.**
1. `linear_updateIssue` with `stateId=Blocked`.
2. Post the condition as a comment if not already posted.
3. Release the claim — same bridge clear as Park.

## Un-park (→ Todo)

**Check.** Either the named blocker is verifiably resolved (re-check the condition from the Blocked comment) or the operator directed the un-park explicitly → refuse if neither holds.

**Execute.** `linear_updateIssue` with `stateId=Todo`. The claim should already be cleared from the park; if it isn't, surface it rather than silently clearing it here. A return to In Progress is a fresh claim, not an un-park — route to `claim.md`.

## Cancel

**Check.** The caller's comment gives a reason. No reason → refuse.

**Execute.** `linear_updateIssue` with `stateId=Canceled`, post the reason comment. If `related_id` is given, create a `duplicate_of` relation.

## What this playbook does NOT do

- Does NOT park or block a map-labeled issue — maps are exactly In Progress → Done; a wedged map routes to the sweep, never here.
- Does NOT execute the map's Done transition — that four-gate close is `close-map.md`'s.
- Does NOT un-park directly to In Progress — that's a fresh claim, routed to `claim.md`.
- Does NOT invent the checkable-condition or named-ask content — the caller composes it; this playbook verifies it's present and executes.
