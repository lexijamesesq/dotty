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
4. **Linear team** — All projects use the team UUID configured in global CLAUDE.md > Configuration > `linear.team_lex_id`.

## Step 3: Create Linear Project (Projects Only)

Call `linear_createProject` with:
- `name`: the project name from Step 2
- `teamIds`: a single-element array containing the team UUID resolved from global CLAUDE.md > Configuration > `linear.team_lex_id`.
- `description`: the short description from Step 2
- `content`: optional expanded content if the user provided additional context

Capture the returned project URL and UUID. Both will be placed in the CLAUDE.md frontmatter as `linear_url` and `linear_project_id`.

## Step 4: Routing Setup (Projects Only)

Linear project ID and URL are already in frontmatter from Step 3 — tasks are routable by default. Create an empty `Context/` directory for rich context docs.

### 4a. Knowledge

Ask the user:

> Will this project accumulate durable reference material across sessions — architectural explanations, research spikes, procedures, posture assessments? (See the "Knowledge Folder (Optional)" section in the project template for when to adopt.)

If **yes:**
- Create a `Knowledge/` directory
- Scaffold the **orientation hierarchy** from the project template's "Orientation hierarchy" section (`templates.project`) — read the three skeletons there at runtime and create each, filling the blanks with the project's name, `project/{name-kebab}` tag, and `{today}`:
  - `overview.md` — at the **project root**: the 30,000ft page (what the project is, how work moves, an empty area map + the "what counts as an area" guide, house rules carrying the three-hop navigation contract and the `integration-modes.md` pointer).
  - `Knowledge/index.md` — the knowledge inventory: entry-point pointer to the root `[[overview]]`, then the three document classes (current truth / frozen reference / append-only) inventorying `Knowledge/` contents — methodology, records, reference. Root orientation files are mapped by the overview's area map, not this inventory.
  - `area-template.md` — at the **project root**: the live blank area skeleton, carrying `integration: current-truth`, marked as a template (not an area). Sessions duplicate it to `area-<slug>.md` at the project root as domains emerge.
- Do **not** fabricate areas. A new project does not know its areas yet — the area map starts empty; areas are added when a domain has accumulated its own state.
- Set `knowledge_intake: true` in the CLAUDE.md frontmatter.

If **no:** Set `knowledge_intake: false` in frontmatter. The project can enable it later by setting `knowledge_intake: true` and scaffolding the orientation hierarchy (overview + index + area-template) per the template — or run the "Upgrade an existing project" checklist below.

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
  CLAUDE.md                    ← From project template, filled with gathered info + Linear project URL
  overview.md                  ← If Knowledge intake enabled — 30,000ft page + area map + house rules (project root)
  area-template.md             ← If Knowledge intake enabled — blank area skeleton, integration: current-truth (project root)
  Context/                     ← If Tasks intake enabled
  Knowledge/                   ← If Knowledge intake enabled (Step 4a)
  Knowledge/index.md           ← If Knowledge intake enabled — knowledge inventory + three document classes
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

**CLAUDE.md requirements (per the canonical template):**
- Frontmatter: `type/claude-project` or `type/claude-hub` tag, `project/{name-kebab}` tag, `status: active`, `description`, `updated`, `linear_project_id`, `linear_url`, `knowledge_intake`
- Template reference comment: `<!-- Template: {workspace_root}/System/project-claude-template.md -->`
- Re-entry Cue section (initialized as "No work in progress" or absent)
- Key Files table (only non-discoverable files)
- Deliverable Repos (if applicable)
- Intent sections from Step 5 (if applicable)

## Step 7: Report

Summarize what was created:
- List all files and directories
- Confirm frontmatter tags
- Confirm the Linear project was created and show the URL
- Note whether Knowledge intake is enabled (`knowledge_intake: true` in frontmatter). If so, confirm the orientation hierarchy scaffolded: `overview.md` at the project root (three-hop navigation contract + area guide), `area-template.md` at the project root (`integration: current-truth`), and `Knowledge/index.md` (knowledge inventory, three document classes, entry-point pointer to the root overview). Confirm the area map starts empty — no fabricated areas.
- Note the Wiki pointer stub (`Wiki/Optimized/project-{name-kebab}.md`) and the topic tags applied. Flag if topic tags are weak — strong tags matter because they drive Wiki-query discoverability.
- Suggest: "Run `/session-start {Project Name}` when you're ready to begin working."

## Upgrade an existing project to the orientation hierarchy

`/new-project` builds the orientation hierarchy into every NEW project. Existing projects are **not** migrated automatically. This checklist ships the *capability* to upgrade one; it is run per-project, under operator direction, as its own slice with its own review — **do not** run it as a side effect of anything else.

Scope guards:
- **The System project stays grandfathered.** Its flat-root + `Knowledge/` layout is deliberate — do not apply this to it.
- Applying this to a real project (sorting its live Knowledge docs) is a judgment task per project, not a mechanical sweep. Run it when the operator asks, one project at a time.

Steps:

1. **Write `overview.md` at the project root** from the template skeleton — the durable "what this project is," how work moves, an empty (or illustrative) area map, and the house rules (three-hop navigation contract + `integration-modes.md` pointer).
2. **Name the areas.** Identify the coherent slices that already have their own state — a session can work each without loading the others. Do not force a slice that isn't there yet.
3. **Sort current-state material into `area-<slug>.md` at the project root.** Current-state material folds into the area doc for its slice; frozen-reference and append-only records keep their own class (they are not areas) and stay in `Knowledge/`. Duplicate the root `area-template.md` per area; delete the template only once at least one real area exists, or keep it as the seed.
4. **Stamp integration modes.** Area docs and the overview carry `integration: current-truth`; a `## State` section only where it is directional — where the area is headed, what is durably true (task status and logs stay in Linear). Append-only records stay append-only.
5. **Rebuild `Knowledge/index.md`.** Entry-point pointer to the root `[[overview]]`, then the three document classes inventorying `Knowledge/` contents — methodology, records, reference. Root orientation files are mapped by the overview's area map, not this inventory. Wire the area map in `overview.md` to the real areas.
6. **Verify:** three hops resolve (overview → each area → its artifacts), no orphaned Knowledge docs, `integration: current-truth` on area docs, index in sync. Run `/lint-knowledge` on the project scope — the root orientation files plus `Knowledge/`.

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
