---
name: capture-meeting
description: >-
  Captures meeting content. Registered meetings (Tier 1) DUAL-WRITE per-area
  rolling logs in {workspace_root}/Wiki/Knowledge/ PLUS every extracted entry
  emitted as a typed candidate to /gatekeeper. Unregistered meetings
  (Tiers 2/3) are ROUTED-ONLY. Triggers on "/capture-meeting", a matched
  meeting-registry entry, or wiki-intake delegation.
argument-hint:
  - meeting-name
  - meeting-name since YYYY-MM-DD
  - meeting-name meeting-record
  - '(no argument — V2 pipeline, reads from JSON staging)'
context: fork
allowed-tools:
  - Read
  - Edit
  - Write
  - 'Bash(date:*)'
  - 'Bash(ls:*)'
  - Glob
  - mcp__obsidian__read_note
  - mcp__obsidian__write_note
  - mcp__obsidian__patch_note
  - mcp__obsidian__search_notes
  - mcp__obsidian__get_frontmatter
  - mcp__obsidian__update_frontmatter
  - mcp__claude_ai_Google_Drive__read_file_content
---

# /capture-meeting — Recurring Meeting Capture

Source-aware extraction front-end of the knowledge-ingress design. Composes with `/gatekeeper` (the gatekeeper — owns coherence, destination, filing, validation) and cites `../gatekeeper/calibration-surface.md` for the coherence judgment rather than restating it.

## Identity

This skill owns extraction only — it never disposes of a candidate itself:

- **Registered meetings (Tier 1) DUAL-WRITE** — per-area rolling logs in `{workspace_root}/Wiki/Knowledge/` (format-specific parsing) PLUS every extracted entry emitted as a candidate.
- **Unregistered meetings (Tiers 2/3) are ROUTED-ONLY** — candidates only, through the gatekeeper; no standalone meeting file by default.
- **Extraction is exhaustive, not selective** — a unit that fails the coherence filter is still an entry, emitted as `noise`, never silently omitted for looking routine on first read.
- **Coherence judgment is cited, not reinvented** — the four dimensions + thresholds live at `calibration-surface.md` §§1-2 ("amend here, nowhere else"); this skill applies them to entries, it does not restate them.
- **No candidate bypasses the gatekeeper; no extractor writes destinations.**

## Intent

**Objective.** Meeting updates contain decisions, risks, timeline shifts, and strategic insights that future sessions need to answer questions like "what's happening with CacheTrack?" Without capture this knowledge exists only in a rolling doc no one re-reads. This skill extracts; `/gatekeeper` resolves every candidate to file/queue/discard.

**Desired outcomes** (observable):
1. A future session asking about a product area surfaces the relevant capture with date attribution.
2. Meeting knowledge is queryable by topic, not just by meeting name.
3. Captures are substantive — not cluttered with routine status updates.
4. A full meeting doc containing previously-captured content is re-processed correctly — only new content extracts.
5. Every identified entry is accounted for in the extraction report as a candidate with exactly one disposition.
6. Strategic content from unregistered meetings reaches durable homes through the gatekeeper without accumulating standalone meeting files.

**Health metrics — must NOT degrade.**
- No rolling-log file created without `type/meeting-capture` + `area/*` + `topic/*` + `status/*` + `sources`.
- No duplicate dated sections within a rolling-log file; no content filed under the wrong product area (cross-posting detected).
- Coherence bias matches mode (interactive = keep-when-uncertain; automated = discard-when-uncertain) — an uncertain automated entry becomes `noise`, never a filed entry.
- No standalone `meeting-*.md` for an unregistered meeting absent an explicit operator meeting-record request.
- Candidate count reconciles with dispositions in the extraction report; `last_captured` accurately reflects what was processed.

**Strategic context.** One of the ingress design's extraction front-ends, alongside `/capture` (mid-session) and `/wiki-intake` (knowledge branch) — all three hand typed candidates to the one gatekeeper. Worked examples in this family use the Acorndyne universe (`dotty/.claude/skills/sample-universe/universe.md`) for narrative consistency.

**Constraints.**
- **Hard:** never dispose of a candidate itself (no Wiki/Queue/, Personal/Work, Linear, or non-log Knowledge writes); never create a standalone meeting file for an unregistered meeting without an explicit interactive request; never modify existing dated sections in a rolling log (prepend only); never summarize/synthesize rolling-log entries (format normalization only — candidate `content` may be context-enriched, never interpreted).
- **Steering:** coherence bias follows mode (discard-when-uncertain automated; keep-when-uncertain interactive) — but a filtered entry is always emitted as `noise`, never dropped.

**Decision authority.**
- **Autonomous:** parsing + registry matching; coherence filtering (mode-biased); creating/prepending rolling-log files for registered areas; updating `last_captured`; cross-posting detection; proposing `kind` per entry and emitting candidates; one gatekeeper handoff per run.
- **Human-initiated:** adding meetings to the registry; modifying product-area mappings; running the skill; a standalone meeting-record file for an unregistered meeting (explicit request, interactive only).
- **Human-approved:** overwriting an existing dated section (re-capture of a previously processed week).

Content matching a product area NOT in the registry's `product_areas` map no longer halts the run: no rolling-log write, candidates flow through with `scope_hint: null`; interactive mode additionally reports it for a routing decision.

**Stop rules.**
- Meeting name not in registry (V1) or no registry match (V2) → Routed-Only Path — do not halt, do not guess registry entries.
- V1 document has no parseable agenda headings → halt; do not attempt freeform extraction on a registered-format document.
- A dated section already exists in the target rolling-log file and mode is not `all` → halt; report the duplicate, do not silently overwrite.
- V2: all sources in the staging payload are empty or null → report "no source content delivered" and exit.
- Never create a standalone meeting file for an unregistered meeting absent an explicit interactive request.
- Never write to Wiki/Queue/, Personal/Work, Linear, or non-log Knowledge destinations — dispositions belong to the gatekeeper.
- Gatekeeper invocation fails → emit the extraction report with candidates intact and `dispositions` empty; report the error; automated mode: **heartbeat suppressed** — the dead-man's switch is the FAIL sentinel here (silence after a suppressed heartbeat is what surfaces the failure). Do not retry-loop; do not dispose of candidates yourself.

## Navigation

Per invocation, source the content and select the tier (see Dispatch below), then load the matching playbook:

| Branch | Input | Output | Playbook |
|---|---|---|---|
| **Tier 1 — registered (dual-write)** | V1: registry-matched meeting name + document. V2: JSON staging matching a registry `name` | Rolling-log writes + candidates emitted + `last_captured` bumped | `playbooks/registered-capture.md` |
| **Tiers 2/3 — unregistered (routed-only)** | V1: unmatched meeting name + document. V2: JSON staging with no registry match | Candidates emitted only (no meeting file, except explicit meeting-record request) | `playbooks/routed-only.md` |

**Invocation forms:** `/capture-meeting <name>` (since last_captured) · `<name> since <date>` · `<name> all` · `<name> meeting-record` (unregistered standalone file, interactive only) · no argument (V2 pipeline — reads `event_title` from JSON staging).

## Cross-cutting

### Dispatch: source content, then select tier

1. **Source the content, in priority order:** JSON staging (`/tmp/pi-cc-staging/delivered-content.json`, V2) → markdown staging (`delivered-content.md`, V1) → `<delivered-content>` block in the prompt (interactive/router) → Drive fetch (registry has `drive_file_id`) → none (report "No meeting document received." and exit).
2. **Select tier:** JSON staging — match `event_title` against registry `name` fields → Tier 1; else `attendees.length == 2` → Tier 2; else → Tier 3. Markdown/prompt staging — look up `$ARGUMENTS[0]` in the registry → matched → Tier 1 (V1); unmatched → Routed-Only Path.
3. **V2 source priority within a tier:** `gemini_notes` (primary if present — already processed) > `granola_notes` (primary if no Gemini) > `agenda` (primary if neither; the only source type that gets format-specific parsing).

### Mode bias (applies to both branches — registered dual-write and routed-only)

**Mode is declared explicitly on every candidate, never inferred** by the gatekeeper (undeclared mode is treated at automated strictness: queue-only) — detected by the presence/absence of staging files or `<delivered-content>` tags.

- **Automated:** coherence bias discard-when-uncertain; no operator interaction expected, process silently; gatekeeper disposition follows the automated column of the mode × trust × kind matrix (`calibration-surface.md` §4, cited not restated); errors log and exit cleanly — the heartbeat/dead-man's switch surfaces failures (see Stop rules).
- **Interactive:** coherence bias keep-when-uncertain; the gatekeeper may surface borderline candidates and ask, can clarify ambiguous content with the operator; errors report conversationally.

A registered meeting arriving via the pipeline uses `registered-capture.md` with automated-mode bias; an unregistered meeting invoked interactively uses `routed-only.md` with interactive-mode bias — same mode semantics, either branch.

### Candidate schema (emitted by both playbooks, Step 6b)

Candidate schema: `../gatekeeper/SKILL.md` › Candidate schema (canonical). This skill adds `pinned: false` (no operator ask pins in pipeline context) and sources `scope_hint` from the registry's `area` field for registered meetings (null otherwise).

Kind proposals: `../gatekeeper/calibration-surface.md` §3 (canonical definitions + signal mapping). One entry may yield multiple candidates of different kinds (duplication at extraction only, shared provenance). Entries that fail coherence are NOT dropped silently — emitted as `noise` so the extraction report accounts for every identified entry.

### Hand off + extraction report (Steps 7b/8, both branches)

Invoke `/gatekeeper assess candidates` ONCE per run with the complete candidate list (`trust`/`mode` declared per candidate). Do NOT pre-filter kinds the disposition matrix will queue — that's the gatekeeper's call. Every run emits this machine-readable extraction report — the rubric-v2 input, the audit artifact, and the fixture-eval interface — plus a human-readable summary (per-branch report shape lives in each playbook):

```json
{
  "run_id": "<staging event_id, or ISO timestamp for interactive runs>",
  "source": "<meeting name / event_title + date>",
  "candidates": [ "<candidate objects per the schema above>" ],
  "dispositions": [ { "content_hash": "…", "disposition": "file|queue|discard", "reasons": ["…"], "target": "<path or null>" } ],
  "write_plan": [ { "target": "…", "destination_class": "meeting-log|durable-knowledge", "...": "…" } ],
  "applied": [ "<targets actually written this run>" ],
  "queue_items": [ "<Wiki/Queue/ items created by the gatekeeper>" ]
}
```

Entries for EXISTING targets never carry rendered full state (`{target, pre_state_hash, suffix}` only — a whole-file overwrite is structurally impossible from a compliant plan); every NEW file enumerates its content sources; `dispositions`/`queue_items` come from the gatekeeper pass, assembled after handoff returns.

## Meeting Registry

`Wiki/Data/meeting-registry.json` maps meeting name → Tier-1 config (`area`, `meeting_topic`, `product_areas`, `format`, `last_captured`, `cadence`, optional `drive_file_id`). Full field reference + example: `playbooks/registered-capture.md`.

## What this skill does NOT do

- Does NOT create or modify the meeting registry (operator manages meeting configs).
- Does NOT dispose of candidates itself — no Wiki/Queue/, Personal/Work, Linear, or non-log Knowledge writes; file/queue/discard is the gatekeeper's judgment.
- Does NOT summarize or synthesize rolling-log entries — format normalization only; synthesis is a context-page responsibility.
- Does NOT create a standalone meeting file for an unregistered meeting absent an explicit interactive meeting-record request.
- Does NOT modify existing dated sections in rolling-log files — prepend only.
- Does NOT resolve or follow up on "Need" items — captures state (may emit a `personal-action` candidate); does not act on it.
- Does NOT send messages or notifications.
- Does NOT handle non-markdown meeting documents on V1 (V2 handles JSON staging with typed sources natively).
- Does NOT restate the four coherence dimensions or the disposition matrix — both cited from `calibration-surface.md`, never duplicated here.

## References

- `../gatekeeper/calibration-surface.md` §§1-2 — coherence dimensions + thresholds (canonical; cited here, not restated).
- `../gatekeeper/SKILL.md` — the gatekeeper this skill hands candidates to.
- `Wiki/Data/meeting-registry.json` — meeting configuration.
- `dotty/.claude/skills/sample-universe/universe.md` — Acorndyne, the narrative universe for worked examples.
