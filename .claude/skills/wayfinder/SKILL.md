---
name: wayfinder
description: Chart and work a map — turn a loose idea too big for one session into decision tickets on Linear, resolve them one at a time with the operator, then build from the operator-confirmed intent through validated slices. Domain-agnostic — software, strategy, content, research. Invoked by the operator — "chart a map", "work the map", or a named map.
disable-model-invocation: false
---

# Wayfinder

<!-- Adapted from Matt Pocock's wayfinder skill (MIT): https://github.com/mattpocock/skills. Estate mutation: Linear-native, two-phase (decide/build). -->

A loose idea has arrived — too big for one session, wrapped in fog: the way to the **destination** isn't visible yet. Wayfinding charts that way as a shared **map** in Linear, works its **decision tickets** one at a time until the route is clear, then builds from what it decided ([Decide, then build](#decide-then-build)). Naming the destination is charting's first act — it fixes scope, shapes every ticket.

No map yet → `playbooks/chart.md`; a map (URL or number) → `playbooks/work-through.md` — table in [Invocation and modes](#invocation-and-modes).

## Decide, then build

Every map runs two phases. **Phase one decides** — conversation, research, throwaway makes on fixtures: plentiful, cheap, never durable mutations. Each ticket resolves a decision. A HITL ticket is attacked before close, the operator is the attacker; an AFK ticket delivers receipted facts, and its trial is consumption — whoever rests a decision on them verifies them first. The doing phase begins once the decision frontier is empty — the pull to start building is the signal to check the frontier, not to build.

**The threshold.** The crossing into building is light: **operator-confirmed Destination + Done When** — shared intent strong enough to base decisions on, not a fully-specced list of boxes. The map body's own `## Destination` + `## Done When`, confirmed with the operator, *is* the settled spec. It stays **living** — re-cut as each slice teaches — but every change to it is the operator's call, never a session's own. If a decision is still open, STOP — resolve or ticket it; the threshold is shared understanding, not the absence of every question.

**Building.** The doing phase cuts **vertical slices** with the operator — near ones sharp, distant ones directional, tickets added / cancelled / refined as each slice teaches. Every slice plan and every slice result is attacked (`` `@attack-kitty` ``) by default. The ending — the last slice closes and the assembly reaches Destination + Done When (via `map-close-eval`) — is `playbooks/work-through.md`'s law (§ Ending); chart sessions never load it.

## Working stance

This session orchestrates; it does not grind. Its work is thought-partnership with the operator and dispatch — authoring at scale goes to teammates, at the lowest model class the outcome tolerates (`/dispatch` shapes the call; `sonnet` the common default). Delegation moves the work, never the accountability: the session answers for every ticket it claims.

Slices are **vertical** — each a complete, usable increment — never horizontal layers; the cut and its tests are [Cutting discipline](#cutting-discipline). Check for drift from the Destination as the work runs: producing an artifact is not success, reaching the outcome is — a slice that ran but left the map no closer to Done When is not done.

`` `@attack-kitty` `` is the non-author check, used three ways: pressure-test a plan before building it, review an implementation after, and — optionally — think a hard problem through. It surfaces gaps and what was missed; it never rewrites your intent. The firing points name where its checks are mandatory.

Every GitHub action — branch, commit, push, PR, merge — goes through `/publish`.

## Roles

Three roles, named once, used everywhere:

| Role | Tier | Note |
|---|---|---|
| Map session | Fable | Charts, sweeps, resolves decisions, cuts slices with the operator; `model:*` pin overrides |
| Researcher | `sonnet` absent `model:*` | Runs one blind investigation for a slice, blind to the map |
| Validator / adversary | Per the mandate card (`@attack-kitty` § Tier policy) | Tier follows the mandate, never the work's label |

Default-plus-exception, never in-context judgment — a session choosing models for others defaults to its own class (self-selection bias); the defaults above are the countermeasure.

**Claim** is the act and state of holding a ticket — Linear's `delegate` field (`` `@traffic-cone` `` `claim`); parks release it. "Delegate" names the field only, never an agent.

Lifecycle transitions route through `` `@traffic-cone` ``; `` `@attack-kitty` `` executes none.

## Running transitions, spawning `@attack-kitty`

Every lifecycle transition is a **call to the `traffic-cone` gate** — you hand it a verb and consume its verdict; it runs its own checks and executes in-process. You never assemble what it runs (the `cone_preflight` invocation, the flags, the bridge, the project lookup): that is behind the wall, and reaching past it defeats the gate. Call the gate, read the verdict.

### Transitions

Navigate a transition by its verb — the Invocation column is the whole call. Values in `"quotes"` are the semantic ones you supply (an ask, a condition, a reason); nothing mechanical is learned. This table is the resolver: every firing point below (and in the playbooks) names a verb and points here.

| Action | Description | Invocation |
|---|---|---|
| **Claim** | Take a takeable ticket before any work | `traffic-cone claim <id>` |
| **Park** | Pause on the operator; releases the claim | `traffic-cone park <id> --ask "<text>"` |
| **Block** | Mark blocked on an external condition | `traffic-cone block <id> --condition "<text>"` |
| **Un-park** | Return a parked ticket to Todo | `traffic-cone un-park <id> --blocker-verified` |
| **Cancel** | Rule a ticket out of scope / invalidated | `traffic-cone cancel <id> --reason "<text>"` |
| **Close map** | Final map close after a CONFIRMED eval | *staged* — `traffic-cone close-map <id>` points to `playbooks/close-map.md` (map session) |
| **Mark done** | Close a resolved ticket by its recorded result — the one close verb for every ticket (needs a `[VALIDATION]` receipt; `[HANDOFF]` too for a map child) | `traffic-cone mark-done <id>` |

Claim's edge intents ride as flags when they apply — `--operator-directed` (a non-Todo claim you direct), `--autonomous` (frontier pickup, no operator), `--caller-ack-wip` (a WIP collision that is a related chain); the common claim needs none.

**Escape hatch — the only reason to open `/traffic-cone`:** a `REFUSE` you don't understand, or a `JUDGMENT_REQUIRED` kernel you can't rule. The kernel-ruling flags (`--model-ruled`, `--mandate-type`, …) are pass-through on the gate for that path only — off the happy path by definition.

**Result handling.** **ADMIT** executes and reports. **REFUSE** is binding — never re-run hoping, never hand-edit state. **NEEDS_INPUT** has already executed its own routing/park in-process. **JUDGMENT_REQUIRED** routes per traffic-cone's judgment kernels — most rule in this session (the caller), M3g alone routes onward to `` `@attack-kitty` ``'s `ticket-close` mandate. Every non-author validation goes through `` `@attack-kitty` ``, unchanged.

`` `@attack-kitty` `` needs **mandate type** (a playbook card), **parameters** (varies by type), **caller depth** (`Caller: L0 orchestrator`/`L1 teammate`). Example: `map-close-eval mandate for <map-id>. Caller: L0 orchestrator`.

Unsure how to compose `` `@attack-kitty` ``'s prompt, or it refuses? **Ask the agent** — never guess, never bypass.

**On refusal:** fix what's fixable (a missing field, a malformed brief), flag to operator what isn't (a structural conflict, a WIP collision). Never self-service a refused state change or skip a refused gate; never work an unclaimed ticket. A refusal is a finding, not an obstacle to route around.

**`` `@attack-kitty` `` blocked by the harness** ≠ a refusal. A judgment or eval spawn the harness won't let through parks the ticket and surfaces to the operator in the same breath as the receipt it degrades — transitions have no equivalent case now; they spawn nothing the harness could block. When a spawn does go through, its return is consumed as given — a gap gets fielded or the spawn respawned once, never repeatedly.

## Refer by name

Every map and ticket is an issue with a **name** — its title. Use it everywhere a human reads, never a bare id, number, or slug — `#42, #43` is illegible, names read at a glance. The id and URL ride inside the name, never stand in for it.

## The Map

A single Linear issue, labeled `map` — the canonical artifact; its tickets are child issues. An **index**, not a store: it points at the tickets holding the detail — a decision lives in exactly one place, its ticket; the map only gists and links.

The map, its children, blocking, and frontier queries live in Linear, via `/linear`, which owns the mechanics; this skill names the logical operation only — create, claim, wire blocking, query, close. No tracker data lives here.

### The map body

Low resolution, loaded once per session. Open tickets aren't listed — they're open child issues, found by query.

```markdown
## Destination

<what reaching the end of this map looks like — the spec, decision, or change this effort is finding its way to. One or two lines; every session orients to it before choosing a ticket.>

## Done When

<testable conditions — Destination's complement: prose orients, these test. Co-drafted with the operator at map creation (chart.md step 3); it stays living through the doing phase, refined as slices teach under operator-directed amendment (mutation-record-spec.md).>

## Notes

<domain context and standing preferences for this effort>

## Decisions

<!-- The decision index is not in the body — it's an attached document, `Decisions — <map name>`, so it can grow without churning map intent. The body carries only this pointer; orientation zooms the doc for the index. -->

See the **Decisions — <map name>** document attached to this map.

## Not yet specified

<!-- see "Fog of war": in-scope fog you can't ticket yet; graduates as the frontier advances -->

## Out of scope

<!-- see "Out of scope": work ruled beyond the destination; closed, never graduates -->
```

**The Decisions document.** The decision index lives in a Linear document attached to the map, titled `Decisions — <map name>` — not in the body, so it grows without touching map intent. Evolution mode ([mutation-record-spec](../traffic-cone/playbooks/mutation-record-spec.md)): append-only, one entry per closed ticket, newest last, never a rewrite of a landed entry. Entry shape — `[<closed ticket title>](link) — <one-line gist of the answer>`. It's map-scoped and dies with the map. Created lazily — the first resolution that has a decision to record creates it (work-through step 4); a fresh map carries the pointer and no doc yet. `map_sweep.py`'s `decisions_missing` reads this doc.

### Tickets

Each ticket is a **child issue** of the map, sized to one 100K-token session; its body carries the standardized child skeleton — two required headings, nothing else standard:

```markdown
## Objective

<intent + problem space — what this slice resolves and the ground it stands on>

## Done When

<fitness: needle-moved or state-exists — what the result is measured against>
```

Every child takes this shape — decision and build slices alike; there is no separate `## Question` body.

State the test, never the vibe — a tone adjective ("elegantly simple", "robust") is an optimization target for every downstream session that loads it; name the checkable property.

| Label | When set | Semantics |
|---|---|---|
| Loop (`hitl`/`afk`) | Create | Marks who drives ([Resolving a slice](#resolving-a-slice)) |
| `model:*` on an afk slice | Operator-acked | Sets the model (default `sonnet`) |
| `model:*` on a hitl slice | Operator-acked | Pins main context — claim flags a mismatch |
| `model:*` on extraction spawn | — | Ignored — Roles' defaults |

**Claims** first, before any work, via the `claim` transition (§ Running transitions) — verified, stored in delegate; concurrent sessions skip it. Assignment differs: system-set on operator-directed claims, the operator's field to clear; assigned = never takeable.

Blocking is the tracker's **native** dependency relationship — renders the frontier _visually_ in the tracker's UI, so the human sees what's takeable without opening the map. Unblocked = every blocker closed; the **frontier** is Todo, unblocked, unclaimed. Ordering is `/linear` frontier.md's rule, never restated — `map_sweep.py` computes it.

The answer isn't in the body — recorded on resolution: a comment, findings as a **document on the ticket**, other assets linked, never pasted.

### Cutting discipline

Four principles govern: one question per ticket, vertical not horizontal, dependencies are the decomposition, and fitness — the result fits the purpose precisely, nothing more, nothing less. The full method — finding the cuts and testing them, at the first cut and every re-cut — is the `vertical-slice` skill; invoke it when cutting.

The Objective encodes purpose, not function. The Done When encodes fitness — quality criteria that mean the purpose is met, not existence checks that mean something was produced.

## Resolving a slice

The **loop label** (`hitl`/`afk`) marks who drives. **HITL** — resolves only in live exchange with the operator, who speaks for herself; the agent never stands in (a grilling agent answering its own questions has broken this). **AFK** — an agent drives it alone; parking for operator input (a manual proof, a Needs Input ask) is machinery, not a loop change.

A slice is resolved by whatever **reflexes** its problem needs — investigate, grill, prototype, do a blocking task, build. These are activities a session applies *within* a slice, not ticket types; a slice often uses several. Cut and size each slice by its Objective + Done When ([Cutting discipline](#cutting-discipline)), never by an activity.

- **Investigate (blind research).** Fact-finding only — docs, APIs, code, knowledge base — how things stand, never what should change; telegraphic (Trace, Enumerate, Map), stripped of the change under consideration. When an afk slice is a pure blind investigation, the map session runs it as orchestrator via `/research ticket` — **spawn prompt is the ticket id alone**, done-condition the findings contract, never what findings should establish (blindness protection); the researcher delivers, returns, never inline (a map-holding context is contaminated by definition). Closed via `mark_done` (§ Running transitions) once the findings doc + its close receipts exist — a `[VALIDATION]` (`` `@attack-kitty` ``'s deliverable-check that the findings meet the Done When, posted as the app actor) and a `[HANDOFF]`. Endorsement is the sweep's audit; reliance is consumption's verification.
- **Land a stance (research in the operator's exchange).** Not a blind researcher, never a bare question — the slice carries Destination and Done When too. Orchestrates the research (dispatched extraction, receipted — grinding it in main context is a spec violation), synthesizes, presents defensibly (explored, rejected and why, proposed and why, what proceeding produces), resolves in the operator's exchange, same session, never deferred.
- **Grill.** Conversation via `/grilling`/`/domain-modeling`, one question at a time — the default way a decision slice resolves.
- **Prototype.** Raise the fidelity of the discussion with a cheap, rough, concrete artifact to react to: an outline, a rough take, a stub, or UI/logic code via `/prototype`, linked as an asset. Reach for it when "how should it look" or "how should it behave" is the key question and a throwaway would settle it faster than talk.
- **Do a blocking task.** Manual work that must happen before a slice can proceed: signing up for a service so its API can be judged, provisioning access, moving data so its shape can be seen — it earns its place by unblocking, not by delivering the destination. The agent drives it alone where it can; otherwise it hands the human a precise checklist. Records what was done and any resulting facts (credentials location, new URLs, row counts) later slices depend on.
- **Build.** Author the increment the slice delivers — in-session, dispatched via `/dispatch` when it needs more than one context. No separate lane; it closes through the same gates every slice uses.

## Fog of war

The map is _deliberately_ incomplete: don't chart what you can't yet see. Beyond the live tickets lies the **fog of war** — decisions you can tell are coming but can't pin down, hung on questions still open. Resolving a ticket clears the fog ahead of it, graduating whatever's now specifiable into fresh tickets — one at a time, until the way to the destination is clear and no tickets remain.

**Not yet specified** holds that dim view — the suspected question, the area to revisit; write as loosely or fully as the view allows. It's the undiscovered frontier _toward_ the destination — everything here is in scope, just not sharp enough to ticket — and it doubles as a signpost for collaborators reading where the effort is headed.

**Fog or ticket?** Can you state the question precisely now — _not_ can you answer it. Sharp, even if blocked → ticket. Can't phrase it that sharply yet → Not yet specified — don't pre-slice; one patch may graduate into several tickets, or none. Excludes what's decided, ticketed, or out of scope (below).

## Out of scope

Fog gathers only _toward_ the destination — work beyond it is **out of scope**, not fog. Its own section: work consciously ruled out. Scope, not sharpness, lands it here — never graduates, returns only if the destination is redrawn, as a fresh effort, not a resumption.

Ruling something out of scope is a scoping act, not a route step. A ticket sitting past the destination — mis-scoped while charting, or exposed by a resolution — propose the ruling to the operator; on confirmation, run the `cancel` transition (§ Running transitions) — reason: its out-of-scope line. One line in **Out of scope**: gist plus why, linking the ticket. Stays out of the **Decisions document** — a scope boundary isn't a step on the route.

## Invocation and modes

Never resolve more than one slice per session, except **a blind investigation — the map session runs those as orchestrator, never the researcher** (grind-in-main-context receipt: sessions grind research in main context when nothing forbids it), chaining them as they unblock, up to **three** per session; past that, the context's own findings begin to color how it briefs the next researcher (context-coloring receipt) — the chain caps before the quality does. A stance-landing slice is a HITL resolution like any other: one per session.

| Bring | Playbook |
|---|---|
| A loose idea, no map yet | `playbooks/chart.md` |
| A map (URL or number) | `playbooks/work-through.md` |

Expect other sessions editing the tracker concurrently — unblocked tickets run in parallel.
