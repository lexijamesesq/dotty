# Playbook: handler-delegation

Step 0 — before intent classification, check whether the content matches a registered specialized handler. Handlers are overrides.

## Input

```yaml
content: <string>   # the raw capture, before any classification
```

## Protocol

1. Check the content against each registered handler's detection signals (table below). If one matches, delegate to it and **skip classification and routing entirely** (Steps 1-3 / the other playbooks).
2. If none match, fall through to `playbooks/classify.md`.

**Current handlers:**

| Handler | Detection signals | Delegation |
|---|---|---|
| `/capture-meeting` | **Explicit:** content includes a meeting name matching a key in `Wiki/Data/meeting-registry.json`. **Structural:** document contains `## Agenda for {date}` or `## **Agenda for {date}**` headings AND entries prefixed with Moved/Learned/Need. **Heuristic:** multiple dated sections with team/product area subsections — flag for confirmation before delegating. | Invoke `/capture-meeting` with the matched meeting name and full content. The handler owns parsing, coherence filtering, and filing. |

## Output

```yaml
delegated: <bool>
handler: <name | null>
```

## Discipline

**Self-sourcing handlers.** Some handlers can fetch their own content from external sources (e.g., `/capture-meeting` auto-fetches from Drive when the registry entry includes `drive_file_id`). When this is the case, users may invoke the handler directly without going through wiki-intake — the handler handles transport itself. wiki-intake remains the entry point for pasted, router-delivered, or unrecognized content; self-sourced invocation is a parallel path, not a replacement. Delivered content always wins over self-sourcing when both are available. See `{workspace_root}/System/routing-architecture.md` for the invocation paths.

## What this playbook does NOT do

- Does NOT classify intent — that's `playbooks/classify.md`, reached only when no handler matches.
- Does NOT maintain the handler registry itself — adding a new handler is a skill-authoring change to this table.
