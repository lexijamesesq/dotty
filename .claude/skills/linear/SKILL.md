---
name: linear
description: Linear domain expert — read issues / projects / queue / narrative; manage issue state, comments, follow-ups; write Project Updates; analyze themes + stale-debt; archive Done/Canceled. Invoked by session orchestrators, mid-session-checkpoint (future), router, and ad-hoc Claude sessions. Triggers on "/linear <operation>" or programmatic invocation.
---

# /linear

Domain expert for all Linear operations across the operator's teams (team prefix→UUID mapping defined in global CLAUDE.md > Configuration; resolved at runtime). Carries the discipline rules from `~/bin/dotty/.claude/rules/linear-discipline.md` — three-layer memory, state on pick-up, integrity on creation, closure form, Waiting vs. Blocked semantics — and enforces them where this skill is the natural enforcement point.

Enforcement boundaries (honest scope):
- **Enforced here:** Project Update body shape + three-layer separation (reject pre-write); team-aware stateId resolution (correctness, not discipline); archive dry-run defaults; closure-side state transitions (`mark_done` correctness); cross-team batch handling.
- **Surfaced but not enforced here:** open-side state-on-pick-up (happens at start-of-work, not at issue-management invocation; caller responsibility); duplicate-check on `create_followup` (the playbook does a cheap title-similarity warn, not a hard block); resolver+trigger prose in Waiting/Blocked move (warned when batch shape suggests omission, not parsed).
- **Out of scope:** rules that govern non-Linear surfaces (e.g., three-layer separation enforcement on CLAUDE.md writes lives in `/project-state`; Knowledge-doc anti-patterns live in `/knowledge-layer`).

## Intent

**Objective.** Linear interactions have outgrown ad-hoc inlining. There are many operations (read narrative/queue/issue/project, write comments/state changes/follow-ups/PUs, analyze themes/stale-debt, archive) consumed by every session orchestrator + the future mid-session-checkpoint + the Router + ad-hoc Claude sessions. Without this skill, discipline rules drift, team-aware stateId resolution gets re-implemented per consumer, and the free-tier cap surprises.

**Desired outcomes** (observable):
1. Every consumer gets consistent Linear discipline application (state on pick-up close-side, integrity on creation surfacing, closure form, three-layer memory) without re-implementing.
2. Project Update body shape is enforced pre-write (rejected by playbook before reaching Linear), not after-the-fact review.
3. Team-aware stateId resolution is uniform across all writes; no hardcoded stateIds anywhere in any consumer.
4. Free-tier cap stays a background concern via the archive playbook (invoked by closeout; ad-hoc dry-run by default).

**Health metrics — must NOT degrade.**
- Three-layer memory: item-level → on issues; session-level → on Project Updates; never collapse.
- Team-aware stateId resolution per batch (cached, not hardcoded).
- Dry-run safety: ad-hoc archive invocations dry-run by default; never archive without explicit non-dry-run.
- Load-boundary-as-guard for project-updates write/review split: write path never loads review playbook.

**Strategic context.** Domain expert for the entire Linear surface across the operator's teams (prefix→UUID mapping in global CLAUDE.md > Configuration). Composes with the auto-loaded `[[linear-discipline]]` rule to enforce discipline at write time. One of three domain skills introduced by this deconstruction work (alongside `/project-state`, `/knowledge-layer`).

**Constraints.**
- **Hard:** Pre-cutoff fallbacks retired — no `linear_getProjects` name-match as fallback for missing Project ID (data error to surface). Team-aware stateId resolution required (no hardcoded stateIds). Dry-run defaults enforced at playbook level (ad-hoc = true, closeout = false explicit).
- **Steering:** Enforcement scope is honest — Project Update body shape is enforced pre-write; state-on-pick-up open-side, integrity-on-creation duplicate-check, Waiting/Blocked resolver-context are SURFACED via warnings but not enforced (caller responsibility).

**Decision authority.**
- **Autonomous:** all MCP read operations; mutations the playbook contracts cover; team-aware stateId resolution; closure-side state transitions (`mark_done`); archive sweep when invoked by closeout (closeout has greenlit via `dry_run=false`).
- **Escalate via error:** ad-hoc archive without explicit dry-run override → refuse; mutations failing validation (body shape, malformed action) → return error to caller; operations not in Navigation table → reject with table reference; cross-team batches with malformed team prefix → reject.
- **Escalate via subagent:** PU body review (write path completes, then orchestrator spawns `/linear review project-update` subagent with fresh context).

**Stop rules.**
- Linear API rate limit → return partial results; caller decides retry.
- PU review subagent FAIL after 3 iterations → escalate to caller (PU exists but flagged).
- Three-layer separation violation in PU body → reject pre-write; caller fixes + re-invokes.
- The filing-time lint gate unavailable (when consumer needs it via cross-skill flow) → surface to caller; do not proceed without gate.

## Identity

This skill owns the Linear domain end-to-end: read paths (queue, narrative, individual issues, projects), write paths (issue mutations, Project Updates), analysis (stale-debt thresholds, theme grouping, priority distribution), and the archive sweep that keeps the free-tier ticket cap from becoming a recurring crisis.

Discipline rules that apply on every invocation:

- **Three-layer memory, no overlap.** Item-level decisions live on the issue (description + comments). Session-level narrative lives on Project Updates. Re-entry orientation lives on CLAUDE.md (NOT here — that's `/project-state`).
- **State on pick-up.** When an issue becomes the focus of work, set state to `In Progress` before the first relevant edit. Set to `Done` when work completes.
- **Integrity on creation.** Before filing a new issue: duplicate-check via search, include falsifiable acceptance criteria, express dependencies as Linear relations (not prose), match project + priority to actual work.
- **Closure form.** Use `Canceled` (not `Duplicate`) for closure when an issue won't be done. Express duplication via `duplicate_of` relation on the Canceled item.
- **Waiting vs. Blocked.** Waiting = expected delay with known resolver (PR review, scheduled response). Blocked = something requires intervention to advance (decision, re-scope, unknown). Both must carry resolver + trigger context in description.
- **Pre-cutoff fallbacks are RETIRED** (2026-05-24). All projects on Linear. No `backlog.json` fallback, no `linear_getProjects` name-match fallback for missing Project ID. Missing Project ID = data error to surface.

## Navigation

Per invocation, identify the operation and load the matching playbook:

| Invocation | Input | Output | Playbook |
|---|---|---|---|
| `read narrative` | `project_id` (UUID), optional `limit` (default 3) | Recent Project Updates | `playbooks/reading.md` |
| `read queue` | `project_id`, optional state filter | Active issues with priority/state/updatedAt | `playbooks/reading.md` |
| `read issue` | `issue_id` (e.g. `<TEAM>-N`), optional `include_blockers` | Full issue + blockers/blocking if requested | `playbooks/reading.md` |
| `read project` | `project_id` OR `project_name` (help-find-UUID only) | Project metadata | `playbooks/reading.md` |
| `analyze stale-debt` | List of issues + per-priority thresholds | Subset past threshold | `playbooks/analysis.md` |
| `analyze themes` / `analyze priority` | List of issues | Grouped + prioritized output | `playbooks/analysis.md` |
| `update issues` | List of `{issue_id, action, ...}` mutations | Per-item results | `playbooks/issue-management.md` |
| `update project` | `project_id` + `description` (and/or other project-level field changes) | Mutation: project metadata updated | inline at this navigator (single MCP call: `mcp__linear-tactic__linear_updateProject`) — if usage grows beyond description updates, extract to `playbooks/project-management.md` |
| `write project-update` | `project_id` + structured body fields | Created PU | `playbooks/project-updates.md` |
| `review project-update` (subagent-only) | PU body + rubric | Findings list | `playbooks/project-updates-review.md` |
| `archive` | optional: `grace_days`, `teams`, `dry_run` | Candidate list (dry-run) OR archived count (live) | `playbooks/archive.md` |

**Invocation convention:** callers use the exact `Invocation` string (e.g. `/linear read narrative`, `/linear update issues`, `/linear archive`). The first word is the verb category; subsequent words qualify within the playbook. This is consistent across all callers.

## Cross-cutting

### Team-aware stateId resolution

Issue IDs carry team via prefix (e.g., `<TEAM>-N`). Resolve the prefix to its team UUID via global CLAUDE.md > Configuration; the operator's CLAUDE.md defines the prefix→UUID mapping. Never hardcode prefixes or UUIDs here — the abstraction must not contain the data it abstracts.

State IDs differ per team. Both teams use the same active state set: `Todo`, `In Progress`, `Waiting`, `Blocked`, `Done`, `Canceled`. Resolve via `mcp__linear-tactic__linear_getWorkflowStates` and **cache per invocation** — do NOT re-resolve per mutation in a batch.

Playbooks that mutate (`issue-management`, `project-updates`, `archive`) handle stateId resolution internally; the navigator passes through the team context. Callers pass logical state names; never hardcode stateIds at the caller layer.

### Project ID handling

Project IDs are UUIDs. The URL slug is NOT a valid `projectId` argument. If a caller has only a URL slug, they must resolve via `/project-state read` first (which parses `**Project ID:**` from CLAUDE.md Intake). This skill does NOT lookup-by-name as fallback.

## Load-boundary-as-guard

`playbooks/project-updates.md` is the WRITE path. `playbooks/project-updates-review.md` is the REVIEW path. The write path NEVER loads the review path. Review is reachable only as a fresh subagent invocation given the written PU + the rubric, with no context about what the write path reasoned. Same pattern as lexi-persona's review/rubric.md.

In a write → review loop, the orchestrator (typically `/session-closeout`) spawns the review subagent after the write completes. Iteration cap 3.

## What this skill does NOT do

- Does NOT read or write CLAUDE.md (that's `/project-state`).
- Does NOT scan Knowledge layer (that's `/knowledge-layer`).
- Does NOT decide WHAT goes into a Project Update — the caller composes content; this skill enforces body shape + discipline. (Exception: `analysis` operations DO produce content — themes, priority groupings — because that's the analysis's job.)
- Does NOT manage cross-issue relations beyond what the action enum supports (`create_followup` with optional `blocked_by`; full relation graph operations like reparenting are out of scope today).

## References

- `~/bin/dotty/.claude/rules/linear-discipline.md` — the discipline rules this skill enforces (auto-loaded as an operator rule, but cited here so the playbooks can reference specific sections).
- `[[sustained-autonomous-agentic-workflows]]` — three-layer memory architecture.
- `~/bin/dotty/.claude/rules/linear-discipline.md` "Project-attachment caveat" subsection — explains why MCP-driven sweep is the only path for active-project issues. `<!-- TODO: this subsection is part of the deconstruction follow-on; remove this marker when Phase 5 ships -->`
