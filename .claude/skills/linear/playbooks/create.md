# Playbook: create

Write a well-formed ticket — the description template, duplicate check, relations, and the map-open exception. The point of this playbook is that every ticket comes out the same shape regardless of who created it.

## Input

```yaml
project_id: <UUID>                 # required
title: <string>                    # required
priority: 1|2|3|4                  # required
teamId: <UUID>                     # resolved from the project's team
parent_id: <issue UUID>            # optional — creates a sub-issue (map children)
objective: <string>                # required unless `question` is given (XOR)
question: <string>                 # map-children variant: body becomes `## Question`; requires parent_id + a type label
done_when: [<string>, ...]         # optional — deferred by default if omitted
constraints: [<string>, ...]       # optional
context: [<string>, ...]           # optional — links/pointers; operator's verbatim words when operator-directed
labels: [<label name>, ...]        # optional
blocked_by: [<issue_id>, ...]      # optional — created as a Linear relation
```

`objective` and `question` are mutually exclusive — refuse if both or neither are given.

## Protocol

**Question-shaped map children.** When `question` is given, require `parent_id` and a type label; the description is just `## Question` + the question text with its directives. Skip Step 1's template and Step 3's duplicate check (map siblings share phrasing by nature; the warn would always fire). Everything else — creation, labels, relations — proceeds identically. `build` tickets are NOT question-shaped: they use the standard template below (Objective = the slice; Done When = the proof).

**Step 1 — Build the description** (standard shape):

```markdown
## Objective

<objective — required>

## Done When

<done_when conditions, one per line — OR the deferral marker if not provided:>
_to be set at claim_

## Constraints

<constraints, one per line — omit this section entirely if empty>

## Context

<context links, one per line — omit this section entirely if empty>
```

When `done_when` is omitted, write the deferral marker `_to be set at claim_` — honest incompleteness, not fake precision. When the operator directed the work, her verbatim words go into Context — her words are what the validator grades intent against.

**Step 2 — Create the issue.** `mcp__linear-tactic__linear_createIssue` with `projectId`, `title`, the assembled `description`, `priority`, `teamId`, `parentId` when given (sub-issue), and `stateId=<Todo>` (default).

**Step 3 — Duplicate check.** Call `linear_searchIssues` with the title; if a recent issue in the same project has >50% title similarity, emit a WARNING (not a block).

**Step 4 — Relations.** If `blocked_by` is provided, call `mcp__linear-tactic__linear_createIssueRelation` for each (`type: blocked_by`).

**Step 4.5 — Late-cut build children.** A `build` child created under a map whose charter document already carries the FINALIZED marker (probe: `linear_getIssueDocuments` on the parent map, check the marker) gets the `ready-for-agent` label at create — the lane stays open for slices cut after finalization; without this, a late-cut slice is permanently untakeable.

**Step 5 — Map-open (map-labeled creates only).** After creating an issue that itself carries the `map` label: set `stateId=<In Progress>` and `assigneeId=<the operator>` via `mcp__linear-tactic__linear_updateIssue` — the effort is live from charting, and this is a ruled exception to assignee-is-the-operator's-field (system-placed effort ownership). No delegate, ever — maps are never claimed.

**Step 6 — Return.** Return the new issue ID and echo any debt: "Created ABC-12. Done When deferred to claim." or "Created ABC-12. Fully formed."

## What this playbook does NOT do

- Does NOT claim the ticket it creates (`playbooks/claim.md`).
- Does NOT decompose an oversized ticket — sizing happens at claim (Too Big check, `playbooks/claim.md`).
- Does NOT write map charters or Project Updates.
