---
name: orchestrate
description: >
  How a team runs once the work is divided — the orchestrator writes briefs, workers
  author, separate workers validate, verdicts get adjudicated on the ticket where the
  operator can read them. Use when an effort spans several pieces or tickets, when
  working a map of tickets toward a destination, when the operator asks for orchestrated
  or agent-team execution, and once /dispatch has settled on delegating. Not needed
  when one context is doing the work itself — that context still owes mark_done's
  non-author validation before Done; this skill governs division of labor, not
  whether closure needs a fresh-context check.
---

# Orchestrate

Running a team is its own craft, distinct from doing the work. The orchestrator holds the map, writes the briefs, and rules on the verdicts. It doesn't author the artifacts — the moment it picks up the pen, it has traded the vantage point that made it useful for one more pair of hands.

`/dispatch` decides whether to divide the work and who gets it; this skill is how the team runs afterward. Each piece a worker takes still runs under `/proof-loop`.

## Roles

- **The orchestrator** produces briefs, adjudications, and map updates. Those are its artifacts; there are no others.
- **Workers author.** One worker per piece, holding only what its brief carries.
- **Validators check work they had no part in** — they receive the charter and the artifact, not the author's account of it. An author doesn't grade its own piece, and the orchestrator that briefed the work is an author of it.

## Briefs

A worker arrives knowing only its brief. Each one carries the done-condition the work will be checked against — stated before the work starts, checkable by someone who didn't do it — and points at sources to read verbatim: the ticket, the file, the record. Worth saying plainly in the brief: read these, don't work from my summary. A paraphrase is where the orchestrator's misreading becomes the worker's output. A brief missing either half — no stated done-condition, or sources carried only in the orchestrator's retelling — isn't ready to send; finish it before the spawn.

Send follow-on work back to the same worker when its context is what qualifies it — a fix to its own artifact, the next piece in the same material. Resuming beats respawning; a fresh context re-derives what the last one already holds. Validation is the standing exception: it goes to a context with no stake in the answer.

## Verdicts

A validator returns a verdict and its specifics; the orchestrator rules on them in writing, on the ticket, before the work moves on — which gaps are real losses to fix, which are charter over-specification, which are tension in the charter rather than defects in the work. A CONFIRMED-WITH-GAPS accepted quietly is indistinguishable from no validation at all, since the operator can only audit what was written down.

When a worker raises something outside its brief, that becomes a ticket rather than a quiet fix. The record of what was noticed and deferred outlasts the small repair, and out-of-scope work done silently is invisible to everyone who arrives later.

## The map

For an effort spanning many pieces, the map is a single ticket carrying the destination and one line per landed piece — a gist and a link, with the detail staying on that piece's own ticket. Tend it as each piece lands: this index is what a fresh session reads to orient before choosing what comes next.

Route each worker's model to what its piece asks for rather than letting it inherit yours — judgment and validation earn the premium tier, mechanical conformance doesn't. The routing methodology lives in the vault (`orchestrator-model-dispatch`), not here.
