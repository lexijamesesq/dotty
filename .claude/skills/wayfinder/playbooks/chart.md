# Playbook: chart

Chart-mode procedure — the user invokes with a loose idea, no map yet. Charting is one session's work: it never resolves a ticket, so it never posts a `[HANDOFF]` — see step 6.

## Steps

1. **Name the destination.** Run a `/grilling` and `/domain-modeling` session to pin down what this map is finding its way to — the spec, decision, or change. The destination fixes the scope (SKILL.md § the intro's naming-first law), so it's settled first.

2. **Map the frontier.** Grill again, **breadth-first** this time: fan out across the whole space rather than deep on any one thread, surfacing the open decisions and the first steps takeable now. **If this surfaces no fog** — the way to the destination is already clear, the whole journey small enough for one session — you don't need a map. Stop and ask the user how they'd like to proceed.

3. **Create the map** (label `map`), titled neutrally — the Destination lives in the body, never the title: a child's fetch shows its parent's title, and researchers must not learn the destination from it this way (blindness-protection receipt — the same concern step 5's spawn-prompt discipline exists for). Destination, Done When, and Notes filled in per SKILL.md § The map body's template — Done When co-drafted with the operator at map creation: the spec is hers, never a session's alone — Decisions-so-far empty, the fog sketched into **Not yet specified**. The map opens assigned to the operator and In Progress (`/linear` create's map-open step) — the effort is live from here; the map is never claimed and never parks (its states are In Progress → Done only; a wedged map is a sweep finding, never a park target).

4. **Create the tickets you can specify now** as child issues of the map, then wire blocking edges in a **second pass** — issues need ids before they can reference each other. Wiring sorts them into the frontier and the blocked; everything you can't yet specify stays in the fog (SKILL.md § Fog of war). Type a ticket as `prototype` when a throwaway artifact would resolve the question faster than conversation — shape questions, competing approaches that need to be seen, state models too complex to reason about on paper; type as `grilling` when the question resolves in dialogue. Grilling is the default; prototype earns its place when making is cheaper than talking. Cut every ticket per SKILL.md § Cutting discipline (the four principles and two tests) — that law fires here in full; this step doesn't restate it.

5. **Fire the researchers.** For each `research`+`afk` ticket just created, run traffic-cone's fused `claim` script to claim it, then fire its researcher per SKILL.md § Ticket Types' `research`+`afk` law, in parallel across every such ticket this pass. The researcher delivers its findings and returns; the orchestrator (this session) closes the ticket via traffic-cone's fused `resolve` script once the findings contract is met, recording the resolution per SKILL.md § Tickets' answer-on-resolution law.

6. **Stop.** Charting hand-resolves nothing this session, so it posts no `[HANDOFF]` (nothing worked, nothing to hand off — the receipt this step exists to name, distinct from work-through's closing act).

## What this playbook does NOT do

- Does NOT resolve decision tickets or run the map's live-exchange work past the researcher-firing in step 5 — that's `playbooks/work-through.md`'s job, the next session to touch this map.
- Does NOT restate `/linear`'s create/claim/resolve mechanics, the Cutting discipline tests, or the `research`+`afk` researcher-firing law — SKILL.md carries those once; this playbook cites them at their firing point.
- Does NOT distill a charter or touch phase two — see SKILL.md § Decide, then build.
