# Playbook: transitions

## Purpose

Admit and execute the intermediate lifecycle moves — `park` (→ Needs Input), `block` (→ Blocked), `un-park` (→ Todo), `cancel` — via `cone_preflight.py` + `linear_bridge.py`.

## Input

```yaml
issue_id: <TEAM>-N
verb: park | block | un-park | cancel
operator_directed: true|false   # un-park only — operator directed the un-park explicitly, bypassing blocker re-check
related_id: <TEAM>-N            # cancel only, optional — duplicate_of relation
```

## Run

1. Resolve `linear.gql_bridge_cmd` into `LINEAR_GQL_CMD` first — exit 2 means this step was skipped.
2. `cone_preflight.py <verb> <issue_id> [flags]`. `REFUSE` → stop; return exactly what's missing. `JUDGMENT_REQUIRED` → rule on every `judgment_items` entry first — including the not-yet-posted case (`P1`), where the ask still needs composing now.
3. Compose any ask/condition/reason text the judgment step called for; post it via `mcp__linear-tactic__linear_createComment` after `lint-body`, if not already posted.
4. `park`/`block` execute: `linear_bridge.py set-state <uuid> --state <facts.state_ids.*>`, then `release-delegate <uuid>` (read-back verified). Assignee untouched.
5. `un-park` executes: `set-state` to Todo. If `facts` shows a delegate still set, surface it — never silently clear it.
6. `cancel` executes: `set-state` to Canceled (the reason comment already posted in step 3); `related_id` given → `mcp__linear-tactic__linear_createIssueRelation` (`duplicate_of`).

## Judgment kernel

- **J-P1 — ask specificity.** Does the posted (or about-to-be-composed) comment name a *specific* ask — what the operator needs to decide or provide?
- **J-B1 — condition checkability.** Is the condition something a session can probe mechanically — a URL, a version, a PR, a date?
- **J-U1 — blocker resolution.** Absent `operator_directed`, is the named blocker verifiably resolved against the condition on record?

## Refusal law

Return exactly what's missing — a park/block with no named ask/condition, or an un-park with nothing on record and no operator direction, refuses rather than inventing one.

## What this playbook does NOT do

- Does NOT park or block a map-labeled issue — maps are exactly In Progress → Done; a wedged map routes to the sweep.
- Does NOT execute the map's Done transition — `close-map.md`.
- Does NOT un-park directly to In Progress — that's a fresh claim, routed to `claim.md`.
- Does NOT invent ask/condition/reason content — the judgment step composes it; this card posts and executes.
