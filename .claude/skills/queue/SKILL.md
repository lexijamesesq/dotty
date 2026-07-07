---
name: queue
description: Operator-judgment queue expert — create Wiki/Queue/ item files, run the conditional session-closeout drain (scope-match / age / backpressure), report queue + Inbox debt status. Invoked by /session-closeout (drain), /knowledge-layer scope-lint (create-item), and ad-hoc sessions. Triggers on "/queue <operation>" or programmatic invocation.
---

# /queue

Domain expert for the operator-judgment queue — the `Wiki/Queue/` directory of one-file-per-item pending judgments. Carries the item schema, the drain's fire conditions and bounded-ask discipline, and the shared debt-line format.

## Identity

The queue is where automated lanes and session-tier skills park candidates that need operator judgment: captures to triage, topics to explore, pages to promote, lint findings to disposition, contradictions to resolve, proposals to accept. One `.md` file per item — distinct-file creation avoids multi-writer conflicts across writer classes (capture lanes, maintenance lanes, interactive closeouts) coordinated only by vault sync. Items are transient judgment artifacts, not knowledge-layer files: `Wiki/Queue/` is deliberately UNGOVERNED by the structural-contract Location Gate, and queue hygiene is owned by the queue mechanics themselves (drain, expiry, backpressure alarm), not by lint.

Discipline rules applied on every invocation:

- **Resolve the vault root via the `workspace_root` config key** (global CLAUDE.md > Configuration). Never hardcode a vault path. Queue dir = `{workspace_root}/Wiki/Queue/`; Inbox dir = `{workspace_root}/Inbox/`.
- **Vault `.md` writes go through the Obsidian MCP tools** (`mcp__obsidian__write_note`, `mcp__obsidian__update_frontmatter`) — never generic Write/Edit.
- **No silent drops.** A failed item write is reported FAIL to the caller loudly; a queue item is never resolved or expired without the operator adjudicating it.
- **Bounded ask.** The drain presents at most 3 items per closeout — warm context, operator present, small decision surface.

## Intent

**Objective.** Automated and semi-automated lanes produce judgment calls no automation may make (per-source trust boundaries, precision-over-recall). Without a queue with owned drain mechanics, those judgments either interrupt the operator at generation time (defeating automation), pile up invisibly in a JSON backlog nobody reads, or get silently auto-resolved (violating decision authority). This skill makes deferred judgment cheap to park, visible as it accumulates, and cheap to pay down at the moment the operator is already present.

**Desired outcomes** (observable):
1. Every queue item is a self-contained adjudication package: kind, source, reasons, scope tags, payload + evidence — the operator decides at drain time without re-deriving context.
2. The closeout drain fires ONLY when it has something relevant or overdue (scope-match, age > 14d, or count > threshold); a closeout with no queue nexus and a quiet queue adds zero cost and zero output.
3. Every drained item resolves to an explicit operator action (file / promote / discard / expire / keep); `status` reflects the outcome the moment it happens.
4. Monotonic queue growth becomes visible within days, not months — the backpressure threshold (default 15) escalates the debt line.
5. Items pending > 30 days surface as expire-candidates (prune-bias); expiry is an operator click, never silent garbage collection.

**Health metrics — must NOT degrade.**
- Drain conditionality: the fire conditions live HERE (in `playbooks/drain.md`), not in the closeout orchestrator — the orchestrator carries one invocation line.
- Drain cap of 3 items per closeout; scope-matched items outrank oldest.
- Distinct-file writes only; no shared-file mutation across writer classes.
- Silence-is-success: no "queue is empty" chatter from the drain; the status line is the only passive signal surface.
- Debt-line format stays in lockstep with the SessionStart hook (`hooks/vault-debt-line.sh`) — `playbooks/status.md` is the canonical definition.

**Strategic context.** Session-tier half of the unified ingress model (see `[[unified-ingress-design]]` §7): automated lanes write queue items (their only vault-write surface until the enablement gate clears); the session tier drains them. Composes with `/session-closeout` (primary drain owner), `/knowledge-layer scope-lint` (disposition-item producer), and the `vault-debt-line.sh` SessionStart hook (passive signal). Supersedes the Wiki backlog-JSON intents: explore/triage/promote live here as item kinds.

**Constraints.**
- **Hard:** `status` enum is `pending | resolved | expired` — nothing else. `queue-kind` enum is `triage | explore | promote | disposition | conflict | proposal`. Item writes are distinct-file creates, never appends to a shared file. Drain never fires outside its three conditions; never presents more than 3 items. Resolution actions execute within the EXISTING decision authority of the skill that executes them — the drain grants no new write authority.
- **Steering:** Slug from the payload topic, not the source lane. Scope tags (`project/*` or `area/*`) are load-bearing — the drain's scope-match reads them; an item without scope tags can only surface via age or count.

**Decision authority.**
- **Autonomous:** item file creation (schema composition, filename, scope-tag derivation from payload); fire-condition evaluation; item selection + ordering for a firing drain; marking `resolved`/`expired` AFTER operator adjudication; status-line composition.
- **Escalate to operator:** every drained item's disposition — file / promote / discard / expire / keep is always the operator's call; the skill never adjudicates. Item-write failure → report FAIL to caller (caller decides whether to halt).

**Stop rules.**
- Vault root unresolvable (no `workspace_root` config, no `VAULT_ROOT` env) → halt; report to caller. Do not guess a path.
- `Wiki/Queue/` does not exist at the resolved root → create-item halts and surfaces (a missing queue dir means the substrate isn't deployed — creating it silently would hide a setup gap); drain and status report zero-state instead.
- Item write fails or read-back verification fails → report FAIL; never proceed as if written.
- Operator declines to adjudicate a presented item → it stays `pending` untouched (that IS the `keep` action); never mark it to make the drain look complete.

## Navigation

Per invocation, identify the operation and load the matching playbook:

| Operation | Input | Output | Playbook |
|---|---|---|---|
| **create-item** | `queue_kind`, `source`, `reasons[]`, scope tags, payload + evidence | One new `Wiki/Queue/` item file (path returned), or FAIL | `playbooks/create-item.md` |
| **drain** | Session scope (project/domain), today's date | Nothing (conditions not met) OR up to 3 adjudicated items + summary | `playbooks/drain.md` |
| **status** | none (optional `today`) | One-line debt summary (Queue pending + Inbox count, oldest ages) | `playbooks/status.md` |

## What this skill does NOT do

- Does NOT execute resolution payloads itself — `file` routes through the filing skills (`/wiki-intake`, `/knowledge-layer query-and-file`), `promote` routes through `/linear`; each with its own gates intact.
- Does NOT apply the knowledge-layer structural envelope or filing-validator to queue items — `Wiki/Queue/` is outside the Location Gate by design.
- Does NOT emit the session-start debt line — that's the `vault-debt-line.sh` SessionStart hook (pure file counting, no skill invocation). This skill's `status` playbook defines the shared line format.
- Does NOT manage the external backpressure monitor (e.g., an uptime monitor flipping to warn) — that belongs to the automation tier.

## References

- `[[unified-ingress-design]]` §7 — the queue substrate decision, item shape, drain ownership, backpressure alarm (the spec this skill implements).
- `hooks/vault-debt-line.sh` — the passive SessionStart signal sharing `playbooks/status.md`'s line format.
- `[[linear-discipline]]` — governs the `promote` resolution path (integrity on creation).
