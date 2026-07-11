---
name: lint-knowledge
description: >
  Scan a target scope (project Knowledge/, Wiki/, or arbitrary path) for structural issues:
  tag taxonomy violations, orphans, stale frontmatter, missing tags, index drift,
  contradictions, legacy tag usage, topic consolidation candidates, and status-coherence
  gaps. Reports findings without auto-fixing. Triggers on "/lint-knowledge",
  "lint knowledge", "check knowledge health", or "scan knowledge for issues".
---

# Lint Knowledge

Health check: scan knowledge content for drift against the taxonomy and the structural contract. Reports findings — does not auto-fix.

## Objective

Knowledge systems decay silently. Tags drift from taxonomy, files lose provenance, context pages fall behind their Knowledge/ sources, and stale content reads as authoritative. Without periodic structural validation, the Wiki's reliability degrades in ways that surface as wrong answers in future sessions — not as visible errors.

Lint is the mechanical verification layer — **the executable form of the contracts.** It checks properties defined elsewhere (tag rules in `knowledge-contract.md § Part I`, envelope rules in `knowledge-contract.md § Part II`, health metrics in `{workspace_root}/Wiki/CLAUDE.md`) and reports violations. It does not define what's correct — it verifies that content matches what the authoritative sources say should be true. The complete check set, with severities and rule sources, is inventoried in `knowledge-contract.md § Part IV`; this skill implements that inventory's **periodic** surface.

## Architecture — two passes

The periodic surface splits in two, and this skill orchestrates both (see `{workspace_root}/Wiki/spec/knowledge-contract.md § Part IV` › "Periodic mode"):

- **Mechanical pass** — the bundled `lint.py` script runs every deterministic check (envelope, tags, links, index integrity, freshness, topic consolidation). No model, read-only, runs full-corpus, costs ~nothing. It derives its rule *values* at runtime from the contracts' Parsing Contracts — it holds no hardcoded vocabulary or limit.
- **Judgment pass** — the model runs the one genuine-judgment check: the contradiction scan (and, for hub/subproject scopes, the hub cross-reference). **Delta-scoped** — only files changed since the last run. This is the sole component that costs model tokens.

The skill's job: resolve the scope, run the script, run the delta-scoped judgment pass, merge both into one report. On a no-change scope the judgment pass is skipped entirely — the run is a pure script pass.

## Desired Outcomes

1. After a lint run, the operator knows exactly which files violate structural rules and at what severity — no silent degradation
2. Taxonomy drift is caught before it fragments the tag namespace beyond recovery
3. Freshness gaps are surfaced so stewardship sessions can prioritize what to validate
4. The periodic run is cheap enough to schedule — script-dominated, with a $0 floor when nothing changed

## Health Metrics (for lint itself)

- Zero false positives on HIGH severity findings — every HIGH is a real violation against an authoritative source
- Rule values derived from authoritative sources at runtime (`knowledge-contract.md § Part I`, `knowledge-contract.md § Part II` Parsing Contract) — never hardcoded values that can drift from their source
- Report is actionable: every finding includes enough context to fix without re-reading the source file
- Read-only guarantee: lint never modifies files — neither the script nor the judgment pass

## Decision Authority

| Decision | Authority |
|---|---|
| Scanning, classifying, and reporting findings | Autonomous |
| Fixing any finding | **Never** — lint reports, caller fixes |
| Determining severity levels for known check types | Autonomous (per `knowledge-contract.md § Part IV`) |
| Flagging that the taxonomy itself may need updating | Autonomous (report as finding, not as a fix) |
| Adding a new check type not in `knowledge-contract.md § Part IV` | Not autonomous — requires a `knowledge-contract.md § Part IV` spec update AND a `lint.py` change |

## Referenced docs

- **Lint surface spec** — `{workspace_root}/Wiki/spec/knowledge-contract.md § Part IV`. The canonical inventory: every check, its rule source, pass (mechanical/judgment), mode, severity. Defer to it for what checks exist and at what severity.
- **Structural contract** — `{workspace_root}/Wiki/spec/knowledge-contract.md § Part II`. Governs the file envelope. `lint.py` parses its **Parsing Contract** at runtime — do not restate its rules here.
- **Tag taxonomy** — path configured in global CLAUDE.md > Configuration > `references.tag_taxonomy`. `lint.py` parses it at runtime for namespace/vocabulary/depth rules. The `person/` and `area/work/` instance vocabularies (real names/employers) are PII-excluded from this doc and parsed instead from the sibling `tag-taxonomy-rosters.md`, same directory, same runtime-parsing discipline.
- **Filing-handoff contracts** — `{workspace_root}/Wiki/spec/knowledge-contract.md § Part III`. Context only: filing-time validation is `lint.py --filing` (same script, filing mode), invoked directly by filing skills — not orchestrated by this skill. This skill is the periodic implementer.

## Scope and flags

**Scope modes** (one required):

| Invocation | Scope paths passed to `lint.py` |
|---|---|
| `/lint-knowledge` | Auto-detect: current project's Knowledge layer (from cwd's `CLAUDE.md`). No project context → error. |
| `/lint-knowledge {project}` | The named project's Knowledge layer |
| `/lint-knowledge --scope wiki` | `{workspace_root}/Wiki/Knowledge/` + `{workspace_root}/Wiki/Contexts/` |
| `/lint-knowledge --scope vault` | The vault's knowledge-layer directories |
| `/lint-knowledge --scope {path}` | An arbitrary vault-relative path |

For a project whose Knowledge layer is a flat root (e.g. System: docs at `{workspace_root}/System/*.md` plus `{workspace_root}/System/Knowledge/`), pass the project root — `lint.py` walks recursively.

`lint.py` applies the **Location Gate** (`knowledge-contract.md § Part II` › Scope Boundaries) per file regardless of the scope path passed: only governed knowledge-layer locations are linted. Ungoverned paths (`Wiki/Data/` domain content, recruiting operational records, `*-archive.md` / `Archived/`, raw/operational project scratch) produce no findings even if a scope path includes them — so passing a broad scope is safe.

**Flags:**

| Flag | Effect |
|---|---|
| `--mechanical-only` | Run only the script (Step 1). Skip the judgment pass. Pure deterministic pass, zero model cost. |
| `--full` | Run the judgment pass over the **entire** scope, not just the delta set. For first runs, migration-validation one-offs, and on-demand deep checks. |

## Instructions

### Step 0: Parse invocation

Resolve the scope mode to one or more absolute directory paths, and resolve the flags. If invocation is ambiguous (`/lint-knowledge` with no detectable project context), report and stop.

### Step 1: Mechanical pass — run the script

Run the bundled script (it sits next to this `SKILL.md`):

```
python3 <skill-base-dir>/lint.py <scope-path> [<scope-path> ...] --json --vault-root <vault-root>
```

The script walks the scope, runs every mechanical check, computes the changed-since-last-run delta against its manifest, and emits JSON: `findings`, `delta` (`changed` / `new` / `deleted`), `scanned`, `summary`. It is read-only and uses no model.

The skill does **not** pass `--no-manifest` — the manifest must persist for the delta to work — so `delta` is always populated (never null) on a skill-driven run. `--state-dir` defaults to `~/.cache/lint-knowledge/`; the script also accepts `--state-dir <path>` and `--no-manifest` (stateless full run, `delta` null), both for CI / one-off direct use outside this skill.

Parse the JSON. If the script exits non-zero, surface its error and stop — a non-zero exit means a script-level failure (e.g. a contract doc could not be parsed), not lint findings.

### Step 2: Judgment pass — contradiction scan (skip if `--mechanical-only`)

Determine the **judgment scope**:

- Default: the delta set from Step 1's JSON (`changed` ∪ `new`).
- `--full`: the entire scanned file set.
- **CLAUDE.md widening:** if the scope's `CLAUDE.md` is in the delta set, widen the judgment scope to all knowledge files in that scope — a Current State edit can retroactively contradict unchanged pages.
- If the judgment scope is **empty** (nothing changed, and not `--full`) → skip this step. Report that the judgment pass was skipped (no changes since last run).

For each file in the judgment scope, read its body (Obsidian MCP, read-only) and run the **contradiction scan** — best-effort, INFO severity:

- Claims contradicted by the scope's `CLAUDE.md` Current State
- References to entities, paths, or configs that no longer exist
- Assertions that contradict other in-scope Knowledge pages

If the target is a hub or a subproject under a hub, also run the **hub cross-reference**: compare hub Knowledge against subproject state; report hub pages that appear stale or incomplete.

Report; never resolve.

### Step 3: Merge and report

Merge the script's mechanical findings (Step 1) and the judgment findings (Step 2) into one report. Organize by **severity first**, then category within severity:

```
## Lint Report — {scope}
Passes: mechanical{, judgment (delta: N files){, widened by CLAUDE.md}}
Scanned: {N files}   Delta since last run: {changed C, new N, deleted D}

### HIGH severity — envelope violations (N)
- **{file path}** — {check}: {detail} [Suggested fix: {...}]

### MEDIUM severity (N)
### WARNING (N)
### INFO (N)
{topic consolidation candidates — heuristic, review required; contradiction-scan findings; hub cross-ref}

### Summary
- Total pages scanned: N
- Clean: N
- Issues: N (HIGH: N, MEDIUM: N, WARNING: N, INFO: N)
- Passes run: {mechanical / mechanical + judgment}
```

Report the run as **clean** only when every tier is zero. `0 HIGH` with MEDIUM/WARNING findings is **not** clean — present it as "0 envelope violations; N tracked at MEDIUM/WARNING", never a bare "0 HIGH" (HIGH = envelope violations specifically; the lower tiers — broken links, freshness, topic drift — are real findings, not noise).

## Notes

- **Read-only.** Neither the script nor the judgment pass modifies any file. The caller applies fixes.
- **The contracts are authoritative.** `lint.py` derives namespace rules (`knowledge-contract.md § Part I`) and envelope rules (`knowledge-contract.md § Part II`) at runtime from their Parsing Contracts — it never hardcodes a rule value. `knowledge-contract.md § Part IV` is the inventory of which checks exist and at what severity. If any of the three changes, the next run picks it up.
- **`[tightening]` checks.** `status/`-tag-present, single-H1, and Wiki-`topic/` enter as HIGH per the structural contract. The first periodic run on the legacy corpus is expected to surface large worklists (`sources` backfill, H1 normalization, `status/`-tag migration) — that is the contract's Migration Legacy work, not lint failure.
- **Cost.** The mechanical pass is local CPU — effectively free. The judgment pass costs model tokens only over the delta set; an unchanged scope skips it entirely ($0). See `knowledge-contract.md § Part IV` › "Cost".
- **Filing-time is separate.** Filing-time envelope validation is `lint.py --filing` (see `knowledge-contract.md § Part III`) — the same script as the periodic mechanical pass, run single-file with `[tightening]` rules escalated to HIGH. Filing skills invoke it directly; this skill orchestrates the periodic surface only.
- For session-boundary maintenance, see `/session-start` (freshness scan) and `/session-closeout` (query-and-file, staleness flagging, index sync).
