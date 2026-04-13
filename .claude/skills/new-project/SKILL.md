---
name: new-project
description: >
  Triggers when the user says "create a new project", "new project",
  "set up a project", "new hub", "/new-project", or similar
  project/hub creation requests.
user_invokable: true
---

# New Project Setup

Interactive protocol for creating a new Claude-managed project or hub. Walk through each step with the user, gathering answers before creating anything.

## Templates

Read the appropriate template before generating any files:

- **Project:** path configured in global CLAUDE.md > Configuration > `templates.project`
- **Hub:** path configured in global CLAUDE.md > Configuration > `templates.hub`
- **Intake defaults:** path configured in global CLAUDE.md > Configuration > `references.intake_defaults`

These templates define the current required structure. Read them at runtime to pick up any changes — do not rely on memorized structure.

## Step 1: Determine Type

Ask the user:

> Is this a **Project** or a **Hub**?
> - **Project** = Active work with state tracking (Next Actions, blockers, decisions)
> - **Hub** = Organizes related subprojects, no state of its own

If Hub, skip Steps 3 and 4 (intake and intent engineering are project-only).

## Step 2: Gather Core Info

Ask the user for:

1. **Name** — Used for the folder name and `project/` tag. Folder uses Mac-style naming (spaces, capitalization). Tag uses kebab-case.
2. **Parent location** — Where in the vault hierarchy? Common locations:
   - `{workspace_root}/Personal/` (personal research)
   - `{workspace_root}/Professional/` (work projects)
   - Or a specific hub path (e.g., `{workspace_root}/Personal/Health/`)

   Where `{workspace_root}` is configured in global CLAUDE.md > Configuration > `workspace_root`.
3. **Description** — 1-3 sentences: "What This Project Is." This goes in both the CLAUDE.md body and the `description` frontmatter field.

## Step 3: Intake Setup (Projects Only)

Two independent questions about what the inbox router can deliver to this project. A project can have tasks, knowledge, both, or neither.

### 3a. Tasks

Ask the user:

> Should Inbox Processing be able to route tasks to this project?

If **yes:**
- Plan to include the `### Tasks` subsection under `## Intake` in the generated CLAUDE.md (method: backlog-json, location: backlog.json)
- Create `backlog.json` with the minimal schema from `intake-defaults.md`:
  ```json
  {
    "project": "{project-name-kebab}",
    "last_updated": "{today}",
    "notes": "Agents may modify: status, subtasks, context_doc. All other fields are human-set.",
    "items": []
  }
  ```
- Create `backlog-archive.json`:
  ```json
  {
    "project": "{project-name-kebab}",
    "last_archived": null,
    "items": []
  }
  ```
- Create an empty `Context/` directory

If **no:** Skip task intake artifacts. The project can add them later by following the template.

### 3b. Knowledge

Ask the user:

> Will this project accumulate durable reference material across sessions — architectural explanations, research spikes, procedures, posture assessments? (See the "Knowledge Folder (Optional)" section in the project template for when to adopt.)

If **yes:**
- Create a `Knowledge/` directory
- Create `Knowledge/index.md` with empty-state content:
  ```markdown
  ---
  tags:
    - type/knowledge
    - project/{project-name-kebab}
  updated: {today}
  ---
  # {Project Name} Knowledge

  Current inventory of `Knowledge/`. Updated on every create/delete/rename.

  _No pages yet._
  ```
- Uncomment the `### Knowledge` subsection inside the `## Intake` block in the generated CLAUDE.md (the template ships it as an HTML comment block).
- After the project is created, tell the user:
  > Your CLAUDE.md needs a project-specific `## Knowledge Sources & Prioritization` section declaring the priority hierarchy (what sources to consult in what order) and a `### Reading posture` subsection (freshness window at point-of-use). This isn't templated because the hierarchy is project-specific. See `Claude/Personal/Home Assistant/CLAUDE.md` for a working example.

If **no:** Skip knowledge artifacts. The project can add them later by following the template's "Knowledge Folder (Optional)" section.

## Step 4: Intent Engineering (Projects Only)

Ask the user:

> Does this project involve autonomous agent workflows or sustained multi-session development?

If **yes**, gather:
- **Objective** — What problem does this solve? (1-2 sentences, framed as a problem statement)
- **Desired Outcomes** — 2-4 observable state changes from the user's perspective
- **Health Metrics** — What must NOT degrade while pursuing outcomes?
- **Strategic Context** — What broader system or workflow does this project operate within? (Skip if standalone.)
- **Decision Authority** — What can agents do autonomously vs. what requires human confirmation?
- **Stop Rules** — When should agents halt or escalate?

Include these as active sections in the CLAUDE.md.

Reference for the user if they want background: path configured in global CLAUDE.md > Configuration > `references.three_disciplines`

If **no:** Leave the intent engineering sections as HTML comments in the CLAUDE.md (they exist in the template for future activation).

## Step 5: Create Structure

Based on the gathered answers, read the appropriate template and create:

**For Projects:**
```
{parent}/{Project Name}/
  CLAUDE.md              ← From project template, filled with gathered info
  progress.md            ← Always created (session-closeout appends here)
  backlog.json           ← If Tasks intake enabled (Step 3a)
  backlog-archive.json   ← If Tasks intake enabled (Step 3a)
  Context/               ← If Tasks intake enabled (Step 3a)
  Knowledge/             ← If Knowledge intake enabled (Step 3b)
  Knowledge/index.md     ← If Knowledge intake enabled (Step 3b)
```

Initialize `progress.md` with a header and frontmatter only:
```markdown
---
tags:
  - type/log
  - project/{name-kebab}
---
# {Project Name} Progress Log

Append-only. Each session adds an entry via `/session-closeout`.
```

**For Hubs:**
```
{parent}/{Hub Name}/
  CLAUDE.md              ← From hub template, filled with gathered info
```

**CLAUDE.md requirements:**
- Frontmatter must include:
  - `type/claude-project` or `type/claude-hub` tag
  - `project/{name-kebab}` tag
  - `status: active`
  - `description:` field (the 1-3 sentence description)
- Project State section initialized with "Not yet started" re-entry cue
- Key Files table listing created artifacts

## Step 6: Report

Summarize what was created:
- List all files and directories
- Confirm frontmatter tags
- Note whether Tasks intake is enabled (backlog.json + Context/)
- Note whether Knowledge intake is enabled (Knowledge/ + index.md + uncommented Knowledge block in CLAUDE.md). If so, remind the user to add the project-specific Knowledge Sources & Prioritization section to CLAUDE.md — point them at HA as the reference.
- Suggest: "Run `/session-start {Project Name}` when you're ready to begin working."

## Stop Rules

| Condition | Action |
|-----------|--------|
| User cancels at any step | Report what was gathered so far and stop. Do not create partial artifacts. |
| Parent location doesn't exist | Ask user to confirm creation or provide a different path. |
| Project name conflicts with existing folder | Warn and ask for a different name. Do not overwrite. |
| Template files not found | Report which templates are missing and stop. |
