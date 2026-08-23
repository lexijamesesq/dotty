# Playbook: work-through

Work-through-mode procedure — the user invokes with a map (URL or number). A ticket is **optional**: without one, you pick the next decision, not the user.

Transition verbs (`claim`, `resolve`, `cancel`, `close-map`, …) resolve to SKILL.md § Running transitions — its table is the literal invocation; this playbook names the verb, never the command.

## Steps

1. **Load and sweep.** Load the map body (low resolution, not every ticket body). Run `map_sweep.py <map-id>` (`.claude/skills/linear/scripts/`) — it returns the map's state, the ordered `frontier` (with `frontier_rule` naming the ordering — never re-derive it), and every detection array: `orphaned_research`, `parked`, `blocked`, `stale_claims`, `decisions_missing`, `handoff_missing`, `last_resolved` (with its `[HANDOFF]` text), `ending_due`, `wedged`. The script owns detection mechanics; its report is input to your orientation, not the orientation — read the map and judge. Judgment on its output stays this session's:
   - Read `last_resolved`'s `[HANDOFF]` text first — it names the recommended next act and carry-forward context; skip re-deriving what it covers.
   - Return operator-confirmed parked tickets to the frontier.
   - `decisions_missing` — spot-check the resolution text each entry supplies as evidence, then copy the gist into the map's Decisions document (gists copied, never authored fresh; SKILL.md § The map body — the Decisions document).
   - `orphaned_research` — findings doc and resolution comment both already exist, so run the `resolve` transition to close each, then copy its gist into the map's Decisions document the same way.
   - `stale_claims` — flag for the operator.
   - `handoff_missing` — Done children that closed with no `[HANDOFF]` receipt: a skipped wrap. Surface them; their carry-forward went unrecorded, so anything they should have propagated is reconstructed from the ticket, never assumed clean. This per-ticket scan, not `last_resolved`, is what makes every miss visible — `last_resolved` surfaces only the newest close.
   - Report the map's state. `wedged.bool: true` (empty frontier with parked/blocked tickets open — `wedged.reason` names which) is a wedged map, not a done one; surface the reason to the operator.

2. **Choose the ticket.** Named by the user → use it. Otherwise take the top of the sweep's `frontier`. If the sweep signals `ending_due`, weigh it (§ Ending, below) — confirm before dispatching — rather than picking a ticket. There is no separate decide→build transition to detect: the crossing into building is the operator-confirmed Destination + Done When (SKILL.md § Decide, then build), and a doing-phase map simply carries build tickets in its frontier alongside any remaining decision tickets. **Claim the chosen ticket** (the `claim` transition) before any work.

3. **Resolve it — zoom as needed.** Fetch the full body of any related or closed ticket on demand; consult `## Notes` for domain context. Findings are aids, not ground truth — verify the claims a decision rests on before resting on them (the AFK-trial-is-consumption receipt, SKILL.md § Decide, then build). Route by type per SKILL.md § Ticket Types — that law isn't restated here:
   - `research`+`afk` → fire per its blind-pattern law (SKILL.md § Ticket Types); orchestration stance and the chaining cap per SKILL.md § Invocation and modes.
   - `research`+`hitl` → its stance pattern: orchestrate, synthesize, hold the operator's exchange — one per session, like any HITL resolution.
   - `build` → this session becomes the ticket's conductor: invoke `/implement` and run it there.
   - `grilling`/`prototype`/`task` → their SKILL.md law governs; between grilling and prototype, prefer whichever finds the answer faster — talk if talking gets close, build if a throwaway artifact would settle it definitively.

4. **Record the resolution.** Post the answer as a **resolution comment** (SKILL.md § Tickets — the answer-on-resolution law), run the `resolve` transition to close the ticket, and append the decision entry to the map's **Decisions document** — `[<ticket title>](link) — <one-line gist>`, append-only, per SKILL.md § The map body (the Decisions document). Create the document (titled `Decisions — <map name>`, attached to the map) if this is the map's first recorded decision and it has none yet; otherwise append. For `grilling` and `prototype` tickets, the resolution records the options weighed, the choice, and why.

   **Knowledge-doc filing rule.** A resolution that is hard to reverse, surprising without context, AND the result of a real trade-off → propose a durable knowledge doc to the operator; on her yes it files to the project's Knowledge/ under the structural contract, lint gate applied.

5. **Re-evaluate at the wrap.** Each slice close is a wrap — where what this slice taught propagates to the rest of the map. A discovery *mid*-slice amends the current slice; the wrap is where it reaches the *remaining* set.
   - **Sharpen the next slice, only if it moved.** Ask the cutting trigger — did this slice teach that the next cut is different? Yes → re-cut it with the `/vertical-slice` method; no → leave it. This step decides *whether* to invoke the method; the cutting judgment is the method's, never restated here.
   - **Validate the remaining set.** From this later vantage, are the still-open tickets accurate — or has the answer invalidated, reordered, or reshaped any? Add newly-surfaced tickets (create-then-wire), graduate fog the answer made specifiable (clearing each patch from **Not yet specified** so it lives only as its new ticket), and rule out-of-scope anything now beyond the destination (SKILL.md § Out of scope) — never resolved on the route.
   - **Every change to intent is the operator's.** Adding or canceling a ticket, re-sequencing (editing blocking relations — the frontier ordering itself stays `map_sweep`'s), and any edit to a ticket's Done When or to the map's Destination / Done When route to the operator (SKILL.md § Decide, then build — the threshold's gate); the session proposes, never self-approves. On her confirmation, run the `cancel` transition (with reason) for anything cut.

6. **Post the `[HANDOFF]` — the wrap's receipt.** One at every slice close, on the ticket just resolved, never the map — per resolve, so a chained session posts one at each close, not one at session end. Its shape, including the null result when the wrap changed nothing, is `/linear`'s `playbooks/comments.md`, not restated here. A later session reads this receipt for context; the map carries none.

## Ending

`ending_due: true` is the sweep's signal that the ending may be due — frontier empty, all children Done/Canceled. The signal is weighed, never obeyed: confirm the state yourself against a fresh read of the map before dispatching — an open child overrides the report. The ending is due only when the assembly actually reaches the map's Destination + Done When, which `map-close-eval` judges below; an empty frontier alone is the invitation to check, not the verdict.

1. Spawn `` `@attack-kitty` `` with a `map-close-eval` mandate and `Caller: L0 orchestrator` in the spawn prompt: a non-author end-to-end eval of the assembly against the Destination and **Done When**. For a system-of-text deliverable, the eval brief also names a cross-surface consistency lens and its scope. Every eval brief names the build tickets' `[VALIDATION]` comments as input — unresolved gaps are eval material.
2. Only `CONFIRMED` posts a `[VALIDATION]`-prefixed comment on the map. Any other verdict returns directly to this session, which routes it to the operator, never onward.
3. After a CONFIRMED receipt lands, run the `close-map` transition — the staged protocol (`playbooks/close-map.md`), which independently verifies the receipt and preconditions (fresh, well-formed, all children Done or Canceled), writes the plain-speech accounting (a document on the map) from the tickets' own receipts, and — as the last act — sets the map Done.

Only then is the map done.

## What this playbook does NOT do

- Does NOT restate `/linear`'s `[HANDOFF]` comment shape, the researcher-firing law, the Cutting discipline tests, or the Out of scope ruling procedure — SKILL.md and `/linear` carry those once; this playbook cites them at their firing point.
- Does NOT compute frontier ordering or detection arrays by hand — `map_sweep.py` is the mechanics; this playbook consumes its output.
- Does NOT chart a map or fire step-5-style researchers on newly created tickets from scratch — that's `playbooks/chart.md`'s job.
