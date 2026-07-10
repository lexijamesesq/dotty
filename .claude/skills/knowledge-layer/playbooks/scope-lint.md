# Playbook: scope-lint

Run the mechanical knowledge-integrity lint over the session's touched scope at closeout. Stateless, ~$0 (pure Python, no model in the lint pass). Envelope HIGHs on session-created files get fixed inline; everything else routes to the operator-judgment queue as disposition items.

## Input

- `scope_paths` — the vault paths this session touched (files or directories; the orchestrator knows them from session-type detection)
- `created_paths` — the subset of `scope_paths` this session CREATED (inline-fix authority applies only here)
- `vault_root` — resolved via the `workspace_root` config key or `VAULT_ROOT` env

## Protocol

1. **Run the linter** — `lint.py` lives in the sibling `lint-knowledge` skill (same skills directory as this skill):

   ```
   python3 <skills-dir>/lint-knowledge/lint.py --no-manifest --json \
       --vault-root <vault_root> <scope_paths...>
   ```

   `--no-manifest` is mandatory: a scope-lint is a stateless per-session pass and must not touch the periodic mode's manifest/delta state (non-overlap with `/lint-knowledge`).

2. **Parse findings** from the JSON output. If the scope contains no lintable files or zero findings, report one line (`scope-lint: clean, N files`) and stop.

3. **Partition and act:**
   - **Envelope HIGH findings on `created_paths`** → fix inline NOW. These are frontmatter-level structural-envelope repairs (missing `type/` or scope tag, missing `status/active`, missing/malformed `updated`, missing `sources`) on files this session made — autonomous, within this skill's existing decision authority. Fix via `mcp__obsidian__update_frontmatter`, then re-run step 1 on the fixed files to confirm the HIGHs cleared.
   - **All other findings** — HIGHs on pre-existing files, MEDIUMs and WARNINGs anywhere — → queue items via `/queue create-item` with `queue_kind: disposition`, `source: scope-lint`, `reasons` from the finding text, scope tags from the affected file's own scope tag. **Batch all findings on the same file into ONE item** — the operator adjudicates files, not line numbers.

4. **Report** to the orchestrator: files linted, findings by severity, inline fixes applied (with confirmation they cleared), queue items created (paths).

## Discipline

- **Inline-fix authority is scoped to session-created files and frontmatter-level repairs.** Findings on pre-existing files are out-of-session-scope docs — flag, don't modify (same escalation rule as the rest of this skill); the queue item is the flag. Body-content findings even on created files (e.g. contradiction candidates) go to the queue too — this playbook's autonomy ends at the envelope.
- **No model in the lint pass.** Judgment enters only at the partition step and the fix composition. Keep it that way — the mechanical pass being free is what makes running it every closeout viable.
- **Don't lint the queue.** `Wiki/Queue/` is outside the knowledge-contract Part II Location Gate; exclude it from `scope_paths` if the session touched it.

## What this playbook does NOT do

- Does NOT run full-corpus scans or manage the manifest — that's `/lint-knowledge` (periodic mode).
- Does NOT adjudicate queued findings — the queue drain surfaces them to the operator.
- Does NOT gate filing — the filing-time lint gate in `query-and-file` already ran for new Knowledge pages; scope-lint is the closeout backstop across the whole touched scope.
