---
name: session-closeout
description: >
  Triggers when the user says "Close out this session for [project]", "Session closeout",
  "Close this session", or similar closeout phrases. Also triggers on "/session-closeout".
user_invokable: true
---

# Session Closeout Protocol

Preserve project state for future session resumption. For long-running projects with state to track. Skip for single-session or simple tasks.

## Instructions

When this skill triggers, identify the **project** from the user's message or the current working context, then execute the following steps.

### Step 1: Assess Current Project State

Review what happened this session:

- What's operational? What's broken? What's in progress?
- What changed this session that affects project status?
- Were any decisions made that should be recorded?

### Step 2: Update the Project's CLAUDE.md

Edit the **Project State** section:

- **Last Updated:** Set to today's date
- **Re-entry Cue:** One sentence — what was I in the middle of? This is the single most important field for session resumption. Write it as if answering "what should I pick up next time?"
- **Current State:** Update component statuses if anything changed
- **Waiting For:** Add/remove external blockers as applicable
- **Decisions Needed:** Add/remove questions blocking progress

For the expected structure, see the project template (path configured in global CLAUDE.md > Configuration > `templates.project`).

### Step 3: Update the Backlog

If the project uses a backlog JSON file:

- Mark completed items as `"status": "complete"`
- Update subtask completion: set `"done": true` for finished subtasks
- Add any new items discovered during the session
- Set `assigned_session` on items worked

### Step 4: Archive Completed Backlog Items

If the active backlog contains completed items:

1. Read the archive file if it exists (typically `{name}-backlog-archive.json`), or prepare to create it
2. Move completed items from the active backlog to the archive
3. Write the archive file with schema:
   ```json
   {
     "project": "project-name",
     "last_archived": "YYYY-MM-DD",
     "items": [...]
   }
   ```
4. Remove completed items from the active backlog — it should retain only pending and in-progress items
5. Update `last_updated` in the active backlog

### Step 5: Append to Progress Log

Add a new entry to the progress log (typically `*-progress.md`):

```markdown
## Session N — YYYY-MM-DD

**Items worked:** [backlog IDs]

**What was done:**
- [Key accomplishments]

**Decisions made:**
- [Key decisions with rationale]

**What's next:**
- [Immediate next steps for next session]
```

Determine the session number by incrementing from the last entry in the log.

### Step 6: Check for Scope Changes

- Did the project scope expand or change this session?
- If yes, update the project description at the top of CLAUDE.md (the 1-3 sentence description)
- This is critical for capture triage — the inbox router uses project descriptions to match captures to destinations

### Step 7: Knowledge Doc Hygiene Check

Check whether knowledge/reference docs need cleanup based on this session's work. This is a safety net for integration that should happen during the session but sometimes doesn't.

**Identify candidates:** For git-tracked projects, check `git diff --name-only`. For vault-only projects, review tool call history for files read or edited this session. Focus on reference material (guides, specs, methodology docs, research syntheses) — skip progress logs, backlogs, and CLAUDE.md files (handled in other steps).

**Scan each candidate for these anti-patterns:**

1. **Appendix syndrome** — Dated sections appended to the end ("Extended Research: YYYY-MM-DD") instead of integrating new content into existing structure
2. **Duplicate structures** — Tables, lists, or sections that repeat earlier content with additions rather than updating the original
3. **Historical framing** — Language about how/when/why research was conducted — belongs in progress logs, not reference docs. Exception: methodology/provenance statements that serve as validity markers ("Analysis used X framework") are fine.
4. **Progress-log bleed** — Session numbers, dated entries, or "what was done" language in a doc that should present timeless current knowledge
5. **Unbounded growth** — Doc exceeding ~300 lines without clear structure, or sections that have grown significantly without consolidation
6. **Stale content** — Findings contradicted or superseded by this session's work that weren't updated in place (best-effort — catch what's obvious)
7. **Orphaned sections** — Content no longer connected to active project concerns — not wrong, just dead weight

**Actions:**
- **Straightforward fixes** (<~20 lines of change — stale paragraph, duplicate table, historical preamble): fix directly
- **Structural issues** (full reorganization, appendix integration, or changes exceeding ~20 lines): add a backlog item describing what needs consolidation
- **Uncertainty** (unclear if content is stale or historical): flag to user in closeout summary, don't modify

Do not modify docs referenced by projects outside the current session scope without flagging to the user.

**Principle:** Reference docs represent current understanding in a single coherent pass. Chronological discovery belongs in progress logs and git history.

### Step 8: Final Verification

Before finishing, verify:

- **Re-entry Cue** answers "what was I in the middle of?" in one sentence
- **Pending backlog items** are each immediately executable (no interpretation needed)
- **No stale content in CLAUDE.md** — remove resolved blockers, answered decisions, completed items (reference doc staleness is handled in Step 7)
- **No "Recent Changes" section** — file system and progress log are the history

### References

- Full template: path configured in global CLAUDE.md > Configuration > `templates.project`
- Design philosophy: path configured in global CLAUDE.md > Configuration > `references.protocols`
