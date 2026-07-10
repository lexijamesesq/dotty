# Playbook: query-and-file

File durable session synthesis as a Knowledge page satisfying the full knowledge-contract Part II envelope. Runs `lint.py --filing` as the structural gate. After filing, returns the path so the caller can chain `index-sync.md`.

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

**Provenance vocabulary** for `sources` — knowledge-contract Part II (Provenance): a URL, `user-stated`, `inbox-capture`, `pre-contract`, `AI research YYYY-MM-DD`, or `routine/<action> <run-id>`. Session-derived filing typically uses `AI research YYYY-MM-DD` (synthesis) or `user-stated` (user-provided facts); cite an external reference as its URL directly — not a bespoke `external:` prefix, which is not a valid shape and will fail the filing-time lint gate's `invalid-sources-value` check.

4. **Write the file** via Obsidian MCP `write_note`.

5. **Run the filing-time lint gate.** Per `[[knowledge-contract]] Part III` §4 session-closeout query-and-file:
   - Run `python3 ~/bin/dotty/.claude/skills/lint-knowledge/lint.py --filing --no-manifest --json --vault-root <vault-root> <target-path>`.
   - Parse the JSON `findings`.
   - If any HIGH findings:
     - Read findings; fix each HIGH finding in the file; re-run the gate.
     - Iteration cap 3. If still failing after 3 iterations, surface to caller with full finding list — do NOT mark complete.
   - If zero HIGH findings: PASS — proceed. WARNING/INFO items are surfaced to caller as advisory but don't block.
   - A `missing-index-entry` MEDIUM on a project-hosted new file is expected (index sync is the post-file step) and does not affect PASS; ignore it.

6. **Return** the filed page path + the lint gate verdict.

## Output

```yaml
filed:
  path: <abs-path>
  destination_class: project-hosted | Wiki-hosted
  lint_gate_verdict: PASS | FAIL
  lint_gate_iterations: <int>
  warnings: [<string>, ...]    # WARNING/INFO from the lint gate
  ready_for_index_sync: <bool>  # true only if lint_gate_verdict PASS
```

## Discipline

- **Single coherent pass.** Knowledge docs represent current understanding. The draft content should not include "this session's work" framing — that bleeds anti-pattern #4 (progress-log).
- **Do NOT include a `## Original Capture` body section.** [[knowledge-contract]] Part II D1 supersedes any prior mandate; provenance lives in frontmatter `sources`.
- **Index sync is a separate step.** This playbook returns `ready_for_index_sync: true` on PASS; the caller chains `index-sync.md` to update the Knowledge/index.md.

## Failure modes

- **The lint gate returns FAIL after 3 iterations:** surface ALL findings to caller; do not mark complete. The page is on disk but not counted as a successful filing.
- **lint.py unavailable (script missing or errors):** surface to caller; do not proceed without the gate.
- **Destination path already exists:** check for content mismatch. If the existing page is older and the new content is a substantive update, that's a normal update path — but query-and-file is for NEW pages; updating existing pages should be a direct edit, not a new filing. Surface this to caller as `"path collision — was this meant to be an update? See <existing-path>"`.

## What this playbook does NOT do

- Does NOT update Knowledge/index.md — that's `index-sync.md`.
- Does NOT compose the draft content — caller composes; this playbook files what's handed in.
- Does NOT decide whether the synthesis is worth filing — caller (typically session-closeout's "Did this session produce durable synthesis?" check) decides.
- Does NOT update existing pages — use direct edit + bump `updated` for in-place revisions.
