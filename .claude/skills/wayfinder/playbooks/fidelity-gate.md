# Playbook: fidelity-gate

Certification of a distilled build charter against the decision tickets it cites — run in wayfinder's transition (SKILL.md § Decide, then build).

## The invariant

An uncertified charter is consumed by nothing — not the adversary, not finalization, not the build lane. Any amendment, whoever made it, voids certification; the charter re-certifies before its next consumer.

## Dispatch

Spawn `` `@attack-kitty` `` via the Agent tool with a `charter-fidelity` mandate. Pass the model override per the card's stated tier: sonnet by default, fable when this dispatch is under refute posture (a charter under live adversarial challenge, or a complex multi-decision distillation) — the caller decides posture, `@attack-kitty` doesn't infer it. The mandate inputs:

```
Mandate type: charter-fidelity

Charter text: <verbatim — nothing the drafter says about the sources>

Map id: <map_id>
```

`@attack-kitty`'s `charter-fidelity` mandate card (in the attack-kitty skill's `playbooks/`) carries the full protocol — the two-direction scan (fidelity + coverage), fetching its own evidence (cited resolution threads, the closed-decision roster from its own child-issue query), the `EXCEEDS-SOURCE` / `UNCITED` finding types, the `[FIDELITY]` receipt shape, and the fix-and-respawn loop. This playbook does not restate it.

## The consumption check (this playbook's law, not `@attack-kitty`'s)

Downstream consumers — the map's adversary spawn and finalization — verify before treating the charter as certified: the newest `[FIDELITY]` comment on the map carries verdict `CONFIRMED` and postdates the charter document's last content edit. The build lane inherits certification through the `FINALIZED` marker alone — finalization never writes that marker over an uncertified charter, and the build lane's validators are quarantined to the pinned document (`closing.md` Step 0.5), never map comments.

## What this playbook does NOT do

- Does NOT give the checker charter-authoring or escalation surfaces — `@attack-kitty` reports and certifies; the drafter fixes; open questions ticket through the map.
- Does NOT extend the mandate into attack — fidelity (conformance) and a pressure-test (refute) stay separate mandates.
- Does NOT add tracker machinery — no new states, labels, or relations; one comment prefix on the map.
