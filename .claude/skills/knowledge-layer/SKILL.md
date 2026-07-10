---
name: knowledge-layer
description: Knowledge layer expert — freshness scan, hygiene anti-pattern detection, query-and-file with structural envelope + filing-time lint gate integration, index sync, hub cross-reference. Invoked by /session-closeout (hygiene + filing + index sync) and /session-start (freshness scan). Triggers on "/knowledge-layer <operation>" or programmatic invocation.
---

# /knowledge-layer

Domain expert for the Knowledge layer — project-local `Knowledge/` subfolders and the `System/` flat root. Carries the knowledge-contract Part II envelope, handoff-contract enforcement points, seven-anti-pattern hygiene rules, and index-sync discipline.

## Identity

The Knowledge layer is the vault's reusable-synthesis surface — methodology docs, implementation specs, reference content. This skill owns operations on that surface: detecting staleness, scanning for anti-patterns, enforcing the structural envelope when filing new pages, keeping indexes in sync, and surfacing cross-references with hub-level knowledge.

Discipline rules applied on every invocation:

- **Knowledge docs represent current understanding in a single coherent pass.** Chronological discovery belongs in Linear Project Updates and git history, not in knowledge docs.
- **Structural envelope required for any new `type/knowledge` page:** full Invariant Core (`type/knowledge` tag, scope tag, `status/active`, `updated: YYYY-MM-DD`, single `# Title` H1) + `sources` frontmatter (provenance) + `topic/` tag(s) for Wiki-hosted pages.
- **The filing-time lint gate is the structural gate.** New Knowledge pages must PASS (zero HIGH findings) via `lint.py --filing` before counted complete — a deterministic check, not a fresh-context judgment gate (validation-discipline's narrow exemption; unlike `/linear`'s project-updates-review, which stays a subagent review).
- **Index sync is a process obligation, not a structural property.** After creating/renaming/deleting pages, the corresponding `Knowledge/index.md` (or root `index.md` for flat variants) must reflect current state.

## Intent

**Objective.** Without this skill, knowledge-doc hygiene + structural envelope enforcement + filing-time lint gate integration + index sync would either live inline in session-closeout (carrying ~80 lines of domain expertise) or get reimplemented across consumers. The seven anti-patterns would drift, the structural envelope would be inconsistently enforced, indexes would silently rot, and the filing-time lint gate would get bypassed.

**Desired outcomes** (observable):
1. Every Knowledge page filed via `query-and-file` satisfies the full structural envelope (Invariant Core + Provenance + Destination Modifiers) before counted complete (the filing-time lint gate confirms).
2. Hygiene anti-pattern scan applies the operator's seven-pattern taxonomy uniformly to every touched doc.
3. Ambiguous hygiene cases get fresh-context review via subagent (load-boundary-as-guard); never self-evaluated in the scan path.
4. Knowledge indexes reflect on-disk reality after every mutation pass (no silent index drift).
5. Hub-level Knowledge gets cross-referenced when sub-project work touches hub topics (surfaces overlap via `supersedes` / `contradicts` / `extends` / `redundant` enum).

**Health metrics — must NOT degrade.**
- Structural-contract envelope fully enforced (full Invariant Core including `status/active`, not subset).
- Load-boundary-as-guard for hygiene write/review split: scan path NEVER loads review playbook.
- Filing-time lint gate: zero HIGH findings required before page counted complete (fix-and-recheck iteration cap 3).
- Non-overlap with `/lint-knowledge`: this skill is per-session/per-operation; `/lint-knowledge` is periodic full-corpus. Shared anti-pattern definitions; canonical implementation here.

**Strategic context.** Domain expert for the Knowledge layer across project-local `Knowledge/`, `System/` flat root, and `{workspace_root}/Wiki/Knowledge/`. Carries the enforcement points of the estate's structural, filing-handoff, and knowledge-contract Part IV contracts (published in the companion wiki repo's `spec/`) at per-session granularity. One of three domain skills; the most complex due to subjective hygiene judgment requiring load-boundary structural guard.

**Constraints.**
- **Hard:** The filing-time lint gate must PASS (zero HIGH findings) before any new page counted complete. Structural envelope is the full Invariant Core (not subset). Hygiene-review subagent invoked with fresh context (scan path never loads review playbook). `contradicts` relationship in hub-cross-ref MUST NOT use `inform_only` action (minimum `file_followup`).
- **Steering:** Hygiene classification (current-context-fix vs. defer) by current-context-availability, NOT line count. Anti-pattern detection uses inclusive matching (flag possible hits as ambiguous; let subagent rigor-check).

**Decision authority.**
- **Autonomous:** freshness scans; mechanical hygiene fixes within current-context scope; index sync; structural envelope composition for new pages; the filing-time lint gate run + fix-and-recheck cycle within cap.
- **Escalate via subagent:** ambiguous hygiene patterns → spawn `hygiene-review` with fresh context.
- **Escalate via Linear issue:** out-of-scope hygiene refactors → file via `/linear update issues create_followup`.
- **Escalate to operator:** the filing-time lint gate FAIL after 3 iterations (page exists but not counted complete); out-of-session-scope docs needing modification → flag, don't modify; hub-cross-ref findings classified `update_directly` for clear contradictions → surface for operator visibility before update lands.

**Stop rules.**
- lint.py unavailable (script missing or errors) → surface to caller; do not proceed without gate.
- The filing-time lint gate FAIL after 3 iterations → escalate (page on disk, not counted complete).
- Out-of-session-scope project doc modification attempted → halt; flag to operator.
- Hygiene-review subagent FAIL after 3 iterations per doc → surface with full finding list; do not silently fix.

## Navigation

Per invocation, identify the operation and load the matching playbook:

| Operation | Input | Output | Playbook |
|---|---|---|---|
| **freshness** scan | Knowledge index path + optional `threshold_days` (default 90) | Stale pages list + orphans list | `playbooks/freshness.md` |
| **hygiene** scan | List of touched doc paths | Fixes applied (current-context) + items flagged (defer) + ambiguous-pattern items for review subagent | `playbooks/hygiene.md` |
| **hygiene-review** (subagent-only) | Doc path + anti-pattern definitions | Per-doc verdict (PASS/FAIL/REVISE) | `playbooks/hygiene-review.md` |
| **query-and-file** | Synthesis draft + destination class (project-hosted / Wiki-hosted) | Filed page with the filing-time lint gate PASS confirmed | `playbooks/query-and-file.md` |
| **hub-cross-ref** | Topic + hub Knowledge index path | Cross-ref findings + suggested updates | `playbooks/hub-cross-ref.md` |
| **scope-lint** | Session-touched vault paths + session-created subset | Inline envelope fixes on session-created files; other findings queued via `/queue create-item` (disposition) | `playbooks/scope-lint.md` |
| **index-sync** | Knowledge folder path | Index reconciled with files on disk | `playbooks/index-sync.md` |

## Cross-cutting

### Structural envelope (the bar for `type/knowledge` filing)

Every `type/knowledge` page must have (full Invariant Core per `[[knowledge-contract]] Part II`):
- **Frontmatter `tags`:** `type/knowledge`, scope tag (`project/<name>` for project-hosted; `area/<hierarchy>` for Wiki-hosted), `status/active`.
- **Frontmatter `updated`:** `YYYY-MM-DD`.
- **Frontmatter (Wiki-hosted modifier):** `topic/<topic>` tag(s) required ≥1; optional for project-hosted.
- **Frontmatter:** `sources` required for `type/knowledge`. Use Provenance vocabulary: `AI research YYYY-MM-DD` for session-derived synthesis; `user-stated` for user-provided facts.
- **Body:** single `# Title` H1; no `## Original Capture` section (provenance lives in frontmatter `sources`).

The `query-and-file` playbook enforces this pre-filing; the filing-time lint gate confirms post-filing.

### Destination class

- **Project-hosted:** `Projects/*/Knowledge/` or `{workspace_root}/System/Knowledge/`. Scope tag: `project/<name>`.
- **Wiki-hosted:** `{workspace_root}/Wiki/Knowledge/`. Scope tag: `area/<hierarchy>` + `topic/<topic>` tag(s) required.

Callers pass `destination_class`; the playbook routes to correct path conventions + validator invocation.

## Load-boundary-as-guard

`playbooks/hygiene.md` is the SCAN+FIX path. `playbooks/hygiene-review.md` is the REVIEW path for ambiguous pattern-matching cases. The hygiene scan path NEVER loads the review file. Review is reachable only as a fresh subagent invocation per ambiguous doc, given the doc + the anti-pattern definitions, with no context about other docs scanned or the closeout's session-level reasoning.

Same pattern as `/linear`'s project-updates write/review split. Same structural guard.

## What this skill does NOT do

- Does NOT read or write CLAUDE.md (that's `/project-state`).
- Does NOT touch Linear (that's `/linear`).
- Does NOT do periodic full-corpus scanning — that's `/lint-knowledge` (separate skill, runs on its own cadence). The two share anti-pattern definitions; `/lint-knowledge` is the periodic mode, this skill is the per-session mode.
- Does NOT decide whether a session produced synthesis worth filing — the caller (typically session-closeout's query-and-file decision) makes that call; this skill files what's handed to it.

## References

- `[[knowledge-contract]] Part II` — the full Invariant Core + Destination Modifiers (cited by `query-and-file.md`).
- `[[knowledge-contract]] Part III` §4 (session-closeout query-and-file) — the handoff this skill enforces.
- `[[knowledge-contract]] Part IV` — what `/lint-knowledge` periodic scan covers; reference for non-overlap with this skill.
- `[[knowledge-integrity-methodology]]` — the why behind the structural/handoff/lint contracts.
