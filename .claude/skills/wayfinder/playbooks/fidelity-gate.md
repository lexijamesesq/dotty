# Playbook: fidelity-gate

Certification of a distilled build charter against the decision tickets it cites — run in wayfinder's transition (SKILL.md § Decide, then build). The checker is a validator (SKILL.md § Roles): fresh-context, non-author, tier per the mandate.

## The invariant

An uncertified charter is consumed by nothing — not the adversary, not finalization, not the build lane. Any amendment, whoever made it, voids certification; the charter re-certifies before its next consumer.

## The checker's brief

Codified here so a respawn is reproducible — the spawning session adds nothing:

- The charter text, verbatim. Nothing the drafter says about the sources — no summary, no cited-id list, no reading guidance.
- The checker fetches its own evidence: each cited ticket's whole resolution thread, and the closed-decision roster from its own child-issue query of the map — never the map body's Decisions-so-far (drafter-authored).
- A findings-document pointer is followed only where a resolution carries its substance by pointer. The checker never audits whether a decision read its research correctly — a resolution that misjudged its evidence is still the decision as made.

## The scan — both directions

- **Fidelity:** every claim says what its cited resolution says. A claim more precise than its source is a finding — `EXCEEDS-SOURCE` (added precision is how a decision changes while looking tightened). A settled claim citing nothing is a finding — `UNCITED`.
- **Coverage:** every closed decision lands in a claim or an explicit no-charter-impact line. The map's Out of scope transcription is checked in the same scan.

Findings quote charter and source side by side. The checker never writes charter language — the drafter authors all fixes.

## The loop

The drafter fixes and messages the same checker — amended text only, never an account of the sources; the checker's loaded sources persist across rounds. Across a session boundary, respawn on this brief — identical by construction. Exit: a clean full scan with sources unchanged since read (re-check their `updatedAt`). No caps, no escalation: the checker certifies or it doesn't yet; drift that won't converge is an open question — wayfinder's STOP governs (resolve or ticket it).

## The receipt and its consumption

The checker posts `[FIDELITY]` on the map, riding the `[VALIDATION]` receipt shape and forgery check (`/linear` closing — verdict vocabulary, evidence per probe, Not covered, spawn execution id; an id-less receipt is drafter-posted — refuse it). Deltas from that shape: the receipt lives on the map, and its scan account lists the sources fetched with their `updatedAt` and the coverage roster. Only `CONFIRMED` certifies.

Consumption check — run by the adversary spawn and by finalization: the newest `[FIDELITY]` comment carries an execution id, verdict `CONFIRMED`, and postdates the charter document's last content edit. The build lane inherits certification through the FINALIZED marker — finalization never writes the marker over an uncertified charter, and the build lane's validators are quarantined to the pinned document (`/linear` closing, Step 0.5), never map comments.

## What this playbook does NOT do

- Does NOT give the checker charter-authoring or escalation surfaces — it reports and certifies; the drafter fixes; open questions ticket through the map.
- Does NOT extend the adversary's mandate — fidelity (conformance) and attack (refute) stay separate mandates.
- Does NOT add tracker machinery — no new states, labels, or relations; one comment prefix on the map.
