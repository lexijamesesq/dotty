---
name: github-readme
description: >
  Triggers when the user says "generate readme for [path]", "write a readme",
  "/github-readme [path]", or similar README generation requests for Claude Code
  infrastructure artifacts.
argument-hint: [path]
user_invokable: true
context: fork
allowed-tools:
  - Read
  - Glob
  - Grep
  - Write
---

# /github-readme — README Generation

Generate a README.md for a Claude Code project or artifact based on its actual content and type.

## Invocation

```
/github-readme [path]
```

- Optional argument: path to the artifact or project
- Default: current working directory
- Accepts: project directory, skill directory, agent file, rule file
- Examples: `/github-readme`, `/github-readme ~/Vaults/Notes/Claude/Professional/Incubator/`, `/github-readme claude/skills/develop/`

## Arguments

Parse `$ARGUMENTS` to resolve the target path.

**Resolution rules:**

| Input | Behavior |
|-------|----------|
| Empty | Use current working directory |
| Absolute path | Use as-is |
| Relative path | Resolve relative to current working directory |

**Artifact type detection:** Same rules as `/github-prep` — detect by `claude/skills/` or `claude/agents/` presence (project), SKILL.md presence (skill), agents/ directory (agent), rules/ directory (rule).

If the path doesn't exist, report "Path not found: {path}" and exit.

## Execution Flow

### Step 1: Read Artifact

Read the full content of the artifact to understand what it does:

- **Project:** Glob for all artifacts in `claude/skills/`, `claude/agents/`. Read reference docs at the project root. Read CLAUDE.sample.md if it exists (for configuration documentation). Build an inventory.
- **Skill:** Read `SKILL.md` — extract name, description, invocation, arguments, what it does, what tools it uses, and any agent references
- **Agent:** Read the agent `.md` — extract name, description, persona, what it evaluates/checks, scope constraints
- **Rule:** Read the rule `.md` — extract what behavioral instructions it enforces

### Step 2: Determine Audience

The audience depends on artifact type:

- **Skill:** Someone who wants to install and use the skill in their Claude Code setup
- **Agent:** Someone who wants to understand what the agent evaluates or wants to customize its persona
- **Rule:** Someone who wants to understand what behavior the rule enforces
- **Project:** Someone browsing the repository who wants to understand what's available and how to set it up

### Step 3: Generate README

Write README content using the appropriate template below. Focus on what someone needs to know to *use* the artifact, not implementation details.

**Voice:** Technical documentation. Clear, direct, no marketing language. Use second person ("you") for instructions.

#### Skill README Template

```markdown
# {Skill Name}

{One paragraph: what this skill does and when you'd use it.}

## Usage

/{skill-name} {arguments}

{Argument description — what each argument means, defaults, examples.}

## What It Does

{Numbered list of high-level steps — what the skill does, not how it's implemented.}

## Requirements

{List any dependencies: agents it references, tools it needs, files it expects to exist.}

## Customization

{How to adapt this skill for a different setup — what to change, what assumptions are baked in.}
```

#### Agent README Template

```markdown
# {Agent Name}

{One paragraph: what this agent evaluates/checks and its role in the workflow.}

## Used By

{Which skill(s) invoke this agent via `context: fork` + `agent:`.}

## Evaluation Framework

{Summary of what the agent checks — categories, taxonomy, or criteria.}

## Scope

{What the agent does and does NOT do — its boundaries.}

## Customization

{How to modify the persona, criteria, or scope for different use cases.}
```

#### Rule README Template

```markdown
# {Rule Name}

{One paragraph: what behavior this rule enforces.}

## When It Loads

{Always-on (auto-loaded) or conditional.}

## What It Enforces

{Summary of the behavioral instructions.}

## Customization

{What to change to adapt it to different workflows.}
```

#### Project README Template

The lede paragraph goes before any heading — what this is and who it's for.

```markdown
{One paragraph: what this system does and who it's for. No heading — this is the first thing readers see.}

## Installation

Clone the repo, then set up the Claude Code directory:

mv claude .claude

Copy the sample config and fill in your paths:

cp CLAUDE.sample.md CLAUDE.md

{List the required and optional configuration fields from CLAUDE.sample.md.}

## What's Included

{Table: artifact name | type | one-line description of what it does when invoked. Organize by grouping (core pipeline, enrichment agents, etc.). Description says what it does, not what it is.}

## Configuration

{The CLAUDE.md contract: what the consumer configures vs. what skills handle. Reference CLAUDE.sample.md fields. Note which are required vs optional.}

## Usage

{Invocation pattern per skill with one example each. Don't repeat full argument docs — link to per-skill README if one exists.}

## Security

Review skills before installing. They load into Claude's context and execute with your permissions. Audit the contents of `claude/skills/` and `claude/agents/` before use.

## License

{Reference LICENSE file.}
```

### Step 4: Check for Existing README

Before writing, check if a `README.md` already exists at the target path.

- If it exists: note the existing file's line count and report to the user that it will be overwritten. Include a brief note in your output: "Overwrote existing README.md ({N} lines)."
- If it does not exist: proceed to write.

For agent files (single .md in agents/), write README.md as a sibling in the agents/ directory only if evaluating the agent in isolation. If multiple agents exist, prefer a single agents/README.md that covers all of them.

### Step 5: Write README.md

Write the generated README to the artifact's directory:

- **Project:** `{project-root}/README.md`
- **Skill:** `{skill-directory}/README.md`
- **Agent:** `{agents-directory}/README.md` (covers all agents if multiple exist)
- **Rule:** `{rules-directory}/README.md` (covers all rules if multiple exist)

Report the path and line count of the written file.

## Stop Rules

| Condition | Action |
|-----------|--------|
| No path and no working directory | Report usage and exit |
| Path does not exist | Report "Path not found" and exit |
| No recognized artifact files at path | Report "No Claude Code artifacts found" and exit |

## Error Handling

| Condition | Behavior |
|-----------|----------|
| Artifact has no description or name in frontmatter | Infer purpose from the body content |
| Agent referenced by skill doesn't exist at expected path | Note in Requirements section |
| Write fails | Report error with the generated content so it's not lost |
