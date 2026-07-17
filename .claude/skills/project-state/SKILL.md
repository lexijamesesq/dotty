---
name: project-state
description: "CLAUDE.md orientation expert — read and write the Re-entry Cue + frontmatter routing fields (linear_project_id, knowledge_intake, description, status). Invoked by /session-start, /session-closeout, and /new-project. Triggers on \"/project-state read\", \"/project-state write\", or programmatic invocation."
---

# /project-state

Domain expert for the CLAUDE.md orientation layer. Reads frontmatter (routing contract: Linear IDs, knowledge intake, description, status) and the Re-entry Cue (the one-sentence heads-up for session resumption). Writes the Re-entry Cue and the `updated` timestamp — nothing else.

Session-level memory (current state, waiting-for, decisions needed) lives in Linear, not in CLAUDE.md. This skill does not read or write those fields.

## Identity

This skill owns the structured orientation that lives in a project's `CLAUDE.md` — the thinnest layer of the three-layer memory model (`CLAUDE.md` = orientation, Linear issues = item-level, Linear Project Updates = session-level).

Discipline rules:

- **Re-entry Cue is ONE sentence, only when work is mid-flight.** If the last session closed cleanly, the cue is "No work in progress" or absent. Not a recap; a heads-up.
- **Three-layer separation:** item-level decisions go on the issue; session-level narrative goes in Project Updates; orientation + re-entry goes here. Nothing else.
- **Routing fields live in frontmatter.** `linear_project_id`, `linear_url`, `knowledge_intake`, `description`, `status`, `updated` — all parsed from frontmatter, never from body text.

## Intent

**Objective.** Parse and write the CLAUDE.md orientation layer so consumers (session-start, session-closeout, new-project) get structured fields without re-implementing parsing. Enforce Re-entry Cue format.

**Health Metrics:**
- Re-entry Cue one-sentence invariant (validated pre-write; fail on violation)
- Frontmatter fields parsed cleanly — missing required fields surfaced as data errors, never silently null

**Decision Authority:**
- **Autonomous:** all read parsing; Re-entry Cue validation; frontmatter `updated` writes
- **Escalate:** CLAUDE.md missing → return null with error; hub type → return minimal structure; missing `linear_project_id` → data error; missing `description` → warning

**Stop Rules:**
- CLAUDE.md not found → fail with clear error
- Re-entry Cue multi-sentence on write → fail; caller collapses before re-invoking
- Hub when caller expected project → return type:hub; caller decides

## Navigation

| Operation | Input | Output | Playbook |
|---|---|---|---|
| **read** | `project_root` (abs path) OR `"cwd"` OR project name | Structured: `type`, `description`, `status`, `last_updated`, `re_entry_cue`, `linear_project_id`, `linear_project_url`, `knowledge_layer_declared`, `knowledge_index_path` | `playbooks/read.md` |
| **write** | `project_root` + `last_updated` + `re_entry_cue` | Mutation: frontmatter `updated` + Re-entry Cue body; `fields_updated` list returned | `playbooks/write.md` |

## Cross-cutting

**Project resolution.** When input is `"cwd"`, walk up from cwd until finding a `CLAUDE.md` whose frontmatter tags contain `type/claude-project` or `type/claude-hub`. When input is a project name, append to `workspace_root` (global CLAUDE.md > Configuration). When input is an absolute path, use directly. Fail if no `CLAUDE.md` exists.

**Hub vs. project.** Frontmatter tag `type/claude-hub` → return `type: hub` with minimal structure; caller decides whether to recurse.

**Frontmatter is the routing contract.** `linear_project_id` missing in a non-hub is a data error. `description` missing is a warning (project is invisible to routing). `knowledge_intake` absent defaults to false.

## What this skill does NOT do

- Does NOT write to Linear (that's `/linear`)
- Does NOT scan Knowledge layer (that's `/knowledge-layer`)
- Does NOT compose the Re-entry Cue's content — the caller writes it; this skill enforces format
- Does NOT read or write Current State, Waiting For, or Decisions Needed — those live in Linear
- Does NOT manage Intake sections — routing fields are in frontmatter; `/new-project` creates the initial frontmatter

## References

- Project template: path configured in global CLAUDE.md > Configuration > `templates.project`
- `[[linear-discipline]]` — three-layer memory model
