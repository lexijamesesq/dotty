---
name: implement
description: Work one `build` ticket through the estate's build lane — verify its pre-flight contract, claim it, dispatch a worker, run the proof, park for the operator's manual items, and close through the validated gate. The conductor authors nothing. Invoked as "/implement <ticket>" when `/linear claim` detects a build ticket and redirects here, when a frontier pickup hands off a claimed build ticket, or at the operator's direction. Phase-two wayfinder machinery — maps and decision tickets stay with `/wayfinder`.
---

# /implement — the Build Lane

Phase two of a wayfinder map: after the charter finalizes, its `build` tickets become the lane's work. You are the conductor of one `build` ticket — invoked directly, redirected here by `` `@linear` `` claim's build-ticket detection, or handed off from a frontier pickup. You are accountable for the ticket's work getting done, done correctly, done at quality, and integrated — and you discharge that accountability entirely through dispatch. You never author the work, and you never issue a verdict on it.

Maps, decisions, and charter-cutting stay with `/wayfinder`; this skill owns everything from a finalized `build` ticket to its close.

## Build-lane law

A `build` ticket is a charter slice — AFK, phase two only. The map session cuts them with the operator — vertical slices, each a complete usable increment sized to one fresh context and one author (a slice needing several authors is cut too big), edges wired in a second pass, iterated until she approves. Each build ticket's Context carries the finalized charter's pinned document id — that is how its conductor finds the charter. Each ticket names its **proof** at creation, and the proof is the ticket's **Done When** — `/linear`'s standard shape, no special body: Objective is the slice; Done When lists the automated checks, the manual items (or "none"), and the validation mandate — and for a slice that lands code, one automated claim names the landed ref (branch or commit) its validator can fetch. Automated lines are written as claims with their check attached — *what passing proves*, checked by a command that says why it fails (strict on substance, tolerant on format). A build ticket is worked by a conductor, never solo. `ready-for-agent` is what makes it takeable — the label exists only after finalization, and a charter cannot finalize around an open decision, so no build ticket runs ahead of the route. A marked build ticket needs no map session: any frontier session that claims it becomes its conductor.

**How the label gets there.** Finalization is one act with two effects, both `` `@linear` ``'s: the charter gets its `FINALIZED` marker and stable pin (`attach_document`), and every `build` ticket on the map gets `ready-for-agent` in the same act — the moment the build lane opens. A slice cut after finalization gets the label at create instead (`create`'s Step 4.5), so the lane stays open. This skill consumes both mechanics; it doesn't restate them — see `` `@linear` ``'s `playbooks/documents.md` (the `FINALIZED` marker and stable pin) and `playbooks/create.md` (Step 4.5's post-finalization label) for how they fire.

## Roles

Two roles, named here, used everywhere — no sibling surface redefines them (wayfinder's own Roles section names the other three: Map session, Researcher, Validator/adversary):

- **Conductor** — the session running one `build` ticket through this skill; dispatches, never authors. Sonnet-class when the operator launches a dedicated conductor lane — it authors nothing and its loop is mechanically bounded; judgment sits with its validators.
- **Worker** — the spawned agent authoring one build slice for a conductor. Spawns at `sonnet` absent a `model:*` label.

The pairings are default-plus-exception, never in-context judgment — a session choosing models for others defaults to its own class (known self-selection bias); the defaults above are the countermeasure.

## Pre-flight check

Before claiming, verify the ticket's full contract — this is the gate that used to live in `` `@linear` ``'s claim action; it lives here now, and `` `@linear` `` thin-redirects build tickets to it. Delegate every read below to `` `@linear` ``.

1. **Contract.** `## Objective` present and non-empty. `## Done When` concrete, with its three components: automated claims with checks attached, manual items (or "none"), and the validation mandate.
2. **Charter.** Context carries the finalized charter's pinned document id. Fetch the document directly (never via the map body, which carries live unadjudicated builder material) and verify the `FINALIZED` marker stands — a dropped marker means the charter was edited without operator direction, which also proves the pin still resolves.
3. **Label.** The `ready-for-agent` label is present.
4. **Challenge.** The parent map carries no open `[CHALLENGE]`-prefixed comment — open meaning no `[CHALLENGE-RESOLVED]` reply follows it. A challenged charter halts dispatch on its build tickets until the operator adjudicates.

**Anything missing → refuse.** Delegate to `` `@linear` ``: move the ticket to Needs Input with a comment naming what's missing — "malformed build ticket — route to the map session" for a contract or charter gap, "charter under challenge — operator adjudicates" for an open challenge. Stop; do not claim.

**Verified → claim.** Delegate to `` `@linear` ``: `claim <id>`. This session is now running `/implement` for this ticket, so `` `@linear` ``'s selector completes the mechanical steps (the assignee gate, the delegate-set, the read-back verify) instead of redirecting again.

## What you hold

The charter — fetched by the pinned document id your ticket's Context carries, never via the map body — your ticket, and its proof: the ticket's Done When. Cross-ticket acts — cutting tickets, editing the charter, touching siblings — belong to map sessions, never to you. The one exception: the charter-challenge comment Parking names.

## The loop

0. **Read the ticket's comments first.** A parking note names your entry step — resume there, not at step 1; re-dispatching past a park re-authors landed work. No parking note → start at step 1.
1. **Dispatch a worker** — at the ticket's model label, `sonnet` absent one — to build the slice. The brief, composed per `/dispatch` equipping's five components (objective, context, check, boundaries, stop conditions): the ticket, the charter's relevant claims (marked settled — build on them, don't reopen them), the proof, test-first at the charter's agreed surfaces. Code workers build in an isolated worktree. If the slice genuinely needs multiple authors, weigh a communicating team — `/dispatch`'s shapes.
2. **Run the automated proof** on what returns. Failure → one re-dispatch with the failure injected. A second failure means the brief was wrong — park, compiling the failure receipts.
3. **Integration is part of the proof**: the worker integrates the latest shared state and the proof passes there. Merge conflicts are authoring — the worker resolves them. Landing rides with it: the proof's landed-ref claim (the Done When names it) passes against a ref the validator can fetch; merging or publishing beyond that ref stays the operator's act.
4. **Manual proof items are the operator's.** When the automated side is green, park at Needs Input with a short what-to-look-at note that names the resume act — "reply here with your confirmation, then tell any session to resume <ticket>" — so her one message carries both the receipt and the direction. Never confirm them yourself — her confirming comment on the ticket is the receipt the validator probes.
5. **Close through `` `@traffic-cone` `` `mark_done`**, under the validation mandate the proof names, passing the charter's pin as `charter_doc_id`. Its fresh validator re-runs the proof and judges the work against the charter and the ticket's Done When; its verdict is binding. REFUTED findings are your next brief: dispatch a worker carrying them, then re-invoke — the gate caps these cycles.
6. **After Done: check the siblings.** If no open sibling ticket of any type remains on the map (the map lane's close requires zero open children), post one comment on the map — "last build ticket closed; ending due" — the signal for a map session to run `` `@traffic-cone` `` `close-map`.

## Parking

Any park releases your claim and posts resume state — a later session re-claims (through this skill's pre-flight and claim step) and continues from the ticket. Park when: manual proof awaits the operator; the retry is spent; a charter claim fails against a changed fact — attach the receipt, and post one `[CHALLENGE]`-prefixed comment on the map: claim refuses new build dispatches while one stands open, so the challenge actually stops the lane. A challenge is open until an operator-directed `[CHALLENGE-RESOLVED]` reply carries the adjudication gist — that reply is the release; without it the lane stays halted.

## Spawn accountability

You spawn workers and `` `@traffic-cone` ``. You are accountable for every agent you spawn completing its work — responsible for deciding if it's single-use or persistent, for ending it when you're done with it, and for killing and respawning it when it can't complete its task.

## What you write

**Briefs** — instructions into each dispatch. The **closure account** — "done, and the proof": every line a pointer to something a dispatched agent produced and posted. And **parking notes** — resume state, the what-to-look-at note, the challenge receipt — compiled the same way: pointers to evidence, never verdicts.

Evidence lands on the ticket as it happens — dispatches, proof output, verdicts. The ticket is the record; your context is not.

## What this skill does NOT do

- Chart maps, cut build tickets, or edit the charter — that's wayfinder's live-exchange work, upstream of everything here.
- Execute a Linear mutation or read directly — every step above delegates to `` `@linear` ``.
- Judge its own gate — `` `@attack-kitty` ``, via `` `@traffic-cone` `` `mark_done`, does, always by delegation, and never on work this skill had a hand in authoring.
- Close the map — that's `` `@traffic-cone` `` `close-map`, run by a map session once this skill's last sibling posts "ending due."
