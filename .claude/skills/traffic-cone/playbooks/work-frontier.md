# Playbook: work frontier

Orchestrates the frontier pickup loop — the entry point for a session that wants the next takeable ticket without hand-assignment, claimed and driven to Done in one pass. This playbook is the orchestration layer only: it reads the frontier, picks a ticket, and sequences `claim` → work → close. The mechanical claim execution — the GraphQL bridge, the `delegateId` write, the read-back race check — is `@linear`'s `claim` action (`playbooks/issue-management.md` in the `linear` skill); this playbook never touches the bridge itself.

## Claim semantics (shared knowledge)

This playbook needs to understand claim semantics to orchestrate correctly, even though it never executes a claim mutation itself:

- **A claim is taken before the first relevant edit.** It lives in Linear's `delegate` field, distinct from `assignee` (the operator's co-engagement record — additive, never cleared by claim or park).
- **One ticket per session.** The WIP check is scoped to claims *this session* made, not the whole frontier.
- **Parks release the claim.** Needs Input or Blocked clears `delegateId` and posts resume state — a parked ticket is re-claimable by any later session once returned to the frontier.
- **A claim is not confirmed until content-verified.** `issueUpdate` is last-write-wins; write-success alone does not prove this session won the claim over a concurrent one. `@linear`'s claim action does the read-back verify — this playbook trusts that result, never re-derives it.
- **Variant selection matters.** A ticket's parent (map-labeled or not) and type label determine which claim variant applies — map-child, build, or full. `@linear`'s claim action selects the variant; this playbook only needs to know that a claimed `build` ticket makes the claiming session its conductor (invoke `/implement`), and a claimed map-child (non-build) routes to wayfinder rather than completing here.

## Input

```yaml
project_id: <UUID>     # OR map_id, exactly one required
map_id: <TEAM>-N
```

## Protocol

1. **Read the frontier.** Delegate to `@linear`: `read map-frontier <map_id>` (map scope) or `read project-frontier <project_id>` (project scope). The frontier convention (unblocked, unclaimed, unassigned, not a map child unless `ready-for-agent` `build`) is `@linear`'s to apply — this playbook consumes the returned list.
2. **Empty frontier.** Nothing takeable → report "no takeable work for `<scope>`" and stop.
3. **Pick the top ticket.** Order by priority (Urgent → Low), then `createdAt` ascending (oldest first) as tiebreak.
4. **Claim it.** Delegate to `@linear`: `claim <id> autonomous:true` — frontier pickups are autonomous (no operator present), suppressing the assignee-set.
   - Claim proceeds to In Progress → go to Step 5.
   - Claim instead routes the ticket to Needs Input (deferred or missing Done When) → that's not a claim. Return to Step 3 and pick the next takeable ticket. **Cap: 3 consecutive Needs Input routings.** At the cap, stop and surface the pattern — a frontier that keeps routing to the operator is a triage signal, not a work queue.
   - Claim returns a build-ticket redirect ("build ticket detected — invoke `/implement <id>`") → the ticket is not yet claimed; invoke `/implement` which runs its own pre-flight and then completes the claim. Go to Step 5.
5. **Hand off the work.** This playbook never authors the ticket's content. A claimed `build` ticket makes the claiming session its conductor — invoke `/implement` and let it run. A claimed decision-type ticket (research/grilling/prototype/task) routes to the appropriate resolver per wayfinder (research → `/research ticket`; HITL types → the map session's live exchange). This playbook's job ends at the handoff; it resumes at Step 6 once the work reports back closeable.
6. **Close it.** Run `closing.md`'s `mark_done` (unmodified) once the work reports done.
7. **Stop.** One ticket per frontier session (one successfully claimed and run). The pull to continue to a second ticket is the signal to end the session, not to loop back to Step 1.

**Discipline:** this playbook does not change `claim` or `mark_done` — it sequences them for one scoped, picked-not-named ticket. The operator-named single-ticket claim flow (caller supplies `issue_id` directly to `@linear claim`) is untouched and does not route through this playbook.

## What this playbook does NOT do

- Does NOT execute the claim mutation — `@linear`'s `claim` action does, including variant selection and the read-back race check.
- Does NOT author the ticket's work — a claimed `build` ticket hands off to `/implement`; this playbook orchestrates pickup and closure, not the middle.
- Does NOT apply to an operator-named single ticket — that claim runs through `@linear` directly, unchanged by this build.
