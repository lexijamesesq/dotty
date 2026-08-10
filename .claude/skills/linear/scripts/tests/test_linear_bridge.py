#!/usr/bin/env python3
"""
Unit tests for linear_bridge.py's transport layer (error-class detection,
retry/backoff, exit-code mapping) and its pure helper functions. Bridge
invocations are mocked via tests/fixtures/stub_bridge.py, a stand-in bridge
command that replays a scripted response sequence — never a network call.

Every Script-homed piece of behavior this module owns gets at least one
failing fixture that proves it catches its named failure: config-gap
(missing/unexecutable bridge command), auth failure, GraphQL-level error,
transient/network failure (with and without eventual recovery), and the
ambiguous-operator refusal. `time.sleep` is patched out during retry tests
so the suite stays fast — the retry *count* and *backoff schedule* are
asserted directly instead of timed.
"""
import json
import os
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
import linear_bridge as lb  # noqa: E402

STUB_BRIDGE = os.path.join(os.path.dirname(os.path.abspath(__file__)), "fixtures", "stub_bridge.py")
STUB_CMD = [sys.executable, STUB_BRIDGE]


def script_responses(responses):
    """Set up env vars so the stub bridge replays `responses` in order.
    Returns the counter-file path (caller is responsible for cleanup via
    the returned cleanup callable, or just let tempfile clean up)."""
    fd, counter_path = tempfile.mkstemp(prefix="stub-counter-")
    os.close(fd)
    os.unlink(counter_path)  # stub creates it fresh on first write
    os.environ["STUB_BRIDGE_RESPONSES"] = json.dumps(responses)
    os.environ["STUB_BRIDGE_COUNTER_FILE"] = counter_path
    return counter_path


def call_count(counter_path):
    if not os.path.exists(counter_path):
        return 0
    with open(counter_path) as f:
        return int(f.read().strip() or "0")


class IdentifierResolutionTests(unittest.TestCase):
    def test_is_uuid_true_for_real_shape(self):
        self.assertTrue(lb.is_uuid("12345678-1234-1234-1234-123456789abc"))

    def test_is_uuid_false_for_identifier(self):
        self.assertFalse(lb.is_uuid("ACR-12"))

    def test_parse_identifier_matches_team_number(self):
        self.assertEqual(lb.parse_identifier("ACR-12"), ("ACR", 12))

    def test_parse_identifier_uppercases_team(self):
        self.assertEqual(lb.parse_identifier("acr-12"), ("ACR", 12))

    def test_parse_identifier_none_for_uuid(self):
        self.assertIsNone(lb.parse_identifier("12345678-1234-1234-1234-123456789abc"))

    def test_parse_identifier_none_for_garbage(self):
        self.assertIsNone(lb.parse_identifier("not-an-id-at-all"))


class LintBodyTests(unittest.TestCase):
    def test_bare_mention_is_a_violation(self):
        violations = lb.find_bare_mentions("ping @linear about this")
        self.assertEqual(len(violations), 1)
        self.assertEqual(violations[0]["name"], "linear")

    def test_escaped_mention_is_clean(self):
        violations = lb.find_bare_mentions("ping `@linear` about this")
        self.assertEqual(violations, [])

    def test_all_three_agent_names_detected(self):
        text = "@linear and @attack-kitty and @traffic-cone are all bare"
        violations = lb.find_bare_mentions(text)
        names = {v["name"] for v in violations}
        self.assertEqual(names, {"linear", "attack-kitty", "traffic-cone"})

    def test_mixed_escaped_and_bare(self):
        text = "`@linear` is fine but @attack-kitty is not"
        violations = lb.find_bare_mentions(text)
        self.assertEqual(len(violations), 1)
        self.assertEqual(violations[0]["name"], "attack-kitty")


class LintBodyCliTests(unittest.TestCase):
    def test_clean_input_via_stdin(self):
        import io
        with patch("sys.stdin", io.StringIO("nothing to escape here")):
            code = lb.main(["lint-body"])
        self.assertEqual(code, lb.EXIT_OK)

    def test_violation_input_exits_one(self):
        import io
        with patch("sys.stdin", io.StringIO("hey @linear look at this")):
            code = lb.main(["lint-body"])
        self.assertEqual(code, 1)


class ResolveBridgeCmdTests(unittest.TestCase):
    def setUp(self):
        self.saved = os.environ.pop("LINEAR_GQL_CMD", None)

    def tearDown(self):
        if self.saved is not None:
            os.environ["LINEAR_GQL_CMD"] = self.saved

    def test_missing_raises_config_error(self):
        with self.assertRaises(lb.BridgeConfigError):
            lb.resolve_bridge_cmd(None)

    def test_env_var_used_when_no_flag(self):
        os.environ["LINEAR_GQL_CMD"] = "some-bridge --flag"
        self.assertEqual(lb.resolve_bridge_cmd(None), ["some-bridge", "--flag"])

    def test_flag_overrides_env(self):
        os.environ["LINEAR_GQL_CMD"] = "env-bridge"
        self.assertEqual(lb.resolve_bridge_cmd("flag-bridge"), ["flag-bridge"])

    def test_nonexistent_command_raises_config_error_on_invocation(self):
        bridge = lb.resolve_bridge_cmd("/no/such/executable/anywhere")
        with self.assertRaises(lb.BridgeConfigError):
            lb.run_graphql(bridge, "query { viewer { id } }")


class RunGraphqlSuccessTests(unittest.TestCase):
    def setUp(self):
        self.counter = script_responses([
            {"stdout": {"data": {"viewer": {"id": "actor-1"}}}, "returncode": 0},
        ])

    def test_success_returns_parsed_data(self):
        result = lb.run_graphql(STUB_CMD, "query { viewer { id } }")
        self.assertEqual(result["data"]["viewer"]["id"], "actor-1")
        self.assertEqual(call_count(self.counter), 1)


class RunGraphqlAuthFailureTests(unittest.TestCase):
    def test_auth_error_message_raises_immediately_no_retry(self):
        counter = script_responses([
            {"stdout": {"errors": [{"message": "Unauthorized: invalid token"}]}, "returncode": 1},
        ])
        with self.assertRaises(lb.BridgeAuthError):
            lb.run_graphql(STUB_CMD, "query { viewer { id } }")
        self.assertEqual(call_count(counter), 1, "auth failures must not retry")

    def test_stderr_401_pattern_raises_auth_error(self):
        counter = script_responses([
            {"stdout": "", "stderr": "curl: (22) The requested URL returned error: 401", "returncode": 22},
        ])
        with self.assertRaises(lb.BridgeAuthError):
            lb.run_graphql(STUB_CMD, "query { viewer { id } }")
        self.assertEqual(call_count(counter), 1)


class RunGraphqlGraphQLErrorTests(unittest.TestCase):
    def test_graphql_level_error_raises_with_payload_echoed(self):
        script_responses([
            {"stdout": {"errors": [{"message": "Entity not found: Issue"}]}, "returncode": 0},
        ])
        with self.assertRaises(lb.GraphQLAPIError) as cm:
            lb.run_graphql(STUB_CMD, 'query { issue(id: "bad-id") { id } }')
        self.assertIn("Entity not found", str(cm.exception))
        self.assertIsNotNone(cm.exception.payload)
        self.assertIn("errors", cm.exception.payload)


class RunGraphqlTransientTests(unittest.TestCase):
    def test_scope_glitch_recovers_after_retries(self):
        """'App user not valid' is the existing /linear law's named transient
        scope failure — it must retry, not raise immediately."""
        counter = script_responses([
            {"stdout": {"errors": [{"message": "App user not valid"}]}, "returncode": 1},
            {"stdout": {"errors": [{"message": "App user not valid"}]}, "returncode": 1},
            {"stdout": {"data": {"viewer": {"id": "actor-1"}}}, "returncode": 0},
        ])
        with patch("linear_bridge.time.sleep") as mock_sleep:
            result = lb.run_graphql(STUB_CMD, "query { viewer { id } }")
        self.assertEqual(result["data"]["viewer"]["id"], "actor-1")
        self.assertEqual(call_count(counter), 3)
        self.assertEqual(mock_sleep.call_args_list[0].args[0], 1)
        self.assertEqual(mock_sleep.call_args_list[1].args[0], 3)

    def test_scope_glitch_exhausts_retries_and_raises_transient(self):
        counter = script_responses([
            {"stdout": {"errors": [{"message": "App user not valid"}]}, "returncode": 1},
        ])  # every attempt replays this same failure (clamped index)
        with patch("linear_bridge.time.sleep"):
            with self.assertRaises(lb.TransientBridgeError):
                lb.run_graphql(STUB_CMD, "query { viewer { id } }")
        self.assertEqual(call_count(counter), 3, "1 initial attempt + 2 retries")

    def test_network_pattern_in_stderr_is_transient(self):
        counter = script_responses([
            {"stdout": "", "stderr": "curl: (6) Could not resolve host: api.linear.app", "returncode": 6},
        ])
        with patch("linear_bridge.time.sleep"):
            with self.assertRaises(lb.TransientBridgeError):
                lb.run_graphql(STUB_CMD, "query { viewer { id } }")
        self.assertEqual(call_count(counter), 3)

    def test_curl_transient_returncode_without_pattern_is_transient(self):
        counter = script_responses([
            {"stdout": "", "stderr": "some unrecognized curl output", "returncode": 28},
        ])
        with patch("linear_bridge.time.sleep"):
            with self.assertRaises(lb.TransientBridgeError):
                lb.run_graphql(STUB_CMD, "query { viewer { id } }")
        self.assertEqual(call_count(counter), 3)

    def test_unrecognized_failure_shape_retries_then_surfaces_transient(self):
        """A failure this script can't classify never gets silently dropped —
        it is treated conservatively as transient (retried, then surfaced)."""
        counter = script_responses([
            {"stdout": "", "stderr": "mystery failure nobody has seen before", "returncode": 99},
        ])
        with patch("linear_bridge.time.sleep"):
            with self.assertRaises(lb.TransientBridgeError) as cm:
                lb.run_graphql(STUB_CMD, "query { viewer { id } }")
        self.assertIn("mystery failure", str(cm.exception))
        self.assertEqual(call_count(counter), 3)


class MainExitCodeTests(unittest.TestCase):
    """CLI-level tests through main(), asserting the exit-code mapping —
    each error class from run_graphql surfaces through the correct code."""

    def test_viewer_success_exit_zero(self):
        script_responses([{"stdout": {"data": {"viewer": {"id": "actor-1", "name": "App", "email": "a@x"}}}, "returncode": 0}])
        code = lb.main(["--bridge-cmd", " ".join(STUB_CMD), "viewer"])
        self.assertEqual(code, lb.EXIT_OK)

    def test_missing_bridge_cmd_exit_two(self):
        os.environ.pop("LINEAR_GQL_CMD", None)
        code = lb.main(["viewer"])
        self.assertEqual(code, lb.EXIT_CONFIG_GAP)

    def test_auth_failure_exit_three(self):
        script_responses([{"stdout": {"errors": [{"message": "Forbidden"}]}, "returncode": 1}])
        code = lb.main(["--bridge-cmd", " ".join(STUB_CMD), "viewer"])
        self.assertEqual(code, lb.EXIT_AUTH)

    def test_graphql_error_exit_four(self):
        script_responses([{"stdout": {"errors": [{"message": "Entity not found: Issue"}]}, "returncode": 0}])
        code = lb.main(["--bridge-cmd", " ".join(STUB_CMD), "issue", "ACR-999"])
        self.assertEqual(code, lb.EXIT_GRAPHQL)

    def test_transient_exhausted_exit_five(self):
        script_responses([{"stdout": "", "stderr": "Connection refused", "returncode": 7}])
        with patch("linear_bridge.time.sleep"):
            code = lb.main(["--bridge-cmd", " ".join(STUB_CMD), "viewer"])
        self.assertEqual(code, lb.EXIT_TRANSIENT)

    def test_claim_write_dry_run_via_cli_with_no_bridge_configured(self):
        """Regression: claim-write --dry-run must never require a bridge
        command — it never touches the bridge at all (see claim_write()'s
        dry_run short-circuit) — so main() must defer bridge-cmd resolution
        for this exact case rather than resolving it unconditionally up
        front."""
        os.environ.pop("LINEAR_GQL_CMD", None)
        code = lb.main([
            "claim-write", "uuid-123",
            "--state", "state-ip", "--delegate", "viewer-1",
            "--dry-run",
        ])
        self.assertEqual(code, lb.EXIT_OK, "dry-run must succeed with zero bridge configuration")

    def test_claim_write_without_dry_run_still_requires_bridge_cmd(self):
        """Companion case: a REAL claim-write (no --dry-run) must still
        refuse on a missing bridge command — the deferral is dry-run-only,
        not a blanket skip."""
        os.environ.pop("LINEAR_GQL_CMD", None)
        code = lb.main([
            "claim-write", "uuid-123",
            "--state", "state-ip", "--delegate", "viewer-1",
        ])
        self.assertEqual(code, lb.EXIT_CONFIG_GAP)


class SubcommandShapeTests(unittest.TestCase):
    """Each subcommand builds the right shape of request and prints the
    contract's JSON. Verified against the stub's echoed responses."""

    def test_issue_falls_back_to_team_number_filter_on_not_found(self):
        counter = script_responses([
            {"stdout": {"errors": [{"message": "Entity not found: Issue"}]}, "returncode": 0},
            {"stdout": {"data": {"issues": {"nodes": [{"id": "uuid-1", "identifier": "ACR-12", "title": "T",
                                                        "state": {"name": "Todo", "type": "unstarted"},
                                                        "labels": {"nodes": []}, "parent": None,
                                                        "delegate": None, "assignee": None,
                                                        "team": {"key": "ACR"},
                                                        "inverseRelations": {"nodes": []}}]}}}, "returncode": 0},
        ])
        node = lb.resolve_issue_ref(STUB_CMD, "ACR-12")
        self.assertEqual(node["identifier"], "ACR-12")
        self.assertEqual(call_count(counter), 2)

    def test_claim_write_dry_run_never_calls_bridge(self):
        counter = script_responses([
            {"stdout": {"data": {}}, "returncode": 0},
        ])
        result = lb.claim_write(STUB_CMD, "uuid-1", "state-ip", "delegate-1", dry_run=True)
        self.assertTrue(result["dry_run"])
        self.assertIn("mutation", result["mutation"])
        self.assertEqual(call_count(counter), 0, "dry-run must never invoke the bridge")

    def test_claim_write_detects_lost_race(self):
        script_responses([
            {"stdout": {"data": {"issueUpdate": {"success": True}}}, "returncode": 0},
            {"stdout": {"data": {"issue": {"id": "uuid-1", "delegate": {"id": "someone-else"},
                                            "state": {"id": "state-ip", "name": "In Progress", "type": "started"},
                                            "assignee": None}}}, "returncode": 0},
        ])
        result = lb.claim_write(STUB_CMD, "uuid-1", "state-ip", "delegate-1")
        self.assertTrue(result["race_lost"])
        self.assertFalse(result["verified"])

    def test_claim_write_verifies_clean_win(self):
        script_responses([
            {"stdout": {"data": {"issueUpdate": {"success": True}}}, "returncode": 0},
            {"stdout": {"data": {"issue": {"id": "uuid-1", "delegate": {"id": "delegate-1"},
                                            "state": {"id": "state-ip", "name": "In Progress", "type": "started"},
                                            "assignee": None}}}, "returncode": 0},
        ])
        result = lb.claim_write(STUB_CMD, "uuid-1", "state-ip", "delegate-1")
        self.assertFalse(result["race_lost"])
        self.assertTrue(result["verified"])

    def test_release_delegate_verified_when_cleared(self):
        script_responses([
            {"stdout": {"data": {"issueUpdate": {"success": True}}}, "returncode": 0},
            {"stdout": {"data": {"issue": {"id": "uuid-1", "delegate": None}}}, "returncode": 0},
        ])
        result = lb.release_delegate(STUB_CMD, "uuid-1")
        self.assertTrue(result["verified"])

    def test_release_delegate_not_verified_when_still_set(self):
        script_responses([
            {"stdout": {"data": {"issueUpdate": {"success": True}}}, "returncode": 0},
            {"stdout": {"data": {"issue": {"id": "uuid-1", "delegate": {"id": "still-there"}}}}, "returncode": 0},
        ])
        result = lb.release_delegate(STUB_CMD, "uuid-1")
        self.assertFalse(result["verified"])

    def test_resolve_state_caches_per_process(self):
        lb._STATE_CACHE.clear()
        counter = script_responses([
            {"stdout": {"data": {"workflowStates": {"nodes": [
                {"id": "state-todo", "name": "Todo", "type": "unstarted"},
                {"id": "state-ip", "name": "In Progress", "type": "started"},
            ]}}}, "returncode": 0},
        ])
        first = lb.resolve_state(STUB_CMD, "ACR", "In Progress")
        second = lb.resolve_state(STUB_CMD, "ACR", "Todo")
        self.assertEqual(first["id"], "state-ip")
        self.assertEqual(second["id"], "state-todo")
        self.assertEqual(call_count(counter), 1, "second lookup must hit the cache, not the bridge")

    def test_operator_ambiguous_raises_with_candidates(self):
        script_responses([
            {"stdout": {"data": {"users": {"nodes": [
                {"id": "u1", "name": "A", "email": "a@x", "admin": True, "app": False},
                {"id": "u2", "name": "B", "email": "b@x", "admin": True, "app": False},
            ]}}}, "returncode": 0},
        ])
        with self.assertRaises(lb.AmbiguousOperatorError) as cm:
            lb.resolve_operator(STUB_CMD)
        self.assertEqual(len(cm.exception.candidates), 2)

    def test_operator_single_non_app_admin_resolves(self):
        script_responses([
            {"stdout": {"data": {"users": {"nodes": [
                {"id": "u1", "name": "A", "email": "a@x", "admin": True, "app": False},
                {"id": "bot", "name": "Bot", "email": "bot@x", "admin": True, "app": True},
            ]}}}, "returncode": 0},
        ])
        result = lb.resolve_operator(STUB_CMD)
        self.assertEqual(result["id"], "u1")

    def test_children_pagination_guard_raises_on_malformed_page(self):
        script_responses([
            {"stdout": {"data": {"issues": {"nodes": [{"id": "c1"}]}}}, "returncode": 0},  # no pageInfo
        ])
        with self.assertRaises(RuntimeError):
            lb.fetch_children(STUB_CMD, "map-uuid-1")

    def test_children_pages_through_multiple_pages(self):
        script_responses([
            {"stdout": {"data": {"issues": {"nodes": [{"id": "c1"}],
                                             "pageInfo": {"hasNextPage": True, "endCursor": "cursor-1"}}}}, "returncode": 0},
            {"stdout": {"data": {"issues": {"nodes": [{"id": "c2"}],
                                             "pageInfo": {"hasNextPage": False, "endCursor": None}}}}, "returncode": 0},
        ])
        nodes = lb.fetch_children(STUB_CMD, "map-uuid-1")
        self.assertEqual([n["id"] for n in nodes], ["c1", "c2"])


class ChildrenFullTests(unittest.TestCase):
    """fetch_children_full — map_sweep.py's read source. Same pagination
    discipline as fetch_children (refuse-on-incomplete-page), plus the
    blocked_by_open post-processing map_sweep.py relies on being present
    without reaching into a private helper itself."""

    def _node(self, node_id, blocked=False):
        rels = []
        if blocked:
            rels = [{"type": "blocks", "issue": {"id": "blocker-1", "identifier": "ACR-9",
                                                   "state": {"type": "started"}}}]
        return {
            "id": node_id, "identifier": f"ACR-{node_id}", "title": "T",
            "state": {"name": "Todo", "type": "unstarted"},
            "labels": {"nodes": [{"name": "research"}]},
            "delegate": None, "assignee": None,
            "priority": 2, "createdAt": "2026-01-01T00:00:00Z",
            "completedAt": None, "updatedAt": "2026-01-01T00:00:00Z",
            "inverseRelations": {"nodes": rels},
        }

    def test_children_full_pages_and_attaches_blocked_by_open(self):
        counter = script_responses([
            {"stdout": {"data": {"issues": {"nodes": [self._node("c1", blocked=True)],
                                             "pageInfo": {"hasNextPage": True, "endCursor": "cursor-1"}}}}, "returncode": 0},
            {"stdout": {"data": {"issues": {"nodes": [self._node("c2")],
                                             "pageInfo": {"hasNextPage": False, "endCursor": None}}}}, "returncode": 0},
        ])
        nodes = lb.fetch_children_full(STUB_CMD, "map-uuid-1")
        self.assertEqual([n["id"] for n in nodes], ["c1", "c2"])
        self.assertEqual(len(nodes[0]["blocked_by_open"]), 1)
        self.assertEqual(nodes[0]["blocked_by_open"][0]["identifier"], "ACR-9")
        self.assertEqual(nodes[1]["blocked_by_open"], [])
        self.assertEqual(call_count(counter), 2)

    def test_children_full_pagination_guard_raises_on_malformed_page(self):
        script_responses([
            {"stdout": {"data": {"issues": {"nodes": [{"id": "c1"}]}}}, "returncode": 0},  # no pageInfo
        ])
        with self.assertRaises(RuntimeError):
            lb.fetch_children_full(STUB_CMD, "map-uuid-1")

    def test_children_full_cli_subcommand(self):
        script_responses([
            {"stdout": {"data": {"issue": {"id": "map-uuid-1", "identifier": "ACR-1", "title": "Map",
                                            "state": {"name": "In Progress", "type": "started"},
                                            "labels": {"nodes": [{"name": "map"}]}, "parent": None,
                                            "delegate": None, "assignee": None, "team": {"key": "ACR"},
                                            "inverseRelations": {"nodes": []}}}}, "returncode": 0},
            {"stdout": {"data": {"issues": {"nodes": [self._node("c1")],
                                             "pageInfo": {"hasNextPage": False, "endCursor": None}}}}, "returncode": 0},
        ])
        code = lb.main(["--bridge-cmd", " ".join(STUB_CMD), "children-full", "ACR-1"])
        self.assertEqual(code, lb.EXIT_OK)


if __name__ == "__main__":
    unittest.main()
