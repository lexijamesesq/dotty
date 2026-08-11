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

Reachability note (see report DEVIATIONS), updated for the contraction spec's
R-A ruling (2026-08-10 — J-P1/J-B1 retire as defers, comment presence stays
scripted): under the current Check Inventory homes, some verdicts are
structurally unreachable for some verbs:
- park, block, cancel: P1/B1/X1 are now purely Script-homed — presence by
  live fetch OR a supplied --comment-file (ruled symmetric across all three;
  the item-4 text naming only X1/P1 was an oversight in the enumeration).
  ADMIT and REFUSE are reachable; JUDGMENT_REQUIRED is not (no Script+J
  check remains in any of the three verbs' inventories).
- resolve, close-map: no Script+J (DEFER-capable) check exists in their
  inventory rows — JUDGMENT_REQUIRED is never reachable; ADMIT and REFUSE
  are.
- mark_done: R-B's M3g makes a full-variant ADMIT reachable only with
  --receipt-audited supplied (a plain run always defers) — map children are
  unaffected (M3g SKIPs).
These are consequences of the frozen inventory semantics, not a choice made
here — the tests below assert the full set of what IS reachable per verb.
"""
import contextlib
import io
import json
import os
import sys
import tempfile
import typing
import unittest

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
import cone_preflight as cp
import linear_bridge as lb

import tests.cone_fixtures as fx
import tests.test_linear_bridge as tlb


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


class ClaimStanceSubRuleTests(unittest.TestCase):
    """Team-lead addendum ruling: the map-child C1/C2 SKIP was loop-label-
    blind. A stance ticket (research + hitl together) keeps C1's SKIP (the
    body is Question + Destination, not an Objective) but ENFORCES C2 —
    wayfinder law requires stance tickets to carry a Done When, never a
    bare question. Every other map-child combination (grilling, task,
    prototype, research+afk) keeps both checks SKIP, unchanged."""

    def _stance_ctx(self, description):
        ctx = fx.claim_map_child_ctx()
        ctx["issue"]["labels"] = {"nodes": [{"name": "research"}, {"name": "hitl"}]}
        ctx["issue"]["description"] = description
        return ctx

    def test_stance_with_done_when_c2_passes(self):
        ctx = self._stance_ctx("## Question\n\nWhich framing?\n\n## Destination\n\nA rival-set for the operator.\n\n## Done When\n- Operator picks a framing\n")
        report = cp.run_checks("claim", ctx, fx.claim_flags())
        self.assertEqual(find_check(report, "C1")["result"], "SKIP")
        self.assertEqual(find_check(report, "C2")["result"], "PASS")
        self.assertEqual(report["verdict"], "ADMIT", report)

    def test_stance_bare_c2_fails_routes_needs_input(self):
        ctx = self._stance_ctx("## Question\n\nWhich framing?\n\n## Destination\n\nA rival-set for the operator.\n")
        report = cp.run_checks("claim", ctx, fx.claim_flags())
        self.assertEqual(find_check(report, "C1")["result"], "SKIP")
        self.assertEqual(find_check(report, "C2")["result"], "FAIL")
        self.assertEqual(report["verdict"], "NEEDS_INPUT", report)

    def test_stance_deferred_done_when_routes_needs_input(self):
        ctx = self._stance_ctx("## Question\n\nWhich framing?\n\n## Done When\n_to be set at claim_\n")
        report = cp.run_checks("claim", ctx, fx.claim_flags())
        self.assertEqual(find_check(report, "C2")["result"], "FAIL")
        self.assertEqual(report["verdict"], "NEEDS_INPUT")

    def test_grilling_map_child_unchanged_both_skip(self):
        ctx = fx.claim_map_child_ctx()
        ctx["issue"]["labels"] = {"nodes": [{"name": "grilling"}]}
        ctx["issue"]["description"] = "## Question\n\nWhat shape should the thing take?\n"
        report = cp.run_checks("claim", ctx, fx.claim_flags())
        self.assertEqual(find_check(report, "C1")["result"], "SKIP")
        self.assertEqual(find_check(report, "C2")["result"], "SKIP")
        self.assertEqual(report["verdict"], "ADMIT", report)

    def test_task_map_child_unchanged_both_skip(self):
        ctx = fx.claim_map_child_ctx()
        ctx["issue"]["labels"] = {"nodes": [{"name": "task"}]}
        ctx["issue"]["description"] = "## Question\n\nBare task child, no Done When.\n"
        report = cp.run_checks("claim", ctx, fx.claim_flags())
        self.assertEqual(find_check(report, "C1")["result"], "SKIP")
        self.assertEqual(find_check(report, "C2")["result"], "SKIP")
        self.assertEqual(report["verdict"], "ADMIT", report)

    def test_prototype_map_child_unchanged_both_skip(self):
        ctx = fx.claim_map_child_ctx()
        ctx["issue"]["labels"] = {"nodes": [{"name": "prototype"}]}
        ctx["issue"]["description"] = "## Question\n\nBare prototype child, no Done When.\n"
        report = cp.run_checks("claim", ctx, fx.claim_flags())
        self.assertEqual(find_check(report, "C1")["result"], "SKIP")
        self.assertEqual(find_check(report, "C2")["result"], "SKIP")
        self.assertEqual(report["verdict"], "ADMIT", report)

    def test_research_afk_map_child_unchanged_both_skip(self):
        # research WITHOUT hitl — the stance pattern requires both labels.
        ctx = fx.claim_map_child_ctx()
        ctx["issue"]["labels"] = {"nodes": [{"name": "research"}, {"name": "afk"}]}
        ctx["issue"]["description"] = "## Question\n\nBare research+afk child, no Done When.\n"
        report = cp.run_checks("claim", ctx, fx.claim_flags())
        self.assertEqual(find_check(report, "C1")["result"], "SKIP")
        self.assertEqual(find_check(report, "C2")["result"], "SKIP")
        self.assertEqual(report["verdict"], "ADMIT", report)


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
        ctx = fx.claim_map_child_ctx(issue=dict(fx.claim_map_child_ctx()["issue"], labels={"nodes": [{"name": "research"}, {"name": "hitl"}]}))
        report = cp.run_checks("claim", ctx, fx.claim_flags())
        self.assertEqual(report["verdict"], "ADMIT")
        self.assertEqual(report["facts"]["variant"], "map-child")
        self.assertEqual(report["facts"]["assignee_gate"], "set")

    def test_map_child_afk_skips_assignee_gate(self):
        ctx = fx.claim_map_child_ctx(issue=dict(fx.claim_map_child_ctx()["issue"], labels={"nodes": [{"name": "research"}, {"name": "afk"}]}))
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

    def test_model_label_ruled_admits(self):
        # Post-ruling resume (pressure-test v2 Gap 1): --model-ruled
        # terminates a re-run instead of deferring J-C8 again.
        ctx = fx.claim_full_ctx()
        ctx["issue"]["labels"] = {"nodes": [{"name": "task"}, {"name": "model:opus"}]}
        report = cp.run_checks("claim", ctx, fx.claim_flags(model_ruled=True))
        self.assertEqual(report["verdict"], "ADMIT", report)
        self.assertEqual(find_check(report, "C8")["result"], "PASS")
        self.assertEqual(report["judgment_items"], [])
        self.assertIn("C8", report["ruled"])


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
        self.assertIn("C6", report["ruled"])

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
    def test_full_variant_still_defers_on_m3g_without_receipt_audited(self):
        # R-B: full-variant (no map parent) mark_done always emits M3g's
        # structural defer — the one lane with no downstream audit. Even
        # with every other check clean, a plain run can never reach ADMIT.
        ctx = fx.mark_done_full_ctx()
        report = cp.run_checks("mark_done", ctx, fx.mark_done_flags())
        self.assertEqual(report["verdict"], "JUDGMENT_REQUIRED", report)
        for cid in ("M2", "M3a", "M3b", "M3c", "M3d", "M3e", "M3f"):
            self.assertEqual(find_check(report, cid)["result"], "PASS", cid)
        self.assertEqual(find_check(report, "M3g")["result"], "DEFER")
        item = find_judgment_item(report, "J-M3g")
        self.assertIsNone(item["evidence"])
        self.assertEqual(report["facts"]["viewer_id"], "viewer-1")
        self.assertEqual(report["facts"]["team_key"], "ACR")
        self.assertFalse(report["facts"]["idempotent"])
        self.assertEqual(report["facts"]["refusal_reasons"], [])
        # Needs Input is resolved alongside Done — it funds the card's M2.5
        # NEEDS_INPUT execution path (set-state to Needs Input).
        self.assertEqual(report["facts"]["state_ids"], {"done": "state-done", "needs_input": "state-ni"})

    def test_full_variant_admits_with_receipt_audited(self):
        # Post-ruling resume: --receipt-audited <comment-id> verifies a
        # CONFIRMED ticket-close [VALIDATION] postdating the In Progress
        # claim and clears M3g mechanically — the full-variant ADMIT path.
        ctx = fx.mark_done_full_ctx()
        ctx["issue"]["comments"]["nodes"].append(fx.ticket_close_receipt())
        report = cp.run_checks("mark_done", ctx, fx.mark_done_flags(receipt_audited="tc-1"))
        self.assertEqual(report["verdict"], "ADMIT", report)
        self.assertEqual(find_check(report, "M3g")["result"], "PASS")
        self.assertEqual(report["judgment_items"], [])
        self.assertIn("M3g", report["ruled"])

    def test_full_variant_receipt_audited_bogus_id_refuses(self):
        ctx = fx.mark_done_full_ctx()
        ctx["issue"]["comments"]["nodes"].append(fx.ticket_close_receipt())
        report = cp.run_checks("mark_done", ctx, fx.mark_done_flags(receipt_audited="no-such-comment-id"))
        self.assertEqual(find_check(report, "M3g")["result"], "FAIL")
        self.assertEqual(report["verdict"], "REFUSE")

    def test_full_variant_receipt_audited_wrong_type_refuses(self):
        ctx = fx.mark_done_full_ctx()
        ctx["issue"]["comments"]["nodes"].append(
            fx.ticket_close_receipt(comment_id="tc-2")
        )
        ctx["issue"]["comments"]["nodes"][-1]["body"] = "[VALIDATION] — conformance\nVerdict: CONFIRMED\nIntent: x\nSpecifics: y"
        report = cp.run_checks("mark_done", ctx, fx.mark_done_flags(receipt_audited="tc-2"))
        self.assertEqual(find_check(report, "M3g")["result"], "FAIL")
        self.assertIn("ticket-close", find_check(report, "M3g")["detail"])
        self.assertEqual(report["verdict"], "REFUSE")

    def test_full_variant_receipt_audited_stale_refuses(self):
        ctx = fx.mark_done_full_ctx()
        ctx["issue"]["comments"]["nodes"].append(
            fx.ticket_close_receipt(created_at="2026-01-29T00:00:00Z")  # before the 2026-01-30 claim
        )
        report = cp.run_checks("mark_done", ctx, fx.mark_done_flags(receipt_audited="tc-1"))
        self.assertEqual(find_check(report, "M3g")["result"], "FAIL")
        self.assertIn("predates", find_check(report, "M3g")["detail"])
        self.assertEqual(report["verdict"], "REFUSE")

    def test_build_variant_admits(self):
        # Map children never see M3g — CM5/CM6 audit them at close-map.
        ctx = fx.mark_done_build_ctx()
        report = cp.run_checks("mark_done", ctx, fx.mark_done_flags())
        self.assertEqual(report["verdict"], "ADMIT", report)
        self.assertEqual(find_check(report, "M2.5")["result"], "PASS")
        self.assertEqual(find_check(report, "M3g")["result"], "SKIP")
        self.assertEqual(report["facts"]["charter_document_id"], "charter-doc-1")

    def test_idempotent_already_done_admits_with_receipt_audited(self):
        # M3g fires "always" per R-B, including the idempotent-recovery
        # path — an already-Done full-variant ticket still has no
        # downstream audit lane.
        ctx = fx.mark_done_full_ctx()
        ctx["issue"]["state"] = {"name": "Done", "type": "completed"}
        ctx["issue"]["comments"]["nodes"].append(fx.ticket_close_receipt())
        report = cp.run_checks("mark_done", ctx, fx.mark_done_flags(receipt_audited="tc-1"))
        self.assertEqual(report["verdict"], "ADMIT")
        self.assertTrue(report["facts"]["idempotent"])
        self.assertEqual(find_check(report, "M2")["result"], "SKIP")
        self.assertEqual(find_check(report, "M-i")["result"], "PASS")
        self.assertEqual(find_check(report, "M3g")["result"], "PASS")

    def test_idempotent_already_done_without_receipt_audited_still_defers(self):
        ctx = fx.mark_done_full_ctx()
        ctx["issue"]["state"] = {"name": "Done", "type": "completed"}
        report = cp.run_checks("mark_done", ctx, fx.mark_done_flags())
        self.assertEqual(report["verdict"], "JUDGMENT_REQUIRED")
        self.assertTrue(report["facts"]["idempotent"])
        self.assertEqual(find_check(report, "M3g")["result"], "DEFER")

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

    def test_m3c_mandate_type_ruled_matching_admits(self):
        # Post-ruling resume: --mandate-type <t> supplies the resolved type
        # the caller already ruled the Done When text names in other words;
        # this re-run matches mechanically instead of deferring again.
        ctx = fx.mark_done_full_ctx()
        ctx["issue"]["description"] = fx.BASE_OBJECTIVE + "## Done When\nThe suite must be green and reviewed.\n\n" + fx.BASE_CTX
        ctx["issue"]["comments"]["nodes"].append(fx.ticket_close_receipt())
        report = cp.run_checks("mark_done", ctx, fx.mark_done_flags(mandate_type="conformance", receipt_audited="tc-1"))
        self.assertEqual(find_check(report, "M3c")["result"], "PASS")
        self.assertIn("M3c", report["ruled"])
        self.assertEqual(report["verdict"], "ADMIT", report)

    def test_m3c_mandate_type_ruled_mismatch_refuses(self):
        ctx = fx.mark_done_full_ctx()
        ctx["issue"]["description"] = fx.BASE_OBJECTIVE + "## Done When\nThe suite must be green and reviewed.\n\n" + fx.BASE_CTX
        report = cp.run_checks("mark_done", ctx, fx.mark_done_flags(mandate_type="pedagogical-fit"))
        self.assertEqual(find_check(report, "M3c")["result"], "FAIL")
        self.assertEqual(report["verdict"], "REFUSE")

    def test_m_d_exempt_ruled_admits(self):
        ctx = fx.mark_done_full_ctx()
        ctx["issue"]["comments"]["nodes"].append(fx.ticket_close_receipt())
        report = cp.run_checks(
            "mark_done", ctx,
            fx.mark_done_flags(deterministic_exempt=True, deterministic_exempt_context="fixture suite green, 40/40",
                                exempt_ruled=True, receipt_audited="tc-1"),
        )
        self.assertEqual(find_check(report, "M-d")["result"], "PASS")
        self.assertIn("M-d", report["ruled"])
        self.assertEqual(report["verdict"], "ADMIT", report)


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
    """R-A (operator, 2026-08-10): J-P1 retires as a defer — the composing
    session owns its ask's specificity. P1 is now purely Script-homed:
    presence by live fetch, or a --comment-file to post at execute."""

    def test_p1_comment_present_admits(self):
        ctx = fx.park_ctx()
        report = cp.run_checks("park", ctx, {})
        self.assertEqual(report["verdict"], "ADMIT", report)
        self.assertEqual(find_check(report, "P1")["result"], "PASS")
        self.assertEqual(report["judgment_items"], [])

    def test_p1_not_yet_posted_admits_with_comment_file(self):
        ctx = fx.park_ctx()
        ctx["issue"]["comments"] = {"nodes": []}
        report = cp.run_checks("park", ctx, {"comment_file": "/tmp/ask.txt"})
        self.assertEqual(report["verdict"], "ADMIT", report)
        self.assertEqual(find_check(report, "P1")["result"], "PASS")

    def test_p1_not_yet_posted_and_no_comment_file_refuses(self):
        ctx = fx.park_ctx()
        ctx["issue"]["comments"] = {"nodes": []}
        report = cp.run_checks("park", ctx, {})
        self.assertEqual(find_check(report, "P1")["result"], "FAIL")
        self.assertEqual(report["verdict"], "REFUSE")

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
    """R-A: J-B1 retires as a defer, same as park's J-P1. Ruled (team-lead):
    B1 is symmetric with P1/X1 — the item-4 enumeration naming only X1/P1
    was an oversight; all three comment-bearing checks pass on live-fetch
    presence OR a supplied --comment-file."""

    def test_b1_condition_present_admits(self):
        ctx = fx.block_ctx()
        report = cp.run_checks("block", ctx, {})
        self.assertEqual(report["verdict"], "ADMIT", report)
        self.assertEqual(find_check(report, "B1")["result"], "PASS")
        self.assertEqual(report["judgment_items"], [])

    def test_b1_not_yet_posted_admits_with_comment_file(self):
        ctx = fx.block_ctx()
        ctx["issue"]["comments"] = {"nodes": []}
        report = cp.run_checks("block", ctx, {"comment_file": "/tmp/condition.txt"})
        self.assertEqual(report["verdict"], "ADMIT", report)
        self.assertEqual(find_check(report, "B1")["result"], "PASS")

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

    def test_blocker_verified_admits_without_operator_directed(self):
        # R-C (operator, 2026-08-10): un-parking session re-checked the
        # condition itself — self-knowledge, ADMIT alongside --operator-directed.
        ctx = fx.unpark_ctx()
        report = cp.run_checks("un-park", ctx, fx.unpark_flags(blocker_verified=True))
        self.assertEqual(report["verdict"], "ADMIT", report)
        self.assertEqual(find_check(report, "U1")["result"], "PASS")
        self.assertIn("U1", report["ruled"])

    def test_blocker_verified_with_nothing_on_record_still_refuses(self):
        ctx = fx.unpark_ctx()
        ctx["issue"]["comments"] = {"nodes": []}
        report = cp.run_checks("un-park", ctx, fx.unpark_flags(blocker_verified=True))
        self.assertEqual(find_check(report, "U1")["result"], "FAIL")
        self.assertEqual(report["verdict"], "REFUSE")

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

    EXPECTED_IDS: typing.ClassVar[dict] = {
        "claim": {"C1", "C2", "C3", "C4a", "C4b", "C4c", "C5", "C5b", "C6", "C7", "C8", "C9", "C10", "C11", "C12"},
        "mark_done": {"M1", "M2", "M2.5", "M3a", "M3b", "M3c", "M3d", "M3e", "M3f", "M4", "M-i", "M-d", "M-o", "M3g"},
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


# ======================================================================
# --execute-if-clean — checks -> execute -> read-back, through the stub
# bridge (never a live call). Per fused verb: an ADMIT-executed run (write
# + read-back happen in-process), a defer-stop, and a REFUSE-stop, plus the
# comment-before-state sequencing law and the NEEDS_INPUT routing paths.
# Verdicts not reachable for a given verb (see the reachability note at the
# top of this file) don't get a defer-stop fixture — REFUSE and ADMIT cover
# what IS reachable.
# ======================================================================

def _resp(data):
    return {"stdout": {"data": data}, "returncode": 0}


def _issue_resp(node):
    return _resp({"issue": node})


def _viewer_resp(vid="viewer-1"):
    return _resp({"viewer": {"id": vid, "name": "App", "email": "a@x"}})


def _operator_resp(oid="operator-1"):
    return _resp({"users": {"nodes": [{"id": oid, "name": "Op", "email": "op@x", "admin": True, "app": False}]}})


def _states_resp(pairs):
    """pairs: [(name, id, type), ...] — one resolve_state call answers every
    name needed for a team (cached per process after the first lookup)."""
    return _resp({"workflowStates": {"nodes": [{"id": sid, "name": name, "type": stype} for (name, sid, stype) in pairs]}})


def _wip_resp(conflicts=None):
    return _resp({"issues": {"nodes": conflicts or []}})


def _docs_resp(docs):
    return _resp({"issue": {"documents": {"nodes": docs}}})


def _mutation_ok_resp():
    """Every mutation subcommand here discards its own mutation response
    (issueUpdate/issueRelationCreate success) and trusts only the
    independent readback — this is a content-agnostic stand-in for it."""
    return _resp({"issueUpdate": {"success": True}})


def _set_state_readback_resp(uuid, state_id, name, state_type):
    return _resp({"issue": {"id": uuid, "state": {"id": state_id, "name": name, "type": state_type}}})


def _release_delegate_readback_resp(uuid):
    return _resp({"issue": {"id": uuid, "delegate": None}})


def _comment_create_resp(comment_id):
    return _resp({"commentCreate": {"success": True, "comment": {"id": comment_id}}})


def _comments_readback_resp(nodes):
    return _resp({"issue": {"comments": {"nodes": nodes}}})


def _relation_create_resp():
    return _resp({"issueRelationCreate": {"success": True, "issueRelation": {
        "id": "rel-1", "type": "duplicate_of", "relatedIssue": {"id": "uuid-related"},
    }}})


def _relations_readback_resp(nodes):
    return _resp({"issue": {"relations": {"nodes": nodes}}})


def _e2e_issue_node(**overrides):
    node = {
        "id": "uuid-e2e", "identifier": "ACR-60", "title": "E2E ticket",
        "description": fx.BASE_OBJECTIVE + "## Done When\n- Tests pass\n\n" + fx.BASE_CTX,
        "state": {"name": "Todo", "type": "unstarted"},
        "labels": {"nodes": [{"name": "task"}]},
        "parent": None, "delegate": None, "assignee": None,
        "team": {"key": "ACR"},
        "inverseRelations": {"nodes": []},
        "comments": {"nodes": []},
        "history": {"nodes": []},
    }
    node.update(overrides)
    return node


def _run_main_capture(argv):
    buf = io.StringIO()
    with contextlib.redirect_stdout(buf):
        code = cp.main(argv)
    text = buf.getvalue()
    parsed = json.loads(text) if text.strip() else None
    return code, parsed


def _with_comment_file(body, fn):
    fd, path = tempfile.mkstemp(suffix=".txt")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            f.write(body)
        return fn(path)
    finally:
        os.unlink(path)


class ExecuteIfCleanAdmitTests(unittest.TestCase):
    def setUp(self):
        lb._STATE_CACHE.clear()

    def test_claim_admit_executed(self):
        issue_node = _e2e_issue_node(identifier="ACR-60", id="uuid-claim-e2e")
        tlb.script_responses([
            _issue_resp(issue_node),
            _viewer_resp("viewer-1"),
            _operator_resp("operator-1"),
            _states_resp([("In Progress", "state-ip", "started"), ("Needs Input", "state-ni", "triage")]),
            _wip_resp([]),
            _mutation_ok_resp(),
            _resp({"issue": {"id": "uuid-claim-e2e", "delegate": {"id": "viewer-1"},
                              "state": {"id": "state-ip", "name": "In Progress", "type": "started"},
                              "assignee": {"id": "operator-1"}}}),
        ])
        code, out = _run_main_capture([
            "claim", "ACR-60", "--project-id", "proj-1", "--execute-if-clean",
            "--bridge-cmd", " ".join(tlb.STUB_CMD),
        ])
        self.assertEqual(code, lb.EXIT_OK)
        self.assertEqual(out["verdict"], "ADMIT")
        self.assertTrue(out["executed"])
        self.assertTrue(out["result"]["claim_write"]["verified"])
        self.assertIn("elapsed_ms", out)
        self.assertNotIn("checks", out, "ADMIT is window-priced — no full checks[] dump")

    def test_claim_lost_race_not_executed(self):
        issue_node = _e2e_issue_node(identifier="ACR-60", id="uuid-claim-race")
        tlb.script_responses([
            _issue_resp(issue_node),
            _viewer_resp("viewer-1"),
            _operator_resp("operator-1"),
            _states_resp([("In Progress", "state-ip", "started"), ("Needs Input", "state-ni", "triage")]),
            _wip_resp([]),
            _mutation_ok_resp(),
            _resp({"issue": {"id": "uuid-claim-race", "delegate": {"id": "someone-else"},
                              "state": {"id": "state-ip", "name": "In Progress", "type": "started"},
                              "assignee": None}}),
        ])
        code, out = _run_main_capture([
            "claim", "ACR-60", "--project-id", "proj-1", "--execute-if-clean",
            "--bridge-cmd", " ".join(tlb.STUB_CMD),
        ])
        self.assertEqual(code, lb.EXIT_OK)
        self.assertEqual(out["verdict"], "ADMIT")
        self.assertFalse(out["executed"], "a lost race means back off and report, never proceed")
        self.assertTrue(out["result"]["claim_write"]["race_lost"])

    def test_claim_needs_input_executes_routing_comment_then_state(self):
        issue_node = _e2e_issue_node(
            identifier="ACR-61", id="uuid-claim-ni",
            description=fx.BASE_OBJECTIVE,  # Done When missing -> C2 NEEDS_INPUT
        )
        tlb.script_responses([
            _issue_resp(issue_node),
            _viewer_resp("viewer-1"),
            _operator_resp("operator-1"),
            _states_resp([("In Progress", "state-ip", "started"), ("Needs Input", "state-ni", "triage")]),
            _wip_resp([]),
            _comment_create_resp("c-routing-1"),
            _comments_readback_resp([{"id": "c-routing-1", "body": "Proposed Done When: ..."}]),
            _mutation_ok_resp(),
            _set_state_readback_resp("uuid-claim-ni", "state-ni", "Needs Input", "triage"),
        ])

        def run(path):
            return _run_main_capture([
                "claim", "ACR-61", "--project-id", "proj-1", "--execute-if-clean",
                "--comment-file", path, "--bridge-cmd", " ".join(tlb.STUB_CMD),
            ])

        code, out = _with_comment_file("Proposed Done When: ...", run)
        self.assertEqual(code, lb.EXIT_OK)
        self.assertEqual(out["verdict"], "NEEDS_INPUT")
        self.assertTrue(out["executed"])
        self.assertTrue(out["result"]["comment"]["verified"])
        self.assertTrue(out["result"]["set_state"]["verified"])
        # claim-path NEEDS_INPUT performs no delegate release — no claim
        # exists yet — confirmed by there being no "release_delegate" key.
        self.assertNotIn("release_delegate", out["result"])

    def test_claim_needs_input_without_comment_file_not_executed(self):
        issue_node = _e2e_issue_node(identifier="ACR-61", id="uuid-claim-ni2", description=fx.BASE_OBJECTIVE)
        tlb.script_responses([
            _issue_resp(issue_node),
            _viewer_resp("viewer-1"),
            _operator_resp("operator-1"),
            _states_resp([("In Progress", "state-ip", "started"), ("Needs Input", "state-ni", "triage")]),
            _wip_resp([]),
        ])
        code, out = _run_main_capture([
            "claim", "ACR-61", "--project-id", "proj-1", "--execute-if-clean",
            "--bridge-cmd", " ".join(tlb.STUB_CMD),
        ])
        self.assertEqual(code, lb.EXIT_OK)
        self.assertEqual(out["verdict"], "NEEDS_INPUT")
        self.assertFalse(out["executed"])

    def test_mark_done_admit_executed_full_variant_with_receipt_audited(self):
        issue_node = _e2e_issue_node(
            identifier="ACR-62", id="uuid-md-e2e",
            state={"name": "In Progress", "type": "started"},
            description=fx.BASE_OBJECTIVE + "## Done When\nValidation mandate: conformance\n\n" + fx.BASE_CTX,
            labels={"nodes": []},
            comments={"nodes": [
                {"id": "c1", "body": "[VALIDATION] — conformance\nVerdict: CONFIRMED\nIntent: it works\nSpecifics: ran the suite",
                 "createdAt": "2026-02-01T12:00:00Z", "user": {"id": "viewer-1"}},
                fx.ticket_close_receipt(),
            ]},
            history={"nodes": [
                {"createdAt": "2026-01-30T09:00:00Z", "fromState": {"name": "Todo", "type": "unstarted"},
                 "toState": {"name": "In Progress", "type": "started"}},
            ]},
        )
        tlb.script_responses([
            _issue_resp(issue_node),
            _viewer_resp("viewer-1"),
            _states_resp([("Done", "state-done", "completed"), ("Needs Input", "state-ni", "triage")]),
            _mutation_ok_resp(),
            _set_state_readback_resp("uuid-md-e2e", "state-done", "Done", "completed"),
        ])
        code, out = _run_main_capture([
            "mark_done", "ACR-62", "--execute-if-clean", "--receipt-audited", "tc-1",
            "--bridge-cmd", " ".join(tlb.STUB_CMD),
        ])
        self.assertEqual(code, lb.EXIT_OK)
        self.assertEqual(out["verdict"], "ADMIT", out)
        self.assertTrue(out["executed"])
        self.assertTrue(out["result"]["set_state"]["verified"])
        self.assertIn("M3g", out["ruled"])

    def test_mark_done_needs_input_m25_executes_state_only(self):
        map_parent = fx.map_parent()
        issue_node = _e2e_issue_node(
            identifier="ACR-63", id="uuid-md-m25",
            state={"name": "In Progress", "type": "started"},
            labels={"nodes": [{"name": "build"}]},
            parent=map_parent,
            description=fx.BASE_OBJECTIVE + "## Done When\nValidation mandate: conformance\n\n" + fx.BASE_CTX,
        )
        tlb.script_responses([
            _issue_resp(issue_node),
            _viewer_resp("viewer-1"),
            _states_resp([("Done", "state-done", "completed"), ("Needs Input", "state-ni", "triage")]),
            _issue_resp({"comments": {"nodes": [
                {"id": "ch1", "body": "[CHALLENGE] scope drifted", "createdAt": "2026-01-25T00:00:00Z", "user": {"id": "x"}},
            ]}}),  # parent comments fetch
            _docs_resp([]),  # parent documents fetch
            _mutation_ok_resp(),
            _set_state_readback_resp("uuid-md-m25", "state-ni", "Needs Input", "triage"),
        ])
        code, out = _run_main_capture([
            "mark_done", "ACR-63", "--execute-if-clean", "--bridge-cmd", " ".join(tlb.STUB_CMD),
        ])
        self.assertEqual(code, lb.EXIT_OK)
        self.assertEqual(out["verdict"], "NEEDS_INPUT")
        self.assertTrue(out["executed"])
        self.assertTrue(out["result"]["set_state"]["verified"])
        self.assertNotIn("comment", out["result"], "M2.5 performs no delegate ops — pending Q2, held to set-state-only")

    def test_mark_done_idempotent_admit_executed_no_mutation(self):
        issue_node = _e2e_issue_node(
            identifier="ACR-64", id="uuid-md-idem",
            state={"name": "Done", "type": "completed"},
            description=fx.BASE_OBJECTIVE + "## Done When\nValidation mandate: conformance\n\n" + fx.BASE_CTX,
            labels={"nodes": []},
            comments={"nodes": [
                {"id": "c1", "body": "[VALIDATION] — conformance\nVerdict: CONFIRMED\nIntent: it works\nSpecifics: ran the suite",
                 "createdAt": "2026-02-01T12:00:00Z", "user": {"id": "viewer-1"}},
                fx.ticket_close_receipt(),
            ]},
            history={"nodes": [
                {"createdAt": "2026-01-30T09:00:00Z", "fromState": {"name": "Todo", "type": "unstarted"},
                 "toState": {"name": "In Progress", "type": "started"}},
            ]},
        )
        counter = tlb.script_responses([
            _issue_resp(issue_node),
            _viewer_resp("viewer-1"),
            _states_resp([("Done", "state-done", "completed"), ("Needs Input", "state-ni", "triage")]),
        ])
        code, out = _run_main_capture([
            "mark_done", "ACR-64", "--execute-if-clean", "--receipt-audited", "tc-1",
            "--bridge-cmd", " ".join(tlb.STUB_CMD),
        ])
        self.assertEqual(code, lb.EXIT_OK)
        self.assertEqual(out["verdict"], "ADMIT")
        self.assertTrue(out["executed"])
        self.assertIn("no re-transition", out["result"]["note"])
        self.assertEqual(tlb.call_count(counter), 3, "idempotent execute makes zero additional bridge calls")

    def test_resolve_admit_executed(self):
        issue_node = _e2e_issue_node(
            identifier="ACR-65", id="uuid-resolve-e2e",
            state={"name": "In Progress", "type": "started"},
            labels={"nodes": [{"name": "research"}, {"name": "afk"}]},
            parent=fx.map_parent(),
            comments={"nodes": [
                {"id": "c1", "body": "Resolution: findings attached.", "createdAt": "2026-02-01T12:00:00Z", "user": {"id": "viewer-1"}},
            ]},
        )
        tlb.script_responses([
            _issue_resp(issue_node),
            _viewer_resp("viewer-1"),
            _states_resp([("Done", "state-done", "completed")]),
            _docs_resp([{"id": "doc-findings-1", "title": "Findings", "archivedAt": None}]),
            _mutation_ok_resp(),
            _set_state_readback_resp("uuid-resolve-e2e", "state-done", "Done", "completed"),
        ])
        code, out = _run_main_capture([
            "resolve", "ACR-65", "--execute-if-clean", "--bridge-cmd", " ".join(tlb.STUB_CMD),
        ])
        self.assertEqual(code, lb.EXIT_OK)
        self.assertEqual(out["verdict"], "ADMIT")
        self.assertTrue(out["executed"])
        self.assertTrue(out["result"]["set_state"]["verified"])

    def test_park_admit_executed_comment_already_present(self):
        issue_node = _e2e_issue_node(
            identifier="ACR-66", id="uuid-park-e2e",
            state={"name": "In Progress", "type": "started"},
            comments={"nodes": [
                {"id": "c1", "body": "Need a decision on the routing convention.", "createdAt": "2026-02-01T12:00:00Z", "user": {"id": "viewer-1"}},
            ]},
        )
        tlb.script_responses([
            _issue_resp(issue_node),
            _viewer_resp("viewer-1"),
            _states_resp([("Needs Input", "state-ni", "triage")]),
            _mutation_ok_resp(),
            _set_state_readback_resp("uuid-park-e2e", "state-ni", "Needs Input", "triage"),
            _mutation_ok_resp(),
            _release_delegate_readback_resp("uuid-park-e2e"),
        ])
        code, out = _run_main_capture([
            "park", "ACR-66", "--execute-if-clean", "--bridge-cmd", " ".join(tlb.STUB_CMD),
        ])
        self.assertEqual(code, lb.EXIT_OK)
        self.assertEqual(out["verdict"], "ADMIT")
        self.assertTrue(out["executed"])
        self.assertNotIn("comment", out["result"], "ask already present by live fetch — nothing fresh to post")
        self.assertTrue(out["result"]["set_state"]["verified"])
        self.assertTrue(out["result"]["release_delegate"]["verified"])

    def test_park_admit_executed_comment_file_posts_before_state(self):
        issue_node = _e2e_issue_node(identifier="ACR-67", id="uuid-park-cf", state={"name": "In Progress", "type": "started"})
        log_path = tlb.script_log()
        tlb.script_responses([
            _issue_resp(issue_node),
            _viewer_resp("viewer-1"),
            _states_resp([("Needs Input", "state-ni", "triage")]),
            _comment_create_resp("c-ask-1"),
            _comments_readback_resp([{"id": "c-ask-1", "body": "Please decide X."}]),
            _mutation_ok_resp(),
            _set_state_readback_resp("uuid-park-cf", "state-ni", "Needs Input", "triage"),
            _mutation_ok_resp(),
            _release_delegate_readback_resp("uuid-park-cf"),
        ])

        def run(path):
            return _run_main_capture([
                "park", "ACR-67", "--execute-if-clean", "--comment-file", path,
                "--bridge-cmd", " ".join(tlb.STUB_CMD),
            ])

        code, out = _with_comment_file("Please decide X.", run)
        self.assertEqual(code, lb.EXIT_OK)
        self.assertTrue(out["executed"])
        self.assertTrue(out["result"]["comment"]["verified"])
        self.assertTrue(out["result"]["set_state"]["verified"])

        # Sequencing law (F2): the comment posts BEFORE the state change —
        # commentCreate must precede the stateId-bearing issueUpdate in the
        # actual call order sent to the bridge.
        queries = tlb.read_log(log_path)
        comment_idx = next(i for i, q in enumerate(queries) if "commentCreate" in q)
        state_idx = next(i for i, q in enumerate(queries) if "stateId" in q and "issueUpdate" in q)
        self.assertLess(comment_idx, state_idx, "comment-before-state-change law violated")

    def test_block_admit_executed(self):
        issue_node = _e2e_issue_node(
            identifier="ACR-68", id="uuid-block-e2e",
            state={"name": "In Progress", "type": "started"},
            comments={"nodes": [
                {"id": "c1", "body": "Blocked on PR #482 merging upstream.", "createdAt": "2026-02-01T12:00:00Z", "user": {"id": "viewer-1"}},
            ]},
        )
        tlb.script_responses([
            _issue_resp(issue_node),
            _viewer_resp("viewer-1"),
            _states_resp([("Blocked", "state-blocked", "backlog")]),
            _mutation_ok_resp(),
            _set_state_readback_resp("uuid-block-e2e", "state-blocked", "Blocked", "backlog"),
            _mutation_ok_resp(),
            _release_delegate_readback_resp("uuid-block-e2e"),
        ])
        code, out = _run_main_capture([
            "block", "ACR-68", "--execute-if-clean", "--bridge-cmd", " ".join(tlb.STUB_CMD),
        ])
        self.assertEqual(code, lb.EXIT_OK)
        self.assertEqual(out["verdict"], "ADMIT")
        self.assertTrue(out["executed"])
        self.assertTrue(out["result"]["release_delegate"]["verified"])

    def test_block_admit_executed_comment_file_posts_before_state(self):
        # Ruled symmetric with park/cancel — B1 also passes on a supplied
        # --comment-file when no condition exists yet, posted before the
        # state change per the sequencing law.
        issue_node = _e2e_issue_node(identifier="ACR-83", id="uuid-block-cf", state={"name": "In Progress", "type": "started"})
        log_path = tlb.script_log()
        tlb.script_responses([
            _issue_resp(issue_node),
            _viewer_resp("viewer-1"),
            _states_resp([("Blocked", "state-blocked", "backlog")]),
            _comment_create_resp("c-condition-1"),
            _comments_readback_resp([{"id": "c-condition-1", "body": "Blocked on PR #482."}]),
            _mutation_ok_resp(),
            _set_state_readback_resp("uuid-block-cf", "state-blocked", "Blocked", "backlog"),
            _mutation_ok_resp(),
            _release_delegate_readback_resp("uuid-block-cf"),
        ])

        def run(path):
            return _run_main_capture([
                "block", "ACR-83", "--execute-if-clean", "--comment-file", path,
                "--bridge-cmd", " ".join(tlb.STUB_CMD),
            ])

        code, out = _with_comment_file("Blocked on PR #482.", run)
        self.assertEqual(code, lb.EXIT_OK)
        self.assertTrue(out["executed"])
        self.assertTrue(out["result"]["comment"]["verified"])
        self.assertTrue(out["result"]["set_state"]["verified"])

        queries = tlb.read_log(log_path)
        comment_idx = next(i for i, q in enumerate(queries) if "commentCreate" in q)
        state_idx = next(i for i, q in enumerate(queries) if "stateId" in q and "issueUpdate" in q)
        self.assertLess(comment_idx, state_idx, "comment-before-state-change law violated")

    def test_unpark_admit_executed(self):
        issue_node = _e2e_issue_node(
            identifier="ACR-69", id="uuid-unpark-e2e",
            state={"name": "Blocked", "type": "backlog"},
        )
        tlb.script_responses([
            _issue_resp(issue_node),
            _viewer_resp("viewer-1"),
            _states_resp([("Todo", "state-todo", "unstarted")]),
            _mutation_ok_resp(),
            _set_state_readback_resp("uuid-unpark-e2e", "state-todo", "Todo", "unstarted"),
        ])
        code, out = _run_main_capture([
            "un-park", "ACR-69", "--operator-directed", "--execute-if-clean",
            "--bridge-cmd", " ".join(tlb.STUB_CMD),
        ])
        self.assertEqual(code, lb.EXIT_OK)
        self.assertEqual(out["verdict"], "ADMIT")
        self.assertTrue(out["executed"])
        self.assertTrue(out["result"]["set_state"]["verified"])

    def test_unpark_blocker_verified_admit_executed(self):
        issue_node = _e2e_issue_node(
            identifier="ACR-70", id="uuid-unpark-bv",
            state={"name": "Blocked", "type": "backlog"},
            comments={"nodes": [
                {"id": "c1", "body": "Blocked on PR #482 merging upstream.", "createdAt": "2026-02-01T12:00:00Z", "user": {"id": "viewer-1"}},
            ]},
        )
        tlb.script_responses([
            _issue_resp(issue_node),
            _viewer_resp("viewer-1"),
            _states_resp([("Todo", "state-todo", "unstarted")]),
            _mutation_ok_resp(),
            _set_state_readback_resp("uuid-unpark-bv", "state-todo", "Todo", "unstarted"),
        ])
        code, out = _run_main_capture([
            "un-park", "ACR-70", "--blocker-verified", "--execute-if-clean",
            "--bridge-cmd", " ".join(tlb.STUB_CMD),
        ])
        self.assertEqual(code, lb.EXIT_OK)
        self.assertEqual(out["verdict"], "ADMIT")
        self.assertTrue(out["executed"])
        self.assertIn("U1", out["ruled"])

    def test_cancel_admit_executed_reason_already_present(self):
        issue_node = _e2e_issue_node(
            identifier="ACR-71", id="uuid-cancel-e2e",
            comments={"nodes": [
                {"id": "c1", "body": "Superseded — canceling.", "createdAt": "2026-02-01T12:00:00Z", "user": {"id": "viewer-1"}},
            ]},
        )
        tlb.script_responses([
            _issue_resp(issue_node),
            _viewer_resp("viewer-1"),
            _states_resp([("Canceled", "state-canceled", "canceled")]),
            _mutation_ok_resp(),
            _set_state_readback_resp("uuid-cancel-e2e", "state-canceled", "Canceled", "canceled"),
        ])
        code, out = _run_main_capture([
            "cancel", "ACR-71", "--execute-if-clean", "--bridge-cmd", " ".join(tlb.STUB_CMD),
        ])
        self.assertEqual(code, lb.EXIT_OK)
        self.assertEqual(out["verdict"], "ADMIT")
        self.assertTrue(out["executed"])
        self.assertNotIn("comment", out["result"])

    def test_cancel_admit_executed_comment_file_posts_before_state_with_relation(self):
        issue_node = _e2e_issue_node(identifier="ACR-72", id="uuid-cancel-cf")
        log_path = tlb.script_log()
        tlb.script_responses([
            _issue_resp(issue_node),
            _viewer_resp("viewer-1"),
            _states_resp([("Canceled", "state-canceled", "canceled")]),
            _comment_create_resp("c-reason-1"),
            _comments_readback_resp([{"id": "c-reason-1", "body": "Duplicate of ACR-9."}]),
            _mutation_ok_resp(),
            _set_state_readback_resp("uuid-cancel-cf", "state-canceled", "Canceled", "canceled"),
            _mutation_ok_resp(),
            _relations_readback_resp([{"type": "duplicate_of", "relatedIssue": {"id": "uuid-related-1"}}]),
        ])

        def run(path):
            return _run_main_capture([
                "cancel", "ACR-72", "--execute-if-clean", "--comment-file", path,
                "--related-id", "uuid-related-1", "--bridge-cmd", " ".join(tlb.STUB_CMD),
            ])

        code, out = _with_comment_file("Duplicate of ACR-9.", run)
        self.assertEqual(code, lb.EXIT_OK)
        self.assertTrue(out["executed"])
        self.assertTrue(out["result"]["comment"]["verified"])
        self.assertTrue(out["result"]["set_state"]["verified"])
        self.assertTrue(out["result"]["create_relation"]["verified"])

        queries = tlb.read_log(log_path)
        comment_idx = next(i for i, q in enumerate(queries) if "commentCreate" in q)
        state_idx = next(i for i, q in enumerate(queries) if "stateId" in q and "issueUpdate" in q)
        self.assertLess(comment_idx, state_idx, "comment-before-state-change law violated")


class ExecuteIfCleanDeferStopTests(unittest.TestCase):
    """JUDGMENT_REQUIRED-verdict runs — reachable only for claim, mark_done,
    un-park post-R-A (see the file-level reachability note). --execute-if-
    clean must stop before any mutation call: executed=False, and the bridge
    call count matches the check-phase reads only."""

    def setUp(self):
        lb._STATE_CACHE.clear()

    def test_claim_defers_not_executed(self):
        issue_node = _e2e_issue_node(
            identifier="ACR-73", id="uuid-claim-defer",
            labels={"nodes": [{"name": "task"}, {"name": "model:opus"}]},
        )
        counter = tlb.script_responses([
            _issue_resp(issue_node),
            _viewer_resp("viewer-1"),
            _operator_resp("operator-1"),
            _states_resp([("In Progress", "state-ip", "started"), ("Needs Input", "state-ni", "triage")]),
            _wip_resp([]),
        ])
        code, out = _run_main_capture([
            "claim", "ACR-73", "--project-id", "proj-1", "--execute-if-clean",
            "--bridge-cmd", " ".join(tlb.STUB_CMD),
        ])
        self.assertEqual(code, lb.EXIT_OK)
        self.assertEqual(out["verdict"], "JUDGMENT_REQUIRED")
        self.assertFalse(out["executed"])
        self.assertIn("checks", out, "non-ADMIT always prints full detail")
        self.assertEqual(tlb.call_count(counter), 5, "defer-stop makes zero mutation calls beyond the check-phase reads")

    def test_mark_done_defers_not_executed(self):
        issue_node = _e2e_issue_node(
            identifier="ACR-74", id="uuid-md-defer",
            state={"name": "In Progress", "type": "started"},
            description=fx.BASE_OBJECTIVE + "## Done When\nValidation mandate: conformance\n\n" + fx.BASE_CTX,
            labels={"nodes": []},
            comments={"nodes": [
                {"id": "c1", "body": "[VALIDATION] — conformance\nVerdict: CONFIRMED\nIntent: it works\nSpecifics: ran the suite",
                 "createdAt": "2026-02-01T12:00:00Z", "user": {"id": "viewer-1"}},
            ]},
            history={"nodes": [
                {"createdAt": "2026-01-30T09:00:00Z", "fromState": {"name": "Todo", "type": "unstarted"},
                 "toState": {"name": "In Progress", "type": "started"}},
            ]},
        )
        counter = tlb.script_responses([
            _issue_resp(issue_node),
            _viewer_resp("viewer-1"),
            _states_resp([("Done", "state-done", "completed"), ("Needs Input", "state-ni", "triage")]),
        ])
        code, out = _run_main_capture([
            "mark_done", "ACR-74", "--execute-if-clean", "--bridge-cmd", " ".join(tlb.STUB_CMD),
        ])
        self.assertEqual(code, lb.EXIT_OK)
        self.assertEqual(out["verdict"], "JUDGMENT_REQUIRED", out)
        self.assertFalse(out["executed"])
        self.assertEqual(tlb.call_count(counter), 3, "M3g's default defer makes zero mutation calls")

    def test_unpark_defers_not_executed(self):
        issue_node = _e2e_issue_node(
            identifier="ACR-75", id="uuid-unpark-defer",
            state={"name": "Blocked", "type": "backlog"},
            comments={"nodes": [
                {"id": "c1", "body": "Blocked on PR #482 merging upstream.", "createdAt": "2026-02-01T12:00:00Z", "user": {"id": "viewer-1"}},
            ]},
        )
        counter = tlb.script_responses([
            _issue_resp(issue_node),
            _viewer_resp("viewer-1"),
            _states_resp([("Todo", "state-todo", "unstarted")]),
        ])
        code, out = _run_main_capture([
            "un-park", "ACR-75", "--execute-if-clean", "--bridge-cmd", " ".join(tlb.STUB_CMD),
        ])
        self.assertEqual(code, lb.EXIT_OK)
        self.assertEqual(out["verdict"], "JUDGMENT_REQUIRED")
        self.assertFalse(out["executed"])
        self.assertEqual(tlb.call_count(counter), 3)


class ExecuteIfCleanRefuseStopTests(unittest.TestCase):
    """REFUSE-verdict runs, one per fused verb — --execute-if-clean stops
    before any mutation call."""

    def setUp(self):
        lb._STATE_CACHE.clear()

    def test_claim_refuses_not_executed(self):
        issue_node = _e2e_issue_node(identifier="ACR-76", id="uuid-claim-refuse", description="## Done When\n- Tests pass\n")
        counter = tlb.script_responses([
            _issue_resp(issue_node),
            _viewer_resp("viewer-1"),
            _operator_resp("operator-1"),
            _states_resp([("In Progress", "state-ip", "started"), ("Needs Input", "state-ni", "triage")]),
            _wip_resp([]),
        ])
        code, out = _run_main_capture([
            "claim", "ACR-76", "--project-id", "proj-1", "--execute-if-clean",
            "--bridge-cmd", " ".join(tlb.STUB_CMD),
        ])
        self.assertEqual(code, lb.EXIT_OK)
        self.assertEqual(out["verdict"], "REFUSE")
        self.assertFalse(out["executed"])
        self.assertEqual(tlb.call_count(counter), 5)

    def test_mark_done_refuses_not_executed(self):
        issue_node = _e2e_issue_node(identifier="ACR-77", id="uuid-md-refuse", state={"name": "Todo", "type": "unstarted"})
        counter = tlb.script_responses([
            _issue_resp(issue_node),
            _viewer_resp("viewer-1"),
            _states_resp([("Done", "state-done", "completed"), ("Needs Input", "state-ni", "triage")]),
        ])
        code, out = _run_main_capture([
            "mark_done", "ACR-77", "--execute-if-clean", "--bridge-cmd", " ".join(tlb.STUB_CMD),
        ])
        self.assertEqual(code, lb.EXIT_OK)
        self.assertEqual(out["verdict"], "REFUSE")
        self.assertFalse(out["executed"])
        self.assertEqual(tlb.call_count(counter), 3)

    def test_resolve_refuses_not_executed(self):
        # no map parent -> R1 guard fails. gather_context() always fetches
        # documents for resolve regardless of what the check decides — the
        # fetch isn't gated on R1, only the check's own logic is.
        issue_node = _e2e_issue_node(identifier="ACR-78", id="uuid-resolve-refuse")
        counter = tlb.script_responses([
            _issue_resp(issue_node),
            _viewer_resp("viewer-1"),
            _states_resp([("Done", "state-done", "completed")]),
            _docs_resp([]),
        ])
        code, out = _run_main_capture([
            "resolve", "ACR-78", "--execute-if-clean", "--bridge-cmd", " ".join(tlb.STUB_CMD),
        ])
        self.assertEqual(code, lb.EXIT_OK)
        self.assertEqual(out["verdict"], "REFUSE")
        self.assertFalse(out["executed"])
        self.assertEqual(tlb.call_count(counter), 4)

    def test_park_refuses_not_executed(self):
        issue_node = _e2e_issue_node(identifier="ACR-79", id="uuid-park-refuse", state={"name": "In Progress", "type": "started"})
        counter = tlb.script_responses([
            _issue_resp(issue_node),
            _viewer_resp("viewer-1"),
            _states_resp([("Needs Input", "state-ni", "triage")]),
        ])
        code, out = _run_main_capture([
            "park", "ACR-79", "--execute-if-clean", "--bridge-cmd", " ".join(tlb.STUB_CMD),
        ])
        self.assertEqual(code, lb.EXIT_OK)
        self.assertEqual(out["verdict"], "REFUSE")
        self.assertFalse(out["executed"])
        self.assertEqual(tlb.call_count(counter), 3)

    def test_block_refuses_not_executed(self):
        issue_node = _e2e_issue_node(identifier="ACR-80", id="uuid-block-refuse", state={"name": "In Progress", "type": "started"})
        counter = tlb.script_responses([
            _issue_resp(issue_node),
            _viewer_resp("viewer-1"),
            _states_resp([("Blocked", "state-blocked", "backlog")]),
        ])
        code, out = _run_main_capture([
            "block", "ACR-80", "--execute-if-clean", "--bridge-cmd", " ".join(tlb.STUB_CMD),
        ])
        self.assertEqual(code, lb.EXIT_OK)
        self.assertEqual(out["verdict"], "REFUSE")
        self.assertFalse(out["executed"])
        self.assertEqual(tlb.call_count(counter), 3)

    def test_unpark_refuses_not_executed(self):
        issue_node = _e2e_issue_node(identifier="ACR-81", id="uuid-unpark-refuse", state={"name": "In Progress", "type": "started"})
        counter = tlb.script_responses([
            _issue_resp(issue_node),
            _viewer_resp("viewer-1"),
            _states_resp([("Todo", "state-todo", "unstarted")]),
        ])
        code, out = _run_main_capture([
            "un-park", "ACR-81", "--operator-directed", "--execute-if-clean",
            "--bridge-cmd", " ".join(tlb.STUB_CMD),
        ])
        self.assertEqual(code, lb.EXIT_OK)
        self.assertEqual(out["verdict"], "REFUSE")
        self.assertFalse(out["executed"])
        self.assertEqual(tlb.call_count(counter), 3)

    def test_cancel_refuses_not_executed(self):
        issue_node = _e2e_issue_node(identifier="ACR-82", id="uuid-cancel-refuse")
        counter = tlb.script_responses([
            _issue_resp(issue_node),
            _viewer_resp("viewer-1"),
            _states_resp([("Canceled", "state-canceled", "canceled")]),
        ])
        code, out = _run_main_capture([
            "cancel", "ACR-82", "--execute-if-clean", "--bridge-cmd", " ".join(tlb.STUB_CMD),
        ])
        self.assertEqual(code, lb.EXIT_OK)
        self.assertEqual(out["verdict"], "REFUSE")
        self.assertFalse(out["executed"])
        self.assertEqual(tlb.call_count(counter), 3)


class ExecuteIfCleanUsageTests(unittest.TestCase):
    def test_project_id_required_for_claim_config_gap(self):
        code, out = _run_main_capture(["claim", "ACR-1", "--bridge-cmd", " ".join(tlb.STUB_CMD)])
        self.assertEqual(code, lb.EXIT_CONFIG_GAP)
        self.assertIsNone(out, "refused before any JSON was printed")

    def test_execute_if_clean_rejected_for_close_map(self):
        with self.assertRaises(SystemExit):
            cp.main(["close-map", "ACR-1", "--execute-if-clean"])


if __name__ == "__main__":
    unittest.main()
