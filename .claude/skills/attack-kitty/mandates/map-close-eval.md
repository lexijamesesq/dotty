# Mandate: map-close-eval

End-to-end assessment of an assembled map against its Destination and charter, refute posture. Gates `close-map` (`/linear` `playbooks/close-map.md` Step 2) — a map does not proceed to accounting and Done without a CONFIRMED verdict from this mandate. Tier: **fable** — this mandate carries the estate's highest adversarial-reasoning weight; it's the last check before the operator's ruling on a whole map.

## What the caller gives you

- `map_id`.
- `charter_doc_id` — the map's finalized charter.
- The build tickets that closed under this map — id and title only, as pointers. Fetch each one's own `[VALIDATION]` comments yourself; do not trust any digest of what they found.
- `consistency_lens` — optional, present only for system-of-text deliverables: `scope` and `description` of what must read as one coherent whole.

## Fetch your own evidence

- Fetch the map yourself (`@linear`) and read its `## Destination` section from the body. That is what the assembly is measured against — not the caller's paraphrase of it.
- Fetch the charter yourself via `@linear` (`linear_getDocumentById`) and verify the `FINALIZED` marker stands. Absent or unfetchable → refuse to validate, report it, post no verdict.
- Fetch each build ticket's `[VALIDATION]` comments yourself. Individual ticket verdicts already happened at `mark_done` — you are not re-running them. Your job is the seam between them: does the assembled whole, taken together, reach the Destination?

## The mandate

Assess whether the assembled whole reaches the Destination and honors the charter. Attack it: find the gap no individual ticket verdict covered, the seam where the pieces don't cohere, the claim the charter makes that the assembly doesn't actually meet. This is end-to-end reasoning — a map can pass every ticket-level gate and still fail here if the pieces don't add up to the Destination.

When `consistency_lens` is present, hold the assembled deliverable against it explicitly — a system-of-text deliverable (a doc set, a skill suite, a template family) that passes every ticket's individual scope but reads as inconsistent voice, structure, or terminology across the set is a finding here, not somewhere else.

## Verdict

Post via `@linear`, prefixed `[VALIDATION]`, on `<map_id>`:

```
Checked:     each probe with evidence — command + output, file + line
Verdict:     CONFIRMED | REFUTED | CONFIRMED-WITH-GAPS | CHARTER-CONFLICT
Specifics:   each gap or refutation with reproduction
Intent:      one line — does the delivered whole serve the Destination?
Not covered: explicit scope boundary
Mode:        e2e-eval — spawn execution id: <yours>
```

A non-CONFIRMED verdict here routes straight to the operator — `close-map` never re-dispatches or negotiates with you on a stale round. If asked to re-check after a fix, treat it as a fresh mandate against the current state, not a continuation of the prior verdict.
