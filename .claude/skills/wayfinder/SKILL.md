---
name: wayfinder
description: Chart and work a map — turn a loose idea too big for one session into decision tickets on Linear, resolve them one at a time with the operator, distill the decisions into a build charter, and build it through conductor-run, validated slices. Domain-agnostic — software, strategy, content, research. Invoked by the operator — "chart a map", "work the map", or a named map.
disable-model-invocation: true
---

# Wayfinder

<!-- Adapted from Matt Pocock's wayfinder skill (MIT): https://github.com/mattpocock/skills. Estate mutation: Linear-native, two-phase (decide/build), conductor-run build lane. -->

A loose idea has arrived — too big for one agent session, and wrapped in fog: the way from here to the **destination** isn't visible yet. Wayfinding is about finding that way, not charging at the destination. This skill charts the way as a **shared map** in Linear, then works its **decision tickets** — questions whose resolution is a decision — one at a time until the route is clear, then builds from what it decided (see [Decide, then build](#decide-then-build)).

The destination varies per effort, and naming it is the first act of charting — it shapes every ticket. It might be a spec to hand off and iterate on, a decision to lock before planning starts, or a change made in place like a data-structure migration. The map is domain-agnostic — engineering work, course content, whatever fits the shape.

## Decide, then build

Every map runs two phases.

**Phase one decides.** Conversation, research, and experiment — throwaway makes on fixtures, plentiful and cheap, never durable mutations. Each ticket resolves a decision. A HITL ticket is attacked before it closes — the operator in the exchange is the attacker. An AFK ticket delivers receipted facts, and its trial is consumption: whoever rests a decision on them verifies them first. The pull to start building is the signal to check the frontier: building begins only when the decisions are done.

**The transition.** When no decision ticket remains open, the map session distills the decisions into the **build charter** — a document on the map: each claim links to the decision ticket that holds it, and the map's Out of scope rides along. (No fixed body template yet — the first real charter shapes it.) A charter cannot finalize around an open question — STOP, resolve or ticket it. Settled claims are marked settled: downstream contexts build on them without reopening them, and a claim falls only to a receipt that its underlying fact changed, never to preference. A fresh-context adversary attacks the certified charter (the fidelity gate, below) — refute mandate, receipts — before the operator finalizes it. The build tickets are cut with the operator before finalization (see phase two) — finalization labels what exists. What that labeling does to open the build lane is `/implement`'s law now — see there.

**The fidelity gate.** An uncertified charter is consumed by nothing — not the adversary, not finalization, not the build lane. A fresh-context checker (a validator — Roles) certifies the charter against the decision tickets it cites, through the drafter↔checker loop codified in `playbooks/fidelity-gate.md`. The adversary spawn and finalization run its consumption check before consuming; the build lane inherits certification — the FINALIZED marker exists only past finalization's check, and the build lane's validators are quarantined to the pinned document (`` `@traffic-cone` ``'s `closing.md` Step 2.5 — charter check), never map comments. Drift that won't converge is an open question wearing charter language — the STOP above governs.

**Phase two builds from the charter** — cutting build tickets, `ready-for-agent` semantics, and the conductor's loop are `/implement`'s law; see there.

**The ending.** When the last build ticket closes — its conductor posts "ending due" on the map, `/implement`'s closing act — the map session spawns `` `@attack-kitty` `` with a `map-close-eval` mandate and `Caller: L0 orchestrator` in the spawn prompt: a non-author end-to-end eval of the assembly against the Destination and the charter — for a system-of-text deliverable, the eval brief also names a cross-surface consistency lens and its scope, and every eval brief names the build tickets' `[VALIDATION]` comments as input: unresolved gaps are eval material. Only `CONFIRMED` posts a `[VALIDATION]`-prefixed comment on the map — any other verdict returns directly to the map session, which routes it to the operator, never onward. After a CONFIRMED receipt lands, the map session spawns `` `@traffic-cone` `` `close-map`, which independently verifies the receipt and preconditions (fresh, well-formed, all children Done or Canceled), writes the plain-speech accounting (a document on the map) from the tickets' receipts, archives the charter (link retained), and — as the last act — sets the map Done. Only then is the map done.

## Roles

Three roles, named once, used everywhere — no sibling surface redefines them:

- **Map session** — the operator-invoked wayfinder session: charts, sweeps, resolves decision tickets, distills the charter. Runs at Fable — the operator's standing pairing; a ticket's `model:*` pin overrides.
- **Researcher** — the spawned agent resolving one `research`+`afk` ticket, blind to the map. Spawns at `sonnet` absent a `model:*` label.
- **Validator / adversary** — fresh-context non-authors: a validator judges at a gate; an adversary attacks with a refute mandate. Fable — the tier follows the mandate, never the work's label.

Conductor and Engineer are `/implement`'s roles — named there, used everywhere; no sibling surface redefines them either.

The pairings are default-plus-exception, never in-context judgment — a session choosing models for others defaults to its own class (known self-selection bias); the defaults above are the countermeasure.

**Claim** is the act and the state of holding a ticket. It is stored in Linear's `delegate` field (`` `@traffic-cone` `` `claim`), and parks release it. "Delegate" names that field only — never an agent.

## Spawning @traffic-cone and @attack-kitty

Every lifecycle transition (claim, resolve, park, cancel, close-map) goes through `` `@traffic-cone` ``; every non-author validation goes through `` `@attack-kitty` ``. At session start, load their invocation specs -- `` `@traffic-cone` ``'s `spec/invocation.md` and `` `@attack-kitty` ``'s `spec/invocation.md` -- for the spawn prompt shape each expects: calling context, verb/mandate, and parameters.

**On refusal:** fix what's fixable (a missing field, a malformed brief), flag to operator what isn't (a structural conflict, a WIP collision). Never bypass -- never self-service a state change that `` `@traffic-cone` `` refused, never skip a validation gate that `` `@attack-kitty` `` refused, never proceed with work on an unclaimed ticket. A refusal is a finding, not an obstacle to route around.

## Refer by name

Every map and ticket is an issue, so it has a **name** — its title. In everything the human reads — narration, the map's Decisions-so-far — refer to it by that name, never by a bare id, number, or slug. A wall of `#42, #43, #44` is illegible; names read at a glance. The id and URL don't vanish — a name wraps its link — but they ride *inside* the name, never stand in for it.

## The Map

The map is a single Linear issue, labelled `map` — the canonical artifact. Its tickets are child issues of the map.

The map is an **index**, not a store. It lists the decisions made and points at the tickets that hold their detail; a decision lives in exactly one place — its ticket — so the map never restates it, only gists it and links.

**The map, its child tickets, blocking, and frontier queries live in Linear, operated through `/linear`.** This skill names the logical operation — create, claim, wire blocking, query the frontier, resolve; `/linear` owns the mechanics (states, labels, relations, the delegate bridge), resolved through the global Configuration. No tracker data lives here.

### The map body

The whole map at low resolution, loaded once per session. Open tickets are **not** listed — they are open child issues, found by query.

```markdown
## Destination

<what reaching the end of this map looks like — the spec, decision, or change this effort is finding its way to. One or two lines; every session orients to it before choosing a ticket.>

## Notes

<domain context and standing preferences for this effort>

## Decisions so far

<!-- the index — one line per closed ticket: enough to judge relevance, then zoom the link for the detail the ticket holds -->

- [<closed ticket title>](link) — <one-line gist of the answer>

## Not yet specified

<!-- see "Fog of war": in-scope fog you can't ticket yet; graduates as the frontier advances -->

## Out of scope

<!-- see "Out of scope": work ruled beyond the destination; closed, never graduates -->
```

### Tickets

Each ticket is a **child issue** of the map; the tracker's issue id is its identity. Its body is the question, sized to one 100K token agent session:

```markdown
## Question

<the decision or investigation this ticket resolves>
```

(`build` tickets are the exception: they carry `/linear`'s Objective/Done When shape — see [Decide, then build](#decide-then-build).)

Ticket bodies and map Notes state the test, never the vibe. A tone adjective ("elegantly simple", "robust", "simple and predictable") is an optimization target for every downstream session that loads it — name the checkable property instead.

Each ticket carries a type label — `research`, `prototype`, `grilling`, `task`, or `build` — and a loop label, `hitl` or `afk` (see [Ticket Types](#ticket-types)). A `model:*` label is an operator-acked exception — on `research`+`afk`/`build` it sets the spawned agent's model (spawns default `sonnet` absent one), on a `hitl` ticket — including `research`+`hitl` — it pins the main context (claim surfaces a mismatch); dispatched extraction spawns keep Roles' defaults regardless.

A session **claims** a ticket — **first**, before any work, via `` `@traffic-cone` `` `claim`, which verifies the ticket is well-formed and stores the claim in the delegate field — so concurrent sessions skip it. An open ticket with no claim is unclaimed. Assignment is different: assignee may be system-set on operator-directed claims (recording co-engagement), but is the operator's field to clear, and an assigned ticket is never takeable.

Blocking uses the tracker's **native** dependency relationship — essential because it renders the frontier _visually_ in the tracker's own UI, so the human sees what's takeable without opening the map. Only a tracker that lacks native blocking falls back to a body convention. A ticket is **unblocked** when every ticket blocking it is closed; the **frontier** is the Todo, unblocked, unclaimed children — the edge of the known.

The answer isn't part of the body — it's recorded on resolution (see [Work through the map](#work-through-the-map)). Research findings produced while resolving a ticket land as a **document on the ticket**; other assets (code, methodology docs in the project's Knowledge/) are linked from the issue, not pasted in.

### Cutting discipline

Four principles govern: one question per ticket, vertical not horizontal, dependencies are the decomposition, and fitness — the result fits the purpose precisely, nothing more, nothing less.

Before finalizing any ticket, two tests:

1. Could someone pass this Done When and still miss the point? Close the gap.
2. Does this Done When ask for anything beyond what the Objective needs? Cut the excess.

The Objective encodes purpose, not function. The Done When encodes fitness — quality criteria that mean the purpose is met, not existence checks that mean something was produced.

## Ticket Types

The loop label marks **who drives resolution**. **HITL** — the ticket resolves only in live exchange with the operator, who speaks for herself; the agent never stands in for her side of it (a grilling agent that answers its own questions has broken this). **AFK** — an agent drives the ticket to completion alone; parking for operator input (a manual proof, a Needs Input ask) is machinery, not a loop change.

- **Research** (AFK or HITL — the loop label splits two patterns). **`research`+`afk`, the blind pattern:** surfaces the facts a decision waits on — documentation, third-party APIs, the codebase, the knowledge base. The session cutting the ticket authors the question, fact-finding only: how things stand today, never what should change; telegraphic directives (Trace, Enumerate, Map); strip anything that names the change being considered. The researcher gets the ticket and nothing else — no map, no Destination — resolves via `/research ticket`, and returns its findings to the orchestrator. Never resolve one inline: a map-holding context is contaminated by definition. The orchestrator spawns `` `@traffic-cone` `` `resolve` to close the ticket once the findings contract is met (doc exists, resolution comment exists). Endorsement is the sweep's audit; reliance is consumption's verification. **`research`+`hitl`, the stance pattern:** research plus thinking that must land a specific stance or recommendation — never fired to a blind researcher, and never a bare question: the ticket carries Destination and Done When alongside it. One session, two phases: it orchestrates the research (dispatched extraction with receipted outputs — grinding it in main context is a spec violation), synthesizes the stance, then presents it defensibly — what was explored, what was rejected and why, what is proposed and why, what proceeding produces — and resolves in the operator's exchange, same session, never deferred. The blind-researcher machinery (map-blindness, `/research ticket`, delivers-and-returns) applies only to the `afk` pattern. Right-sized: `afk` — one focused investigation, one findings document; `hitl` — one stance to land, one exchange to land it in.
- **Prototype** (HITL): Raise the fidelity of the discussion by making a cheap, rough, concrete artifact to react to — an outline, a rough take, a stub, or UI/logic code via the /prototype skill. Links the prototype as an asset. Use when "how should it look" or "how should it behave" is the key question. Right-sized when: one thing to build and react to.
- **Grilling** (HITL): Conversation via the `/grilling` and `/domain-modeling` skills, one question at a time. The default case. Right-sized when: one decision to make, one conversation to make it.
- **Task** (HITL or AFK): Manual work that must happen before a *decision* can be made — nothing to decide, prototype, or research, but the discussion is blocked until it's done. Signing up for a service so its API can be judged, provisioning access, moving data so its shape can be seen. This is the one type that *does* rather than decides — and it earns its place by unblocking a decision, not by delivering the destination. The agent drives it alone where it can (AFK); otherwise it hands the human a precise checklist (HITL). Resolved when the work is done; the answer records what was done and any resulting facts (credentials location, new URLs, row counts) later tickets depend on. Right-sized when: one blocking action, one session to complete it.
- **Build** (AFK): a charter slice, phase two only — the type's discipline lives in `/implement`. Right-sized when: one slice, one proof, one validator.

## Fog of war

The map is _deliberately_ incomplete: don't chart what you can't yet see. Beyond the live tickets lies the **fog of war** — the dim view of decisions and investigations you can tell are coming but can't yet pin down, because they hang on questions still open. Resolving a ticket clears the fog ahead of it, graduating whatever's now specifiable into fresh tickets — one at a time, until the way to the destination is clear and no tickets remain.

The map's **Not yet specified** section is where that dim view is written down: the suspected question, the area to revisit later. It's the undiscovered frontier _toward_ the destination — everything here is in scope, just not sharp enough to ticket. Write as loosely or as fully as the view allows; it doubles as a signpost for collaborators reading where the effort is headed.

**Fog or ticket?** The test is whether you can state the question precisely now — _not_ whether you can answer it now.

- **Ticket when** the question is already sharp — even if it's blocked and you can't act on it yet.
- **Not yet specified when** you can't yet phrase it that sharply. Don't pre-slice the fog into ticket-sized pieces: it's coarser than a ticket, and one patch may graduate into several tickets, or none, once the frontier reaches it.

**Not yet specified** excludes what's already decided (Decisions so far), what's already a live ticket, and what's out of scope (the next section).

## Out of scope

Fog only ever gathers _toward_ the destination. The destination fixes the scope, so work beyond it is **out of scope** — it isn't fog, and it doesn't belong in **Not yet specified**. It gets its own **Out of scope** section on the map: work you've consciously ruled out of _this_ effort. Scope, not sharpness, lands it here.

Out-of-scope work never graduates — the frontier stops at the destination — so it returns only if the destination is redrawn, and then as a fresh effort, not a resumption.

Ruling something out of scope is a scoping act, not a step on the route. When a ticket that already exists turns out to sit past the destination — mis-scoped in while charting, or exposed by a resolution — propose the out-of-scope ruling to the operator; on her confirmation, spawn `` `@traffic-cone` `` to **cancel it** (reason: its out-of-scope line; a canceled ticket is unambiguously off the frontier). Out-of-scope rulings are scoping acts, not mechanical transitions — the operator confirms scope; traffic-cone executes the cancel. Leave one line in the **Out of scope** section: the gist plus why it's out of scope, linking the canceled ticket. It stays out of **Decisions so far**, which records the route actually walked — a scope boundary isn't a step on it.

## Invocation

Two modes. Either way, **never resolve more than one ticket per session** — with the exception of `research`+`afk` tickets: the map session runs those as the **orchestrator, never the researcher** (see work-through step 3), and may chain them as they unblock (cap there). A `research`+`hitl` ticket is a HITL resolution like any other: one per session.

### Chart the map

User invokes with a loose idea.

1. **Name the destination.** Run a `/grilling` and `/domain-modeling` session to pin down what this map is finding its way to — the spec, decision, or change. The destination fixes the scope, so it's settled first.
2. **Map the frontier.** Grill again, **breadth-first** this time: fan out across the whole space rather than deep on any one thread, surfacing the open decisions and the first steps takeable now. **If this surfaces no fog** — the way to the destination is already clear, the whole journey small enough for one session — you don't need a map. Stop and ask the user how they'd like to proceed.
3. **Create the map** (label `map`), titled neutrally — the Destination lives in the body, never the title: a child's fetch shows its parent's title, and researchers must not learn the destination from it. Destination and Notes filled in, Decisions-so-far empty, the fog sketched into **Not yet specified**. The map opens assigned to the operator and In Progress (`/linear` create's map-open step) — the effort is live from here; the map is never claimed and never parks (its states are In Progress → Done; a wedged map is reported by the sweep).
4. **Create the tickets you can specify now** as child issues of the map — then wire blocking edges in a **second pass** (issues need ids before they can reference each other). Wiring sorts them into the frontier and the blocked; everything you can't yet specify stays in the fog — the **Not yet specified** section. Type a ticket as `prototype` when a throwaway artifact would resolve the question faster than conversation — shape questions, competing approaches that need to be seen, state models too complex to reason about on paper. Type as `grilling` when the question resolves in dialogue. Grilling is the default; prototype earns its place when making is cheaper than talking.
5. **Fire the researchers.** For each `research`+`afk` ticket just created, spawn `` `@traffic-cone` `` to claim it, then spawn its researcher — `/research ticket <id>` at the ticket's model label (`sonnet` absent one), in parallel. The spawn prompt is the ticket id alone — its done-condition is the playbook's findings contract, never what the findings should establish. The researcher delivers its findings and returns; the orchestrator closes the ticket through `` `@traffic-cone` `` `resolve`.
6. **Stop** — charting is one session's work; it hand-resolves nothing, so it posts no `[HANDOFF]`: no ticket was worked this session for one to carry.

### Work through the map

User invokes with a map (URL or number). A ticket is **optional** — without one, you pick the next decision, not the user.

1. Load the **map** — the low-res view, not every ticket body. Open the most recently resolved ticket (the last entry in Decisions-so-far) and read its `[HANDOFF]` comment first: it names the recommended next act and any carry-forward context; skip re-deriving what it covers. Then sweep: read open charter-challenge comments (`[CHALLENGE]`-prefixed with no `[CHALLENGE-RESOLVED]` reply, posted by parking conductors) — tickets resting on a challenged claim are not dispatched, and the challenge is surfaced to the operator, whose adjudication lands as the `[CHALLENGE-RESOLVED]` reply that releases the lane; return operator-confirmed parked tickets to the frontier; audit newly closed research — spot-check receipts and copy each resolution gist into Decisions-so-far (copied, never authored fresh); close orphaned research — if a research ticket has a findings document and resolution comment but is still open (researcher returned, orchestrator never closed), spawn `` `@traffic-cone` `` `resolve` to close it, then copy its gist into Decisions-so-far; flag stale claims (claimed, no recent activity) for the operator. Report the map's state — an empty frontier with parked tickets is a wedged map, not a done one.
2. Choose the ticket. If the user named one, use it. Otherwise take the top frontier ticket (`/linear`'s frontier ordering). If the frontier is empty and all children are Done or Canceled, the map is ready for its ending — spawn `` `@attack-kitty` `` with a `map-close-eval` mandate and `Caller: L0 orchestrator` (see "The ending" above) rather than picking a ticket. **Claim it** (spawn `` `@traffic-cone` `` `claim`) before any work.
3. Resolve it — **zoom as needed**: fetch the full body of any related or closed ticket on demand; consult the `## Notes` block for domain context. Findings are aids, not ground truth — verify the claims a decision rests on before resting on them. A `research`+`afk` ticket is fired to its researcher at the ticket's model label (`sonnet` absent one) — **the map session is the orchestrator, never the researcher**: it spawns, audits, and consumes; running the research in the map context is a spec violation, not a style choice (history shows sessions grind research in main context when the spec doesn't forbid it). When a closed research ticket unblocks further `research` tickets, the session may **chain them — fire the next spawn as the frontier clears — up to three research tickets per session**: past that, the orchestrating context's accumulated findings begin to color how it briefs and audits the next researcher, so the chain caps before the quality does. A `research`+`hitl` ticket resolves per its stance pattern (Ticket Types): the session orchestrates the research, synthesizes, and holds the operator's exchange — one such ticket per session, like any HITL resolution. A `build` ticket makes this session its conductor: invoke `/implement` and run it there. If in doubt, use `/grilling` and `/domain-modeling`. If the discussion could be talked through at length and get close, but a throwaway prototype would find out definitively in a fraction of the time — switch to `/prototype`.
4. Record the resolution: post the answer as a **resolution comment**, spawn `` `@traffic-cone` `` `resolve` to close the ticket, and **append a context pointer** to the map's Decisions-so-far. For `grilling` and `prototype` tickets, the resolution records the options weighed, the choice, and why. A resolution that is hard to reverse, surprising without context, AND the result of a real trade-off → propose a durable knowledge doc to the operator; on her yes it files to the project's Knowledge/ under the structural contract, lint gate applied.
5. Add newly-surfaced tickets (create-then-wire); graduate any fog the answer has made specifiable, clearing each graduated patch from **Not yet specified** so it lives only as its new ticket. If the answer reveals a ticket — this one or another — sits beyond the destination, **rule it out of scope** rather than resolving it on the route. If the decision invalidates other parts of the map, update those tickets or propose cancellation to the operator — on her confirmation, spawn `` `@traffic-cone` `` to cancel (with reason).
6. **Post the `[HANDOFF]`** — the session's closing act, a short comment on the ticket just resolved, never the map: the recommended next act (top frontier ticket, or a phase transition now due) in one line, plus one to two lines of carry-forward context the ticket body doesn't already hold. No re-summary of what was done — the resolution comment and closed state already carry that. Two to three lines max. A later session opening this ticket reads its `[HANDOFF]` for context; the map carries none.

The user may run unblocked tickets in parallel, so expect other sessions to be editing the tracker concurrently.
