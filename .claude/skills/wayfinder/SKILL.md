---
name: wayfinder
description: Chart and work a map — turn a loose idea too big for one session into decision tickets on Linear, resolve them one at a time with the operator, distill the decisions into a build charter, and build it through conductor-run, validated slices. Domain-agnostic — software, strategy, content, research. Invoked by the operator — "chart a map", "work the map", or a named map.
disable-model-invocation: false
---

# Wayfinder

<!-- Adapted from Matt Pocock's wayfinder skill (MIT): https://github.com/mattpocock/skills. Estate mutation: Linear-native, two-phase (decide/build), conductor-run build lane. -->

A loose idea has arrived — too big for one session, wrapped in fog: the way to the **destination** isn't visible yet. Wayfinding charts that way as a shared **map** in Linear, works its **decision tickets** one at a time until the route is clear, then builds from what it decided ([Decide, then build](#decide-then-build)). Naming the destination is charting's first act — it fixes scope, shapes every ticket.

No map yet → `playbooks/chart.md`; a map (URL or number) → `playbooks/work-through.md` — table in [Invocation and modes](#invocation-and-modes).

## Decide, then build

Every map runs two phases. **Phase one decides** — conversation, research, throwaway makes on fixtures: plentiful, cheap, never durable mutations. Each ticket resolves a decision. A HITL ticket is attacked before close, the operator is the attacker; an AFK ticket delivers receipted facts, and its trial is consumption — whoever rests a decision on them verifies them first. Building begins once the decision frontier is empty — the pull to start building is the signal to check the frontier, not to build.

**The transition.** No decision ticket left open → the map session distills decisions into the **build charter**, a map document: each claim links to its decision ticket, the map's Out of scope rides along (no fixed template yet — the first real charter shapes it). A charter can't finalize around an open question — STOP, resolve or ticket it; unconverging drift is the same STOP. Settled claims are marked settled and fall only to a receipt the fact changed, never to preference. Finalizes only after: **certify** (`playbooks/fidelity-gate.md`'s drafter↔checker loop against the cited tickets — invariant and consumption check live there) → **attack** (fresh-context adversary, refute mandate + receipts) → **finalize** (the operator). Build tickets are cut with the operator before finalization; what finalization's labeling opens in the build lane is `/implement`'s law now.

Phase two builds from the charter — build tickets, `ready-for-agent`, the conductor's loop: `/implement`'s law. The ending — last build ticket closes — is `playbooks/work-through.md`'s law (§ Ending); chart sessions never load it.

## Roles

Three roles, named once, used everywhere:

| Role | Tier | Note |
|---|---|---|
| Map session | Fable | Charts, sweeps, resolves decisions, distills the charter; `model:*` pin overrides |
| Researcher | `sonnet` absent `model:*` | Resolves one `research`+`afk` ticket, blind to the map |
| Validator / adversary | Per the mandate card (`@attack-kitty` § Tier policy) | Tier follows the mandate, never the work's label |

Conductor/Engineer: `/implement`'s roles, named there. Default-plus-exception, never in-context judgment — a session choosing models for others defaults to its own class (self-selection bias); the defaults above are the countermeasure.

**Claim** is the act and state of holding a ticket — Linear's `delegate` field (`` `@traffic-cone` `` `claim`); parks release it. "Delegate" names the field only, never an agent.

Lifecycle transitions route through `` `@traffic-cone` ``; `` `@attack-kitty` `` executes none.

## Spawning `@traffic-cone` and `@attack-kitty`

Every lifecycle transition goes through `` `@traffic-cone` `` (verb list below); every non-author validation goes through `` `@attack-kitty` ``.

`` `@traffic-cone` `` needs **verb** (`claim`, `mark_done`, `resolve`, `close-map`, `park`, `block`, `un-park`, `cancel`), **target**, **calling context** (skill/session; mapped tickets — parent map id, routing verified). Example: `claim <ticket-id> — delegated from <map-id>'s map session, routing verified`.

`` `@attack-kitty` `` needs **mandate type** (a playbook card), **parameters** (varies by type), **caller depth** (`Caller: L0 orchestrator`/`L1 teammate`). Example: `map-close-eval mandate for <map-id>. Caller: L0 orchestrator`.

Unsure how to compose either's prompt, or either refuses? **Ask the agent** — never guess, never bypass.

**On refusal:** fix what's fixable (a missing field, a malformed brief), flag to operator what isn't (a structural conflict, a WIP collision). Never self-service a refused state change or skip a refused gate; never work an unclaimed ticket. A refusal is a finding, not an obstacle to route around.

**Unreachability — the escape hatch (L-FALLBACK).** A `` `@traffic-cone` `` or `` `@attack-kitty` `` spawn *blocked by the harness* ≠ a refusal — flag it in the same breath as the receipt it degrades. **Availability transitions** (claim, park, un-park, block) may run `/linear`'s known-shape protocol in-session — `/linear`'s `playbooks/claim.md` Step 0 names this hatch. **Certifying transitions** (resolve, mark_done, cancel, close-map) never self-execute this way: park, surface to the operator. Recurring unreachability is a receipt for permissions/config work, never license to normalize the hatch — no disclosure comment, no Linear record; the operator's live flag is the whole disclosure surface.

## Refer by name

Every map and ticket is an issue with a **name** — its title. Use it everywhere a human reads, never a bare id, number, or slug — `#42, #43` is illegible, names read at a glance. The id and URL ride inside the name, never stand in for it.

## The Map

A single Linear issue, labeled `map` — the canonical artifact; its tickets are child issues. An **index**, not a store: it points at the tickets holding the detail — a decision lives in exactly one place, its ticket; the map only gists and links.

The map, its children, blocking, and frontier queries live in Linear, via `/linear`, which owns the mechanics; this skill names the logical operation only — create, claim, wire blocking, query, resolve. No tracker data lives here.

### The map body

Low resolution, loaded once per session. Open tickets aren't listed — they're open child issues, found by query.

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

Each ticket is a **child issue** of the map, sized to one 100K-token session; its body is the question:

```markdown
## Question

<the decision or investigation this ticket resolves>
```

`build` tickets are the exception — `/linear`'s Objective/Done When shape instead ([Decide, then build](#decide-then-build)).

State the test, never the vibe — a tone adjective ("elegantly simple", "robust") is an optimization target for every downstream session that loads it; name the checkable property.

| Label | When set | Semantics |
|---|---|---|
| Type + loop | Create | Routes to a resolver ([Ticket Types](#ticket-types)); loop marks who drives |
| `model:*` on `research`+`afk`/`build` | Operator-acked | Sets the model (default `sonnet`) |
| `model:*` on `hitl` (incl. `research`+`hitl`) | Operator-acked | Pins main context — claim flags a mismatch |
| `model:*` on extraction spawn | — | Ignored — Roles' defaults |

**Claims** first, before any work, via `` `@traffic-cone` `` `claim` — verified, stored in delegate; concurrent sessions skip it. Assignment differs: system-set on operator-directed claims, the operator's field to clear; assigned = never takeable.

Blocking is the tracker's **native** dependency relationship — renders the frontier _visually_ in the tracker's UI, so the human sees what's takeable without opening the map. Unblocked = every blocker closed; the **frontier** is Todo, unblocked, unclaimed. Ordering is `/linear` frontier.md's rule, never restated — `map_sweep.py` computes it.

The answer isn't in the body — recorded on resolution: a comment, findings as a **document on the ticket**, other assets linked, never pasted.

### Cutting discipline

Four principles govern: one question per ticket, vertical not horizontal, dependencies are the decomposition, and fitness — the result fits the purpose precisely, nothing more, nothing less.

Before finalizing any ticket, two tests:

1. Could someone pass this Done When and still miss the point? Close the gap.
2. Does this Done When ask for anything beyond what the Objective needs? Cut the excess.

The Objective encodes purpose, not function. The Done When encodes fitness — quality criteria that mean the purpose is met, not existence checks that mean something was produced.

## Ticket Types

The loop label marks **who drives resolution**. **HITL** — resolves only in live exchange with the operator, who speaks for herself; the agent never stands in (a grilling agent answering its own questions has broken this). **AFK** — an agent drives it alone; parking for operator input (a manual proof, a Needs Input ask) is machinery, not a loop change.

| Type | Loop | Right-sized when | Resolver |
|---|---|---|---|
| `research` | afk/hitl | afk: one focused investigation, one findings document; hitl: one stance to land, one exchange to land it in | `/research ticket` / this session |
| `prototype` | hitl | one thing to build and react to | `/prototype` |
| `grilling` | hitl | one decision to make, one conversation to make it | `/grilling`, `/domain-modeling` |
| `task` | hitl/afk | one blocking action, one session to complete it | agent or checklist |
| `build` | afk | one slice, one proof, one validator | `/implement` |

**`research`+`afk` (blind).** Fact-finding only — docs, APIs, code, knowledge base — how things stand, never what should change; telegraphic (Trace, Enumerate, Map), stripped of the change under consideration. **Spawn prompt is the ticket id alone** — done-condition is the findings contract, never what findings should establish (blindness protection). Resolves via `/research ticket`, delivers, returns — never inline, a map-holding context is contaminated by definition. Orchestrator (map session, never researcher) spawns `` `@traffic-cone` `` `resolve` once doc + resolution comment exist. Endorsement is the sweep's audit; reliance is consumption's verification.

**`research`+`hitl` (stance).** Lands a stance or recommendation — never a blind researcher, never a bare question: carries Destination and Done When too. Orchestrates the research (dispatched extraction, receipted — grinding it in main context is a spec violation), synthesizes, presents defensibly (explored, rejected and why, proposed and why, what proceeding produces), resolves in the operator's exchange, same session, never deferred.

- **`prototype`** — raise the fidelity of the discussion by making a cheap, rough, concrete artifact to react to: an outline, a rough take, a stub, or UI/logic code via `/prototype`, linked as an asset. Use when "how should it look" or "how should it behave" is the key question.
- **`grilling`** — conversation via `/grilling`/`/domain-modeling`, one question at a time. The default case.
- **`task`** — manual work that must happen before a decision can be made: signing up for a service so its API can be judged, provisioning access, moving data so its shape can be seen. The one type that *does* rather than decides — and it earns its place by unblocking a decision, not by delivering the destination. The agent drives it alone where it can (AFK); otherwise it hands the human a precise checklist (HITL). Resolved when done; the answer records what was done and any resulting facts (credentials location, new URLs, row counts) later tickets depend on.
- **`build`** — a charter slice, phase two only; discipline lives in `/implement`.

## Fog of war

The map is _deliberately_ incomplete: don't chart what you can't yet see. Beyond the live tickets lies the **fog of war** — decisions you can tell are coming but can't pin down, hung on questions still open. Resolving a ticket clears the fog ahead of it, graduating whatever's now specifiable into fresh tickets — one at a time, until the way to the destination is clear and no tickets remain.

**Not yet specified** holds that dim view — the suspected question, the area to revisit; write as loosely or fully as the view allows. It's the undiscovered frontier _toward_ the destination — everything here is in scope, just not sharp enough to ticket — and it doubles as a signpost for collaborators reading where the effort is headed.

**Fog or ticket?** Can you state the question precisely now — _not_ can you answer it. Sharp, even if blocked → ticket. Can't phrase it that sharply yet → Not yet specified — don't pre-slice; one patch may graduate into several tickets, or none. Excludes what's decided, ticketed, or out of scope (below).

## Out of scope

Fog gathers only _toward_ the destination — work beyond it is **out of scope**, not fog. Its own section: work consciously ruled out. Scope, not sharpness, lands it here — never graduates, returns only if the destination is redrawn, as a fresh effort, not a resumption.

Ruling something out of scope is a scoping act, not a route step. A ticket sitting past the destination — mis-scoped while charting, or exposed by a resolution — propose the ruling to the operator; on confirmation, spawn `` `@traffic-cone` `` to **cancel it** (reason: its out-of-scope line). One line in **Out of scope**: gist plus why, linking the ticket. Stays out of **Decisions so far** — a scope boundary isn't a step on the route.

## Invocation and modes

Never resolve more than one ticket per session, except **`research`+`afk` — the map session runs those as orchestrator, never the researcher** (grind-in-main-context receipt: sessions grind research in main context when nothing forbids it), chaining them as they unblock, up to **three** per session; past that, the context's own findings begin to color how it briefs the next researcher (context-coloring receipt) — the chain caps before the quality does. `research`+`hitl` is a HITL resolution like any other: one per session.

| Bring | Playbook |
|---|---|
| A loose idea, no map yet | `playbooks/chart.md` |
| A map (URL or number) | `playbooks/work-through.md` |

Expect other sessions editing the tracker concurrently — unblocked tickets run in parallel.
