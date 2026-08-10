#!/usr/bin/env python3
"""
Unit tests for cone_preflight.py's per-verb check logic.

Every context here is hand-built (see cone_fixtures.py) rather than fetched
through a stubbed bridge: run_checks(verb, ctx, flags) is a pure function
once handed a context, and that's the boundary under test — linear_bridge's
own transport is covered separately in test_linear_bridge.py.

Coverage follows the spec's Testing §1: every Script-homed check id gets at
least one fixture proving it catches its named failure (isolated via a
single-field mutation off a known-good baseline), plus one full ADMIT
fixture and one JUDGMENT_REQUIRED fixture per verb where those verdicts are
reachable at all.

Reachability note (see report DEVIATIONS): under the spec's own Check
Inventory homes, some verdicts are structurally unreachable for some verbs:
- park, block: their one check's PASS branch always requires a judgment call
  once a comment is found (checkability is Home=Judgment, never Script) —
  ADMIT is never reachable; REFUSE and JUDGMENT_REQUIRED are.
- resolve, cancel, close-map: no Script+J (DEFER-capable) check exists in
  their inventory rows — JUDGMENT_REQUIRED is never reachable; ADMIT and
  REFUSE are.
These are consequences of the frozen inventory semantics, not a choice made
here — the tests below assert the full set of what IS reachable per verb.
"""
import os
import sys
import unittest

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
import cone_preflight as cp  # noqa: E402
import linear_bridge as lb  # noqa: E402
import tests.cone_fixtures as fx  # noqa: E402
import tests.test_linear_bridge as tlb  # noqa: E402 — reuses the stub-bridge harness


def find_check(report, check_id):
    for c in report["checks"]:
        if c["id"] == check_id:
            return c
    raise AssertionError(f"check {check_id!r} not present in report: {[c['id'] for c in report['checks']]}")


def find_judgment_item(report, item_id):
    for j in report["judgment_items"]:
        if j["id"] == item_id:
            return j
    raise AssertionError(f"judgment item {item_id!r} not present: {[j['id'] for j in report['judgment_items']]}")


# ======================================================================
# gather_context() live wiring (regression: C5 blocked-by-open dead code)
# ======================================================================

class GatherContextLiveWiringTests(unittest.TestCase):
    """Exercises gather_context() itself through the stub bridge — the real
    code path cone_preflight.py's CLI runs — rather than a hand-built
    context dict. This is the regression test for the bug where
    resolve_issue_ref() never populated blocked_by_open on its own (that
    field was only ever set in linear_bridge.py's CLI `issue` handler), so
    gather_context()'s output silently carried an empty blocked_by_open
    regardless of what the live fetch actually returned — C5 could never
    see an open blocker through the real path, only through a test that
    injected the field by hand."""

    def setUp(self):
        lb._STATE_CACHE.clear()

    def test_claim_context_carries_open_blocker_through_to_c5_refusal(self):
        issue_node = {
            "id": "uuid-live-1", "identifier": "ACR-99", "title": "Live-wired ticket",
            "description": "## Objective\nShip it.\n\n## Done When\n- Tests pass\n\n## Constraints and Context\nNone.",
            "state": {"name": "Todo", "type": "unstarted"},
            "labels": {"nodes": [{"name": "task"}]},
            "parent": None, "delegate": None, "assignee": None,
            "team": {"key": "ACR"},
            "inverseRelations": {"nodes": [
                {"type": "blocks", "issue": {"id": "blocker-uuid", "identifier": "ACR-1", "state": {"type": "started"}}},
            ]},
            "comments": {"nodes": []},
            "history": {"nodes": []},
        }
        responses = [
            {"stdout": {"data": {"issue": issue_node}}, "returncode": 0},  # resolve_issue_ref
            {"stdout": {"data": {"viewer": {"id": "viewer-1"}}}, "returncode": 0},  # resolve_viewer
            {"stdout": {"data": {"users": {"nodes": [
                {"id": "op-1", "name": "Op", "email": "op@x", "admin": True, "app": False},
            ]}}}, "returncode": 0},  # resolve_operator
            {"stdout": {"data": {"workflowStates": {"nodes": [
                {"id": "state-ip", "name": "In Progress", "type": "started"},
                {"id": "state-ni", "name": "Needs Input", "type": "triage"},
            ]}}}, "returncode": 0},  # resolve_state — one call resolves both names (cached per team)
        ]
        tlb.script_responses(responses)

        ctx = cp.gather_context(tlb.STUB_CMD, "claim", "ACR-99", fx.claim_flags())

        self.assertEqual(
            ctx["issue"]["blocked_by_open"],
            [{"id": "blocker-uuid", "identifier": "ACR-1", "state": {"type": "started"}}],
            "gather_context() must populate blocked_by_open from the live fetch itself",
        )
        self.assertEqual(
            ctx["state_ids"], {"in_progress": "state-ip", "needs_input": "state-ni"},
            "Needs Input must resolve alongside In Progress through the real path",
        )

        report = cp.run_checks("claim", ctx, fx.claim_flags())
        c5 = find_check(report, "C5")
        self.assertEqual(c5["result"], "FAIL", c5)
        self.assertIn("ACR-1", c5["detail"])
        self.assertEqual(report["verdict"], "REFUSE")

    def test_claim_context_with_no_blocker_admits_through_real_path(self):
        """Companion case: the real path must also correctly report a clean
        blocked_by_open when there's genuinely nothing open, not just when
        there's something to catch."""
        issue_node = {
            "id": "uuid-live-2", "identifier": "ACR-98", "title": "Live-wired, unblocked",
            "description": "## Objective\nShip it.\n\n## Done When\n- Tests pass\n\n## Constraints and Context\nNone.",
            "state": {"name": "Todo", "type": "unstarted"},
            "labels": {"nodes": [{"name": "task"}]},
            "parent": None, "delegate": None, "assignee": None,
            "team": {"key": "ACR"},
            "inverseRelations": {"nodes": []},
            "comments": {"nodes": []},
            "history": {"nodes": []},
        }
        responses = [
            {"stdout": {"data": {"issue": issue_node}}, "returncode": 0},
            {"stdout": {"data": {"viewer": {"id": "viewer-1"}}}, "returncode": 0},
            {"stdout": {"data": {"users": {"nodes": [
                {"id": "op-1", "name": "Op", "email": "op@x", "admin": True, "app": False},
            ]}}}, "returncode": 0},
            {"stdout": {"data": {"workflowStates": {"nodes": [
                {"id": "state-ip", "name": "In Progress", "type": "started"},
                {"id": "state-ni", "name": "Needs Input", "type": "triage"},
            ]}}}, "returncode": 0},
        ]
        tlb.script_responses(responses)

        ctx = cp.gather_context(tlb.STUB_CMD, "claim", "ACR-98", fx.claim_flags())
        self.assertEqual(ctx["issue"]["blocked_by_open"], [])
        self.assertEqual(ctx["state_ids"], {"in_progress": "state-ip", "needs_input": "state-ni"})

        report = cp.run_checks("claim", ctx, fx.claim_flags())
        self.assertEqual(find_check(report, "C5")["result"], "PASS")
        self.assertEqual(report["verdict"], "ADMIT")


# ======================================================================
# claim
# ======================================================================

class ClaimMapChildShapeScopingTests(unittest.TestCase):
    def test_map_child_question_body_skips_c1_c2_and_admits(self):
        # A grilling child whose body is only ## Question — the map-child
        # brief shape. C1/C2 must SKIP, never FAIL: the first live run
        # refused a well-formed grilling child on these checks.
        ctx = fx.claim_map_child_ctx()
        ctx["issue"]["labels"] = {"nodes": [{"name": "grilling"}]}
        ctx["issue"]["description"] = "## Question\n\nWhat shape should the thing take?\n"
        report = cp.run_checks("claim", ctx, fx.claim_flags())
        by_id = {c["id"]: c for c in report["checks"]}
        self.assertEqual(by_id["C1"]["result"], "SKIP")
        self.assertEqual(by_id["C2"]["result"], "SKIP")
        self.assertEqual(report["verdict"], "ADMIT", report)

    def test_full_variant_still_fails_c1_without_objective(self):
        ctx = fx.claim_full_ctx()
        ctx["issue"]["description"] = "## Question\n\nNot a map child, no Objective.\n"
        report = cp.run_checks("claim", ctx, fx.claim_flags())
        by_id = {c["id"]: c for c in report["checks"]}
        self.assertEqual(by_id["C1"]["result"], "FAIL")
        self.assertEqual(report["verdict"], "REFUSE")


class ConductorPreflightTests(unittest.TestCase):
    def test_conductor_preflight_runs_build_checks_without_delegated_flag(self):
        # /implement's own pre-flight: build child, delegated flag false —
        # C7 must admit the build variant and C4a/b/c must EVALUATE, not
        # SKIP (the reviewer's blocking finding: without this path the
        # conductor's "Verified" branch was unreachable).
        ctx = fx.claim_build_ctx()
        report = cp.run_checks(
            "claim", ctx, fx.claim_flags(conductor_preflight=True))
        by_id = {c["id"]: c for c in report["checks"]}
        self.assertEqual(report["facts"]["variant"], "build")
        for cid in ("C4a", "C4b", "C4c"):
            self.assertIn(by_id[cid]["result"], ("PASS", "FAIL"),
                          f"{cid} must evaluate, not SKIP: {by_id[cid]}")
        self.assertEqual(report["verdict"], "ADMIT", report)

    def test_build_child_without_either_flag_still_refuses_with_routing(self):
        ctx = fx.claim_build_ctx()
        report = cp.run_checks("claim", ctx, fx.claim_flags())
        by_id = {c["id"]: c for c in report["checks"]}
        self.assertEqual(by_id["C7"]["result"], "FAIL")
        self.assertEqual(report["verdict"], "REFUSE")


class ClaimAdmitTests(unittest.TestCase):
    def test_full_variant_admits_with_facts_asserted_field_by_field(self):
        ctx = fx.claim_full_ctx()
        report = cp.run_checks("claim", ctx, fx.claim_flags())
        self.assertEqual(report["verdict"], "ADMIT")
        self.assertTrue(all(c["result"] in ("PASS", "SKIP") for c in report["checks"]), report["checks"])
        facts = report["facts"]
        self.assertEqual(facts["variant"], "full")
        self.assertEqual(facts["team_key"], "ACR")
        self.assertEqual(facts["viewer_id"], "viewer-1")
        self.assertEqual(facts["operator_id"], "operator-1")
        self.assertEqual(facts["assignee_gate"], "set")
        self.assertIsNone(facts["model_label"])
        self.assertEqual(facts["refusal_reasons"], [])
        # Needs Input is resolved alongside In Progress — it funds the card's
        # C2/C3 NEEDS_INPUT execution path (set-state to Needs Input).
        self.assertEqual(facts["state_ids"], {"in_progress": "state-ip", "needs_input": "state-ni"})

    def test_build_variant_admits(self):
        ctx = fx.claim_build_ctx()
        report = cp.run_checks("claim", ctx, fx.claim_flags(delegated_preflight_passed=True))
        self.assertEqual(report["verdict"], "ADMIT")
        self.assertEqual(report["facts"]["variant"], "build")
        self.assertEqual(report["facts"]["assignee_gate"], "skip")
        for cid in ("C4a", "C4b", "C4c"):
            self.assertEqual(find_check(report, cid)["result"], "PASS")

    def test_map_child_hitl_sets_assignee_gate(self):
        ctx = fx.claim_map_child_ctx(issue=dict(fx.claim_map_child_ctx()["issue"], **{"labels": {"nodes": [{"name": "research"}, {"name": "hitl"}]}}))
        report = cp.run_checks("claim", ctx, fx.claim_flags())
        self.assertEqual(report["verdict"], "ADMIT")
        self.assertEqual(report["facts"]["variant"], "map-child")
        self.assertEqual(report["facts"]["assignee_gate"], "set")

    def test_map_child_afk_skips_assignee_gate(self):
        ctx = fx.claim_map_child_ctx(issue=dict(fx.claim_map_child_ctx()["issue"], **{"labels": {"nodes": [{"name": "research"}, {"name": "afk"}]}}))
        report = cp.run_checks("claim", ctx, fx.claim_flags())
        self.assertEqual(report["facts"]["assignee_gate"], "skip")

    def test_full_variant_autonomous_skips_assignee_gate(self):
        ctx = fx.claim_full_ctx()
        report = cp.run_checks("claim", ctx, fx.claim_flags(autonomous=True))
        self.assertEqual(report["verdict"], "ADMIT")
        self.assertEqual(report["facts"]["assignee_gate"], "skip")


class ClaimJudgmentRequiredTests(unittest.TestCase):
    def test_model_label_defers_with_evidence(self):
        ctx = fx.claim_full_ctx()
        ctx["issue"]["labels"] = {"nodes": [{"name": "task"}, {"name": "model:opus"}]}
        report = cp.run_checks("claim", ctx, fx.claim_flags())
        self.assertEqual(report["verdict"], "JUDGMENT_REQUIRED")
        self.assertEqual(find_check(report, "C8")["result"], "DEFER")
        item = find_judgment_item(report, "J-C8")
        self.assertEqual(item["evidence"], "model:opus")
        self.assertEqual(report["facts"]["model_label"], "model:opus")
        # no hard failures alongside the defer
        self.assertEqual(report["facts"]["refusal_reasons"], [])


class ClaimRefuseAndNeedsInputTests(unittest.TestCase):
    def test_c1_missing_objective_refuses(self):
        ctx = fx.claim_full_ctx()
        ctx["issue"]["description"] = "## Done When\n- Tests pass\n"
        report = cp.run_checks("claim", ctx, fx.claim_flags())
        self.assertEqual(report["verdict"], "REFUSE")
        self.assertEqual(find_check(report, "C1")["result"], "FAIL")

    def test_c2_deferred_done_when_routes_needs_input(self):
        ctx = fx.claim_full_ctx()
        ctx["issue"]["description"] = fx.BASE_OBJECTIVE + "## Done When\n_to be set at claim_\n"
        report = cp.run_checks("claim", ctx, fx.claim_flags())
        self.assertEqual(report["verdict"], "NEEDS_INPUT")
        self.assertEqual(find_check(report, "C2")["result"], "FAIL")

    def test_c2_missing_done_when_routes_needs_input(self):
        ctx = fx.claim_full_ctx()
        ctx["issue"]["description"] = fx.BASE_OBJECTIVE
        report = cp.run_checks("claim", ctx, fx.claim_flags())
        self.assertEqual(report["verdict"], "NEEDS_INPUT")
        self.assertEqual(find_check(report, "C2")["result"], "FAIL")

    def test_c3_build_with_question_body_is_conflict_cell(self):
        ctx = fx.claim_full_ctx()
        ctx["issue"]["labels"] = {"nodes": [{"name": "build"}]}
        ctx["issue"]["description"] = fx.BASE_OBJECTIVE + "## Question\nWhich approach?\n"
        report = cp.run_checks("claim", ctx, fx.claim_flags())
        self.assertEqual(find_check(report, "C3")["result"], "FAIL")
        self.assertEqual(report["verdict"], "NEEDS_INPUT")

    def test_c3_build_no_map_parent_is_conflict_cell(self):
        ctx = fx.claim_full_ctx()
        ctx["issue"]["labels"] = {"nodes": [{"name": "build"}]}
        report = cp.run_checks("claim", ctx, fx.claim_flags())
        self.assertEqual(find_check(report, "C3")["result"], "FAIL")
        self.assertEqual(report["verdict"], "NEEDS_INPUT")

    def test_c3_map_child_no_type_label_is_conflict_cell(self):
        ctx = fx.claim_map_child_ctx()
        ctx["issue"]["labels"] = {"nodes": []}
        report = cp.run_checks("claim", ctx, fx.claim_flags())
        self.assertEqual(find_check(report, "C3")["result"], "FAIL")
        self.assertEqual(find_check(report, "C7")["result"], "FAIL")
        self.assertEqual(report["verdict"], "NEEDS_INPUT")

    def test_c4a_missing_ready_for_agent_refuses(self):
        ctx = fx.claim_build_ctx()
        ctx["issue"]["labels"] = {"nodes": [{"name": "build"}]}
        report = cp.run_checks("claim", ctx, fx.claim_flags(delegated_preflight_passed=True))
        self.assertEqual(find_check(report, "C4a")["result"], "FAIL")
        self.assertEqual(report["verdict"], "REFUSE")

    def test_c4b_charter_not_finalized_refuses(self):
        ctx = fx.claim_build_ctx()
        ctx["parent_documents"] = [{"id": "doc-1", "title": "Draft", "archivedAt": None, "content": "no marker here"}]
        report = cp.run_checks("claim", ctx, fx.claim_flags(delegated_preflight_passed=True))
        self.assertEqual(find_check(report, "C4b")["result"], "FAIL")
        self.assertEqual(report["verdict"], "REFUSE")

    def test_c4c_open_challenge_refuses(self):
        ctx = fx.claim_build_ctx()
        ctx["parent_comments"] = [
            {"id": "ch1", "body": "[CHALLENGE] the approach is wrong", "createdAt": "2026-01-20T00:00:00Z", "user": {"id": "x"}},
        ]
        report = cp.run_checks("claim", ctx, fx.claim_flags(delegated_preflight_passed=True))
        self.assertEqual(find_check(report, "C4c")["result"], "FAIL")
        self.assertEqual(report["verdict"], "REFUSE")

    def test_c4c_resolved_challenge_passes(self):
        ctx = fx.claim_build_ctx()
        ctx["parent_comments"] = [
            {"id": "ch1", "body": "[CHALLENGE] the approach is wrong", "createdAt": "2026-01-20T00:00:00Z", "user": {"id": "x"}},
            {"id": "ch2", "body": "[CHALLENGE-RESOLVED] addressed", "createdAt": "2026-01-21T00:00:00Z", "user": {"id": "x"}},
        ]
        report = cp.run_checks("claim", ctx, fx.claim_flags(delegated_preflight_passed=True))
        self.assertEqual(find_check(report, "C4c")["result"], "PASS")
        self.assertEqual(report["verdict"], "ADMIT")

    def test_c5_not_todo_refuses_without_operator_directed(self):
        ctx = fx.claim_full_ctx()
        ctx["issue"]["state"] = {"name": "In Progress", "type": "started"}
        report = cp.run_checks("claim", ctx, fx.claim_flags())
        self.assertEqual(find_check(report, "C5")["result"], "FAIL")
        self.assertEqual(report["verdict"], "REFUSE")

    def test_c5_not_todo_passes_with_operator_directed(self):
        ctx = fx.claim_full_ctx()
        ctx["issue"]["state"] = {"name": "In Progress", "type": "started"}
        report = cp.run_checks("claim", ctx, fx.claim_flags(operator_directed=True))
        self.assertEqual(find_check(report, "C5")["result"], "PASS")

    def test_c5_open_blocker_refuses(self):
        ctx = fx.claim_full_ctx()
        ctx["issue"]["blocked_by_open"] = [{"identifier": "ACR-99", "id": "blocker-1"}]
        report = cp.run_checks("claim", ctx, fx.claim_flags())
        self.assertEqual(find_check(report, "C5")["result"], "FAIL")
        self.assertEqual(report["verdict"], "REFUSE")

    def test_c5_already_delegated_refuses(self):
        ctx = fx.claim_full_ctx()
        ctx["issue"]["delegate"] = {"id": "someone-1"}
        report = cp.run_checks("claim", ctx, fx.claim_flags())
        self.assertEqual(find_check(report, "C5")["result"], "FAIL")
        self.assertEqual(report["verdict"], "REFUSE")

    def test_c5b_closed_parent_map_refuses_distinctly(self):
        ctx = fx.claim_map_child_ctx()
        ctx["issue"]["parent"] = fx.map_parent(state={"name": "Done", "type": "completed"})
        report = cp.run_checks("claim", ctx, fx.claim_flags())
        c5b = find_check(report, "C5b")
        self.assertEqual(c5b["result"], "FAIL")
        self.assertIn("closed map", c5b["detail"])
        self.assertEqual(report["verdict"], "REFUSE")

    def test_c6_wip_conflict_refuses_without_ack(self):
        ctx = fx.claim_full_ctx()
        ctx["wip_conflict"] = {"identifier": "ACR-77", "id": "other-uuid"}
        report = cp.run_checks("claim", ctx, fx.claim_flags())
        self.assertEqual(find_check(report, "C6")["result"], "FAIL")
        self.assertEqual(report["verdict"], "REFUSE")

    def test_c6_wip_conflict_passes_with_ack(self):
        ctx = fx.claim_full_ctx()
        ctx["wip_conflict"] = {"identifier": "ACR-77", "id": "other-uuid"}
        report = cp.run_checks("claim", ctx, fx.claim_flags(caller_ack_wip=True))
        self.assertEqual(find_check(report, "C6")["result"], "PASS")
        self.assertEqual(report["verdict"], "ADMIT")

    def test_c7_map_labeled_issue_refuses(self):
        ctx = fx.claim_full_ctx()
        ctx["issue"]["labels"] = {"nodes": [{"name": "map"}]}
        report = cp.run_checks("claim", ctx, fx.claim_flags())
        self.assertEqual(find_check(report, "C7")["result"], "FAIL")
        self.assertEqual(report["verdict"], "REFUSE")

    def test_c7_build_child_without_delegated_preflight_refuses(self):
        ctx = fx.claim_build_ctx()
        report = cp.run_checks("claim", ctx, fx.claim_flags(delegated_preflight_passed=False))
        self.assertEqual(find_check(report, "C7")["result"], "FAIL")
        self.assertIn("/implement", find_check(report, "C7")["detail"])
        self.assertEqual(report["verdict"], "REFUSE")


# ======================================================================
# mark_done
# ======================================================================

class MarkDoneAdmitTests(unittest.TestCase):
    def test_full_variant_admits_with_facts(self):
        ctx = fx.mark_done_full_ctx()
        report = cp.run_checks("mark_done", ctx, fx.mark_done_flags())
        self.assertEqual(report["verdict"], "ADMIT", report)
        for cid in ("M2", "M3a", "M3b", "M3c", "M3d", "M3e", "M3f"):
            self.assertEqual(find_check(report, cid)["result"], "PASS", cid)
        self.assertEqual(report["facts"]["viewer_id"], "viewer-1")
        self.assertEqual(report["facts"]["team_key"], "ACR")
        self.assertFalse(report["facts"]["idempotent"])
        self.assertEqual(report["facts"]["refusal_reasons"], [])
        # Needs Input is resolved alongside Done — it funds the card's M2.5
        # NEEDS_INPUT execution path (set-state to Needs Input).
        self.assertEqual(report["facts"]["state_ids"], {"done": "state-done", "needs_input": "state-ni"})

    def test_build_variant_admits(self):
        ctx = fx.mark_done_build_ctx()
        report = cp.run_checks("mark_done", ctx, fx.mark_done_flags())
        self.assertEqual(report["verdict"], "ADMIT", report)
        self.assertEqual(find_check(report, "M2.5")["result"], "PASS")
        self.assertEqual(report["facts"]["charter_document_id"], "charter-doc-1")

    def test_idempotent_already_done_admits(self):
        ctx = fx.mark_done_full_ctx()
        ctx["issue"]["state"] = {"name": "Done", "type": "completed"}
        report = cp.run_checks("mark_done", ctx, fx.mark_done_flags())
        self.assertEqual(report["verdict"], "ADMIT")
        self.assertTrue(report["facts"]["idempotent"])
        self.assertEqual(find_check(report, "M2")["result"], "SKIP")
        self.assertEqual(find_check(report, "M-i")["result"], "PASS")

    def test_deterministic_exempt_non_build_defers(self):
        ctx = fx.mark_done_full_ctx()
        report = cp.run_checks("mark_done", ctx, fx.mark_done_flags(deterministic_exempt=True, deterministic_exempt_context="fixture suite green, 40/40"))
        self.assertEqual(find_check(report, "M-d")["result"], "DEFER")
        item = find_judgment_item(report, "J-M-d")
        self.assertEqual(item["evidence"], "fixture suite green, 40/40")
        self.assertEqual(report["verdict"], "JUDGMENT_REQUIRED")


class MarkDoneJudgmentRequiredTests(unittest.TestCase):
    def test_m3c_regex_miss_defers_with_full_done_when_text(self):
        ctx = fx.mark_done_full_ctx()
        ctx["issue"]["description"] = fx.BASE_OBJECTIVE + "## Done When\nThe suite must be green and reviewed.\n\n" + fx.BASE_CTX
        report = cp.run_checks("mark_done", ctx, fx.mark_done_flags())
        self.assertEqual(find_check(report, "M3c")["result"], "DEFER")
        item = find_judgment_item(report, "J-M3c")
        self.assertIn("suite must be green", item["evidence"])
        self.assertEqual(report["verdict"], "JUDGMENT_REQUIRED")


class MarkDoneRefuseAndNeedsInputTests(unittest.TestCase):
    def test_m2_missing_objective_refuses(self):
        ctx = fx.mark_done_full_ctx()
        ctx["issue"]["description"] = "## Done When\nValidation mandate: conformance\n"
        report = cp.run_checks("mark_done", ctx, fx.mark_done_flags())
        self.assertEqual(find_check(report, "M2")["result"], "FAIL")
        self.assertEqual(report["verdict"], "REFUSE")

    def test_m2_deferred_done_when_refuses(self):
        ctx = fx.mark_done_full_ctx()
        ctx["issue"]["description"] = fx.BASE_OBJECTIVE + "## Done When\n_to be set at claim_\n"
        report = cp.run_checks("mark_done", ctx, fx.mark_done_flags())
        self.assertEqual(find_check(report, "M2")["result"], "FAIL")
        self.assertEqual(report["verdict"], "REFUSE")

    def test_m2_not_in_progress_refuses(self):
        ctx = fx.mark_done_full_ctx()
        ctx["issue"]["state"] = {"name": "Todo", "type": "unstarted"}
        report = cp.run_checks("mark_done", ctx, fx.mark_done_flags())
        self.assertEqual(find_check(report, "M2")["result"], "FAIL")
        self.assertEqual(report["verdict"], "REFUSE")

    def test_m2_decision_type_label_refuses(self):
        ctx = fx.mark_done_full_ctx()
        ctx["issue"]["labels"] = {"nodes": [{"name": "research"}]}
        report = cp.run_checks("mark_done", ctx, fx.mark_done_flags())
        self.assertEqual(find_check(report, "M2")["result"], "FAIL")
        self.assertIn("resolve", find_check(report, "M2")["detail"])
        self.assertEqual(report["verdict"], "REFUSE")

    def test_m2_5_open_challenge_needs_input_and_short_circuits(self):
        ctx = fx.mark_done_build_ctx()
        ctx["parent_comments"] = [
            {"id": "ch1", "body": "[CHALLENGE] scope drifted", "createdAt": "2026-01-25T00:00:00Z", "user": {"id": "x"}},
        ]
        report = cp.run_checks("mark_done", ctx, fx.mark_done_flags())
        self.assertEqual(find_check(report, "M2.5")["result"], "FAIL")
        self.assertEqual(report["verdict"], "NEEDS_INPUT")
        for cid in ("M3a", "M3b", "M3c", "M3d", "M3e", "M3f", "M-i", "M-d"):
            self.assertEqual(find_check(report, cid)["result"], "SKIP", cid)

    def test_m2_5_charter_not_finalized_refuses(self):
        ctx = fx.mark_done_build_ctx()
        ctx["parent_documents"] = [{"id": "doc-1", "title": "Draft", "archivedAt": None, "content": "no marker"}]
        report = cp.run_checks("mark_done", ctx, fx.mark_done_flags())
        self.assertEqual(find_check(report, "M2.5")["result"], "FAIL")
        self.assertEqual(report["verdict"], "REFUSE")

    def test_m2_5_charter_finalized_after_receipt_refuses(self):
        ctx = fx.mark_done_build_ctx()
        ctx["parent_documents"] = [fx.finalized_charter(finalized_date="2026-02-05")]  # after the 2026-02-01 receipt
        report = cp.run_checks("mark_done", ctx, fx.mark_done_flags())
        self.assertEqual(find_check(report, "M2.5")["result"], "FAIL")
        self.assertEqual(report["verdict"], "REFUSE")

    def test_m3a_no_receipt_refuses(self):
        ctx = fx.mark_done_full_ctx()
        ctx["issue"]["comments"] = {"nodes": []}
        report = cp.run_checks("mark_done", ctx, fx.mark_done_flags())
        self.assertEqual(find_check(report, "M3a")["result"], "FAIL")
        self.assertEqual(report["verdict"], "REFUSE")

    def test_m3b_stale_receipt_refuses(self):
        ctx = fx.mark_done_full_ctx()
        ctx["issue"]["comments"]["nodes"][0]["createdAt"] = "2026-01-29T00:00:00Z"  # before the claim ts
        report = cp.run_checks("mark_done", ctx, fx.mark_done_flags())
        self.assertEqual(find_check(report, "M3b")["result"], "FAIL")
        self.assertEqual(report["verdict"], "REFUSE")

    def test_m3c_mismatched_type_refuses(self):
        ctx = fx.mark_done_full_ctx()
        ctx["issue"]["comments"]["nodes"][0]["body"] = "[VALIDATION] — pedagogical-fit\nVerdict: CONFIRMED\nIntent: x\nSpecifics: y"
        report = cp.run_checks("mark_done", ctx, fx.mark_done_flags())
        self.assertEqual(find_check(report, "M3c")["result"], "FAIL")
        self.assertEqual(report["verdict"], "REFUSE")

    def test_m3d_wrong_verdict_refuses(self):
        ctx = fx.mark_done_full_ctx()
        ctx["issue"]["comments"]["nodes"][0]["body"] = "[VALIDATION] — conformance\nVerdict: REFUTED\nIntent: x\nSpecifics: y"
        report = cp.run_checks("mark_done", ctx, fx.mark_done_flags())
        self.assertEqual(find_check(report, "M3d")["result"], "FAIL")
        self.assertEqual(report["verdict"], "REFUSE")

    def test_m3e_malformed_schema_refuses(self):
        ctx = fx.mark_done_full_ctx()
        ctx["issue"]["comments"]["nodes"][0]["body"] = "[VALIDATION] — conformance\nVerdict: CONFIRMED\nIntent: x"
        report = cp.run_checks("mark_done", ctx, fx.mark_done_flags())
        self.assertEqual(find_check(report, "M3e")["result"], "FAIL")
        self.assertEqual(report["verdict"], "REFUSE")

    def test_m3f_wrong_author_refuses(self):
        ctx = fx.mark_done_full_ctx()
        ctx["issue"]["comments"]["nodes"][0]["user"] = {"id": "a-human-not-the-app-actor"}
        report = cp.run_checks("mark_done", ctx, fx.mark_done_flags())
        self.assertEqual(find_check(report, "M3f")["result"], "FAIL")
        self.assertEqual(report["verdict"], "REFUSE")

    def test_m_d_exempt_on_build_is_hard_refusal_no_defer(self):
        ctx = fx.mark_done_build_ctx()
        report = cp.run_checks("mark_done", ctx, fx.mark_done_flags(deterministic_exempt=True))
        self.assertEqual(find_check(report, "M-d")["result"], "FAIL")
        self.assertEqual(report["verdict"], "REFUSE")
        self.assertEqual(report["judgment_items"], [], "never on build — hard refusal, no deferral")


# ======================================================================
# resolve
# ======================================================================

class ResolveTests(unittest.TestCase):
    def test_research_afk_admits(self):
        ctx = fx.resolve_research_afk_ctx()
        report = cp.run_checks("resolve", ctx, {})
        self.assertEqual(report["verdict"], "ADMIT")
        self.assertEqual(find_check(report, "R1")["result"], "PASS")
        self.assertEqual(find_check(report, "R2")["result"], "PASS")

    def test_grilling_hitl_admits_via_r3(self):
        ctx = fx.resolve_grilling_hitl_ctx()
        report = cp.run_checks("resolve", ctx, {})
        self.assertEqual(report["verdict"], "ADMIT")
        self.assertEqual(find_check(report, "R3")["result"], "PASS")

    def test_r1_guard_refuses_non_map_child(self):
        ctx = fx.resolve_research_afk_ctx()
        ctx["issue"]["parent"] = None
        report = cp.run_checks("resolve", ctx, {})
        self.assertEqual(find_check(report, "R1")["result"], "FAIL")
        self.assertEqual(report["verdict"], "REFUSE")

    def test_r1_guard_refuses_non_decision_label(self):
        ctx = fx.resolve_research_afk_ctx()
        ctx["issue"]["labels"] = {"nodes": [{"name": "build"}]}
        report = cp.run_checks("resolve", ctx, {})
        self.assertEqual(find_check(report, "R1")["result"], "FAIL")
        self.assertEqual(report["verdict"], "REFUSE")

    def test_r2_missing_findings_doc_refuses(self):
        ctx = fx.resolve_research_afk_ctx()
        ctx["documents"] = []
        report = cp.run_checks("resolve", ctx, {})
        self.assertEqual(find_check(report, "R2")["result"], "FAIL")
        self.assertEqual(report["verdict"], "REFUSE")

    def test_r2_missing_resolution_comment_refuses(self):
        ctx = fx.resolve_research_afk_ctx()
        ctx["issue"]["comments"] = {"nodes": []}
        report = cp.run_checks("resolve", ctx, {})
        self.assertEqual(find_check(report, "R2")["result"], "FAIL")
        self.assertEqual(report["verdict"], "REFUSE")

    def test_r3_missing_resolution_comment_refuses(self):
        ctx = fx.resolve_grilling_hitl_ctx()
        ctx["issue"]["comments"] = {"nodes": []}
        report = cp.run_checks("resolve", ctx, {})
        self.assertEqual(find_check(report, "R3")["result"], "FAIL")
        self.assertEqual(report["verdict"], "REFUSE")


# ======================================================================
# park
# ======================================================================

class ParkTests(unittest.TestCase):
    def test_p1_comment_present_defers_with_evidence(self):
        ctx = fx.park_ctx()
        report = cp.run_checks("park", ctx, {})
        self.assertEqual(report["verdict"], "JUDGMENT_REQUIRED")
        self.assertEqual(find_check(report, "P1")["result"], "DEFER")
        item = find_judgment_item(report, "J-P1")
        self.assertIn("decision on the routing", item["evidence"])

    def test_p1_not_yet_posted_still_defers(self):
        ctx = fx.park_ctx()
        ctx["issue"]["comments"] = {"nodes": []}
        report = cp.run_checks("park", ctx, {})
        self.assertEqual(report["verdict"], "JUDGMENT_REQUIRED")
        item = find_judgment_item(report, "J-P1")
        self.assertIsNone(item["evidence"])

    def test_p1_map_labeled_refuses(self):
        ctx = fx.park_ctx()
        ctx["issue"]["labels"] = {"nodes": [{"name": "map"}]}
        report = cp.run_checks("park", ctx, {})
        self.assertEqual(find_check(report, "P1")["result"], "FAIL")
        self.assertEqual(report["verdict"], "REFUSE")


# ======================================================================
# block
# ======================================================================

class BlockTests(unittest.TestCase):
    def test_b1_condition_present_defers_with_evidence(self):
        ctx = fx.block_ctx()
        report = cp.run_checks("block", ctx, {})
        self.assertEqual(report["verdict"], "JUDGMENT_REQUIRED")
        self.assertEqual(find_check(report, "B1")["result"], "DEFER")
        item = find_judgment_item(report, "J-B1")
        self.assertIn("PR #482", item["evidence"])

    def test_b1_missing_condition_refuses(self):
        ctx = fx.block_ctx()
        ctx["issue"]["comments"] = {"nodes": []}
        report = cp.run_checks("block", ctx, {})
        self.assertEqual(find_check(report, "B1")["result"], "FAIL")
        self.assertEqual(report["verdict"], "REFUSE")

    def test_b1_map_labeled_refuses(self):
        ctx = fx.block_ctx()
        ctx["issue"]["labels"] = {"nodes": [{"name": "map"}]}
        report = cp.run_checks("block", ctx, {})
        self.assertEqual(find_check(report, "B1")["result"], "FAIL")
        self.assertEqual(report["verdict"], "REFUSE")


# ======================================================================
# un-park
# ======================================================================

class UnparkTests(unittest.TestCase):
    def test_operator_directed_admits(self):
        ctx = fx.unpark_ctx()
        report = cp.run_checks("un-park", ctx, fx.unpark_flags(operator_directed=True))
        self.assertEqual(report["verdict"], "ADMIT")
        self.assertEqual(find_check(report, "U1")["result"], "PASS")
        self.assertEqual(find_check(report, "U2")["result"], "PASS")

    def test_condition_present_defers_without_operator_directed(self):
        ctx = fx.unpark_ctx()
        report = cp.run_checks("un-park", ctx, fx.unpark_flags())
        self.assertEqual(report["verdict"], "JUDGMENT_REQUIRED")
        self.assertEqual(find_check(report, "U1")["result"], "DEFER")
        item = find_judgment_item(report, "J-U1")
        self.assertIn("PR #482", item["evidence"])

    def test_u1_nothing_on_record_refuses(self):
        ctx = fx.unpark_ctx()
        ctx["issue"]["comments"] = {"nodes": []}
        report = cp.run_checks("un-park", ctx, fx.unpark_flags())
        self.assertEqual(find_check(report, "U1")["result"], "FAIL")
        self.assertEqual(report["verdict"], "REFUSE")

    def test_u2_in_progress_routes_to_claim_not_unpark(self):
        ctx = fx.unpark_ctx()
        ctx["issue"]["state"] = {"name": "In Progress", "type": "started"}
        report = cp.run_checks("un-park", ctx, fx.unpark_flags(operator_directed=True))
        self.assertEqual(find_check(report, "U2")["result"], "FAIL")
        self.assertIn("claim", find_check(report, "U2")["detail"])
        self.assertEqual(report["verdict"], "REFUSE")

    def test_u2_surfaces_uncleared_delegate_without_blocking(self):
        ctx = fx.unpark_ctx()
        ctx["issue"]["delegate"] = {"id": "leftover-delegate"}
        report = cp.run_checks("un-park", ctx, fx.unpark_flags(operator_directed=True))
        u2 = find_check(report, "U2")
        self.assertEqual(u2["result"], "PASS", "never silently clear, but never block on it either")
        self.assertIn("NOT cleared", u2["detail"])
        self.assertEqual(report["verdict"], "ADMIT")


# ======================================================================
# cancel
# ======================================================================

class CancelTests(unittest.TestCase):
    def test_reason_present_admits(self):
        ctx = fx.cancel_ctx()
        report = cp.run_checks("cancel", ctx, {})
        self.assertEqual(report["verdict"], "ADMIT")
        self.assertEqual(find_check(report, "X1")["result"], "PASS")

    def test_no_reason_refuses(self):
        ctx = fx.cancel_ctx()
        ctx["issue"]["comments"] = {"nodes": []}
        report = cp.run_checks("cancel", ctx, {})
        self.assertEqual(find_check(report, "X1")["result"], "FAIL")
        self.assertEqual(report["verdict"], "REFUSE")


# ======================================================================
# close-map
# ======================================================================

class CloseMapAdmitTests(unittest.TestCase):
    def test_admits_with_facts_asserted_field_by_field(self):
        ctx = fx.close_map_ctx()
        report = cp.run_checks("close-map", ctx, {})
        self.assertEqual(report["verdict"], "ADMIT", report)
        for cid in ("CM1", "CM2", "CM3", "CM4", "CM5", "CM6"):
            self.assertEqual(find_check(report, cid)["result"], "PASS", cid)
        self.assertEqual(report["facts"]["charter_document_id"], "charter-doc-1")
        self.assertEqual(report["facts"]["open_children"], [])
        # CM7's accounting evidence covers every Done child, not just build
        # ones — the build child carries its [VALIDATION] comment, the
        # research child carries its own resolution comment.
        done_ids = {d["identifier"] for d in report["facts"]["done_children"]}
        self.assertEqual(done_ids, {"ACR-2", "ACR-3"})
        build_entry = next(d for d in report["facts"]["done_children"] if d["identifier"] == "ACR-2")
        self.assertIn("CONFIRMED", build_entry["validation_comment"])
        research_entry = next(d for d in report["facts"]["done_children"] if d["identifier"] == "ACR-3")
        self.assertIn("angle explored", research_entry["comments"][0])
        self.assertEqual(report["facts"]["refusal_reasons"], [])


class CloseMapRefuseTests(unittest.TestCase):
    def test_cm1_not_map_or_not_in_progress_refuses(self):
        ctx = fx.close_map_ctx()
        ctx["issue"]["state"] = {"name": "Done", "type": "completed"}
        report = cp.run_checks("close-map", ctx, {})
        self.assertEqual(find_check(report, "CM1")["result"], "FAIL")
        self.assertEqual(report["verdict"], "REFUSE")

    def test_cm2_open_challenge_refuses(self):
        ctx = fx.close_map_ctx()
        ctx["issue"]["comments"]["nodes"].append(
            {"id": "ch1", "body": "[CHALLENGE] scope", "createdAt": "2026-01-15T00:00:00Z", "user": {"id": "x"}}
        )
        report = cp.run_checks("close-map", ctx, {})
        self.assertEqual(find_check(report, "CM2")["result"], "FAIL")
        self.assertEqual(report["verdict"], "REFUSE")

    def test_cm3_open_children_named_and_refused(self):
        ctx = fx.close_map_ctx()
        ctx["children"].append({"id": "child-3", "identifier": "ACR-4", "title": "Still open",
                                 "state": {"name": "In Progress", "type": "started"}, "labels": {"nodes": []}, "delegate": None})
        report = cp.run_checks("close-map", ctx, {})
        cm3 = find_check(report, "CM3")
        self.assertEqual(cm3["result"], "FAIL")
        self.assertIn("ACR-4", cm3["detail"])
        self.assertEqual(report["facts"]["open_children"], ["ACR-4"])
        self.assertEqual(report["verdict"], "REFUSE")

    def test_cm4_missing_charter_refuses(self):
        ctx = fx.close_map_ctx()
        ctx["documents"] = []
        report = cp.run_checks("close-map", ctx, {})
        self.assertEqual(find_check(report, "CM4")["result"], "FAIL")
        self.assertEqual(report["verdict"], "REFUSE")

    def test_cm5_missing_validation_on_done_build_child_refuses(self):
        ctx = fx.close_map_ctx()
        ctx["children_comments"]["child-1"] = []
        report = cp.run_checks("close-map", ctx, {})
        cm5 = find_check(report, "CM5")
        self.assertEqual(cm5["result"], "FAIL")
        self.assertIn("ACR-2", cm5["detail"])
        self.assertEqual(report["verdict"], "REFUSE")

    def test_cm_a_aggregates_multiple_step1_failures_no_partial_refusal(self):
        ctx = fx.close_map_ctx()
        ctx["issue"]["comments"]["nodes"].append(
            {"id": "ch1", "body": "[CHALLENGE] scope", "createdAt": "2026-01-15T00:00:00Z", "user": {"id": "x"}}
        )
        ctx["documents"] = []
        report = cp.run_checks("close-map", ctx, {})
        self.assertEqual(find_check(report, "CM2")["result"], "FAIL")
        self.assertEqual(find_check(report, "CM4")["result"], "FAIL")
        self.assertEqual(find_check(report, "CM-a")["result"], "FAIL")
        # CM6 never evaluated once Step 1 has failures
        self.assertEqual(find_check(report, "CM6")["result"], "SKIP")
        self.assertEqual(len(report["facts"]["refusal_reasons"]), 2, "both Step-1 failures aggregated, not just the first")

    def test_cm6_missing_receipt_refuses(self):
        ctx = fx.close_map_ctx()
        ctx["issue"]["comments"]["nodes"] = [c for c in ctx["issue"]["comments"]["nodes"] if "map-conformance" not in c["body"]]
        report = cp.run_checks("close-map", ctx, {})
        self.assertEqual(find_check(report, "CM6")["result"], "FAIL")
        self.assertEqual(report["verdict"], "REFUSE")

    def test_cm6_stale_receipt_refuses(self):
        ctx = fx.close_map_ctx()
        ctx["issue"]["comments"]["nodes"][0]["createdAt"] = "2026-01-15T00:00:00Z"  # before the build child's own receipt
        report = cp.run_checks("close-map", ctx, {})
        self.assertEqual(find_check(report, "CM6")["result"], "FAIL")
        self.assertEqual(report["verdict"], "REFUSE")


class CloseMapReverifyTests(unittest.TestCase):
    """CM9's scripted re-verify path — cone_preflight.py close-map
    --reverify. Modeled on a post-execute fetch: the accounting document
    now exists on the map (not archived), and the charter document that
    used to carry only the FINALIZED marker now also carries archivedAt.
    Any drift on any of the four gates refuses instead of writing Done."""

    def _post_execute_ctx(self, **overrides):
        ctx = fx.close_map_ctx()
        # The charter is now archived (the execute step's step 4 already ran).
        ctx["documents"][0]["archivedAt"] = "2026-02-01T12:05:00Z"
        # The accounting document the execute step's step 3 just created.
        ctx["documents"].append({
            "id": "accounting-doc-1", "title": "Accounting — The Map",
            "archivedAt": None, "content": "Accounting body.",
        })
        ctx.update(overrides)
        return ctx

    def test_admits_when_all_four_gates_hold(self):
        ctx = self._post_execute_ctx()
        report = cp.run_close_map_reverify(ctx, "accounting-doc-1", "charter-doc-1")
        self.assertEqual(report["verdict"], "ADMIT", report)
        cm9 = find_check(report, "CM9")
        self.assertEqual(cm9["result"], "PASS")
        # CM1/CM2/CM3/CM5/CM6 re-run fresh as part of the reverify. CM4 does
        # NOT — by re-verify time the charter is expected to already be
        # archived, the opposite of CM4's admission-time "not yet archived"
        # requirement; CM9's own archival check supersedes it.
        for cid in ("CM1", "CM2", "CM3", "CM5", "CM6"):
            self.assertEqual(find_check(report, cid)["result"], "PASS", cid)
        with self.assertRaises(AssertionError):
            find_check(report, "CM4")

    def test_refuses_when_accounting_document_missing(self):
        ctx = self._post_execute_ctx()
        ctx["documents"] = [d for d in ctx["documents"] if d["id"] != "accounting-doc-1"]
        report = cp.run_close_map_reverify(ctx, "accounting-doc-1", "charter-doc-1")
        self.assertEqual(report["verdict"], "REFUSE")
        cm9 = find_check(report, "CM9")
        self.assertEqual(cm9["result"], "FAIL")
        self.assertIn("accounting-doc-1", cm9["detail"])
        self.assertIn("not found", cm9["detail"])

    def test_refuses_when_charter_not_actually_archived(self):
        ctx = self._post_execute_ctx()
        ctx["documents"][0]["archivedAt"] = None  # step 4 never landed
        report = cp.run_close_map_reverify(ctx, "accounting-doc-1", "charter-doc-1")
        self.assertEqual(report["verdict"], "REFUSE")
        cm9 = find_check(report, "CM9")
        self.assertEqual(cm9["result"], "FAIL")
        self.assertIn("not archived", cm9["detail"])

    def test_refuses_when_a_base_gate_regressed_between_admit_and_execute(self):
        """A child reopened (or a challenge landed) between the original
        ADMIT and the execute step — the four-gate re-verify must catch it,
        not just the two new artifacts."""
        ctx = self._post_execute_ctx()
        ctx["children"].append({
            "id": "child-3", "identifier": "ACR-4", "title": "Reopened mid-flight",
            "state": {"name": "In Progress", "type": "started"}, "labels": {"nodes": []}, "delegate": None,
        })
        report = cp.run_close_map_reverify(ctx, "accounting-doc-1", "charter-doc-1")
        self.assertEqual(report["verdict"], "REFUSE")
        self.assertEqual(find_check(report, "CM3")["result"], "FAIL")
        cm9 = find_check(report, "CM9")
        self.assertEqual(cm9["result"], "FAIL")
        self.assertIn("ACR-4", cm9["detail"])

    def test_refuses_when_document_ids_not_supplied(self):
        ctx = self._post_execute_ctx()
        report = cp.run_close_map_reverify(ctx, None, None)
        self.assertEqual(report["verdict"], "REFUSE")
        cm9 = find_check(report, "CM9")
        self.assertIn("no accounting_document_id", cm9["detail"])
        self.assertIn("no charter_document_id", cm9["detail"])

    def test_cli_reverify_flag_only_valid_for_close_map(self):
        with self.assertRaises(SystemExit):
            cp.main(["claim", "ACR-1", "--reverify"])

    def test_cli_reverify_end_to_end_through_stub_bridge(self):
        """Exercises the actual CLI wiring: cone_preflight.py close-map
        <map_id> --reverify --accounting-document-id ... --charter-document-id
        ... — the shape the rewritten close-map.md card's Step 5 invokes."""
        lb._STATE_CACHE.clear()
        map_node = {
            "id": "map-uuid-cli", "identifier": "ACR-1", "title": "The Map",
            "state": {"name": "In Progress", "type": "started"},
            "labels": {"nodes": [{"name": "map"}]},
            "parent": None, "delegate": None, "assignee": None,
            "team": {"key": "ACR"},
            "inverseRelations": {"nodes": []},
            "comments": {"nodes": [
                {"id": "mc1", "body": "[VALIDATION] — map-conformance\nVerdict: CONFIRMED\nIntent: map holds\nSpecifics: e2e ran clean",
                 "createdAt": "2026-02-01T11:00:00Z", "user": {"id": "viewer-1"}},
            ]},
            "history": {"nodes": []},
        }
        responses = [
            {"stdout": {"data": {"issue": map_node}}, "returncode": 0},  # resolve_issue_ref (the map)
            {"stdout": {"data": {"viewer": {"id": "viewer-1"}}}, "returncode": 0},  # resolve_viewer
            {"stdout": {"data": {"workflowStates": {"nodes": [
                {"id": "state-done", "name": "Done", "type": "completed"},
            ]}}}, "returncode": 0},  # resolve_state
            {"stdout": {"data": {"issues": {"nodes": [], "pageInfo": {"hasNextPage": False, "endCursor": None}}}}, "returncode": 0},  # fetch_children (empty)
            {"stdout": {"data": {"issue": {"documents": {"nodes": [
                {"id": "charter-doc-1", "title": "Charter", "archivedAt": "2026-02-01T12:05:00Z", "content": "**FINALIZED** — 2026-01-01 — operator sign-off recorded"},
                {"id": "accounting-doc-1", "title": "Accounting", "archivedAt": None, "content": "Accounting body."},
            ]}}}}, "returncode": 0},  # fetch_documents on the map
        ]
        tlb.script_responses(responses)

        exit_code = cp.main([
            "close-map", "ACR-1", "--reverify",
            "--accounting-document-id", "accounting-doc-1",
            "--charter-document-id", "charter-doc-1",
            "--bridge-cmd", " ".join(tlb.STUB_CMD),
        ])
        self.assertEqual(exit_code, lb.EXIT_OK)


# ======================================================================
# --list-checks conformance
# ======================================================================

class ListChecksConformanceTests(unittest.TestCase):
    """Every verb's --list-checks output must cover its full Check Inventory
    row set (id 1:1), and every runtime-emitted check id for that verb must
    appear in the static inventory (no drift between the two)."""

    EXPECTED_IDS = {
        "claim": {"C1", "C2", "C3", "C4a", "C4b", "C4c", "C5", "C5b", "C6", "C7", "C8", "C9", "C10", "C11", "C12"},
        "mark_done": {"M1", "M2", "M2.5", "M3a", "M3b", "M3c", "M3d", "M3e", "M3f", "M4", "M-i", "M-d", "M-o"},
        "resolve": {"R1", "R2", "R3", "R4"},
        "park": {"P1", "P2"},
        "block": {"B1", "B2"},
        "un-park": {"U1", "U2"},
        "cancel": {"X1"},
        "close-map": {"CM1", "CM2", "CM3", "CM4", "CM5", "CM-a", "CM6", "CM7", "CM8", "CM9"},
    }

    def test_inventory_ids_match_spec_transcription_exactly(self):
        for verb, expected in self.EXPECTED_IDS.items():
            actual = {row["id"] for row in cp.CHECK_INVENTORY[verb]}
            self.assertEqual(actual, expected, f"verb={verb}")

    def test_no_duplicate_ids_within_a_verb(self):
        for verb, rows in cp.CHECK_INVENTORY.items():
            ids = [r["id"] for r in rows]
            self.assertEqual(len(ids), len(set(ids)), f"duplicate id in verb={verb}: {ids}")

    def test_cross_cutting_ids_present_and_distinct_from_verb_ids(self):
        cross_ids = {row["id"] for row in cp.CROSS_CUTTING}
        self.assertEqual(cross_ids, {"X-esc", "X-team", "X-rb", "X-retry", "X-park"})
        for verb, rows in cp.CHECK_INVENTORY.items():
            verb_ids = {r["id"] for r in rows}
            self.assertEqual(verb_ids & cross_ids, set(), f"cross-cutting id collides with verb={verb}")

    def test_pure_judgment_ids_never_appear_in_runtime_checks(self):
        """C12, M-o, CM7 are pure Judgment (no script component) — they must
        live only in --list-checks + the playbook's Judgment kernel, never
        in a runtime checks[]/judgment_items[] emission."""
        pure_judgment = {"claim": "C12", "mark_done": "M-o", "close-map": "CM7"}
        fixtures = {
            "claim": (fx.claim_full_ctx(), fx.claim_flags()),
            "mark_done": (fx.mark_done_full_ctx(), fx.mark_done_flags()),
            "close-map": (fx.close_map_ctx(), {}),
        }
        for verb, pure_id in pure_judgment.items():
            ctx, flags = fixtures[verb]
            report = cp.run_checks(verb, ctx, flags)
            runtime_ids = {c["id"] for c in report["checks"]} | {j["id"].replace("J-", "") for j in report["judgment_items"]}
            self.assertNotIn(pure_id, runtime_ids, f"{pure_id} is pure Judgment; must not appear in {verb}'s runtime output")

    def test_execution_only_ids_never_appear_in_runtime_checks(self):
        """C10/C11/M4/R4/P2/B2/CM8/CM9 live in linear_bridge.py's mutation
        subcommands, not in cone_preflight's own runtime checks (which never
        mutates) — confirmed absent from a representative ADMIT run."""
        execution_only = {
            "claim": {"C10", "C11"},
            "mark_done": {"M4"},
            "resolve": {"R4"},
            "park": {"P2"},
            "block": {"B2"},
            "close-map": {"CM8", "CM9"},
        }
        fixtures = {
            "claim": (fx.claim_full_ctx(), fx.claim_flags()),
            "mark_done": (fx.mark_done_full_ctx(), fx.mark_done_flags()),
            "resolve": (fx.resolve_research_afk_ctx(), {}),
            "park": (fx.park_ctx(), {}),
            "block": (fx.block_ctx(), {}),
            "close-map": (fx.close_map_ctx(), {}),
        }
        for verb, ids in execution_only.items():
            ctx, flags = fixtures[verb]
            report = cp.run_checks(verb, ctx, flags)
            runtime_ids = {c["id"] for c in report["checks"]}
            self.assertEqual(runtime_ids & ids, set(), f"execution-only ids leaked into {verb}'s runtime checks: {runtime_ids & ids}")


if __name__ == "__main__":
    unittest.main()
