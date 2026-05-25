# Playbook: analysis

Analysis operations on Linear data — stale-debt detection, theme grouping, priority distribution. Read-only; consumes outputs from `reading.md` and applies operator-discipline thresholds + heuristics.

## Operations

### 1. Stale-debt detection

Identify `Todo` and `In Progress` items past per-priority freshness thresholds based on `updatedAt`. Stale here means "should be moving but isn't" — distinct from `Waiting`/`Blocked` which aren't expected to move.

**Input:**
- `issues` — list from `reading.md` queue (or any compatible list with `priority` + `updatedAt` + `state`)
- `state_scope` (default `[Todo, In Progress]`)
- `today` (ISO date — orchestrator passes for testability)

**Per-priority thresholds (days unupdated):**

| Linear priority | Threshold |
|---|---|
| Urgent (1) | 7 |
| High (2) | 14 |
| Normal (3) | 30 |
| Low (4) | 90 |
| No priority (0) | 60 |

**Protocol:**
1. Filter `issues` to those in `state_scope`.
2. For each, compute days-since-updated from `updatedAt` to `today`.
3. Return those past their priority's threshold.

**Output:**
```yaml
stale:
  - identifier: <TEAM>-N
    title: <string>
    priority: <number>
    priority_name: Urgent | High | Normal | Low | None
    days_unupdated: <int>
    threshold: <int>
```

**Discipline:** Caller surfaces stale items LAST in any orientation output (per session-start convention) so the operator reads them right before directing the session. Silence is the success signal — if the stale list is empty, the caller should OMIT the section entirely, not say "0 stale" or "backlog clean."

### 2. Waiting/Blocked re-evaluation

Different from stale-debt: these states aren't expected to move on calendar age. The signal is whether the *dependency* has moved.

**Input:**
- `issues` — list filtered to `[Waiting, Blocked]`

**Protocol:**
This playbook does NOT auto-evaluate (the resolver/trigger lives in the issue description as prose; requires reading + judgment). Instead, return the items structured for the orchestrator to re-evaluate inline at session-start (per `[[linear-discipline]]` "Waiting and Blocked entry paths" section — operator-driven re-eval).

**Output:**
```yaml
needs_reevaluation:
  - identifier: <TEAM>-N
    state: Waiting | Blocked
    title: <string>
    description: <markdown — orchestrator reads to find resolver + trigger>
    days_unupdated: <int>     # informational only — calendar age is a weak signal here
```

The orchestrator then asks per-item: has the resolver moved? has the trigger fired? is the wait still warranted?

### 3. Theme grouping

Group a list of issues by inferred theme/topic. Useful for queue triage, multi-project portfolio review.

**Input:**
- `issues`
- `dimension` (default `topic` — alternatives: `system_component`, `stakeholder`, `decision_class`)

**Protocol:**
Inferential pattern-matching across titles + descriptions + labels. NOT a hardcoded taxonomy — let the model identify natural groupings in the data. Bias toward 3-7 groups; fewer if data permits, more if forcing groups would mislabel.

**Output:**
```yaml
themes:
  - name: <theme name>
    items: [<identifier>, ...]
    rationale: <one-line why these group>
```

### 4. Priority distribution

Quick count by priority for a queue snapshot.

**Input:**
- `issues`

**Output:**
```yaml
distribution:
  urgent: <count>
  high: <count>
  normal: <count>
  low: <count>
  none: <count>
total: <count>
```

## What this playbook does NOT do

- Does NOT mutate (no state changes, no comments). Pure read-side analysis.
- Does NOT include `Waiting`/`Blocked` in stale-debt — per `[[linear-discipline]]`, those are surfaced separately via re-evaluation, not calendar threshold.
- Does NOT recommend actions (e.g., "you should close <TEAM>-N"). Returns analysis; caller decides.
