"""margot-floor-gate.py — sequence Margot AFTER the mechanical floor is green.

The boundary: mechanical gates are deterministic and gate FIRST; Margot is
judgment and runs ONLY after every mechanical required check on the PR head is
green. This script is the SEQUENCING gate — it READS check-run status to decide
whether Margot may proceed. It never runs, re-runs, or revalidates mechanical,
and it never feeds mechanical results to Margot's agent (the review job passes the
agent PR facts only). A green/not-green decision here is ordering, not judgment.

"The mechanical floor" for a repo is resolved from dotty's COMMITTED
`rulesets/default-branch.json` → `.repos[<repo>].required_contexts` (declared
state, checked out at a pin — never a live branch-protection/rulesets API, which
Margot's token has no scope for), MINUS the literal check name `margot` itself.
Excluding `margot` is load-bearing: a repo (e.g. probe-local-to-merged) may
REQUIRE the `margot` check for merge, and a floor that included it would have
Margot wait on her own check — a permanent self-deadlock.

FAIL-CLOSED: a repo with no entry in the rulesets, or an empty required_contexts,
resolves to NO declared floor → Margot does NOT run. Rationale: no declared floor
means the repo is not yet enrolled in the estate gate = "nothing has passed" =
Margot waits. Rollout gives every enrolled repo a floor.

In CI the check-run statuses are fetched from the GitHub API with a SHORT bounded
poll (a residual-race safety net for the window between a workflow_run wake-up and
the last check-run write — NOT a long wait; the real retrigger is the caller's
workflow_run trigger, and a long poll would hold a runner and starve the review).
For tests, pass --check-runs-file to supply a check-runs payload directly, so the
pure floor-resolution and green-evaluation logic is verifiable without the network.

Output: writes `floor_green=true|false` to $GITHUB_OUTPUT (and stdout). Exits 0
in all normal cases (the boolean output is the gate; the review job keys off it).
Exit 2 only on a usage/IO error it cannot proceed from.
"""

import argparse
import json
import os
import subprocess
import sys
import time

MARGOT_CHECK = "margot"


def resolve_floor(rulesets: dict, repo: str) -> set[str] | None:
    """The mechanical floor for <repo>: its required_contexts minus `margot`.
    Returns None (fail-closed) if the repo has no entry or an empty floor."""
    repos = rulesets.get("repos") or {}
    entry = repos.get(repo)
    if not isinstance(entry, dict):
        return None
    contexts = entry.get("required_contexts") or []
    floor = {c for c in contexts if c and c != MARGOT_CHECK}
    return floor or None


def evaluate(floor: set[str], check_runs: list[dict]) -> tuple[bool, list[str], list[str]]:
    """Given the floor and the head SHA's check-runs, return
    (all_green, pending, failing). A floor context is green iff a check-run with
    that name has conclusion 'success'. No check-run yet ⇒ pending; a non-success
    conclusion ⇒ failing; status != 'completed' ⇒ pending."""
    latest: dict[str, dict] = {}
    for cr in check_runs:
        name = cr.get("name")
        if name in floor:
            latest[name] = cr  # check-runs API returns newest first per name group; last wins is fine for status
    pending, failing = [], []
    for ctx in sorted(floor):
        cr = latest.get(ctx)
        if cr is None or cr.get("status") != "completed":
            pending.append(ctx)
        elif cr.get("conclusion") != "success":
            failing.append(ctx)
    return (not pending and not failing), pending, failing


def _fetch_check_runs(repo: str, sha: str) -> list[dict]:
    """Fetch all check-runs for a commit via the gh CLI (github.token in CI)."""
    out = subprocess.run(
        ["gh", "api", "--paginate",
         f"repos/{repo}/commits/{sha}/check-runs",
         "--jq", ".check_runs[] | {name, status, conclusion}"],
        capture_output=True, text=True, check=True,
    ).stdout
    return [json.loads(line) for line in out.splitlines() if line.strip()]


def _emit(floor_green: bool) -> None:
    val = "true" if floor_green else "false"
    print(f"floor_green={val}")
    gh_out = os.environ.get("GITHUB_OUTPUT")
    if gh_out:
        with open(gh_out, "a", encoding="utf-8") as f:
            f.write(f"floor_green={val}\n")


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--rulesets", required=True)
    ap.add_argument("--repo", required=True)
    ap.add_argument("--head-sha", default="")
    ap.add_argument("--check-runs-file", default="")  # test mode: a JSON list of {name,status,conclusion}
    ap.add_argument("--poll-seconds", type=int, default=90)
    ap.add_argument("--interval", type=int, default=15)
    args = ap.parse_args()

    try:
        with open(args.rulesets, encoding="utf-8") as f:
            rulesets = json.load(f)
    except (OSError, ValueError) as e:
        print(f"margot-floor-gate: BLOCKED — cannot read rulesets {args.rulesets}: {e}", file=sys.stderr)
        return 2

    floor = resolve_floor(rulesets, args.repo)
    if floor is None:
        print(f"margot-floor-gate: no declared mechanical floor for {args.repo} "
              f"(not enrolled / empty required_contexts) — fail-closed, Margot does not run.", file=sys.stderr)
        _emit(False)
        return 0
    print(f"margot-floor-gate: floor for {args.repo} = {sorted(floor)} (margot excluded)", file=sys.stderr)

    # Test mode: evaluate a supplied payload once, no network, no poll.
    if args.check_runs_file:
        with open(args.check_runs_file, encoding="utf-8") as f:
            check_runs = json.load(f)
        green, pending, failing = evaluate(floor, check_runs)
        print(f"margot-floor-gate: pending={pending} failing={failing}", file=sys.stderr)
        _emit(green)
        return 0

    if not args.head_sha:
        print("margot-floor-gate: BLOCKED — --head-sha required in CI mode", file=sys.stderr)
        return 2

    # CI mode: short bounded poll for the residual race (workflow_run event vs the
    # last check-run write). NOT a long wait — the caller's workflow_run trigger is
    # the real retrigger; a failing floor check short-circuits immediately.
    deadline = time.monotonic() + max(0, args.poll_seconds)
    while True:
        try:
            check_runs = _fetch_check_runs(args.repo, args.head_sha)
        except (subprocess.CalledProcessError, ValueError) as e:
            print(f"margot-floor-gate: BLOCKED — cannot read check-runs: {e}", file=sys.stderr)
            return 2
        green, pending, failing = evaluate(floor, check_runs)
        if green:
            print("margot-floor-gate: mechanical floor is green — Margot may proceed.", file=sys.stderr)
            _emit(True)
            return 0
        if failing:
            print(f"margot-floor-gate: floor checks failing={failing} — Margot does not run.", file=sys.stderr)
            _emit(False)
            return 0
        if time.monotonic() >= deadline:
            print(f"margot-floor-gate: floor not green within poll window (pending={pending}) — "
                  f"Margot does not run this pass; the workflow_run wake-up re-evaluates on completion.", file=sys.stderr)
            _emit(False)
            return 0
        time.sleep(max(1, args.interval))


if __name__ == "__main__":
    sys.exit(main())
