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

- `status: active` (or on-hold, completed, archived)
- "What This Project Is" section (1-3 sentences)
- Project State section (Re-entry Cue, Current State, Waiting For, Decisions Needed)

**Template:** `PATH_TO_YOUR_PROJECT_TEMPLATE`

### Hub CLAUDE.md

**Required:**

- Description of what the hub organizes
- Projects table linking to subproject CLAUDE.md files

**Template:** `PATH_TO_YOUR_HUB_TEMPLATE`

## Claude-Maintained Personal Files

Files outside your project folders that Claude may update on your behalf. Declare each so Claude knows the boundary and update cadence:

| File | Pattern | Boundary | Frequency |
| --- | --- | --- | --- |
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
- **Files** (Markdown, `.json`, images, PDFs, scripts, YAML, binaries): `Read` / `Edit` / `Write` / `Grep` / `Glob`.
- **Knowledge discovery:** When a question references topics, documents, or decisions already tracked, search your knowledge store before creating new content.

## Shared Infrastructure

See `rules/shared-infrastructure.md` for details (auto-loaded).

## Configuration

Paths referenced by shared skills and rules. Skills reference these by config key rather than hardcoding paths.

```yaml
# IANA timezone for skill date math
user_timezone: "TODO: e.g., America/Phoenix, Europe/London, UTC"

# Linear team UUIDs — used by /new-project to assign new projects to a team.
# Get these from Linear: Settings → Teams → <Team> → Identifier (or via API).
# Add only the teams you actually use (these examples assume two teams: personal and work).
linear.team_lex_id: "TODO: paste your personal/system team UUID here"
linear.team_inst_id: "TODO: paste your work team UUID here"

# Machine-fixed path to the private name roster the leak rules are generated from
references.tag_taxonomy_rosters: "~/.config/estate/tag-taxonomy-rosters.md"
```

## Knowledge References

When a session's work touches these topics, read the referenced doc before proceeding:

| Topic | Reference |
| --- | --- |
| TODO: Add topic | `path/to/your/reference-doc.md` |

Max 10 entries. When adding, evaluate existing entries for promotion or removal.
