# Playbook: issue-management

Apply batched item-level mutations to Linear issues. Parameterized via action enum so the same playbook serves session-closeout's full surface and mid-session-checkpoint's comment-only subset.

## Input

A list of mutation items:

```yaml
mutations:
  - issue_id: <TEAM>-N                 # required for non-create actions (TEAM = team prefix per CLAUDE.md > Configuration)
    action: mark_done | comment | move_state | create_followup | update_description
    # additional fields per action:
    body: <markdown>                    # for: comment, mark_done (as closing_comment), create_followup (description)
    state: Waiting | Blocked            # for: move_state
    new_description: <markdown>         # for: update_description
    # for create_followup (no issue_id):
    project_id: <UUID>
    title: <string>
    priority: 1|2|3|4
    labels: [<label name>, ...]         # optional
    blocked_by: [<issue_id>, ...]       # optional — created as Linear relation
```

## Protocol

1. **Resolve teams + stateIds.** For each unique team prefix in the batch, look up the team UUID in global CLAUDE.md > Configuration (prefix→UUID mapping). Call `mcp__linear-tactic__linear_getWorkflowStates` ONCE per unique team and cache the stateId map. Don't re-resolve per mutation. Don't hardcode prefixes or UUIDs in this playbook.

2. **Apply each mutation in order:**

   - **`mark_done`** — `mcp__linear-tactic__linear_updateIssue` with `stateId=<Done for issue's team>`. If `body` (closing_comment) provided, also `mcp__linear-tactic__linear_createComment`.
     - **Discipline:** add a closing comment ONLY if resolution was non-obvious (rejected approach, surprising root cause, decision specific to this task). Skip the comment for obvious closures ("fixed the typo").

   - **`comment`** — `mcp__linear-tactic__linear_createComment` with `body`.
     - **Discipline:** item-level memory lives here. Decisions specific to this task, progress notes for in-flight work. Use ISO date prefix for progress comments: `2026-05-24 — fixed X, remaining Y`.

   - **`move_state`** — `mcp__linear-tactic__linear_updateIssue` with `stateId=<target>`. Validate target ∈ {`Waiting`, `Blocked`} (use `mark_done` for `Done`).
     - **Discipline:** moving to Waiting/Blocked requires the caller to ALSO provide context about resolver + trigger (typically via a separate `comment` mutation in the same batch, or `update_description`). This playbook does NOT enforce the resolver-context requirement — it's the caller's responsibility per `[[linear-discipline]]`. Optionally surface a WARNING if move_state to Waiting/Blocked is the only mutation for that issue in this batch.

   - **`create_followup`** — `mcp__linear-tactic__linear_createIssue` with `projectId`, `title`, `description=body`, `priority`, `teamId` (resolved from project's team), and `stateId=<Todo>` (default).
     - **Discipline (integrity on creation):** Before creating, the caller should have duplicate-checked via search; this playbook does not enforce it but flags if the `title` is suspiciously similar to a recent issue in the same project (cheap check — call `linear_searchIssues` with the title; if >50% similar string distance to an existing recent issue, emit a WARNING).
     - **Discipline:** description should include falsifiable acceptance criteria. Caller responsibility.
     - **Discipline:** if `blocked_by` provided, after issue creation call `mcp__linear-tactic__linear_createIssueRelation` for each (`type: blocked_by`).

   - **`update_description`** — `mcp__linear-tactic__linear_updateIssue` with `description=new_description`.
     - **Discipline:** the description is the issue's spec; comments are its log. Update description when scope or approach changes materially; use comments for incremental progress.

3. **Collect results.** If any mutation fails, continue with the rest. Report all results together — caller decides retry/escalation.

## Output

```yaml
results:
  - issue_id: <ID>           # or new_issue_id for create_followup
    action: <action>
    status: success | failure | warning
    warnings: [<string>, ...]   # e.g. "move_state to Blocked without resolver-context mutation in batch"
    error: <string if failure>
    new_issue_id: <ID if create_followup succeeded>
```

## State on pick-up reciprocal

This playbook handles the CLOSE side of the state-on-pick-up rule (mark_done at session-closeout). The OPEN side (`In Progress` on focus) is the caller's responsibility — typically done at the start of substantive work on an issue, not at closeout. Closeout's `update-issues` batch is for closure + comments + follow-ups, not for opening.

## Per-action team-aware caveats

| Action | Team-aware concern |
|---|---|
| mark_done | stateId for Done differs per team — handled via resolution cache |
| comment | No state change; no team concern |
| move_state | stateId for Waiting/Blocked differs per team — handled via cache |
| create_followup | teamId derived from `project_id`'s team — query once if uncertain, cache |
| update_description | No state change; no team concern |

## What this playbook does NOT do

- Does NOT write Project Updates (that's `project-updates.md`).
- Does NOT archive (that's `archive.md`).
- Does NOT enforce duplicate-check on every `create_followup` — it does a cheap title-similarity warn, but the caller's integrity-on-creation responsibility is unchanged.
- Does NOT do cross-team batches with hardcoded stateIds — every team's stateIds resolved via cache.
