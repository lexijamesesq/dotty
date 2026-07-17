# Playbook: process

Sweep the whole Inbox: classify, match, deliver, delete — every capture, one operator-present session.

## Input

- `today` — ISO date (defaults to system date)
- Operator presence (interactive-only; this playbook has a mandatory approval checkpoint)

## Protocol

### 1. Setup

- Resolve the vault root via the `workspace_root` config key (global CLAUDE.md > Configuration; fallback `VAULT_ROOT` env). Unresolvable → halt (Stop rule).
- Enumerate `Inbox/*.md` (`mcp__obsidian__list_directory`). Exclude every file tagged `type/dashboard` (generated views — e.g. the Unprocessed Captures dashboard), and any file carrying a `routed:` frontmatter stamp from a prior run (already delivered; surface it as a retained-delivered leftover instead of re-routing).
- **Zero captures after exclusions → stop silently.** No sweep plan, no summary, no deliveries, no "inbox is empty" chatter.

### 2. Discover destinations (runtime)

Per SKILL.md § Destination resolution. Fresh discovery every run — never a cached map.

### 3. Classify every capture (read-only pass)

For each capture, via `mcp__obsidian__read_note`:

1. Read full content including existing frontmatter.
2. Classify per spec § Classification Taxonomy — `professional-strategy | professional-operational | personal | meta` — with confidence (high/medium/low). Spec § Classification Examples calibrates the call.
3. Two-axis evaluation per spec § Knowledge Axis Classification: Task and Knowledge fire independently; both, either, or neither are valid outcomes.
4. Detect specialized routes per spec § Contract Resolution: Slack weekly team update (spec's detection criteria), ad-hoc Slack capture (signal-extraction candidate), `professional-strategy` (Incubator seed).
5. **Coverage check:** search for prior coverage before proposing a new delivery — Linear duplicate check per `linear-discipline` § Integrity on Creation, existing seed filenames per spec § Processing Behavior. A capture requesting a capability or artifact that already exists is a **superseded-candidate**: surfaced with evidence, never silently filed, never silently discarded.

### 4. Present the sweep plan (mandatory checkpoint)

One table: capture | classification (confidence) | axes fired | destination + delivery method | proposed end state (delete / retain / ask). Present to the operator and get approval **before any delivery executes**.

- Operator approves the plan → that approval IS the batch confirmation for the deletions the plan lists.
- Operator may instead request per-file confirmation, amend rows, or pull captures out of the sweep.
- Rows marked "ask" (superseded-candidates, ambiguous items resolvable in a sentence) are settled during this checkpoint.

### 5. Deliver per capture

Route in this order. Task-side: first match wins. Knowledge axis: evaluated under its own rules, independently.

**a. Specialized routes (spec-owned, pre-architecture — execute per spec, do not restate here):**
- `professional-strategy` → a strategy seed per spec § Seed Creation, conforming to the destination project's intake contract (`{workspace_root}/Projects/<strategy-seed-project>/CLAUDE.md` → Intake `### Notes` → its own reference doc; vault-resident, does not ship in this repo). Exact-duplicate check against existing seed filenames first.
- Slack weekly team update → per-designer activity log entries per spec § Team Activity Log Creation, conforming to the destination project's contract (`{workspace_root}/Projects/<team-activity-project>/team-activity-log-spec.md`; vault-resident, does not ship in this repo).
- Ad-hoc Slack capture → signal extraction per spec § Slack Signal Extraction (clear signal → seed; possible signal → summary flag, no seed); the capture itself then continues down the default path below.

**b. Project-owned (confident `project/*` match):**
- **Task axis** → Linear issue per `{workspace_root}/System/Knowledge/unified-ingress-design.md §14` § Default Delivery: Linear Issue (teamId + Project ID from the destination's `### Tasks`), satisfying `linear-discipline` integrity-on-creation. Captures of 3+ sentences or with structure get a `Context/` doc with `## Original Capture` per the Origin Handoff Contract; a ≤2-sentence capture's description must reproduce it completely.
- **Knowledge axis** → ONLY if the destination's CLAUDE.md frontmatter includes `knowledge_intake: true` (read via `get_frontmatter`; absent or false = opt-out, not oversight; the Task axis still fires independently). `Knowledge/` is the standardized location. Deliver per spec § Knowledge Delivery Rules: structural envelope, provenance via `sources` frontmatter, index update when an index exists, the filing-time lint gate confirmation, dual-axis cross-reference when both axes fired. `Knowledge/` directory missing on disk → do not create it; queue-triage this axis.

**c. Domain-owned (no project match, identifiable domain via lightweight area identification):**
- **Knowledge axis** → hand the FULL VERBATIM capture + the lightweight area identification + source filename to `/wiki-intake`, declaring `mode: interactive`, `trust: registered`. Full stop — wiki-intake owns everything downstream. Record its reported outcome for the summary; a reported outcome is the delivery confirmation for this axis.
- **Task axis** → append to the domain page's existing task section (`Personal/{Domain Title Case}.md` or `Work/{Domain Title Case}.md`) per spec § Domain Destinations (Task axis): auto-id checklist item via `mcp__obsidian__patch_note`, verbatim-overflow rules per the Origin Handoff Contract. Page or task section absent → queue-triage (never create pages or sections).

**d. No home / ambiguous / needs deferred judgment** → `/queue create-item`: `queue_kind: disposition`, `source: router`, `reasons` naming why no autonomous route exists, scope tags when identifiable (absence noted in reasons), payload = **full verbatim capture** + evidence (candidate destinations considered, what was missing). The verbatim payload is what makes queue delivery satisfy the Origin Handoff Contract.

**e. Superseded-candidate** → present the evidence (the existing skill/doc/ticket) at the checkpoint; the operator chooses: **discard** (delete, logged in the summary as an explicit operator discard), **queue** (park the judgment), or **deliver anyway**. Never auto-discard.

### 6. Verify provenance, then delete

Per delivered capture, verify per route before deletion:

| Route | Provenance check |
|---|---|
| Incubator seed / signal seed | `## Original Capture` section present, verbatim |
| Linear issue | Description reproduces a ≤2-sentence capture, OR context doc with `## Original Capture` exists |
| Project Knowledge file | `sources` frontmatter present; the filing-time lint gate PASS reported |
| `/wiki-intake` delivery | wiki-intake reported a concrete disposition for the capture |
| Domain-page task append | Checklist item present; verbatim overflow handled per contract |
| Queue item | Item file created (path returned) with full verbatim payload |
| Team activity logs | Per-designer entries created; W: content verbatim |

Then delete via `mcp__obsidian__delete_note`, under the confirmation mode established at the checkpoint (approved plan = batch; otherwise per-file). Declined confirmation or failed verification → the file stays; stamp additive `routed: <destination> (<date>)` frontmatter via `mcp__obsidian__update_frontmatter` (body untouched) and record the retained-delivered state in the summary.

### 7. Session summary

Emit per spec § Output Schema: per-item YAML records plus the session summary (classified items, delivery summary, needs-review, duplicates detected, signals extracted, possible signals, statistics, and items remaining in the Inbox with the reason each remains).

## Discipline

- **Zero silent drops.** Every enumerated capture ends the run as exactly one of: filed artifact, queue item, or explicit halt-and-ask recorded in the summary. Discards exist but only as logged operator decisions.
- **Ask vs queue:** halt-and-ask is for ambiguity the present operator can resolve in a sentence; captures needing a design conversation, missing structure, or future judgment go to the queue.
- **No delivery before the checkpoint.** Classification is read-only; nothing mutates until the operator has seen the plan.
- **One disposition per capture** (plus independently-fired Task/Knowledge axes, cross-referenced when both land).
- **Failures are loud.** A failed delivery, failed queue write (the `/queue` playbook reports FAIL), or failed verification is reported per capture — never papered over by proceeding to deletion.

## What this playbook does NOT do

- Does NOT decide Wiki-internal placement, intent, or handler questions — delivery to `/wiki-intake` ends the Router's Wiki-axis responsibility.
- Does NOT process the `Unprocessed Captures` dashboard or any `type/dashboard` file.
- Does NOT create destination structure, develop content, or consolidate related captures.
