---
name: vertical-slice
description: Cut a body of work too big for one session into vertical slices — complete, usable increments that reach through every layer, not horizontal stages. A first-principles method, five principles each taught by the failure it prevents, fired at the first cut and every re-cut. Domain-agnostic — software, a launch, a research program, an org change. Invoked when decomposing work into slices — `/wayfinder` calls it at charting and building; any planning context can call it directly.
disable-model-invocation: false
---

# Vertical slices

You have a body of work too big for one session. This is how you decompose it into **vertical slices** — increments you can actually land one at a time. It is a way of thinking, not a checklist: each principle below is paired with the failure it prevents, and the way you use it is to hold your proposed cut against those failures until it survives them.

The method fires at **two moments**, identically: the first cut of the whole body of work, and every later re-cut when a finished slice teaches you the next one is different. (Deciding *when* to re-cut, and running the add/cancel/refine bookkeeping, is the surrounding loop's job — not this method's. This method only answers "given what I know now, where do the cuts go?")

Domain doesn't matter — software, a launch, a research program, an org change. The unit is always the same: a complete increment that leaves the system observably better and stands on its own.

The cut is the highest-leverage decision in the whole effort — get it wrong and the error amplifies downward, becoming many bad increments built against a bad boundary before anyone notices. It earns disproportionate scrutiny before you spend time detailing any single slice.

---

## 1. Cut by outcome-increment, never by layer

A slice is **one complete, usable increment**: after it lands, the system is observably better, and it stands without the next slice arriving. You are cutting the work into *whole thin things*, not into stages of one big thing.

**The failure this catches — the horizontal cut.** "Do all the data models, then all the interfaces, then all the tests." Each layer is inert until the last one lands; nothing is usable in between; a slip anywhere strands everything. The tell: a slice whose value only arrives when a *later* slice does. That slice is a layer, not an increment — re-cut it so each piece reaches through every layer it needs to be usable on its own.

Three corollaries of "complete increment":

- **The first slice is a walking skeleton** — the leanest end-to-end thread that touches every layer and proves the whole path works while doing almost nothing. (For a search feature: search one field, exact-match only, rendered in the real UI — not "the whole index," not "the query parser.") It buys you a working spine to hang everything else on.
- **A destructive slice must re-land what it removes, in the same slice** — or hand the seam to a named sibling explicitly. Removing or changing existing behavior and leaving the system broken until a *later* slice restores it is the horizontal failure wearing a demolition hat. If two slices touch the same surface, decide at cut time which one owns the seam, so the system is never incoherent between landings.
- **One increment is one question, one session.** If a slice holds two things that could ship independently, it's two slices. If it can't fit one focused work session, it's too big — cut again.

## 2. Find the cuts in the dependency structure, not the schedule

You don't *invent* an order and then justify it. You find **what must be true before each piece can land**, and the wiring shows you where the natural seams already are. Dependencies are the decomposition.

**The failure this catches — cutting by box.** Slicing along components, teams, or calendar phases produces pieces that look tidy and can't land independently, because the real seams run *across* those boxes. When you find yourself unable to land a slice without "just also" landing its neighbor, the cut is following the wrong grain — follow the enablement chain instead.

## 3. Cut to the fidelity you have — near sharp, far directional

At any cut, the near work you can state precisely; the far work you can only point at. **Don't manufacture certainty about distant slices** — they sharpen for free as you finish what sits between you and them. This is why the method re-fires: each completed slice turns some fog into something you can now cut sharply.

**The ruling that makes this safe:** a slice you cannot yet state as a **sharp, answerable question** is not a ticket — it stays a named *fog patch* until you're close enough to sharpen it. A directional slice promoted to a takeable ticket early lets someone pick it up and build against a question that wasn't ready.

**The failure this catches — two-sided.** Front-load thirteen fully-specified tickets and you'll rework half of them when reality arrives (false certainty). Leave a vague "we'll need something about X" sitting as a takeable ticket and someone builds the wrong X (premature sharpness). Near: sharp ticket. Far: honest fog. Nothing in between pretending to be either.

## 4. Name each slice by the needle it moves or the state it creates — then test fitness

Every slice carries its **Done When** at birth, and it is *observable*: a needle moved, or a state that now exists — never "did we build it." Name the slice's negative space too — what it's explicitly *not* doing, the adjacent work it excludes, and which sibling slice owns that overflow. Stated up front, the exclusion sharpens the boundary with neighboring slices and stops the slice absorbing a tempting adjacent question mid-execution.

Then, before the cut is final, two tests:

- **Could someone satisfy this Done When and still miss the point?** If yes, the letter and the spirit have a gap — close it.
- **Does this Done When ask for anything the objective doesn't need?** If yes, cut the excess.

**The failure this catches.** "Improve the onboarding flow" is not a Done When — you can't tell when it's true, so the slice never closes cleanly and its validator has nothing to check. And a Done When that passes on a technicality while missing the intent ships a slice that's "done" and useless. A slice with no stated exclusions quietly grows to swallow its neighbors' work — absorbing whatever adjacent question comes up mid-execution instead of staying inside its boundary.

## 5. Choose where to start deliberately — keystone or rhythm-setter

Two good first moves, for opposite reasons. The **keystone**: the slice everything else reshapes around — do it first and every downstream slice sharpens against its answer. The **rhythm-setter**: an independent, zero-blast-radius win — do it first to establish flow and bank a clean result. Either is right; drifting into "whatever's easiest to see" is not.

**The failure this catches.** Start at the convenient corner and you discover, three slices in, that everything you built reshapes the moment the keystone finally lands — you paid to build against assumptions the keystone would have settled.

---

## Using this

Lay out your proposed slices and walk each principle's *failure* against them — is any slice a layer (1)? cutting across the grain (2)? a fog patch masquerading as a ticket (3)? un-closeable, bloated, or missing its exclusions (4)? Have you chosen your entry (5)? A cut that survives all five failures is ready; one that doesn't tells you exactly where to re-cut. You are testing the cut against how it breaks, not filling in a form.
