---
name: lint-knowledge
description: >
  Scan a project's Knowledge layer for structural issues: orphans, stale frontmatter,
  missing tags, index drift, and contradictions. Reports findings without auto-fixing.
  Triggers on "/lint-knowledge", "lint knowledge", "check knowledge health", or
  "scan knowledge for issues".
user_invokable: true
---

# Lint Knowledge

On-demand health check for a project's Knowledge layer. Reports findings — does not auto-fix.

## Instructions

### Step 1: Identify the Target

Determine which project to lint from the user's message or the current working context.

Find the project's Knowledge layer:
- Check CLAUDE.md `## Intake` for a `### Knowledge` subsection → read the declared `Location`
- Or detect a `Knowledge/` folder in the project root
- Or detect the project root IS the Knowledge layer (flat variation — check for an `index.md` at root alongside operational files like `backlog.json`)

If no Knowledge layer is found, report that and stop.

### Step 2: Inventory Check

Read the Knowledge `index.md`. Then list the actual files in the Knowledge location (via `list_directory`).

**Check for orphans in both directions:**
- Pages listed in `index.md` but missing from disk → **Missing page** (index references a deleted or moved file)
- Pages on disk in the Knowledge location but absent from `index.md` → **Unlisted page** (was created or moved without updating the index)

Report each orphan with its path and direction (missing vs unlisted).

### Step 3: Frontmatter Check

For each Knowledge page on disk, read its frontmatter (via `get_frontmatter`):

- **Missing `updated` field** → flag with the page path
- **Missing `tags` field** → flag
- **Missing `type/knowledge` tag** (or project-appropriate variant like `type/spec`, `type/reference`) → flag
- **Missing `project/<name>` tag** → flag (the project tag should match the project's `project/` tag from its CLAUDE.md frontmatter)

### Step 4: Freshness Check

For each page with an `updated` field, compare against the project's freshness threshold (default 90 days from today).

- **Stale pages** (older than threshold) → list with their `updated` date and how many days past threshold

This overlaps with the session-start freshness scan but provides a complete view rather than the lightweight scan session-start does.

### Step 5: Contradiction Scan

Compare Knowledge page content against the project's CLAUDE.md for obvious contradictions:

- Knowledge page claims something the CLAUDE.md's Current State or Key Findings contradicts
- Knowledge page references entities, paths, or configurations that no longer exist in the project
- Two Knowledge pages assert different facts about the same subject

This is best-effort — read pages and flag what's obviously wrong. Don't try to resolve contradictions, just report them.

### Step 6: Hub Cross-Reference (if applicable)

If the project is a subproject under a hub with shared `Knowledge/`:

- Read the hub's `Knowledge/index.md`
- For each hub Knowledge page, check whether the subproject's current state or findings have made it stale or incomplete
- Report hub pages that appear to need updating based on subproject state

If the target IS a hub: for each subproject listed in the hub's Projects table, check whether the subproject's CLAUDE.md contains findings that the hub Knowledge doesn't reflect.

### Step 7: Report

Present findings organized by category:

```
## Knowledge Lint — [Project Name]

### Orphans
- [Missing/Unlisted pages]

### Frontmatter Issues
- [Pages with missing fields]

### Stale Pages
- [Pages past freshness threshold with dates]

### Contradictions
- [Obvious conflicts between pages or with CLAUDE.md]

### Hub Cross-Reference
- [Hub pages needing update, or N/A if not a hub/subproject]

### Summary
- Total pages: X
- Clean: X
- Issues found: X
```

If no issues are found, report a clean bill of health.

## Notes

- This skill reads but does not modify files. All fixes are manual follow-up.
- For automated maintenance at session boundaries, see `/session-start` (freshness scan) and `/session-closeout` (query-and-file, staleness flagging, index sync).
- For the broader architecture: see `Claude/System/knowledge-compilation-architecture.md`.
