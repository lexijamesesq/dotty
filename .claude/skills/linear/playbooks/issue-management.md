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
    state: Needs Input | Blocked | Todo | Done  # for: move_state (Done = map lane only, guarded; Todo = return a confirmed park to the frontier)
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

     **Step 4.5 — Late-cut build children.** A `build` child created under a map whose charter document already carries the FINALIZED marker (probe: `linear_getIssueDocuments` on the parent map, check the marker) gets the `ready-for-agent` label at create — the lane stays open for slices cut after finalization; without this, a late-cut slice is permanently untakeable.

     **Step 5 — Map-open (map-labeled creates only).** After creating an issue that carries the `map` label: set `stateId=<In Progress>` and `assigneeId=<the operator>` via `mcp__linear-tactic__linear_updateIssue` — the effort is live from charting, and this is the one ruled exception to assignee-is-the-operator's-field (system-placed effort ownership). No delegate, ever — maps are never claimed.

     **Step 6 — Return.** Return the new issue ID and echo any debt: "Created ABC-12. Done When deferred to claim." or "Created ABC-12. Fully formed."

   - **`claim`** — set the claim (stored in the delegate field) with the discipline the ticket's shape demands.

     **Step 0 — Select the variant.** Fetch the issue via `mcp__linear-tactic__linear_getIssueById`. The issue itself carrying the `map` label → refuse: maps are never claimed — map close is `move_state`'s map lane. Claim requires state Todo unless the caller passes `operator_directed: true`.

     **Mapped-ticket check (direct pickups).** If the fetched issue has a `parent`, fetch the parent (once — cache it) and check its labels — a `map` label makes this a map child. Mapped → announce it ("mapped ticket — child of <parent title>, type <label>") and, unless this session is already running **the map that is this ticket's parent** (wayfinder's own flows invoke claim from inside work-through and charting), do NOT complete a bare claim here: surface the wayfinder invocation to the operator — "run `/wayfinder`, work the map with this ticket named" — since wayfinder is operator-invoked; the map's flow then claims it under the right discipline (per wayfinder). **Exception: a `build` child labeled `ready-for-agent`** — proceed with the build variant; the claiming session becomes the ticket's conductor (invokes `/conduct`), no map session required. A closed or canceled parent → surface, don't route: "mapped to a closed map — needs disposition." Parent without a `map` label = an ordinary sub-task; no parent = standalone — both announce "un-mapped ticket — standard lifecycle" and run the full variant below.

     Selector — parent + type label:
       - Parent is `map`-labeled + type label `research`/`prototype`/`grilling`/`task` → **map-child variant**: skip Steps 1–5; go straight to Step 6 (delegate-set + In Progress, read-back verified). The ticket body is the brief; no attestation.
       - Parent is `map`-labeled + type label `build` → **build variant**: verify the ticket's full contract — `## Objective` present; `## Done When` concrete with its three components (automated claims with checks attached, manual items or "none", the validation mandate); Context carries the charter's pinned document id — fetch it (`linear_getDocumentById`) and verify the FINALIZED marker stands, which also proves the pin resolves (a dropped marker means the charter was edited without operator direction); the `ready-for-agent` label present; and the parent map carries no open `[CHALLENGE]`-prefixed comment — open = no `[CHALLENGE-RESOLVED]` reply follows it (fetch the map's comments — a challenged charter halts dispatch on its build tickets until the operator adjudicates). Anything missing → refuse: move to Needs Input with a comment naming what's missing ("malformed build ticket — route to the map session"; for a challenge: "charter under challenge — operator adjudicates"). Verified → read the ticket's comments (a parking note names the conduct re-entry step), then Step 6.
       - Conflict cells, all refuse with a routing comment + Needs Input: `build` label with a `## Question` body; a map child with no type label; a `build` label on a ticket with no map parent.
       - No map parent → **full variant**: Steps 1–6 below, unchanged.

     Regardless of variant: announce a `model:*` label when present; if this session will author the work itself and its own model mismatches the label (class — or exact version when pinned), surface to the operator before any work: proceed here or relaunch at the labeled model. Headless, park at Needs Input per the standard routing.

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

     **Step 6 — Set In Progress.** The claim is one GraphQL mutation: resolve the claiming app actor's id via `mcp__linear-tactic__linear_getViewer`, then set `stateId=<In Progress for issue's team>` and `delegateId=<viewer id>` together, atomically — self-delegation is the claim. `delegateId` isn't exposed by the tactic MCP, so issue this as a raw `issueUpdate` mutation against Linear's GraphQL endpoint, authenticated with the app token — retrieve the `linear.app_token_ref` reference with the command at `secrets.op_read` (both via global CLAUDE.md > Configuration; bare `op` hits the desktop-approval path and fails unattended); never a literal secret path in skill text (public repo). The `assignee` field is never touched by claim — it belongs to the operator (her personal holds and accountability).
       - **Read-back verify (the race check):** `issueUpdate` is last-write-wins, so after the write, re-fetch the delegate. Not this session's actor → a concurrent session won the claim; back off and report — never proceed on a lost race.
       - **Discipline (delegation is the claim):** the delegate is the claim; an In Progress ticket with no delegate is a data error to surface — with one exception: an issue that ITSELF carries the `map` label. In Progress with no delegate is the map's normal signature (maps are never claimed); the rule stands for everything else, including map children.

   - **`mark_done`** and **`resolve`** — the closure verbs; protocols in `playbooks/closing.md` (mark_done's non-author validation gate, resolve's decision-ticket close). Fields ride this playbook's mutation schema.

   - **`cancel`** — closure for work that won't be done. `body` (reason) required; `mcp__linear-tactic__linear_updateIssue` with `stateId=<Canceled>` + reason comment; optional `related_id` → `duplicate_of` relation.

   - **`add_relation`** — `mcp__linear-tactic__linear_createIssueRelation` (`type: blocked_by`) between `issue_id` and `related_id`. Second-pass edge wiring for map children (issues need ids before they can reference each other).

   - **`attach_document`** — create OR update: with `document_id`, `mcp__linear-tactic__linear_updateDocument` (the pin stays stable across draft → finalized → amended); without, `mcp__linear-tactic__linear_createDocument` on the issue with `document.title` + `document.content`. When `finalized: true` (the charter, after operator sign-off): append the marker block — `**FINALIZED** — <ISO date> — operator sign-off recorded` — and return the document id as the pin the gate requires. When the finalized document is a map's build charter, the same act applies the `ready-for-agent` label to the map's `build` children — finalization opens the build lane. Updating a finalized document removes its marker unless the update is operator-directed (amendments re-finalize, same pin).

   - **`archive_document`** — `mcp__linear-tactic__linear_archiveDocument` with `document_id`; post a comment with the retained link (charter retirement at map close).

   - **`comment`** — `mcp__linear-tactic__linear_createComment` with `body`.
     - **Discipline:** item-level memory lives here. Decisions specific to this task, progress notes for in-flight work. Use ISO date prefix for progress comments: `2026-05-24 — fixed X, remaining Y`.

   - **`move_state`** — `mcp__linear-tactic__linear_updateIssue` with `stateId=<target>`. Validate target ∈ {`Needs Input`, `Blocked`, `Todo`, `Done`} (use `mark_done` for `Done`, `claim` for `In Progress`) — with the map lane as the one exception, both directions:
     - **Map lane (issues carrying the `map` label only):** `Done` is permitted, guarded — a `[VALIDATION]`-prefixed comment posted by the dispatched non-author e2e eval carrying verdict `CONFIRMED` in the standard vocabulary (any other verdict — including `CONFIRMED-WITH-GAPS` — routes to the operator), zero open children, the accounting document present, the charter archived. Verify all four; any missing → refuse. Park states (`Needs Input`, `Blocked`) are REFUSED for maps — a wedged map is reported by the sweep, never parked; map states are exactly In Progress → Done.
     - **Parks release the claim.** Moving to Needs Input OR Blocked clears the claim (`delegateId: null` via the GraphQL bridge) and posts resume state — the claim marks active work only; a parked ticket is re-claimable by any later session once returned to the frontier.
     - **Todo** returns a park to the frontier — the map sweep's un-park step, or any session acting on the operator's confirmation; the claim should already be cleared — if not, surface it.
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

The entry point for parallel sessions: point a session at a project (or a specific map's build lane), get the next ticket claimed and driven to Done without hand-assignment. In wayfinder's spirit — never resolve more than one ticket per session.

**Input:** `project_id` (UUID) OR `map_id` (issue identifier). Exactly one required.

**Protocol:**
1. **Read the frontier.**
   - **Project scope** (`project_id`): Query Linear's GraphQL endpoint directly for the project — same bridge and token reference as claim Step 6 (`linear.app_token_ref`), since `delegate` isn't exposed by the tactic MCP: `issues(filter: { project: { id: { eq: <project_id> } }, delegate: { null: true }, state: { type: { eq: "unstarted" } } })` — the filter runs server-side, returning the correct takeable set directly. Then narrow client-side to `assignee: null`, no open `blocked_by` relation, no `map` label, **and no map-labeled parent** — fetch each unique parent once per scan (cache, like stateIds) and check its labels; a child of a `map`-labeled issue belongs to map sessions (`read map-frontier`), never to this flow, while an ordinary sub-task stays takeable — **except a `build` child labeled `ready-for-agent`, which is takeable here: its claim runs the build variant and the session becomes the ticket's conductor** (SKILL.md > Cross-cutting > Frontier convention).
   - **Map scope** (`map_id`): Fetch the map issue, verify it carries the `map` label — if not, refuse: "issue `<map_id>` is not a map; use `project_id` for project-scoped frontier." Query its children (`issues(filter: { parent: { id: { eq: <map_uuid> } }, delegate: { null: true }, state: { type: { eq: "unstarted" } } })`), then narrow client-side to `assignee: null`, no open `blocked_by` relation, and labeled `ready-for-agent` + `build` — only finalized build children are takeable via this scope. Non-build map children are never takeable here (they route through wayfinder's map session). Steps 2–7 proceed identically.
2. **Empty frontier.** Nothing takeable → report "no takeable work for `<scope>`" and stop.
3. **Pick the top ticket.** Order by priority (Urgent → Low), then by `createdAt` ascending (oldest first) as tiebreak.
4. **Claim it.** Run the `claim` action above, unmodified — Step 2's WIP check is trivially clear on a fresh frontier session (no claims made yet this conversation).
   - If claim proceeds to In Progress → go to Step 5.
   - If claim instead routes the ticket to Needs Input (deferred or missing Done When, per claim Step 3) → that's not a claim. Return to Step 3 and pick the next takeable ticket. **Cap: 3 consecutive Needs Input routings.** At the cap, stop and surface the pattern — a frontier that keeps routing to the operator is a triage signal, not a work queue.
5. **Run it.** Work the claimed ticket's pieces proof-first — each piece named by its proof, the proof existing completes it. A `build` ticket routes to conduct instead: the claim's build variant made this session its conductor — invoke `/conduct` and run its loop; the conductor authors nothing.
6. **Close it.** Run the `mark_done` action (`playbooks/closing.md`), unmodified.
7. **Stop.** One ticket per frontier session (one successfully claimed and run). The pull to continue to a second ticket is the signal to end the session, not to loop back to Step 1.

**Discipline:** this flow does not change `claim` or `mark_done` — it sequences them for one scoped, picked-not-named ticket (project-wide or map-specific). The operator-named single-session claim flow (caller supplies `issue_id` directly) is untouched.

## What this playbook does NOT do

- Does NOT write Project Updates (that's `project-updates.md`).
- Does NOT archive (that's `archive.md`).
- Does NOT do cross-team batches with hardcoded stateIds — every team's stateIds resolved via cache.
