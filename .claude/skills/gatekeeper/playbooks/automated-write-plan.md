# Playbook: automated-write-plan

Pre-commit write execution for `mode: automated` (handoff-contracts §5). Loaded from assess-candidates step 8 — never a direct entry. In this mode the skill's ONLY direct vault writes are `/queue create-item` files; destination writes are *planned* here and applied downstream.

## What files in automated mode

Only the matrix cells that say `file`: durable-knowledge (registered + resolved-unique) and meeting-log (registered playbook context). Everything else was queued or discarded upstream in assess-candidates.

**Enablement gate:** the Pi lane config owns the gate. When the lane declares the gate uncleared, skip planning entirely — every `file` disposition becomes a queue landing with reason `enablement-gate`.

## Plan shape (verbatim contract)

Per target:

- **NEW files:** the full composed content (complete structural-contract envelope) + **enumerated content sources** — which candidates/source items produced this file. An absent or empty enumeration is itself a critic FAIL (rubric R4, no-rollup: no new file whose substance derives from ≥2 already-filed vault files; the enumeration's *presence* is mechanical, the derivation claim stays named judgment).
- **EXISTING targets:** `{target, pre_state_hash, append_suffix}` **ONLY**. The plan never carries a rendered full state for an existing file — that makes rubric R6 (mutation discipline) mechanically checkable from the plan itself (a full-state entry for an existing target = automatic FAIL) and makes a whole-file overwrite structurally impossible.

`pre_state_hash` = SHA-256 over the target's current content (read via `mcp__obsidian__read_note`, hash via `Bash(shasum:*)` on stdin: `shasum -a 256`).

`append_suffix` carries: date attribution, and — mandatory on every automated write (handoff-contracts §5 field derivation) — provenance `routine/<action> <run-id>` (structural-contract › Provenance) **plus** the human-readable source attribution (e.g. `Canopy Triad Sync 2026-05-28`). Rubric R5 checks both.

## Idempotency recheck

Immediately before planning each append, recheck the target for a `content_hash` / attribution+date match — vault sync may have delivered writes since step 2's search. Match → drop the candidate to `discard: duplicate`.

## Downstream handoff (the contract this plan feeds — not executed here)

```
plan (model — this playbook)
  → validate (model — critic gate, capture-rubric v2, separate context)
      FAIL → nothing commits; run reports FAIL; heartbeat suppressed;
             plan + reasons → quarantine queue item (exempt from R7 — written after the gate)
  → apply (deterministic script — NOT a model)
      per append: recheck pre_state_hash at apply time; mismatch (e.g. a sync-delivered
      operator edit) → abort that write + queue item + continue others;
      new files created verbatim; bulk-write guard active
  → verify (post-apply)
      filing-validator on new files; suffix-presence check on appends;
      FAIL → quarantine queue item naming the file + expected-vs-found;
      heartbeat suppressed; no further writes this run — never silent, no auto-revert
```

## Output

Return to assess-candidates step 9: `write_plan` (shape above) + updated dispositions. `applied[]` stays pending — the apply/verify stage completes it in the run report.
