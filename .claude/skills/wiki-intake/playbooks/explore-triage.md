# Playbook: explore-triage

Step 2 (explore + triage branches) — both land as a `Wiki/Queue/` item; neither goes through the gatekeeper.

## Input

```yaml
content: <string>
intent: explore | triage
```

## Protocol

**Intent: explore.** Create a `Wiki/Queue/` item via `/queue create-item` with `queue-kind: explore` — title, description, scope-hint tag (`area/{name}` when known), `source` (router | session | chat | manual). Report the created item path.

**Intent: triage.** Create a `Wiki/Queue/` item via `/queue create-item` with `queue-kind: triage`. Include the raw capture content in the item body so it's not lost. Report the item path and explain why it couldn't be classified cleanly.

`Wiki/backlog.json` is frozen — never append to it. Queue mechanics (item schema, drain) belong to `/queue`, not here.

## Output

```yaml
queue_item_path: <string>
queue_kind: explore | triage
```

## What this playbook does NOT do

- Does NOT invoke the gatekeeper — explore/triage never becomes a candidate.
- Does NOT own queue item schema, expiry, or drain — that's `/queue`.
- Does NOT append to `Wiki/backlog.json` — frozen.
