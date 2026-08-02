# Playbook: archive

Sweep eligible issue clusters — a topmost issue and every descendant beneath it — across the operator's teams (per Configuration), moving them out of the active Linear cap once every member has closed. Driven by the 2026-05-23 free-tier cap incident (250-ticket limit; project-attached issues bypass UI auto-archive — see the `/linear` SKILL.md discipline rules), and hardened into a topology-aware, cap-pressure-responsive design: archival respects the shape of the work — a cluster archives as a unit, never split — and the state of the cap — grace shortens as pressure rises, so the sweep gets more aggressive exactly when it needs to.

## Input

```yaml
teams: [<team_prefix>, ...]  # default all teams in CLAUDE.md > Configuration — filter to subset if desired
dry_run: <bool>              # default depends on invocation context (see below)
today: <YYYY-MM-DD>          # orchestrator passes for testability — used for elapsed-time math against root close dates
```

There is no `grace_days` input. The hold period is computed internally, once per run, from live cap pressure (Protocol Step 2) — a caller-supplied grace period would fight the exact mechanism this design exists to provide.

**Dry-run default policy:**

| Invocation context | dry_run default |
|---|---|
| Operator ad-hoc (e.g., `/linear archive`) | `true` — never destroy data without explicit `--dry-run=false` |
| Automated / lane-triggered invocation | `false` — the invoking lane sets this explicitly; never inferred |

The default lives here in the playbook, not in the caller — that way ad-hoc invocations are safe regardless of caller carelessness. Per `live-test-vs-dry-run` operator-feedback memory.

## Protocol

1. **Resolve team scope.** Default to all teams in the operator's CLAUDE.md > Configuration. Translate the team prefix list to team UUIDs via the prefix→UUID mapping there. Never hardcode prefixes or UUIDs in this playbook — both are operator-specific and live in dotty-private (the abstraction must not contain the data it abstracts).

2. **Check cap pressure and compute the hold period.** This check always covers every team in Configuration, regardless of the `teams` input filter from Step 1 — the 250-ticket cap is a workspace-wide constraint, not a per-team one, so a partial-team sweep still needs the true global count to size its hold correctly.

   The tactic MCP doesn't expose live per-team issue counts, so this is raw GraphQL: write the query payload (JSON with a `"query"` field) to a temp file, invoke the GraphQL bridge — the same authenticated bridge claim Step 6 in `issue-management.md` uses for delegate-set, resolved via `secrets.op_read` / `linear.app_token_ref` (CLAUDE.md > Configuration; never a literal bridge or secret path in skill text — public repo) — and read the response.

   ```json
   {"query":"query { teams(filter: { id: { in: [\"<team-uuid-1>\", \"<team-uuid-2>\"] } }) { nodes { id key issueCount } } }"}
   ```

   Sum `issueCount` across every returned team → `active_issue_count`. This field is probed to exclude archived issues already, so it's the correct live-pressure signal — archiving a cluster moves this number directly.

   **Hold period formula.** Baseline 7 days (168 hours) with no cap pressure. Under cap pressure (`active_issue_count` > 200, against the 250 free-tier cap), the hold decays linearly from 168 hours at zero pressure toward zero at the 250-issue cap, floored at 12 hours:

   ```
   hold_hours = 168 * (250 - active_issue_count) / 50
   hold_hours = clamp(hold_hours, 12, 168)
   ```

   Verify against these points before trusting an implementation of this formula:

   | active_issue_count | raw (168 × (250−n)/50) | hold_hours (clamped) | ≈ days |
   |---|---|---|---|
   | 150 | 336.0 | **168** (floor of the clamp's ceiling) | 7.0 |
   | 200 | 168.0 | **168** | 7.0 |
   | 210 | 134.4 | **134.4** | 5.6 |
   | 245 | 16.8 | **16.8** | 0.7 |
   | ≥ 247 (≈ 246.43 exactly) | < 12 | **12** (floor) | 0.5 |

   Note for anyone re-deriving this: a naive two-point interpolation directly between the anchors "(200 active, 168h)" and "(250 active, 12h)" produces a *different* curve (≈136.8h at 210, ≈27.6h at 245) — that reading is wrong for this design. The formula above is a straight-line decay to zero at the cap, clamped at a 12-hour floor; the "12h at 250" language describes the floor's effect under full pressure, not a literal point the raw line passes through.

   Compute `hold_hours` **once**, from this pre-run `active_issue_count`. Never recompute mid-pass, even as archival in this same run changes the live count — no iterative re-sweep. A partial pass is acceptable; the next daily run converges further.

3. **Fetch full topology.** Fetch every non-archived issue (open AND closed) across the resolved team scope — open issues are required to verify the all-closed eligibility invariant in Step 5; a topology built from closed issues alone can't tell a truly-orphaned-and-done cluster from one still anchored to an open sibling. Same GraphQL bridge as Step 2.

   ```json
   {"query":"query($after: String) { issues(first: 250, after: $after, filter: { team: { id: { in: [\"<team-uuid-1>\", \"<team-uuid-2>\"] } } }) { nodes { id identifier title parent { id } state { type } completedAt canceledAt team { key } } pageInfo { hasNextPage endCursor } } }","variables":{"after":null}}
   ```

   The `issues` query excludes archived issues by default — exactly the live topology this pass needs. Loop while `pageInfo.hasNextPage` is true, feeding `endCursor` into `variables.after` on the next call. Given the 250-issue cap, this is typically one request, occasionally two — combined with Step 2's cap check, the whole pass runs 2–4 GraphQL requests total.

   **If pagination fails partway through**, do not proceed on the partial set — an incomplete topology can misjudge the all-closed invariant (a member fetched on a page that never arrived looks absent, not open). Abort the pass, report what was fetched, and let the next run retry clean.

4. **Rebuild cluster topology client-side.** For each fetched issue, walk `parent.id` upward until reaching an issue with no parent — that issue is the cluster's topmost ancestor (root). Group all fetched issues by their resolved root id; a root with no children found is a cluster of one (a standalone issue is its own cluster).

   **Edge case:** if an issue's `parent.id` points to an id *not present* in this pass's fetched set, treat that issue as its own root for this pass — its true parent was already archived in a prior sweep, so it's no longer part of the live topology. This is expected and normal on any run after the first.

5. **Determine eligibility per cluster.** A cluster is eligible when:
   - **Every member** (root + all descendants) has `state.type` in `{completed, canceled}` — the all-closed invariant. One open member anywhere in the cluster disqualifies the whole cluster, root included.
   - The cluster **root's** close date — `completedAt` if its `state.type` is `completed`, `canceledAt` if `canceled` — is at least `hold_hours` (Step 2) in the past, measured against `today` if the caller supplied it, else the current time. Only the root's close date matters; descendants' individual close dates are irrelevant to timing (the invariant already requires them all closed).

   Relations do **not** gate eligibility. Eligibility is cluster-membership-only — a `blocked_by` or other relation edge touching a cluster member never excludes it. When either endpoint of a relation archives, Linear archives the relation edge with it; that's an accepted side effect, not something this playbook manages or checks for.

6. **Build the candidate list** (one entry per eligible cluster, not per issue):

   ```yaml
   candidates:
     - root_identifier: <TEAM>-N
       root_title: <string>
       root_team: <team_prefix>
       cluster_size: <int>              # 1 = standalone issue
       member_identifiers: [<TEAM>-N, ...]
       root_close_date: <ISO date>
       hours_since_close: <float>
       hold_hours_applied: <float>      # the Step 2 value in effect for this run
   ```

7. **If `dry_run: true`:** return the candidate list with summary counts and the computed cap-pressure state (Step 9). Do NOT call archive. Output ends here.

8. **If `dry_run: false`:** for each candidate, archive the cluster **root only** via `mcp__linear-tactic__linear_archiveIssue`. Do not issue separate archive calls for descendants — archiving a root cascades to every descendant beneath it (verified during this design's build via live probe), so a per-child call is redundant and unnecessary.

9. **Classify the pass's exit state**, using the pre-run `active_issue_count` (Step 2) and this pass's `candidates_count.total` (Step 6, before any archival):
   - **`normal`** — pre-run `active_issue_count` ≤ 200. No pressure; the sweep ran at the 168-hour baseline.
   - **`exhausted`** — pre-run `active_issue_count` > 200, `hold_hours` at the 12-hour floor, AND zero eligible candidates found this pass. Maximum aggression already applied; nothing further is eligible right now. This is an accepted residual — the workspace stays over 200 until more clusters close and age past 12 hours, and the next daily run picks it up.
   - **`cap_pressure`** — pre-run `active_issue_count` > 200 and either `hold_hours` is above the floor, or at the floor with candidates found. The dipped hold is doing its job — aggressive but bounded.

   **All three states exit successfully.** None of them is a failure, and none escalates to the operator beyond ambient dead-man monitoring (the lane simply not having run) — autonomous cap management means the sweep handles its own pressure without a human in the loop. A partial pass in `cap_pressure` or `exhausted` is expected behavior, not a problem to surface.

10. **Handle failures.** If any cluster-root archive call fails (rate limit, transient API, permission), continue with the rest — one bad root doesn't stop the pass. Collect all failures; report together.

## Output

```yaml
mode: dry_run | live
teams_scoped: [<team_prefix>, ...]
active_issue_count: <int>        # pre-run, workspace-wide (Step 2)
hold_hours: <float>              # computed once this run (Step 2)
cap_state: normal | cap_pressure | exhausted
clusters_evaluated: <int>        # total clusters found in scope, eligible or not
candidates_count:
  total: <int>
  by_team:
    <team_prefix>: <int>
candidates:
  - root_identifier: <TEAM>-N
    root_title: <string>
    cluster_size: <int>
    member_identifiers: [<TEAM>-N, ...]
    root_close_date: <ISO date>
    hold_hours_applied: <float>
archived_count: <int>             # 0 in dry-run; count of successfully archived ROOTS in live (descendants cascade, uncounted here)
failures:
  - root_identifier: <ID>
    error: <string>
```

## Discipline

- **Never archive without an explicit non-dry-run decision.** The dry-run default is the safety floor.
- **All Configuration-listed teams by default** for the sweep scope (Step 1) — but the cap check (Step 2) is always workspace-wide regardless of that scope, since the cap it's protecting is workspace-wide. Skipping a listed team from the sweep leaves its clusters unswept; it does not change what the cap check sees.
- **Cluster is the unit of archival, not the issue.** A cluster with one open member anywhere in it is wholly ineligible — never archive part of a cluster.
- **Hold is computed once, from cap pressure, not a fixed calendar grace.** No mid-pass recomputation. This is the design's core departure from the old fixed 14-day grace: the hold responds to how close the workspace is to the cap, not a constant.
- **Root-only archive calls.** Cascade handles descendants; never issue a child-level archive call from this playbook.
- **Relations never gate eligibility.** Cluster membership is the only eligibility axis. Relation-edge archival on endpoint-archive is accepted, not managed here.
- **Recoverable.** Linear's archive is recoverable — archived issues remain in the database, just outside the active cap. If a sweep archives a cluster prematurely, it can be unarchived via `linear_unarchive*` operations (out of scope for this playbook; operator does it manually).
- **Three states, all success.** `normal`, `cap_pressure`, and `exhausted` are all terminal-success outcomes. No operator escalation beyond dead-man monitoring — a run that doesn't happen is what the monitor catches, never a run that converges partially.
- **Invocable identically from either caller.** The operator's `/linear archive` and any automated lane-triggered invocation run the exact same protocol above; only the `dry_run` default (and whatever the caller passes explicitly) differs.

## Failure modes to surface clearly

- **GraphQL bridge failure (cap check or topology fetch).** Neither Step 2 nor Step 3 has a fallback — both are required inputs to eligibility and hold sizing. Abort the pass, report the failure, retry on the next run.
- **Partial pagination on the topology fetch.** Do not compute eligibility from an incomplete issue set — abort rather than risk a false-positive all-closed read. Report what was fetched; the next run retries clean.
- **Linear API rate limit on cluster-root archive calls.** Pause + report partial completion; operator can re-invoke, or the next scheduled run picks up the remainder.
- **Network failure mid-batch (archive calls).** Report which roots succeeded; un-archived candidates remain eligible for the next sweep (their hold period has already passed, so they stay candidates).
- **Permission failure on a specific root.** Skip + report; don't abort the batch.

## What this playbook does NOT do

- Does NOT gate eligibility on relations — cluster-membership-only, per Step 5.
- Does NOT archive individual cluster members directly — root archive cascades; no per-child calls.
- Does NOT delete. Archive is recoverable; this playbook is sweep, not destroy.
- Does NOT recompute the hold period mid-pass, and does NOT iteratively re-sweep within a single run — one hold value, computed once, from the pre-run count. Convergence happens across runs, not within one.
- Does NOT check per-issue `[VALIDATION]` comments. Validation enforcement lives at close time (`mark_done` refuses without a verdict, per `closing.md`); at cluster granularity, an unvalidated Done ticket buried inside an otherwise-eligible cluster isn't a distinct signal worth carrying forward from the old per-issue design.
- Does NOT respect Linear UI's auto-archive setting (the whole point — that setting doesn't work for project-attached issues, which is why this playbook exists).
- Does NOT change the cap. Free tier is 250; this maintains headroom *within* the cap.
- Does NOT escalate to the operator on any of the three exit states (`normal` / `cap_pressure` / `exhausted`) — all three are accepted, successful outcomes.
