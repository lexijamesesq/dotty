# Playbook: documents

Attach and archive documents on Linear issues — create/update-in-place, and archive-with-retained-link. Mechanical actions only.

## Input

```yaml
issue_id: <TEAM>-N                                                   # required
document: { title: <string>, content: <markdown> }                   # for attach_document, create path
document_id: <id>                                                    # for attach_document (update-in-place, pin stays stable) or archive_document
```

## Protocol

### `attach_document`

- **With `document_id`:** `mcp__linear-tactic__linear_updateDocument` — the pin stays stable across create → amended.
- **Without `document_id`:** `mcp__linear-tactic__linear_createDocument` on the issue with `document.title` + `document.content`, returning the new document id as the stable pin.

Map documents (the `Decisions — <map name>` index, the accounting document) attach this way. The operator-confirmed Destination + Done When on the map body is the settled spec, and its children are takeable by the plain frontier rule.

### `archive_document`

`mcp__linear-tactic__linear_archiveDocument` with `document_id`; post a comment with the retained link — used to retire a map-scoped or superseded document while keeping it reachable.

## What this playbook does NOT do

- Does NOT decide when to archive or supersede a document — that's the caller's act (a map close, an operator-directed retirement); this playbook only executes it once directed.
- Does NOT gate on anything it writes — reads and writes documents, never interprets them; gating lives with the caller (`` `@traffic-cone` ``).
