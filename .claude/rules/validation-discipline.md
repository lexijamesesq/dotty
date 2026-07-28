# Validation Discipline

Nothing ships author-graded. The role that builds a thing never issues its own PASS — not a subagent, not the orchestrator, not a skill. This rule exists because author-graded proofs are the most expensive recurring failure in agent work: every "validated" claim that later collapses was graded by its own author.

When no independent validator is available, report "self-checked, not independently validated" — never apply validator vocabulary to your own work. An honest status label is more informative than an independence claim you cannot back.

## What counts as proof

- Empirical probes against the real mechanism, using synthetic shape-equivalent fixtures — never real secrets, never real leaked values.
- A "proven / validated / E2E" claim names its artifact: execution ID, log line, exit code, commit hash. A claim that cannot name one is a hypothesis.
- The proof must exercise the path being claimed. A demo that bypasses the component under test proves nothing about it.
- Acceptance for automation is produced by the automation's own trigger path — a human-fired rehearsal of a scheduled lane proves the handler, not the system. If the trigger is a schedule, arm a one-shot and let the system fire itself.
- Evidence is captured whole: full output to a file, then read the file. Truncating in transit (`tail`/`head`/`grep` on first read) is how false-greens survive.
- Local green is not CI green. An environment-dependent test is a defect in the test.
- **Done = a reproducible acceptance command that a non-author session can run.** A narrative demo is not acceptance, and a ticket closed on one is not closed.

## Scope boundary

Validation answers "is the claim true" — never "should this exist." Mission-fit is chartered before building (discovery, planning, pressure-testing) and is not laundered through a validator afterward: a CONFIRMED verdict on scope creep is still scope creep.

## Narrow exemption

Work whose correctness is fully decided by an existing deterministic check — a one-line edit that a green fixture suite, linter, or byte-level diff adjudicates completely — may ship on that check alone. When in doubt, it is not exempt.

## Role machinery

When delegation is available, independent validation uses the roles, distances, and loop defined in `/dispatch` and `/linear` (which gates Done transitions on a non-author validator). The standing requirement: no delegate, critic, or validator may move the North Star — feedback that would change the objective is the signal to stop and take the question to the operator.
