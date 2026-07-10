---
name: github-readme
description: >
  Triggers when the user says "generate readme for [path]", "write a readme",
  "/github-readme [path]", or similar README generation requests for Claude Code
  infrastructure artifacts.
argument-hint: [path]
context: fork
allowed-tools:
  - Bash
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

- **Project:** Read `house-style.md` in this skill's directory — the canonical spine, verbatim strings, and register. Glob `claude/skills/`, `claude/agents/`. Read `CLAUDE.sample.md` if it exists. Build an inventory. Then read one of the exemplar READMEs `house-style.md` names, in full, if it is reachable — imitate its structure, do not merely measure it. They are frequently unreachable; when they are, `house-style.md` alone is sufficient. Never guess at their contents.
- **Skill:** Read `SKILL.md` — name, description, invocation, what it does, tools, agent references.
- **Agent:** Read the agent `.md` — name, description, what it evaluates, scope.
- **Rule:** Read the rule `.md` — what behavior it enforces.

## Step 2: Choose mode

If no README exists, this is an **initial write** — generate the full spine.

If one exists, read it and compare its `##` headings against the spine.

| State | Mode | Action |
|-------|------|--------|
| Headings match the spine | incremental | Rebuild the tables and fenced invocations inside the generated sections |
| Any heading is off-spine | reshape | Report each divergence, then stop. Reshaping is the operator's call, never a silent rewrite. |

Which sections are generated and which are authored: `house-style.md` § Regeneration boundary.

Granularity is the table and the fenced block, never the whole section — a paragraph the operator wrote under `## Usage` is authored prose and survives. Preservation is by copy, not by marker: read the existing text and write it back unchanged.

A **generated** section the spine requires, which current artifact state justifies but the file lacks — `What's Included`, `Usage`, `Configuration` — is created. A heading is structure, not authored prose.

A **preserved** section is never edited, even to satisfy a fixed string. Where one falls short — an `Installation` missing its sample-copy line, a `Security` audit clause that omits an executable surface the repo ships — report the gap and let the operator fix it.

## Step 3: Generate

**Voice.** Technical documentation. Direct, no marketing. Address the reader as *you*; never write in first person.

**Never include** the artifact's own production — its validation state, test coverage, maturity, or the name of this skill. `house-style.md` § Systematic omissions is the full list.

**Length.** Target the median in `house-style.md` § Length. Cut before adding.

### Templates by type

**Project:** follow `house-style.md` — its spine, its shared patterns, its fixed strings, its table schemas, and its rules earned from real failures. Do not paraphrase the fixed strings.

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

Where a skill ships its own README, `Usage` links to it rather than restating its arguments. For agent files, prefer a single `agents/README.md` covering all agents if multiple exist.

## Step 4: Write

Write to `{target}/README.md` (project/skill) or `{parent-dir}/README.md` (agent/rule). Report the path, the line count, which sections were regenerated versus preserved, and — separately — every fixed-string gap found inside a preserved section.

## Stop rules

| Condition | Action |
|-----------|--------|
| Path does not exist | "Path not found: {path}" — exit |
| No recognized artifact files | "No Claude Code artifacts found" — exit |
| `house-style.md` unreadable on a project target | Abort. A silently skipped style source is worse than no run. |
| Existing README has off-spine headings | Report each divergence, name the reshape it would take, exit without writing |
| Write fails | Report error with generated content so it's not lost |
