# Playbook: close-map

## Purpose

Admit and execute the map-close ending sequence — the executable form of wayfinder's Ending (`playbooks/work-through.md` § Ending) — via `cone_preflight.py` + `linear_bridge.py`. Dispatching `@attack-kitty`'s `map-close-eval` mandate happens before this card runs; it verifies the verdict landed and executes on it.

## Input

```yaml
map_id: <TEAM>-N
```

## Run

1. `LINEAR_GQL_CMD` is set in the environment (`settings.json`); pass `--bridge-cmd <path>` if it isn't. Exit 2 means neither resolved.
2. `cone_preflight.py close-map <map_id>`. Step-1 preconditions (`CM1`/`CM3`/`CM5`) are aggregated — any failure → `REFUSE` with the full checklist, no partial execution, `CM6` not evaluated. Clean Step 1 → `CM6` (the `map-conformance` receipt) checked; failure there also `REFUSE`s.
3. `ADMIT` → author the accounting document (`CM7`, below) and attach it via `mcp__linear-tactic__linear_createDocument`.
4. **Before writing Done:** `cone_preflight.py close-map <map_id> --reverify --accounting-document-id <id from step 3>` — the scripted CM9 re-check of the close gates (`CM1`/`CM3`/`CM5`/`CM6`) plus the accounting-doc existence, against a fresh fetch. `ADMIT` → `set-state <map_id> --state <facts.state_ids.done>`. `REFUSE` (any drift — a late comment, a reopened child, the accounting doc gone missing) → refuse and surface instead of transitioning; do not retry silently.

## Judgment kernel

- **CM7 — the accounting document.** Compose "Accounting — `<map title>`" from each Done child's *own* receipts (`facts.done_children`, evidence supplied) — never this card's summary of the eval.

## Refusal law

Any Step-1 or Step-2 failure → refuse, return the full list of what's missing. Stop — the map stays In Progress; never re-dispatch or negotiate the verdict.

## What this playbook does NOT do

- Does NOT dispatch the e2e eval — the caller runs `@attack-kitty`'s `map-close-eval` mandate first; this card verifies the verdict already landed.
- Does NOT define what the eval should find.
- Does NOT handle mid-map work — charting, sweeping, decision-ticket resolution live in wayfinder.
- Does NOT re-validate individual slices — `CM5` verifies their verdicts exist, it doesn't re-run them.
