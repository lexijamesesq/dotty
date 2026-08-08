# Playbook: documents

Attach and archive documents on Linear issues — the FINALIZED marker and its cascade, and archive-with-retained-link. Mechanical actions only: they read and write the markers, they never interpret them or decide when finalization is warranted.

## Input

```yaml
issue_id: <TEAM>-N                                                   # required
document: { title: <string>, content: <markdown>, finalized: true|false }   # for attach_document, create path
document_id: <id>                                                    # for attach_document (update-in-place, pin stays stable) or archive_document
```

## Protocol

### `attach_document`

- **With `document_id`:** `mcp__linear-tactic__linear_updateDocument` — the pin stays stable across draft → finalized → amended.
- **Without `document_id`:** `mcp__linear-tactic__linear_createDocument` on the issue with `document.title` + `document.content`.
- **`finalized: true`** (the charter, after operator sign-off): append the marker block — `**FINALIZED** — <ISO date> — operator sign-off recorded` — and return the document id as the pin the gate requires. **This is an operator sign-off act — never fire `finalized: true` on your own initiative, only at explicit operator direction.**
- When the finalized document is a map's build charter, the same act applies the `ready-for-agent` label to the map's `build` children — finalization is what opens the build lane.
- Updating a finalized document removes its marker unless the update is operator-directed (amendments re-finalize, same pin).

### `archive_document`

`mcp__linear-tactic__linear_archiveDocument` with `document_id`; post a comment with the retained link — this is charter retirement at map close.

## What this playbook does NOT do

- Does NOT decide when to finalize — that's the operator's act; this playbook only executes it once directed.
- Does NOT gate on the marker it writes — reads and writes it, never interprets it; the gate lives with the caller (`` `@traffic-cone` ``).
