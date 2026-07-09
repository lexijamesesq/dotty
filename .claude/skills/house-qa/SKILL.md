---
name: house-qa
description: >
  Corpus-conformance QA for authored artifacts — the executable form of
  corpus-conformance-methodology.md's "does it belong" validation axis (distinct
  from functional correctness). Two operations: `check` (mechanical pass — size
  vs. class exemplar median, forbidden-pattern scans, self-narration, citation
  integrity, fiction detection, cross-file fiction continuity) and `review`
  (mechanical + a fresh-context judgment critic). Runs as the pre-publish gate
  for public artifacts, and on-demand for any authored artifact class. Triggers
  on "/house-qa check <path>", "/house-qa review <path>", "does this belong",
  or as the publish-gate step before a skill/README/script ships.
user_invokable: true
---

# /house-qa

Domain expert for corpus conformance — whether authored work (a skill, a playbook, a README, a script) belongs in this estate's established corpus, independent of whether it works. Composes with `/lint-knowledge` (the sibling mechanical-pass architecture `qa.py` copies) and with the publish-gate flow (`publishing-workflow.md`) for anything shipping publicly.

## Identity

This skill owns ONE thing: validating that an artifact conforms to the corpus it's joining — the second, independent validation axis defined in corpus-conformance-methodology.md. Function is necessary and never sufficient; this skill checks belonging, not correctness.

- **Mechanical pass is `qa.py`** — read-only, no model, derives its size baseline from live exemplar files (never a hardcoded number); consumer repos can declare their own class corpus (see Cross-cutting § Class exemplars).
- **Judgment pass is a fresh-context critic** (`playbooks/review.md`) — grades against the class exemplars, weighs criticisms over confirmations, never self-grades the artifact it just wrote.
- **Grows by regression, never speculatively.** A new check is added only after a real classified failure produces a fixture (see `tests/`). Six checks are the current set — the sixth (cross-file fiction continuity) was added after a Wiki publication PII sweep found a real name still attached to a date its fictional replacement was already using elsewhere in the corpus. Do not add a seventh without a new failure to justify it.

## Intent

**Objective.** Without this skill, every session re-derives "does this look right" by vibes, at exactly the moment (shipping something new) when vibes are least reliable — the author just finished the thing and is primed to confirm it, not criticize it.

**Desired outcomes:**
1. Every artifact that ships publicly has run `check` at least once, findings triaged.
2. Every SIMPLIFY/REWORK verdict from `review` traces to a specific exemplar or methodology clause — never a bare aesthetic call.
3. The six mechanical checks stay 1:1 traceable to corpus-conformance-methodology.md clauses (canonical table: `qa.py`'s module docstring).

**Health metrics — must NOT degrade.**
- Zero false HIGH findings on `ticket-id-leak` / `roster-name-leak` / `vault-path-leak` — these are string-match checks; a false positive means the regex is wrong, not that the policy is wrong.
- `qa.py` never mutates a file — report only, same discipline as `lint.py`.
- The exemplar median is always read live from `linear` / `project-state` / `knowledge-layer` — never a hardcoded number that can drift from the corpus it describes.

**Strategic context.** The executable form of corpus-conformance-methodology.md, mirroring how `/lint-knowledge` executes structural-contract.md + tag-taxonomy.md. Where lint-knowledge governs the vault's knowledge layer, house-qa governs the *authored-artifact* corpus — skills, playbooks, READMEs, scripts.

**Constraints.**
- **Hard:** `qa.py` fails loud (non-zero exit) if tag-taxonomy-rosters.md or `../sample-universe/universe.md` is missing — a check silently no-op'ing because its data source vanished is worse than no check.
- **Steering:** the fiction-detection heuristic (CamelCase compounds + a small Council/Sync/Suite/... suffix list) has known gaps — a bare invented ALL-CAPS acronym won't be caught. WARNING severity by design: it feeds the judgment pass, it does not gate alone.

**Decision authority.**
- **Autonomous:** running `check`, reporting findings at their derived severity.
- **Escalate:** any SIMPLIFY/REWORK verdict from `review` — the critic recommends, the corpus owner (or calling session) decides whether to act.

**Stop rules.**
- Required reference file (rosters or sample-universe) missing → abort the whole run, do not partially check.
- Never fix a finding — this skill reports; the caller edits.

## Navigation

| Operation | Input | Output | How |
|---|---|---|---|
| **check** | One or more artifact paths | Findings: `{severity, check, file, detail, suggestion}` | `python3 qa.py <path> [<path> ...] --json --vault-root <vault-root>` |

**Repo-level targets default to `--git-tracked-only`.** Pass a directory and it walks every `*.md` on disk by default — including untracked scratch, `Evals/`, or other content never meant to ship. Add `--git-tracked-only` to scope to `git ls-files` instead; this is the documented default invocation whenever the target is a repo root, not a single artifact.
| **review** | One or more artifact paths + their class exemplars | Verdict per artifact: KEEP / SIMPLIFY / REWORK, with target size and the exemplar/clause it traces to | Load `playbooks/review.md` as the critic brief; run in a fresh context (not the authoring session) |

`check` is mechanical only — run it first, always. `review` is judgment — run it before any operator-facing ship decision; a same-session quick lint can skip straight to `check`.

## Cross-cutting

**Vault-root and reference files.** `qa.py` needs `--vault-root` (or the `VAULT_ROOT` env var) to locate the vault's Wiki/spec/tag-taxonomy-rosters.md, and defaults `--universe` to the sibling `../sample-universe/universe.md` in this repo. Both are read at runtime, never hardcoded.

**Class exemplars.** Auto-detected by convention (`SKILL.md` → `skill-md`; anything under `playbooks/` → `playbook`) and resolved live against `linear` / `project-state` / `knowledge-layer` — the audit-measured trio (SKILL.md median 108 lines; playbook median ~79). Consumer repos whose artifact classes don't match this corpus declare their own via a repo-root `.house-qa.json` (shape: `qa.py` § `repo_config_exemplars`). Resolution order per target: `--exemplars` CLI > repo-local config > built-ins; pass `--exemplars` for a class with no built-in baseline (e.g. `readme`).

**Findings feed judgment, not autofix.** Every mechanical finding is an input to the `review` pass or the operator's own read — never applied automatically.

## What this skill does NOT do

- Does NOT fix anything — `check` and `review` both report; the caller edits.
- Does NOT replace `/lint-knowledge` — that skill governs the vault knowledge layer; this one governs authored artifacts (skills, playbooks, READMEs, scripts).
- Does NOT mechanize structure conformance (Navigation-table presence, playbook-extraction triggers) — that's judgment-pass territory in `playbooks/review.md`, not built into `qa.py` tonight; no real failure motivated mechanizing it yet.
- Does NOT grow checks speculatively — a new check requires a new classified failure and a new fixture in `tests/`.

## References

- corpus-conformance-methodology.md — the contract this skill executes: `{workspace_root}/System/Knowledge/corpus-conformance-methodology.md`.
- `/lint-knowledge` — the sibling architecture; `../lint-knowledge/lint.py`'s runtime-contract-parsing pattern is what `qa.py` reuses.
- `../sample-universe/universe.md` — the canonical fictional-entity reference for the fiction-detection check.
- `tests/run_tests.py` — fixture suite; run before trusting any change to `qa.py`.
