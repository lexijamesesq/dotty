# Validation Discipline

Nothing ships author-graded. The role that builds a thing never issues its own PASS — not a subagent, not the orchestrator, not a skill. This rule exists because author-graded proofs are the most expensive recurring failure in agent work: every "validated" claim that later collapses was graded by its own author.

## Roles

- **Builder** (subagent or orchestrator): produces the work plus evidence of what it did. Its self-checks are progress signals, never acceptance.
- **Validator**: a fresh context with no authorship of the work. Mandate is to REFUTE, not confirm — re-derive every probe from scratch; never reuse the builder's scratch artifacts, fixtures, or transcript claims. Verdicts: CONFIRMED / REFUTED (with reproduction) / CONFIRMED-WITH-GAPS (each gap named). Every verdict cites its evidence: command plus output, exit code, execution ID.
- **Orchestrator**: routes work and grades nothing it authored. Work the orchestrator writes directly goes to an independent validator at the same bar as a subagent's — authorship, not seniority, disqualifies a grader.

## The loop

1. Builder ships work + claims.
2. Validator adversarially probes the claims — and the claim *source*: defect reports can be wrong in both directions, so refuting a reported defect is as valid a finding as confirming one.
3. Builder applies the validator's exact specifications. No silent adaptations — a forced deviation is named before acting.
4. Validator runs a targeted re-check that its own spec was applied (scoped confirmation, not a new adversarial round).
5. Escalation: values, scope, and decision-reversals go to the operator; objective architecture calls go to a critic subagent, not to her.

## What counts as proof

- Empirical probes against the real mechanism, using synthetic shape-equivalent fixtures — never real secrets, never real leaked values.
- A "proven / validated / E2E" claim names its artifact: execution ID, log line, exit code, commit hash. A claim that cannot name one is a hypothesis.
- The proof must exercise the path being claimed. A demo that bypasses the component under test proves nothing about it.
- Local green is not CI green. An environment-dependent test is a defect in the test.
- **Done = a reproducible acceptance command that a non-author session can run.** A narrative demo is not acceptance, and a ticket closed on one is not closed.

## Scope boundary

Validation answers "is the claim true" — never "should this exist." Mission-fit is chartered before building (discovery, planning, pressure-testing) and is not laundered through a validator afterward: a CONFIRMED verdict on scope creep is still scope creep.

## Narrow exemption

Work whose correctness is fully decided by an existing deterministic check — a one-line edit that a green fixture suite, linter, or byte-level diff adjudicates completely — may ship on that check alone. When in doubt, it is not exempt.
