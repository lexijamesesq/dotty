# Playbook: read

Parse a project's `CLAUDE.md` and return structured Project State + routing fields.

## Input

- `project_root` — absolute path to project folder, OR `"cwd"`, OR project name (resolved under `workspace_root`).

## Protocol

1. **Resolve** `project_root` per the navigator's cross-cutting "Project resolution" rule. Fail with clear error if no `CLAUDE.md` exists.

2. **Read** `<project_root>/CLAUDE.md`.

3. **Parse frontmatter** (via `get_frontmatter`):
   - `type/claude-project` tag → `type: project`; `type/claude-hub` tag → `type: hub` (hubs lack Project State; return minimal structure)
   - `description` → `description`
   - `status` → `status`
   - `updated` → `last_updated`
   - `linear_project_id` → `linear_project_id` (UUID). **Required** for non-hub projects; if absent, surface as data error.
   - `linear_url` → `linear_project_url`
   - `knowledge_intake` → `knowledge_layer_declared` (boolean; absent = false)
   - If `knowledge_layer_declared: true`, derive `knowledge_index_path` as `<project_root>/Knowledge/index.md` (or `<project_root>/index.md` for flat variants — check both, prefer the subfolder if both exist)
   - `build_home` → `build_homes` (list of absolute paths to this project's repo(s) outside the vault; absent = empty list). Replaces the retired `## Deliverable Repos` body section — see `System/project-claude-template.md`.

4. **Parse the body** for session-relevant fields:
   - `## Re-entry Cue` → `re_entry_cue` (the prose below the heading; may be absent or say "No work in progress" — both mean null)

5. **Build the structured return.**

## Output

```yaml
type: project | hub
project_root: <abs-path>
description: <string or null>
status: <string or null>
last_updated: <YYYY-MM-DD or null>
re_entry_cue: <string or null>
linear_project_id: <UUID or null>
linear_project_url: <URL or null>
knowledge_layer_declared: <bool>
knowledge_index_path: <path or null>
build_homes: <list of abs-paths, possibly empty>
```

## Fields removed from prior version

These fields are no longer parsed from CLAUDE.md. They were session-level memory that now lives in Linear:
- `current_state` — read from Linear Project Updates via `/session-start`
- `waiting_for` — read from Linear issue states via `/session-start`
- `decisions_needed` — read from Linear issue states via `/session-start`
- `capture_note_path` — retired

## Failure modes (surface to caller; do not paper over)

- **No CLAUDE.md at resolved path:** return null with error string `"No CLAUDE.md at <resolved-path>"`.
- **Hub type:** return `type: hub` with empty fields; caller almost always wants a sub-project's CLAUDE.md and will re-invoke.
- **Missing `linear_project_id` in frontmatter for non-hub:** surface as data error. Pre-cutoff fallback to `linear_getProjects` name-match is RETIRED.
- **Missing `description` in frontmatter:** surface as warning — the project is invisible to routing until a description is added.

## Parser notes

- Use Obsidian MCP `get_frontmatter` for all structured fields. `read_note` only for the Re-entry Cue body parse.
- The Re-entry Cue heading may be `## Re-entry Cue` or `### Re-entry Cue` (template uses `##`; legacy files may use `###`). Accept either.
