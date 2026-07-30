---
name: proof-loop
description: >
  The ordering that makes each piece of work land proven — name the proof, produce
  until it exists, then move. Use when production is about to start: "let's build",
  "implement this", "work through this", "start on it", "take a pass at this", or
  when a task is being split into pieces or steps. Also on pick-up of a claimed
  Linear ticket, and once /dispatch has settled the execution shape. Skip it when the
  work is a single step with no meaningful piece boundary to name proof against.
---

# Proof-First Loop

Work lands in pieces. A piece begins by naming what would prove it, and the piece is complete when that proof exists. There is no later step where proof gets added — a piece without its proof is not a piece yet.

Naming the proof is the first artifact of the piece, not a delay before it. You cannot build what you can't recognize as finished, and the proof is what recognition looks like.

## The loop

1. **Name the proof.** Before the first edit, draft, or search of the piece, state in a sentence what would show it works. If someone who didn't do the work couldn't check it, it isn't the proof yet.
2. **Produce until the proof exists.** Enough to make it hold, no more. Anything the proof doesn't ask for belongs to a later piece.
3. **Land it.** The proof existing is the completion event. A proof that doesn't hold means the piece isn't finished — that's the loop working. The next piece stands on proven ground, which is what makes moving fast safe.

## Seams

A **seam** is the boundary where the proof gets observed — where the piece can be watched behaving without reaching inside it. Agree the seams before the work starts: with the operator when she's in the conversation, declared in the attestation when working from a ticket. Agreeing them up front is what keeps proof effort on the paths that carry risk instead of spread evenly across everything.

Proof at a seam, by craft:

- **Software** — a failing test at a public interface, then passing.
- **Strategy** — the claims a reviewer would attack, named first, then survived.
- **Research** — the question stated precisely enough that a source either answers it or doesn't.
- **Knowledge** — the assertion a reader could falsify, written so falsifying it is possible.

## Horizontal slicing

The failure to watch for: building every piece, then proving everything at the end. Bulk proof checks imagined behavior — it confirms the shape you expected rather than what the work does, and by then each piece has been built on unproven ground. Slice vertically instead: one proof, one piece, repeat, each cycle answering what the last one taught.

When unproven pieces already exist, resist the sweep that proves them all at once — that's the same anti-pattern arriving late. Prove them one at a time, oldest first, and let that finish before a new piece starts.

## Where the loop runs

Inside a Linear ticket, the pieces come from the claim attestation, and each proof becomes a dated progress comment naming its artifact — that accumulation is the evidence manifest `mark_done` asks for. In bare conversation, the pieces come from the exchange and the proof lands in the conversation as it happens. Same loop; only where the proof is recorded changes.

When the proof is hard to name, the piece isn't understood well enough yet — `/grilling` is the conversation for that.
