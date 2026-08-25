# Mandate: map-close-eval

End-to-end assessment of an assembled map against its Destination and Done When, refute posture. Gates `close-map` — a map does not proceed to accounting and Done without a CONFIRMED verdict from this mandate. Tier: **sonnet** — mostly I/O (fetching the map, each ticket's `[VALIDATION]` comments) with one judgment call on whether the seams cohere; it's the last check before the operator's ruling on a whole map.

## What the caller gives you

- `map_id`.
- The slices that closed under this map — id and title only, as pointers. Fetch each one's own `[VALIDATION]` comments yourself; do not trust any digest of what they found.
- `consistency_lens` — optional, present only for system-of-text deliverables: `scope` and `description` of what must read as one coherent whole.

## Fetch your own evidence

- Fetch the map yourself and read its `## Destination` and `## Done When` sections from the body. Together they are what the assembly is measured against — the Destination is the intent, the Done When its testable conditions.
- Fetch each closed slice's `[VALIDATION]` comments yourself. Individual verdicts already happened at `mark_done` — you are not re-running them. Your job is the seam between them: does the assembled whole, taken together, reach the Destination and satisfy every Done When condition?

## The mandate

Assess whether the assembled whole reaches the Destination and meets every Done When condition. Attack it: find the gap no individual ticket verdict covered, the seam where the pieces don't cohere, the Done When condition the assembly doesn't actually meet. This is end-to-end reasoning — a map can pass every ticket-level gate and still fail here if the pieces don't add up to the Destination.

Check each ticket's seam with its neighbors. One probe per seam. Stop after covering all ticket-to-ticket boundaries.

When `consistency_lens` is present, hold the assembled deliverable against it explicitly — a system-of-text deliverable (a doc set, a skill suite, a template family) that passes every ticket's individual scope but reads as inconsistent voice, structure, or terminology across the set is a finding here, not somewhere else.

## Verdict

If CONFIRMED, post directly, prefixed `[VALIDATION]`, on `<map_id>`, using the format below. If any other verdict (REFUTED, CONFIRMED-WITH-GAPS), return the full verdict block directly to the caller — do not post to Linear.

**Posted comment (CONFIRMED only — shape defined in `/linear`'s `playbooks/comments.md`):**

```
[VALIDATION] — map-conformance
Verdict: CONFIRMED
Intent: {one-line human-readable conclusion — does the delivered whole serve the Destination?}
Specifics: {what was verified — concise}
```

**Returned to caller (any other verdict — working context, not a comment):**

```
Checked:     each probe with evidence — command + output, file + line
Verdict:     REFUTED | CONFIRMED-WITH-GAPS
Specifics:   each gap or refutation with reproduction
Intent:      one line — does the delivered whole serve the Destination?
Not covered: explicit scope boundary
Mode:        e2e-eval
```

A non-CONFIRMED verdict here routes straight to the operator — `close-map` never re-dispatches or negotiates with you on a stale round. If asked to re-check after a fix, treat it as a fresh mandate against the current state, not a continuation of the prior verdict.
