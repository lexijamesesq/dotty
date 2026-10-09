"""Wait for the migrated bound floor; the package owns check authentication.

The frozen legacy floor remains at its existing immutable producer commit.
This CLI requires the complete bound identity. It retains the existing fetch/wait
loop and delegates one-shot evaluation to the installed pinned package, so the
hosted producer, floor and reviewer share one payload/reporter contract.
"""

import argparse
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time

MARGOT_OWN_CHECKS = {"review / margot", "review / triage"}


def resolve_floor(rulesets: dict, repo: str) -> set[str] | None:
    entry = (rulesets.get("repos") or {}).get(repo)
    if not isinstance(entry, dict):
        return None
    floor = {
        c for c in entry.get("required_contexts", []) if c not in MARGOT_OWN_CHECKS
    }
    return floor or None


def _api(path: str) -> dict:
    return json.loads(subprocess.check_output(["gh", "api", path], text=True))


def _fetch_check_runs(repo: str, sha: str) -> list[dict]:
    # Keep full App ID, revision, ownership and machine payload fields. The typed
    # package filters expected reporter BEFORE selecting the newest matching run.
    out = subprocess.check_output(
        [
            "gh",
            "api",
            "--paginate",
            "--slurp",
            f"repos/{repo}/commits/{sha}/check-runs",
        ],
        text=True,
    )
    return [check for page in json.loads(out) for check in page["check_runs"]]


def evaluate(evaluator: str, evidence: dict) -> tuple[bool, list[str], list[str]]:
    with tempfile.TemporaryDirectory(prefix="margot-floor-") as scratch:
        incoming, outgoing = Path(scratch) / "input.json", Path(scratch) / "output.json"
        incoming.write_text(json.dumps(evidence), encoding="utf-8")
        subprocess.run(
            [
                evaluator,
                "evaluate-checks",
                "--input-file",
                str(incoming),
                "--output-file",
                str(outgoing),
            ],
            check=True,
        )
        result = json.loads(outgoing.read_text(encoding="utf-8"))
    # This is the evaluator's transport result, not another check payload schema.
    green, pending, failing = result["green"], result["pending"], result["failing"]
    if not isinstance(green, bool) or any(
        not isinstance(items, list) or any(not isinstance(item, str) for item in items)
        for items in (pending, failing)
    ):
        raise ValueError("invalid evaluator result")
    if green != (not pending and not failing):
        raise ValueError("inconsistent evaluator result")
    return green, pending, failing


def _emit(green: bool) -> None:
    line = f"floor_green={'true' if green else 'false'}"
    print(line)
    if os.environ.get("GITHUB_OUTPUT"):
        with open(os.environ["GITHUB_OUTPUT"], "a", encoding="utf-8") as stream:
            stream.write(line + "\n")


def main() -> int:
    parser = argparse.ArgumentParser()
    for name in (
        "rulesets",
        "repo",
        "head-sha",
        "base-sha",
        "workflow-ref",
        "request-file",
        "config-file",
        "evaluator",
    ):
        parser.add_argument(f"--{name}", required=True)
    parser.add_argument("--pr", type=int, required=True)
    parser.add_argument("--triage-check-id", type=int, required=True)
    parser.add_argument(
        "--evidence-file", help="offline raw pull/checks/triage fixture; no network"
    )
    parser.add_argument("--poll-seconds", type=int, default=90)
    parser.add_argument("--interval", type=int, default=15)
    args = parser.parse_args()
    try:
        rulesets = json.loads(Path(args.rulesets).read_text(encoding="utf-8"))
        request = json.loads(Path(args.request_file).read_text(encoding="utf-8"))
        config = json.loads(Path(args.config_file).read_text(encoding="utf-8"))
        expected = {
            "repository": args.repo,
            "pr": args.pr,
            "head": args.head_sha,
            "base": args.base_sha,
            "triageCheckId": args.triage_check_id,
            "workflowRef": args.workflow_ref,
        }
        if any(request.get(key) != value for key, value in expected.items()):
            raise ValueError("CLI identity differs from bound request")
        floor = resolve_floor(rulesets, args.repo)
        if floor is None:
            raise ValueError("no declared mechanical floor")
        if floor != set(config["review"]["requiredChecks"]) - MARGOT_OWN_CHECKS:
            raise ValueError("bound policy differs from declared floor")
        print(
            f"margot-floor-gate: floor for {args.repo} = {sorted(floor)} (margot excluded)",
            file=sys.stderr,
        )
        deadline = time.monotonic() + max(0, args.poll_seconds)
        while True:
            if args.evidence_file:
                raw = json.loads(Path(args.evidence_file).read_text(encoding="utf-8"))
            else:
                raw = {
                    "pull": _api(f"repos/{args.repo}/pulls/{args.pr}"),
                    "checks": _fetch_check_runs(args.repo, args.head_sha),
                    "triage": _api(
                        f"repos/{args.repo}/check-runs/{args.triage_check_id}"
                    ),
                }
            green, pending, failing = evaluate(
                args.evaluator,
                {
                    "request": request,
                    "config": config,
                    "pull": raw["pull"],
                    "checks": raw["checks"],
                    "triage": raw["triage"],
                },
            )
            print(
                f"margot-floor-gate: pending={pending} failing={failing}",
                file=sys.stderr,
            )
            if green or failing or args.evidence_file or time.monotonic() >= deadline:
                _emit(green)
                return 0
            time.sleep(min(max(1, args.interval), max(0, deadline - time.monotonic())))
    except (OSError, ValueError, KeyError, TypeError, subprocess.CalledProcessError):
        # Never print API evidence or raw provider diagnostics: text may be private.
        print(
            "margot-floor-gate: BLOCKED — cannot authenticate the bound floor",
            file=sys.stderr,
        )
        _emit(False)
        return 2


if __name__ == "__main__":
    sys.exit(main())
