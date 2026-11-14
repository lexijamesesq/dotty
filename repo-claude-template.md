# Repo CLAUDE.md Template

The canonical shape for a repo's CLAUDE.md. It is the project's one instruction file: a session, engine, CI runner or cloud session that opens the repo reads this and nothing else first, so it must be complete on its own. It says what the repo is, how to build and test it, what the project is for, and where the project's work and documentation are.

The project's documentation is not in the repo. It lives in Notion and is reached from the `notion_project` pointer below; work is tracked in Linear.

## Template

The outer fence is four backticks so the `yaml` example inside it nests as
content instead of closing the block. Use the content between the two outer
fences for a new repository, filling placeholders from its actual contract.
Follow new-repo/README.md for the paired native setup.

````markdown
---
tags:
  - type/claude-repo
description: "{What this repo is and what it builds — one or two sentences.}"
linear_project_id: "{UUID of the project in Linear}"
linear_url: "{URL of the project in Linear}"
notion_project: "{URL of the project's page in Notion}"
notion_knowledge: "{data-source URL of the project's Knowledge database in Notion}"
---

# {Repo Name}

{One paragraph: what this repo is, what it builds/ships, who/what consumes it. A session, engine, or CI runner with zero other context should understand the repo's purpose from this paragraph alone.}

## Intent

### Objective

{The problem this project solves, in one or two sentences.}

### Health Metrics

{What must not get worse while pursuing the objective.}

### Decision Authority

{What a session may do on its own, and what needs the operator's yes.}

### Stop Rules

{When a session halts or asks.}

## Setup

{How to get from a fresh clone to a working local environment — install steps, dependencies, required tools. Copy any `*.sample.*`/`*.example.*` config files to their real names and fill in values (see Configuration below).}

## Configuration

{Config keys skills/code read at runtime, by key name — not hardcoded. Sensitive values referenced by path (1Password, env var), never inlined. Mirrors the `*.sample.*` files this repo ships for consumers.}

```yaml
# example
some.config.key: "value or op://vault/item/field reference"
```

## Build / Test

Read root `AGENTS.md` for the shared checkout-readiness, identity and testing contract.

{Exact commands to build and run the test suite locally. If there's more than one (lint, unit, integration), name each and what it checks.}

## CI

{What runs on every PR, what's required to merge, where the workflow/ruleset config lives. Point at `.github/workflows/` rather than duplicating the YAML — this section names the shape (checks, required-status gate), not the implementation.}

## Conventions

{Code style, commit message shape, branch naming, anything a contributor or an autonomous session would get wrong by guessing. Only what's genuinely non-obvious — skip anything a linter already enforces.}

## Workflow Cadence

{Recurring operational rhythms, if this repo has any — e.g. "run `/skill-name` monthly," a deploy cadence, a scheduled job. Omit entirely if the repo has none (most don't).}

## Key Files

{Only files a session can't discover from the filesystem — non-obvious paths, entry points, generated files that shouldn't be hand-edited.}

| File | Purpose |
| ---- | ------- |
````

## Frontmatter contract

| Property | Required | Read by |
| -------- | -------- | ------- |
| `tags: type/claude-repo` | **Yes** | Marks the file as a repo's instruction file. |
| `description` | **Yes** | Anyone, or anything, that opens the repo cold. |
| `linear_project_id`, `linear_url` | When the project is tracked in Linear | Skills that file or look up the project's work. |
| `notion_project`, `notion_knowledge` | When the project has documentation in Notion | The `project-docs` skill, and the global instruction that cues it. Leave both out until the pages exist: a repo without `notion_project` is not cued. |

A project with more than one repo repeats the same four values in each.

## Intent in a public repo

Everything in this file is published with the repo. In a public repo, keep Intent to what is fine for anyone to read. Rules that describe how the operator's own systems are run or secured belong on the project's Notion overview, which this file points to.

## What does NOT belong in a repo CLAUDE.md

- **State and narrative.** Where a piece of work stands, what is waiting, what was decided along the way: that is Linear's.
- **Project documentation.** What the project's parts are, what is built, design and its reasons: that is in Notion, reached from `notion_project`. Point to it; don't carry a copy.
- **File inventories or directory trees beyond genuinely non-obvious entries.** A session reads the filesystem; Key Files is for what it can't discover that way (a generated file, a config the docs don't otherwise surface).

## Line-earning test

Every line must pass: "Would removing this cause a session — cloud, CI, or local — to make a mistake it wouldn't otherwise make?" If a linter, the build tooling, or the project's documentation already covers it, cut the line.
