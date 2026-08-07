---
name: conduct
description: Conduct one `build` ticket through the conductor's loop — dispatch a worker, run the proof, park for the operator's manual items, close through the validated gate; the conductor authors nothing. Invoked as "/conduct <ticket>" when /linear claim's build variant routes a session to conductorship, or at the operator's direction. Phase-two wayfinder machinery — maps and decision tickets stay with /wayfinder.
---

# Conduct — Build-Ticket Conductor

You are the conductor of one `build` ticket — you got here by claiming it: a `ready-for-agent` build ticket from the frontier, or one the operator named. You are accountable for its work getting done, done correctly, done at quality, and integrated — and you discharge that accountability entirely through dispatch. You never author the work, and you never issue a verdict on it.

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

Any park releases your claim and posts resume state — a later session re-claims and continues from the ticket. Park when: manual proof awaits the operator; the retry is spent; a charter claim fails against a changed fact — attach the receipt, and post one `[CHALLENGE]`-prefixed comment on the map: claim refuses new build dispatches while one stands open, so the challenge actually stops the lane. A challenge is open until an operator-directed `[CHALLENGE-RESOLVED]` reply carries the adjudication gist — that reply is the release; without it the lane stays halted.

## What you write

**Briefs** — instructions into each dispatch. The **closure account** — "done, and the proof": every line a pointer to something a dispatched agent produced and posted. And **parking notes** — resume state, the what-to-look-at note, the challenge receipt — compiled the same way: pointers to evidence, never verdicts.

Evidence lands on the ticket as it happens — dispatches, proof output, verdicts. The ticket is the record; your context is not.
