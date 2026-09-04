# Mutation-Record Spec

How a mission record — a ticket description, a map body section, a Project Update, an accounting document — may legally be changed after it first lands. This spec governs `@traffic-cone`'s checks and the mutations it executes directly, following `/linear`'s playbooks for mechanical protocol; it is the reference to load before mutating anything that isn't a fresh append.

A **mission record** is any artifact the lifecycle relies on to know what was decided or what is true: ticket descriptions, ticket comments, the map body (Destination / Done When / Notes / Fog / Out of scope), the map's Decisions document, Project Updates, the map's accounting document.

## Two mutation methods

**Mutate-in-place.** The record is overwritten; the new content replaces the old as the thing readers consume going forward. Linear's own edit history is the only trace of what stood before.

**Append.** The record only grows. Existing entries are never edited or removed; a correction is a new entry, not a rewrite of an old one.

## Selection by mode

Every mission-record class has exactly one mode, fixed by what the record is *for* — not chosen per edit:

- **Current-truth mode → mutate-in-place.** The record represents what is true *now*: a ticket's `## Objective` / `## Done When` / `## Constraints` / `## Context`, the map's `## Destination` / `## Done When` / `## Notes` / `## Fog` / `## Out of scope`.
- **Evolution mode → append.** The record represents what happened *over time*, and the sequence itself is the value: ticket comments (progress notes, `[VALIDATION]` verdicts), the map's Decisions document (the decision index), Project Updates.

A record's mode never toggles per invocation. If a caller wants evolution-mode behavior from a current-truth record (or vice versa), that is a request to reclassify the record, not an edit — reclassifying is a map-intent change (see Standing Rule 2) and routes to the operator.

**Foundation records** are a protected subset of current-truth records: work downstream is built on their claims, so an unauthorized mutation invalidates that work silently. Today's one instance: the map's **operator-confirmed Destination + Done When** — the settled spec every doing-phase slice builds on. A foundation record's mode is current-truth *plus* an authorization gate (below) — mutate-in-place is still the method, but it never runs on session judgment alone.

## Authorization

A current-truth mutation runs on the session's own judgment — that's what "current" means, the record tracks the latest agreed state and any session with reason to update it may. A **foundation-record** mutation never does. It runs only under one of two receipts:

1. **A dispositioned audit finding** — a fresh-context checker (e2e eval, `map-close-eval`, or equivalent) named the claim wrong against a receipt, and that finding has been dispositioned (accepted, not merely raised).
2. **Operator direction** — she said to change it, in the exchange or in a comment on the record itself.

Never a session's own inference that the record "should" be different — that is exactly the failure mode the gate exists to stop. A mutation with neither receipt is refused, full stop, regardless of how confident the session is.

## History and revertibility

Mutate-in-place records keep their pre-state in exactly one place: Linear's native edit history on the field or document. This spec does not introduce a parallel version store — there isn't one, and a mutation that needs a durable pre-state snapshot beyond Linear's own history is a signal the record should have been append-mode instead. For the map's Destination + Done When specifically, the edit lands on the map issue's own description field via `update_description` — the field's native Linear edit history is the pre-state trace; what mutated is visible there.

## Marking scheme

Every mission-record class carries a marker, readable at the point of use, that tells a session which mode it's looking at and whether authorization gates a change:

- **Map Destination + Done When:** no runtime marker — the foundation-grade protection is a **convention gated by the operator**, not a surface flag. A Destination or Done When edit is a map-intent change, made only with the operator's approval (Standing Rule 1) — the same operator-gated discipline the wayfinder skill states for a claimed Done When.
- **Ticket Done When:** the `_to be set at claim_` deferral marker signals "not yet current-truth" — mutable freely until claim sets real conditions, after which Objective/Done When edits route to the operator regardless of marker (claim Step 3's rule, unchanged by this spec).
- **Ticket comments / map Decisions document:** no runtime marker needed — evolution mode is structural, but the two are held to it differently. For ticket comments (and Project Updates), the mechanical surface enforces it: `/linear` appends via `createComment`, never `updateComment` for a landed entry — the absence of an edit action on the surface *is* the marker. For the map's Decisions document the discipline is now also mechanically enforced, not convention alone: `linear_bridge.py decisions-append` is the only sanctioned write path — fetch immediately before write, refuse a duplicate entry, append, write, read back, and verify the pre-write content survives as an exact prefix, retrying on a detected race — closing the gap a whole-content-overwrite update surface otherwise leaves open. Its role as the append-only decision index — established by SKILL.md § The map body, honored as one dated entry per closed ticket, never a rewrite of a landed entry — is still the marker; the primitive is what makes a session honoring it mechanical rather than a hand sequence someone can get wrong under time pressure.
- **Project Updates:** structural, same as above — each PU is a new record, never a rewrite of a prior one.

The rule for any future mission-record class: if it doesn't already carry one of these structural markers, it needs an explicit one before it ships — a class with no readable marker is a class whose mutation discipline nobody can check.

## Integration contract

1. **Traffic-cone's mechanical execution reads and writes records, never interprets them as gate input on its own.** Following `/linear`'s `playbooks/documents.md` and `playbooks/transitions.md` protocols: `update_description` and `comment` execute whatever the caller directs. The write itself trusts the authorization already checked in the gate step below — it does not re-derive it.
2. **The gate is operator-in-the-loop, not a scripted marker check.** The map's Destination + Done When carry no runtime marker for a script to gate on; their protection is that a change to either is a map-intent change, made only with the operator's approval (Standing Rule 1). No `cone_preflight` check and no `close-map` step gates on a foundation-record marker.
3. **Any session encountering an unmarked mutate-in-place record it suspects is foundation-grade** stops and asks the operator whether it needs the marker, rather than guessing. Silence is not a mode.

## Standing rules (operator-ratified)

These three rules, previously carried as an interim note in the map's `## Notes` section, are superseded by this spec as their canonical home:

1. **Maps are created collaboratively; changing map intent mid-flow flags to the operator.** The Destination is current-truth but not a session's to redraw alone — a Destination edit is a map-intent change, routed the same way a ticket's Objective edit is (claim Step 3's rule, same shape at map scope).
2. **Decision modes are classifications, not preferences; moving between modes is a map-intent change.** Reclassifying a ticket's loop label (`hitl`↔`afk`) mid-flight changes who drives its resolution — that's a scope decision, not a housekeeping edit, and routes to the operator the same as any other map-intent change.
3. **Foundation records mutate only under a dispositioned audit finding or operator direction — never session-inferred.** This is the Authorization section above, restated as the rule it always was; the map's operator-confirmed Destination + Done When is the first instance, not the only one this rule is written for.
