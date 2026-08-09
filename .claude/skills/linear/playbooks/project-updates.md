# Playbook: project-updates (write path)

Write a Linear Project Update — the session-level memory artifact.

## Input

```yaml
project_id: <UUID>
title: <string>                        # 1 short headline
items_worked: [<ticket-id>, ...]       # bare IDs
what_was_done: [<bullet>, ...]         # 3-7 dense bullets
decisions_made: [<bullet>, ...]        # non-obvious only, with rationale + rejected alternative
health: onTrack | atRisk | offTrack
```

## Protocol

1. **Validate inputs** (fail loudly):
   - Title non-empty.
   - `items_worked` present (may be empty for pure-knowledge sessions).
   - `what_was_done`: 3-7 bullets (1-3 for genuinely routine sessions).
   - Each `decisions_made` item includes rationale and the rejected alternative.
   - `health` ∈ valid enum.

2. **Reject three-layer violations** (return error, do not write):

   - **Task-level mechanics in `what_was_done`.** Bullets answer "what shifted in the project's overall state," not "what steps I took." Reject: file-by-file edits, tool call sequences, methodology/stage sequences ("ran as three stages: X, Y, Z"; "build → acceptance → review → gate"), per-step debug narrative. The rewrite test: "migrated all backlogs to Linear" (right) vs. "exported backlog.json, mapped enum, validated counts" (wrong — split: summary here, mechanics in issue comment). Most common regression.
   - **Ticket-ID mismatch.** Every ID in `items_worked` must appear in the body, and vice versa.
   - **"What's next" framing.** Reject "Next session...", "Up next:", "TODO:", "Will:", `## Next steps`. **Exception:** `**Still open**` documenting incompleteness within the same arc (test: are items same-parent as what was moved Done?). "Next session we'll tackle <ticket-id>" → rejected (not worked this session; forward planning). "Still open: <ticket-id> — <parent-id>'s acceptance gate" → allowed when the ticket is a sub-ticket of the parent, which this session advanced (arc incompleteness).
   - **Loose Threads / Provisional categories.** Reject "loose threads", "provisional", "ideas", "follow-ups to consider." Provisional → CLAUDE.md Current State (decays on overwrite); actionable → low-priority Linear issue.

3. **Compose the body:**

```markdown
## {{title}}

**Items worked:** {{items_worked joined by ", "}}

**What was done:**
- {{bullet 1}}
...

**Decisions made:**
- {{decision 1}}
...
```

   Omit `Decisions made:` if empty.

4. **Write** via `mcp__linear-tactic__linear_createProjectUpdate` with `projectId`, composed `body`, and `health`.

5. **Return** the update ID + URL.

## Body discipline

Audience: future-me reading via MCP. Dense, scannable, references inline. ~15-25 lines for substantial sessions; ~5-10 for routine. Decisions belonging to a single issue go on the issue comment, not here.

## Health semantics

- **onTrack** — no blocked decisions; trajectory matches plan.
- **atRisk** — Needs Input/Decisions Needed grew; trajectory in question.
- **offTrack** — major direction shift or critical blocker; needs re-direction.
