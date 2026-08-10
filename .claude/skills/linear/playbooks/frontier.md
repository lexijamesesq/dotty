# Playbook: frontier

Find takeable tickets — the mechanical query, not judgment. A caller consumes the returned list and picks; this playbook doesn't choose for it.

## Frontier convention

Takeable = state Todo, unblocked (no open `blocked_by` relation), `assignee: null`, unclaimed (`delegate: null`), not labeled `map`, and not a child of a map — map children belong to map sessions (routed by type label: `research`/`prototype`/`grilling`/`task` → their resolvers; `build` → a conductor), never the generic frontier — **with one exception: a `build` child labeled `ready-for-agent` is takeable here too**, and its claimant becomes the ticket's conductor once `/implement`'s pre-flight check and claim (`playbooks/claim.md`) complete.

Ordering: priority (Urgent → Low; `0`/no-priority sorts last — an unprioritized ticket never outranks a prioritized one), then age (`createdAt` ascending — oldest first).

The claim lives in the `delegate` field, not `assignee` — `assignee` is system-set on operator-directed claims (a co-engagement record) and is the operator's field to clear, never a frontier filter.

**`delegate` isn't exposed by the tactic MCP** — every takeable-set query below goes through the GraphQL bridge (same bridge as `playbooks/claim.md`'s Step 6, resolved via `secrets.op_read` / `linear.app_token_ref` per CLAUDE.md > Configuration), never `linear_getIssues`/`linear_getProjectIssues` alone.

## Map-frontier (takeable children of a map)

**Input:** `map_id`.

**Protocol:**
1. Run `map_sweep.py <map_id> --frontier-only` (`.claude/skills/linear/scripts/`) — it fetches through the bridge, applies the takeability filter and the Frontier-convention ordering above, and returns the ordered frontier with type labels and a `frontier_rule` string naming the rule, so no session re-derives it.
2. The caller routes by label (`research`/`prototype`/`grilling`/`task` → their resolvers; `build` → a conductor). `build` children labeled `ready-for-agent` also surface in Project-frontier below — they're takeable without a map session.

**Output:**
```yaml
frontier:
  - identifier: <TEAM>-N
    title: <string>
    type_label: research | prototype | grilling | task | build | none  # none = malformed, surface it
    priority: <number>
    createdAt: <ISO date>  # the ordering tiebreak, returned so a caller can inspect the sort
```

## Project-frontier (takeable tickets for a project)

**Input:** `project_id` (UUID).

**Protocol:**
1. Query Linear's GraphQL endpoint directly for the project via the bridge — the filter runs server-side:
   ```json
   {"query":"query { issues(filter: { project: { id: { eq: \"<project_id>\" } }, delegate: { null: true }, state: { type: { eq: \"unstarted\" } } }) { nodes { id identifier title priority createdAt parent { id } labels { nodes { name } } } } }"}
   ```
2. Narrow client-side to `assignee: null`, no open `blocked_by` relation, no `map` label, **and no map-labeled parent** — fetch each unique parent once per scan (cache, like stateIds) and check its labels; a child of a `map`-labeled issue belongs to map sessions (Map-frontier above), never here, while an ordinary sub-task stays takeable — **except a `build` child labeled `ready-for-agent`, which is takeable here** (Frontier convention above).
3. Return ordered by priority (Urgent → Low), then `createdAt` ascending as tiebreak.

**Output:** same shape as Map-frontier, project-scoped.

## What this playbook does NOT do

- Does NOT pick or claim a ticket — the caller (a conductor or frontier-pickup session) picks from the returned list and invokes `` `@traffic-cone` ``'s `claim` playbook, which verifies the ticket and executes `playbooks/claim.md`'s protocol directly. Driving the loop to close and capping at one ticket per session is that caller's discipline, not this playbook's or `` `@traffic-cone` ``'s.
- Does NOT analyze the returned list (staleness, theming, priority distribution) — read the data, reason about it inline; no playbook.
