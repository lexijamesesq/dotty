# Playbook: hub-cross-ref

For a project under a hub, detect whether the current session's findings touch topics covered by hub-level Knowledge pages. Surface overlaps so the orchestrator can decide to update hub docs or flag for follow-up.

## Relationship to `/lint-knowledge`

`/lint-knowledge` runs hub cross-reference as part of its periodic full-corpus judgment pass — across ALL findings in the scope, on its own cadence. This playbook runs hub cross-reference per-session — scoped to what THIS session changed, before the next periodic lint run.

Both implementations exist deliberately:
- **`/lint-knowledge`'s periodic pass** is the safety net — catches drift across the whole corpus on cadence.
- **This per-session playbook** is the proactive surface — catches the hub overlap at the moment of writing, while the operator has current context. Avoids the cost of remediation later.

If the two implementations drift, this playbook is canonical (it's the structured per-operation contract). `/lint-knowledge`'s periodic step should reference this playbook's relationship enum and suggested-action set rather than reimplementing them. A future consolidation could collapse the duplication by having `/lint-knowledge` delegate to this playbook for the hub-cross-ref step.

## Input

- `topics` — list of topics the current session's findings touched (the caller derives this from what was modified/synthesized)
- `hub_knowledge_index_path` — absolute path to the hub's `Knowledge/index.md`
- `current_findings_summary` — short description of what the session concluded (for matching against hub-doc summaries in the index)

## Protocol

1. **Read the hub's Knowledge index.** Parse listed pages with their summary lines.

2. **Match topics against hub doc summaries.** For each session topic, scan the index for hub docs whose title or summary references the same concept. Be inclusive — a session topic of "Linear archive policy" matches a hub doc about "ticket lifecycle management" even if the exact words differ.

3. **For each match, read the hub doc** (frontmatter + body) and assess:
   - Does the current session's findings WHOLLY REPLACE the hub doc's content on this topic (the hub doc's content is now obsolete)? → flag as `supersedes`.
   - Does the current session's findings CONTRADICT the hub doc's content (disagreement on a specific point)? → flag as `contradicts`.
   - Does the current session's findings ADD substantively beyond what the hub doc has (no disagreement, just more)? → flag as `extends`.
   - Does the current session's findings reproduce what the hub doc already says? → flag as `redundant` (no action needed; just informational).

4. **Return findings.** The orchestrator decides what to do (direct update vs. file follow-up vs. inform operator).

## Output

```yaml
matches:
  - hub_doc_path: <abs-path>
    matched_topic: <topic from input>
    relationship: supersedes | contradicts | extends | redundant
    summary: <one-line description of the overlap>
    suggested_action: update_directly | file_followup | inform_only
```

## Valid relationship × action combinations

| Relationship | Allowed actions |
|---|---|
| `supersedes` | `update_directly` (preferred when current-context fix available), `file_followup` (when out-of-scope) |
| `contradicts` | `update_directly` (clear, trivial fix), `file_followup` (anything non-trivial). **NOT `inform_only`** — a contradiction left in the corpus rots; the orchestrator must take an action. |
| `extends` | `update_directly`, `file_followup`, `inform_only` (all valid depending on substantiveness) |
| `redundant` | `inform_only` (default) |

Surface the relationship + a default-action; let the orchestrator override with operator input if needed. But the playbook must NOT return `contradicts + inform_only` — that combination is invalid; downgrade to `file_followup` as the minimum action.

## Discipline

- **Be inclusive in matching, conservative in suggested actions.** Surface possible overlaps generously; recommend direct updates only for clear contradictions or trivial additions.
- **Hub docs are typically more cross-cutting than project docs.** A small project finding may not justify updating a hub doc that synthesizes across multiple projects — surface as `extends` with `suggested_action: file_followup` rather than `update_directly`.
- **Don't auto-edit hub docs in this playbook.** Even for clear contradictions, surface the recommendation; the orchestrator (and ultimately the operator) decides whether to update directly or file the follow-up.

## When to skip this playbook

- Project is NOT under a hub (orchestrator can detect this from CLAUDE.md frontmatter — no parent hub declared).
- Hub has no `Knowledge/` folder (no shared knowledge to cross-reference against).
- Session's findings are tightly scoped to this project's internals (e.g., a specific component refactor with no broader pattern emergence).

## Output handling for the orchestrator

- `update_directly` → orchestrator may invoke a direct edit on the hub doc (with current-context discipline).
- `file_followup` → orchestrator invokes `/linear` issue-management `create_followup` with the hub-doc-update task, project = hub's project, priority = Low/Normal depending on whether the contradiction blocks anything.
- `inform_only` → orchestrator surfaces in closeout summary; no action.

## What this playbook does NOT do

- Does NOT modify hub docs (read-only + recommend).
- Does NOT decide what's a "topic" — caller derives the topic list from session context.
- Does NOT scan beyond the immediate hub (multi-hop relationships — hub-of-hubs — are out of scope).
