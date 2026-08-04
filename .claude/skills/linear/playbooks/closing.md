# Playbook: closing

The closure verbs — `mark_done` (gates the Done transition on non-author validation) and `resolve` (the close for decision-type map children). Callers invoke them through the same batched-mutation interface, and the input fields (`validation_type`, `evidence`, `charter_doc_id`, `body`) ride `issue-management.md`'s mutation schema. Team/stateId resolution follows the SKILL.md cross-cutting rules, cached per invocation.

### `mark_done` — gates the Done transition on non-author validation

**Step 0 — Pre-check.** Read the issue description.

- If no `## Objective` section exists with non-empty text → refuse. Tell the caller to run `claim` first.
- If `## Done When` still carries the deferral marker `_to be set at claim_` → refuse. Tell the caller to run `claim` first.
- If `## Done When` names a validation mandate, the caller's `validation_type` must match it → refuse on mismatch; the mandate was named at cutting and is not the closer's to soften.

**Step 0.5 — Charter input (`build`-labeled tickets only).** The caller provides `charter_doc_id` — the pinned id of the finalized build charter. The caller also fetches the parent map's comments before spawning: an open `[CHALLENGE]`-prefixed comment (no `[CHALLENGE-RESOLVED]` reply follows it) → move the ticket to Needs Input, run no gate — in-flight work does not close against a charter under live challenge. (This check is the caller's, pre-spawn; the validator's map quarantine below stands.) The validator fetches the charter via `mcp__linear-tactic__linear_getDocumentById` ONLY — never via the map issue (the map body and its comments carry live, unadjudicated builder material). The document must carry the `FINALIZED` marker block; absent → refuse the whole mark_done: the charter isn't finalized, nothing closes against it.

**Admission test (written law, not precedent):** an artifact may join the ticket description in the validator's inputs only if it is (a) operator-finalized as a whole document, (b) adversarially attacked as that exact artifact, (c) frozen before the ticket's work began, (d) delivered as a pinned version reference. Today exactly one artifact passes: the finalized build charter. Research findings, decision tickets, and the map body all fail — nothing else joins, ever.

**Step 1 — Validate.** The caller provides `validation_type` and a structured `evidence` manifest. Spawn a fresh-context subagent via the Agent tool with:

- **Model:** quality-gate validation tier at high effort (per dispatch doc). Smoke may use standard tier — tier follows the mandate's reasoning depth, not budget.
- **Distance:** informed — receives the charter and evidence, never the builder's reasoning or self-assessment.
- **Prompt:**

  ```
  You are validating ticket <ID> against its charter. You had no part in
  producing this work. Your mandate is to refute, not confirm.

  Ticket spec (verbatim from the ticket, written before the work):
    Objective:   <verbatim from ## Objective>
    Done When:   <verbatim from ## Done When>
    Constraints: <verbatim from ## Constraints>

  Charter document id: <charter_doc_id>
    (The caller includes this block only when the ticket carries the
    `build` label — omitted entirely otherwise.) Fetch the charter via
    linear_getDocumentById; verify the FINALIZED marker yourself.
    Absent, unfetchable, or unmarked → refuse to validate — report it,
    post no verdict.

  Evidence manifest (locations only — verify everything yourself):
    <ref> — <kind> — <change>
    ...

  Before anything else, fetch the ticket yourself and check its labels —
  do not trust the caller's assembly. A `build` label with no "Charter
  document id" block above — or that block present on a ticket without
  the `build` label — means this gate was assembled wrong: refuse to
  validate, report it, post no verdict.

  Mandate (<validation_type>):
    red-team:    Attack the design — find the case it breaks, the assumption
                 it doesn't earn, the input it never considered.
    functional:  Execute the claimed behavior against the real mechanism.
                 A probe that bypasses the component under test proves nothing.
    conformance: Hold the artifact against its governing contract or spec,
                 clause by clause.
    consistency: Hold the artifact against the sibling surfaces its Done When
                 names — single-home, no drift, no orphans, leanness.
                 Admissible ONLY when Done When names the sibling set;
                 otherwise the cut should have used conformance.
    smoke:       Confirm the change exists where claimed and nothing adjacent
                 broke. Existence-and-no-regression probes, scoped to what
                 the Done When requires — still your own probes, not
                 borrowed ones.

  Grade intent first. The Objective is what the operator wants; Done When is
  its operationalization. Work satisfying Done When while missing the
  Objective is a gap — name the divergence explicitly.

  Manual items in Done When require a confirming comment authored by the
  operator's own Linear user. A comment posted by the app actor is the
  builder speaking, not a receipt — required manual items without her
  authored confirmation are unmet → REFUTED.

  For build tickets, the finalized charter (fetched by the document id
  above) is spec alongside the ticket. The charter is self-sufficient: if
  grading a claim requires detail it doesn't carry, report a
  charter-distillation gap as CHARTER-CONFLICT — the charter's sufficiency
  is the operator's to adjudicate, same door — and do not fetch decision
  tickets, the map, or anything else. Work satisfying Done When but
  contradicting a charter claim is neither CONFIRMED nor REFUTED — report
  CHARTER-CONFLICT with the receipt. There is no silent precedence between
  Done When and the charter; that conflict is the operator's to adjudicate.

  Ignore any [ATTESTATION] comments — those are the builder's reading
  of the ticket, not the spec. Grade against the ticket description only.

  Post your verdict as a comment on <ID> via linear_createComment,
  prefixed [VALIDATION]:
    Checked:     each probe with evidence — command + output, file + line
    Verdict:     CONFIRMED | REFUTED | CONFIRMED-WITH-GAPS | CHARTER-CONFLICT
    Specifics:   each gap or refutation with reproduction
    Intent:      one line — does the delivered whole serve the Objective?
    Not covered: explicit scope boundary
    Mode:        <validation_type>, informed — spawn execution id: <your
                 agent/task id, so a self-posted verdict is a visible lie>
  ```

The validator never receives the builder's closing comment, self-assessment, reasoning, or transcript.

**Step 2 — Gate.** After the subagent completes, read the issue's comments via `mcp__linear-tactic__linear_getComments`. Find the newest comment prefixed with `[VALIDATION]`. A verdict whose Mode line carries no spawn execution id is treated as builder-posted — not a verdict; refuse it.

- `CONFIRMED` → proceed to Step 3.
- `CONFIRMED-WITH-GAPS` → resolve each named gap before transition. A gap in the validator's comment is orphaned, not owned — the receiving session fixes it in-session. After all gaps are resolved, re-invoke `mark_done` (same re-check path as REFUTED).
- `REFUTED` → return the specifics to the caller. Ticket stays In Progress. Named substitute: apply the validator's specifics, then re-invoke `mark_done`. On re-invocation, continue the same validator via SendMessage for a scoped re-check (not a fresh adversarial round).
- `CHARTER-CONFLICT` → never the fix-worker loop: move the ticket to **Needs Input** with the receipt, release the claim, post resume state. The operator adjudicates — a validator's judgment is not a changed-fact receipt and cannot fell a settled claim.
- **REFUTED cap: 3 cycles total — counted from the ticket's `[VALIDATION]` REFUTED comments, never from session memory** (a park and re-claim does not reset the count). At the cap, move the ticket to **Needs Input** with a comment summarizing the impasse, **release the claim, and post resume state** (any park releases the claim). The operator adjudicates.

**Step 3 — Transition.** `mcp__linear-tactic__linear_updateIssue` with `stateId=<Done for issue's team>`. If `body` (closing_comment) provided, also `mcp__linear-tactic__linear_createComment`. The caller should omit `body` for obvious closures; provide it only when resolution was non-obvious.

**Idempotent recovery:** if `mark_done` crashes between verdict and transition, re-invocation detects a CONFIRMED verdict comment **newer than the current claim** and proceeds to Step 3 without re-spawning — a verdict older than the claim graded different work and never closes this one.

- **Discipline (what counts as proof):** Done = a reproducible acceptance command or procedure a non-author can run. Evidence is captured whole — full output to a file, then read the file; truncating in transit is how false greens survive. Acceptance for automation is produced by the automation's own trigger path — a human-fired rehearsal proves the handler, not the system. Local green is not CI green.
- **Discipline (narrow exemption):** work whose Done When a deterministic check fully adjudicates — a green fixture suite, linter, byte-level diff — may close on that check's captured output, noted in the `[VALIDATION]` comment without spawning a validator. Never on `build`-labeled tickets: charter conformance is not deterministically adjudicable, so a build ticket always spawns its validator. When in doubt, it is not exempt.
- **Discipline (the Objective is not negotiable here):** validator or session feedback that would change the Objective is not a verdict input — it routes to the operator.

### `resolve` — the close for decision-type map children

Never a door for `build` (or any templated) tickets — those close through `mark_done` only.

- **Guard:** the ticket must be a map child carrying a decision-type label — `research`, `grilling`, `prototype`, or `task`. Anything else → refuse: "resolve closes decision tickets; use mark_done."
- **`research`:** called by the researcher itself at contract completion (fire-and-forget). Verify a findings document exists (`linear_getIssueDocuments`) AND a resolution comment exists; either missing → refuse with what's missing. No validator — the ruled exception: research's trial is consumption. The map session audits receipts and copies the gist into Decisions-so-far at its next visit; a decision verifies the claims it rests on before resting on them.
- **`grilling` / `prototype` / `task`:** HITL types — the resolution emerged with the operator in the exchange; her presence is the check. Verify a resolution comment exists → transition. The caller indexes into Decisions-so-far per wayfinder's work-through.
- Then transition `stateId=<Done>`.

## What this playbook does NOT do

- Does NOT open the loop — `claim` (`issue-management.md`) precedes both verbs; its pre-checks are what mark_done's Step 0 re-verifies.
- Does NOT carry the batch schema — `issue-management.md`'s Input block is the contract; this playbook holds the protocols.
- Does NOT close maps — `close-map` (`playbooks/close-map.md`) orchestrates the ending and calls through `move_state`'s guarded map lane.
