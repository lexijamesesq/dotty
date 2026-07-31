---
name: linear
description: Linear domain expert — read issues / projects / queue / narrative / map frontiers; ticket lifecycle (create, claim, mark_done, resolve, cancel); documents on issues; Project Updates; analysis; archive. Invoked by session orchestrators, map sessions, conductors, and ad-hoc sessions. Triggers on "/linear <operation>" or programmatic invocation.
---

# /linear

Domain expert for all Linear operations across the operator's teams (team prefix→UUID mapping defined in global CLAUDE.md > Configuration; resolved at runtime).

Discipline rules that apply on every invocation:

- **Three-layer memory, no overlap.** Item-level decisions live on the issue (description + comments). Session narrative lives on Project Updates. Re-entry orientation lives on CLAUDE.md (that's `/project-state`, not here).
- **State on pick-up, proof on close.** Claim before the first relevant edit. Close through `mark_done` — the `[VALIDATION]` comment is what makes work landed — or through `resolve` for decision-type map children (research: the sweep's receipt spot-check; HITL types: the operator in the exchange).
- **Integrity on creation.** `create` writes the description template (Objective, Done When, Constraints, Context) or the `## Question` shape for map children. Dependencies are Linear relations, never prose.
- **Label discipline.** `map` marks a map issue. `hitl`/`afk` are loop labels. Type labels — `research`, `prototype`, `grilling`, `task`, `build` — route map children to their resolvers. Apply at create.
- **Closure form.** `cancel` (state `Canceled`) for work that won't be done; duplication via `duplicate_of` relation on the Canceled item.
- **Needs Input vs. Blocked.** Needs Input = paused on the operator. Blocked = external dependency with a checkable condition. Both carry the specific ask or condition in a comment; both release the delegate (parking releases the claim).

## Navigation

Per invocation, identify the operation and load the matching playbook:

| Invocation | Input | Playbook |
|---|---|---|
| `read narrative` / `read queue` / `read issue` / `read project` | ids per playbook | `playbooks/reading.md` |
| `read map-frontier` | map issue id — open/unblocked/unclaimed children with type labels | `playbooks/reading.md` |
| `read documents` | `issue_id` | `playbooks/reading.md` |
| `analyze stale-debt` / `analyze themes` / `analyze priority` / `analyze re-eval` (Needs Input/Blocked) | issue lists + thresholds | `playbooks/analysis.md` |
| `create` | `project_id` + `title` + (`objective` [+ `done_when`] OR `question`) + optional `parent_id`, `labels`, `blocked_by` | `playbooks/issue-management.md` |
| `claim` | `issue_id` — variant auto-selected: full / map-child / build | `playbooks/issue-management.md` |
| `mark_done` | `issue_id` + `validation_type` + `evidence` (+ `charter_doc_id` for `build` tickets) | `playbooks/issue-management.md` |
| `resolve` | `issue_id` — decision-type map children (research from the sweep; grilling/prototype/task HITL) | `playbooks/issue-management.md` |
| `work frontier` | `project_id` — generic tickets only; map children excluded | `playbooks/issue-management.md` |
| `update issues` | batch of `{issue_id, action, ...}` — comment, move_state, update_description, add_relation, attach_document, archive_document, cancel | `playbooks/issue-management.md` |
| `update project` | `project_id` + field changes | inline: `mcp__linear-tactic__linear_updateProject` |
| `write project-update` | `project_id` + structured body fields | `playbooks/project-updates.md` |
| `review project-update` (subagent-only) | PU body + rubric | `playbooks/project-updates-review.md` |
| `archive` | optional `grace_days`, `teams`, `dry_run` | `playbooks/archive.md` |

**Invocation convention:** callers use the exact `Invocation` string. Autonomous-pickup policy lives in global CLAUDE.md — this skill carries capability; permission lives there.

## Cross-cutting

### Team-aware stateId resolution

Issue IDs carry team via prefix. Resolve the prefix to its team UUID via global CLAUDE.md > Configuration. State IDs differ per team: resolve via `mcp__linear-tactic__linear_getWorkflowStates` and **cache per invocation** — never re-resolve per mutation in a batch. Playbooks that mutate handle stateId resolution internally; callers pass logical state names, never stateIds.

### Frontier convention

Takeable = Todo, unblocked, unassigned, no delegate, not labeled `map`, and **not a child of a map** — map children belong to map sessions, reached via `read map-frontier` and routed by type label, never by the generic flow. Delegate-is-claim: the `delegate` field is the session's claim; the `assignee` field is the operator's hold. Ordering: priority (Urgent → Low), then age (oldest first). `work frontier` reads the generic frontier and drives one ticket to Done per session.

### Project ID handling

Project IDs are UUIDs; a URL slug is not a valid `projectId`. Resolve via `/project-state read` (frontmatter `linear_project_id`). No lookup-by-name fallback — a missing ID is a data error to surface.

## Load-boundary-as-guard

`playbooks/project-updates.md` is the WRITE path; `playbooks/project-updates-review.md` is the REVIEW path. The write path NEVER loads the review path — review runs as a fresh subagent given the written PU + rubric, with no context from the write path. Iteration cap 3.

## What this skill does NOT do

CLAUDE.md writes (`/project-state`); Knowledge-layer scans (`/knowledge-layer`); Project Update content authorship (the caller composes; this skill enforces shape); relation graphs beyond `blocked_by` / `duplicate_of`.
