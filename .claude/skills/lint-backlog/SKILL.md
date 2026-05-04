---
name: lint-backlog
description: >
  Scan one or more project backlog.json files for stale items — items whose age (days
  since `created`) exceeds the per-status threshold declared in the backlog's `lint`
  block. Reports findings; never modifies files. Triggers on "/lint-backlog",
  "lint backlog", "lint this backlog", or "/lint-backlog <project>".
user_invokable: true
---

# Lint Backlog

Mechanical staleness check: scan a project's backlog and surface items that have sat past their threshold without movement. Reports — does not auto-archive, auto-close, or auto-modify lint settings.

## Objective

Backlogs accumulate items that sit untouched for weeks past the point of relevance. Direction shifts, priorities move, items get forgotten. Without periodic surfacing, dead items pile up alongside live ones and the backlog stops being a tool for choosing what to work on. This skill surfaces stale items at the moment of decision (session start, on-demand check) so they can be acted on or killed.

It enforces structural rules defined elsewhere — the `lint` block in each project's `backlog.json`, and the schema rules in `Claude/System/intake-defaults.md`. It does not define what "stale" means; it verifies items against the project's own declared thresholds.

## Desired Outcomes

1. After a lint run, the operator knows exactly which items are past their staleness threshold and by how much
2. The lint never invents thresholds — it only reads what each project's `backlog.json` declares
3. Output is actionable: every finding includes the item ID, status, age, and how far past threshold so the operator can decide quickly
4. Read-only guarantee: lint never modifies files, never auto-archives, never auto-tunes thresholds

## Decision Authority

| Decision | Authority |
|---|---|
| Reading backlog files and computing staleness | Autonomous |
| Suggesting threshold adjustments to the operator | Autonomous (in standalone output, not session-start) |
| Modifying any backlog field | **Never** — lint reports, operator acts |
| Auto-archiving completed items | Not this skill — see `/session-closeout` |
| Adding new check types | Not autonomous — requires spec update |

## Configuration

The skill reads these config keys from the user's CLAUDE.md > Configuration section. Consumers must define them for the skill to function in their environment:

| Key | Purpose | Example |
|---|---|---|
| `workspace_root` | Root of the user's Claude system files (where `intake-defaults.md` and project templates live) | `~/Vaults/Notes/Claude` |
| `projects_root` | Root of the operational projects space (where each project's `backlog.json` lives) | `~/Vaults/Notes/Projects` |
| `user_timezone` | IANA timezone name used to resolve "today" for date math. Defaults to UTC if unset. | `America/Phoenix` |

## Referenced docs

- `{workspace_root}/System/intake-defaults.md` > File-Level Schema — canonical definition of the `lint` block, threshold semantics, exemption rules

## Invocation

| Form | Scope |
|---|---|
| `/lint-backlog` | Current project (auto-detect from session context or working directory). Error if no project context. |
| `/lint-backlog <project>` | Named project — kebab-case (`home-assistant`) or Title Case (`Home Assistant`) both accepted |
| `/lint-backlog --all` | All projects under `~/Vaults/Notes/Projects/*` that have a `backlog.json` |
| `/lint-backlog --top N` | Cap output at N most-overdue items per project. Used by `/session-start` integration; default unlimited in standalone mode. |
| `/lint-backlog --quiet` | Suppress malformed-item warnings and clean-state confirmations. Used by `/session-start` so a clean backlog produces no nag at all. |

## Instructions

### Step 1: Resolve scope

Determine the list of `backlog.json` files to scan:

- Explicit project arg → resolve to `{projects_root}/{TitleCase}/backlog.json`
- `--all` → enumerate all `{projects_root}/*/backlog.json` via `list_directory`
- No args → use current project context if known (set by `/session-start` or detectable from cwd via `pwd` matching `{projects_root}/{Project}/...`); otherwise error with usage hint

Project name resolution: if user passes `home-assistant`, look for `Home Assistant/`. If passes `Home Assistant`, use directly. Match case-insensitively against existing folder names.

### Step 2: Load and validate each backlog

For each target backlog:

1. Read `backlog.json` (use `Read` tool — these are not vault notes, they're JSON data files)
2. Validate file structure:
   - **No `lint` block** → in standalone: emit HIGH finding "missing lint block — add per `intake-defaults.md` File-Level Schema" and skip the project. In `--quiet` mode: skip silently.
   - **Partial `lint` block** (missing one or more of the three threshold fields) → emit HIGH finding "incomplete lint block — fields {missing} required" and skip the project regardless of mode.
3. Determine the items array key — most projects use `items`, but some legacy backlogs may still use `features` or another name. Look for the first array-of-objects field at the top level. If none, error.

### Step 3: Build same-backlog item index

Build a map: `id → status` for every item in the backlog. Used in Step 4 for exemption checks.

### Step 4: Classify each item

For each item:

1. **Skip if `status == "completed"`** — completed items are out of lint scope.
2. **Check for missing `created`** — if absent, add to malformed-items list and continue (do not classify as stale or fresh).
3. **Resolve threshold key:**
   - Normalize status: replace hyphens with underscores (`in-progress` → `in_progress`, `blocked` → `blocked`)
   - Map status to threshold field per the table in `intake-defaults.md`:
     - `in_progress` → `in_progress_threshold_days`
     - `pending` → `pending_threshold_days`
     - `waiting`, `blocked` → `waiting_threshold_days`
   - **Status with no mapped threshold** (e.g., `cancelled`, `deferred`, custom statuses) → skip silently. Lint only judges statuses with a declared threshold.
4. **Check exemption** — if item has `depends_on` or `blocked_by` field whose value (or any element if list) matches an item ID in the same-backlog index AND that referenced item is not `completed` → exempt from staleness. Cross-project ID references (item IDs not found in this backlog) do not exempt.
5. **Compute age:**
   - `today` = current date in `{user_timezone}` (UTC if not configured), date-only
   - `created_date` = parse `created` field as date-only
   - `age_days = (today - created_date).days`
6. **Classify:**
   - `age_days > threshold` → STALE. Record `overdue = age_days - threshold`.
   - Otherwise → fresh, no record.

### Step 5: Sort and cap

Sort stale items per project by `overdue` descending. Tiebreakers in order:
1. Status priority (most decision-ready first): `in-progress` > `waiting` > `blocked` > `pending`
2. `created` ascending
3. `id` ascending

Stable, deterministic ordering — important for session-start where the same call should produce the same nag. Status priority surfaces the cheapest cleanup first (in-progress items are most likely "done but not marked").

If `--top N` flag set, truncate each project's stale list to first N.

### Step 6: Report

Output format depends on flags.

**Standalone (no `--quiet`, single project):**

```
## Lint Backlog — {project name}

Stale items: {N}    Malformed: {M}    Scanned: {total non-completed}

### Stale (sorted: most overdue first)
- **{id}** [{status}] — {title (truncated to 80 chars)}
  age: {age_days}d · threshold: {threshold}d · overdue: {overdue}d

### Malformed
- **{id}** — missing `created` field

### Settings (current)
in_progress: {N}d · pending: {N}d · waiting: {N}d
```

**Standalone, `--all`:** repeat the per-project block; precede with a one-line summary across projects (`Total stale: N across M projects`).

**`--quiet` mode (session-start consumer):**

If 0 stale items: produce no output at all (truly silent).

If stale items present:

```
{N} item(s) past staleness threshold in this backlog.
- **{id}** [{status}] — {title} (overdue {overdue}d)
- ...
```

No header, no settings block, no malformed section. Just the line count and the items. The session-start skill wraps this in its own framing.

### Step 7: Optional suggestions (standalone only)

If a project has more than half its non-completed items stale, append a note: "Threshold may be too tight, or this backlog has a debt problem. Review settings in `backlog.json` or do a sweep."

This is a hint, not a directive. Lint never auto-tunes.

## Health Metrics (for lint itself)

- Zero false positives on stale findings — every flagged item genuinely exceeds its threshold per the rules in `intake-defaults.md`
- Deterministic output: same backlog state + same date produces identical output across runs (sort stability)
- Read-only guarantee: lint never modifies files
- Failure modes are loud: missing or partial `lint` block produces a finding, not silent skip (except in `--quiet` mode for session-start)

## Execution guardrails

- **Read-only.** Never call any write tool. Never modify the `lint` block, never re-classify item status, never archive.
- **No network calls.** Pure file read + arithmetic.
- **Concurrency:** runs serially per project. `--all` reads projects in sequence; no parallelism needed at this scale.
- **Subtasks (Router and similar):** staleness applies to the parent item only. Subtask `done` flags are not consulted.

## Notes

- Date math uses date-only values in `{user_timezone}` (UTC if not configured). `created` is interpreted as midnight in that timezone on that date; `today` is today's date in the same timezone. No off-by-one drift across DST or timezone boundaries.
- The `lint` block lives in each project's `backlog.json` per `intake-defaults.md` File-Level Schema. There is no global default — every project owns its values. To adjust, edit the file directly.
- For session-start integration, see the session-start skill's invocation of this skill with `--quiet --top 3`.
