# Repo CLAUDE.md Template

The canonical shape for **repo working-guide** CLAUDE.md files — every git repo outside the vault (operator rule: a git repo and an Obsidian folder are never the same directory) carries one of these at its root. Must be complete **on its own**: engines, CI runners, and cloud sessions see only the repo, never the vault. The paired vault knowledge-home template is `System/project-claude-template.md`.

Synthesized from the common shape already present across Metrics, Incubator, Wiki, and home-assistant-tools' own `CLAUDE.sample.md` files (Project Overview, Configuration keys, Workflow Cadence) — not from dotty's own `CLAUDE.sample.md`, which is a profile-setup sample for a different purpose. Vault-project concerns those four samples also carried (Intent, Project State, Intake, Knowledge Sources & Prioritization) do NOT belong here — those stay in the paired vault knowledge-home CLAUDE.md; a repo session that needs them follows `docs_home`.

## Template

```markdown
---
tags:
  - type/claude-repo
description: "{What this repo is and what it builds — one or two sentences.}"
docs_home: "{Absolute path to the paired vault knowledge-home folder — omit only if this repo genuinely has no vault knowledge home.}"
---

# {Repo Name}

{One paragraph: what this repo is, what it builds/ships, who/what consumes it. A session, engine, or CI runner with zero other context should understand the repo's purpose from this paragraph alone.}

## Setup

{How to get from a fresh clone to a working local environment — install steps, dependencies, required tools. Copy any `*.sample.*`/`*.example.*` config files to their real names and fill in values (see Configuration below).}

## Configuration

{Config keys skills/code read at runtime, by key name — not hardcoded. Sensitive values referenced by path (1Password, env var), never inlined. Mirrors the `*.sample.*` files this repo ships for consumers.}

```yaml
# example
some.config.key: "value or op://vault/item/field reference"
```

## Build / Test

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
|------|---------|
```

## Frontmatter contract

| Property | Required | Parsed by |
|----------|----------|-----------|
| `tags: type/claude-repo` | **Yes** | Marks this as a repo working-guide file, distinct from `type/claude-project` (vault knowledge-home) — lets tooling tell the two apart without checking `docs_home`/`build_home` presence. |
| `description` | **Yes** | Session orientation for anyone (or anything) that opens the repo cold. |
| `docs_home` | Only when a vault knowledge home exists | Absolute path back to the paired vault project folder. Singular — a repo has exactly one docs home. The vault project's own CLAUDE.md carries the reverse pointer as `build_home` (a list, since a project can have more than one repo). Omit only for a repo with no vault-side knowledge home at all (rare — most repos exist because a vault project needed one). |

## What does NOT belong in a repo CLAUDE.md

- **Intent (Objective / Health Metrics / Decision Authority / Stop Rules).** That's the vault knowledge-home's job — it's about what the *project* is for, not how the *repo* builds. A repo session that needs it follows `docs_home`.
- **Project State, Re-entry Cue, Waiting For, Decisions Needed.** Session-level narrative lives in Linear (via the vault knowledge-home), not here — a repo has no session-narrative surface of its own.
- **Intake sections.** Task/narrative/knowledge routing is a vault-project concept; a repo doesn't route captures.
- **Knowledge Sources & Prioritization.** Discoverable from the vault knowledge home's `Knowledge/index.md` via `docs_home` — a repo session that needs deep domain knowledge follows the pointer rather than carrying a copy here.
- **File inventories or directory trees beyond genuinely non-obvious entries.** A session reads the filesystem; Key Files is for what it can't discover that way (a generated file, a config the docs don't otherwise surface).

## Line-earning test

Every line must pass: "Would removing this cause a session — cloud, CI, or local, with no vault access — to make a mistake it wouldn't otherwise make?" If a linter, the build tooling, or the docs_home vault project already covers it, cut the line.
