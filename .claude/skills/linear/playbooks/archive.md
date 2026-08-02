# Playbook: archive

Sweep eligible issue clusters — a topmost issue and every descendant beneath it — across the operator's teams (per Configuration), moving them out of the active Linear cap once every member has closed. Driven by the 2026-05-23 free-tier cap incident (250-ticket limit; project-attached issues bypass UI auto-archive — see the `/linear` SKILL.md discipline rules), and hardened into a topology-aware, cap-pressure-responsive design: archival respects the shape of the work — a cluster archives as a unit, never split — and the state of the cap — under pressure, the quiet-hold window dips progressively within the same run, sweeping again at each shorter hold until utilization clears or the floor is reached, so the sweep gets more aggressive exactly when it needs to.

## Input

```yaml
teams: [<team_prefix>, ...]  # default all teams in CLAUDE.md > Configuration — filter to subset if desired
dry_run: <bool>              # default depends on invocation context (see below)
today: <YYYY-MM-DD>          # orchestrator passes for testability — used for elapsed-time math against each cluster's newest `updatedAt`
```

There is no `grace_days` input. The hold period starts at a fixed 7-day (168-hour) quiet-hold baseline and, under cap pressure, dips iteratively within a single run (Protocol Step 8) — a caller-supplied grace period would fight the exact mechanism this design exists to provide.

**Dry-run default policy:**

| Invocation context | dry_run default |
|---|---|
| Operator ad-hoc (e.g., `/linear archive`) | `true` — never destroy data without explicit `--dry-run=false` |
| Automated / lane-triggered invocation | `false` — the invoking lane sets this explicitly; never inferred |

The default lives here in the playbook, not in the caller — that way ad-hoc invocations are safe regardless of caller carelessness. Per `live-test-vs-dry-run` operator-feedback memory.

## Protocol

1. **Resolve team scope.** Default to all teams in the operator's CLAUDE.md > Configuration. Translate the team prefix list to team UUIDs via the prefix→UUID mapping there. Never hardcode prefixes or UUIDs in this playbook — both are operator-specific and live in dotty-private (the abstraction must not contain the data it abstracts).

2. **Check initial cap pressure.** This check always covers every team in Configuration, regardless of the `teams` input filter from Step 1 — the 250-ticket cap is a workspace-wide constraint, not a per-team one, so a partial-team sweep still needs the true global count to size pressure correctly.

   The tactic MCP doesn't expose live per-team issue counts, so this is raw GraphQL: write the query payload (JSON with a `"query"` field) to a temp file, invoke the GraphQL bridge — the same authenticated bridge claim Step 6 in `issue-management.md` uses for delegate-set, resolved via `secrets.op_read` / `linear.app_token_ref` (CLAUDE.md > Configuration; never a literal bridge or secret path in skill text — public repo) — and read the response.

   ```json
   {"query":"query { teams(filter: { id: { in: [\"<team-uuid-1>\", \"<team-uuid-2>\"] } }) { nodes { id key issueCount } } }"}
   ```

   Sum `issueCount` across every returned team → `active_issue_count`. This field excludes archived issues already, so it's the correct live-pressure signal — archiving a cluster moves this number directly. This same query is reissued after every archival pass in Step 8's dip loop, to recheck live pressure.

   **Baseline hold.** Every run's first pass sweeps at a fixed 7-day (168-hour) quiet hold, regardless of pre-run pressure.

   **Does this run need to dip?** Record the pre-run `active_issue_count` for two later uses: sizing the dip loop (Step 8) and classifying the exit state (Step 9). If `active_issue_count` ≤ 200, the run needs only the one baseline pass — Step 8 stops there, no recount, no dip. If `active_issue_count` > 200, cap pressure is in effect: after the baseline pass, Step 8 recounts and, if utilization is still over 200, halves the hold and sweeps again — repeating down to a 12-hour floor across at most 4 dip steps — until utilization clears 200 or candidates run out.

3. **Fetch full topology.** Fetch every non-archived issue (open AND closed) across the resolved team scope — open issues are required to verify the all-closed eligibility invariant in Step 5; a topology built from closed issues alone can't tell a truly-orphaned-and-done cluster from one still anchored to an open sibling. Same GraphQL bridge as Step 2.

   ```json
   {"query":"query($after: String) { issues(first: 250, after: $after, filter: { team: { id: { in: [\"<team-uuid-1>\", \"<team-uuid-2>\"] } } }) { nodes { id identifier title parent { id } state { type } updatedAt team { key } } pageInfo { hasNextPage endCursor } } }","variables":{"after":null}}
   ```

   The `issues` query excludes archived issues by default — exactly the live topology this pass needs. Loop while `pageInfo.hasNextPage` is true, feeding `endCursor` into `variables.after` on the next call. Given the 250-issue cap, this is typically one request, occasionally two.

   **This fetch happens once, at the start of the run.** The dip loop in Step 8 reuses this same topology across every pass, re-evaluating it at successively shorter hold levels rather than refetching — `updatedAt` values for issues untouched during the run don't change mid-pass. Clusters archived earlier in the same run are excluded from later passes by tracking their root ids (Step 8), not by re-querying.

   **If pagination fails partway through**, do not proceed on the partial set — an incomplete topology can misjudge the all-closed invariant (a member fetched on a page that never arrived looks absent, not open). Abort the pass, report what was fetched, and let the next run retry clean.

4. **Rebuild cluster topology client-side.** For each fetched issue, walk `parent.id` upward until reaching an issue with no parent — that issue is the cluster's topmost ancestor (root). Group all fetched issues by their resolved root id; a root with no children found is a cluster of one (a standalone issue is its own cluster).

   **Edge case:** if an issue's `parent.id` points to an id *not present* in this pass's fetched set, treat that issue as its own root for this pass — its true parent was already archived in a prior sweep, so it's no longer part of the live topology. This is expected and normal on any run after the first.

5. **Determine eligibility per cluster, at a given hold `H`.** A cluster is eligible at hold `H` when:
   - **Every member** (root + all descendants) has `state.type` in `{completed, canceled}` — the all-closed invariant. One open member anywhere in the cluster disqualifies the whole cluster, root included.
   - **Quiet hold.** Find the newest `updatedAt` across **every member of the cluster** — root and every descendant — call it the cluster's `newest_updated_at`. The cluster is eligible at hold `H` when `newest_updated_at` is at least `H` hours in the past (measured against `today` if the caller supplied it, else current time). A touch on *any* member — root or descendant — resets the whole cluster's clock; this is a quiet-hold measurement of the cluster as a unit, not a root-close-date measurement. `completedAt` and `canceledAt` play no role in timing.

   Relations do **not** gate eligibility. Eligibility is cluster-membership-and-quiet-hold only — a `blocked_by` or other relation edge touching a cluster member never excludes it. When either endpoint of a relation archives, Linear archives the relation edge with it; that's an accepted side effect, not something this playbook manages or checks for.

6. **Build the candidate list at hold `H`** (one entry per eligible cluster, not per issue):

   ```yaml
   candidates:
     - root_identifier: <TEAM>-N
       root_title: <string>
       root_team: <team_prefix>
       cluster_size: <int>              # 1 = standalone issue
       member_identifiers: [<TEAM>-N, ...]
       newest_updated_at: <ISO datetime>   # newest updatedAt across every cluster member — the quiet-hold clock
       hours_since_newest_update: <float>
       hold_hours_applied: <float>      # the hold level (this pass) that made this cluster eligible
   ```

7. **If `dry_run: true`:** build the candidate list at the 168-hour baseline hold only (Steps 5–6) and return it with summary counts, the pre-run `active_issue_count`, and whether that count exceeds 200. Do NOT call archive, and do NOT run Step 8's recount/dip loop — dipping is a live response to a live recount, and a dry run never archives, so there is nothing to recount. If pre-run pressure exceeds 200, note in the output that a live run would engage the iterative dip loop beyond this baseline preview. Output ends here.

8. **If `dry_run: false`:** run the sweep as an iterative loop, starting at the 168-hour baseline hold:

   a. **Sweep at the current hold.** Using Step 5 at the current hold level, build the candidate list (Step 6) from clusters not yet archived earlier in this run. For each eligible cluster, archive the root only via `mcp__linear-tactic__linear_archiveIssue` — cascade handles descendants; never issue a child-level archive call. Record this pass (hold level, candidates found, roots archived) for the output's `passes` list.

   b. **No pre-run pressure? Stop.** If the pre-run `active_issue_count` (Step 2) was ≤ 200, stop after this one pass — there was no pressure to respond to. Exit state: `normal`.

   c. **Otherwise, recount.** Reissue Step 2's `teams { issueCount }` query to get the live `active_issue_count` after this pass's archival.

   d. **Cleared? Stop.** If `active_issue_count` ≤ 200, stop. Exit state: `cap_pressure`.

   e. **Still over, and hold above the floor? Dip and repeat.** If `active_issue_count` > 200 and the current hold is above 12 hours, halve it (168 → 84 → 42 → 21 → 12, never below 12) and return to (a). The next pass evaluates only clusters not yet archived this run — one found eligible and archived at a longer hold is never re-evaluated.

   f. **Still over, and already at the floor? One last pass, then stop.** If `active_issue_count` > 200 and the hold is already at 12 hours: if pass (a) at the floor found and archived at least one candidate, recount once more via (c) — a further floor pass in the same run will find zero new candidates, since no time passes mid-run, so this converges immediately. If pass (a) at the floor found zero candidates, stop. Exit state: `exhausted`.

   The halving progression is fixed and bounded: 168h → 84h → 42h → 21h → 12h. At most 5 sweep passes (1 baseline + up to 4 dips) run per invocation — the loop cannot run indefinitely.

9. **Classify the pass's exit state**, using the pre-run `active_issue_count` (Step 2) and the outcome of Step 8's loop:
   - **`normal`** — pre-run `active_issue_count` ≤ 200. No pressure; the run took its one pass at the 168-hour baseline and stopped.
   - **`cap_pressure`** — pre-run `active_issue_count` > 200, and the dip loop brought utilization to ≤ 200 by the end of the run (at the baseline hold or after one or more dips). The dipped hold did its job.
   - **`exhausted`** — pre-run `active_issue_count` > 200, the hold reached the 12-hour floor, and the final recount is still > 200. Maximum aggression already applied; nothing further is eligible right now. This is an accepted residual — the workspace stays over 200 until more clusters close and age past 12 hours, and the next run picks it up.

   **All three states exit successfully.** None of them is a failure, and none escalates to the operator beyond ambient dead-man monitoring (the lane simply not having run) — autonomous cap management means the sweep handles its own pressure without a human in the loop. A partial pass ending in `cap_pressure` or `exhausted` is expected behavior, not a problem to surface.

10. **Handle failures.** If any cluster-root archive call fails (rate limit, transient API, permission), continue with the rest — one bad root doesn't stop the pass. Collect all failures; report together.

## Output

```yaml
mode: dry_run | live
teams_scoped: [<team_prefix>, ...]
active_issue_count_pre_run: <int>     # workspace-wide, before any archival (Step 2)
active_issue_count_post_run: <int>    # workspace-wide, after the final pass; equals pre-run in dry-run
cap_state: normal | cap_pressure | exhausted
dip_steps_taken: <int>                # 0-4; 0 = single baseline pass only
passes:                               # one entry per sweep pass this run
  - hold_hours: <float>
    candidates_count: <int>
    archived_count: <int>             # 0 in dry-run
clusters_evaluated: <int>             # total clusters found in scope, eligible or not (Step 4; constant across passes)
candidates_count:
  total: <int>                        # sum across all passes
  by_team:
    <team_prefix>: <int>
candidates:
  - root_identifier: <TEAM>-N
    root_title: <string>
    cluster_size: <int>
    member_identifiers: [<TEAM>-N, ...]
    newest_updated_at: <ISO datetime>
    hold_hours_applied: <float>
archived_count: <int>             # 0 in dry-run; total successfully archived ROOTS across all passes in live (descendants cascade, uncounted here)
failures:
  - root_identifier: <ID>
    error: <string>
```

## Discipline

- **Never archive without an explicit non-dry-run decision.** The dry-run default is the safety floor.
- **All Configuration-listed teams by default** for the sweep scope (Step 1) — but the cap check (Step 2) is always workspace-wide regardless of that scope, since the cap it's protecting is workspace-wide. Skipping a listed team from the sweep leaves its clusters unswept; it does not change what the cap check sees.
- **Cluster is the unit of archival, not the issue.** A cluster with one open member anywhere in it is wholly ineligible — never archive part of a cluster.
- **Hold is a quiet hold, measured cluster-level.** The clock is the newest `updatedAt` across every member — root and every descendant. A touch anywhere in the cluster resets the whole cluster's clock; there is no per-member hold. `completedAt` / `canceledAt` play no role in timing.
- **Under pressure, the hold dips iteratively within the same run.** No pre-computed formula. Starting at the 168-hour baseline, each pass archives what's eligible, then a live recount decides whether to stop or halve the hold and sweep again — down to a 12-hour floor across at most 4 dip steps. This is the design's core departure from a one-shot calculation: pressure response is a live decision tree over live recounts, not a value computed once from a stale pre-run count.
- **Bounded and predictable.** At most 5 sweep passes per run (1 baseline + up to 4 dips), each one "the same sweep, at half the window" — simple enough to reason about step by step, never an open-ended search.
- **Root-only archive calls.** Cascade handles descendants; never issue a child-level archive call from this playbook.
- **Relations never gate eligibility.** Cluster membership and quiet hold are the only eligibility axes. Relation-edge archival on endpoint-archive is accepted, not managed here.
- **Recoverable.** Linear's archive is recoverable — archived issues remain in the database, just outside the active cap. If a sweep archives a cluster prematurely, it can be unarchived via `linear_unarchive*` operations (out of scope for this playbook; operator does it manually).
- **Three states, all success.** `normal`, `cap_pressure`, and `exhausted` are all terminal-success outcomes. No operator escalation beyond dead-man monitoring — a run that doesn't happen is what the monitor catches, never a run that converges partially.
- **Invocable identically from either caller.** The operator's `/linear archive` and any automated lane-triggered invocation run the exact same protocol above; only the `dry_run` default (and whatever the caller passes explicitly) differs.

## Failure modes to surface clearly

- **GraphQL bridge failure (cap check or topology fetch).** Neither Step 2 nor Step 3 has a fallback — both are required inputs to eligibility and pressure sizing. Abort the pass, report the failure, retry on the next run.
- **Recount failure mid-loop (Step 8c).** If a recount call fails partway through the dip loop, do not guess at the live count to decide whether to keep dipping — stop the loop where it stands, report everything archived so far plus the failure, and let the next run pick up from the (now-lower, but unconfirmed) count.
- **Partial pagination on the topology fetch.** Do not compute eligibility from an incomplete issue set — abort rather than risk a false-positive all-closed read. Report what was fetched; the next run retries clean.
- **Linear API rate limit on cluster-root archive calls.** Pause + report partial completion; operator can re-invoke, or the next scheduled run picks up the remainder.
- **Network failure mid-batch (archive calls).** Report which roots succeeded; un-archived candidates remain eligible for the next sweep (their hold period has already passed, so they stay candidates).
- **Permission failure on a specific root.** Skip + report; don't abort the batch.

## What this playbook does NOT do

- Does NOT gate eligibility on relations — cluster-membership-and-quiet-hold only, per Step 5.
- Does NOT archive individual cluster members directly — root archive cascades; no per-child calls.
- Does NOT delete. Archive is recoverable; this playbook is sweep, not destroy.
- Does NOT use a pre-computed formula for the hold, and does NOT compute it once and hold it fixed for the whole run — the hold starts at 168h and dips iteratively, live recount by live recount, down to the 12-hour floor, within a single run (Step 8).
- Does NOT dip the hold below the 12-hour floor, no matter how much pressure remains — the floor is a hard stop. A workspace still over 200 after an exhausted pass waits for the next run (or more clusters closing and aging past 12 hours), rather than eroding the quiet-hold guarantee further.
- Does NOT re-evaluate a cluster already archived earlier in the same run — each dip pass considers only clusters not yet swept this run.
- Does NOT check per-issue `[VALIDATION]` comments. Validation enforcement lives at close time (`mark_done` refuses without a verdict, per `closing.md`); at cluster granularity, an unvalidated Done ticket buried inside an otherwise-eligible cluster isn't a distinct signal worth carrying forward from the old per-issue design.
- Does NOT respect Linear UI's auto-archive setting (the whole point — that setting doesn't work for project-attached issues, which is why this playbook exists).
- Does NOT change the cap. Free tier is 250; this maintains headroom *within* the cap.
- Does NOT escalate to the operator on any of the three exit states (`normal` / `cap_pressure` / `exhausted`) — all three are accepted, successful outcomes.
