# Linear Discipline

Linear is the source of truth for backlog and project narrative. Two policies: state must reflect reality, and new tickets must be individually well-formed.

## State, relation, description: three layers, one job each

A ticket carries three kinds of information; each has one job:

- **State** — the ticket's lifecycle position. Single field, indexable, visible in list views. Answers "where is this in motion?" This is THE signal.
- **Relation** (`blocked_by`, `blocks`, `related`, `duplicate_of`) — structural link to another Linear ticket. Adds navigability and bidirectional surfacing. Use when the context IS another Linear ticket.
- **Description** — prose context. Use when the context isn't another Linear ticket (external dependency, stakeholder decision, upstream fix, workflow stage, etc.).

State is the signal. Relation and description are different forms of context that explain *why* the state is what it is. The State must match reality regardless of which form of context applies:

- A ticket blocked by another Linear ticket gets the relation AND moves to Blocked state.
- A ticket blocked by an external factor gets prose context AND moves to Blocked state.
- The relation does NOT substitute for the State. Prose does NOT substitute for the State.

This applies symmetrically to Waiting: pick the right form of context (relation if Linear-ticket, prose if external), but the State carries the lifecycle signal.

## State on pick-up

When a Linear issue becomes the focus of work — you've read its description with intent to act on it — set state to `In Progress` before the first relevant edit. Set to `Done` when the work is complete.

Applies per-issue, not per-batch. A session that closes five issues still sets and clears state on each one. Why: dashboards, audit trails, and human visibility into what's actively in motion all depend on state matching reality, not just terminal state.

## Waiting and Blocked entry paths

Two valid paths into Waiting or Blocked (see next section for which to pick):

1. **Creation-time.** File the issue directly into Waiting or Blocked when the dependency exists at the moment of filing — needs a stakeholder decision, awaits an upstream fix, depends on a workflow stage that hasn't been reached. This is the dominant pattern in current usage.
2. **Mid-flight transition.** When you discover an external dependency mid-work, move `In Progress` → `Waiting` or `Blocked`.

Both paths must satisfy Integrity on Creation (clause below) including a description that states: what resolves the dependency, who/what is the resolver, expected trigger.

When the dependency clears:
- Creation-time items → move to `Todo` (now pickupable; work hasn't yet started)
- Mid-flight items → move back to `In Progress` (resume from where work paused)

Closing a Waiting or Blocked item to `Canceled` is also valid — abandoning the wait is a legitimate outcome, not a failure.

## Waiting vs Blocked

`Waiting` = expected delay with a known resolver; the wait will end on its own (PR review, scheduled response, upstream integration fix). Monitor passively; re-check at next session-start.

`Blocked` = something requires intervention to advance; the block won't lift on its own (a decision is needed, a re-scoping is required, an unknown must be resolved). Surface to human as "decide," not "wait."

Both states must carry the resolver + trigger in the description per the entry-paths rule above. Both surface in the active queue at every session-start; re-evaluate context on each before continuing:

- `Waiting`: continue waiting (only if the trigger is still in the future), nag the resolver, change the resolver, or Cancel.
- `Blocked`: decide now, find an alternate path to unblock, or Cancel.

The trigger for re-evaluation is the session boundary plus any context shift the operator notices — not a calendar threshold. Days unupdated is a weak signal for these states because the work isn't expected to move; the question is whether the *dependency* has moved.

## Closure form

Use `Canceled`, not `Duplicate`, for closure when an issue isn't going to be done. Express duplication via Linear's `duplicate_of` relation on the Canceled item — the link is queryable; a `Duplicate` state with no relation isn't.

## Integrity on creation

Before filing a new Linear issue:

1. **Duplicate check** — search Linear for existing coverage of the topic first. The new ticket may collapse into an existing one, or merit creation as a sibling.
2. **Acceptance criteria** — include a falsifiable definition of done in the description. Without it, closure becomes argumentative and the ticket inflates or atrophies.
3. **Dependencies as Linear relations** — express `blocks` / `blocked_by` via Linear's native relations, not as prose mentions in the description. Prose-mentions are invisible to filters and queries.
4. **Project + priority match the work** — don't default to the convenience choice (e.g., System + Normal) because it's the path of least resistance. Pick the right project for routing; pick a priority that reflects actual urgency.
