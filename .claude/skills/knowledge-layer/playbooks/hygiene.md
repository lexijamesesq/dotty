# Playbook: hygiene

Scan a list of touched knowledge/reference docs for the seven anti-patterns. Apply current-context fixes directly; defer out-of-scope refactors to Linear issues; escalate ambiguous pattern-matching cases to the `hygiene-review` subagent.

**Load boundary:** this is the SCAN+FIX path. `hygiene-review.md` is the REVIEW path for ambiguous cases — invoked as a fresh subagent, never loaded here.

## Input

- `docs` — list of doc paths to scan (typically `git diff --name-only` for git-tracked + tool-call-history files for vault-only)
- `current_context_systems` — list of systems/topics the current session has substantive context for (informs current-context-fix vs. defer classification)

## The seven anti-patterns

| # | Pattern | Detection signal |
|---|---|---|
| 1 | **Appendix syndrome** | Dated section headers appended ("Extended Research: 2026-05-23", "Update: 2026-04-12") instead of integration into existing structure |
| 2 | **Duplicate structures** | Tables, lists, or sections that repeat earlier content with additions rather than updating the original |
| 3 | **Historical framing** | Language about how/when research was conducted ("Last session I found...", "This session's investigation revealed..."). Exception: methodology/provenance markers ("Analysis used X framework") are fine |
| 4 | **Progress-log bleed** | Session numbers, dated entries ("Session 4 findings:"), or "what was done" language in a doc that should present timeless current knowledge |
| 5 | **Unbounded growth** | Doc exceeds ~300 lines without clear structure, OR sections that have grown significantly without consolidation |
| 6 | **Stale content** | Findings contradicted or superseded by recent work that weren't updated in place (best-effort detection — what's obviously stale) |
| 7 | **Orphaned sections** | Content no longer connected to active project concerns — not wrong, just dead weight |

## Protocol

For each doc in `docs`:

1. **Read the doc** (frontmatter + body).
2. **Run pattern checks** in order. For each pattern hit:
   - **Unambiguous hit + current-context-fix scope:** fix directly. Examples: a dated "Extended Research" section can be merged into the main body; obvious progress-log bleed can be stripped; clearly stale content (a finding the current session contradicted) can be replaced.
   - **Unambiguous hit + out-of-scope scope:** file as a Linear issue describing what needs consolidation. Use `/linear` issue-management with action=`create_followup`, project=current project, priority=Low, description naming the doc + the pattern + what needs to happen.
   - **Ambiguous pattern-match:** add to `for_review` list. The orchestrator spawns a `hygiene-review` subagent per ambiguous doc.
   - **No hit:** continue.

3. **Classification is by current-context-availability, NOT by line count.** Per session-closeout's Step 6 discipline:
   - You have current-context for systems you authored or modified this session — fix regardless of size. The keystrokes are the cost; deferring rebuilds the context later.
   - Out-of-scope = genuinely separate scope (different system, different domain, requires independent research you didn't do this session). A 5-line edit to a system you don't understand may still belong as a Linear issue.

## Output

```yaml
docs_scanned: <count>
fixes_applied:
  - doc: <path>
    pattern: <number + name>
    fix: <one-line description>
deferrals_filed:
  - doc: <path>
    pattern: <number + name>
    linear_issue: <new issue ID>
for_review:
  - doc: <path>
    pattern: <number + name>
    ambiguity: <why this isn't a clear hit>
```

## Discipline notes

- **Reference docs represent current understanding in a single coherent pass.** This is the principle the seven patterns enforce. Chronological discovery belongs in Linear Project Updates and git history.
- **Do not modify docs referenced by projects outside the current session scope** without flagging to the user. The `current_context_systems` input is the scope filter.
- **Skip CLAUDE.md, progress.md / progress-archive.md, backlog.json, backlog-archive.json** — those are not knowledge/reference docs (handled in their own steps).

## When to defer vs. fix (the classification primitive)

The wrong primitive is line count. The right primitive is **whether you have current session context sufficient to do the work correctly.**

- Authored or modified the documented system this session → current context → FIX (any size).
- Did not touch the system this session, mechanical translation possible → still FIX if the work is mechanical (e.g., reformat dated headers into integrated content); defer if it requires interpretation.
- Did not touch the system this session, requires interpretation → DEFER (file Linear issue).
- Unsure if you have sufficient context → ESCALATE via `for_review` (subagent decides with clean context).

## What this playbook does NOT do

- Does NOT scan CLAUDE.md files (out of scope; handled by `/project-state` write discipline + caller responsibility).
- Does NOT scan Linear Project Updates (those are session-level memory; anti-patterns are knowledge-doc-specific).
- Does NOT do periodic full-corpus scanning (that's `/lint-knowledge`).
- Does NOT silently fix anything across out-of-session-scope projects.
