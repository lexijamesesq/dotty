# Playbook: routed-only

Tiers 2/3 (unregistered meetings): extract candidates without a registered format or product-area map, hand them to the gatekeeper, never write a meeting file (one narrow exception below). Applies whenever the meeting is not in the registry: V1 invocations with an unknown name, pipeline deliveries with an unknown `meeting_name`/`event_title`, and V2 Tiers 2/3. The skill does NOT halt on this — it's a normal path, not an error.

## Input

```yaml
content:    <document | sources[]>   # per navigator Dispatch — the sourced content
attendees:  <int>                    # V2 only; length == 2 selects Tier 2, else Tier 3
mode:       automated | interactive  # per navigator Mode bias
```

## Protocol

1. **Select tier** (V2 only; V1 unregistered is always treated at the Tier 3/universal threshold): `attendees.length == 2` → Tier 2 (1:1 modifier); else → Tier 3 (universal). V2 source selection follows the navigator's source-priority rule (Dispatch step 3) same as the registered playbook.

2. **First-principles extraction.** No format-specific parsing — no registry entry means no format hint and no `product_areas` map. Scan the delivered content for decisions, action items, strategic insights, blockers, timeline shifts, and dependencies. **Extraction is exhaustive, not selective**: segment the ENTIRE delivered content into discrete units (topics, paragraphs, or standalone bullets) FIRST — every unit is an entry, whether or not it names a decision/action/insight on its face. Each entry then runs the coherence filter below; a unit that fails is still an entry, emitted as `noise` — never silently omitted for looking routine. All-routine content therefore yields a `candidates[]` list populated with `noise` entries, never an empty list.

3. **Coherence filter**, per `calibration-surface.md` §§1-2 (cited not reinvented), at the tier's threshold:
   - **Tier 3 (universal):** standard — any two of four dimensions.
   - **Tier 2 (1:1 modifier):** elevated — three of four, with stricter queryability ("would a future session search for this in a *professional* context?"). Passes: commitments with deadlines, escalations, project-direction decisions, blockers affecting the broader team. Below the bar: career development, feedback, personal check-ins, venting.

   Bias by mode per the navigator (discard-when-uncertain automated / keep-when-uncertain interactive). Entries below the bar → `noise`, never silently dropped. For worked KEEP/FILTER examples applying this same four-dimension judgment, see `registered-capture.md`'s Coherence filter section — the reasoning style is identical, only the source format (parsed Moved/Learned/Need vs. first-principles units) differs.

4. **Emit every extracted entry as a candidate** per the navigator's schema, with `trust: unregistered` and the declared mode.

5. **Do NOT write a meeting file** — the one exception is below. **Hand off** to the gatekeeper (one `assess candidates` call, per the navigator). Per the disposition matrix, automated + unregistered candidates land in Wiki/Queue/ or are discarded — never filed autonomously.

6. **Report:**

```
Processed {event_title} (Tier {2|3}): {N} entries extracted -> {N} candidates
Dispositions: {n} filed, {n} queued, {n} discarded
No meeting file created (routed-only).
```

If the gatekeeper discards everything: "no substantive content identified for this meeting."

## The one exception: explicit meeting-record request (interactive only)

When the operator explicitly asks for a meeting record (`meeting-record` argument, or an unambiguous in-conversation request), additionally write `{workspace_root}/Wiki/Knowledge/meeting-{slugified-event-title}.md` with tags `type/meeting-capture` + `area/work/acorndyne` + `topic/{slugified-event-title}` + `status/active`, a dated section body, and `sources:` carrying provenance URLs. Candidates still route through the gatekeeper as normal — the meeting-record write does not substitute for the candidate handoff.

## What this playbook does NOT do

- Does NOT create any vault file, except the one explicit meeting-record exception above.
- Does NOT attempt format-specific parsing — no registry entry means no format hint.
- Does NOT use `product_areas` routing — no registry entry means no area map.
- Does NOT restate the four coherence dimensions — cited from `calibration-surface.md` §§1-2 per the navigator.
- Does NOT dispose of candidates — hands off to the gatekeeper, same as `registered-capture.md`.
