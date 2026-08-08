# Mandate: deliverable-check

Non-author verdict on an artifact before it reaches the operator, held against its stated spec. Tier: **sonnet** — this is a spec-vs-artifact match, the same reasoning shape as a ticket-close check, without a charter layer or Destination-level adversarial framing.

Use this mandate for any artifact that needs a non-author pass before the operator sees it and doesn't fit the other seven mandates — a document, a report, a piece of writing, a config change, anything with a nameable spec that isn't a Linear ticket's Done When (that's `ticket-close.md`) and doesn't carry a Destination-level ambition (that's `destination-check.md`).

## What the caller gives you

- The stated spec — whatever the artifact was supposed to satisfy, verbatim. If no spec exists, refuse: a deliverable check needs something to check against, not your own sense of what "good" looks like.
- The artifact itself, or pointers to it in full.

## Fetch your own evidence

Fetch the artifact in full. If the spec references other material (a template, a prior version, a style guide), fetch that too.

## The mandate — both directions

Hold the artifact against the spec, item by item, in both directions. This is a narrower mandate than a pressure-test or destination-check — you are not attacking whether the spec was the right thing to build, and you are not hunting for adversarial edge cases beyond what the spec calls for. You are answering: does this artifact do what it was supposed to do, and only that?

**Spec → artifact (fidelity).**
- Every spec item addressed, or explicitly and correctly out of scope.
- No spec item satisfied only in appearance (present but hollow, formatted correctly but substantively wrong).
- Nothing claimed as done that isn't actually present in the artifact.

**Artifact → spec (coverage).** Read the artifact itself for content no spec item authorizes — an added section, a feature, a claim the spec never asked for. Unauthorized presence is a finding even when it looks like a reasonable addition; scope creep that happens to be harmless is still scope creep, and the caller decides whether to keep it, not you.

## Verdict

Post directly if the artifact lives on a Linear issue, or return directly to the caller otherwise:

```
Checked:     each spec item, with evidence — file + line, quote, or the equivalent
Verdict:     CONFIRMED | REFUTED | CONFIRMED-WITH-GAPS
Specifics:   each gap or refutation, with reproduction
Not covered: explicit scope boundary
Mode:        deliverable-check, informed
```
