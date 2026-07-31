# Playbook: issue-management

Apply batched item-level mutations to Linear issues. Parameterized via action enum so the same playbook serves any caller — session-closeout, mid-session, operator-directed, router delivery.

## Input

A list of mutation items:

```yaml
mutations:
  - issue_id: <TEAM>-N                 # required for non-create actions (TEAM = team prefix per CLAUDE.md > Configuration)
    action: create | claim | mark_done | resolve | cancel | comment | move_state | update_description | add_relation | attach_document | archive_document
    # additional fields per action:
    body: <markdown>                    # for: comment, mark_done (as closing_comment), cancel (reason — required)
    validation_type: red-team | functional | conformance | consistency | smoke  # required for: mark_done
    charter_doc_id: <document id>       # required for: mark_done on `build`-labeled tickets — the pinned, finalized charter
    related_id: <issue_id>              # for: add_relation (blocked_by), cancel (optional duplicate_of)
    document: { title, content, finalized: true|false }  # for: attach_document; finalized writes the FINALIZED marker block
    document_id: <id>                   # for: archive_document; for attach_document = update-in-place (pin stays stable)
    operator_directed: true|false       # for: claim — permits claiming a non-Todo ticket at the operator's direction
    evidence:                          # required for: mark_done — structured evidence manifest
      - ref: <path | commit | execution-id | URL>
        kind: file | commit | run | artifact
        change: <what changed here — bare facts, no assessment>
    state: Needs Input | Blocked | Todo  # for: move_state (Todo = return a confirmed park to the frontier)
    new_description: <markdown>        # for: update_description
    # for create:
    project_id: <UUID>
    title: <string>
    priority: 1|2|3|4
    parent_id: <issue UUID>            # optional — creates a sub-issue (map children)
    objective: <string>                # required for: create — unless `question` is given (XOR)
    question: <string>                 # map-children variant: body becomes `## Question`; requires parent_id + a type label
    done_when: [<string>, ...]         # optional for: create — deferred by default if omitted
    constraints: [<string>, ...]       # optional for: create
    context: [<string>, ...]           # optional for: create — links/pointers
    labels: [<label name>, ...]        # optional
    blocked_by: [<issue_id>, ...]      # optional — created as Linear relation
```

## Protocol

1. **Resolve teams + stateIds.** For each unique team prefix in the batch, look up the team UUID in global CLAUDE.md > Configuration (prefix→UUID mapping). Call `mcp__linear-tactic__linear_getWorkflowStates` ONCE per unique team and cache the stateId map. Don't re-resolve per mutation. Don't hardcode prefixes or UUIDs in this playbook.

2. **Apply each mutation in order:**

   - **`create`** — write a well-formed ticket with the description template.

     **Question-shaped map children:** when `question` is given (XOR with `objective` — refuse if both or neither), require `parent_id` and a type label; the description is just `## Question` + the question text with its directives. Skip the template below and the duplicate check (map siblings share phrasing by nature; the warn would always fire). Everything else — creation, labels, relations — proceeds identically. `build` tickets are NOT question-shaped: they use the standard template (Objective = the slice; Done When = the proof).

     **Step 1 — Build the description.** Assemble from the caller's input:

     ```markdown
     ## Objective

     <objective — required>

     ## Done When

     <done_when conditions, one per line — OR the default deferral marker if not provided:>
     _to be set at claim_

     ## Constraints

     <constraints, one per line — omit this section entirely if empty>

     ## Context

     <context links, one per line — omit this section entirely if empty>
     ```

     When the caller provides `done_when`, write the conditions. When the caller omits it, write the deferral marker `_to be set at claim_` — honest incompleteness, not fake precision.

     When the operator directed the work, her verbatim words go into Context — her words are what the validator grades intent against.

     **Step 2 — Create the issue.** `mcp__linear-tactic__linear_createIssue` with `projectId`, `title`, `description` (assembled above), `priority`, `teamId` (resolved from project's team), `parentId` when given (sub-issue — live-probed capability), and `stateId=<Todo>` (default).

     **Step 3 — Duplicate check.** Call `linear_searchIssues` with the title; if a recent issue in the same project has >50% title similarity, emit a WARNING (not a block).

     **Step 4 — Relations.** If `blocked_by` provided, call `mcp__linear-tactic__linear_createIssueRelation` for each (`type: blocked_by`).

     **Step 5 — Return.** Return the new issue ID and echo any debt: "Created ABC-12. Done When deferred to claim." or "Created ABC-12. Fully formed."

   - **`claim`** — set the delegate (the claim) with the discipline the ticket's shape demands.

     **Step 0 — Select the variant.** Fetch the issue via `mcp__linear-tactic__linear_getIssueById`. Claim requires state Todo unless the caller passes `operator_directed: true`. Selector — parent + type label:
       - Parent is `map`-labeled + type label `research`/`prototype`/`grilling`/`task` → **map-child variant**: skip Steps 1–5; go straight to Step 6 (delegate-set + In Progress, read-back verified). The ticket body is the brief; no attestation.
       - Parent is `map`-labeled + type label `build` → **build variant**: verify `## Objective` present and `## Done When` concrete (the proof, named at cutting). Missing or deferred → refuse: move to Needs Input with a comment ("malformed build ticket — proof missing; route to the map session"). Verified → Step 6 only.
       - Conflict cells, all refuse with a routing comment + Needs Input: `build` label with a `## Question` body; a map child with no type label; a `build` label on a ticket with no map parent.
       - No map parent → **full variant**: Steps 1–6 below, unchanged.

     **Step 1 — Read the ticket.** Read comments via `mcp__linear-tactic__linear_getComments`. Check relations for blockers.

     **Step 2 — WIP check.** Scoped to claims *this session* made — tickets this conversation has itself claimed. A sibling session's In Progress ticket isn't a switch candidate — the frontier (SKILL.md > Cross-cutting > Frontier convention) already excludes it. If this session has already claimed a ticket, surface it: "You have ABC-12 in progress (claimed this session). Is this work related (dependent chain) or a switch?" If a switch, the prior ticket moves to Needs Input with a comment explaining the pause.

     **Step 3 — Understand the problem.** Parse the description for the four sections:

     **Objective:** must be present and non-empty.
       - Present and current → proceed.
       - Present but stale or missing → propose an update as a comment on the ticket and route to the operator. The Objective is what the validator grades intent against — it carries the same authority as Done When.

     **Done When:** the operator's spec — what the work is measured against.
       - Concrete conditions present → these are the spec. Quote them verbatim in the attestation.
       - Deferral marker present (`_to be set at claim_`) or missing → propose conditions as a comment on the ticket, move the ticket to Needs Input, stop. Do not proceed to Steps 5-6. When the operator confirms, a new `claim` invocation picks up the ticket with hardened conditions.

     **Constraints and Context:** review for currency.

     **Objective and Done When edits are spec changes.** Any edit to either — by any action, at any point in the lifecycle — routes to the operator. The session does not self-classify edits as fact corrections vs. intent changes.

     **Step 4 — Size the ticket.** If Done When contains multiple independently shippable outcomes, apply the **Too Big** label and propose a decomposition to the operator.

     **Step 5 — Post the attestation.** Post a comment on the ticket via `mcp__linear-tactic__linear_createComment` with prefix `[ATTESTATION]`:

       - **Objective:** one-line restatement of what the work achieves
       - **Done When:** quoted verbatim from the ticket
       - **Pieces:** the session's breakdown of the work, each piece named by the proof that will complete it and the seam where that proof gets observed — `<piece> — proven when <proof> at <seam>`. A piece with no named proof isn't a piece yet.

     The pieces run proof-first — the proof is named before the piece is built, and the proof existing is what completes it. This section is the plan for the middle, written before the middle starts.

     **The seams are the operator's beat.** When she's in the session, put them to her before the work starts and adjust to her answer — the validation plan is hers to agree, and after that the middle is the session's to run. Headless, the attestation declares the seams and they stand visible on the ticket.

     Each piece's proof becomes a dated progress comment naming its artifact; that accumulation is the `evidence` manifest `mark_done` requires. The validator there grades the ticket's Done When, not the attestation.

     **Step 6 — Set In Progress.** The claim is one GraphQL mutation: resolve the claiming app actor's id via `mcp__linear-tactic__linear_getViewer`, then set `stateId=<In Progress for issue's team>` and `delegateId=<viewer id>` together, atomically — self-delegation is the claim. `delegateId` isn't exposed by the tactic MCP, so issue this as a raw `issueUpdate` mutation against Linear's GraphQL endpoint, authenticated with the app token — resolve it via global CLAUDE.md > Configuration (`linear.app_token_ref`); never a literal secret path in skill text (public repo). The `assignee` field is never touched by claim — it belongs to the operator (her personal holds and accountability).
       - **Read-back verify (the race check):** `issueUpdate` is last-write-wins, so after the write, re-fetch the delegate. Not this session's actor → a concurrent session won the claim; back off and report — never proceed on a lost race.
       - **Discipline (delegation is the claim):** the delegate is the claim; an In Progress ticket with no delegate is a data error to surface.

   - **`mark_done`** — gates the Done transition on non-author validation.

     **Step 0 — Pre-check.** Read the issue description.
       - If no `## Objective` section exists with non-empty text → refuse. Tell the caller to run `claim` first.
       - If `## Done When` still carries the deferral marker `_to be set at claim_` → refuse. Tell the caller to run `claim` first.

     **Step 0.5 — Charter input (`build`-labeled tickets only).** The caller provides `charter_doc_id` — the pinned id of the finalized build charter. The validator fetches it via `mcp__linear-tactic__linear_getDocumentById` ONLY — never via the map issue (the map body and its comments carry live, unadjudicated builder material). The document must carry the `FINALIZED` marker block; absent → refuse the whole mark_done: the charter isn't finalized, nothing closes against it.

     **Admission test (written law, not precedent):** an artifact may join the ticket description in the validator's inputs only if it is (a) operator-finalized as a whole document, (b) adversarially attacked as that exact artifact, (c) frozen before the ticket's work began, (d) delivered as a pinned version reference. Today exactly one artifact passes: the finalized build charter. Research findings, decision tickets, and the map body all fail — nothing else joins, ever.

     **Step 1 — Validate.** The caller provides `validation_type` and a structured `evidence` manifest. Spawn a fresh-context subagent via the Agent tool with:

       - **Model:** quality-gate validation tier at high effort (per dispatch doc). Smoke may use standard tier — tier follows the mandate's reasoning depth, not budget.
       - **Distance:** informed — receives the charter and evidence, never the builder's reasoning or self-assessment.
       - **Prompt:**

         ```
         You are validating ticket <ID> against its charter. You had no part in
         producing this work. Your mandate is to refute, not confirm.

         Charter (verbatim from the ticket, written before the work):
           Objective:   <verbatim from ## Objective>
           Done When:   <verbatim from ## Done When>
           Constraints: <verbatim from ## Constraints>

         Evidence manifest (locations only — verify everything yourself):
           <ref> — <kind> — <change>
           ...

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

         For build tickets, the finalized charter (provided by pinned document id)
         is spec alongside the ticket. The charter is self-sufficient: if grading a
         claim requires detail it doesn't carry, report a charter-distillation gap —
         do not fetch decision tickets, the map, or anything else. Work satisfying
         Done When but contradicting a charter claim is neither CONFIRMED nor
         REFUTED — report CHARTER-CONFLICT with the receipt. There is no silent
         precedence between Done When and the charter; that conflict is the
         operator's to adjudicate.

         Ignore any [ATTESTATION] comments — those are the builder's reading
         of the ticket, not the spec. Grade against the ticket description only.

         Post your verdict as a comment on <ID> via linear_createComment,
         prefixed [VALIDATION]:
           Checked:     each probe with evidence — command + output, file + line
           Verdict:     CONFIRMED | REFUTED | CONFIRMED-WITH-GAPS | CHARTER-CONFLICT
           Specifics:   each gap or refutation with reproduction
           Intent:      one line — does the delivered whole serve the Objective?
           Not covered: explicit scope boundary
           Mode:        <validation_type>, informed
         ```

       The validator never receives the builder's closing comment, self-assessment, reasoning, or transcript.

     **Step 2 — Gate.** After the subagent completes, read the issue's comments via `mcp__linear-tactic__linear_getComments`. Find the comment prefixed with `[VALIDATION]`.
       - `CONFIRMED` or `CONFIRMED-WITH-GAPS` → proceed to Step 3. Gaps are visible on the ticket.
       - `REFUTED` → return the specifics to the caller. Ticket stays In Progress. Named substitute: apply the validator's specifics, then re-invoke `mark_done`. On re-invocation, continue the same validator via SendMessage for a scoped re-check (not a fresh adversarial round).
       - `CHARTER-CONFLICT` → never the fix-worker loop: move the ticket to **Needs Input** with the receipt, release the delegate, post resume state. The operator adjudicates — a validator's judgment is not a changed-fact receipt and cannot fell a settled claim.
       - **REFUTED cap: 3 cycles total.** At the cap, move the ticket to **Needs Input** with a comment summarizing the impasse, **release the delegate, and post resume state** (any park releases the claim). The operator adjudicates.

     **Step 3 — Transition.** `mcp__linear-tactic__linear_updateIssue` with `stateId=<Done for issue's team>`. If `body` (closing_comment) provided, also `mcp__linear-tactic__linear_createComment`.
       - The caller should omit `body` for obvious closures. Provide it only when resolution was non-obvious.

     **Idempotent recovery:** if `mark_done` crashes between verdict and transition, re-invocation detects a fresh CONFIRMED verdict comment and proceeds to Step 3 without re-spawning.

     - **Discipline (what counts as proof):** Done = a reproducible acceptance command or procedure a non-author can run. Evidence is captured whole — full output to a file, then read the file; truncating in transit is how false greens survive. Acceptance for automation is produced by the automation's own trigger path — a human-fired rehearsal proves the handler, not the system. Local green is not CI green.
     - **Discipline (narrow exemption):** work whose Done When a deterministic check fully adjudicates — a green fixture suite, linter, byte-level diff — may close on that check's captured output, noted in the `[VALIDATION]` comment without spawning a validator. When in doubt, it is not exempt.
     - **Discipline (the Objective is not negotiable here):** validator or session feedback that would change the Objective is not a verdict input — it routes to the operator.

   - **`resolve`** — the close for decision-type map children. Never a door for `build` (or any templated) tickets — those close through `mark_done` only.
     - **Guard:** the ticket must be a map child carrying a decision-type label — `research`, `grilling`, `prototype`, or `task`. Anything else → refuse: "resolve closes decision tickets; use mark_done."
     - **`research`:** called from the map sweep only — the map session has already spot-checked the findings' receipts and indexed the resolution into Decisions-so-far. Verify a findings document exists (`linear_getIssueDocuments`) AND a resolution comment exists; either missing → refuse with what's missing. No validator — the ruled exception: research's trial is the decision it feeds.
     - **`grilling` / `prototype` / `task`:** HITL types — the resolution emerged with the operator in the exchange; her presence is the check. Verify a resolution comment exists → transition. The caller indexes into Decisions-so-far per wayfinder's work-through.
     - Then transition `stateId=<Done>`.

   - **`cancel`** — closure for work that won't be done. `body` (reason) required; `mcp__linear-tactic__linear_updateIssue` with `stateId=<Canceled>` + reason comment; optional `related_id` → `duplicate_of` relation.

   - **`add_relation`** — `mcp__linear-tactic__linear_createIssueRelation` (`type: blocked_by`) between `issue_id` and `related_id`. Second-pass edge wiring for map children (issues need ids before they can reference each other).

   - **`attach_document`** — create OR update: with `document_id`, `mcp__linear-tactic__linear_updateDocument` (the pin stays stable across draft → finalized → amended); without, `mcp__linear-tactic__linear_createDocument` on the issue with `document.title` + `document.content`. When `finalized: true` (the charter, after operator sign-off): append the marker block — `**FINALIZED** — <ISO date> — operator sign-off recorded` — and return the document id as the pin the gate requires. Updating a finalized document removes its marker unless the update is operator-directed (amendments re-finalize, same pin).

   - **`archive_document`** — `mcp__linear-tactic__linear_archiveDocument` with `document_id`; post a comment with the retained link (charter retirement at map close).

   - **`comment`** — `mcp__linear-tactic__linear_createComment` with `body`.
     - **Discipline:** item-level memory lives here. Decisions specific to this task, progress notes for in-flight work. Use ISO date prefix for progress comments: `2026-05-24 — fixed X, remaining Y`.

   - **`move_state`** — `mcp__linear-tactic__linear_updateIssue` with `stateId=<target>`. Validate target ∈ {`Needs Input`, `Blocked`, `Todo`} (use `mark_done` for `Done`, `claim` for `In Progress`).
     - **Parks release the claim.** Moving to Needs Input OR Blocked releases the delegate (`delegateId: null` via the GraphQL bridge) and posts resume state — the delegate marks active work only; a parked ticket is re-claimable by any later session once returned to the frontier.
     - **Todo** returns a park to the frontier — the map sweep's un-park step, or any session acting on the operator's confirmation; the delegate should already be null — if not, surface it.
     - **Discipline:** moving to Needs Input requires the specific ask in a comment — what the operator needs to decide or provide. Moving to Blocked requires a checkable condition — a URL to poll, a version to check, a PR to look up, an API status, a date to wait for — something `/session-start` can probe mechanically to determine if the block has resolved. Optionally surface a WARNING if move_state is the only mutation for that issue in the batch.

   - **`update_description`** — `mcp__linear-tactic__linear_updateIssue` with `description=new_description`.
     - **Discipline:** the description is the issue's spec; comments are its log. Update description when scope or approach changes materially; use comments for incremental progress.
     - **Discipline:** Objective and Done When edits route to the operator — claim Step 3's lifecycle-wide law. Ticket history makes all edits visible.

3. **Collect results.** If any mutation fails, continue with the rest. Report all results together — caller decides retry/escalation.

## Output

```yaml
results:
  - issue_id: <ID>           # or new_issue_id for create
    action: <action>
    status: success | failure | warning
    warnings: [<string>, ...]
    error: <string if failure>
    new_issue_id: <ID if create succeeded>
```

## Work the frontier

The entry point for parallel sessions: point a session at a project, get the next ticket claimed and driven to Done without hand-assignment. In wayfinder's spirit — never resolve more than one ticket per session.

**Input:** `project_id` (UUID).

**Protocol:**
1. **Read the frontier.** Query Linear's GraphQL endpoint directly for the project — same bridge and token reference as claim Step 6 (`linear.app_token_ref`), since `delegate` isn't exposed by the tactic MCP: `issues(filter: { project: { id: { eq: <project_id> } }, delegate: { null: true }, state: { type: { eq: "unstarted" } } })` — the filter runs server-side, returning the correct takeable set directly. Then narrow client-side to `assignee: null`, no open `blocked_by` relation, no `map` label, **and no parent** — a sub-issue is a map child and belongs to map sessions (`read map-frontier`), never to this flow (SKILL.md > Cross-cutting > Frontier convention).
2. **Empty frontier.** Nothing takeable → report "no takeable work for `<project_id>`" and stop.
3. **Pick the top ticket.** Order by priority (Urgent → Low), then by `createdAt` ascending (oldest first) as tiebreak.
4. **Claim it.** Run the `claim` action above, unmodified — Step 2's WIP check is trivially clear on a fresh frontier session (no claims made yet this conversation).
   - If claim proceeds to In Progress → go to Step 5.
   - If claim instead routes the ticket to Needs Input (deferred or missing Done When, per claim Step 3) → that's not a claim. Return to Step 3 and pick the next takeable ticket. **Cap: 3 consecutive Needs Input routings.** At the cap, stop and surface the pattern — a frontier that keeps routing to the operator is a triage signal, not a work queue.
5. **Run it.** Work the claimed ticket's pieces proof-first — each piece named by its proof, the proof existing completes it.
6. **Close it.** Run the `mark_done` action above, unmodified.
7. **Stop.** One ticket per frontier session (one successfully claimed and run). The pull to continue to a second ticket is the signal to end the session, not to loop back to Step 1.

**Discipline:** this flow does not change `claim` or `mark_done` — it sequences them for one project-scoped, picked-not-named ticket. The operator-named single-session claim flow (caller supplies `issue_id` directly) is untouched.

## What this playbook does NOT do

- Does NOT write Project Updates (that's `project-updates.md`).
- Does NOT archive (that's `archive.md`).
- Does NOT do cross-team batches with hardcoded stateIds — every team's stateIds resolved via cache.
