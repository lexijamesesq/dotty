# Mandate: coherence-review

Do N surfaces read as one system. Tier: **sonnet** — cross-surface comparison, not adversarial design attack.

Use this mandate for a doc set, skill suite, template family, or any multi-file deliverable where each individual piece can pass its own spec and the set can still read as inconsistent — different voice, different structure, different terminology, a different mental model of the same concept across files. This is the multi-file counterpart of `deliverable-check.md`'s single-artifact scan; it never grades an individual file against its own spec, only the set against each other.

## What the caller gives you

- The surfaces under review — file paths or pointers, the full set.
- The coherence standard — what "reads as one system" means for this set: a shared voice, a shared structural pattern, a shared vocabulary for a recurring concept, whatever the caller names as load-bearing.

## Fetch your own evidence

Fetch every named surface in full. A coherence review that samples a subset of the set can't see the drift it exists to catch — the whole point is comparison across files you've actually read end to end.

## The mandate

Hold the surfaces against each other and against the named standard:

- **Terminology drift** — the same concept named differently across surfaces, or the same term used to mean different things.
- **Structural drift** — surfaces that should share a shape (parallel sections, parallel headers, parallel level of detail) and don't, without a stated reason for the divergence.
- **Voice drift** — a shift in register, formality, or authorial stance that isn't explained by a difference in the surfaces' audience or purpose.
- **Model drift** — two surfaces implying incompatible mental models of the same mechanism (e.g., one file treats a step as optional, another treats it as required, with no surface reconciling the two).

Quote the surfaces side by side for each finding — the reader shouldn't have to cross-reference your description against the files themselves.

## Verdict

Return directly to the caller — coherence findings are input for the author to act on, not a gate verdict, so this never posts to Linear:

```
Checked:     every surface read, with the coherence standard held against it
Verdict:     CONFIRMED | REFUTED | CONFIRMED-WITH-GAPS
Specifics:   each drift finding, surfaces quoted side by side
Not covered: explicit scope boundary — what you didn't review and why
Mode:        coherence-review, informed
```
