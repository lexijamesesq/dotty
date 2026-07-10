---
name: new-project
description: >
  Triggers when the user says "create a new project", "new project",
  "set up a project", "new hub", "/new-project", or similar
  project/hub creation requests.
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
> - **Project** = Active work with state tracking (Re-entry Cue, blockers, decisions; queue lives in Linear)
> - **Hub** = Organizes related subprojects, no state of its own

If Hub, skip Steps 3, 4, and 5 (those are project-only).

## Step 2: Gather Core Info

Ask the user for:

1. **Name** — Used for the folder name and `project/` tag. Folder uses Mac-style naming (spaces, capitalization). Tag uses kebab-case.
2. **Parent location** — Where in the vault hierarchy? Common locations:
   - `{workspace_root}/Personal/` (personal research)
   - `{workspace_root}/Professional/` (work projects)
   - Or a specific hub path (e.g., `{workspace_root}/Personal/Health/`)

   Where `{workspace_root}` is configured in global CLAUDE.md > Configuration > `workspace_root`.
3. **Description** — 1-3 sentences: "What This Project Is." This goes in both the CLAUDE.md body and the `description` frontmatter field.
4. **Linear team** — Which team should this project belong to? The skill is shipped with a two-team mental model (personal / work); your Configuration in CLAUDE.md defines the labels and UUIDs. Defaults documented for the original author: a personal/system team (`linear.team_lex_id`) and a work team (`linear.team_inst_id`). Replace with your own team labels and UUIDs in CLAUDE.md.

## Step 3: Create Linear Project (Projects Only)

Call `linear_createProject` with:
- `name`: the project name from Step 2
- `teamIds`: a single-element array containing the team UUID resolved from global CLAUDE.md > Configuration:
  - For the personal/system team: use `linear.team_lex_id`
  - For the work team: use `linear.team_inst_id`
  - These two keys are conventions inherited from the original author's setup; rename and reassign in your own CLAUDE.md if your team taxonomy differs. If neither key is present, ask the user to add it to their global CLAUDE.md before proceeding (consumers of this skill must set their own team UUIDs — these are not hardcoded for portability).
- `description`: the short description from Step 2
- `content`: optional expanded content if the user provided additional context

Capture the returned project URL and UUID. The URL will be placed in CLAUDE.md (Key Files table and Intake section) where the template has `URL` placeholders. The UUID will be placed as `**Project ID:** <uuid>` in the Intake `### Tasks` block, immediately after the `**Location:**` line.

## Step 4: Intake Setup (Projects Only)

Two independent questions about what the inbox router can deliver to this project. A project can have tasks, knowledge, both, or neither.

### 4a. Tasks

The Linear project created in Step 3 is already the task home. Confirm with the user:

> Should the Router be able to route tasks to this project?

If **yes:**
- Plan to include the `### Tasks` subsection under `## Intake` in the generated CLAUDE.md (method: linear, location: Linear project URL from Step 3)
- Create an empty `Context/` directory (rich context docs for complex items)

If **no:** Omit the Tasks subsection from `## Intake`. The project can add it later.

### 4b. Knowledge

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
  > Your CLAUDE.md needs a project-specific `## Knowledge Sources & Prioritization` section declaring the priority hierarchy (what sources to consult in what order) and a `### Reading posture` subsection (freshness window at point-of-use). This isn't templated because the hierarchy is project-specific. Reference an existing project's CLAUDE.md in your workspace as a working example, if one exists.

If **no:** Skip knowledge artifacts. The project can add them later by following the template's "Knowledge Folder (Optional)" section.

## Step 5: Intent Engineering (Projects Only)

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

## Step 6: Create Structure

Based on the gathered answers, read the appropriate template and create:

**For Projects:**
```
{parent}/{Project Name}/
  CLAUDE.md              ← From project template, filled with gathered info + Linear project URL
  Context/               ← If Tasks intake enabled (Step 4a)
  Knowledge/             ← If Knowledge intake enabled (Step 4b)
  Knowledge/index.md     ← If Knowledge intake enabled (Step 4b)
```

Do NOT create:
- `backlog.json` — task tracking is in Linear
- `backlog-archive.json` — this exists only for migrated projects (pre-cutoff)
- `progress.md` — session narrative is in Linear Project Updates
- `progress-archive.md` — this exists only for migrated projects (pre-cutoff)

**Also create a Wiki pointer stub for every Project** (see [[target-architecture-v2]] > Wiki > Project Pointer Stubs for the full convention):

Location: `Wiki/Optimized/project-{name-kebab}.md`

Shape:

```markdown
---
tags:
  - type/project-pointer
  - project/{name-kebab}
  - topic/{4-8 topic tags describing the project's scope}
updated: {today}
status: active
---
# Project: {Name}

{One-sentence description of what this project covers.}

**Project root:** `{parent}/{Project Name}/`
**Linear:** {Linear project URL}
**Knowledge:** `{parent}/{Project Name}/Knowledge/` — authoritative for {domain}
**CLAUDE.md:** `{parent}/{Project Name}/CLAUDE.md`

If you're researching {topic}-adjacent material from Wiki/, check `{parent}/{Project Name}/Knowledge/` first — this stub is a pointer, not a mirror.
```

Guidance:
- Pick 4-8 `topic/*` tags that describe the project's domain. These drive Wiki-query discoverability — without them the stub is dead weight.
- If Knowledge intake is NOT enabled (no Knowledge/ folder), replace the Knowledge line with a reference to wherever spec/reference material lives (e.g., `**Authoritative spec:** \`{path}/router-spec.md\``) and add a note: "No `Knowledge/` folder. Reference material at {paths}."
- The stub is a pointer, not a mirror. Don't duplicate CLAUDE.md content. ~10 lines total.

After creating the stub, update `Wiki/Optimized/index.md` — add a row to the **Project Pointers** table linking the new stub.

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
- Key Files table listing created artifacts, including the Linear project URL
- Intake section with `### Tasks` method set to `linear` and URL from Step 3

## Step 7: Report

Summarize what was created:
- List all files and directories
- Confirm frontmatter tags
- Confirm the Linear project was created and show the URL
- Note whether Tasks intake is enabled (Context/ created, Linear project linked)
- Note whether Knowledge intake is enabled (Knowledge/ + index.md + uncommented Knowledge block in CLAUDE.md). If so, remind the user to add the project-specific Knowledge Sources & Prioritization section to CLAUDE.md — point them at an existing project's CLAUDE.md as a reference, if one exists in their workspace.
- Note the Wiki pointer stub (`Wiki/Optimized/project-{name-kebab}.md`) and the topic tags applied. Flag if topic tags are weak — strong tags matter because they drive Wiki-query discoverability.
- Suggest: "Run `/session-start {Project Name}` when you're ready to begin working."

## Publishing Safety Setup (for projects with a GitHub repo)

When the project has its own git repo that pushes to GitHub, set up publishing safety after creating the vault structure. Copy config from dotty as the reference.

**GitHub server-side (one-time):**
- Enable push protection + secret scanning: `gh api repos/<owner>/<repo> --method PATCH --field 'security_and_analysis[secret_scanning][status]=enabled' --field 'security_and_analysis[secret_scanning_push_protection][status]=enabled'` (resolve `<owner>` from the repo's git remote)
- Create ruleset: `gh api repos/<owner>/<repo>/rulesets --method POST --input -` with `{"name":"Protect <branch>","target":"branch","enforcement":"active","conditions":{"ref_name":{"include":["refs/heads/<branch>"],"exclude":[]}},"rules":[{"type":"non_fast_forward"},{"type":"deletion"}]}`
- Set OAuth secret: `gh secret set CLAUDE_CODE_OAUTH_TOKEN --repo <owner>/<repo>` (paste from 1Password)

**Local config (copy from dotty, tune per repo):**
- `.gitleaks.toml` — operator patterns + repo-specific allowlist (LICENSE for copyright name; remove employer rules for work-project repos)
- `.pre-commit-config.yaml` — gitleaks (`language: system`), file-presence, check-yaml, check-json, end-of-file-fixer, trailing-whitespace
- `README.md` + `LICENSE`

**Activate:** `pre-commit install`

**Commit** the config files via the PR workflow (branch → PR → merge). See `rules/publishing-workflow.md` for the workflow.

Not all projects have GitHub repos. Hub-only or vault-only projects skip this section.

## Stop Rules

| Condition | Action |
|-----------|--------|
| User cancels at any step | Report what was gathered so far and stop. Do not create partial artifacts. |
| Linear project creation fails | Report the error and stop. Do not create vault structure until Linear project exists. |
| Parent location doesn't exist | Ask user to confirm creation or provide a different path. |
| Project name conflicts with existing folder | Warn and ask for a different name. Do not overwrite. |
| Template files not found | Report which templates are missing and stop. |
