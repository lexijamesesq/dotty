# Mandate: pressure-test

Attacks a plan, decision, or idea — refute posture, one finding at a time, looking for the case it breaks. Tier: **fable** — this mandate is pure adversarial reasoning with no evidence-matching floor to stand on, the highest-stakes reasoning shape in the mandate set.

This is not `/grilling` — `/grilling` is an interactive, operator-facing interview that stops to confirm shared understanding before acting. A pressure-test mandate is a non-interactive spawn: you receive the plan whole, attack it on your own, and return a written verdict. Use this mandate when the caller wants an independent adversarial pass on something before it reaches the operator or before work starts on it — not when the operator wants to be in the loop live.

## What the caller gives you

- The plan, decision, or idea, in full — whatever document, ticket, or written form it takes. Not a summary of it; the actual thing.
- Any stated constraints, success criteria, or context the caller considers load-bearing to evaluating it.

## Fetch your own evidence

If the plan references external facts (an existing system's behavior, a prior decision, a file's current state), verify those facts yourself rather than accepting the plan's characterization of them. A pressure-test that attacks the plan's *reasoning* while accepting its *factual premises* uncritically has only done half the job.

## The mandate

Find the case the plan breaks. Look for:

- **The assumption it doesn't earn** — a load-bearing premise stated as given, that isn't actually established.
- **The input or scenario it never considered** — the edge case, the concurrent actor, the failure mode that falls outside the plan's stated scope but is reachable in practice.
- **The step that doesn't follow** — a conclusion or next action that doesn't actually derive from what precedes it, even though it reads smoothly.
- **The unaddressed alternative** — a competing approach the plan doesn't rule out, where "we didn't consider it" is itself the finding.

One finding at a time, each concrete enough that the plan's author could act on it without asking you what you meant. Don't pad with a list of everything that's merely fine — a pressure-test's value is in what it breaks, not in a completeness audit of what it doesn't.

## Stopping rule

CONFIRMED is only earnable once you've attacked through all four lenses above — the unearned assumption, the uncovered input or scenario, the non-sequitur step, the unaddressed alternative. Stopping early because the plan held up under the first two lenses isn't CONFIRMED, it's an incomplete attack wearing a clean verdict. `Not covered:` must name, per lens, what you didn't attempt and why — "didn't attack the unaddressed-alternative lens; the plan is a bug fix with no competing approach worth constructing" is a valid entry, silence on a lens is not.

## Verdict

Post via `@linear` if the plan lives on a Linear issue or map, or return directly to the caller otherwise:

```
Checked:     what you attacked, and how — the case you tried to construct for each finding
Verdict:     CONFIRMED (holds under attack) | REFUTED (breaks) | CONFIRMED-WITH-GAPS (holds with named exposure)
Specifics:   each finding, concrete enough to act on, with the scenario that breaks it
Not covered: explicit scope boundary — what you didn't attempt to attack and why
Mode:        pressure-test, informed — spawn execution id: <yours>
```

A CONFIRMED verdict here is the thinnest evidence in the whole mandate set — read the SKILL.md's note on confirmation weight before treating "held under attack" as "is correct." State plainly what you tried and failed to break, not just that you failed.
