# Playbook: closing

## Purpose

Admit and execute the closure verbs — `mark_done` (gates Done on a legitimate non-author `[VALIDATION]` receipt) and `resolve` (decision-type map children) — via `cone_preflight.py` + `linear_bridge.py`.

## Input

```yaml
issue_id: <TEAM>-N
verb: mark_done | resolve
body: <string>                          # optional closing comment (mark_done)
deterministic_exempt: true|false        # mark_done only — asserts a deterministic check fully adjudicated Done When
deterministic_exempt_context: <string>  # captured output backing the exemption assertion
```

## Run

1. Resolve `linear.gql_bridge_cmd` into `LINEAR_GQL_CMD` first — exit 2 means this step was skipped.
2. `cone_preflight.py mark_done <issue_id> [flags]` or `cone_preflight.py resolve <issue_id>`. `REFUSE`/`NEEDS_INPUT` → stop; return exactly what's missing. `NEEDS_INPUT` (M2.5 open `[CHALLENGE]`) itself executes `set-state` Needs Input — no further checks, no delegate ops. `JUDGMENT_REQUIRED` → rule on every `judgment_items` entry first.
3. `ADMIT` (or judgment cleared, and `M-o` clears) → `linear_bridge.py set-state <uuid> --state <facts.state_ids.done>`. `body` provided → post it via `mcp__linear-tactic__linear_createComment` after `lint-body`.
4. Idempotent path: already Done with a valid existing receipt → success, no re-transition (script reports `facts.idempotent: true`).

## Judgment kernel

- **J-M3c — type match on regex miss.** No literal `Validation mandate: <type>` found: does the Done When text name a mandate in other words? Only if genuinely silent does the build→`conformance` / neither→refuse fallback apply.
- **J-M-d — non-build exemption.** `deterministic_exempt` asserted on a non-build ticket: is the captured output actually applicable? When in doubt, not exempt. (Never on `build` — the script refuses that hard, no deferral.)
- **M-o — Objective drift.** Feedback that would change the Objective is not receipt input — refuse, route to the operator, never fold it into the transition.
- `resolve` has no deferred items of its own — guard and comment/document presence are fully deterministic.

## Refusal law

Return exactly what's missing: no receipt, stale receipt, type mismatch, malformed receipt, charter-timing violation, or missing resolution comment. Never retry, re-spawn a validator, or fix the gap — the caller runs `@attack-kitty` and re-invokes.

## What this playbook does NOT do

- Does NOT open the loop — `claim.md` precedes both verbs.
- Does NOT compose a mandate or spawn a validator — the receipt already exists or it doesn't.
- Does NOT close maps — `close-map.md`.
- Does NOT cap retries on a caller re-invoking against the same unfixed state — that discipline is the caller's.
