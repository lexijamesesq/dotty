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

## Project Creation Protocol

When creating a new folder for project work, determine if it's a **Project** or **Hub**:

**Project** = Active work with state tracking (Re-entry Cue, blockers, decisions; queue lives in your task system)
**Hub** = Organizes related subprojects, no state of its own

### Project CLAUDE.md

**Required:**
- `type/claude-project` tag (or your taxonomy equivalent)
- `project/{{project-name}}` tag
- `status: active` (or on-hold, completed, archived)
- "What This Project Is" section (1-3 sentences)
- Project State section (Re-entry Cue, Current State, Waiting For, Decisions Needed)

**Template:** `PATH_TO_YOUR_PROJECT_TEMPLATE`

### Hub CLAUDE.md

**Required:**
- `type/claude-hub` tag
- `project/{{hub-name}}` tag
- Description of what the hub organizes
- Projects table linking to subproject CLAUDE.md files

**Template:** `PATH_TO_YOUR_HUB_TEMPLATE`

## Claude-Maintained Personal Files

Files outside your project folders that Claude may update on your behalf. Declare each so Claude knows the boundary and update cadence:

| File | Pattern | Boundary | Frequency |
|------|---------|----------|-----------|
| `path/to/your/file.md` | Section/Full/Frontmatter/Snapshot | Section heading or property | Cadence |

**Patterns:**
- **Section:** Find heading, replace content until next `##`, preserve everything else
- **Full:** Regenerate entire file (used for summaries/status notes)
- **Frontmatter:** Update only a specific property
- **Snapshot:** Time-stamped immutable files (e.g., `workload-2026-W05.json`)

**Rules:**
- Verify structure exists before writing
- Read back after write to confirm
- Document update rules in the relevant project's CLAUDE.md

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
# Base path for Claude system files (templates, references, intake-defaults)
workspace_root: "~/path/to/your/workspace"

# Operational projects space (peer to workspace_root). Each project has its own backlog.json.
projects_root: "~/path/to/your/projects"

# IANA timezone for skill date math
user_timezone: "TODO: e.g., America/Phoenix, Europe/London, UTC"

# Linear team UUIDs — used by /new-project to assign new projects to a team.
# Get these from Linear: Settings → Teams → <Team> → Identifier (or via API).
# Add only the teams you actually use (these examples assume two teams: personal and work).
linear.team_lex_id: "TODO: paste your personal/system team UUID here"
linear.team_inst_id: "TODO: paste your work team UUID here"

# Templates (paths relative to workspace_root)
templates.project: "path/to/your/project-template.md"
templates.hub: "path/to/your/hub-template.md"

# Reference documents (paths relative to workspace_root)
references.protocols: "path/to/your/protocols-reference.md"
references.intake_defaults: "path/to/your/intake-defaults.md"
references.search_methodology: "path/to/your/search-methodology.md"
references.three_disciplines: "path/to/your/agentic-workflows.md"
references.iterative_development: "path/to/your/iterative-development.md"
references.tag_taxonomy: "path/to/your/Wiki/spec/tag-taxonomy.md"
references.structural_contract: "path/to/your/Wiki/spec/structural-contract.md"
references.handoff_contracts: "path/to/your/Wiki/spec/handoff-contracts.md"
references.lint_surface: "path/to/your/Wiki/spec/lint-surface.md"
```

## Knowledge References

When a session's work touches these topics, read the referenced doc before proceeding:

| Topic | Reference |
|-------|-----------|
| TODO: Add topic | `path/to/your/reference-doc.md` |

Max 10 entries. When adding, evaluate existing entries for promotion or removal.
