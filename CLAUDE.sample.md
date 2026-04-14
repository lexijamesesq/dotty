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
- **Vault files Obsidian parses** (`.md`, `.markdown`, `.txt`, `.base`, `.canvas`) — match operation to Obsidian MCP tool:
  - Read: `read_note` / `read_multiple_notes` (batch ≤10) / `search_notes` (content + frontmatter)
  - Discover: `list_directory` / `get_notes_info` (metadata only) / `get_vault_stats`
  - Frontmatter: `get_frontmatter` / `update_frontmatter`
  - Tags: `list_all_tags` (vault-wide) / `manage_tags` (per note)
  - Mutate: `write_note` (create / overwrite / append) / `patch_note` (targeted replace) / `delete_note`
  - Move / rename: Obsidian CLI via Bash (wikilink-safe; requires Obsidian open)
- **Everything else in the vault** (`.json`, images, PDFs, scripts, YAML, binaries): generic tools. Obsidian doesn't parse these.
- **Outside the vault:** generic tools (`Read` / `Edit` / `Write` / `Grep` / `Glob`).
- **Vault discovery:** When a question references topics, documents, or decisions previously tracked in the vault, search with `mcp__obsidian__search_notes` before creating new content.

## Shared Infrastructure

See `rules/shared-infrastructure.md` for details (auto-loaded).

## Configuration

Paths referenced by shared skills and rules. Skills reference these by config key rather than hardcoding paths.

```yaml
# Base path for all project folders (skills resolve project names under this root)
workspace_root: "~/path/to/your/workspace"

# Templates (paths relative to workspace_root)
templates.project: "path/to/your/project-template.md"
templates.hub: "path/to/your/hub-template.md"

# Reference documents (paths relative to workspace_root)
references.protocols: "path/to/your/protocols-reference.md"
references.intake_defaults: "path/to/your/intake-defaults.md"
references.search_methodology: "path/to/your/search-methodology.md"
references.three_disciplines: "path/to/your/agentic-workflows.md"
references.iterative_development: "path/to/your/iterative-development.md"
```

## Knowledge References

When a session's work touches these topics, read the referenced doc before proceeding:

| Topic | Reference |
|-------|-----------|
| TODO: Add topic | `path/to/your/reference-doc.md` |

Max 10 entries. When adding, evaluate existing entries for promotion or removal.
