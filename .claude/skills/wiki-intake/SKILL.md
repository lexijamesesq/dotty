---
name: wiki-intake
description: >
  Single entry point for all Wiki-axis content. Checks for registered
  specialized handlers (e.g., /capture-meeting for recurring meeting docs)
  and delegates when matched. Otherwise classifies intent and routes:
  knowledge-intent captures are packaged as typed candidates for the
  knowledge-integration gatekeeper (which owns coherence, destination,
  filing, and validation), explore/triage captures become Wiki/Queue/
  items, and data corrections run the mutation chain. Triggers on
  "/wiki-intake", "file this to wiki", "wiki intake", or router delivery
  of wiki-axis captures.
user_invokable: true
---

# Wiki Intake

Single entry point for all Wiki-axis content. Checks for specialized handlers first, delegates when matched, otherwise classifies intent and routes. This skill owns intent classification and routing; the knowledge-integration gatekeeper owns the coherence decision and filing — speculative filing creates orphaned content that's harder to find than unfiled content. See `{workspace_root}/System/routing-architecture.md` for the architectural pattern.

## Objective

Captures die in two ways: they never get filed (lost in queue purgatory) or they get filed wrong (orphaned in the wrong location, mistagged, lacking provenance). Wiki intake ensures every capture that reaches the Wiki axis gets a deliberate routing decision — packaged as candidates for the gatekeeper when it's knowledge, staged as a Wiki/Queue/ item with enough context to promote later when it isn't, or run through the mutation chain when it's a correction.

The cost of a wrong placement is higher than the cost of a queue item. An honest "I don't know where this goes" preserves the capture for future triage. A confident misfile buries it under the wrong tags where no future query finds it.

## Desired Outcomes

1. Every capture receives a classification decision — no silent drops, no ambiguous deferrals
2. Candidates handed to the gatekeeper are self-contained and fully specified per the candidate schema — the gatekeeper never receives content it must reconstruct from missing context
3. Queue items contain enough context that a future triage or stewardship session can act on them without re-deriving intent
4. Data corrections propagate through all affected layers in a single pass — no partial updates that leave inconsistency between Data/, Knowledge/, Context, and Personal/Work

## Health Metrics

- Zero captures lost during intake — every input produces a gatekeeper disposition, a Wiki/Queue/ item, a staged Inbox/ file, or an explicit halt-and-ask
- Zero underspecified candidates — every candidate handed to the gatekeeper carries provenance, trust, and mode
- Data-correction chain touches all affected layers — no partial propagation
- Queue items are actionable: description + body carry enough context to promote without the original conversation

## Decision Authority

| Decision | Authority |
|---|---|
| Detecting specialized content types and delegating to handlers | Autonomous |
| Classifying capture intent | Autonomous |
| Packaging knowledge-intent captures as candidates + invoking the gatekeeper | Autonomous |
| Coherence, destination, filing, and validation of knowledge candidates | **Gatekeeper-owned** — knowledge-integration decides; wiki-intake relays its report |
| Creating `Wiki/Queue/` items for explore/triage (via `/queue create-item`) | Autonomous |
| Staging out-of-vault captures to `Inbox/` | Autonomous |
| Data-correction on an explicit operator mutation statement: updating Data/, appending to Knowledge/, updating Context, patching Personal/Work via `patch_note` | Autonomous |
| Data-correction where mutation intent is inferred, not stated | **Ask/confirm** before executing the chain |
| Promoting queue items to Knowledge/ | Human-initiated |
| Editing existing substance in Knowledge/ (vs. appending) | **Halt and flag** |
| New `type/*` or `area/*` values needed | **Halt and flag** |
| Classification is ambiguous | **Halt and ask** |
| Knowledge/ file would exceed 150 lines after a data-correction append | **Advisory flag** — do not halt; flag as consolidation candidate (lint INFO heuristic per [[structural-contract]], not a filing block per [[handoff-contracts]] §1) |

## Referenced docs

Paths use the `{workspace_root}` placeholder — resolve via global CLAUDE.md > Configuration > `workspace_root`.

- `{workspace_root}/System/Knowledge/unified-ingress-design.md` — the routing model this skill implements: candidate schema (§1), trust/mode disposition matrix (§2), gatekeeper wiring (§3), out-of-vault guard (§9)
- knowledge-integration skill (vault-root, `{workspace_root}/Wiki/claude/skills/knowledge-integration/`) — the gatekeeper. Its bundled playbooks are the calibration surface: coherence dimensions, thresholds, and worked examples live there, not here
- `{workspace_root}/Wiki/CLAUDE.md` — Wiki stewardship rules, decision authority, stop rules
- `{workspace_root}/System/tag-taxonomy.md` — closed tag namespaces
- `{workspace_root}/System/target-architecture-v2.md` — space structure, Data/ threshold
- `{workspace_root}/System/routing-architecture.md` — routing patterns, handler registration, accountability boundaries
- `{workspace_root}/System/structural-contract.md` — file envelope (Invariant Core + per-type additions + destination modifiers). Authority for the frontmatter a filed Knowledge/ file must carry; the gatekeeper enforces it at filing time.
- `{workspace_root}/System/handoff-contracts.md` §1 — wiki intake filing handoff contract. The gatekeeper enforces the coherence gate, field derivation, and post-file obligations on the `knowledge`-intent branch; wiki-intake packages the input.

## Input

The skill accepts content via:

| Source | Format |
|---|---|
| `/wiki-intake {text}` | Inline text in the invocation |
| `/wiki-intake` (no args) | Prompts user for content |
| Router delivery | Capture content passed from the Router's wiki-axis classification |
| Chat interface delivery | Data update or query from messaging integration (future) |

## Instructions

### Preflight: Out-of-vault guard

wiki-intake's processing delegates — specialized handlers, the knowledge-integration gatekeeper, `/queue` — are vault-root skills; they resolve only when the session cwd is inside the vault.

Determine the vault root: `VAULT_ROOT` env var if set; otherwise global CLAUDE.md > Configuration > `workspace_root`. If the session cwd is NOT inside the vault root:

1. **Do not classify or process.** The delegates this skill routes to are unavailable; processing directly would bypass the gatekeeper.
2. **Stage the raw capture** to `{vault_root}/Inbox/` as a new file: the capture content verbatim, plus a provenance note (capture source, date, invoking context, and the reason staged: wiki-intake invoked outside the vault).
3. **Report the staged path.** The session-start debt line covers Inbox/, so the staged capture surfaces at the next vault-rooted session — Inbox/ is not a dead letter box.

If the cwd is vault-rooted, proceed to Step 0.

### Step 0: Check for specialized handlers

Before intent classification, check if the content matches a registered specialized handler. Handlers are overrides — if one matches, delegate to it and skip Steps 1-3. If none match, fall through to default processing (Step 1).

**Current handlers:**

| Handler | Detection signals | Delegation |
|---|---|---|
| `/capture-meeting` | **Explicit:** content includes a meeting name matching a key in `Wiki/Data/meeting-registry.json`. **Structural:** document contains `## Agenda for {date}` or `## **Agenda for {date}**` headings AND entries prefixed with Moved/Learned/Need. **Heuristic:** multiple dated sections with team/product area subsections — flag for confirmation before delegating. | Invoke `/capture-meeting` with the matched meeting name and full content. The handler owns parsing, coherence filtering, and filing. |

**If no handler matches → proceed to Step 1.**

**Self-sourcing handlers:** Some handlers can fetch their own content from external sources (e.g., `/capture-meeting` auto-fetches from Drive when the registry entry includes `drive_file_id`). When this is the case, users may invoke the handler directly without going through wiki-intake — the handler handles transport itself. wiki-intake remains the entry point for pasted, router-delivered, or unrecognized content; self-sourced invocation is a parallel path, not a replacement. Delivered content always wins over self-sourcing when both are available. See `{workspace_root}/System/routing-architecture.md` for the invocation paths.

### Step 1: Classify intent

Read the capture and classify into one of four intents:

| Intent | Signal | Example |
|---|---|---|
| **knowledge** | Substantive content about a topic, with enough detail to stand alone | "Dedicating a backhaul channel on the mesh Wi-Fi restored full throughput — sharing a channel between nodes halved it" |
| **data-correction** | A fact change to existing data — not new knowledge, a mutation to current state | "Switched ISP to FiberCo", "Streaming plan downgraded to the ad-supported tier", "Gym membership cancelled" |
| **explore** | A topic the user wants to research later — no real content yet | "Look into rsync alternatives for incremental backup" |
| **triage** | Content too incoherent or ambiguous to classify cleanly | Partial thoughts, mixed topics, unclear intent |

If intent is ambiguous → **halt and ask.** An honest "I'm not sure where this goes" is better than a wrong placement.

#### Classification examples

These demonstrate the reasoning pattern — evaluate what the capture IS, not what it could become.

**Knowledge:**
> "The mesh Wi-Fi backhaul drops to half throughput when both nodes share a channel — moving the backhaul to a dedicated channel restored full speed. Confirmed across three evenings of testing."

→ **knowledge.** Self-contained finding. Clear topic (e.g. `topic/networking`, home-infrastructure area). Specific enough to stand alone. Single question: why was the mesh backhaul slow, and what fixed it.

**Data-correction:**
> "Cancelled the streaming-service-X subscription as of today"

→ **data-correction.** State change to existing tracked data, not new knowledge. The subscription was previously active; the mutation is active → cancelled. Propagate through the subscriptions tracking chain.

**Explore:**
> "Look into rsync alternatives for incremental backup over flaky network"

→ **explore.** No substantive content — just a topic to research later. Nothing to file as knowledge yet.

**Triage:**
> "Something about the way the Zigbee mesh handles... maybe we need to think about the coordinator placement, or is it the channel? Related to the interference from the microwave probably."

→ **triage.** Multiple possible topics (mesh routing, coordinator placement, channel selection, RF interference), no clear single question, stream-of-consciousness rather than a finding. Preserve as a queue item so it's not lost.

**Boundary — knowledge vs data-correction:**
> "The annual renewal for the backup tool posted — it's $X now, up from $Y"

→ **data-correction.** The primary signal is "a tracked value changed." The renewal price is a fact update to existing subscription data. If the increase also carries strategic implications worth capturing (e.g., triggers a keep/replace analysis), that's a separate knowledge capture — don't conflate the mutation with the analysis.

**Boundary — knowledge vs explore:**
> "Filesystem X reportedly corrupts data on drive firmware Y"

→ Depends on context. If the user runs that filesystem on that hardware → **knowledge** (actionable operational note, self-contained). If speculative/general → **explore** (needs research before it's a finding). **When uncertain → halt and ask.**

#### Reasoning dimensions for ambiguous cases

When classification isn't obvious, evaluate along these axes:

| Dimension | Knowledge signal | Not-knowledge signal |
|---|---|---|
| **Specificity** | Contains a concrete claim, finding, or fact | Vague interest, question, or direction |
| **Completeness** | A reader can understand it standalone | Requires conversation context to parse |
| **Actionability** | Changes understanding or behavior | Observation without conclusion |
| **Scope** | One identifiable question/topic | Multiple tangled threads |
| **Mutation signal** | "X is now Y", "stopped X", "changed to Y" | No state change implied |

A capture that scores high on specificity + completeness + actionability + single scope → knowledge. High on mutation signal → data-correction. Low across the board → triage. Clear topic but no content yet → explore.

### Step 2: Route by intent

#### Intent: knowledge

wiki-intake does NOT file knowledge directly. Package the capture as one or more typed candidates and hand them to the **knowledge-integration gatekeeper**, which owns the coherence assessment (dimensions and thresholds per its bundled calibration surface), destination resolution, filing (full [[structural-contract]] envelope per [[handoff-contracts]] §1), duplicate scan, and filing-validator invocation.

**Candidate packaging** — schema per unified-ingress-design §1:

| Field | Derivation |
|---|---|
| `content` | The capture text, enriched to be self-contained — resolve pronouns and implicit references from the invocation context before packaging |
| `kind` | `durable-knowledge` — a proposal; the gatekeeper may re-grade |
| `source_attribution` | Human-readable origin, e.g. "wiki-intake {date} (router delivery)" or "wiki-intake {date} (operator paste)" |
| `provenance` | [[structural-contract]] › Provenance vocabulary: `inbox-capture`, the original URL, or `user-stated` |
| `scope_hint` | Proposed `area/*` — a hint, not authoritative; the gatekeeper resolves the destination |
| `topic_hints` | Proposed `topic/*` values (collapse-bias: prefer existing terms over near-synonyms) |
| `trust` | `registered` for operator-authored or router-delivered content; `unregistered` for pasted third-party or forwarded content |
| `mode` | `interactive` — wiki-intake is an operator-present surface |
| `content_hash` | Hash of `content` (idempotency key) |

One capture may yield multiple candidates (e.g., two distinct findings) — split at packaging if needed; the gatekeeper never splits a candidate.

**Invoke** knowledge-integration (`assess candidates`) with the candidate list. It returns per-candidate dispositions — file (with target path), queue, surface, or discard, each with reasons. Then run Step 3.

#### Intent: data-correction

This is the mutation chain — a fact changed and needs to propagate. It executes **only on explicit operator mutation intent**: the capture itself IS a correction statement ("switched to X", "cancelled Y", "the value is now Z"). If mutation intent is inferred rather than stated, ask/confirm with the operator before touching anything.

Not every correction touches every layer. The reasoning scaffolding below determines which layers are affected before you start modifying files.

**Scoping the correction — reason through these before acting:**

1. **What changed?** State the old value and new value explicitly. "Stopped using Tool-X" = Tool-X status: active → discontinued. "New payment card ending NNNN" = card number updated (or new card issued).
2. **Where is this fact currently recorded?** Search each layer — a fact may live in zero, one, or multiple layers. Only layers that currently hold the old value need updating.
3. **What's the blast radius?** A single-tool change may only touch Data/ and a Knowledge/ file. An address change could ripple through multiple providers and Personal/ pages. Map the full chain before starting edits.
4. **Which edits are appends vs. substance changes?** Appending new information to Knowledge/ is autonomous. Editing existing substance requires human approval. Know which you're doing before you start.

**Execution steps:**

1. **Identify the domain** — which `area/*` does this correction touch?
2. **Load the domain's context page** — understand current state
3. **Identify affected files** (check all layers):
   - Data/ records (if structured data exists for this domain)
   - Knowledge/ files (if the correction affects narrative knowledge)
   - Context page (if working understanding needs updating)
   - Personal/Work pages (downstream, stewarded last)
4. **Apply the correction** through the chain:
   - Data/ → update frontmatter fields via `update_frontmatter`
   - Knowledge/ → append new information (append-bias; don't edit existing substance without approval)
   - Context page → update if working understanding shifted
   - Personal/Work → `patch_note` only (autonomous stewardship rules apply)
5. **Report what was updated** across all layers

**Stop rule:** If the correction would require editing existing substance in a Knowledge/ file (not appending), halt and flag for human approval.

#### Intent: explore

Create a `Wiki/Queue/` item via `/queue create-item` with `queue-kind: explore` — title, description, scope-hint tag (`area/{name}` when known), `source` (router | session | chat | manual). Report the created item path.

#### Intent: triage

Create a `Wiki/Queue/` item via `/queue create-item` with `queue-kind: triage`. Include the raw capture content in the item body so it's not lost. Report the item path and explain why it couldn't be classified cleanly.

(`Wiki/backlog.json` is frozen — never append to it. Queue mechanics: the `/queue` skill owns the item schema and drain.)

### Step 3: Confirm the gatekeeper's report

Applies to the `knowledge`-intent branch. The gatekeeper's report is authoritative — wiki-intake does not re-run duplicate scans, tag validation, or filing-validator; all of that runs behind the gatekeeper.

1. **Completeness check** — every candidate handed over has exactly one disposition in the report. A candidate with no disposition is a lost capture; re-invoke or halt and report.
2. **Relay the report** — filed items with paths; queued items with the queue-item path and reasons; discards with reasons.
3. **Surface, don't resolve** — if the gatekeeper surfaced a conflict, an ambiguity, or an unregistered-trust hold, present it to the operator. Do not resolve it unilaterally.

For the data-correction / explore / triage branches, report what was updated or created (as specified per branch above).

## Stop rules

- Out-of-vault cwd → stage to `Inbox/` with a provenance note and report; never process directly
- Halt when the capture can't be classified cleanly — don't guess
- Halt when a taxonomy decision requires a new `type/*` or `area/*` value — flag for human approval
- Data-correction chain runs only on an explicit operator mutation statement — inferred mutation intent → ask/confirm first
- Halt when a data-correction would edit existing Knowledge/ substance (vs. appending)
- Never file knowledge-intent content directly — candidates go through the gatekeeper, always
- When a data-correction append would push a Knowledge/ file past 150 lines, flag the file as a consolidation candidate (advisory — do not halt; [[structural-contract]] classifies the 150-line threshold as a lint INFO heuristic, not a filing block per [[handoff-contracts]] §1 De-scoping)
- Never delete content as part of intake — intake adds, it doesn't remove

## Notes

- **Provenance is mandatory.** Every candidate carries `provenance` from the [[structural-contract]] Provenance vocabulary; every data-correction append carries date attribution. For user-stated facts, use `user-stated`. For captures, use the original URL or `inbox-capture`.
- **The queue is not a graveyard.** Items surface via the statusline queue signal and are drained via operator-invoked `/queue triage`. Keep descriptions actionable.
- **Data-corrections are the bridge to the chat interface.** When the messaging integration ships, data-corrections will be the primary intent from that channel. The mutation chain defined here is the same chain the chat interface will use.
