# Playbook: project-updates (write path)

Write a Linear Project Update — the session-level memory artifact. Carries the body-shape contract, three-layer discipline, granularity test, length guidance, and health-field semantics.

**Load boundary:** this is the WRITE path. The REVIEW path (`project-updates-review.md`) is loaded ONLY by a fresh subagent invocation after the write completes. The write path NEVER loads the review file — that's the structural self-evaluation guard per `[[composable-skills-methodology]]`.

## Input

```yaml
project_id: <UUID>                # required
title: <string>                   # 1 short headline
items_worked: [<TEAM>-N, <TEAM>-M]     # bare IDs, no markdown links — read via MCP
what_was_done: [<bullet>, ...]    # 3-7 dense bullets, file paths + decisions inline
decisions_made: [<bullet>, ...]   # non-obvious decisions only, with rationale + rejected alternatives
health: onTrack | atRisk | offTrack
```

## Protocol

1. **Validate body shape** (fail loudly if violated):
   - Title present and non-empty.
   - `items_worked` present (may be empty for pure-knowledge sessions).
   - `what_was_done` has 3-7 bullets unless the session is genuinely routine (then 1-3 acceptable).
   - `decisions_made` may be empty; if present, each item must include rationale.
   - `health` ∈ valid enum.

2. **Validate three-layer separation** (fail with specific guidance if violated). Concrete reject triggers:
   - **Task-level mechanic** in any `what_was_done` bullet — reject if bullet matches the pattern: file-by-file edits ("modified file X, then file Y"); enumerated tool calls ("called linear_updateIssue, then linear_createComment"); MCP query mechanics ("queried X with parameters Y"); per-step debug narrative ("first I tried X, that failed, then Y"). The project-level rewrite ("migrated all backlogs to Linear" vs. "exported backlog.json, mapped enum, validated counts, archived source") is the test. Fail with the granularity example.
   - **"What's next" framing** — reject any section, header, or bullet whose content is generic forward-looking planning. Patterns: bullets starting with "Next session...", "Up next:", "TODO:", "Will:", any "## What's next" / "## Next steps" / "## Going forward" section. Linear active issues ARE the queue; the CLAUDE.md Re-entry Cue is the orientation. Fail with the three-layer table.
   - **Loose Threads / Provisional category** — reject any bullet category labeled "loose threads", "provisional", "ideas", "follow-ups to consider", "maybe", "things to think about", or equivalent. Provisional thoughts go in CLAUDE.md Current State (decays on overwrite); shaped-actionable thoughts get filed as low-priority Linear issues. Fail with the decay-vs-issue framing.

   **ALLOWED (not "What's next"):** a `**Still open**` / `**Remaining for this arc**` / `**Open acceptance gates**` section documenting incompleteness WITHIN the scope of what the session actually worked on. This is session-level information ("this session advanced X but didn't complete Y within X's scope"). The distinction from "What's next":
   - **Rejected** (forward planning): "Next session we'll tackle <TEAM>-N" — <TEAM>-N wasn't worked on this session; it's queue duplication.
   - **Allowed** (arc incompleteness): "**Still open:** <TEAM>-N — <TEAM>-M's acceptance gate, calibration workflow + 4-test verification" — <TEAM>-N is a sub-ticket of work the session pushed on (<TEAM>-M); the section documents what remained unfinished within the arc this session advanced.

   The test: does the item belong to the same arc/parent as the items the session moved Done? If yes, "Still open" is allowed. If no, it's forward planning — reject.

3. **Compose the body** into the Linear Project Update markdown:

```markdown
## {{title}}

**Items worked:** {{items_worked joined by ", "}}

**What was done:**
- {{bullet 1}}
- {{bullet 2}}
...

**Decisions made:**
- {{decision 1}}
- {{decision 2}}
...
```

Omit `Decisions made:` section entirely if `decisions_made` is empty.

4. **Call** `mcp__linear-tactic__linear_createProjectUpdate` with `projectId`, the composed `body`, and `health`.

5. **Return** the created update's ID + URL.

## Output

```yaml
update:
  id: <uuid>
  url: <linear URL>
  health: <value>
  warnings: [<string>, ...]    # if any non-fatal warnings emitted during validation
```

## Body shape — the discipline

Audience: future-me reading via MCP query, not a human browsing the UI. Dense, scannable, references inline.

**Length:** ~15-25 lines for substantial sessions; ~5-10 for routine work. Length earns itself from session magnitude.

**Granularity test for "What was done" bullets:**
Project Update bullets are at *project-level* granularity — they answer "what shifted in the project's overall state this session." Issue comments are at *task-level* granularity — they answer "what happened on this specific task."

Example:
- **Project Update bullet (right):** "Migrated all 9 project backlogs to Linear; pre-cutoff records frozen as `*-archive` files."
- **Issue comment (right):** "Exported `<project>/backlog.json` (47 items), mapped status enum to Linear states, validated count match before archiving source."

If a piece of content fits both granularities, it's a level-of-detail problem — split it: project-level summary in the Update, task-level mechanics in the comment (via `/linear` issue-management `comment` action).

## Three-layer memory enforcement (in this playbook)

| Layer | Lives on | Holds |
|---|---|---|
| Item-level memory | Linear issue description + comments | What this task is, decisions specific to it, resolution context |
| **Session-level memory** | **Project Update (this playbook)** | **What was done this session and why — frozen historical record** |
| Re-entry / queue | CLAUDE.md Re-entry Cue + Linear active issues | "What was I in the middle of" + the active work queue |

If a decision belongs to one issue, write it on the issue via `issue-management.md` (`comment` or `update_description` action) — NOT here.

## Health field semantics

- **onTrack** — no blocked decisions; no piling Waiting items; trajectory matches plan.
- **atRisk** — Waiting/Decisions Needed sections in CLAUDE.md grew this session; trajectory in question but not derailed.
- **offTrack** — major direction shift or critical blocker landed; trajectory needs explicit re-direction.

## Anti-patterns to reject (return error, do not write)

These would create progress.md sprawl in a different layer — the architecture exists to prevent that.

1. **"What's next" / "Next steps" sections.** Reject. Active queue is in Linear issues; orientation is in CLAUDE.md Re-entry Cue.
2. **"Loose Threads" / "Provisional" bullet category.** Reject. Provisional thoughts go in CLAUDE.md Current State (decays on overwrite); actionable thoughts get filed as low-priority Linear issues.
3. **Task-level mechanics in `what_was_done`.** Reject with the granularity-test guidance — caller can split into issue comments + Project Update bullets.

## What this playbook does NOT do

- Does NOT auto-compose body content from session activity — the caller composes; this playbook validates and writes.
- Does NOT review the written content — that's `project-updates-review.md`, invoked as a subagent by the orchestrator after the write.
- Does NOT write to CLAUDE.md (that's `/project-state` write).
- Does NOT update issues (that's `issue-management.md`).
