---
name: wayfinder
description: Chart and work a map — turn a loose idea too big for one session into decision tickets on Linear, resolve them one at a time with the operator, then build from the operator-confirmed intent through validated slices. Domain-agnostic — software, strategy, content, research. Invoked by the operator — "chart a map", "work the map", or a named map.
disable-model-invocation: false
---

# Wayfinder

<!-- Seeded by Matt Pocock's wayfinder skill (MIT): https://github.com/mattpocock/skills — rebuilt estate-native (Linear-native, two-phase, status machine); inherited traces remain (the fog/map framing, the refer-by-name guidance). -->

A loose idea has arrived — too big for one session, wrapped in fog: the way to the **destination** isn't visible yet. Wayfinding charts that way as a shared **map** in Linear, works its **decision tickets** one at a time until the route is clear, then builds from what it decided ([Decide, then build](#decide-then-build)). Naming the destination is charting's first act — it fixes scope, shapes every ticket.

No map yet → `playbooks/chart.md`; a map (URL or number) → `playbooks/work-through.md` — table in [Invocation and modes](#invocation-and-modes).

## Decide, then build

Every map runs two phases. **Phase one decides** — conversation, research, throwaway makes on fixtures: plentiful, cheap, never durable mutations. Each ticket resolves a decision. A HITL ticket is attacked before close, the operator is the attacker; an AFK ticket delivers receipted facts, and its trial is consumption — whoever rests a decision on them verifies them first. The doing phase begins once the decision frontier is empty — the pull to start building is the signal to check the frontier, not to build.

**The threshold.** The crossing into building is light: **operator-confirmed Destination + Done When** — shared intent strong enough to base decisions on, not a fully-specced list of boxes. The map body's own `## Destination` + `## Done When`, confirmed with the operator, *is* the settled spec. It stays **living** — re-cut as each slice teaches — but every change to it is the operator's call, never a session's own. If a decision is still open, STOP — resolve or ticket it; the threshold is shared understanding, not the absence of every question.

**Building.** The doing phase cuts **vertical slices** with the operator — near ones sharp, distant ones directional, tickets added / cancelled / refined as each slice teaches. Every slice plan and every slice result is attacked (`` `@attack-kitty` ``) by default. The ending — the last slice closes and the assembly reaches Destination + Done When (via `map-close-eval`) — is `playbooks/work-through.md`'s law (§ Ending); chart sessions never load it.

## Working stance

This session orchestrates; it does not grind. Its work is thought-partnership with the operator and dispatch — authoring at scale goes to teammates, at the lowest model class the outcome tolerates (`/dispatch` shapes the call; `sonnet` the common default). Delegation moves the work, never the accountability: the session answers for every ticket it claims.

Slices are **vertical** — each a complete, usable increment — never horizontal layers; the cut and its tests are [Cutting discipline](#cutting-discipline). Check for drift from the Destination as the work runs: producing an artifact is not success, reaching the outcome is — a slice that ran but left the map no closer to Done When is not done.

`` `@attack-kitty` `` is the non-author check, used three ways: `pressure-test` a plan before building it, `deliverable-check` an implementation after, and — optionally — `thought-partner` a hard problem through. It surfaces gaps and what was missed; it never rewrites your intent. Each mandatory firing point names its mandate where it fires — work-through's firing points (plan-attack before `begin`, the close validator by kind, `map-close-eval` at the ending); spawn shape and caller depth: § Running transitions.

Every map and ticket is referred to by its **name** — its title — everywhere a human reads, never a bare id, number, or slug: `#42, #43` is illegible, names read at a glance; the id and URL ride inside the name, never stand in for it.

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

Every lifecycle transition is a **call to the `traffic-cone` gate** — hand it a verb, consume its verdict; it runs its own checks and executes in-process. What it runs is behind the wall: never assemble or hand-run `cone_preflight` yourself — reaching past the gate defeats it.

### Transitions

Navigate a transition by its verb — the Invocation column is the whole call. Values in `"quotes"` are the semantic ones you supply (an ask, a condition, a reason); nothing mechanical is learned. This table is the resolver: every firing point below (and in the playbooks) names a verb and points here.

| Action | Description | Invocation |
|---|---|---|
| **Claim** | Take a takeable ticket before any work (a map-child slice lands in Planning) | `traffic-cone claim <id>` |
| **Begin** | Move a claimed slice from Planning to In Progress, once its plan is attacked | `traffic-cone begin <id> --plan-attested` |
| **Park** | Pause on the operator; releases the claim | `traffic-cone park <id> --ask "<text>"` |
| **Block** | Mark blocked on an external condition | `traffic-cone block <id> --condition "<text>"` |
| **Un-park** | Return a parked ticket to Todo | `traffic-cone un-park <id> --blocker-verified` |
| **Cancel** | Rule a ticket out of scope / invalidated | `traffic-cone cancel <id> --reason "<text>"` |
| **Close map** | Final map close after a CONFIRMED eval | *staged* — `traffic-cone close-map <id>` points to traffic-cone's `playbooks/close-map.md` (map session) |
| **Mark done** | Close a resolved ticket by its recorded result — the one close verb for every ticket (needs a `[VALIDATION]` receipt; `[HANDOFF]` too for a map child) | `traffic-cone mark-done <id>` |

Claim's edge intents ride as flags when they apply — `--operator-directed` (a non-Todo claim you direct), `--autonomous` (frontier pickup, no operator), `--caller-ack-wip` (a WIP collision that is a related chain); the common claim needs none.

**Escape hatch — the only reason to open `/traffic-cone`:** a `REFUSE` you don't understand, or a `JUDGMENT_REQUIRED` kernel you can't rule. The kernel-ruling flags (`--model-ruled`, `--mandate-type`, …) are pass-through on the gate for that path only — off the happy path by definition.

### Result handling

**ADMIT** executed and reported. Anything else blocks the transition: **REFUSE** is binding — never re-run hoping, never hand-edit state around it; **NEEDS_INPUT** has already parked/routed the ticket in-process; **JUDGMENT_REQUIRED** waits on this session to rule the named kernel and resume. Verb-by-verb behavior and every kernel's question: `/traffic-cone` § Result handling and § Judgment kernels.

`` `@attack-kitty` `` needs **mandate type** (a playbook card), **parameters** (varies by type), **caller depth** (`Caller: L0 orchestrator`/`L1 teammate`). Example: `map-close-eval mandate for <map-id>. Caller: L0 orchestrator`.

Unsure how to compose `` `@attack-kitty` ``'s prompt, or it refuses? **Ask the agent** — never guess, never bypass.

**On refusal:** fix what's fixable (a missing field, a malformed brief), flag to the operator what isn't (a structural conflict, a WIP collision). A refusal is a finding, never an obstacle to route around — and an unclaimed ticket is never worked.

**`` `@attack-kitty` `` blocked by the harness** ≠ a refusal. A judgment or eval spawn the harness won't let through parks the ticket and surfaces to the operator in the same breath as the receipt it degrades — transitions have no equivalent case now; they spawn nothing the harness could block. When a spawn does go through, its return is consumed as given — a gap gets fielded or the spawn respawned once, never repeatedly.

## The Map

A single Linear issue, labeled `map` — the canonical artifact; its tickets are child issues. An **index**, not a store: it points at the tickets holding the detail — a decision lives in exactly one place, its ticket; the map only gists and links.

The map, its children, blocking, and frontier queries live in Linear, via `/linear`, which owns the mechanics; this skill names the logical operation only — create, claim, wire blocking, query, close. No tracker data lives here.

### The map body

Low resolution, loaded once per session; open tickets aren't listed — they're open child issues, found by query. Body shape — `## Destination`, `## Done When`, `## Notes`, a `## Decisions` pointer, `## Fog`, `## Out of scope` — authored once at charting; the template lives in `playbooks/chart.md` (§ The map body template).

**The Decisions document.** The decision index lives in a Linear document attached to the map, titled `Decisions — <map name>` — not in the body, so it grows without touching map intent. Evolution mode ([mutation-record-spec](../traffic-cone/playbooks/mutation-record-spec.md)): append-only, one entry per closed ticket — Done or Cancelled — newest last, never a rewrite of a landed entry. Entry shape — `[<closed ticket title>](link) — <one-line gist of the answer>`. It's map-scoped and dies with the map. Created lazily — the first resolution that has a decision to record creates it (work-through step 3); a fresh map carries the pointer and no doc yet. `map_sweep.py`'s `decisions_missing` reads this doc.

### Tickets

Each ticket is a **child issue** of the map, sized to one 100K-token session; its body carries the standardized child skeleton — `## Objective` (intent + problem space) and `## Done When` (fitness: needle-moved or state-exists) required, `## Constraints`/`## Context` only when the slice genuinely carries one. The template is `/linear`'s `playbooks/create.md`; every child takes this shape — decision and build slices alike, no separate `## Question` body.

State the test, never the vibe — a tone adjective ("elegantly simple", "robust") is an optimization target for every downstream session that loads it; name the checkable property.

| Label | When set | Semantics |
|---|---|---|
| Loop (`hitl`/`afk`) | Create | Marks who drives (`playbooks/work-through.md` § Resolving a slice) |
| `model:*` on an afk slice | Operator-acked | Sets the model (default `sonnet`) |
| `model:*` on a hitl slice | Operator-acked | Pins main context — claim flags a mismatch |
| `model:*` on extraction spawn | — | Ignored — Roles' defaults |

**Claims** first, before any work, via the `claim` transition (§ Running transitions) — verified, stored in delegate; concurrent sessions skip it. Assignment differs: system-set on operator-directed claims, the operator's field to clear; assigned = never takeable.

Blocking is the tracker's **native** dependency relationship — renders the frontier _visually_ in the tracker's UI, so the human sees what's takeable without opening the map. Unblocked = every blocker closed; the **frontier** is Todo, unblocked, unclaimed. Ordering is `/linear` frontier.md's rule, never restated — `map_sweep.py` computes it.

The answer isn't in the body — recorded on resolution: a comment, findings as a **document on the ticket**, other assets linked, never pasted.

### Cutting discipline

Four principles govern: one question per ticket, vertical not horizontal, dependencies are the decomposition, and fitness — the result fits the purpose precisely, nothing more, nothing less. The full method — finding the cuts and testing them, at the first cut and every re-cut — is the `vertical-slice` skill; invoke it when cutting.

The Objective encodes purpose, not function. The Done When encodes fitness — quality criteria that mean the purpose is met, not existence checks that mean something was produced.

## Fog of war

The map is _deliberately_ incomplete: don't chart what you can't yet see. Beyond the live tickets lies the **fog of war** — decisions you can tell are coming but can't pin down, hung on questions still open. Resolving a ticket clears the fog ahead of it, graduating whatever's now specifiable into fresh tickets — one at a time, until the way to the destination is clear and no tickets remain.

**Fog** holds that dim view — the suspected question, the area to revisit; write as loosely or fully as the view allows. It's the undiscovered frontier _toward_ the destination — everything here is in scope, just not sharp enough to ticket — and it doubles as a signpost for collaborators reading where the effort is headed.

**Fog or ticket?** Can you state the question precisely now — _not_ can you answer it. Sharp, even if blocked → ticket. Can't phrase it that sharply yet → Fog — don't pre-slice; one patch may graduate into several tickets, or none. Excludes what's decided, ticketed, or out of scope (below).

## Out of scope

Fog gathers only _toward_ the destination — work beyond it is **out of scope**, not fog. Its own section: work consciously ruled out. Scope, not sharpness, lands it here — never graduates, returns only if the destination is redrawn, as a fresh effort, not a resumption.

Ruling something out of scope is a scoping act, not a route step. A ticket sitting past the destination — mis-scoped while charting, or exposed by a resolution — propose the ruling to the operator; on confirmation, run the `cancel` transition (§ Running transitions) — reason: its out-of-scope line. One line in **Out of scope**: gist plus why, linking the ticket. Stays out of the **Decisions document** — a scope boundary isn't a step on the route.

## Invocation and modes

One slice **in progress** at a time; a session chains to the next slice only after the full close — receipts posted, wrap done (work-through's per-close law). Context health is the limiter: chain while judgment stays sharp, hand off when it doesn't. **Blind investigations** run differently — the map session runs those as orchestrator, never the researcher (grind-in-main-context receipt), chaining them as they unblock, up to **three** per session; past that, the context's own findings begin to color how it briefs the next researcher (context-coloring receipt) — the chain caps before the quality does. A stance-landing slice is a HITL resolution: one per session in the operator's exchange.

| Bring | Playbook |
|---|---|
| A loose idea, no map yet | `playbooks/chart.md` |
| A map (URL or number) | `playbooks/work-through.md` |

Expect other sessions editing the tracker concurrently — unblocked tickets run in parallel.
