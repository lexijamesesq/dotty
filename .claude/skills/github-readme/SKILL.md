---
name: github-readme
description: >
  Triggers when the user says "generate readme for [path]", "write a readme",
  "/github-readme [path]", or similar README generation requests for Claude Code
  infrastructure artifacts.
argument-hint: [path]
context: fork
allowed-tools:
  - Read
  - Glob
  - Grep
  - Write
---

# /github-readme — README Generation

Generate a README.md for a Claude Code project or artifact based on its actual content and type.

## Step 0: Resolve target

```bash
INPUT="${ARGUMENTS:-$PWD}"
RESOLVED="${INPUT/#\~/$HOME}"
case "$RESOLVED" in /*) ;; *) RESOLVED="$PWD/$RESOLVED" ;; esac
RESOLVED="$(realpath "$RESOLVED" 2>/dev/null || echo "$RESOLVED")"
[ -e "$RESOLVED" ] || { echo "Path not found: $INPUT (resolved to $RESOLVED)" >&2; exit 1; }
echo "$RESOLVED"
```

Run this first; its output is "the target path" for all subsequent steps.

## Step 1: Detect type and read content

| Signal | Type |
|--------|------|
| `claude/skills/` or `claude/agents/` present | project |
| `SKILL.md` in target directory | skill |
| `.md` file in an `agents/` directory | agent |
| `.md` file in a `rules/` directory | rule |

Read the artifact content to understand what it does:
- **Project:** Glob `claude/skills/`, `claude/agents/`. Read CLAUDE.sample.md if it exists. Build an inventory. Read at least one sibling project's README — match its line count and section distribution.
- **Skill:** Read `SKILL.md` — name, description, invocation, what it does, tools, agent references.
- **Agent:** Read the agent `.md` — name, description, what it evaluates, scope.
- **Rule:** Read the rule `.md` — what behavior it enforces.

## Step 2: Generate or update

**Voice:** Technical documentation. Direct, no marketing. Never include validation state, test coverage, maturity, ticket IDs, absolute local paths, or the name of this skill.

**Length:** Match the sibling README's word count if one was read; otherwise default to under 150 lines. Cut before adding.

**If README exists:** Read it. Preserve human-written sections (lede paragraph, Customization, Security, License, anything user-added). Regenerate structured sections (What's Included, Configuration, Usage) from current artifact state. Identify sections by heading text — no markers needed.

**If README is new:** Generate using the template for the detected type.

### Templates by type

**Skill:**
- Lede paragraph (what + when to use)
- `## Usage` — invocation with arguments, defaults, examples
- `## What It Does` — numbered high-level steps
- `## Requirements` — dependencies: agents, tools, expected files
- `## Customization` — how to adapt for a different setup

**Agent:**
- Lede paragraph (what it evaluates, its workflow role)
- `## Used By` — which skills invoke it
- `## Evaluation Framework` — what it checks
- `## Scope` — boundaries (does / does not)
- `## Customization` — how to modify criteria

**Rule:**
- Lede paragraph (what behavior it enforces)
- `## When It Loads` — always-on or conditional
- `## What It Enforces` — behavioral instructions
- `## Customization` — what to change

**Project:** (lede before any heading)
- Lede paragraph (what this is, who it's for — no heading)
- `## Installation` — clone, `mv claude .claude`, `cp CLAUDE.sample.md CLAUDE.md`, config fields
- `## What's Included` — table: artifact name | type | one-line description
- `## Configuration` — CLAUDE.md contract: what to configure vs what skills handle
- `## Usage` — invocation per skill, one example each
- `## Security` — "Review skills before installing. They load into Claude's context and execute with your permissions."
- `## License` — reference LICENSE file

For agent files, prefer a single `agents/README.md` covering all agents if multiple exist.

## Step 3: Write

Write to `{target}/README.md` (project/skill) or `{parent-dir}/README.md` (agent/rule). Report path and line count.

## Stop rules

| Condition | Action |
|-----------|--------|
| Path does not exist | "Path not found: {path}" — exit |
| No recognized artifact files | "No Claude Code artifacts found" — exit |
| Write fails | Report error with generated content so it's not lost |
