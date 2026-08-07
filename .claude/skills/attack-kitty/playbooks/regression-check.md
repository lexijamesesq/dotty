# Mandate: regression-check

Holds a change against the before-state it modified — did this break something that was working. Tier: **sonnet** — evidence-vs-contract matching, the same reasoning shape as `deliverable-check.md`, aimed backward at prior behavior instead of forward at a spec.

Distinct from `deliverable-check.md` (does the artifact match its spec) and `destination-check.md` (does the deliverable reach the ticket's Destination) — this mandate doesn't ask whether the change achieves what it set out to do. It asks only whether the change quietly broke something that was working before it landed.

## What the caller gives you

- What changed — the diff, the ticket, or a pointer to it.
- What was working before — a description of the prior behavior, in the caller's words.
- Pointers to the before-state contract: capability lines, test suites, behavioral expectations that documented what "working" meant. Locations only — you fetch the content.

## Fetch your own evidence

Fetch the change itself in full, and fetch the before-state contract in full — never the caller's summary of either. If the contract is a test suite, run it. If it's a capability line or behavioral expectation written in prose, hold the current state against it directly rather than against the caller's paraphrase of whether it still holds.

## The mandate

For each item the before-state contract names:

- **Still holds** — the behavior is unchanged, or changed in a way the contract itself anticipated.
- **Silently broke** — the behavior no longer holds and nothing in the change's stated scope said it should.
- **Broke on purpose, undocumented** — the behavior changed as an intended consequence of the change, but nothing marks it as an intentional break; this is a finding, not a pass, even when the break is correct — an undocumented intentional break reads identically to an accidental one to the next person who hits it.

You are not judging whether the new behavior is better — only whether its arrival was silent.

## Verdict

Post via `@linear`, prefixed `[VALIDATION]`, on the relevant issue:

```
Checked:     each before-state item, with evidence — command + output, file + line
Verdict:     CONFIRMED | REFUTED | CONFIRMED-WITH-GAPS
Specifics:   each regression or undocumented intentional break, with reproduction
Not covered: explicit scope boundary
Mode:        regression-check, informed
```
