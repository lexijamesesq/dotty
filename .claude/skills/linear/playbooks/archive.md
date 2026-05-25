# Playbook: archive

Sweep Done + Canceled Linear issues past a grace period across both teams. Driven by the 2026-05-23 free-tier cap incident (250-ticket limit; project-attached issues bypass UI auto-archive — see `~/bin/dotty/.claude/rules/linear-discipline.md` "Project-attachment caveat" subsection, added during the deconstruction work).

## Input

```yaml
grace_days: <int>          # default 14 — issues with stateType in {completed, canceled} older than this are candidates
teams: [<team_prefix>, ...]  # default all teams in CLAUDE.md > Configuration — filter to subset if desired
dry_run: <bool>            # default depends on invocation context (see below)
today: <YYYY-MM-DD>        # orchestrator passes for testability
```

**Dry-run default policy:**

| Invocation context | dry_run default |
|---|---|
| Operator ad-hoc (e.g., `/linear archive`) | `true` — never destroy data without explicit `--dry-run=false` |
| `/session-closeout` automated invocation | `false` — closeout invokes deliberately at end-of-session; operator has already greenlit closeout |

The default lives here in the playbook, not in the caller — that way ad-hoc invocations are safe regardless of caller carelessness. Per `live-test-vs-dry-run` operator-feedback memory.

## Protocol

1. **Resolve team scope.** Default to all teams in the operator's CLAUDE.md > Configuration. Translate the team prefix list to team UUIDs via the prefix→UUID mapping there. Never hardcode prefixes or UUIDs in this playbook — both are operator-specific and live in dotty-private (the abstraction must not contain the data it abstracts).

2. **Query candidates per team.** For each team in scope, call `mcp__linear-tactic__linear_searchIssues` filtered to states `[Done, Canceled]`. Iterate pages if necessary (the 250-cap means current state has ~250 max; manageable single query).

3. **Filter by grace.** Compute days-since-state-change from `updatedAt` (proxy for state-entry-time — Linear doesn't expose state-change-time directly, but for Done/Canceled the latest update IS typically the state change). Keep items where `days_since_updated >= grace_days`.

4. **Build candidate list:**

```yaml
candidates:
  - identifier: <TEAM>-N
    title: <string>
    state: Done | Canceled
    days_since_state_change: <int>
    project: <name>
    team: <team_prefix>
```

5. **If `dry_run: true`:** return the candidate list with summary counts. Do NOT call archive. Output ends here.

6. **If `dry_run: false`:** for each candidate, call `mcp__linear-tactic__linear_archiveIssue` (this is `linear_archiveIssue` per the MCP tool surface — verify exact name on first call; the operation moves the issue out of the active 250 cap).

7. **Handle failures.** If any archive call fails (rate limit, transient API), continue with the rest. Collect all failures; report together.

## Output

```yaml
mode: dry_run | live
grace_days: <int>
teams_scoped: [<team_prefix>, ...]
candidates_count:
  total: <int>
  by_team:
    <team_prefix>: <int>
  by_state:
    done: <int>
    canceled: <int>
archived_count: <int>    # 0 in dry-run; equals successful archive calls in live
failures:
  - identifier: <ID>
    error: <string>
```

## Discipline

- **Never archive without an explicit non-dry-run decision.** The dry-run default is the safety floor. Even closeout's automated invocation has `dry_run: false` set explicitly by the closeout flow — never inferred.
- **Both teams by default.** The cap is global to the operator's free tier across both teams. Skipping a team means the cap can still hit on the unswept side.
- **Grace period is calendar age, not in-state age.** Linear doesn't expose state-change-time cleanly; `updatedAt` is the proxy. This is acceptable because Done/Canceled items typically don't see post-state updates; the proxy matches reality in nearly all cases.
- **Recoverable.** Linear's archive is recoverable — archived issues remain in the database, just outside the 250 active cap. If a sweep archives something prematurely, it can be unarchived via `linear_unarchive*` operations (out of scope for this playbook; operator does it manually).
- **Closeout integration.** Closeout invokes this as the FINAL step (after Project Update + Knowledge hygiene), so a successful closeout never leaves the cap closer to 250 than when it started.

## Failure modes to surface clearly

- **Linear API rate limit.** Pause + report partial completion; operator can re-invoke to complete.
- **Network failure mid-batch.** Report which items succeeded; un-archived candidates remain for the next sweep.
- **Permission failure on a specific issue.** Skip + report; don't abort batch.

## What this playbook does NOT do

- Does NOT archive `Waiting`, `Blocked`, `Todo`, or `In Progress` items. Only Done + Canceled.
- Does NOT delete. Archive is recoverable; this playbook is sweep, not destroy.
- Does NOT respect Linear UI's auto-archive setting (the whole point — that setting doesn't work for project-attached issues, which is why this playbook exists).
- Does NOT change the cap. Free tier is 250; this maintains headroom *within* the cap.
