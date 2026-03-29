# CLAUDE.sample.md — Configuration Template

This file shows the structure consumers should use for their own `CLAUDE.md`. Copy to `~/.claude/CLAUDE.md` (or your profile's CLAUDE.md) and customize.

---

## User Identity

- **Name:** YOUR_NAME
- **Preferred name:** YOUR_PREFERRED_NAME

## Session Protocols

Use `/session-start` when beginning project work. Use `/session-closeout` when closing a session.

**Project State template:** `PATH_TO_YOUR_PROJECT_TEMPLATE`
**Extended reference:** `PATH_TO_YOUR_PROTOCOLS_REFERENCE`

## Tool Selection Rules

- **Web research:** WebFetch/WebSearch first. Chrome MCP only for interactive elements.
- **Vault files:** Obsidian MCP for frontmatter updates, search, batch reads. Direct Read/Edit for precise line edits.
- **Vault discovery:** When a question references topics, documents, or decisions previously tracked in the vault, search with `mcp__obsidian__search_notes` before creating new content.

## Shared Infrastructure

See `rules/shared-infrastructure.md` for details (auto-loaded).

## Knowledge References

When a session's work touches these topics, read the referenced doc before proceeding:

| Topic | Reference |
|-------|-----------|
| TODO: Add topic | `path/to/your/reference-doc.md` |

Max 10 entries. When adding, evaluate existing entries for promotion or removal.
