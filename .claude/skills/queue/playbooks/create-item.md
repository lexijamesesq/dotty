# Playbook: create-item

Write one operator-judgment item into `Wiki/Queue/` as a distinct file.

## Input

- `queue_kind` — one of `triage | explore | promote | disposition | conflict | proposal`
- `source` — what produced the item (a skill name, lane name, or session descriptor; e.g. `scope-lint`, `capture-lane`, `session-closeout`)
- `reasons` — array of short strings: why this needs operator judgment rather than autonomous handling
- `scope_tags` — one or more `project/<name>` or `area/<hierarchy>` tags locating the item's domain (load-bearing: the statusline scoped count and triage's scope resolution read these)
- `payload` — the candidate/question the operator will adjudicate
- `evidence` — supporting material (file paths, quotes, search results) sufficient to decide without re-derivation
- `today` — ISO date (caller passes for testability)

## Protocol

1. **Resolve the queue directory.** Vault root via the `workspace_root` config key (global CLAUDE.md > Configuration); queue dir = `{workspace_root}/Wiki/Queue/`. If the directory does not exist, halt and surface — do not create it silently (Stop rule).

2. **Compose the filename:** `{YYYY-MM-DD}-{queue-kind}-{slug}.md`
   - Date = `today`.
   - Slug = 3–6 lowercase hyphenated words naming the payload topic (not the source lane). Example: `2026-07-06-disposition-stale-updated-frontmatter.md`.
   - On collision (file already exists), append `-2`, `-3`, … Never overwrite an existing item.

3. **Compose frontmatter** — exactly this shape, keys in canonical unquoted form (`status: pending` literally — the SessionStart hook greps this string; do not quote or restyle it):

   ```yaml
   ---
   queue-kind: <queue_kind>
   source: <source>
   reasons:
     - <reason 1>
     - <reason 2>
   created: 'YYYY-MM-DD'
   status: pending
   tags:
     - <project/* or area/* scope tag(s)>
   ---
   ```

   `created` is quoted (YAML date-vs-string safety); `status` and `queue-kind` are not.

4. **Compose the body:** a single `# <Title>` H1 naming the judgment, then the payload, then an `## Evidence` section. The test: could the operator adjudicate this at a triage 3 weeks from now, with zero session context, from this file alone? If not, the body is too thin.

5. **Write via `mcp__obsidian__write_note`** (create mode). Vault `.md` files are MCP-only — never generic Write.

6. **Verify:** read back the frontmatter (`mcp__obsidian__get_frontmatter`) and confirm `status: pending` and `queue-kind` are present. On write or verification failure, report **FAIL** to the caller with the attempted path and error — never silently drop (a dropped judgment is invisible forever; the design treats queue-write failure as a loud, run-failing event).

## Output

- Success: the created file's vault-relative path + one-line confirmation.
- Failure: `FAIL` + attempted path + error. Nothing else.

## Discipline

- **One item per file, one judgment per item.** Two unrelated findings are two files. Related findings on the same subject (e.g. several lint findings on one page) batch into ONE item — the operator adjudicates subjects, not line numbers.
- **No structural-contract envelope, no filing-validator.** Queue items are transient judgment artifacts outside the Location Gate. Do not add `type/knowledge`, `status/active`, `updated`, or `sources` — the schema above is complete.
- **Scope tags are the routing signal.** Derive them from the payload's domain. An item with no plausible scope tag still gets filed (it surfaces in Wiki scope and triage-all) — note the absence in `reasons`.

## What this playbook does NOT do

- Does NOT decide whether something belongs in the queue — the caller makes that call per its own decision authority; this playbook files what it is handed.
- Does NOT notify the operator — the statusline count is the surfacing mechanism.
