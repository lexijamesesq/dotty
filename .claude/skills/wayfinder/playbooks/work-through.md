# Playbook: work-through

Work-through-mode procedure — the user invokes with a map (URL or number). A ticket is **optional**: without one, you pick the next decision, not the user.

## Steps

1. **Load and sweep.** Load the map body (low resolution, not every ticket body). Run `map_sweep.py <map-id>` (`.claude/skills/linear/scripts/`) — it returns the map's state, the ordered `frontier` (with `frontier_rule` naming the ordering — never re-derive it), and every detection array: `open_challenges`, `orphaned_research`, `parked`, `blocked`, `stale_claims`, `decisions_missing`, `last_resolved` (with its `[HANDOFF]` text), `charter_state`, `ending_due`, `wedged`. The script owns detection mechanics; its report is input to your orientation, not the orientation — read the map and judge. Judgment on its output stays this session's:
   - Read `last_resolved`'s `[HANDOFF]` text first — it names the recommended next act and carry-forward context; skip re-deriving what it covers.
   - `open_challenges` — tickets resting on a challenged claim are not dispatched; surface each to the operator, whose adjudication lands as the `[CHALLENGE-RESOLVED]` reply that releases the lane.
   - Return operator-confirmed parked tickets to the frontier.
   - `decisions_missing` — spot-check the resolution text each entry supplies as evidence, then copy the gist into Decisions-so-far (gists copied, never authored fresh).
   - `orphaned_research` — findings doc and resolution comment both already exist, so run traffic-cone's fused `resolve` script to close each, then copy its gist into Decisions-so-far the same way.
   - `stale_claims` — flag for the operator.
   - Report the map's state. `wedged.bool: true` (empty frontier with parked/blocked tickets open — `wedged.reason` names which) is a wedged map, not a done one; surface the reason to the operator.

2. **Choose the ticket.** Named by the user → use it. Otherwise take the top of the sweep's `frontier`. If the sweep signals `ending_due`, weigh it (§ Ending, below) — confirm before dispatching — rather than picking a ticket. If the frontier is empty and all children are Done/Canceled but `charter_state` is **not** `finalized` — that's the decide→build transition, not the ending: distill the charter per SKILL.md § Decide, then build, don't treat this as done. **Claim the chosen ticket** (traffic-cone's fused `claim` script) before any work.

3. **Resolve it — zoom as needed.** Fetch the full body of any related or closed ticket on demand; consult `## Notes` for domain context. Findings are aids, not ground truth — verify the claims a decision rests on before resting on them (the AFK-trial-is-consumption receipt, SKILL.md § Decide, then build). Route by type per SKILL.md § Ticket Types — that law isn't restated here:
   - `research`+`afk` → fire per its blind-pattern law (SKILL.md § Ticket Types); orchestration stance and the chaining cap per SKILL.md § Invocation and modes.
   - `research`+`hitl` → its stance pattern: orchestrate, synthesize, hold the operator's exchange — one per session, like any HITL resolution.
   - `build` → this session becomes the ticket's conductor: invoke `/implement` and run it there.
   - `grilling`/`prototype`/`task` → their SKILL.md law governs; between grilling and prototype, prefer whichever finds the answer faster — talk if talking gets close, build if a throwaway artifact would settle it definitively.

4. **Record the resolution.** Post the answer as a **resolution comment**, run traffic-cone's fused `resolve` script to close the ticket, and append a context pointer to the map's Decisions-so-far (SKILL.md § Tickets — the answer-on-resolution law). For `grilling` and `prototype` tickets, the resolution records the options weighed, the choice, and why.

   **Knowledge-doc filing rule.** A resolution that is hard to reverse, surprising without context, AND the result of a real trade-off → propose a durable knowledge doc to the operator; on her yes it files to the project's Knowledge/ under the structural contract, lint gate applied.

5. **Add and graduate.** Add newly-surfaced tickets (create-then-wire, per SKILL.md § Cutting discipline). Graduate any fog the answer made specifiable, clearing each graduated patch from **Not yet specified** so it lives only as its new ticket. A ticket sitting beyond the destination → rule it out of scope (SKILL.md § Out of scope), never resolve it on the route. If the decision invalidates other parts of the map, update those tickets or propose cancellation to the operator; on confirmation, run traffic-cone's fused `cancel` script (with reason).

6. **Post the `[HANDOFF]`.** The session's closing act — a short comment on the ticket just resolved, never the map. Shape per `/linear`'s `playbooks/comments.md`. Content law (its only firing point): the recommended next act (top frontier ticket, or a phase transition now due) in one line, plus one to two lines of carry-forward context the ticket body doesn't already hold — no re-summary of what was done, the resolution comment and closed state already carry that. Two to three lines max. A later session opening this ticket reads its `[HANDOFF]` for context; the map carries none.

## Ending

`ending_due: true` is the sweep's signal that the ending may be due — frontier empty, all children Done/Canceled, `charter_state: finalized`. The signal is weighed, never obeyed: confirm the state yourself against a fresh read of the map before dispatching — an open child, a live challenge, or an unfinalized charter overrides the report. (Without the charter clause, an empty decision-ticket frontier alone would look like an ending at the decide→build transition — step 2 routes that case to charter distillation instead.)

1. Spawn `` `@attack-kitty` `` with a `map-close-eval` mandate and `Caller: L0 orchestrator` in the spawn prompt: a non-author end-to-end eval of the assembly against the Destination, **Done When**, and the charter. For a system-of-text deliverable, the eval brief also names a cross-surface consistency lens and its scope. Every eval brief names the build tickets' `[VALIDATION]` comments as input — unresolved gaps are eval material.
2. Only `CONFIRMED` posts a `[VALIDATION]`-prefixed comment on the map. Any other verdict returns directly to this session, which routes it to the operator, never onward.
3. After a CONFIRMED receipt lands, run traffic-cone's staged `close-map` protocol (`playbooks/close-map.md`), which independently verifies the receipt and preconditions (fresh, well-formed, all children Done or Canceled), writes the plain-speech accounting (a document on the map) from the tickets' own receipts, archives the charter (link retained), and — as the last act — sets the map Done.

Only then is the map done.

## What this playbook does NOT do

- Does NOT restate `/linear`'s `[HANDOFF]` comment shape, the researcher-firing law, the Cutting discipline tests, or the Out of scope ruling procedure — SKILL.md and `/linear` carry those once; this playbook cites them at their firing point.
- Does NOT compute frontier ordering or detection arrays by hand — `map_sweep.py` is the mechanics; this playbook consumes its output.
- Does NOT chart a map or fire step-5-style researchers on newly created tickets from scratch — that's `playbooks/chart.md`'s job.
