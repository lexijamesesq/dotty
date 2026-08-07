# Mandate: destination-check

Holds a deliverable against a ticket's stated Destination, refute posture. Tier: **fable** — a Destination is a higher-altitude target than a Done When checklist, and confirming a deliverable reaches it takes the same adversarial reasoning as a map-close eval, just scoped to one ticket instead of a whole map.

Use this mandate when a ticket names a `## Destination` (or equivalent end-state framing) that Done When alone doesn't fully operationalize, and the caller wants a check on whether the delivered artifact actually gets there — not just whether it checks the boxes. If the ticket's Done When already fully captures the Destination, `ticket-close.md` is the right mandate instead; don't run both.

## What the caller gives you

- The ticket id.
- The Destination text, verbatim from the ticket.
- Pointers to the deliverable — file paths, a PR, a document id, whatever form the work took. Locations only; you fetch the content.

## Fetch your own evidence

- Fetch the ticket yourself (via `@linear` for Linear content, directly for files) and read the Destination in its own words — not the caller's paraphrase of it.
- Fetch the deliverable itself, in full. A destination check that samples the deliverable instead of reading it whole is exactly the kind of green that doesn't survive contact with reality.
- If the ticket's Done When exists alongside the Destination, read it too — Done When compliance without Destination attainment is a specific, nameable gap, not silence.

## The mandate

Attack whether the deliverable reaches the Destination. This is not a checklist walk — it's an adversarial question: if someone arrived at this Destination expecting what the ticket promised, would the delivered artifact satisfy them, or would they find a gap the ticket's literal wording didn't anticipate?

Look specifically for:
- **Literal-but-hollow compliance** — every checkable item present, but the whole doesn't add up to the Destination's intent.
- **Scope drift** — the deliverable solves an adjacent problem that resembles the Destination without being it.
- **Unstated assumptions** — the Destination presumes something (an audience, a downstream consumer, an environment) the deliverable doesn't actually address.

## Verdict

Post via `@linear`, prefixed `[VALIDATION]`, on the ticket:

```
Checked:     each aspect of the Destination, with evidence — file + line, command + output
Verdict:     CONFIRMED | REFUTED | CONFIRMED-WITH-GAPS | CHARTER-CONFLICT
Specifics:   each gap or refutation, with reproduction
Intent:      one line — does the delivered whole reach the Destination?
Not covered: explicit scope boundary
Mode:        destination-check, informed — spawn execution id: <yours>
```

`CHARTER-CONFLICT` applies only if the caller hands you a charter alongside the Destination and the deliverable satisfies the Destination while contradicting a charter claim — route that to the operator the same way `ticket-close.md` does, don't adjudicate it yourself.
