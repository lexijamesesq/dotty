# Playbook: closing

Verifies and executes the closure verbs — `mark_done` (gates the Done transition on a legitimate non-author `[VALIDATION]` receipt) and `resolve` (the close for decision-type map children). This playbook reads the ticket itself, checks the receipt is real, and executes the transition directly. It does not compose a mandate or spawn a validator — dispatching `@attack-kitty` is the caller's act, done before `mark_done` is ever invoked here.

### `mark_done` — gates the Done transition on a verified receipt

**Step 1 — Read.** `mcp__linear-tactic__linear_getIssueById` on `<id>`, plus its comments (`linear_getComments`). Read directly — never trust the caller's summary of where the ticket stands.

**Step 2 — Pre-check.** From the description just read:

- `## Objective` exists with non-empty text → else refuse: "run claim first."
- `## Done When` carries concrete conditions, not the deferral marker `_to be set at claim_` → else refuse: "run claim first."
- Ticket is In Progress → else refuse: not an open claim, nothing to close.
- Ticket does NOT carry a decision-type label (`research`, `grilling`, `prototype`, `task`) → else refuse: "decision tickets close through `resolve`, not `mark_done`."
- Note the ticket's type label and whether `## Done When` names a validation mandate (e.g., "Validation mandate: conformance") — Step 3's type-match check uses both.

**Step 2.5 — Charter check (`build`-labeled tickets only).** Read the parent map's comments. An open `[CHALLENGE]`-prefixed comment (no `[CHALLENGE-RESOLVED]` reply follows it) → move the ticket to Needs Input, run no further checks — in-flight work does not close against a charter under live challenge. Otherwise, read the map's documents (`linear_getDocumentById` on the charter's id only — never the map issue body or its comments, which carry live, unadjudicated builder material) and locate the charter. It must carry the `**FINALIZED** — <ISO date> — operator sign-off recorded` marker (`mutation-record-spec.md`), and that date must precede the `[VALIDATION]` comment's timestamp (Step 3) → charter not finalized, or finalized after the receipt it's meant to ground, refuse the whole `mark_done`.

**Step 3 — Verify the `[VALIDATION]` receipt.** From the comments read in Step 1, find the newest `[VALIDATION]`-prefixed comment. Every one of the following must hold, or the receipt is invalid:

- **Exists.** No `[VALIDATION]`-prefixed comment → refuse: "no validation receipt — run `@attack-kitty` first."
- **Fresh.** Its `createdAt` postdates the ticket's current claim — the most recent state change to In Progress, resolved from `linear_getIssueHistory` (find the latest entry whose new state is In Progress; its `createdAt` is the claim timestamp). A receipt older than the claim graded different work and never closes this one.
- **Type match.** The `{validation_type}` in its header matches the required type, resolved in order: (1) if `## Done When` names a validation mandate, require that exact type; (2) if Done When is silent and the ticket carries the `build` label, require `conformance`; (3) if neither yields a type, refuse — the gate cannot determine what was validated. A mismatched type is never the closer's to wave through.
- **Verdict.** `Verdict: CONFIRMED` — per `linear`'s `playbooks/comments.md`, any other verdict is never posted as a `[VALIDATION]` comment, so a non-CONFIRMED verdict landing here at all is itself a data error to refuse on.
- **Schema.** Carries all four lines of the `linear` skill's `playbooks/comments.md` format — `[VALIDATION] — {validation_type}`, `Verdict:`, `Intent:`, `Specifics:`. Missing any → malformed, refuse.
- **Author.** The comment's `user.id` matches the app actor — resolve via `linear_getViewer`. A `[VALIDATION]` comment posted by a human is not a non-author validation; the receipt's legitimacy rests on the app actor having posted it independently.
- **Charter timing (`build` tickets only).** Postdates the charter's FINALIZED date, per Step 2.5.

Any failure → refuse. Return exactly what's missing: no receipt, stale receipt, type mismatch, malformed receipt, or charter-timing violation. This playbook does not retry, re-spawn a validator, or fix the gap itself — the caller (who ran or should run `@attack-kitty`) does that and re-invokes `mark_done`.

**Step 4 — Transition.** All checks pass → `mcp__linear-tactic__linear_updateIssue` with `stateId=Done`. If the caller provided a closing `body`, post it via `linear_createComment` — omit for obvious closures, provide only when resolution was non-obvious.

**Idempotent recovery.** If the ticket is already Done and Step 3's checks pass against its existing `[VALIDATION]` comment, return success without re-transitioning.

**Retry discipline.** This playbook has no memory of prior invocations — it checks the current state and reports what's wrong, every time, then stops. It does not count cycles or cap retries; a caller re-invoking `mark_done` against the same unfixed state gets the same refusal each time. Capping runaway re-invocation cycles (three per continuous orchestration) is the caller's discipline, not this playbook's — there is no ticket comment a REFUTED verdict leaves behind for this playbook to count against.

**Discipline (deterministic exemption).** A ticket whose Done When a deterministic check fully adjudicates — a green fixture suite, a linter, a byte-level diff — may close on that check's captured output, noted in a comment, without a `[VALIDATION]` receipt, when the caller has recorded it as such and Step 3's checks are skipped by design rather than by omission. Never on `build`-labeled tickets — charter conformance is not deterministically adjudicable, so a build ticket always requires the receipt. When in doubt, it is not exempt; require the receipt.

**Discipline (the Objective is not negotiable here).** Feedback that would change the Objective is not a receipt input — refuse and route it to the operator, don't fold it into the transition.

### `resolve` — the close for decision-type map children

Never a door for `build` (or any templated) tickets — those close through `mark_done` only.

- **Guard.** Read the ticket directly. It must be a map child carrying a decision-type label — `research`, `grilling`, `prototype`, or `task`. Anything else → refuse: "resolve closes decision tickets; use mark_done."
- **`research`+`afk`.** Invoked by the orchestrator once the researcher has returned and the findings contract is met. Verify a findings document exists (`linear_getDocuments`) AND a resolution comment exists (`linear_getComments`) → either missing, refuse with what's missing. No validator — the ruled exception: research's trial is consumption, not adversarial review.
- **`research`+`hitl`.** Invoked by the map session after the operator's exchange lands the stance. Verify a resolution comment exists (`linear_getComments`) → transition. No findings document required — the stance was presented and resolved in the live exchange.
- **`grilling` / `prototype` / `task`.** HITL types — the resolution emerged with the operator in the exchange; her presence is the check. Verify a resolution comment exists → transition.
- All checks pass → `mcp__linear-tactic__linear_updateIssue` with `stateId=Done`.

## What this playbook does NOT do

- Does NOT open the loop — `claim.md` precedes both verbs; its checks are what `mark_done`'s Step 2 re-verifies.
- Does NOT compose a mandate or spawn a validator — the `[VALIDATION]` receipt already exists or it doesn't; this playbook checks, it doesn't produce.
- Does NOT close maps — `close-map.md` closes the map itself.
- Does NOT fix a bad receipt or retry on the caller's behalf — reports the gap, every time it's asked, and stops.
