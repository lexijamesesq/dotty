#!/usr/bin/env bash
# Exercise the ordinary native waiter; GitHub evidence is the mocked boundary.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/assert.sh"
FLOOR="$SCRIPT_DIR/../../.github/scripts/margot-floor-gate.py"
python3 - "$FLOOR" <<'PY'
import contextlib
import importlib.util
import io
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("floor", sys.argv[1])
floor = importlib.util.module_from_spec(spec)
spec.loader.exec_module(floor)
script = sys.argv.pop()

class NativeFloor(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.head = "b" * 40
        self.config = {"review": {
            "requiredChecks": ["checks / checks", "ci / retained"],
            "requiredCheckReporters": {"checks / checks": 15368, "ci / retained": 15368},
            "trustedCheckActors": ["github-actions"],
            "allowedSkippedChecks": ["ci / retained"]}}
        self.checks = [self.check("checks / checks"), self.check("ci / retained")]

    def check(self, name, **changes):
        return dict(name=name, head_sha=self.head, app={"id":15368, "slug":"github-actions"},
                    id=1, started_at="2026-10-10T10:00:00Z", status="completed",
                    conclusion="success", **changes)

    def run_floor(self, fetch_error=None):
        config = self.root / "config"
        config.write_text(json.dumps(self.config))
        output = io.StringIO()
        with patch.object(sys, "argv", [script, "--repo", "example/repo", "--head-sha", self.head,
                                        "--config-file", str(config), "--poll-seconds", "0"]), \
             patch.object(floor.subprocess, "check_output", side_effect=fetch_error,
                          return_value=json.dumps([{ "check_runs": self.checks }])), \
             contextlib.redirect_stdout(output), contextlib.redirect_stderr(io.StringIO()):
            status = floor.main()
        return status, output.getvalue()

    def test_green_floor_and_unrelated_review_checks(self):
        self.checks += [self.check("review / margot"), self.check("review / triage")]
        self.checks[-1]["conclusion"] = "failure"
        self.assertEqual(self.run_floor(), (0, "floor_green=true\n"))

    def test_missing_or_running_prerequisite_waits(self):
        self.checks.pop()
        self.assertEqual(self.run_floor(), (0, "floor_green=false\n"))
        self.checks.append(self.check("ci / retained"))
        self.checks[-1]["status"] = "in_progress"
        self.assertEqual(self.run_floor(), (0, "floor_green=false\n"))

    def test_failed_or_cancelled_prerequisite_blocks(self):
        for outcome in ("failure", "cancelled"):
            self.checks[0]["conclusion"] = outcome
            self.assertEqual(self.run_floor(), (0, "floor_green=false\n"))

    def test_only_configured_job_may_be_skipped(self):
        self.checks[1]["conclusion"] = "skipped"
        self.assertEqual(self.run_floor(), (0, "floor_green=true\n"))
        self.checks[0]["conclusion"] = "skipped"
        self.assertEqual(self.run_floor(), (0, "floor_green=false\n"))

    def test_latest_run_owns_result_before_reporter_validation(self):
        old = dict(self.checks[0], id=0, conclusion="cancelled")
        self.checks.append(old)
        self.assertEqual(self.run_floor(), (0, "floor_green=true\n"))
        newest = dict(self.checks[0], id=2, app={"id":999, "slug":"github-actions"})
        self.checks.insert(0, newest)
        self.assertEqual(self.run_floor(), (0, "floor_green=false\n"))
        # A rerun can be queued before it has started_at. Its newer ID still owns the result.
        self.checks = [self.check("checks / checks"), self.check("ci / retained"),
                       dict(self.check("checks / checks"), id=3, started_at=None,
                            status="queued", conclusion=None)]
        self.assertEqual(self.run_floor(), (0, "floor_green=false\n"))

    def test_wrong_head_or_actor_blocks(self):
        self.checks[0]["head_sha"] = "c" * 40
        self.assertEqual(self.run_floor(), (0, "floor_green=false\n"))
        self.checks[0]["head_sha"] = self.head
        self.checks[0]["app"]["slug"] = "foreign"
        self.assertEqual(self.run_floor(), (0, "floor_green=false\n"))

    def test_missing_policy_or_unreadable_evidence_fails_closed(self):
        del self.config["review"]["requiredCheckReporters"]["ci / retained"]
        self.assertEqual(self.run_floor(), (2, "floor_green=false\n"))
        self.config["review"]["requiredCheckReporters"]["ci / retained"] = 15368
        self.assertEqual(self.run_floor(fetch_error=subprocess.CalledProcessError(23, "gh")),
                         (2, "floor_green=false\n"))

    def test_pending_then_green_uses_existing_wait_loop(self):
        config = self.root / "config"
        config.write_text(json.dumps(self.config))
        output = io.StringIO()
        pending = [dict(self.checks[0], status="in_progress"), self.checks[1]]
        with patch.object(sys, "argv", [script, "--repo", "example/repo", "--head-sha", self.head,
                                        "--config-file", str(config)]), \
             patch.object(floor.subprocess, "check_output",
                          side_effect=[json.dumps([{ "check_runs": pending }]),
                                       json.dumps([{ "check_runs": self.checks }])]), \
             patch.object(floor.time, "sleep"), contextlib.redirect_stdout(output), \
             contextlib.redirect_stderr(io.StringIO()):
            self.assertEqual(floor.main(), 0)
        self.assertEqual(output.getvalue(), "floor_green=true\n")

unittest.main()
PY
