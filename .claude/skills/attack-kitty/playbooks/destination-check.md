# Mandate: destination-check

Holds a deliverable against a ticket's stated Destination, refute posture. Tier: **sonnet** — a deliverable-check with a wider lens; a Destination is a higher-altitude target than a Done When checklist, but the check itself is still evidence-vs-spec matching, not open-ended adversarial design attack.

Use this mandate when a ticket names a `## Destination` (or equivalent end-state framing) that Done When alone doesn't fully operationalize, and the caller wants a check on whether the delivered artifact actually gets there — not just whether it checks the boxes. If the ticket's Done When already fully captures the Destination, `ticket-close.md` is the right mandate instead; don't run both.

## What the caller gives you

- The ticket id.
- The Destination text, verbatim from the ticket.
- Pointers to the deliverable — file paths, a PR, a document id, whatever form the work took. Locations only; you fetch the content.

## Fetch your own evidence

- Fetch the ticket yourself (via Linear MCP tools for Linear content, directly for files) and read the Destination in its own words.
- Fetch the deliverable itself, in full. A destination check that samples the deliverable instead of reading it whole is exactly the kind of green that doesn't survive contact with reality.
- If the ticket's Done When exists alongside the Destination, read it too — Done When compliance without Destination attainment is a specific, nameable gap, not silence.

## The mandate

Attack whether the deliverable reaches the Destination. This is not a checklist walk — it's an adversarial question: if someone arrived at this Destination expecting what the ticket promised, would the delivered artifact satisfy them, or would they find a gap the ticket's literal wording didn't anticipate?

Look specifically for:
- **Literal-but-hollow compliance** — every checkable item present, but the whole doesn't add up to the Destination's intent.
- **Scope drift** — the deliverable solves an adjacent problem that resembles the Destination without being it.
- **Unstated assumptions** — the Destination presumes something (an audience, a downstream consumer, an environment) the deliverable doesn't actually address.

One pass through the deliverable against the Destination. These three checks — literal compliance, scope coverage, unstated assumption scan. Stop after these three.

## Verdict

If CONFIRMED, post directly, prefixed `[VALIDATION]`, on the ticket, using the format below. If any other verdict (REFUTED, CONFIRMED-WITH-GAPS), return the full verdict block directly to the caller — do not post to Linear.

**Posted comment (CONFIRMED only — shape defined in `/linear`'s `playbooks/comments.md`):**

```
[VALIDATION] — delivery
Verdict: CONFIRMED
Intent: {one-line human-readable conclusion — does the delivered whole reach the Destination?}
Specifics: {what was verified — concise}
```

**Returned to caller (any other verdict — working context, not a comment):**

```
Checked:     each aspect of the Destination, with evidence — file + line, command + output
Verdict:     REFUTED | CONFIRMED-WITH-GAPS
Specifics:   each gap or refutation, with reproduction
Intent:      one line — does the delivered whole reach the Destination?
Not covered: explicit scope boundary
Mode:        destination-check, informed
```
