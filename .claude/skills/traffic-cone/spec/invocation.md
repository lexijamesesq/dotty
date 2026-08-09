# Invoking @traffic-cone

## Spawn prompt shape

Three things: **verb**, **target**, **calling context**.

- **Verb:** `claim`, `mark_done`, `resolve`, `close-map`, `park`, `block`, `un-park`, `cancel`
- **Target:** ticket or map id
- **Calling context:** which skill/session, and for mapped tickets — the parent map id and that routing was verified

Example: `claim <ticket-id> — delegated from the <map-id> map session (wayfinder work-through, orchestrator verified routing)`

Without calling context on a mapped ticket, the mapped-ticket check refuses and routes to the operator — correct for a bare pickup, a wasted roundtrip when the caller is the map session.
