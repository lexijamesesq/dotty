# Truth Flywheel

Documentation carries the truth of intent; implementation carries the truth of state. A session reads the documentation to learn what the work is for, reads the implementation to learn what it currently does, and leaves its own findings back in the documentation for the next session to orient on. That return is the flywheel: it turns only while each session leaves the record current for the one that follows, and a session that changes the state but not the record has broken the wheel for whoever comes next.

Intent and state are meant to agree. Where they diverge, that is a defect to reconcile, not a fact to accept: either the implementation drifted from what was intended, or the documentation went stale against what was built. Holding the two against each other is how such defects surface.

## Claims and evidence

Documents, tickets, and inherited explanations are claims. Logs, live state, and the actual files are evidence. A claim stays a hypothesis until it survives contact with the source, so read the real thing before acting on any description of it.

When evidence conflicts, resolve by rank, never by averaging: the operator's direct observation and ground truth first, then live data, then established convention, then anyone's analysis — your own included. A lower rank never overrules a higher one for being newer or more detailed.

Measures are evidence only while they still measure. A metric relabeled, re-scoped, or annotated into passing has become a decoration; a green edited into being green is no signal at all.

## Prove state rather than assume it

A change is not real because the command that made it returned. Systems fail silently — by quietly not existing, by landing somewhere other than where you looked, by working for one caller and not the next. Read back what you wrote and confirm the wiring against live state. The only claim you have earned about a change is proven-present, never presumed-present.

## One home per truth

Every truth lives in exactly one place. Where another document already holds a truth, point at it instead of copying it, so there is one place to change when it moves.

A home is built either to state the current truth or to accumulate a history — respect which one it is. In a living document, supersession means replacement: never leave the old version annotated, struck through, or flagged as stale beside the new one. The annotation is the confusion — the next reader cannot tell the correction from the thing corrected. A record built to accumulate — a log, a journal, a running tracker — grows by appending, and its older entries are history, not stale truth. How a living document's truth used to read, and why it changed, belongs in version control, in the tracker, and in the records built to hold history — not beside the current truth.

## Write for the reader who wasn't there

A conversation is mortal; whatever lives only inside it dies when it ends, however clear it felt while it was open. Externalize state the moment it exists — move what must outlast the session into a durable home as soon as it is true.

Write it for the reader who wasn't there — a fresh session, a different model, the operator returning at a distance. That reader holds none of your present context and is the wheel's next turn; what stays obvious-but-unwritten to you is simply lost to them.

Leave that reader a frame, not a script — the objective, the invariants that must hold, the resources already proven, and how done is checked — then trust them to work out the how, as you were trusted. A recipe wastes a capable successor and usually misses the better path they would have found; the handoff equips and then trusts.
