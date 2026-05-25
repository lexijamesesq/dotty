# Playbook: index-sync

After Knowledge pages have been created, renamed, or deleted, reconcile the corresponding `Knowledge/index.md` (or root `index.md` for flat variants) so the index reflects current state.

## Input

- `knowledge_folder_path` — absolute path to the Knowledge folder (or project root for flat variants)
- `changes` (optional) — list of recent mutations to drive incremental sync:
  ```yaml
  changes:
    - action: created | renamed | deleted
      path: <abs-path>
      old_path: <abs-path>     # for renames
      title: <string>          # from frontmatter or H1
      summary: <one-line>      # if known
  ```
  If `changes` not provided, full-reconcile mode (slower but exhaustive).

## Protocol

### Mode 1: Incremental sync (when `changes` provided)

For each change:

1. **Created:** Add a new entry to the index in the appropriate section. The entry shape (per existing index conventions):
   - For project-hosted Knowledge: typically `- [Title](filename.md) — one-line summary`
   - For System/ Knowledge: same shape with section grouping (root-level vs. Knowledge/ subfolder)
   - Use the file's frontmatter or first paragraph for the summary if not provided.

2. **Renamed:** Update the link target + title (if changed). Preserve the entry's position in the index.

3. **Deleted:** Remove the entry. Note: if other docs cite this page via wikilinks `[[...]]`, those are now dangling — surface as a warning so the orchestrator can flag.

### Mode 2: Full reconcile (when `changes` not provided)

1. **Walk the Knowledge folder.** Build a set of `.md` files with `type/knowledge` / `type/spec` / `type/reference` frontmatter.
2. **Read the index.** Build a set of listed paths.
3. **Diff:**
   - Files on disk not in index → ADD entries.
   - Entries in index not on disk → REMOVE entries.
4. Apply all diffs in a single write.

## Output

```yaml
index_path: <abs-path>
changes_applied:
  - action: added | updated | removed
    entry: <one-line>
    section: <index section header where the entry landed>
warnings:
  - <string>    # e.g. "Deleted entry was cited via [[wikilink]] in <other-doc>"
```

## Discipline

- **Section grouping matters.** If the index has explicit sections (e.g., "## Knowledge/" and "## Reference/"), add new entries to the correct section based on the file's `type/*` tag and location. Don't dump everything in one list.
- **Summary discipline.** One-line summaries; concrete (what this doc holds, not "describes X"). Pull from the file's first paragraph if the frontmatter doesn't have a `description`.
- **Preserve existing entries.** When adding new entries, do NOT rewrite the entire index — patch in place. Use Obsidian MCP `patch_note` for surgical updates.
- **Wikilink integrity.** Deleted pages may leave dangling `[[old-name]]` references elsewhere. This playbook surfaces the warning; resolving the dangling reference is the orchestrator's call (typically: update the citing doc or file as a follow-up Linear issue).

## Hub-shared index considerations

If the project is under a hub with shared Knowledge AND this session's filing was to the hub-level Knowledge (not project-local), invoke this playbook with the HUB's index path, not the project's. The caller resolves which index is the target.

## What this playbook does NOT do

- Does NOT update any documents OTHER than the index itself.
- Does NOT validate file content (the structural envelope is `query-and-file`'s job).
- Does NOT detect orphans on its own (that's `freshness.md`'s job).
- Does NOT cross-reference between project-local and hub-level indexes (that's `hub-cross-ref.md`).
