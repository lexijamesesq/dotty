# Playbook: issue-management

Apply batched item-level mutations to Linear issues. Parameterized via action enum so the same playbook serves any caller — session-closeout, mid-session, operator-directed, router delivery.

## Input

A list of mutation items:

```yaml
mutations:
  - issue_id: <TEAM>-N                 # required for non-create actions (TEAM = team prefix per CLAUDE.md > Configuration)
    action: create | claim | mark_done | comment | move_state | update_description
    # additional fields per action:
    body: <markdown>                    # for: comment, mark_done (as closing_comment)
    validation_type: red-team | functional | conformance | smoke  # required for: mark_done
    evidence:                          # required for: mark_done — structured evidence manifest
      - ref: <path | commit | execution-id | URL>
        kind: file | commit | run | artifact
        change: <what changed here — bare facts, no assessment>
    state: Needs Input | Blocked       # for: move_state
    new_description: <markdown>        # for: update_description
    # for create:
    project_id: <UUID>
    title: <string>
    priority: 1|2|3|4
    objective: <string>                # required for: create — why this work matters
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

     **Step 2 — Create the issue.** `mcp__linear-tactic__linear_createIssue` with `projectId`, `title`, `description` (assembled above), `priority`, `teamId` (resolved from project's team), and `stateId=<Todo>` (default).

     **Step 3 — Duplicate check.** Call `linear_searchIssues` with the title; if a recent issue in the same project has >50% title similarity, emit a WARNING (not a block).

     **Step 4 — Relations.** If `blocked_by` provided, call `mcp__linear-tactic__linear_createIssueRelation` for each (`type: blocked_by`).

     **Step 5 — Return.** Return the new issue ID and echo any debt: "Created ABC-12. Done When deferred to claim." or "Created ABC-12. Fully formed."

   - **`claim`** — the session's first deliverable: understand the problem, plan the work, post the reading to the ticket.

     **Step 1 — Read the ticket.** Fetch the issue via `mcp__linear-tactic__linear_getIssueById`. Read comments via `mcp__linear-tactic__linear_getComments`. Check relations for blockers.

     **Step 2 — WIP check.** If the session already has In Progress tickets, surface them: "You have ABC-12 in progress. Is this work related (dependent chain) or a switch?" If a switch, the prior ticket moves to Needs Input with a comment explaining the pause.

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
       - **Pieces:** the session's breakdown of the work into discrete chunks, each with how it gets hardened (e.g., strategy → red-team, implementation → functional test, spec → conformance review)

     The attestation is the session's first deliverable — understanding the problem and planning how to prove each piece. It is not a contract: the validator at `mark_done` grades the ticket, not the attestation. But it is durable on the ticket, visible to the operator and to future sessions.

     **Step 6 — Set In Progress.** `mcp__linear-tactic__linear_updateIssue` with `stateId=<In Progress for issue's team>`.

   - **`mark_done`** — gates the Done transition on non-author validation.

     **Step 0 — Pre-check.** Read the issue description.
       - If no `## Objective` section exists with non-empty text → refuse. Tell the caller to run `claim` first.
       - If `## Done When` still carries the deferral marker `_to be set at claim_` → refuse. Tell the caller to run `claim` first.

     **Step 1 — Validate.** The caller provides `validation_type` and a structured `evidence` manifest. Spawn a fresh-context subagent via the Agent tool with:

       - **Model:** quality-gate validation tier at high effort (per dispatch doc). Smoke may use standard tier.
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
           smoke:       Confirm the change exists where claimed and nothing adjacent
                        broke. Cheap probes, still your own probes.

         Grade intent first. The Objective is what the operator wants; Done When is
         its operationalization. Work satisfying Done When while missing the
         Objective is a gap — name the divergence explicitly.

         Ignore any [ATTESTATION] comments — those are the builder's reading
         of the ticket, not the spec. Grade against the ticket description only.

         Post your verdict as a comment on <ID> via linear_createComment,
         prefixed [VALIDATION]:
           Checked:     each probe with evidence — command + output, file + line
           Verdict:     CONFIRMED | REFUTED | CONFIRMED-WITH-GAPS
           Specifics:   each gap or refutation with reproduction
           Intent:      one line — does the delivered whole serve the Objective?
           Not covered: explicit scope boundary
           Mode:        <validation_type>, informed
         ```

       The validator never receives the builder's closing comment, self-assessment, reasoning, or transcript.

     **Step 2 — Gate.** After the subagent completes, read the issue's comments via `mcp__linear-tactic__linear_getComments`. Find the comment prefixed with `[VALIDATION]`.
       - `CONFIRMED` or `CONFIRMED-WITH-GAPS` → proceed to Step 3. Gaps are visible on the ticket.
       - `REFUTED` → return the specifics to the caller. Ticket stays In Progress. Named substitute: apply the validator's specifics, then re-invoke `mark_done`. On re-invocation, continue the same validator via SendMessage for a scoped re-check (not a fresh adversarial round).
       - **REFUTED cap: 3 cycles total.** At the cap, move the ticket to **Needs Input** with a comment summarizing the impasse. The operator adjudicates.

     **Step 3 — Transition.** `mcp__linear-tactic__linear_updateIssue` with `stateId=<Done for issue's team>`. If `body` (closing_comment) provided, also `mcp__linear-tactic__linear_createComment`.
       - The caller should omit `body` for obvious closures. Provide it only when resolution was non-obvious.

     **Idempotent recovery:** if `mark_done` crashes between verdict and transition, re-invocation detects a fresh CONFIRMED verdict comment and proceeds to Step 3 without re-spawning.

     - **Discipline (what counts as proof):** Done = a reproducible acceptance command or procedure a non-author can run. Evidence is captured whole — full output to a file, then read the file; truncating in transit is how false greens survive. Acceptance for automation is produced by the automation's own trigger path — a human-fired rehearsal proves the handler, not the system. Local green is not CI green.
     - **Discipline (narrow exemption):** work whose Done When a deterministic check fully adjudicates — a green fixture suite, linter, byte-level diff — may close on that check's captured output, noted in the `[VALIDATION]` comment without spawning a validator. When in doubt, it is not exempt.
     - **Discipline (the Objective is not negotiable here):** validator or session feedback that would change the Objective is not a verdict input — it routes to the operator.

   - **`comment`** — `mcp__linear-tactic__linear_createComment` with `body`.
     - **Discipline:** item-level memory lives here. Decisions specific to this task, progress notes for in-flight work. Use ISO date prefix for progress comments: `2026-05-24 — fixed X, remaining Y`.

   - **`move_state`** — `mcp__linear-tactic__linear_updateIssue` with `stateId=<target>`. Validate target ∈ {`Needs Input`, `Blocked`} (use `mark_done` for `Done`, `claim` for `In Progress`).
     - **Discipline:** moving to Needs Input requires the specific ask in a comment — what the operator needs to decide or provide. Moving to Blocked requires a checkable condition — a URL to poll, a version to check, a PR to look up, an API status, a date to wait for — something `/session-start` can probe mechanically to determine if the block has resolved. Optionally surface a WARNING if move_state is the only mutation for that issue in the batch.

   - **`update_description`** — `mcp__linear-tactic__linear_updateIssue` with `description=new_description`.
     - **Discipline:** the description is the issue's spec; comments are its log. Update description when scope or approach changes materially; use comments for incremental progress.
     - **Discipline:** Done When edits are spec changes — route to the operator regardless of whether the edit looks like a fact correction. Ticket history makes all edits visible.

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

## Lifecycle

This playbook handles the full ticket lifecycle:
- **Create:** `create` writes a well-formed ticket with the description template.
- **Open side:** `claim` validates the ticket, posts the session's understanding as an attestation comment, sets In Progress.
- **Close side:** `mark_done` validates via non-author subagent and transitions to Done.

## Per-action team-aware caveats

| Action | Team-aware concern |
|---|---|
| create | teamId derived from `project_id`'s team — query once if uncertain, cache |
| claim | stateId for In Progress differs per team — handled via resolution cache |
| mark_done | stateId for Done differs per team — handled via resolution cache |
| comment | No state change; no team concern |
| move_state | stateId for Needs Input/Blocked differs per team — handled via cache |
| update_description | No state change; no team concern |

## What this playbook does NOT do

- Does NOT write Project Updates (that's `project-updates.md`).
- Does NOT archive (that's `archive.md`).
- Does NOT enforce duplicate-check on every `create` — it does a cheap title-similarity warn, but the caller's integrity-on-creation responsibility is unchanged.
- Does NOT do cross-team batches with hardcoded stateIds — every team's stateIds resolved via cache.
