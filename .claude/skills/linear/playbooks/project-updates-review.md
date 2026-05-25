# Playbook: project-updates-review (load-boundary guard)

**LOAD BOUNDARY:** This file is loaded ONLY by a fresh subagent invocation given a written Project Update + this rubric. The write path (`project-updates.md`) NEVER loads this file. The load boundary IS the structural self-evaluation guard per `[[composable-skills-methodology]]`.

The orchestrator (typically `/session-closeout`) spawns a critic subagent AFTER the Project Update is written. The subagent reads:
1. This file (the rubric)
2. The written Project Update body
3. Nothing else (no closeout reasoning, no session context, no orchestrator state)

The subagent returns findings; the orchestrator decides whether to revise. Iteration cap 3.

## Rubric (per-criterion PASS/FAIL with specific gap)

### 1. Three-layer separation intact

- **Item-level bleed?** Does any bullet read like a task-level mechanic (file-by-file edits, MCP queries, individual tool calls)? If yes, FAIL with `"Task-level mechanic in bullet N: '<excerpt>'. Belongs in an issue comment, not the Project Update."`
- **"What's next" framing?** Any section, header, or bullet that frames generic forward-looking work? If yes, FAIL — Linear active issues are the queue; Re-entry Cue is orientation. **Carve-out (do NOT flag):** a `**Still open**` / `**Remaining for this arc**` / `**Open acceptance gates**` section documenting incompleteness within the scope of what the session actually worked on (e.g., sub-tickets of a parent the session pushed on, acceptance gates of an arc the session advanced). Test: are the items same-arc as items the session moved Done or commented on? If yes, allowed. If they're unrelated future work, fail with "What's next" framing.
- **Loose Threads / Provisional category?** Any bullet category labeled "loose threads", "provisional", "ideas", "follow-ups to consider", "maybe", or equivalent? If yes, FAIL — those decay in CLAUDE.md Current State or get filed as low-priority issues.

### 2. Granularity test

For each `what_was_done` bullet:
- Project-level: PASS (answers "what shifted in the project's overall state")
- Task-level: FAIL with the example: a bullet about "exported the file, mapped the enum, validated counts" is task-level; the project-level version is "migrated all backlogs to Linear."

### 3. Decisions section discipline

- Each item in `decisions_made` includes rationale (not just the decision)?
- Each item names the rejected alternative or explains why other options were ruled out?
- If yes for both → PASS. If decisions section is present but bullets are bare claims → FAIL.

### 4. Length proportionality

- Substantial session (multi-issue, multi-system, architectural shift): 15-25 lines expected.
- Routine session: 5-10 lines.
- Empty session: shouldn't have a Project Update at all (orchestrator's empty-type flow output "Session was conversation-only").
- If length doesn't match magnitude (e.g., 40 lines for a single-bug-fix session, or 3 lines for a multi-day architectural push), FAIL with the size guidance.

### 5. Health field calibration

- `onTrack` claimed but the body mentions new blockers, decisions piling up, scope changes? FAIL — should be `atRisk` minimum.
- `offTrack` claimed but body reads like routine progress? FAIL — calibrate down to `onTrack` or `atRisk`.
- `atRisk` is the safe default when Waiting/Decisions Needed sections grew this session.

### 6. Items worked field

- All IDs in `items_worked` actually referenced in the body (at least one bullet mentions each)?
- IDs that aren't referenced get flagged with `"Item <TEAM>-N listed but not mentioned in body — should this be on the list?"`
- Body mentions an ID not in `items_worked`? FAIL with `"Body references <TEAM>-N but it's not in items_worked."`

## Output format

```yaml
verdict: PASS | REVISE | FAIL
findings:
  - criterion: <number>
    severity: HIGH | MEDIUM | LOW
    issue: <specific gap>
    suggested_fix: <one line>
```

- **PASS** = zero HIGH findings, ≤2 MEDIUM. Orchestrator counts complete; no revision needed.
- **REVISE** = HIGH findings present. Orchestrator should fix per `suggested_fix` and re-invoke this rubric (iteration cap 3).
- **FAIL** = same findings after 3 iterations OR architecture-level issue (e.g., body fundamentally can't satisfy three-layer separation because it tries to do something Project Updates shouldn't do). Escalate to operator.

## Adversarial framing (for the critic subagent reading this)

You are the structural guard. The write path has a vested interest in the body being acceptable — it just spent reasoning composing it. You don't. Your value comes from rejecting flawed content the writer would rationalize.

Default to skepticism. If a bullet *could* be task-level, surface it. If a decision *could* be missing rationale, surface it. If the health field *might* be over-optimistic, surface it. The orchestrator decides whether to fix; your job is to catch.

If you find yourself agreeing with the write path's framing of an ambiguous case → re-read the rubric, ground in the methodology, surface the concern anyway. False positives are recoverable (revise and re-invoke); false negatives are not (escapes land in Linear and become future-confusion).
