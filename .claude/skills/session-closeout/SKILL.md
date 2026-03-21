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

For the expected structure, see `~/Vaults/Notes/Claude/System/project-claude-template.md`.

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

### Step 7: ADHD-Optimized Principles

Before finishing, verify:

- **Re-entry Cue** answers "what was I in the middle of?" in one sentence
- **Pending backlog items** are each immediately executable (no interpretation needed)
- **No stale content** — remove resolved blockers, answered decisions, completed items
- **No "Recent Changes" section** — file system and progress log are the history

### References

- Full template: `~/Vaults/Notes/Claude/System/project-claude-template.md`
- Design philosophy: `~/Vaults/Notes/Claude/System/protocols-reference.md`
