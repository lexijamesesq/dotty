# Playbook: registered-capture

Tier 1 dual-write: parse a registered meeting (V1 document or V2 JSON staging), write per-area rolling logs, and emit every extracted entry as a candidate to the gatekeeper.

## Input

```yaml
meeting_name: <string>       # V1: $ARGUMENTS[0], matched against registry `name` fields
event_title:  <string>       # V2: from JSON staging, matched the same way
content:      <document | sources[]>   # per navigator Dispatch — the sourced content
date_arg:     since <YYYY-MM-DD> | all | null   # V1 only
```

## Meeting Registry

`Wiki/Data/meeting-registry.json` — structured config mapping meeting names to their properties.

```json
{
  "canopy-triad-sync": {
    "name": "Canopy Triad Sync",
    "drive_file_id": "EXAMPLE_DRIVE_FILE_ID_REDACTED",
    "area": "area/work/acorndyne",
    "meeting_topic": "topic/canopy-triad-sync",
    "product_areas": {
      "CacheTrack": "topic/cachetrack",
      "GMS": "topic/gms",
      "Ledger": "topic/ledger",
      "CAP": "topic/cap"
    },
    "format": "moved-learned-need",
    "last_captured": null,
    "cadence": "weekly/thursday"
  }
}
```

**Fields:** `name` (source attribution) · `drive_file_id` (optional; when present the skill auto-fetches via Drive MCP, when absent it expects router/paste delivery) · `area` (tag on all captures, `scope_hint` on candidates) · `meeting_topic` (full topic tag) · `product_areas` (section-heading keyword → topic tag map; also used for cross-posting detection) · `format` (parser hint; only `moved-learned-need` is currently supported) · `last_captured` (ISO date, `null` on first run) · `cadence` (informational only).

## Protocol

### V1 path — parse the document

1. **Parse structure:** week delimiter `## Agenda for {date}` / `## **Agenda for {date}**`; product-area sections as bold headers (`**GMS**`); bulleted content entries; `## Decisions Made` sections (capture if non-empty). Build a structured `[{date, iso_date, product_areas: {name: [{prefix, content, owner}]}, decisions}]` representation. Normalize dates via `Bash(date:*)`.

2. **Determine capture window:**

   | Condition | Window |
   |---|---|
   | No date arg, `last_captured` null | All weeks (first capture) |
   | No date arg, `last_captured` set | `iso_date > last_captured` |
   | `since YYYY-MM-DD` | `iso_date >= argument_date` |
   | `all` | All weeks — prompt if existing rolling-log files would be overwritten |

   Empty window → report "No new entries since {last_captured}." and exit.

3. **Parse entry prefixes** (format `moved-learned-need`): `Moved` (progressed/shipped) → `- **Moved** -- `; `Learned` (insight/discovery) → `- **Learned** -- `; `Need` (request for help/decision/unblocking) → `- **Need** -- `; no prefix → sub-bullet, preserved under parent.
   - **Owner extraction:** strip mechanical `- [Name](mailto:...)` / trailing `- Name` attribution; content-embedded names are preserved.
   - **Cross-posting:** file content under its actual product area, not the section heading it appeared under — use the `product_areas` keyword map; when ambiguous, file under the section heading and note the ambiguity; when cross-posted, add a parenthetical noting the original section.
   - **Empty product areas (both V1 and V2 paths):** if all entries for a registered area are cross-posted elsewhere or filtered, do not create an empty rolling-log file — report "Skipped."
   - **Template/placeholder detection:** agenda weeks containing only template text (e.g., "Moved Topic - Owner") are not real content — skip entirely, don't count in the window, don't emit candidates for them.

### V2 path — multi-source processing

Select the primary source from `sources[]` per the navigator's source-priority rule (Dispatch step 3).

1. Select primary source.
2. If the registry entry has `format`: apply the format-specific parser above to the `agenda` source if present. For `gemini_notes`/`granola_notes` (already processed), extract using first-principles — don't force a format parser on pre-processed content.
3. Apply product-area routing from `product_areas`.
4. Apply the coherence filter (below).
5. Write to rolling logs with provenance URLs from source `url` fields.
6. Emit candidates, then hand off per the navigator.

**Provenance in V2 output:** each source's `url` surfaces in candidates' `provenance`, and — for rolling-log (and meeting-record) files — as a source line inside the dated section itself, never in existing-file frontmatter. Every prepended dated section (new file's first section, or a later prepend) opens with one source line per contributing source, before the first content bullet:

```markdown
## {date}

*Source: [gemini notes](https://docs.google.com/document/d/...) · captured by routine/capture-meetings <run-id>*

- **Moved** -- Content here
```

Format: `*Source: [{source type} notes](<url>) · captured by <provenance run-id>*` — one line per source carrying a URL; a source without a URL (e.g. an operator paste) is omitted. This section-body line is the **entire provenance surface** for a run against an EXISTING log — the file's `sources:` frontmatter list is populated once, at creation, and never revisited by later runs. This is the F01 fix: the dated-section source line, not frontmatter, is what carries provenance forward on every subsequent prepend.

### Coherence filter

Apply the four dimensions at the standard threshold (any two of four — the Tier-1 log bar) per `calibration-surface.md` §§1-2, cited not reinvented. Bias by mode per the navigator (discard-when-uncertain automated / keep-when-uncertain interactive); a filtered entry still emits as a `noise` candidate.

**Worked examples** (Acorndyne universe; `<thinking>` traces demonstrate the reasoning style — KEEP means log entry + candidate; FILTER means no log entry, `noise` candidate):

**1 — KEEP (Learned, strategic timeline shift).** `Learned The Cache-to-Ledger data migration is a fundamental prerequisite to the GMS. Current delays suggest the earliest CacheTrack could be integrated into the GMS is now likely 2028, a timeline the Drey Council had previously found unacceptable.`
<thinking>Queryability high ("what's the CacheTrack-to-GMS timeline?"); durability high (2028 shift, exec-level implications); specificity strong (prerequisite, date, stakeholder reaction named); independence passes. KEEP — durable-knowledge + context-shift (two candidates, one entry).</thinking>

**2 — FILTER (Moved, routine status).** `Moved Onboarding one additional engineer (3rd in total) to GMS Delivery Settings. Overall progress is steady.`
<thinking>Queryability low; durability low (stale within a sprint); specificity moderate but routine; independence fine. FILTER — noise candidate.</thinking>

**3 — KEEP (Need, escalation with strategic stakes).** `Need A definitive decision from the director level or above on the CAP long-term strategy (continue or pivot) following the upcoming offsite. We need clarification on whether we should proceed with escalating the current authentication blocker.`
<thinking>High on all four dimensions (decision level, decision type, trigger, linked blocker all named). KEEP — durable-knowledge; also personal-action if the escalation is the operator's to drive.</thinking>

**4 — KEEP with context enrichment (Moved, borderline but specific).** `Moved AI features migrated over to Tool-X; PR simply needs to be merged.`
<thinking>Moderate queryability/durability, specific claim, independence borderline ("Tool-X" unexplained but searchable). KEEP — durable-knowledge.</thinking>

**5 — FILTER (redundant with prior capture).** `Moved CAP: the lightweight sync piece might be quick and easy to solve, the tracking piece needs more custom dev around the streaming pipeline, in progress.` (Prior week already captured: `Need CAP project at risk: cascade deletes still not right, cascade updates also not handled.`)
<thinking>Incremental info is thin relative to the existing at-risk capture; dominant signal is still "in progress." FILTER — noise candidate; a material status change next week is its own entry.</thinking>

### Write to per-area rolling logs

**File naming:** `{workspace_root}/Wiki/Knowledge/meeting-{meeting_slug}-{product_area_slug}.md` (slugs from tag values, e.g. `topic/cachetrack` → `cachetrack`).

**New files:**

```markdown
---
tags:
  - type/meeting-capture
  - {area tag}
  - {meeting_topic tag}
  - {product_area_topic tag}
  - status/active
updated: {most recent entry date}
sources:
  - "{meeting name}"
---

## {date}

*Source: [{source type} notes](<url>) · captured by routine/capture-meetings <run-id>*

- **Moved** -- Content here
- **Learned** -- Content here
- **Need** -- Content here
```

Tags use the `tags:` array — the vault's tag query system reads this, not standalone fields. Do not create standalone `type:`, `area:`, or `status:` fields alongside it.

**Existing files:** read the file; prepend the new dated section after frontmatter and before the first existing `## {date}` heading. The prepended section's FIRST line is the source line (above) — this is how provenance survives the frontmatter freeze on existing logs. Update `updated` to the new most-recent date. This prepend + `updated` bump is this playbook's **entire write surface on an existing log** — never edit existing dated sections or other frontmatter. Multiple weeks: prepend in reverse chronological order (newest at top).

### Emit candidates, update registry, hand off, report

1. Emit every entry from parsing/filtering above as a candidate per the navigator's schema, with `trust: registered`.
2. **Update registry:** set `last_captured` to the most recent `iso_date` captured (V2: the event date); write back to `Wiki/Data/meeting-registry.json`.
3. **Hand off** per the navigator (one `assess candidates` call, complete list). There is no separate post-write validation call — the former registered-path `assess single` confirmation is removed. The rolling-log writes above are this playbook's own E2E-validated surface; in automated mode the orchestration-tier critic gate (capture-rubric v2) validates the extraction report + composed artifacts pre-commit, separately from the gatekeeper pass.
4. **Report:**

```
Captured {meeting name}: {start_date} through {end_date}

Rolling logs:
  - meeting-canopy-triad-sync-cachetrack.md -- {N} entries ({date1}, {date2})
  - meeting-canopy-triad-sync-gms.md -- {N} entries ({date1})

Candidates: {N} emitted -> {n} filed, {n} queued, {n} discarded (noise/duplicate)
Skipped: {product areas with no substantive content}

Updated last_captured: {date}
```

Plus the extraction report (navigator schema). Automated mode: this report is the capture-rubric v2 input; errors log and exit cleanly; the heartbeat confirms success.

## Failure modes

| Condition | Behavior |
|---|---|
| Drive fetch fails (registry has `drive_file_id`) | Report the specific Drive error (auth, missing file, network), exit without writing. Do not fall back to paste mode silently. |
| No document content provided (registry has no `drive_file_id`) | Report "No meeting document received. Either add `drive_file_id` to the registry entry or provide content via router or paste.", exit |
| Doc has no parseable agenda headings | Report "Could not parse agenda structure", exit (this IS the navigator's halt stop rule) |
| Date argument is unparseable | Report format error, exit |
| No new content since `last_captured` | Report "up to date", exit |
| All entries fail coherence | No rolling-log writes; every entry emitted as a `noise` candidate; extraction report complete; heartbeat fires (automated). Report "no substantive entries found for this period." |
| Rolling-log write fails | Report error, do not update `last_captured` |
| Content matches unknown product area | No log write; emit candidates with `scope_hint: null`; interactive mode additionally reports the unmatched content for a routing decision |

## What this playbook does NOT do

- Does NOT apply format-specific parsing to `gemini_notes`/`granola_notes` — first-principles extraction only (they're already processed).
- Does NOT edit existing dated sections or non-`updated` frontmatter on an existing log.
- Does NOT dispose of candidates — hands off to the gatekeeper, same as `routed-only.md`.
- Does NOT restate the four coherence dimensions — cited from `calibration-surface.md` §§1-2 per the navigator.
