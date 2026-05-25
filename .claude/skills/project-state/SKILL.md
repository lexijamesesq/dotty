---
name: project-state
description: CLAUDE.md Project State expert — read and write the structured Project State + Intake sections (Re-entry Cue, Current State, Waiting For, Decisions Needed, Linear Project ID). Invoked by /session-start, /session-closeout, and the future /mid-session-checkpoint. Triggers on "/project-state read", "/project-state write", or programmatic invocation.
---

# /project-state

Domain expert for the CLAUDE.md Project State + Intake sections. Carries the field semantics, Re-entry Cue discipline, and three-layer memory boundaries that determine what belongs in CLAUDE.md vs. on a Linear issue vs. in a Project Update.

## Identity

This skill owns ONE thing: the structured state that lives in a project's `CLAUDE.md` — the orientation layer of the three-layer memory model (`CLAUDE.md` = orientation, Linear issues = item-level, Linear Project Updates = session-level). Reading and writing it correctly is what makes session resumption cheap.

The discipline rules that apply to every invocation:

- **Re-entry Cue is ONE sentence.** The single most important field. Future-Claude reads it first. No padding, no multi-sentence elaboration. References the active Linear issue or specific next-action.
- **No "Recent Changes" section.** Linear Project Updates and git history are the timeline; CLAUDE.md is not.
- **Provisional thoughts go in Current State paragraph** (which gets overwritten next session, so unprosecuted ideas decay naturally). Shaped-actionable thoughts get promoted to a Linear issue instead.
- **Three-layer separation:** item-level decisions go on the issue (NOT in CLAUDE.md); session-level narrative goes in Project Updates (NOT in CLAUDE.md); orientation + re-entry goes here.
- **Linear Project ID is the UUID, not the URL slug.** Required field; do not fall back to project-name lookup (pre-cutoff fallback retired 2026-05-24).

## Intent

**Objective.** Without this skill, every consumer (session-start, session-closeout, mid-session-checkpoint, new-project, future orchestrators) would parse and write CLAUDE.md Project State + Intake by hand, re-implementing field semantics + Re-entry Cue discipline + three-layer memory boundaries. Errors compound: a multi-sentence Re-entry Cue here, a missing field there, inconsistent formatting that breaks future parsers. This skill is the single source of CLAUDE.md structured-state truth.

**Desired outcomes** (observable):
1. Every read returns structured fields the caller can use without re-parsing.
2. Every write enforces Re-entry-Cue-one-sentence + per-field replace (preserve everything else) + field semantics.
3. CLAUDE.md-domain anti-patterns (Recent Changes / dated changelog content in Current State) get surfaced as structured WARNINGs the orchestrator can act on.
4. Scope boundary clarity — Project State + Intake read is this skill; Linear ops and Knowledge ops are routed to their domain experts.

**Health metrics — must NOT degrade.**
- Re-entry Cue one-sentence invariant (validated pre-write; fail loudly on violation).
- Per-field replace preserves everything else in the file (no full-file rewrites).
- Scope boundary holds (no Linear-domain or Knowledge-domain leak into this skill's playbooks).

**Strategic context.** Domain expert for the structured state in CLAUDE.md — the orientation layer of the three-layer memory model from `[[sustained-autonomous-agentic-workflows]]`. Smallest of the three domain skills; mechanical operations only (no subjective writes, no load-boundary-as-guard required).

**Constraints.**
- **Hard:** Re-entry Cue must be one sentence (write playbook fails on multi-sentence). Pre-cutoff fallbacks retired — missing Project ID is a data error, NOT a trigger for name-lookup. Intake writes are scope-deferred (today: `/new-project` owns initial creation; future: extract `intake-write.md` playbook when second consumer emerges).
- **Steering:** "Recent Changes" content in `current_state` warned but not refused — caller has authority on content judgment; this skill enforces format, not content gatekeeping.

**Decision authority.**
- **Autonomous:** all read parsing; per-field replace logic; Re-entry Cue validation (regex sentence count); WARNING emission for anti-pattern detection.
- **Escalate:** CLAUDE.md missing at resolved path → return null with clear error string; hub (not project) returned → caller decides whether to recurse; missing Project State section in non-hub → flag explicitly as data error.

**Stop rules.**
- CLAUDE.md not found at resolved path → fail with clear error.
- Re-entry Cue multi-sentence on write → fail; caller must collapse before re-invoking (no auto-truncate, no silent acceptance).
- Type = hub when caller wanted project state → return type:hub with minimal structure; caller decides whether to recurse.

## Navigation

Per invocation, identify the operation and load the matching playbook:

| Operation | Input | Output | Playbook |
|---|---|---|---|
| **read** | `project_root` (abs path) OR `"cwd"` OR project name to resolve under `workspace_root` | Structured: `re_entry_cue`, `current_state`, `waiting_for`, `decisions_needed`, `last_updated`, `linear_project_id`, `linear_project_url`, `capture_note_path`, `knowledge_layer_declared`, `knowledge_index_path`, `type` (`project` vs. `hub`) | `playbooks/read.md` |
| **write** | `project_root` + at least `re_entry_cue` and `last_updated`; any of `current_state`, `waiting_for`, `decisions_needed` optional | Mutation: `CLAUDE.md` edited in place; `fields_updated` list returned | `playbooks/write.md` |

## Cross-cutting (applies to both operations)

**Project resolution.** When input is `"cwd"`, walk up from the current working directory until finding a `CLAUDE.md` whose frontmatter `tags` contains `type/claude-project` or `type/claude-hub`. When input is a project name, append to `workspace_root` (path configured in global CLAUDE.md > Configuration > `workspace_root`). When input is an absolute path, use directly. Fail with a clear error if no `CLAUDE.md` exists at the resolved path.

**Hub vs. project.** If the resolved CLAUDE.md has frontmatter tag `type/claude-hub` (not `type/claude-project`), return `type: hub` and let the caller decide whether to recurse to a sub-project. Hubs do not have Project State sections.

**No pre-cutoff fallbacks.** All projects are on Linear as of 2026-05-09 (universal cutoff). If `linear_project_id` is missing from a CLAUDE.md's Intake, that's a data error — surface it; do not fall back to `linear_getProjects` name-match.

## What this skill does NOT do

- Does NOT write to Linear (that's `/linear`).
- Does NOT scan Knowledge layer (that's `/knowledge-layer`).
- Does NOT make decisions about what the Re-entry Cue should *say* — the caller composes the cue's content; this skill enforces the format (one sentence) and field placement.
- Does NOT manage the Capture Note buffer (returns its path if declared, but processing is the caller's responsibility — see follow-up ticket for future extraction (when a second consumer emerges)).

## Scope boundary: Intake section writes

This skill's `read.md` parses BOTH the Project State section AND the Intake section. But `write.md` only writes Project State, NOT Intake. This is intentional scope today, with a known extension hook:

- **Today's owner of Intake writes:** `/new-project` (creates the whole CLAUDE.md from template, including Intake, on initial project creation). No other consumer mutates Intake.
- **Future extension:** if a second consumer needs to mutate Intake (e.g., updating `**Project ID:**` after a Linear project rename, adding a `**Capture Note:**` reference mid-project-life), add `playbooks/intake-write.md` here. Same navigator pattern; the domain ownership stays with `/project-state`.

This is a YAGNI deferral, not a domain split. `/project-state` owns the CLAUDE.md structured-state domain; Intake writes belong here when a consumer warrants them.

## References

- Project template (the structure being read/written): path configured in global CLAUDE.md > Configuration > `templates.project`
- `[[linear-discipline]]` — three-layer memory model
- `[[sustained-autonomous-agentic-workflows]]` — Seven Components of Intent (the "Project State" structure is the agent-memory layer of state-through-artifacts)
