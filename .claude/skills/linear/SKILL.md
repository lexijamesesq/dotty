---
name: linear
description: Linear reference card — the correct-procedure source for operations where improvising produces wrong results: ticket creation, claiming, state transitions, and structured comment formats. Any agent at any depth invokes it directly; simple reads and basic updates call Linear MCP tools without it. Triggers on "/linear <operation>" or programmatic invocation.
---

# /linear

Reference card for Linear operations across the operator's teams (team prefix→UUID mapping in global CLAUDE.md > Configuration; resolved at runtime). Not an agent, not a domain owner — any agent at any depth calls `mcp__linear-tactic__*` tools directly and consults this skill wherever winging it produces a wrong result.

**Load this skill for:** creating a ticket, claiming one, changing its state (park, cancel, or the mechanical half of a close), finding takeable/frontier tickets, attaching or archiving a document, or posting a `[VALIDATION]`/`[HANDOFF]` comment.
**Skip it for:** simple reads (`getIssueById`, `getProjectIssues`, `getComments`, `getProjectUpdates`, ...), basic field updates (`update_description`, `add_relation`), or a plain progress comment — call the MCP tool directly.

## Navigation

| Operation | Playbook |
|---|---|
| Create a ticket (standard, or a map-child `## Question` shape) | `playbooks/create.md` |
| Claim a ticket (full / map-child / build thin-redirect variants) | `playbooks/claim.md` |
| `move_state` (Needs Input / Blocked / Todo), `cancel`, and the mechanical `mark_done`/`resolve` transitions | `playbooks/transitions.md` |
| Find takeable tickets (map-level or project-level frontier) | `playbooks/frontier.md` |
| `attach_document` (incl. the FINALIZED marker + `ready-for-agent` cascade) and `archive_document` | `playbooks/documents.md` |
| Post a `[VALIDATION]` receipt or a `[HANDOFF]` comment | `playbooks/comments.md` |
| Write a Project Update | `playbooks/project-updates.md` |
| Review a written Project Update (subagent-only, fresh spawn) | `playbooks/project-updates-review.md` |
| Archive sweep (cap management) | `playbooks/archive.md` |

`mark_done`, `resolve`, and `close-map` — pre-checks, the non-author validation-receipt verification, verdict routing, the map-close ending sequence — belong to `@traffic-cone`, the transition law and its scripts (`cone_preflight.py` + `linear_bridge.py`), never an agent: the caller runs them itself, and they verify each transition is earned before executing it. This card's `transitions.md` carries the mechanical protocol the scripts execute against; calling these transitions directly without that verification bypasses the gate, it doesn't satisfy it.

## Cross-cutting rules

### Team-aware stateId resolution

Issue IDs carry team via prefix. Resolve the prefix to its team UUID via global CLAUDE.md > Configuration. State IDs differ per team: resolve via `mcp__linear-tactic__linear_getWorkflowStates` and **cache per invocation** — never re-resolve per mutation in a batch.

### Mention escaping

Backtick-escape agent names (`@linear`, `@attack-kitty`, `@traffic-cone`) in comment and description bodies — Linear's mention parser treats a bare `@` as a user lookup. The OAuth app lacks `app:mentionable` scope (agents aren't Linear workspace members), so a bare mention fails the entire write with a misleading "App user not valid" error. Always write agent names as code spans: `` `@linear` ``, `` `@attack-kitty` ``, `` `@traffic-cone` ``.

### Verification laws

- **No mutation response is trusted.** Always independent-read to verify what actually landed.
- **lastSyncId awareness.** A same-value write returns `success:true, lastSyncId:0` — that is not proof of a no-op vs. a real write. Verify by read-back + content match, never by the sync id alone.
- **Claim checks route through the GraphQL bridge.** The tactic MCP does not project the `delegate` field — a claim can't be verified through it.
- **`createComment` doesn't surface `lastSyncId`.** Route through the bridge when per-item sync verification is needed.
- **Transient scope failures retry — they don't fail the batch.** A write that fails on a scope/permission error (e.g., "App user not valid") may be a transient platform fault, not a real authorization gap — retry twice with backoff (1s, 3s) before treating it as real. Still failing after retries → surface the specific error on that item and continue the rest of the batch; never silently drop the item or invent a success.

### Project ID handling

Project IDs are UUIDs; a URL slug is not a valid `projectId`. Resolve via `/project-state read` (frontmatter `linear_project_id`). No lookup-by-name fallback — a missing ID is a data error to surface, not a name-search to run.

### Label discipline

`map` marks a map issue. `hitl`/`afk` are loop labels — who drives resolution. Type labels — `research`, `prototype`, `grilling`, `task`, `build` — route map children to their resolvers. `ready-for-agent` marks a `build` child takeable by frontier sessions — applied at charter finalization, or at create for a build child cut after its map's charter finalized; never by hand mid-flight. Apply type and loop labels at create. `model:*` marks a model-routing exception — versioned = an operator pin; AFK spawns use the class.

### Needs Input vs. Blocked

Needs Input = paused on the operator. Blocked = external dependency with a checkable condition. Both carry the specific ask or condition in a comment; both release the claim. Maps never park.

## Load-boundary-as-guard

`playbooks/project-updates.md` is the WRITE path; `playbooks/project-updates-review.md` is the REVIEW path. The write path NEVER loads the review path — review runs as a fresh `@attack-kitty` `pu-review` subagent given only the written PU body. Single pass, no iteration.

## What this skill does NOT do

Simple reads (call MCP directly). Analysis — stale-debt, theming, priority distribution (read the data, reason about it inline; no playbook). CLAUDE.md writes (`/project-state`). Knowledge-layer scans (`/knowledge-layer`). Project Update content authorship (the caller composes; `project-updates.md` enforces shape). `mark_done`/`resolve`/`close-map` verification-and-execution (`@traffic-cone`). Picking a ticket off the frontier and driving it to close (the calling orchestrator — a conductor or frontier-pickup session — using this card's `frontier.md` to find candidates). Gate judgment (`@attack-kitty`).
