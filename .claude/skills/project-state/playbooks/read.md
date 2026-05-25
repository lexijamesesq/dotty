# Playbook: read

Parse a project's `CLAUDE.md` and return structured Project State + Intake fields.

## Input

- `project_root` — absolute path to project folder, OR `"cwd"`, OR project name (resolved under `workspace_root`).

## Protocol

1. **Resolve** `project_root` per the navigator's cross-cutting "Project resolution" rule. Fail with clear error if no `CLAUDE.md` exists.

2. **Read** `<project_root>/CLAUDE.md`.

3. **Parse frontmatter** to determine type. Look for tag `type/claude-project` (return `type: project`) or `type/claude-hub` (return `type: hub`; hubs lack Project State, return minimal structure and let caller decide).

4. **Parse the Project State section.** Locate `## Project State`. Within it:
   - `**Last Updated:**` → `last_updated` (YYYY-MM-DD; capture optional parenthetical context)
   - `### Re-entry Cue` → `re_entry_cue` (capture the prose, expected one sentence)
   - `### Current State` → `current_state` (capture as free-form text; may be paragraph or bullet list)
   - `### Waiting For` → `waiting_for` (capture as list of items; null if section says "None" or is absent)
   - `### Decisions Needed` → `decisions_needed` (same as Waiting For)

5. **Parse the Intake section.** Locate `## Intake`. Within it:
   - `**Project ID:**` → `linear_project_id` (UUID). **Required** for non-hub projects; if absent, surface as a data error.
   - Linear project URL (in a `### Tasks` subsection or similar) → `linear_project_url` (optional)
   - `**Capture Note:**` reference (if present, in any subsection) → `capture_note_path`
   - `### Knowledge` declaration (presence) → `knowledge_layer_declared: true`
   - If `knowledge_layer_declared: true`, derive `knowledge_index_path` as `<project_root>/Knowledge/index.md` (or `<project_root>/index.md` for flat variants — check both, prefer the subfolder if both exist)

6. **Build the structured return.**

## Output

```yaml
type: project | hub
project_root: <abs-path>
last_updated: <YYYY-MM-DD or null>
re_entry_cue: <string or null>
current_state: <string, may be empty>
waiting_for: <list of strings or null>
decisions_needed: <list of strings or null>
linear_project_id: <UUID or null>
linear_project_url: <URL or null>
capture_note_path: <path or null>
knowledge_layer_declared: <bool>
knowledge_index_path: <path or null>
```

## Failure modes (surface to caller; do not paper over)

- **No CLAUDE.md at resolved path:** return null with error string `"No CLAUDE.md at <resolved-path>"`.
- **Missing Project State section:** return what parsed; mark missing fields explicitly; let caller decide whether to proceed (likely error for `/session-start`, recoverable for `/session-closeout` if it's about to write the section fresh).
- **Hub type:** return `type: hub` with empty Project State fields; caller almost always wants a sub-project's CLAUDE.md instead and will re-invoke.
- **Missing `**Project ID:**` for non-hub:** surface as data error. Pre-cutoff fallback to `linear_getProjects` name-match is RETIRED — do not attempt.

## Parser notes

- Use Obsidian MCP `get_frontmatter` for the frontmatter; `read_note` for the body parse.
- Section headers may have varied prefixes (`### Re-entry Cue` is canonical but tolerant parsing for case + emoji bypass shouldn't be added — flag template drift instead).
- `**Last Updated:**` may be on its own line or inline; either is fine.
- `**Capture Note:**` reference may be in `## Intake` or a subsection; scan the full Intake section.
