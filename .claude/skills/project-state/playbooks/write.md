# Playbook: write

Edit the **Re-entry Cue** and **frontmatter `updated`** field of a project's `CLAUDE.md`, preserving everything else.

## Input

```yaml
project_root: <abs-path>           # required
last_updated: <YYYY-MM-DD>         # required; today's date
re_entry_cue: <string or null>     # required; ONE sentence when work is mid-flight, null or "No work in progress" when clean
```

## Protocol

1. **Resolve** project root per navigator's cross-cutting rule. Fail clearly if CLAUDE.md missing.

2. **Read** `<project_root>/CLAUDE.md`.

3. **Validate Re-entry Cue** (when non-null and not "No work in progress") is ONE sentence — if it contains multiple sentences (multiple `. ` or `! ` or `? ` followed by capital), fail with `"Re-entry Cue must be one sentence; got N sentences"`. The caller composed the cue; this skill enforces the format.

4. **Update frontmatter `updated`** via `update_frontmatter`.

5. **Update Re-entry Cue body.** Locate `## Re-entry Cue` (or `### Re-entry Cue` for legacy files). Replace the content below the heading through the start of the next section. If the heading doesn't exist, create it after `# {Project Title}` and the template comment.

6. **Write the file back.**

## Output

```yaml
fields_updated: [updated, re_entry_cue]
warnings: [<warning strings if any>]
file_path: <abs-path to CLAUDE.md>
```

## Fields removed from prior version

These fields are no longer written to CLAUDE.md. They were session-level memory that now lives in Linear:
- `current_state` — written as Linear Project Update via `/session-closeout`
- `waiting_for` — tracked as Linear issue states
- `decisions_needed` — tracked as Linear issue states

## What this playbook does NOT do

- Does NOT write Current State, Waiting For, or Decisions Needed (retired from CLAUDE.md).
- Does NOT write to the Intake section (retired; routing fields are in frontmatter).
- Does NOT validate Linear Project ID (out of scope; that's `/linear` territory).

## Tool notes

- Use Obsidian MCP `update_frontmatter` for the `updated` field.
- Use Obsidian MCP `patch_note` for the Re-entry Cue body replacement.
- The harness's `vault-mcp-redirect` hook will route generic `Edit`/`Write` to MCP automatically; using MCP directly is faster and avoids the redirect.
