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

### Step 3: Update Linear issues (item-level memory)

Per the 2026-05-09 cutover, backlog items live in Linear, not local backlog.json.

**Memory division of labor:** Linear issues hold **item-level memory** — what this task is, decisions specific to this task, and progress on this task. Don't push item-level narrative into the Project Update (Step 4); push it onto the issue itself.

For each Linear issue worked this session:

1. **Mark completed issues Done** via `mcp__linear-tactic__linear_updateIssue` with the appropriate `stateId` for that team's Done state. If the issue had non-obvious resolution (rejected approach, surprising root cause, decision specific to this task), add a closing comment via `mcp__linear-tactic__linear_createComment` capturing it. Future-me will read this when the issue surfaces in search.
2. **Update in-progress issues** with progress comments via `mcp__linear-tactic__linear_createComment` if the work was substantive — e.g., "[date] — fixed X, remaining Y" — same shape as the <TEAM>-N example from the trial
3. **Move stalled items to Waiting/Blocked** if they hit external blockers — and comment on what the blocker is
4. **Create new issues** for follow-ups discovered this session via `mcp__linear-tactic__linear_createIssue`. Put item-level rationale in the issue description, not in the Project Update.
5. **Update issue descriptions** when the scope or approach for an open issue changed materially this session — the description is the issue's spec, comments are its log.

Linear auto-archives Done items per workflow config — no separate archive step required.

**Pre-cutoff projects (transitional):** if the project hasn't migrated yet, fall back to the old pattern: mark completed items in `backlog.json`, move to `backlog-archive.json`, etc. The trigger is whether CLAUDE.md Intake declares a Linear project URL.

### Step 4: Write a Linear Project Update (session-level memory)

Append session narrative as a Linear Project Update via `mcp__linear-tactic__linear_createProjectUpdate`. The memory layer for future sessions, per `sustained-autonomous-agentic-workflows.md`. Audience: future-me reading via MCP query, not a human browsing the UI.

**Three layers, no overlap:**

| Layer | Lives on | Holds |
|---|---|---|
| Item-level memory | Linear issue description + comments | What this task is, decisions specific to it, resolution context |
| Session-level memory | Project Update | What was *done* this session and *why* — frozen historical record |
| Re-entry / queue | CLAUDE.md Re-entry Cue + Linear active issues | "What was I in the middle of" + the active work queue |

If a decision belongs to one issue, write it on the issue. The Project Update is for session-spanning narrative.

**Project Updates do NOT include "What's next."** Linear active issues are the queue (queryable at session start); the CLAUDE.md Re-entry Cue holds the one-sentence orientation including any non-issue next-step (push commits, restart session). Rationale: pre-Linear, progress.md was the only persistent record so "What's next" had to live there. Now Linear holds the queue, so "What's next" in a Project Update mostly duplicates either the queue or the Re-entry Cue.

**Provisional thoughts** ("we should think about X next session," "Y might be the next direction") go in CLAUDE.md Project State's Current State paragraph — that paragraph gets overwritten next session, so unprosecuted ideas decay naturally. If the thought is shaped enough to be actionable, promote it to a low-priority Linear issue instead. Do NOT create a "Loose Threads" or "Provisional" bullet category in Project Updates — that recreates the progress.md sprawl pattern this architecture explicitly killed.

**Granularity test for "What was done" bullets vs. issue comments.** Project Update bullets are at *project-level* granularity — they answer "what shifted in the project's overall state this session." Issue comments are at *task-level* granularity — they answer "what happened on this specific task." Example:

- **Project Update bullet:** "Migrated all 8 project backlogs to Linear (<TEAM>-N–75); pre-cutoff records frozen as `*-archive` files."
- **Issue comment on <TEAM>-N:** "Exported HA backlog.json (32 items), mapped status enum to Linear states, validated count match before archiving source."

Same work, different granularity. If a piece of content fits both granularities, it's a level-of-detail problem — split it: project-level summary in the Update, task-level mechanics in the comment.

**Body shape:**

```markdown
## Brief Title

**Items worked:** LEX-N, LEX-M (bare IDs, no markdown links — read via MCP)

**What was done:**
- 3-7 dense bullets, file paths and decisions inline

**Decisions made:**
- Non-obvious decisions only, with rationale and rejected alternatives
```

**Length:** ~15-25 lines for substantial sessions; ~5-10 for routine work. Length earns itself from session magnitude, not from listing every touched issue.

**Health field:**
- `onTrack` — no blocked decisions, no piling waiting items
- `atRisk` — Waiting/Decisions Needed sections in CLAUDE.md grew
- `offTrack` — major direction shift or critical blocker landed

**Pre-cutoff projects (transitional):** if no Linear project, append to `progress.md` with `## YYYY-MM-DD — Brief Title` header (file logs lack createdAt).

### Step 5: Check for Scope Changes

- Did the project scope expand or change this session?
- If yes, update the project description at the top of CLAUDE.md (the 1-3 sentence description) AND update the Linear project's description via `mcp__linear-tactic__linear_updateProject`
- Project description is used for capture triage — the inbox router uses it to match captures to destinations

### Step 6: Knowledge Doc Hygiene Check

Check whether knowledge/reference docs need cleanup based on this session's work. This is a safety net for integration that should happen during the session but sometimes doesn't.

**Identify candidates:** Start from what changed architecturally this session, then find docs that describe those systems. Two discovery paths: (1) For git-tracked projects, check `git diff --name-only`. For vault-only projects, review tool call history for files read or edited. (2) For any project, consider changes made through external tools (MCP, SSH, APIs, dashboards) that altered system behavior without touching local files — knowledge docs describing those systems are candidates even if never opened this session. Focus on reference material (guides, specs, methodology docs, research syntheses) — skip progress logs, backlogs, and CLAUDE.md files (handled in other steps).

**Scan each candidate for these anti-patterns:**

1. **Appendix syndrome** — Dated sections appended to the end ("Extended Research: YYYY-MM-DD") instead of integrating new content into existing structure
2. **Duplicate structures** — Tables, lists, or sections that repeat earlier content with additions rather than updating the original
3. **Historical framing** — Language about how/when/why research was conducted — belongs in Linear Project Updates, not reference docs. Exception: methodology/provenance statements that serve as validity markers ("Analysis used X framework") are fine.
4. **Progress-log bleed** — Session numbers, dated entries, or "what was done" language in a doc that should present timeless current knowledge
5. **Unbounded growth** — Doc exceeding ~300 lines without clear structure, or sections that have grown significantly without consolidation
6. **Stale content** — Findings contradicted or superseded by this session's work that weren't updated in place (best-effort — catch what's obvious)
7. **Orphaned sections** — Content no longer connected to active project concerns — not wrong, just dead weight

**Actions:**
- **Straightforward fixes** (<~20 lines of change — stale paragraph, duplicate table, historical preamble): fix directly
- **Structural issues** (full reorganization, appendix integration, or changes exceeding ~20 lines): create a Linear issue describing what needs consolidation
- **Uncertainty** (unclear if content is stale or historical): flag to user in closeout summary, don't modify

Do not modify docs referenced by projects outside the current session scope without flagging to the user.

**Principle:** Reference docs represent current understanding in a single coherent pass. Chronological discovery belongs in Linear Project Updates and git history.

#### 6b: Query-and-File Check

If the project has a Knowledge layer (declared in CLAUDE.md Intake `### Knowledge` or detected via a `Knowledge/` folder):

**Ask:** Did this session produce durable synthesis — findings, methodology, architecture decisions, research results, validated patterns — that future sessions would need to consult? If the answer disappeared into chat history, would a future session have to re-derive it?

If yes: file it as a Knowledge page in the project's declared Knowledge location, with the project's frontmatter schema (`type/knowledge` + `project/<name>` + `updated`), and update `Knowledge/index.md` with a new entry.

If uncertain: include it in the closeout summary as a candidate for the user to decide.

#### 6c: Hub Cross-Reference

If this project is a subproject under a hub that has its own shared `Knowledge/`:

**Ask:** Do this session's findings touch any topic covered by a hub-level Knowledge page? Check the hub's `Knowledge/index.md` for topic overlap.

If yes and the hub doc is clearly incomplete or contradicted by this session's work: update it directly (straightforward changes) or flag it as needing update (structural changes).

If uncertain: note it in the closeout summary — "Hub Knowledge page `X` may need updating based on this session's findings about Y."

#### 6d: Index Sync

If Knowledge pages were created, renamed, or deleted during this session, verify `Knowledge/index.md` reflects the current state. Add new entries, remove deleted ones, update summaries for pages whose content changed substantially.

### Step 7: Final Verification

Before finishing, verify:

- **Re-entry Cue** answers "what was I in the middle of?" in one sentence
- **Linear active issues** are each immediately executable (no interpretation needed) — if not, comment or rewrite
- **Item-level memory landed where Step 3 specifies** — closed issues with non-obvious resolution have closing comments; in-progress issues touched substantively have progress comments; mutated descriptions reflect current scope
- **No stale content in CLAUDE.md** — remove resolved blockers, answered decisions, completed items (reference doc staleness is handled in Step 6)
- **No "Recent Changes" section** in CLAUDE.md — Linear Project Updates and git history are the timeline
- **Linear Project Update was created** for this session (Step 4)

### References

- Full template: path configured in global CLAUDE.md > Configuration > `templates.project`
- Design philosophy: path configured in global CLAUDE.md > Configuration > `references.protocols`
