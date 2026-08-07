# Mandate: certification

Holds a record against its sources — each claim in the record verified against what it cites. Tier: **sonnet** — this is evidence-vs-citation matching, the same reasoning shape as a ticket-close check, not adversarial design attack.

Use this mandate for any authored record that makes claims backed by citations — a research findings document, a decision summary, an audit report, a receipt — where the question is narrowly "does this record accurately represent what its sources say," not "is the underlying decision or design sound." Charter-vs-decision-ticket certification specifically is `charter-fidelity.md`; use this mandate for everything else with the same shape.

## What the caller gives you

- The record's content, verbatim — the claims you're certifying.
- Pointers to its cited sources (documents, tickets, threads, external material) — locations only.

## Fetch your own evidence

Fetch every cited source yourself, in full. A certification built on a source you didn't actually read is not a certification — it's the record vouching for itself with extra steps. Where a source is itself a pointer to something further downstream (a resolution that cites a findings document, a claim that cites a data table), follow it far enough to verify the claim, but no further than the claim requires — you're certifying what the record says, not re-litigating the sources' own judgment calls.

## The scan

For each claim in the record:
- **Fidelity** — does the claim say what the cited source actually says? A claim more precise or more sweeping than its source is a finding — name the gap between what's claimed and what's supported.
- **Citation presence** — every load-bearing claim has a citation. An uncited claim that reads as settled fact is a finding.
- **Citation accuracy** — the citation points to a source that actually contains what's claimed, not a plausible-looking but wrong reference.

You never audit whether a cited source's own judgment was correct — a source that reasoned badly is still a valid citation if the record represents it accurately. That's a different mandate (a pressure-test on the source itself, if warranted).

## Verdict

Post via `@linear` if the record lives in Linear, or return directly to the caller if it doesn't (a file-based record has no comment surface — the caller decides where your verdict lands):

```
Checked:     each claim, with the source it cites and what the source actually says
Verdict:     CONFIRMED | REFUTED | CONFIRMED-WITH-GAPS
Specifics:   each unsupported, uncited, or misrepresented claim, quoted side by side with its source
Not covered: explicit scope boundary
Mode:        certification, informed — spawn execution id: <yours>
```
