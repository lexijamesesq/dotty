#!/usr/bin/env bash
# The retained floor owns fetching/waiting; machine authentication is shared package code.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/assert.sh"
FLOOR="$SCRIPT_DIR/../../.github/scripts/margot-floor-gate.py"
python3 - "$FLOOR" <<'PY'
import importlib.util
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

class FloorTransport(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.request = dict(repository="example/repo", pr=7, base="a" * 40, head="b" * 40, triageCheckId=5, workflowRef="v0.10.0")
        self.config = {"review": {"requiredChecks": ["ci / checks", "trusted-scan / trusted-scan", "ci / retained"]}}
        self.rules = {"repos": {"example/repo": {"required_contexts": self.config["review"]["requiredChecks"] + ["review / margot"]}}}
        self.evidence = {"pull": {"privateText": "not for stdout"}, "triage": {"id": 5}, "checks": [{"app": {"id": 4862659}, "output": {"text": "opaque payload"}}]}
        self.write("request", self.request)
        self.write("config", self.config)
        self.write("rules", self.rules)
        self.write("evidence", self.evidence)
        self.evaluator = self.root / "evaluator"
        self.evaluator.write_text("#!/usr/bin/env python3\nimport json,sys\nfrom pathlib import Path\nassert sys.argv[1]=='evaluate-checks'\nv=json.loads(Path(sys.argv[3]).read_text())\nassert v['request']['triageCheckId']==5\nassert v['checks'][0]['app']['id']==4862659\nassert v['checks'][0]['output']['text']=='opaque payload'\nPath(sys.argv[5]).write_text(json.dumps({'green':True,'pending':[],'failing':[]}))\n")
        self.evaluator.chmod(0o755)

    def write(self, name, value):
        (self.root / name).write_text(json.dumps(value))

    def args(self):
        r = self.request
        return [script, "--rulesets", str(self.root / "rules"), "--repo", r["repository"], "--pr", str(r["pr"]), "--head-sha", r["head"], "--base-sha", r["base"], "--triage-check-id", str(r["triageCheckId"]), "--workflow-ref", r["workflowRef"], "--request-file", str(self.root / "request"), "--config-file", str(self.root / "config"), "--evaluator", str(self.evaluator), "--evidence-file", str(self.root / "evidence")]

    def run_floor(self, args=None):
        return subprocess.run([sys.executable, *(args or self.args())], capture_output=True, text=True)

    def test_delegate_preserves_raw_evidence(self):
        result = self.run_floor()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("floor_green=true", result.stdout)
        self.assertNotIn("not for stdout", result.stdout + result.stderr)

    def test_missing_or_mismatched_identity_fails(self):
        args = self.args()
        index = args.index("--base-sha")
        del args[index:index + 2]
        self.assertNotEqual(self.run_floor(args).returncode, 0)
        self.request["head"] = "c" * 40
        self.assertNotEqual(self.run_floor().returncode, 0)

    def test_declared_exception_cannot_disappear_from_bound_policy(self):
        self.config["review"]["requiredChecks"].remove("ci / retained")
        self.write("config", self.config)
        result = self.run_floor()
        self.assertEqual(result.returncode, 2)
        self.assertIn("floor_green=false", result.stdout)

    def test_failed_or_malformed_evaluator_fails_closed(self):
        for body in ("raise SystemExit(23)", "from pathlib import Path; import sys; Path(sys.argv[5]).write_text('{}')"):
            self.evaluator.write_text("#!/usr/bin/env python3\n" + body + "\n")
            result = self.run_floor()
            self.assertEqual(result.returncode, 2)
            self.assertIn("floor_green=false", result.stdout)

    def test_existing_waiter_rechecks_pending_then_passes(self):
        args = self.args()
        index = args.index("--evidence-file")
        del args[index:index + 2]
        with patch.object(sys, "argv", args), patch.object(floor, "_api", return_value={}), patch.object(floor, "_fetch_check_runs", return_value=[]), patch.object(floor, "evaluate", side_effect=[(False, ["ci / checks"], []), (True, [], [])]) as evaluate, patch.object(floor.time, "sleep") as sleep:
            self.assertEqual(floor.main(), 0)
            self.assertEqual(evaluate.call_count, 2)
            sleep.assert_called_once()

    def test_reported_failure_does_not_wait(self):
        args = self.args()
        index = args.index("--evidence-file")
        del args[index:index + 2]
        with patch.object(sys, "argv", args), patch.object(floor, "_api", return_value={}), patch.object(floor, "_fetch_check_runs", return_value=[]), patch.object(floor, "evaluate", return_value=(False, [], ["ci / checks"])), patch.object(floor.time, "sleep") as sleep:
            self.assertEqual(floor.main(), 0)
            sleep.assert_not_called()

unittest.main()
PY
