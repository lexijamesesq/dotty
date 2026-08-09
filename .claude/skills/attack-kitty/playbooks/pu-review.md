# Mandate: pu-review

Structural-conformance review of a written Project Update. Tier: **sonnet**. Single pass — one review, one verdict, no re-invocation.

## Input

The written Project Update body only — no session context.

## Rubric

### 1. Three-layer separation

- **Task-level bleed?** Bullets reading as file-by-file edits, MCP queries, tool calls, methodology/stage sequences → FAIL. Belongs in issue comments.
- **"What's next" framing?** Generic forward planning → FAIL. **Exception:** `**Still open**` documenting incompleteness within the same arc (same parent as items moved Done) is allowed.
- **Loose Threads / Provisional?** → FAIL.

### 2. Granularity

Each `what_was_done` bullet answers "what shifted in the project's overall state" (project-level), not "what steps I took" (task-level).

### 3. Decisions discipline

Each `decisions_made` item has rationale + rejected alternative. Bare claims → FAIL.

### 4. Length proportionality

Substantial session: 15-25 lines. Routine: 5-10. Mismatch to magnitude → FAIL.

### 5. Health calibration

Body mentions blockers/scope changes but health is `onTrack` → FAIL. Routine progress but `offTrack` → FAIL.

### 6. Items worked reciprocity

Every ID in `items_worked` referenced in body; every body-referenced ID in `items_worked`. Mismatch → FAIL.

## Verdict

```yaml
verdict: PASS | REVISE
findings:
  - criterion: <number>
    severity: HIGH | MEDIUM
    issue: <specific gap>
    suggested_fix: <one line>
```

- **PASS** = zero HIGH, ≤2 MEDIUM.
- **REVISE** = HIGH findings present. Caller fixes at discretion; no re-invocation.

Return verdict directly to caller — no Linear comment.
