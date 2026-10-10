"""Wait for native prerequisite checks on the requested head.

Trusted route/binding supplies the required names, reporters and skipped-check
allowances. This ordinary check-run waiter never publishes a check or recovers
another run. The reviewer authenticates classification and rechecks prerequisites
before publication.
"""

import argparse
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import time


def _recency_key(check: dict) -> tuple[int, str]:
    # A newer queued run has no start time yet; its ID still supersedes the old result.
    return int(check.get("id") or 0), check.get("started_at") or ""


def evaluate(
    config: dict, head: str, check_runs: list[dict]
) -> tuple[bool, list[str], list[str]]:
    """Select the latest named check, then require its bound head and reporter."""
    latest: dict[str, dict] = {}
    for check in check_runs:
        name = check.get("name")
        if name not in config["requiredChecks"]:
            continue
        previous = latest.get(name)
        if previous is None or _recency_key(check) > _recency_key(previous):
            latest[name] = check
    pending, failing = [], []
    for name in sorted(config["requiredChecks"]):
        check = latest.get(name)
        if check is None:
            pending.append(name)
            continue
        app = check.get("app") or {}
        if (
            check.get("head_sha") != head
            or app.get("id") != config["requiredCheckReporters"][name]
            or app.get("slug") not in config["trustedCheckActors"]
        ):
            failing.append(name)
        elif check.get("status") != "completed":
            pending.append(name)
        elif not (
            check.get("conclusion") == "success"
            or (
                check.get("conclusion") == "skipped"
                and name in config["allowedSkippedChecks"]
            )
        ):
            failing.append(name)
    return not pending and not failing, pending, failing


def _fetch_check_runs(repo: str, sha: str) -> list[dict]:
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


def _emit(green: bool) -> None:
    line = f"floor_green={'true' if green else 'false'}"
    print(line)
    if os.environ.get("GITHUB_OUTPUT"):
        with open(os.environ["GITHUB_OUTPUT"], "a", encoding="utf-8") as stream:
            stream.write(line + "\n")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--repo", required=True)
    parser.add_argument("--head-sha", required=True)
    parser.add_argument("--config-file", required=True)
    parser.add_argument("--poll-seconds", type=int, default=90)
    parser.add_argument("--interval", type=int, default=15)
    args = parser.parse_args()
    try:
        if not re.fullmatch(r"[0-9a-f]{40}", args.head_sha):
            raise ValueError("invalid head")
        config = json.loads(Path(args.config_file).read_text(encoding="utf-8"))[
            "review"
        ]
        required = config["requiredChecks"]
        reporters = config["requiredCheckReporters"]
        if (
            not isinstance(required, list)
            or not required
            or any(not isinstance(name, str) or not name for name in required)
            or any(
                type(reporters.get(name)) is not int or reporters[name] <= 0
                for name in required
            )
            or not isinstance(config["allowedSkippedChecks"], list)
            or not isinstance(config["trustedCheckActors"], list)
        ):
            raise ValueError("invalid prerequisite policy")
        print(
            f"margot-floor-gate: floor for {args.repo} = {sorted(required)}",
            file=sys.stderr,
        )
        deadline = time.monotonic() + max(0, args.poll_seconds)
        while True:
            green, pending, failing = evaluate(
                config, args.head_sha, _fetch_check_runs(args.repo, args.head_sha)
            )
            print(
                f"margot-floor-gate: pending={pending} failing={failing}",
                file=sys.stderr,
            )
            if green or failing or time.monotonic() >= deadline:
                _emit(green)
                return 0
            time.sleep(min(max(1, args.interval), max(0, deadline - time.monotonic())))
    except (
        OSError,
        ValueError,
        KeyError,
        TypeError,
        AttributeError,
        subprocess.CalledProcessError,
    ):
        # API responses and diagnostics can contain private text.
        print(
            "margot-floor-gate: BLOCKED — cannot read the bound floor", file=sys.stderr
        )
        _emit(False)
        return 2


if __name__ == "__main__":
    sys.exit(main())
