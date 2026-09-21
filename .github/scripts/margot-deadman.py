#!/usr/bin/env python3
"""margot-deadman.py — dead-man backstop for a silent `margot` no-verdict.

WHY this exists: an intentional escalation signal (the `margot` check-run)
that fails silently when nobody sends it is a gate that fails open — the
dispatch can wake up and never post a verdict, and nothing today assigns a
human when that happens. The `margot` check-run's own content — a status
that mixes adequacy and band, whether it should route to the operator — is
the poster/finalize step's problem, not this script's. This script answers a
narrower question: has a PR sat open past a wait limit with NO completed
`margot` check-run on its head sha at all? If so, nobody is coming — assign
the operator so a human sees it.

NAMED PATTERN (DW#6): a GitHub Actions `schedule` cron job, run under the
standard `github-actions`/estate identity — NOT Margot, NOT a new App. This
mirrors `converge-on-merge.yml`'s scheduled drift check and
`renovate.yml`'s scheduled poll: read-only sweep across the enrolled repos,
one small mechanical decision, done. Cross-repo reach and the `issues:write`
grant needed to add an assignee both come from Ollie's existing App token —
`renovate.yml` already mints `permission-issues: write` from the same App
(id 4984137) to label its own PRs, so this is a reuse of an already-granted
scope, not a new one.

WAIT LIMIT is a config default this script sets (`DEFAULT_LIMIT_HOURS`), a
chosen default rather than an operator input. 6 hours is chosen because it is
comfortably longer than Margot's own review latency (single-digit minutes
per review, measured baseline) while still catching a stuck PR within the
same working day. Override with `--limit-hours` for a test run.

WHAT COUNTS AS "NO VERDICT": the most recently *started* check-run named
`margot` on the PR's head sha (ties broken the same way
`margot-floor-gate.py` breaks them — a repeated name on one head is a
re-run, and the current one is the one that started last) must exist AND
have `status == "completed"`. A `margot` check-run that exists but is still
`in_progress` is silence too — the whole point is nobody has heard a
verdict, and "it's running" three hours after a 30-minute review is exactly
the state defect #1 leaves you in. Any completed conclusion — success,
failure, action_required, neutral, cancelled, timed_out — counts as a
verdict and is left alone; this script has no opinion on what the verdict
says (that judgment, including the "APPROVED+HIGH must not silently
auto-merge" requirement, is X1's surface, not this one's).

PR AGE is measured from the PR's `created_at` — the plainest reading of
"has waited", and the one that can't be gamed by a push that resets
`updated_at` without ever getting a review.

IDEMPOTENT: a PR already assigned to the operator is left alone (no repeat
API call, no assignment-notification spam on every sweep).

Two run modes:
  * Live (default): fetches open PRs and check-runs for each `--repos` entry
    via `gh api` (GH_TOKEN from the environment — the Ollie token the
    workflow mints). `--dry-run` reports every decision without POSTing.
  * Fixture (`--fixture-file`): the decision logic (`should_assign` and its
    helpers) runs over a supplied JSON file instead of the network, so the
    three-way branch (stale+no-verdict / fresh / already-concluded) is
    provable offline and in CI without depending on the live fleet being in
    a particular state at test time. Always implies --dry-run.
    `margot-deadman.demo-fixture.json` (alongside this file) is a worked
    example: run
    `python3 .github/scripts/margot-deadman.py --fixture-file .github/scripts/margot-deadman.demo-fixture.json`
    to reproduce it — five synthetic PRs covering stale+no-verdict (assign),
    stale+still-`in_progress` (assign — a running-but-silent check is still
    silence), fresh (skip), stale+already-concluded (skip), and
    stale+no-verdict+already-assigned (skip — idempotency).
"""

from __future__ import annotations

import argparse
import json
import subprocess
import sys
from datetime import datetime, timezone

DEFAULT_LIMIT_HOURS = 6.0
MARGOT_CHECK = "margot"
DEFAULT_ASSIGNEE = "lexijamesesq"
# The one documented exclusion from the ruleset's repo list: a scratch/probe
# repo used to test the provisioner itself, not a delivery repo Margot gates
# in earnest. `hazel` is excluded too, but it is not present in
# `rulesets/default-branch.json` at all, so no entry is needed for it here.
DEFAULT_EXCLUDE_SHORT_NAMES = {"probe-local-to-merged"}


def latest_named_check_run(check_runs: list[dict], name: str) -> dict | None:
    """The current check-run of `name` on a head sha. Mirrors
    margot-floor-gate.py's tie-break: several check-runs can share one name
    on the same head (a re-run) — the current one is the one that started
    last."""
    named = [cr for cr in check_runs if cr.get("name") == name]
    if not named:
        return None
    named.sort(key=lambda cr: cr.get("started_at") or "", reverse=True)
    return named[0]


def has_margot_verdict(check_runs: list[dict]) -> bool:
    """True iff the current `margot` check-run has completed (any
    conclusion). False for "no check-run yet" and for "still running" alike
    — both are silence from this script's point of view."""
    cr = latest_named_check_run(check_runs, MARGOT_CHECK)
    if cr is None:
        return False
    return cr.get("status") == "completed"


def pr_age_hours(created_at: str, now: datetime) -> float:
    created = datetime.fromisoformat(created_at.replace("Z", "+00:00"))
    return (now - created).total_seconds() / 3600.0


def already_assigned(pr: dict, login: str) -> bool:
    return any(a.get("login") == login for a in pr.get("assignees", []))


def should_assign(
    pr: dict,
    check_runs: list[dict],
    now: datetime,
    limit_hours: float,
    assignee: str,
) -> tuple[bool, str]:
    """Returns (assign, reason) — reason is always populated, for logging
    even on the negative branches."""
    age = pr_age_hours(pr["created_at"], now)
    if age < limit_hours:
        return False, f"fresh ({age:.1f}h < {limit_hours}h limit)"
    if has_margot_verdict(check_runs):
        return False, f"already concluded ({age:.1f}h old, margot has a verdict)"
    if already_assigned(pr, assignee):
        return False, f"stale+no-verdict but already assigned ({age:.1f}h old)"
    return True, f"stale+no-verdict ({age:.1f}h >= {limit_hours}h limit, no margot conclusion)"


# --- live mode: gh api I/O -------------------------------------------------


def _gh_json(args: list[str]) -> object:
    out = subprocess.run(
        ["gh", "api", *args], capture_output=True, text=True, check=True
    )
    return json.loads(out.stdout)


def fetch_open_prs(repo: str) -> list[dict]:
    # `-X GET` is load-bearing: `gh api` silently switches its default method
    # to POST the moment any `-f`/`-F` param is present, which would otherwise
    # send this at the pulls endpoint's *create* action (422 "base, head
    # weren't supplied") instead of listing.
    return _gh_json(
        [
            "-X",
            "GET",
            f"repos/{repo}/pulls",
            "--paginate",
            "-f",
            "state=open",
            "-f",
            "per_page=100",
        ]
    )


def fetch_check_runs(repo: str, sha: str) -> list[dict]:
    result = _gh_json(["-X", "GET", f"repos/{repo}/commits/{sha}/check-runs", "--paginate"])
    if isinstance(result, dict):
        return result.get("check_runs", [])
    # --paginate over a paginated sub-key concatenates the check_runs arrays.
    runs: list[dict] = []
    for page in result if isinstance(result, list) else [result]:
        runs.extend(page.get("check_runs", []))
    return runs


def assign_operator(repo: str, number: int, assignee: str) -> None:
    subprocess.run(
        [
            "gh",
            "api",
            "-X",
            "POST",
            f"repos/{repo}/issues/{number}/assignees",
            "-f",
            f"assignees[]={assignee}",
        ],
        check=True,
    )


def enrolled_repos(rulesets_path: str, exclude_short_names: set[str]) -> list[str]:
    with open(rulesets_path, encoding="utf-8") as f:
        data = json.load(f)
    repos = []
    for full in data["repos"]:
        short = full.split("/", 1)[1] if "/" in full else full
        if short in exclude_short_names:
            continue
        repos.append(full)
    return sorted(repos)


# --- driver ------------------------------------------------------------


def sweep(
    repos: list[str],
    now: datetime,
    limit_hours: float,
    assignee: str,
    dry_run: bool,
    prs_by_repo: dict[str, list[dict]] | None = None,
    check_runs_by_key: dict[str, list[dict]] | None = None,
) -> int:
    """Returns the count of PRs assigned (or, under --dry-run, that WOULD be
    assigned). `prs_by_repo` / `check_runs_by_key` let the fixture mode
    substitute fetched data; live mode leaves them None and calls `gh api`."""
    assigned = 0
    for repo in repos:
        try:
            prs = (
                prs_by_repo[repo]
                if prs_by_repo is not None
                else fetch_open_prs(repo)
            )
        except Exception as exc:  # noqa: BLE001 — one repo's failure must not sink the sweep
            print(f"::warning::{repo}: could not list open PRs ({exc})", file=sys.stderr)
            continue
        for pr in prs:
            number = pr["number"]
            sha = pr["head"]["sha"] if "head" in pr else pr.get("head_sha")
            key = f"{repo}#{number}"
            try:
                check_runs = (
                    check_runs_by_key[key]
                    if check_runs_by_key is not None
                    else fetch_check_runs(repo, sha)
                )
            except Exception as exc:  # noqa: BLE001
                print(f"::warning::{key}: could not read check-runs ({exc})", file=sys.stderr)
                continue
            assign, reason = should_assign(pr, check_runs, now, limit_hours, assignee)
            verb = "WOULD ASSIGN" if dry_run and assign else ("ASSIGN" if assign else "skip")
            print(f"{verb:12s} {key:40s} {reason}")
            if assign:
                assigned += 1
                if not dry_run:
                    assign_operator(repo, number, assignee)
    return assigned


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--repos", default="", help="comma-separated owner/repo list")
    ap.add_argument(
        "--rulesets-file",
        default="rulesets/default-branch.json",
        help="used to derive --repos when it is not passed explicitly",
    )
    ap.add_argument("--limit-hours", type=float, default=DEFAULT_LIMIT_HOURS)
    ap.add_argument("--assignee", default=DEFAULT_ASSIGNEE)
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument(
        "--fixture-file",
        default="",
        help="JSON file of [{repo, number, created_at, assignees, head:{sha}, check_runs}] "
        "for an offline test run; implies --dry-run",
    )
    args = ap.parse_args()

    now = datetime.now(timezone.utc)

    if args.fixture_file:
        with open(args.fixture_file, encoding="utf-8") as f:
            fixture = json.load(f)
        prs_by_repo: dict[str, list[dict]] = {}
        check_runs_by_key: dict[str, list[dict]] = {}
        for row in fixture:
            repo = row["repo"]
            pr = {
                "number": row["number"],
                "created_at": row["created_at"],
                "assignees": row.get("assignees", []),
                "head": {"sha": row.get("sha", "deadbeef")},
            }
            prs_by_repo.setdefault(repo, []).append(pr)
            check_runs_by_key[f"{repo}#{row['number']}"] = row.get("check_runs", [])
        repos = sorted(prs_by_repo)
        assigned = sweep(
            repos,
            now,
            args.limit_hours,
            args.assignee,
            dry_run=True,
            prs_by_repo=prs_by_repo,
            check_runs_by_key=check_runs_by_key,
        )
        print(f"\n[fixture mode] {assigned} PR(s) would be assigned to {args.assignee}.")
        return 0

    repos = (
        [r.strip() for r in args.repos.split(",") if r.strip()]
        if args.repos
        else enrolled_repos(args.rulesets_file, DEFAULT_EXCLUDE_SHORT_NAMES)
    )
    if not repos:
        print("margot-deadman: no repos to sweep (empty --repos and no rulesets file)", file=sys.stderr)
        return 2

    assigned = sweep(repos, now, args.limit_hours, args.assignee, dry_run=args.dry_run)
    mode = "dry-run — nothing written" if args.dry_run else "live"
    print(f"\n[{mode}] {assigned} PR(s) {'would be' if args.dry_run else 'were'} assigned to {args.assignee}.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
