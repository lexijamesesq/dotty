# Playbook: freshness

Scan a Knowledge layer for stale pages (older than threshold) and orphans (listed in index but missing on disk, or on disk but absent from index).

## Input

- `index_path` — absolute path to `Knowledge/index.md` (or `index.md` for flat variants)
- `threshold_days` (default 90 — pages with frontmatter `updated` older than this are stale)
- `today` (ISO date — orchestrator passes for testability)

## Protocol

1. **Read the index.** Parse for listed pages (typical pattern: bulleted markdown links in sections under `## <Category>` headers).

2. **For each listed page, check existence on disk.** If missing, add to `orphans.missing_files` list (index references a file that doesn't exist).

3. **For each existing listed page, read frontmatter `updated`.** Compute days-since-updated vs. `today`. If past `threshold_days`, add to `stale`.

4. **Scan the knowledge folder for files NOT in the index.** Walk the directory; for each `.md` file with frontmatter `type/knowledge` or `type/spec` or `type/reference`, check if it's listed in the index. If not, add to `orphans.unindexed_files` (file exists, index doesn't know about it).

5. **Return both lists.**

## Output

```yaml
stale:
  - path: <abs-path>
    title: <from frontmatter or H1>
    updated: <YYYY-MM-DD>
    days_stale: <int>
orphans:
  missing_files:
    - path: <abs-path from index>
      cited_in_index_at: <line or section>
  unindexed_files:
    - path: <abs-path>
      type: knowledge | spec | reference
```

## Discipline

- **Lightweight by design.** Do not read full Knowledge page content; only frontmatter. The Reading posture (from System CLAUDE.md) handles full content at point-of-use during the session.
- **`updated` is the staleness signal.** Not file mtime (which gets touched by Obsidian re-saves), not git log (vault not git-tracked). Frontmatter `updated` is the operator's "this is current as of" stamp.
- **Threshold is per-project tunable.** Default 90d; if a project has rapid-iteration knowledge docs, the caller may pass a tighter threshold. Don't hardcode beyond the default.

## Hub-shared concerns

If the index is a sub-project's Knowledge index but the project is under a hub with shared `Knowledge/`, the orchestrator should ALSO run this playbook against the hub's index. This playbook itself only scans one index per invocation — the orchestrator chains.

## What this playbook does NOT do

- Does NOT classify what to do about stale items (caller decides: validate-and-bump, edit, delete).
- Does NOT read body content (lightweight read only).
- Does NOT modify anything (read-only).
