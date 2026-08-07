# Playbook: closing

Orchestrates the closure verbs — `mark_done` (gates the Done transition on non-author validation) and `resolve` (the close for decision-type map children). This playbook carries the sequencing: pre-checks, the admission test, mandate composition for `@attack-kitty`, verdict routing, retry, and the cap. The raw reads and the final state transition are `@linear`'s mechanical actions (`playbooks/closing.md` in the `linear` skill) — this playbook never calls a Linear tool directly.

### `mark_done` — gates the Done transition on non-author validation

**Step 0 — Pre-check.** Delegate to `@linear`: `read issue <id>`. From the returned description:

- If no `## Objective` section exists with non-empty text → refuse. Tell the caller to run `claim` first (via `@linear`).
- If `## Done When` still carries the deferral marker `_to be set at claim_` → refuse. Tell the caller to run `claim` first.
- If `## Done When` names a validation mandate, the caller's `validation_type` must match it → refuse on mismatch; the mandate was named at cutting and is not the closer's to soften.

**Step 0.5 — Charter input (`build`-labeled tickets only).** The caller provides `charter_doc_id` — the pinned id of the finalized build charter. Before spawning the validator, delegate to `@linear`: `read comments <parent map id>`. An open `[CHALLENGE]`-prefixed comment (no `[CHALLENGE-RESOLVED]` reply follows it) → move the ticket to Needs Input (delegate to `@linear`), run no gate — in-flight work does not close against a charter under live challenge. Delegate to `@linear`: `read documents <charter_doc_id>` — via `linear_getDocumentById` only, never via the map issue (the map body and its comments carry live, unadjudicated builder material). The document must carry the `FINALIZED` marker block (see `mutation-record-spec.md`) — absent → refuse the whole `mark_done`: the charter isn't finalized, nothing closes against it.

**Admission test (written law, not precedent):** an artifact may join the ticket description in the validator's inputs only if it is (a) operator-finalized as a whole document, (b) adversarially attacked as that exact artifact, (c) frozen before the ticket's work began, (d) delivered as a pinned version reference. Today exactly one artifact passes: the finalized build charter. Research findings, decision tickets, and the map body all fail — nothing else joins, ever.

**Step 1 — Validate.** The caller provides `validation_type` and a structured `evidence` manifest. Spawn `` `@attack-kitty` `` via the Agent tool with a `ticket-close` mandate:

- **Model:** sonnet (the mandate card's tier — `playbooks/ticket-close.md` in the attack-kitty skill).
- **Distance:** informed — receives the charter and evidence, never the builder's reasoning or self-assessment.
- **Mandate inputs:**

  ```
  Mandate type: ticket-close

  Ticket id: <ID>

  Ticket spec (verbatim from the ticket, written before the work):
    Objective:   <verbatim from ## Objective>
    Done When:   <verbatim from ## Done When>
    Constraints: <verbatim from ## Constraints>

  Charter document id: <charter_doc_id>
    (Include only when the ticket carries the `build` label — omit
    entirely otherwise.)

  Evidence manifest (locations only — attack-kitty verifies everything
  itself):
    <ref> — <kind> — <change>
    ...

  validation_type: <red-team | functional | conformance | consistency | smoke>
  ```

`` `@attack-kitty` `` carries the full protocol — labels re-check, charter admission test, intent grading, manual-items rule, CHARTER-CONFLICT routing, and the `[VALIDATION]` verdict format — in its `ticket-close` mandate card. This playbook hands it the inputs; it does not restate the protocol.

`` `@attack-kitty` `` never receives the builder's closing comment, self-assessment, reasoning, or transcript — this playbook does not forward any of those either.

**Step 2 — Gate.** After the subagent completes, delegate to `@linear`: `read comments <id>`. Find the newest comment prefixed with `[VALIDATION]`.

- `CONFIRMED` → proceed to Step 3.
- `CONFIRMED-WITH-GAPS` → resolve each named gap before transition. A gap in the validator's comment is orphaned, not owned — the receiving session fixes it in-session. After all gaps are resolved, re-invoke `mark_done` (same re-check path as REFUTED).
- `REFUTED` → return the specifics to the caller. Ticket stays In Progress. Named substitute: apply the validator's specifics, then re-invoke `mark_done`. On re-invocation, try resuming the same validator via SendMessage for a scoped re-check (not a fresh adversarial round) — this saves tokens over a fresh spawn. If the validator goes idle without delivering a verdict (no new `[VALIDATION]` comment appears), it is incapable — kill it (`shutdown_request`) and spawn a fresh `` `@attack-kitty` `` with the same mandate inputs. The fresh spawn reads the prior `[VALIDATION]` comment on the ticket to scope its re-check to the named findings. The latest verdict governs; prior verdicts are scoping input only.
- `CHARTER-CONFLICT` → never the fix-worker loop: delegate to `@linear` to move the ticket to **Needs Input** with the receipt (releases the claim, posts resume state). The operator adjudicates — a validator's judgment is not a changed-fact receipt and cannot fell a settled claim.
- **REFUTED cap: 3 cycles total — counted from the ticket's `[VALIDATION]` REFUTED comments, never from session memory** (a park and re-claim does not reset the count — the count lives on the ticket, read via `@linear`, not in this orchestration's own memory). At the cap, delegate to `@linear`: move the ticket to **Needs Input** with a comment summarizing the impasse (releases the claim, posts resume state). The operator adjudicates.

**Step 3 — Transition.** Delegate to `@linear`: `mark_done <id>` (the mechanical action — `stateId=Done`, plus the closing comment if `body` was provided). Omit `body` for obvious closures; provide it only when resolution was non-obvious.

**Idempotent recovery:** if orchestration crashes between verdict and transition, re-invocation delegates to `@linear` for a fresh read and detects a CONFIRMED verdict comment **newer than the current claim** — proceeds straight to Step 3 without re-spawning `@attack-kitty`. A verdict older than the claim graded different work and never closes this one.

- **Discipline (what counts as proof):** Done = a reproducible acceptance command or procedure a non-author can run. Evidence is captured whole — full output to a file, then read the file; truncating in transit is how false greens survive. Acceptance for automation is produced by the automation's own trigger path — a human-fired rehearsal proves the handler, not the system. Local green is not CI green.
- **Discipline (narrow exemption):** work whose Done When a deterministic check fully adjudicates — a green fixture suite, linter, byte-level diff — may close on that check's captured output, noted in the closing comment without spawning a validator. Never on `build`-labeled tickets: charter conformance is not deterministically adjudicable, so a build ticket always spawns its validator. When in doubt, it is not exempt.
- **Discipline (the Objective is not negotiable here):** validator or session feedback that would change the Objective is not a verdict input — it routes to the operator.

### `resolve` — the close for decision-type map children

Never a door for `build` (or any templated) tickets — those close through `mark_done` only.

- **Guard:** the ticket must be a map child carrying a decision-type label — `research`, `grilling`, `prototype`, or `task`. Anything else → refuse: "resolve closes decision tickets; use mark_done." Verify via `@linear` read.
- **`research`:** called by the researcher itself at contract completion (fire-and-forget) — the researcher invokes this playbook directly, not through a caller. Verify a findings document exists AND a resolution comment exists (delegate to `@linear`: `read documents`, `read comments`); either missing → refuse with what's missing. No validator — the ruled exception: research's trial is consumption. The map session audits receipts and copies the gist into Decisions-so-far at its next visit; a decision verifies the claims it rests on before resting on them.
- **`grilling` / `prototype` / `task`:** HITL types — the resolution emerged with the operator in the exchange; her presence is the check. Verify a resolution comment exists (delegate to `@linear`) → transition. The caller indexes into Decisions-so-far per wayfinder's work-through.
- Then delegate to `@linear`: `resolve <id>` (the mechanical action — `stateId=Done`).

## What this playbook does NOT do

- Does NOT open the loop — claim (via `work-frontier.md`'s orchestration, or an operator-named `@linear claim`) precedes both verbs; its pre-checks are what `mark_done`'s Step 0 re-verifies.
- Does NOT execute a Linear mutation directly — every state change and comment routes through `@linear`; this playbook holds the protocol, not the API calls.
- Does NOT close maps — `close-map.md` orchestrates the ending and calls through `@linear`'s guarded map lane as its final gate.
