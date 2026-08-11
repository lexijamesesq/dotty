---
name: implement
description: Work one `build` ticket through the estate's build lane — verify its pre-flight contract, claim it, dispatch an engineer, run the proof, park for the operator's manual items, and close through the validated gate. The conductor authors nothing. Invoked as "/implement <ticket>" when `/linear claim` detects a build ticket and redirects here, when a frontier pickup hands off a claimed build ticket, or at the operator's direction. Phase-two wayfinder machinery — maps and decision tickets stay with `/wayfinder`.
---

# /implement — the Build Lane

Phase two of a wayfinder map: after the charter finalizes, its `build` tickets become the lane's work. You are the conductor of one `build` ticket — invoked directly, redirected here by `/linear` claim's build-ticket detection, or handed off from a frontier pickup. You are accountable for the ticket's work getting done, done correctly, done at quality, and integrated — and you discharge that accountability entirely through dispatch. You never author the work, and you never issue a verdict on it.

Maps, decisions, and charter-cutting stay with `/wayfinder`; this skill owns everything from a finalized `build` ticket to its close.

## Build-lane law

A `build` ticket is a charter slice — AFK, phase two only. The map session cuts them with the operator — vertical slices, each a complete usable increment sized to one fresh context and one author (a slice needing several authors is cut too big), edges wired in a second pass, iterated until she approves. Each build ticket's Context carries the finalized charter's pinned document id — that is how its conductor finds the charter. Each ticket names its **proof** at creation, and the proof is the ticket's **Done When** — `/linear`'s standard shape, no special body: Objective is the slice; Done When lists the automated checks, the manual items (or "none"), and the validation mandate — and for a slice that lands code, one automated claim names the landed ref (branch or commit) its validator can fetch. Automated lines are written as claims with their check attached — *what passing proves*, checked by a command that says why it fails (strict on substance, tolerant on format). A build ticket is worked by a conductor, never solo. `ready-for-agent` is what makes it takeable — the label exists only after finalization, and a charter cannot finalize around an open decision, so no build ticket runs ahead of the route. A marked build ticket needs no map session: any frontier session that claims it becomes its conductor.

**How the label gets there.** Finalization is one act with two effects: the charter gets its `FINALIZED` marker and stable pin (`attach_document`), and every `build` ticket on the map gets `ready-for-agent` in the same act — the moment the build lane opens. A slice cut after finalization gets the label at create instead (`create`'s Step 4.5), so the lane stays open. This skill consumes both mechanics; it doesn't restate them — see `/linear`'s `playbooks/documents.md` (the `FINALIZED` marker and stable pin) and `playbooks/create.md` (Step 4.5's post-finalization label) for how they fire.

## Roles

Two roles, named here, used everywhere — no sibling surface redefines them (wayfinder's own Roles section names the other three: Map session, Researcher, Validator/adversary):

- **Conductor** — the session running one `build` ticket through this skill; dispatches, never authors. Sonnet-class when the operator launches a dedicated conductor lane — it authors nothing and its loop is mechanically bounded; judgment sits with its validators.
- **Engineer** — the session-scoped discipline teammate authoring build slices for a conductor. Receives work via SendMessage, persists within the session. May invoke `/dispatch` for complex slices — dispatch decides whether to work it directly, fan out unnamed subagents, or use a thinking partner. Spawns at `sonnet` absent a `model:*` label.

The pairings are default-plus-exception, never in-context judgment — a session choosing models for others defaults to its own class (known self-selection bias); the defaults above are the countermeasure.

## Running transitions, spawning `@attack-kitty`

Every lifecycle transition (`claim`, `park`, `mark_done`, `cancel`) runs through traffic-cone's fused scripts — the conductor runs `cone_preflight.py <verb> <target> --execute-if-clean [flags]` itself, in-process; no agent is spawned for a transition. The traffic-cone skill's Dispatch table names the exact invocation per verb. **ADMIT** executes and reports; **REFUSE** is binding — never re-run hoping, never hand-edit state; **JUDGMENT_REQUIRED** routes per traffic-cone's judgment kernels — most rule in this session, M3g alone (full-variant `mark_done`, never a build ticket here — build children are map children, CM5/CM6 audit them at close) routes onward to `` `@attack-kitty` ``'s `ticket-close` mandate. Every validation still goes through `` `@attack-kitty` ``, unchanged.

**`` `@attack-kitty` ``** expects three things: **mandate type** (one of its playbook cards), **parameters** (ticket id, map id, charter doc id — varies by type), and **caller depth** (`Caller: L0 orchestrator` or `Caller: L1 teammate`). Example: `ticket-close mandate for <ticket-id>, charter doc id <id>. Caller: L0 orchestrator`.

If `` `@attack-kitty` `` refuses or you're unsure how to compose its prompt, **ask the agent** — it can explain what it needs. Never guess at the shape and never bypass.

**On refusal:** fix what's fixable (a missing field, a malformed brief), flag to operator what isn't (a structural conflict, a charter gap). Never bypass -- never self-service a state change traffic-cone's scripts refused, never skip a validation gate `` `@attack-kitty` `` refused, never proceed with work on an unclaimed ticket. A refusal is a finding, not an obstacle to route around.

**`` `@attack-kitty` `` blocked by the harness** ≠ a refusal — flag it to the operator in the same breath as the receipt it degrades; park and surface, never self-execute a workaround. Transitions have no equivalent case — they spawn nothing the harness could block.

## Pre-flight check

Before claiming, verify the ticket's full contract — the conductor runs the checks itself, from its own fresh fetch, never through an intermediary's summary.

1. **Run the deterministic checks:** `cone_preflight.py claim <ticket-id> --project-id <project-id> --conductor-preflight` (`.claude/skills/linear/scripts/`; bridge-command resolution per traffic-cone's SKILL.md § Scripts). The `--conductor-preflight` flag runs the build-variant checks without asserting the delegated flag — `--delegated-preflight-passed` is then passed to the fused claim invocation this check admits. The script fetches directly and never mutates. Its report covers the contract shape (C1/C2 — a `build` ticket carries Objective and Done When), the `ready-for-agent` label (C4a), the charter's `FINALIZED` marker fetched by the pinned document id — never via the map body, which carries live unadjudicated builder material (C4b), the open-`[CHALLENGE]` scan (C4c), and claimable state (C5) — plus the cross-cutting claim checks (type-label, closed-parent, WIP, model-label, assignee gate) that run alongside unconditionally; the verdict you consume aggregates all of them.
2. **Judge what the script can't:** Done When's three components present as content, not just shape — automated claims with checks attached, manual items (or "none"), and the validation mandate. A shape-passing Done When missing a component is still a contract gap.

**Anything missing → refuse.** Run traffic-cone's fused `park` script (`--comment-file` naming what's missing — "malformed build ticket — route to the map session" for a contract or charter gap, "charter under challenge — operator adjudicates" for an open challenge). Stop; do not claim.

**Verified → claim.** Run traffic-cone's fused `claim` script with `--delegated-preflight-passed` — the script re-runs its own admission checks independently (no actor trusts another's word) and executes the claim via `/linear`'s claim protocol (the GraphQL bridge, the read-back verify). A refusal at claim time is a data error this pre-flight missed — surface it, don't retry.

## What you hold

The charter — fetched by the pinned document id your ticket's Context carries, never via the map body — your ticket, and its proof: the ticket's Done When. Cross-ticket acts — cutting tickets, editing the charter, touching siblings — belong to map sessions, never to you. The one exception: the charter-challenge comment Parking names.

## The loop

0. **Read the ticket's comments first.** A parking note names your entry step — resume there, not at step 1; re-dispatching past a park re-authors landed work. No parking note → start at step 1.
1. **Dispatch the engineer** — if no engineer teammate is running for this session, spawn one with a discipline brief (`playbooks/discipline-brief.md`) at the ticket's model label, `sonnet` absent one. Send the slice via SendMessage: the ticket, the charter's relevant claims (marked settled — build on them, don't reopen them), the proof, test-first at the charter's agreed surfaces. Code engineers build in an isolated worktree. If the slice genuinely needs multiple authors, weigh a communicating team — `/dispatch`'s shapes.
2. **Run the automated proof** on what returns. Failure → one re-dispatch with the failure injected. A second failure means the brief was wrong — park, compiling the failure receipts.
3. **Integration is part of the proof**: the engineer integrates the latest shared state and the proof passes there. Merge conflicts are authoring — the engineer resolves them. Landing rides with it: the proof's landed-ref claim (the Done When names it) passes against a ref the validator can fetch; merging or publishing beyond that ref stays the operator's act, through `/publish`.
4. **Manual proof items are the operator's.** When the automated side is green, run traffic-cone's fused `park` script with a short what-to-look-at note (via `--comment-file`) that names the resume act — "reply here with your confirmation, then tell any session to resume <ticket>" — so her one message carries both the receipt and the direction. Never confirm them yourself — her confirming comment on the ticket is the receipt the validator probes.
5. **Validate.** Spawn `` `@attack-kitty` `` with the validation mandate the proof names, the charter's pinned document id, and `Caller: L0 orchestrator` in the spawn prompt. Attack-kitty fetches its own evidence, re-runs the proof, and judges the work against the charter and the ticket's Done When. Three outcomes:
   - **CONFIRMED** → attack-kitty posts a `[VALIDATION]` receipt on the ticket. Proceed to step 6.
   - **REFUTED / CONFIRMED-WITH-GAPS** → findings return directly to you. Those findings are your next brief: send them to the engineer via SendMessage, then re-validate. The gate caps these cycles.
   - **CHARTER-CONFLICT** → the charter's claims don't hold against the facts. This is not fixable by an engineer — post a `[CHALLENGE]`-prefixed comment on the map naming the conflicting claim and its receipt, then run traffic-cone's fused `park` script. The challenge halts the lane until the operator adjudicates.
6. **Close.** After a CONFIRMED receipt lands, run traffic-cone's fused `mark_done` script. It independently verifies the receipt (M3a–f: exists, fresh, type-matched, well-formed, posted by the app actor) and executes the Done transition — M3g never fires here: a `build` ticket is a map child, and CM5/CM6 audit its receipt at close-map instead. A refusal means the receipt is defective — surface it, don't retry the transition.
7. **After Done: check the siblings.** If no open sibling ticket of any type remains on the map (the map lane's close requires zero open children), post one comment on the map — "last build ticket closed; ending due" — the signal for a map session to run traffic-cone's staged `close-map` protocol.

## Parking

Every park runs through traffic-cone's fused `park` script — the conductor names the reason and the ask via `--comment-file` (R-A: the composing session owns its ask's specificity; the script posts it and executes, never judges whether it's specific enough) — which sets Needs Input and releases the claim. To resume: the operator confirms the blocker is resolved (or directs the un-park), a session runs the fused `un-park` script (Needs Input → Todo, `--operator-directed` or `--blocker-verified`), then re-claims through this skill's pre-flight and claim step and continues from the ticket's parking note. A `JUDGMENT_REQUIRED` verdict on any of these routes per traffic-cone's judgment kernel — rule it in this session, then re-run with the matching assertion flag. Park when: manual proof awaits the operator; the retry is spent; a charter claim fails against a changed fact — attach the receipt, and post one `[CHALLENGE]`-prefixed comment on the map: claim refuses new build dispatches while one stands open, so the challenge actually stops the lane. A challenge is open until an operator-directed `[CHALLENGE-RESOLVED]` reply carries the adjudication gist — that reply is the release; without it the lane stays halted.

## Spawn accountability

You spawn an engineer (session-scoped) and `` `@attack-kitty` `` (for validation) — transitions run through traffic-cone's fused scripts directly, never a spawn. You are accountable for every agent you spawn completing its work — responsible for deciding if it's single-use or persistent, for ending it when you're done with it, and for killing and respawning it when it can't complete its task.

## What you write

**Briefs** — instructions into each dispatch. The **closure account** — "done, and the proof": every line a pointer to something a dispatched agent produced and posted. And **parking notes** — resume state, the what-to-look-at note, the challenge receipt — compiled the same way: pointers to evidence, never verdicts.

Evidence lands on the ticket as it happens — dispatches, proof output, verdicts. The ticket is the record; your context is not.

## What this skill does NOT do

- Chart maps, cut build tickets, or edit the charter — that's wayfinder's live-exchange work, upstream of everything here.
- Mutate ticket state directly — all state changes (claim, park, mark_done, cancel) route through `` `@traffic-cone` ``.
- Judge its own gate — `` `@attack-kitty` `` validates independently; `` `@traffic-cone` `` verifies the receipt and executes the transition. Neither trusts this skill's word.
- Close the map — that's `` `@traffic-cone` `` `close-map`, run by a map session once this skill's last sibling posts "ending due."
