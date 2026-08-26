# Playbook: chart

Chart-mode procedure — the user invokes with a loose idea, no map yet. Charting is one session's work: it hand-resolves no decision in live exchange, so it posts no closing handoff of its own — its blind-investigation closes carry their own per-ticket `[HANDOFF]`s (step 5), see step 6.

Transition verbs (`claim`, `mark_done`, `cancel`, …) resolve to SKILL.md § Running transitions — its table is the literal invocation; this playbook names the verb, never the command.

## Steps

1. **Name the destination.** Run a `/grilling` and `/domain-modeling` session to pin down what this map is finding its way to — the spec, decision, or change. The destination fixes the scope (SKILL.md § the intro's naming-first law), so it's settled first.

2. **Map the frontier.** Grill again, **breadth-first** this time: fan out across the whole space rather than deep on any one thread, surfacing the open decisions and the first steps takeable now. **If this surfaces no fog** — the way to the destination is already clear, the whole journey small enough for one session — you don't need a map. Stop and ask the user how they'd like to proceed.

3. **Create the map** (label `map`), titled neutrally — the Destination lives in the body, never the title: a child's fetch shows its parent's title, and researchers must not learn the destination from it this way (blindness-protection receipt — the same concern step 5's spawn-prompt discipline exists for). Destination, Done When, and Notes filled in per SKILL.md § The map body's template — Done When co-drafted with the operator at map creation: the spec is hers, never a session's alone — the body carrying its Decisions pointer in place of an inline index (the `Decisions — <map name>` document is created lazily, when the first decision lands — work-through step 5; SKILL.md § The map body), the fog sketched into **Not yet specified**. The map opens assigned to the operator and In Progress (`/linear` create's map-open step) — the effort is live from here; the map is never claimed and never parks (its states are In Progress → Done only; a wedged map is a sweep finding, never a park target).

4. **Create the tickets you can specify now** as child issues of the map, then wire blocking edges in a **second pass** — issues need ids before they can reference each other. Wiring sorts them into the frontier and the blocked; everything you can't yet specify stays in the fog (SKILL.md § Fog of war). Cut every ticket per SKILL.md § Cutting discipline — the full method is the `vertical-slice` skill; invoke it here. This step doesn't restate it. (Which reflexes a slice needs — grill, prototype, investigate — is chosen when the slice is worked, not fixed at the cut; SKILL.md § Resolving a slice.)

5. **Fire the researchers.** For each slice you just cut that is a **blind investigation** (afk, pure fact-finding — SKILL.md § Resolving a slice): run the `claim` transition to claim it — the slice lands in **Planning**. **Attack its research brief before firing** — a blind investigation's plan *is* its brief, so the mandatory plan-attack (SKILL.md § Working stance) tests the brief: is this the right question, is the framing sound, would these findings actually settle the fog it targets? A real pressure-test, never a rubber-stamp. Then run the `begin` transition with `--plan-attested` (afk: the brief-attack ran) — Planning → In Progress — and fire its researcher per that law, in parallel across every such slice this pass. The researcher delivers its findings and returns; the orchestrator (this session) closes the ticket via the `mark_done` transition once the findings contract is met and its close receipts exist — a `[VALIDATION]` and a per-ticket `[HANDOFF]` (validator and shape: SKILL.md § Resolving a slice, the investigate bullet — stated once there, never restated here) — recording the resolution per SKILL.md § Tickets' answer-on-resolution law.

6. **Stop.** Each blind-investigation close in step 5 carries its own per-ticket `[HANDOFF]` (findings-forward context, posted on the ticket before the close — M-h requires one for a map-child close). Beyond those, charting hand-resolves no decision in live exchange, so it posts no closing handoff of its own — distinct from work-through's slice-wrap act.

## What this playbook does NOT do

- Does NOT resolve decision tickets or run the map's live-exchange work past the researcher-firing in step 5 — that's `playbooks/work-through.md`'s job, the next session to touch this map.
- Does NOT restate `/linear`'s create/claim/mark_done mechanics or the blind-investigation researcher-firing law — SKILL.md carries those once; this playbook cites them at their firing point.
- Does NOT cross into the doing phase or touch phase two — see SKILL.md § Decide, then build.
