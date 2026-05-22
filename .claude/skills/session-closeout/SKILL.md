---
name: session-closeout
description: >
  Triggers when the user says "Close out this session for [project]", "Session closeout",
  "Close this session", or similar closeout phrases. Also triggers on "/session-closeout".
user_invokable: true
---

# Session Closeout Protocol

Preserve project state and knowledge artifacts for future session resumption. Adapts to what the session actually did — pure project work, pure knowledge work, mixed, or empty.

## Pre-flight: substantive work check

Closeout is state-preservation, not substantive work. Before classifying session type, ask:

> "Is there substantive work I have current session context for that should land BEFORE this closeout? E.g., docs that describe systems I just changed, code refactors I deferred, follow-ons to today's commits, knowledge syntheses that are still in chat."

If yes: stop closeout, do the work, then re-invoke closeout. The cost of doing it now (context is fresh) is much lower than the cost of deferring (future-you must re-load the context to act on a Linear issue, or worse, the work never gets done because the Linear issue ages out).

This is the upstream guard. Step 6's hygiene check catches what slipped through; this pre-flight prevents the slip. The "anything else?" prompt at the end of substantive work — and the user's answer to it — should be honest: if substantive work is pending, the answer is yes, and closeout waits.

## Trigger Handling

Inspect the argument passed to the skill:

- **No argument** (bare `/session-closeout`, "session closeout", "close this session") → run **Session Type Detection** below to classify what the session actually did, then execute the matching flow.
- **Argument present** → user-supplied override. Accept `project`, `knowledge`, `mixed`, or `empty` directly; treat free-text as intent and reason about which classification it indicates. The override skips detection but still runs the per-type flow against the projects/knowledge that were actually touched.

This is the closeout-side mirror of `/session-start`'s intent argument: detection is the default, intent overrides when offered.

## Session Type Detection

Classify the session by what it actually produced. Detection cannot rely on whether `/session-start` fired — many sessions begin ad-hoc.

### Signals

- **File mutations** — paths of files written/edited this session. (Path patterns and Linear project names below reflect this repo's owner's conventions — adjust to yours.)
  - Project folders (under `workspace_root`): project work.
  - `Knowledge/` subfolders, `Wiki/` paths, `index.md` files: knowledge work.
  - `~/bin/dotty`, `~/.claude`, `~/bin/dotty-private`, system config: out-of-vault project work — maps to the System Linear project (or your equivalent infrastructure-tracking project).
  - Vault notes outside any project (raw notes, Personal/, Work/): see **Vault stewardship** below.
- **MCP/API surface** — `linear_*` writes (status changes, comments, new issues): project work; `obsidian` reads/writes against Knowledge content: knowledge work; long research arcs (WebSearch/WebFetch with notes filed): knowledge work.
- **CLAUDE.md files loaded** — which projects came into scope.
- **Substantive vs. incidental** — a single edit to a project file alongside a long knowledge research arc is mixed-with-knowledge-primary, not project work.

### Types

- **Project** — primary deliverables are Linear-tracked work and/or project artifacts (skill code, project config, project state).
- **Knowledge** — primary deliverables are knowledge-layer pages, methodology synthesis, or research filings. Linear involvement minimal or none.
- **Mixed** — both. Run both flows, in order: project first (Re-entry Cue stays accurate), then knowledge.
- **Empty** — conversation, exploration, or planning that didn't produce mutations. No file writes, no Linear writes, no durable artifacts.

### Projects in scope

Independently of type, list which projects this session actually touched (file mutations + CLAUDE.md loads + Linear writes). One project = single-project flow. Two or more = multi-project flow (see below).

### Vault stewardship

If file mutations land in vault notes that aren't covered by any project's CLAUDE.md (Personal/, Work/, raw notes), treat as a fourth shape — **stewardship** — and run a minimal closeout: bump frontmatter `updated`, no Linear write, brief summary to user.

## Per-Type Flow

### Empty

Output one line: "Session was conversation-only. Nothing to record." Stop.

### Project (single)

Execute Steps 1–7 below against the resolved project.

### Project (multi-project)

Pick a **primary** (the project with the most substantive work or the one the user is most likely to re-enter next; ask if ambiguous). For the primary: run Steps 1–7. For each **incidental** project: run Step 3 (issue updates) and a brief Step 4 Project Update referencing the cross-project context. Skip Steps 1, 2, 5, 6, 7 for incidentals — their CLAUDE.md and Knowledge layer weren't substantively touched.

### Knowledge

Skip Steps 1, 3, 5. Run:

- **Step 2** — only if a host project is in scope. Update Re-entry Cue (one sentence pointing at the filed artifact) and `Last Updated`. Skip Current State / Waiting For / Decisions Needed unless they actually changed.
- **Step 4** — only if a host project is in scope (e.g., `System/Knowledge/` work belongs to System). Body emphasizes what was filed/synthesized, not Linear-issue advancement. If no host project, skip Step 4 entirely.
- **Step 6** — full hygiene check. This is the knowledge flow's primary write surface.
- **Step 7** — verification, scoped to knowledge layer (index sync, frontmatter `updated` bumps, no orphaned new pages).

Knowledge sessions update `updated` frontmatter on touched pages, sync the relevant `index.md`, and prompt for query-and-file (Step 6b) if durable synthesis emerged but didn't get filed.

### Mixed

Run the Project (single or multi) flow, then run the Knowledge flow's Step 6 with extra emphasis. Don't write a separate Project Update for the knowledge work — fold it into the project's Step 4 Update as a "Knowledge artifacts filed" line if relevant.

### Stewardship (vault notes outside any project)

Bump `updated` on touched pages. No CLAUDE.md edit, no Linear write. Output: brief summary of what was touched, in case the user wants to file any of it as a project.

## Out-of-vault sessions

Work in `~/bin/dotty`, `~/.claude`, system config, or other tracked-but-non-vault locations is project-shaped. Resolve the host project (almost always System) and run the Project flow against it. The CLAUDE.md to update lives in the vault even if the work didn't.

## Mutation Steps

These are the building blocks. The per-type flow above selects which to run and against which targets.

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

Backlog items live in Linear, not in a local backlog.json. Skill assumes the consumer has migrated to Linear-as-source-of-truth for backlog; if your setup still uses local backlog files, the closeout flow won't apply cleanly.

**Memory division of labor:** Linear issues hold **item-level memory** — what this task is, decisions specific to this task, and progress on this task. Don't push item-level narrative into the Project Update (Step 4); push it onto the issue itself.

For each Linear issue worked this session:

1. **Mark completed issues Done** via `mcp__linear-tactic__linear_updateIssue` with the appropriate `stateId` for that team's Done state. If the issue had non-obvious resolution (rejected approach, surprising root cause, decision specific to this task), add a closing comment via `mcp__linear-tactic__linear_createComment` capturing it. Future-me will read this when the issue surfaces in search.
2. **Update in-progress issues** with progress comments via `mcp__linear-tactic__linear_createComment` if the work was substantive — e.g., "[date] — fixed X, remaining Y"
3. **Move stalled items to Waiting/Blocked** if they hit external blockers — and comment on what the blocker is
4. **Create new issues** for follow-ups discovered this session via `mcp__linear-tactic__linear_createIssue`. Put item-level rationale in the issue description, not in the Project Update.
5. **Update issue descriptions** when the scope or approach for an open issue changed materially this session — the description is the issue's spec, comments are its log.

Linear auto-archives Done items per workflow config — no separate archive step required.

**Pre-cutoff projects (transitional):** if the project hasn't migrated yet, fall back to the old pattern: mark completed items in `backlog.json`, move to `backlog-archive.json`, etc. The trigger is whether CLAUDE.md Intake declares a `**Project ID:**` field (UUID) or Linear project URL.

**Resolving the Linear projectId:** Read `**Project ID:**` (a UUID) from the project's CLAUDE.md Intake `### Tasks` section. The URL slug is NOT a valid `projectId` argument. If absent (legacy CLAUDE.md), fall back to `linear_getProjects` and match the project name from CLAUDE.md frontmatter or title.

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

- **Project Update bullet:** "Migrated all N project backlogs to Linear; pre-cutoff records frozen as `*-archive` files."
- **Issue comment on a specific ticket:** "Exported `<project>/backlog.json` (N items), mapped status enum to Linear states, validated count match before archiving source."

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

**Pre-cutoff projects (transitional):** if no `**Project ID:**` or Linear project URL in CLAUDE.md Intake, append to `progress.md` with `## YYYY-MM-DD — Brief Title` header (file logs lack createdAt).

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

**Actions** — classify by *whether you have current session context*, not by line count:

- **Current-context fixes** (you authored or modified the systems being documented in this session — your context is fresh and complete): fix directly, regardless of size. The cost of doing it now is the keystrokes; the cost of deferring is a future context re-load to act on a Linear issue, or the work decaying in backlog. If you have the context, deferring is the wrong call — see Pre-flight.
- **Out-of-scope refactors** (genuinely separate scope — different system, different domain, requires independent research you didn't do this session): file as a Linear issue describing what needs consolidation. Line count is a weak signal; the real signal is whether your current context is sufficient to do the work correctly. A 5-line edit to a system you don't understand may still belong as a Linear issue.
- **Uncertainty** (unclear if content is stale or historical, or unsure whether you have the context to update correctly): flag to user in closeout summary, don't modify.

Do not modify docs referenced by projects outside the current session scope without flagging to the user.

**Anti-pattern to avoid:** Treating the line-count threshold as the decision primitive. The threshold encoded a heuristic ("big changes are usually structural"), but the actual blocker is context, not size. A mechanical translation of fresh session work into doc form is a current-context fix even at 100 lines; a 10-line edit to a system whose semantics you don't fully understand is out-of-scope.

**Principle:** Reference docs represent current understanding in a single coherent pass. Chronological discovery belongs in Linear Project Updates and git history.

#### 6b: Query-and-File Check

If the project has a Knowledge layer (declared in CLAUDE.md Intake `### Knowledge` or detected via a `Knowledge/` folder):

**Ask:** Did this session produce durable synthesis — findings, methodology, architecture decisions, research results, validated patterns — that future sessions would need to consult? If the answer disappeared into chat history, would a future session have to re-derive it?

If yes: file it as a Knowledge page per [[handoff-contracts]] §3 and [[structural-contract]]. This step is the §3 enforcer — every filed page must satisfy the full envelope:

- **Full Invariant Core:** `type/knowledge` tag, scope tag (`project/<name>` for project-hosted, `area/<hierarchy>` for Wiki-hosted), `status/active`, `updated: YYYY-MM-DD`, single `# Title` H1.
- **`sources`:** required for `type/knowledge`. Use the [[structural-contract]] Provenance vocabulary: `AI research YYYY-MM-DD` for session-derived synthesis; `user-stated` for user-provided facts.
- **`topic/`:** required (≥1) when filing to `Wiki/Knowledge/` (Wiki-hosted modifier); optional for project-hosted (`Projects/*/Knowledge/`, `System/Knowledge/`).
- **Do NOT include a `## Original Capture` body section** — [[structural-contract]] D1 supersedes any prior mandate; provenance lives in `sources` frontmatter.
- After filing, update `Knowledge/index.md` (Step 6d).
- **Filing validation** — invoke the `filing-validator` agent (via the Task tool) with: (a) target file path, (b) handoff `§3 session-closeout query-and-file`, (c) destination class (`project-hosted` if filed under `Projects/*/Knowledge/` or `System/Knowledge/`; `Wiki-hosted` if filed under `Wiki/Knowledge/`). Invoke it before Step 6d (index sync) — the validator does not check for an `index.md` entry, so ordering is not a constraint, but run validation while the filed page is fresh. If the agent returns `RESULT: FAIL`, fix each named HIGH violation and re-invoke `filing-validator` to confirm. A PASS (zero HIGH violations) is required before the filed page is counted as complete. WARNING/INFO items may be noted to the user but do not block completion.

If uncertain: include it in the closeout summary as a candidate for the user to decide.

#### 6c: Hub Cross-Reference

If this project is a subproject under a hub that has its own shared `Knowledge/`:

**Ask:** Do this session's findings touch any topic covered by a hub-level Knowledge page? Check the hub's `Knowledge/index.md` for topic overlap.

If yes and the hub doc is clearly incomplete or contradicted by this session's work: update it directly (straightforward changes) or flag it as needing update (structural changes).

If uncertain: note it in the closeout summary — "Hub Knowledge page `X` may need updating based on this session's findings about Y."

#### 6d: Index Sync

If Knowledge pages were created, renamed, or deleted during this session, verify `Knowledge/index.md` reflects the current state. Add new entries, remove deleted ones, update summaries for pages whose content changed substantially. This is the post-file obligation for §3 of [[handoff-contracts]]; index sync is a process obligation, not a structural property of the filed file (see [[structural-contract]] Destination Modifiers).

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
