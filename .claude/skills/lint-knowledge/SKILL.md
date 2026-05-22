---
name: lint-knowledge
description: >
  Scan a target scope (project Knowledge/, Wiki/, or arbitrary path) for structural issues:
  tag taxonomy violations, orphans, stale frontmatter, missing tags, index drift,
  contradictions, legacy tag usage, topic consolidation candidates, and status-coherence
  gaps. Reports findings without auto-fixing. Triggers on "/lint-knowledge",
  "lint knowledge", "check knowledge health", or "scan knowledge for issues".
user_invokable: true
---

# Lint Knowledge

Ad-hoc health check: scan knowledge content for drift against the taxonomy and architectural rules. Reports findings — does not auto-fix.

## Objective

Knowledge systems decay silently. Tags drift from taxonomy, files lose provenance, context pages fall behind their Knowledge/ sources, and stale content reads as authoritative. Without periodic structural validation, the Wiki's reliability degrades in ways that surface as wrong answers in future sessions — not as visible errors.

Lint is the mechanical verification layer — the executable form of the contracts. It checks properties defined elsewhere (tag rules in `tag-taxonomy.md`, envelope rules in `structural-contract.md`, health metrics in `Wiki/CLAUDE.md`) and reports violations. It does not define what's correct — it verifies that content matches what the authoritative sources say should be true. The complete check set, with severities and rule sources, is inventoried in `lint-surface.md`; this skill implements that inventory's **periodic** column.

## Desired Outcomes

1. After a lint run, the operator knows exactly which files violate structural rules and at what severity — no silent degradation
2. Taxonomy drift is caught before it fragments the tag namespace beyond recovery
3. Freshness gaps are surfaced so stewardship sessions can prioritize what to validate
4. The health metrics defined in `Wiki/CLAUDE.md` are mechanically verified, not assumed

## Health Metrics (for lint itself)

- Zero false positives on HIGH severity findings — every HIGH is a real violation against an authoritative source
- All checks derived from authoritative sources at runtime (`tag-taxonomy.md`, `structural-contract.md` Parsing Contract, `Wiki/CLAUDE.md`) per the `lint-surface.md` inventory — never hardcoded rules that can drift from their source
- Report is actionable: every finding includes enough context to fix without re-reading the source file
- Read-only guarantee: lint never modifies files

## Decision Authority

| Decision | Authority |
|---|---|
| Scanning, classifying, and reporting findings | Autonomous |
| Fixing any finding | **Never** — lint reports, caller fixes |
| Determining severity levels for known check types | Autonomous (per severity rules in this spec) |
| Flagging that the taxonomy itself may need updating | Autonomous (report as finding, not as a fix) |
| Adding new check types not defined in this spec | Not autonomous — requires spec update |

## Referenced docs

- **Lint surface spec** — `System/lint-surface.md`. The canonical inventory of the complete check set: every check, its rule source, execution mode, severity. This skill implements the **periodic** half of that surface. Defer to it for what checks exist and at what severity.
- **Structural contract** — `System/structural-contract.md`. Governs the file *envelope* (required frontmatter, single H1, discoverability). Its **Parsing Contract** section is the runtime source for structural checks; its **Scope Boundaries** list names the exempt `type/` values. **This skill reads it at runtime; do not hardcode the structural rules here.**
- Canonical tag-namespace rules (closed vocabularies, thresholds, depth limits): path configured in global CLAUDE.md > Configuration > `references.tag_taxonomy`. **This skill reads it at runtime; do not hardcode rules here.**
- **Filing-handoff contracts** — `System/handoff-contracts.md`. Context only: the filing-time critic-subagent (not this skill) implements filing-time validation. This skill is the periodic implementer.
- Architectural target state: path configured in global CLAUDE.md > Configuration > `references.target_architecture`.

The lint surface and structural contract are now authoritative sources this skill *references at runtime*, not rule sets it restates. When they change, this skill picks up the change at the next run.

## Scope and modifier modes

**Scope modes** (one required):

| Invocation | Scope |
|---|---|
| `/lint-knowledge` | Auto-detect: current project's Knowledge/ (fallback if no project context detected: error) |
| `/lint-knowledge {project}` | Specified project's Knowledge/ |
| `/lint-knowledge --scope wiki` | `Wiki/Knowledge/` + `Wiki/Data/` + `Wiki/Contexts/` |
| `/lint-knowledge --scope vault` | Entire vault (taxonomy-only by default; see execution guardrails below) |
| `/lint-knowledge --scope {path}` | Arbitrary vault-relative path |

**Modifier flags** (combinable with any scope):

| Flag | Effect |
|---|---|
| `--taxonomy-only` | Skip Steps 2, 5, 6, 7 (inventory/link/index integrity, freshness, contradictions, hub cross-ref). Run only Steps 3, 4 (taxonomy + structural-envelope validation + topic consolidation). Step 3 covers both tag-taxonomy checks and the per-file structural-envelope checks derived from `structural-contract.md` (3E, 3J) — these are file-at-rest checks, cheap, and run even under `--taxonomy-only`. The corpus-scale structural checks (cross-project links, index integrity) live in Step 2 and are skipped. |
| `--metadata-first` | For large scopes, use `get_notes_info` to collect frontmatter before `read_note` for body checks. Default ON for `--scope vault`; default OFF otherwise. |

**Default combinations:**
- `--scope vault` implies `--taxonomy-only` and `--metadata-first` unless overridden (prevents runaway execution).

## Instructions

### Step 0: Parse invocation

Resolve scope mode and modifier flags. If invocation is ambiguous (e.g., `/lint-knowledge` outside any project context), report and stop.

### Step 1: Load authoritative sources (always runs)

**A. Load the taxonomy**

Read `System/tag-taxonomy.md`. Extract the following lists using the stated parsing contract — this is the only authoritative source for tag rules:

**Parsing contract:**

| What to extract | Where in the doc | How to parse |
|---|---|---|
| Six namespace prefixes | "## The Namespaces" table, column 1 | Split on `/`; take first segment; strip `<x>` angle brackets |
| Closed `type/` values | "### `type/`" section, table column 1 | Strip `type/` prefix; collect values |
| Closed `status/` values | "### `status/`" section, table column 1 | Strip `status/` prefix; collect values |
| Active `project/` values | "### `project/`" section, bullet list under "Active projects" | Strip `project/` prefix; collect values |
| Grandfathered `project/*` prefixes | "### `project/`" section, text mentioning "grandfathered" | Collect prefix patterns (e.g., `project/neudesic/*`, `project/grin/*`) |
| Current `area/` top-levels | "### `area/`" section, "Current top-levels" bullet list | First path segment under `area/` |
| `person/` roster | "### `person/`" section, "Current roster" list | Names — normalize to kebab-case |
| Depth limits | "## Depth Limits (Summary)" table | Per-namespace typical + max |

Enumerate active `Projects/*` folders at runtime via `list_directory` on `Projects/` — this is the authoritative source for "which `project/x` tags have a matching folder." Do NOT rely on the taxonomy doc's list alone; it may drift.

**B. Load the structural contract**

Read `System/structural-contract.md`. Parse its **Parsing Contract** section the same way Step 1A parses the tag-taxonomy parsing contract — each row tells you what structural rule to extract and how. Do NOT hardcode the structural rules; derive them. Extract:

| What to extract | Where in the doc | Use |
|---|---|---|
| Invariant-core frontmatter elements (`type/`, scope tag, `status/`, `updated`) | "Invariant Core" table | Presence/cardinality checks applied to **every** governed type — Step 3E |
| Invariant-core body element (single H1) | "Invariant Core" table, "Title" row | Single-H1 body check — Step 3J |
| Per-type required additions (keyed by `type/` value) | "Per-Type Additions" table | Type-specific required tags + `sources` requirement — Step 3E |
| Destination modifiers (Wiki-hosted vs project-hosted) | "Destination Modifiers" table | Scope-tag-matches-destination, `topic/`-on-Wiki-`knowledge`, `index.md`-entry — Step 3E, Step 2 |
| Scope exemptions | "Scope Boundaries" list | Which `type/` values are **exempt** from the Per-Type Additions table (still satisfy Invariant Core where they carry tags) |

Carry forward the `[tightening]` markers from the contract — a rule marked `[tightening]` is stricter than lint's prior behavior; this skill escalates its severity per the lint surface (see Step 3E, 3J), it does not silently adopt.

**Governed-type set:** the Invariant Core applies to every knowledge-layer `type/` value. The Per-Type Additions apply only to types in the contract's Per-Type Additions table; types named in Scope Boundaries are exempt from per-type checks. Resolve both sets from the parsed contract at runtime — do not hardcode the type list.

**C. Load Wiki health metrics**

Read `Wiki/CLAUDE.md` > Health Metrics section. These define the structural properties that must hold across the Wiki. The checks in Steps 3–5 implement these metrics mechanically. If the health metrics in `Wiki/CLAUDE.md` change, re-evaluate whether the checks below still cover them.

Key metrics to extract and verify (current as of spec writing — always defer to the live document):
- Tag compliance: every Knowledge/ file has `type/knowledge` + `area/*` + `status/*`
- Provenance: every Knowledge/ file has `sources` frontmatter
- Size: no Knowledge/ file over 150 lines without human-approved consolidation
- Context coverage: every `area/*` with Knowledge/ files has a corresponding Context file
- Freshness: no context page contradicts current Knowledge/ state
- Wikilinks: no broken `[[wikilinks]]` inside Wiki/

### Step 2: Inventory Check (skip if `--taxonomy-only`)

List files via `list_directory` on the target scope. Tags are the index — no hand-curated index files.

**Wiki scope — Stub drift check:**
For each page with `type/project-pointer` tag:
1. Extract the project name from the page's `project/<name>` tag (NOT from filename or body)
2. Convert kebab-case to Title Case for folder lookup (e.g., `home-assistant` → `Home Assistant`)
3. Verify `Projects/{TitleCase}/` exists via `list_directory`
4. If missing → **Stub drift**: stub points at nonexistent project folder

**Wiki scope — Broken wikilinks:**
For each page in scope, scan body content for `[[wikilinks]]`. Verify each target resolves to an existing page. Broken target → **Broken wikilink** (HIGH)

**Cross-project reference link-integrity** (see lint surface "Cross-project-reference link-integrity"):
A reference from one project's Knowledge into another project's Knowledge must *be* a `[[wikilink]]`, not a bare path or prose mention. For each in-scope page carrying a `project/x` tag:
1. Scan body for references that cross a `project/` boundary (a bare path like `Projects/Other/...` or a prose mention of another project's file)
2. A cross-project reference not expressed as a wikilink → **Cross-project reference not a wikilink** (MEDIUM)
3. A cross-project `[[wikilink]]` whose target does not resolve → **Broken cross-project wikilink** (MEDIUM) — mechanically the broken-wikilink check scoped to links crossing a `project/` boundary

**Index integrity** (project-hosted scope — see lint surface "index integrity"; derived from the structural contract's Destination Modifiers `index.md`-entry rule):
For project-hosted scopes (`Projects/{name}/Knowledge/`, `System/Knowledge/`, `System/` root):
1. Read the scope's `index.md` if present
2. Each governed knowledge-layer file in scope must have a corresponding `index.md` entry → missing entry → **Missing index entry** (MEDIUM)
3. Each `index.md` entry must resolve to an existing file → entry pointing at a nonexistent file → **Orphan index entry** (MEDIUM)
Index *syncing* is a filing-skill obligation, not a lint fix — lint only reports drift.

### Step 3: Tag Taxonomy + Structural Envelope Validation (core check)

For each in-scope page, get frontmatter via `get_frontmatter`. Checks 3A–3I and 3E's frontmatter checks operate on frontmatter only. Check 3J (single H1) needs body content — under `--metadata-first` defer 3J until after the frontmatter pass, then read bodies. Validate each tag and each envelope rule:

**A. Namespace membership**

Tag must start with one of the six namespace prefixes (from Step 1).

| Issue | Severity | Example |
|---|---|---|
| **Orphan tag** (outside namespaces) | HIGH | `ag-design-team`, `gear`, single letters, hex codes |
| **Legacy `people/*`** | MEDIUM | `people/alli_sobiecki` → `person/alli-sobiecki` |
| **Legacy `phase/*`** | MEDIUM | `phase/active` → `status/active` |

**B. Closed vocabulary (HIGH threshold namespaces)**

For `type/`, `status/`: validate against extracted closed lists.

For `project/`: tag is valid if EITHER:
- `project/x` where `x` matches an active Projects/{TitleCase}/ folder (Step 1 enumeration), OR
- `project/x/...` where the root prefix matches a grandfathered pattern (from taxonomy doc)

| Issue | Severity | Action |
|---|---|---|
| **Unknown type** — `type/x` not in closed list | HIGH | Flag; suggest known alternatives if stem-similar |
| **Unknown status** — `status/x` not in closed list | HIGH | Flag |
| **Orphan project tag** — `project/x` with no Projects/ match and not grandfathered | HIGH | Flag. **If `area/x` or `area/{plausible-parent}/{x}` would be reasonable, suggest it** (this catches legacy overloaded project tags like `project/photography` → `area/photography`) |

**C. Depth limits**

Count path segments per tag (splits on `/`, depth = segment count). Apply per-namespace max from taxonomy.

- Tag exceeding max depth → **Depth violation** (suggest "split into multiple tags across namespaces — see taxonomy > Depth Escape Hatch")
- Exception: `project/*` tags matching a grandfathered prefix skip the depth check.

**D. Medium-threshold value recognition**

| Issue | Severity |
|---|---|
| **Unrecognized area** — `area/x` where `x` is not a known top-level, or `area/x/y` where `x` is unknown | WARNING (may be a legitimate new area; prompt user to confirm + add to taxonomy) |
| **Unrecognized person** — `person/x` not in known roster | WARNING |

**E. Invariant-core presence (all governed types)**

The structural contract's Invariant Core applies to **every** governed knowledge-layer type — not just `type/knowledge`/`type/context`/`type/data`. Apply these presence/cardinality checks (derived from the parsed Invariant Core, Step 1B) to every in-scope page carrying a `type/` value, EXCEPT pages whose `type/` is listed in the contract's Scope Boundaries (those satisfy the core where they carry tags but are not held to it by lint as a violation):

- Not exactly one `type/` tag → **Type cardinality** (HIGH — must carry exactly one closed-vocabulary `type/`)
- Missing **both** `area/` AND `project/` scope tag → **Missing scope tag** (HIGH — need at least one)
- Missing `updated` frontmatter field → **Missing updated** (HIGH)
- Not exactly one `status/` tag → **Missing/duplicate status** (HIGH — escalated from WARNING per lint-surface `[tightening]`; the first periodic run produces the structural contract's `status/`-tag migration worklist — expected output, not failure)

**Scope-tag-matches-destination** (derived from the contract's Destination Modifiers):
- A **Wiki-hosted** file (`Wiki/Knowledge/`, `Wiki/Data/`, `Wiki/Contexts/`) must carry an `area/*` scope tag → carries only `project/*` → **Scope tag mismatch** (HIGH — Wiki-hosted requires `area/`)
- A **project-hosted** file (`Projects/{name}/Knowledge/`, `System/Knowledge/`, `System/` root) must carry a `project/*` scope tag → carries only `area/*` → **Scope tag mismatch** (HIGH — project-hosted requires `project/`)

**Per-type additions** (derived from the contract's Per-Type Additions table — only for types in that table; types in Scope Boundaries are exempt):
- `type/knowledge`: missing `sources` frontmatter → **Missing provenance** (HIGH)
- `type/knowledge` **Wiki-hosted**: missing any `topic/` tag → **Missing topic** (HIGH — `[tightening]`: enters as HIGH; the first run produces the contract's H1/topic-backfill worklist — expected)
- `type/project-pointer`: missing `project/` OR missing `topic/` → **Missing required pointer tag** (HIGH)
- Other types' `sources` requirement is per the contract's `sources` column (Required / Optional / n/a) — flag only Required-and-absent.

**F. Status coherence**

If both frontmatter `status:` field AND a `status/*` tag present on the same page:
- Values must match (e.g., `status: active` + `status/active` is OK; `status: active` + `status/draft` is a mismatch)
- Mismatch → **Status incoherence** (HIGH severity; frontmatter value and tag value diverge)

If only one present: that's fine. The migration itself will resolve divergence.

**G. Context page coverage**

Collect all `area/*` tags from Knowledge/ files in scope. For each unique `area/*` value:
- Check if a corresponding Context file exists in `Wiki/Contexts/` (`{domain}-context.md` with `type/context` + matching `area/*` tag)
- Missing → **Missing context page** (WARNING — domain has Knowledge/ files but no context page for Claude to discover them)

**H. Knowledge/ file size**

For each `type/knowledge` file:
- Over 150 lines → **Consolidation candidate** (WARNING — flag for human review per mutation discipline)
- Over 6 distinct entries in `sources` frontmatter → **Source sprawl** (INFO — may indicate file scope is too broad)

**I. Stale suspects audit**

For each Context page with a `stale_suspects` frontmatter array:
- Verify each listed file path still exists → missing file = **Stale suspect target missing** (WARNING)
- Report unresolved stale suspects count per domain for stewardship awareness

**J. Single H1 (body check)**

Per the structural contract Invariant Core "Title" rule (a `[tightening]` rule — lint had no H1 check before). For each in-scope governed page (types in Scope Boundaries exempt), scan body for level-1 headings (`# `):
- Zero or more than one level-1 heading → **H1 violation** (HIGH — `[tightening]`: enters as HIGH per lint surface; the first periodic run produces the contract's single-H1 normalization worklist — expected output, not failure)

### Step 4: Topic Consolidation Scan

Collect all `topic/*` tags in scope.

**Matching algorithm (deterministic):**
1. For each pair of topics in scope: compute Jaccard similarity on character 3-grams
2. Also compute: same-stem check (one is prefix/suffix of the other with length-delta ≤ 3 chars)
3. Flag pairs where Jaccard ≥ 0.6 OR same-stem passes
4. Sort flagged pairs alphabetically (canonical ordering) for reproducible output

**Sub-variant proliferation check (new):**
1. Group all `topic/*` tags in scope by stem (first 4-6 characters) OR by shared primary word (e.g., "scent", "skin", "shoe")
2. Flag groups of 3+ topics that share a stem or primary word
3. For each group, propose the broader topic as canonical (e.g., `topic/scent-exploration` + `topic/scent-blooming` + `topic/scent-scales` → `topic/fragrance`)
4. Also flag domain-facet topics: if a topic describes a method, retailer, brand, or framework within an existing broader topic (via cross-reference with the taxonomy doc), suggest the broader as canonical.

Output is labeled "**Consolidation candidates (heuristic — review required)**". Not authoritative; a manual pass decides.

For each candidate pair/group, propose the existing-more-used tag as the canonical (or alphabetically first if counts tie).

### Step 5: Frontmatter Freshness Check (skip if `--taxonomy-only`)

For each page, determine the freshness date:
- Use `verified` if present (content was reviewed for accuracy on this date)
- Fall back to `updated` if no `verified` field
- A file with `updated` but no `verified` was mechanically touched (migration, retagging) — not content-reviewed. Flag as **Unverified** (INFO) if `updated` is within the freshness window but `verified` is absent.

Compare freshness date against threshold:
- Default: 90 days from today
- Domain override: if the domain's context page declares a freshness threshold, use that
- Project override: if the target project's CLAUDE.md declares a freshness threshold, use that

Stale pages → list with freshness date, source field (`verified` or `updated`), and days past threshold.

### Step 6: Contradiction Scan (skip if `--taxonomy-only`)

Best-effort check of knowledge pages against the scope's CLAUDE.md (if any):
- Claims contradicted by CLAUDE.md Current State
- References to entities, paths, configs no longer existing
- Assertions that contradict other Knowledge pages in scope

Report; don't resolve.

### Step 7: Hub Cross-Reference (skip if not hub/subproject, or if `--taxonomy-only`)

If target is subproject under a hub, or is itself a hub: cross-reference hub Knowledge against subproject state. Report hub pages that appear stale or incomplete.

### Step 8: Report

Organize findings by **severity first**, then category within severity. Output template:

```
## Lint Report — {scope}
Mode: {modifiers applied}
Scanned: {N files}

### HIGH severity (N)
{orphan tags, depth violations, status incoherence, unknown type/status/project, stub drift,
type cardinality, missing scope tag, missing updated, missing/duplicate status tag,
scope-tag mismatch, missing provenance, missing topic (Wiki knowledge),
missing pointer tags, H1 violation, broken wikilinks}

- **{file path}** — {finding type}: {details} [Suggested fix: {...}]

### MEDIUM severity (N)
{legacy people/*, phase/*, orphan missing project tag without suggested area alternative,
cross-project reference not a wikilink, broken cross-project wikilink,
missing index entry, orphan index entry}

### WARNING (N)
{unrecognized area/person, stale pages, freshness, missing context page, stale suspect target missing}

### INFO (N)
{topic consolidation candidates, hub cross-ref observations}

### Summary
- Total pages scanned: N
- Clean: N
- Issues found: N (HIGH: N, MEDIUM: N, WARNING: N, INFO: N)
- Mode: {flags}
```

If no issues, report clean state.

## Execution guardrails

**Large scopes (`--scope vault`, or `--scope wiki` with many files):**
- Default to `--metadata-first`: use `get_notes_info` to batch frontmatter extraction before expensive `read_note` calls
- Steps 3J (single H1), 5, 6, 7 require body content; defer until after the frontmatter-only checks (cheap) complete
- Steps 5 and 6 skipped by default under `--taxonomy-only` (the usual vault-scope invocation); Step 3J still runs under `--taxonomy-only` — it is a per-file envelope check, but its body read is deferred behind the frontmatter pass under `--metadata-first`

**Concurrency:** This skill runs serially. No parallelization.

## Notes

- **Read-only.** This skill reports findings; it never modifies files. The caller applies fixes.
- **The contracts are authoritative.** Never hardcode namespace rules (`tag-taxonomy.md`) or structural-envelope rules (`structural-contract.md`) here — derive both at runtime from their parsing contracts. The lint surface (`lint-surface.md`) is the inventory of which checks exist and at what severity. If any of the three changes, this skill picks up the change at the next run.
- **`[tightening]` checks.** `status/`-tag-present (escalated WARNING→HIGH), single-H1, and Wiki-`topic/` (both entering as HIGH) are marked `[tightening]` in the structural contract. Their first periodic run is expected to surface large legacy worklists (`sources` backfill, H1 normalization, `status/`-tag migration) — that is the contract's Migration Legacy work, not lint failure.
- **This skill is the periodic surface.** Filing-time envelope validation is a separate, not-yet-built critic-subagent (see `handoff-contracts.md` and `lint-surface.md`). This skill does not implement filing-time.
- For session-boundary maintenance, see `/session-start` (freshness scan) and `/session-closeout` (query-and-file, staleness flagging, index sync).
