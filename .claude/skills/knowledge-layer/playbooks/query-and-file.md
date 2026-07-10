# Playbook: query-and-file

File durable session synthesis as a Knowledge page satisfying the full knowledge-contract Part II envelope. Invokes the `filing-validator` Task-tool agent as the structural gate. After filing, returns the path so the caller can chain `index-sync.md`.

## Input

```yaml
draft_content: <markdown>           # the synthesis body (without H1 or frontmatter)
title: <string>                     # for the H1 and frontmatter
destination_class: project-hosted | Wiki-hosted
scope: <project name OR area hierarchy>   # for the scope tag
host_project_root: <abs-path>       # required for project-hosted (determines Knowledge/ path)
sources: [<provenance string>, ...] # required; see Provenance vocabulary
topic: [<topic>, ...]               # required for Wiki-hosted (≥1); optional for project-hosted
suggested_filename: <slug>          # optional; derive from title if not provided
```

## Protocol

1. **Validate inputs:**
   - `destination_class` ∈ {`project-hosted`, `Wiki-hosted`}.
   - `sources` non-empty (provenance required for `type/knowledge`).
   - If `Wiki-hosted`: `topic` non-empty.
   - If `project-hosted`: `host_project_root` exists + has `Knowledge/` subfolder OR is willing to create one.

2. **Resolve destination path:**
   - Project-hosted: `<host_project_root>/Knowledge/<filename>.md`
   - Wiki-hosted: `{workspace_root}/Wiki/Knowledge/<filename>.md` (relative to vault root)
   - `<filename>` from `suggested_filename` or slugified `title` (kebab-case, lowercase, dashes for spaces, strip punctuation).

3. **Compose the page:**

```yaml
---
tags:
  - type/knowledge
  - <scope tag — project/<name> OR area/<hierarchy>>
  - status/active
  - <topic/<topic> ... if Wiki-hosted or provided for project-hosted>
updated: <today YYYY-MM-DD>
sources:
  - <provenance string 1>
  - <provenance string 2>
---

# {{title}}

{{draft_content}}
```

**Provenance vocabulary** for `sources`:
- `AI research YYYY-MM-DD` — session-derived synthesis (this case is typical for query-and-file).
- `user-stated` — user-provided facts during the session.
- `external: <citation>` — references to external sources cited in body.

4. **Write the file** via Obsidian MCP `write_note`.

5. **Invoke `filing-validator` Task-tool agent.** Per `[[knowledge-contract]] Part III` §4 session-closeout query-and-file:
   - Pass: target file path, handoff `§4 session capture (closeout query-and-file)`, destination class.
   - Wait for verdict.
   - If `RESULT: FAIL` with HIGH violations:
     - Read findings; fix each HIGH violation in the file; re-invoke `filing-validator`.
     - Iteration cap 3. If still failing after 3 iterations, surface to caller with full finding list — do NOT mark complete.
   - If `RESULT: PASS` (zero HIGH violations): proceed. WARNING/INFO items are surfaced to caller as advisory but don't block.

6. **Return** the filed page path + filing-validator verdict.

## Output

```yaml
filed:
  path: <abs-path>
  destination_class: project-hosted | Wiki-hosted
  filing_validator_verdict: PASS | FAIL
  filing_validator_iterations: <int>
  warnings: [<string>, ...]    # WARNING/INFO from filing-validator
  ready_for_index_sync: <bool>  # true only if filing_validator PASS
```

## Discipline

- **Single coherent pass.** Knowledge docs represent current understanding. The draft content should not include "this session's work" framing — that bleeds anti-pattern #4 (progress-log).
- **Do NOT include a `## Original Capture` body section.** [[knowledge-contract]] Part II D1 supersedes any prior mandate; provenance lives in frontmatter `sources`.
- **Index sync is a separate step.** This playbook returns `ready_for_index_sync: true` on PASS; the caller chains `index-sync.md` to update the Knowledge/index.md.

## Failure modes

- **filing-validator returns FAIL after 3 iterations:** surface ALL findings to caller; do not mark complete. The page is on disk but not counted as a successful filing.
- **filing-validator unavailable:** surface to caller; do not proceed without the gate.
- **Destination path already exists:** check for content mismatch. If the existing page is older and the new content is a substantive update, that's a normal update path — but query-and-file is for NEW pages; updating existing pages should be a direct edit, not a new filing. Surface this to caller as `"path collision — was this meant to be an update? See <existing-path>"`.

## What this playbook does NOT do

- Does NOT update Knowledge/index.md — that's `index-sync.md`.
- Does NOT compose the draft content — caller composes; this playbook files what's handed in.
- Does NOT decide whether the synthesis is worth filing — caller (typically session-closeout's "Did this session produce durable synthesis?" check) decides.
- Does NOT update existing pages — use direct edit + bump `updated` for in-place revisions.
