---
name: queue
description: Operator-judgment queue expert — create Wiki/Queue/ item files and run the operator-invoked triage flow (menu-guided; scoped or all). Signal surface is the statusline Knowledge Triage Queue line; this skill is the verb. Invoked by /knowledge-layer scope-lint (create-item), automated lanes (create-item), and the operator (triage). Triggers on "/queue triage", "/queue triage-all", "triage the queue", "/queue <operation>".
---

# /queue

Domain expert for the operator-judgment queue — the `Wiki/Queue/` directory of one-file-per-item pending judgments. Carries the item schema and the operator-invoked, menu-guided triage flow. Signal lives in the statusline (icon · title · scoped → All counts); work happens only when the operator says so.

## Identity

The queue is where automated lanes and session-tier skills park candidates that need operator judgment: captures to triage, topics to explore, pages to promote, lint findings to disposition, contradictions to resolve, proposals to accept. One `.md` file per item — distinct-file creation avoids multi-writer conflicts across writer classes (capture lanes, maintenance lanes, interactive closeouts) coordinated only by vault sync. Items are transient judgment artifacts, not knowledge-layer files: `Wiki/Queue/` is deliberately UNGOVERNED by the structural-contract Location Gate, and queue hygiene is owned by the queue mechanics themselves (triage, expiry, backpressure alarm), not by lint.

Discipline rules applied on every invocation:

- **Resolve the vault root via the `workspace_root` config key** (global CLAUDE.md > Configuration). Never hardcode a vault path. Queue dir = `{workspace_root}/Wiki/Queue/`; Inbox dir = `{workspace_root}/Inbox/`.
- **Vault `.md` writes go through the Obsidian MCP tools** (`mcp__obsidian__write_note`, `mcp__obsidian__update_frontmatter`) — never generic Write/Edit.
- **No silent drops.** A failed item write is reported FAIL to the caller loudly; a queue item is never resolved or expired without the operator adjudicating it.
- **Pull, never push.** Triage runs only on explicit operator invocation. Session boundaries are never task surfaces. The statusline count is the only ambient signal.

## Intent

**Objective.** Automated and semi-automated lanes produce judgment calls no automation may make (per-source trust boundaries, precision-over-recall). Without a queue with an owned signal + an owned verb, those judgments either interrupt the operator at generation time (defeating automation), pile up invisibly in a JSON backlog nobody reads, or get silently auto-resolved (violating decision authority). This skill makes deferred judgment cheap to park, ambiently visible (statusline), and cheap to pay down whenever — and only when — the operator chooses.

**Desired outcomes** (observable):
1. Every queue item is a self-contained adjudication package: kind, source, reasons, scope tags, payload + evidence — the operator decides at triage time without re-deriving context.
2. Triage never fires on its own; sessions start and end with zero queue-related cost or output. The statusline line is absent at zero and shows (scoped) → All (total) otherwise.
3. Every triaged item resolves to an explicit operator action (apply / skip / expire / discuss→decision); `status` reflects the outcome the moment it happens.
4. Monotonic queue growth becomes visible within days, not months — the backpressure threshold (default 15) escalates the debt line.
5. Items pending > 30 days surface as expire-candidates (prune-bias); expiry is an operator click, never silent garbage collection.

**Health metrics — must NOT degrade.**
- No auto-fire, anywhere: no orchestrator invokes triage; grep for `/queue triage` in orchestrators should return nothing.
- Menu is scaffolding, not ceremony: a direct operator instruction bypasses it.
- Distinct-file writes only; no shared-file mutation across writer classes.
- Silence-is-success: no "queue is empty" chatter; the statusline is the only passive signal surface.
- Count format stays in lockstep with the statusline Knowledge Triage Queue line — `statusline/statusline.sh` is the canonical definition.

**Strategic context.** Session-tier half of the unified ingress model: automated lanes write queue items (their only vault-write surface until the enablement gate clears); the operator triages them on demand. Composes with `/knowledge-layer scope-lint` (disposition-item producer) and the statusline Knowledge Triage Queue line (passive signal). Future: the Slack CHAT lane drains this same queue conversationally. Supersedes the Wiki backlog-JSON intents: explore/triage/promote live here as item kinds.

**Constraints.**
- **Hard:** `status` enum is `pending | resolved | expired` — nothing else. `queue-kind` enum is `disposition | proposal` (collapsed — until reality demands more). Item writes are distinct-file creates, never appends to a shared file. Triage never auto-fires — operator invocation only. Resolution actions execute within the EXISTING decision authority of the skill that executes them — triage grants no new write authority.
- **Steering:** Slug from the payload topic, not the source lane. Scope tags (`project/*` or `area/*`) are load-bearing — the statusline scoped count and `triage`'s scope resolution read them; an unscoped item surfaces in Wiki scope and in `triage-all`.

**Decision authority.**
- **Autonomous:** item file creation (schema composition, filename, scope-tag derivation from payload); scope resolution + mechanical/judgment classification + item ordering within an invoked triage; marking `resolved`/`expired` AFTER operator adjudication; status reporting.
- **Escalate to operator:** every triaged item's disposition — apply / skip / expire (and any judgment-class action) is always the operator's call; the skill never adjudicates. Item-write failure → report FAIL to caller (caller decides whether to halt).

**Stop rules.**
- Vault root unresolvable (no `workspace_root` config, no `VAULT_ROOT` env) → halt; report to caller. Do not guess a path.
- `Wiki/Queue/` does not exist at the resolved root → create-item halts and surfaces (a missing queue dir means the substrate isn't deployed — creating it silently would hide a setup gap); triage and status report zero-state instead.
- Item write fails or read-back verification fails → report FAIL; never proceed as if written.
- Operator declines to adjudicate a presented item → it stays `pending` untouched (that IS the skip action); never mark it to make triage look complete.

## Navigation

Per invocation, identify the operation and load the matching playbook:

| Operation | Input | Output | Playbook |
|---|---|---|---|
| **create-item** | `queue_kind`, `source`, `reasons[]`, scope tags, payload + evidence | One new `Wiki/Queue/` item file (path returned), or FAIL | `playbooks/create-item.md` |
| **triage** | none (scope from cwd) | menu-guided adjudication of current-project items | `playbooks/triage.md` |
| **triage-all** | none | menu-guided adjudication of ALL pending items, grouped by scope | `playbooks/triage.md` |

## What this skill does NOT do

- Does NOT execute resolution payloads itself — a consequence that files knowledge routes through the filing skills (`/wiki-intake`, `/knowledge-layer query-and-file`); one that creates a work item routes through `/linear`; each with its own gates intact.
- Does NOT apply the knowledge-layer structural envelope or filing-validator to queue items — `Wiki/Queue/` is outside the Location Gate by design.
- Does NOT emit any ambient signal — that's the statusline (pure file counting in `statusline.sh`, no skill invocation). `statusline.sh` alone defines the count semantics.
- Does NOT manage the external backpressure monitor (e.g., an uptime monitor flipping to warn) — that belongs to the automation tier.

## References

- The ingress design — the queue substrate decision, item shape, backpressure alarm, and the triage design history (the spec this skill implements).
- `statusline/statusline.sh` — the passive signal surface (icon · title · scoped → All counts) and sole canonical definition of the count semantics.
- `linear-discipline` — governs the `promote` resolution path (integrity on creation).
