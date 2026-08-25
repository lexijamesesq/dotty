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
- close-map: no Script+J (DEFER-capable) check exists in its inventory
  rows — JUDGMENT_REQUIRED is never reachable; ADMIT and REFUSE are.
  (resolve retired this slice — begin replaces it as the judgment-kernel
  verb, and begin's BG2 IS Script+J, so JUDGMENT_REQUIRED is reachable
  there.)
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

    def test_build_child_admits_as_map_child_to_planning(self):
        # Build variant removed: a build child is an ordinary map child now —
        # map-child variant, claims to Planning so the plan-attack gate at
        # `begin` fires on it, assignee skipped (build is not hitl).
        ctx = fx.claim_build_ctx()
        report = cp.run_checks("claim", ctx, fx.claim_flags())
        self.assertEqual(report["verdict"], "ADMIT")
        self.assertEqual(report["facts"]["variant"], "map-child")
        self.assertEqual(report["facts"]["assignee_gate"], "skip")
        self.assertEqual(report["facts"]["claim_target_state_key"], "planning")

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

    def test_c3_map_child_no_type_label_now_admits(self):
        # Brick 2 / compatibility window: the old "map child with no type
        # label -> conflict cell" branch retired from both C3 and C7 — a
        # label-less map child is now a valid map-child variant, admitted
        # exactly like an old-labeled one.
        ctx = fx.claim_map_child_ctx()
        ctx["issue"]["labels"] = {"nodes": []}
        report = cp.run_checks("claim", ctx, fx.claim_flags())
        self.assertEqual(find_check(report, "C3")["result"], "PASS")
        self.assertEqual(find_check(report, "C7")["result"], "PASS")
        self.assertEqual(report["facts"]["variant"], "map-child")
        self.assertEqual(report["verdict"], "ADMIT", report)

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

    def test_c7_build_child_is_map_child_variant(self):
        # Build variant removed: a build child selects the map-child variant
        # (no separate build variant, no pre-flight flag gate) and admits.
        ctx = fx.claim_build_ctx()
        report = cp.run_checks("claim", ctx, fx.claim_flags())
        self.assertEqual(find_check(report, "C7")["result"], "PASS")
        self.assertEqual(report["facts"]["variant"], "map-child")
        self.assertEqual(report["verdict"], "ADMIT", report)


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
        # Needs Input is resolved alongside Done — it funds the NEEDS_INPUT
        # execution path (set-state to Needs Input).
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
        # Map children never see M3g — CM6 audits them at close-map.
        ctx = fx.mark_done_build_ctx()
        report = cp.run_checks("mark_done", ctx, fx.mark_done_flags())
        self.assertEqual(report["verdict"], "ADMIT", report)
        self.assertEqual(find_check(report, "M3g")["result"], "SKIP")
        self.assertNotIn("charter_document_id", report["facts"])

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

    def test_m2_decision_type_label_no_longer_gates_mark_done(self):
        # Brick 2: resolve is retired, mark_done is the sole close verb —
        # a decision-type label no longer refuses M2 (the old redirect
        # string naming "resolve" is gone with it).
        ctx = fx.mark_done_full_ctx()
        ctx["issue"]["labels"] = {"nodes": [{"name": "research"}]}
        report = cp.run_checks("mark_done", ctx, fx.mark_done_flags())
        self.assertEqual(find_check(report, "M2")["result"], "PASS")
        for c in report["checks"]:
            self.assertNotIn("resolve", c["detail"])

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

    def test_m2_planning_state_refuses_forbidden_planning_to_done_edge(self):
        # Brick 1 name-keying: Planning shares type "started" with In
        # Progress — a type-keyed M2 would wrongly let a Planning ticket
        # through. Name-keyed, it correctly refuses the forbidden
        # Planning->Done edge.
        ctx = fx.mark_done_map_child_ctx()
        ctx["issue"]["state"] = {"name": "Planning", "type": "started"}
        report = cp.run_checks("mark_done", ctx, fx.mark_done_flags())
        m2 = find_check(report, "M2")
        self.assertEqual(m2["result"], "FAIL")
        self.assertIn("not In Progress", m2["detail"])
        self.assertEqual(report["verdict"], "REFUSE")


class MarkDoneHandoffTests(unittest.TestCase):
    """M-h: a map-child close requires a [HANDOFF] comment — present by
    live fetch OR supplied via --handoff-file, posted BEFORE the Done
    state change. Full/no-map variant: not required."""

    def test_map_child_with_handoff_present_admits(self):
        ctx = fx.mark_done_map_child_ctx()
        report = cp.run_checks("mark_done", ctx, fx.mark_done_flags())
        self.assertEqual(find_check(report, "M-h")["result"], "PASS")
        self.assertEqual(report["verdict"], "ADMIT", report)

    def test_map_child_missing_handoff_refuses(self):
        ctx = fx.mark_done_map_child_ctx()
        ctx["issue"]["comments"]["nodes"] = [
            c for c in ctx["issue"]["comments"]["nodes"] if "[HANDOFF]" not in c["body"]
        ]
        report = cp.run_checks("mark_done", ctx, fx.mark_done_flags())
        self.assertEqual(find_check(report, "M-h")["result"], "FAIL")
        self.assertEqual(report["verdict"], "REFUSE")

    def test_map_child_missing_handoff_admits_with_handoff_file(self):
        ctx = fx.mark_done_map_child_ctx()
        ctx["issue"]["comments"]["nodes"] = [
            c for c in ctx["issue"]["comments"]["nodes"] if "[HANDOFF]" not in c["body"]
        ]
        report = cp.run_checks("mark_done", ctx, fx.mark_done_flags(handoff_file="/tmp/handoff.txt"))
        self.assertEqual(find_check(report, "M-h")["result"], "PASS")
        self.assertEqual(report["verdict"], "ADMIT", report)

    def test_full_variant_does_not_require_handoff(self):
        ctx = fx.mark_done_full_ctx()
        report = cp.run_checks("mark_done", ctx, fx.mark_done_flags())
        self.assertEqual(find_check(report, "M-h")["result"], "SKIP")

    def test_idempotent_already_done_skips_handoff(self):
        ctx = fx.mark_done_map_child_ctx()
        ctx["issue"]["state"] = {"name": "Done", "type": "completed"}
        ctx["issue"]["comments"]["nodes"] = [
            c for c in ctx["issue"]["comments"]["nodes"] if "[HANDOFF]" not in c["body"]
        ]
        report = cp.run_checks("mark_done", ctx, fx.mark_done_flags())
        self.assertEqual(find_check(report, "M-h")["result"], "SKIP")


# ======================================================================
# begin
# ======================================================================

class BeginTests(unittest.TestCase):
    """begin is Planning -> In Progress: the second leg of the vertical-
    slice lifecycle. It never inspects labels — both old-labeled and
    label-less tickets must behave identically."""

    def test_planning_with_plan_attested_admits(self):
        ctx = fx.begin_ctx()
        report = cp.run_checks("begin", ctx, fx.begin_flags(plan_attested=True))
        self.assertEqual(report["verdict"], "ADMIT", report)
        self.assertEqual(find_check(report, "BG1")["result"], "PASS")
        self.assertEqual(find_check(report, "BG2")["result"], "PASS")
        self.assertIn("BG2", report["ruled"])

    def test_planning_without_plan_attested_defers(self):
        ctx = fx.begin_ctx()
        report = cp.run_checks("begin", ctx, fx.begin_flags())
        self.assertEqual(report["verdict"], "JUDGMENT_REQUIRED", report)
        self.assertEqual(find_check(report, "BG2")["result"], "DEFER")
        item = find_judgment_item(report, "J-BG2")
        self.assertIsNone(item["evidence"])

    def test_todo_state_refuses_forbidden_todo_to_in_progress_edge(self):
        # Structural half of the forbidden-edge guarantee: begin only ever
        # advances a Planning ticket — a Todo ticket can never reach
        # In Progress through begin (only through claim -> Planning first).
        ctx = fx.begin_ctx(state_name="Todo", state_type="unstarted")
        report = cp.run_checks("begin", ctx, fx.begin_flags(plan_attested=True))
        self.assertEqual(find_check(report, "BG1")["result"], "FAIL")
        self.assertEqual(find_check(report, "BG2")["result"], "SKIP")
        self.assertEqual(report["verdict"], "REFUSE")

    def test_in_progress_state_refuses(self):
        ctx = fx.begin_ctx(state_name="In Progress", state_type="started")
        report = cp.run_checks("begin", ctx, fx.begin_flags(plan_attested=True))
        self.assertEqual(find_check(report, "BG1")["result"], "FAIL")
        self.assertEqual(report["verdict"], "REFUSE")

    def test_label_less_planning_ticket_admits_identically(self):
        ctx = fx.begin_ctx(labels=[])
        report = cp.run_checks("begin", ctx, fx.begin_flags(plan_attested=True))
        self.assertEqual(report["verdict"], "ADMIT", report)

    def test_old_labeled_planning_ticket_admits_identically(self):
        ctx = fx.begin_ctx(labels=["research"])
        report = cp.run_checks("begin", ctx, fx.begin_flags(plan_attested=True))
        self.assertEqual(report["verdict"], "ADMIT", report)


# ======================================================================
# vertical-slice edge-walk (Slice A Done When): every allowed + forbidden
# edge, each twice — once old-labeled, once label-less — plus a
# build-shape case proving the kept build branch is untouched.
# ======================================================================

class VerticalSliceEdgeWalkTests(unittest.TestCase):
    """Todo -> [claim] -> Planning -> [begin] -> In Progress -> [mark_done]
    -> Done, plus park/block/cancel/un-park and the two forbidden edges
    (Todo->In-Progress, Planning->Done). Brick 2's compatibility window
    requires an old-labeled and a label-less ticket to pass every gate
    identically. Planning->In-Progress via begin (both shapes) is covered
    in BeginTests just above."""

    # ---- allowed: Todo -> Planning via claim ----

    def test_claim_todo_map_child_old_labeled_targets_planning(self):
        ctx = fx.map_child_slice_ctx(labels=["task"])
        report = cp.run_checks("claim", ctx, fx.claim_flags())
        self.assertEqual(report["verdict"], "ADMIT", report)
        self.assertEqual(report["facts"]["variant"], "map-child")
        self.assertEqual(report["facts"]["claim_target_state_key"], "planning")

    def test_claim_todo_map_child_label_less_targets_planning(self):
        ctx = fx.map_child_slice_ctx(labels=[])
        report = cp.run_checks("claim", ctx, fx.claim_flags())
        self.assertEqual(report["verdict"], "ADMIT", report)
        self.assertEqual(report["facts"]["variant"], "map-child")
        self.assertEqual(report["facts"]["claim_target_state_key"], "planning")

    # ---- forbidden: Todo -> In-Progress. Structurally impossible for a
    # non-build map child — claim always retargets to Planning, never
    # straight to In Progress. ----

    def test_claim_never_targets_in_progress_for_non_build_map_child(self):
        for labels in (["task"], []):
            ctx = fx.map_child_slice_ctx(labels=labels)
            report = cp.run_checks("claim", ctx, fx.claim_flags())
            self.assertNotEqual(report["facts"]["claim_target_state_key"], "in_progress", f"labels={labels}")

    # ---- §8 finding 4c: an --operator-directed re-claim of a non-Todo map
    # child preserves its current state, never demotes Planning-ward ----

    def test_operator_directed_reclaim_of_in_progress_map_child_preserves_state(self):
        for labels in (["task"], []):
            ctx = fx.map_child_slice_ctx(labels=labels, state_name="In Progress", state_type="started")
            report = cp.run_checks("claim", ctx, fx.claim_flags(operator_directed=True))
            self.assertEqual(report["facts"]["claim_target_state_key"], "in_progress", f"labels={labels}")

    def test_operator_directed_reclaim_of_planning_map_child_preserves_planning(self):
        for labels in (["task"], []):
            ctx = fx.map_child_slice_ctx(labels=labels, state_name="Planning", state_type="started")
            report = cp.run_checks("claim", ctx, fx.claim_flags(operator_directed=True))
            self.assertEqual(report["facts"]["claim_target_state_key"], "planning", f"labels={labels}")

    def test_operator_directed_reclaim_of_blocked_or_parked_targets_planning_not_in_progress(self):
        # GAP 1 (deliverable-check): a Blocked / Needs-Input map child
        # re-claimed under --operator-directed must NOT route straight to In
        # Progress — that would reach In Progress without begin/BG2, bypassing
        # the plan-attack gate. The hardened guard routes every non-In-Progress
        # map-child state to Planning (re-plan), so no claim path silently
        # bypasses `begin`. (Replaces the old state_ids-dependent fallback that
        # sent Blocked -> in_progress.)
        for state_name, state_type in (("Blocked", "backlog"), ("Needs Input", "started")):
            for labels in (["task"], []):
                ctx = fx.map_child_slice_ctx(labels=labels, state_name=state_name, state_type=state_type)
                report = cp.run_checks("claim", ctx, fx.claim_flags(operator_directed=True))
                self.assertEqual(
                    report["facts"]["claim_target_state_key"], "planning",
                    f"{state_name}/{labels} must target Planning, never bypass begin",
                )

    # ---- allowed: In Progress -> Done via mark_done ----

    def test_mark_done_map_child_old_labeled_admits(self):
        ctx = fx.mark_done_map_child_ctx(labels=["task"])
        report = cp.run_checks("mark_done", ctx, fx.mark_done_flags())
        self.assertEqual(report["verdict"], "ADMIT", report)

    def test_mark_done_map_child_label_less_admits(self):
        ctx = fx.mark_done_map_child_ctx(labels=[])
        report = cp.run_checks("mark_done", ctx, fx.mark_done_flags())
        self.assertEqual(report["verdict"], "ADMIT", report)

    # ---- forbidden: Planning -> Done via mark_done ----

    def test_mark_done_refuses_planning_state_old_labeled(self):
        ctx = fx.mark_done_map_child_ctx(labels=["task"])
        ctx["issue"]["state"] = {"name": "Planning", "type": "started"}
        report = cp.run_checks("mark_done", ctx, fx.mark_done_flags())
        self.assertEqual(report["verdict"], "REFUSE")
        self.assertEqual(find_check(report, "M2")["result"], "FAIL")

    def test_mark_done_refuses_planning_state_label_less(self):
        ctx = fx.mark_done_map_child_ctx(labels=[])
        ctx["issue"]["state"] = {"name": "Planning", "type": "started"}
        report = cp.run_checks("mark_done", ctx, fx.mark_done_flags())
        self.assertEqual(report["verdict"], "REFUSE")
        self.assertEqual(find_check(report, "M2")["result"], "FAIL")

    # ---- allowed: park / block / cancel / un-park — always label-agnostic,
    # both shapes must admit identically ----

    def test_park_old_labeled_and_label_less_both_admit(self):
        for labels in ({"nodes": [{"name": "task"}]}, {"nodes": []}):
            ctx = fx.park_ctx()
            ctx["issue"]["labels"] = labels
            report = cp.run_checks("park", ctx, {})
            self.assertEqual(report["verdict"], "ADMIT", f"labels={labels}")

    def test_block_old_labeled_and_label_less_both_admit(self):
        for labels in ({"nodes": [{"name": "task"}]}, {"nodes": []}):
            ctx = fx.block_ctx()
            ctx["issue"]["labels"] = labels
            report = cp.run_checks("block", ctx, {})
            self.assertEqual(report["verdict"], "ADMIT", f"labels={labels}")

    def test_cancel_old_labeled_and_label_less_both_admit(self):
        for labels in ({"nodes": [{"name": "task"}]}, {"nodes": []}):
            ctx = fx.cancel_ctx()
            ctx["issue"]["labels"] = labels
            report = cp.run_checks("cancel", ctx, {})
            self.assertEqual(report["verdict"], "ADMIT", f"labels={labels}")

    def test_unpark_old_labeled_and_label_less_both_admit(self):
        for labels in ({"nodes": [{"name": "task"}]}, {"nodes": []}):
            ctx = fx.unpark_ctx()
            ctx["issue"]["labels"] = labels
            report = cp.run_checks("un-park", ctx, fx.unpark_flags(operator_directed=True))
            self.assertEqual(report["verdict"], "ADMIT", f"labels={labels}")

    # ---- Build variant removed: a build child is a map-child variant now —
    # claim admits it (to Planning), and mark_done closes it like any map
    # child, with a [HANDOFF]. ----

    def test_build_shape_mark_done_admits_with_handoff(self):
        ctx = fx.mark_done_build_ctx()
        report = cp.run_checks("mark_done", ctx, fx.mark_done_flags())
        self.assertEqual(report["verdict"], "ADMIT", report)


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
        for cid in ("CM1", "CM3", "CM6"):
            self.assertEqual(find_check(report, cid)["result"], "PASS", cid)
        self.assertNotIn("charter_document_id", report["facts"])
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

    def test_cm_a_aggregates_multiple_step1_failures_no_partial_refusal(self):
        ctx = fx.close_map_ctx()
        ctx["issue"]["state"] = {"name": "Todo", "type": "unstarted"}  # CM1 fails
        ctx["children"].append({"id": "child-3", "identifier": "ACR-4", "title": "Still open",
                                 "state": {"name": "In Progress", "type": "started"}, "labels": {"nodes": []}, "delegate": None})  # CM3 fails
        report = cp.run_checks("close-map", ctx, {})
        self.assertEqual(find_check(report, "CM1")["result"], "FAIL")
        self.assertEqual(find_check(report, "CM3")["result"], "FAIL")
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

    def test_cm3_duplicate_state_type_counts_as_closed(self):
        # §8 finding 6b: the live Duplicate state is type "duplicate", not
        # "canceled" — without the fold-in a Duplicate child would block
        # CM3 forever.
        ctx = fx.close_map_ctx()
        ctx["children"].append({
            "id": "child-dup", "identifier": "ACR-7", "title": "Duplicate of another slice",
            "state": {"name": "Duplicate", "type": "duplicate"}, "delegate": None,
            "labels": {"nodes": []},
        })
        report = cp.run_checks("close-map", ctx, {})
        self.assertEqual(find_check(report, "CM3")["result"], "PASS", find_check(report, "CM3"))
        self.assertEqual(report["facts"]["open_children"], [])


class CloseMapReverifyTests(unittest.TestCase):
    """CM9's scripted re-verify path — cone_preflight.py close-map
    --reverify. Modeled on a post-execute fetch: the accounting document
    now exists on the map (not archived). Any drift on the close gates
    (CM1/CM3/CM6) or the accounting-doc check refuses instead of
    writing Done."""

    def _post_execute_ctx(self, **overrides):
        ctx = fx.close_map_ctx()
        # The accounting document the execute step's step 3 just created.
        ctx["documents"].append({
            "id": "accounting-doc-1", "title": "Accounting — The Map",
            "archivedAt": None, "content": "Accounting body.",
        })
        ctx.update(overrides)
        return ctx

    def test_admits_when_all_close_gates_hold(self):
        ctx = self._post_execute_ctx()
        report = cp.run_close_map_reverify(ctx, "accounting-doc-1")
        self.assertEqual(report["verdict"], "ADMIT", report)
        cm9 = find_check(report, "CM9")
        self.assertEqual(cm9["result"], "PASS")
        # CM1/CM3/CM6 re-run fresh as part of the reverify. CM4 is
        # not a registered check.
        for cid in ("CM1", "CM3", "CM6"):
            self.assertEqual(find_check(report, cid)["result"], "PASS", cid)
        with self.assertRaises(AssertionError):
            find_check(report, "CM4")

    def test_refuses_when_accounting_document_missing(self):
        ctx = self._post_execute_ctx()
        ctx["documents"] = [d for d in ctx["documents"] if d["id"] != "accounting-doc-1"]
        report = cp.run_close_map_reverify(ctx, "accounting-doc-1")
        self.assertEqual(report["verdict"], "REFUSE")
        cm9 = find_check(report, "CM9")
        self.assertEqual(cm9["result"], "FAIL")
        self.assertIn("accounting-doc-1", cm9["detail"])
        self.assertIn("not found", cm9["detail"])

    def test_refuses_when_a_base_gate_regressed_between_admit_and_execute(self):
        """A child reopened (or a challenge landed) between the original
        ADMIT and the execute step — the close-gate re-verify must catch it,
        not just the accounting artifact."""
        ctx = self._post_execute_ctx()
        ctx["children"].append({
            "id": "child-3", "identifier": "ACR-4", "title": "Reopened mid-flight",
            "state": {"name": "In Progress", "type": "started"}, "labels": {"nodes": []}, "delegate": None,
        })
        report = cp.run_close_map_reverify(ctx, "accounting-doc-1")
        self.assertEqual(report["verdict"], "REFUSE")
        self.assertEqual(find_check(report, "CM3")["result"], "FAIL")
        cm9 = find_check(report, "CM9")
        self.assertEqual(cm9["result"], "FAIL")
        self.assertIn("ACR-4", cm9["detail"])

    def test_refuses_when_accounting_id_not_supplied(self):
        ctx = self._post_execute_ctx()
        report = cp.run_close_map_reverify(ctx, None)
        self.assertEqual(report["verdict"], "REFUSE")
        cm9 = find_check(report, "CM9")
        self.assertIn("no accounting_document_id", cm9["detail"])

    def test_cli_reverify_flag_only_valid_for_close_map(self):
        with self.assertRaises(SystemExit):
            cp.main(["claim", "ACR-1", "--reverify"])

    def test_cli_reverify_end_to_end_through_stub_bridge(self):
        """Exercises the actual CLI wiring: cone_preflight.py close-map
        <map_id> --reverify --accounting-document-id ... — the shape the
        rewritten close-map.md card's Step 5 invokes."""
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
                {"id": "accounting-doc-1", "title": "Accounting", "archivedAt": None, "content": "Accounting body."},
            ]}}}}, "returncode": 0},  # fetch_documents on the map
        ]
        tlb.script_responses(responses)

        exit_code = cp.main([
            "close-map", "ACR-1", "--reverify",
            "--accounting-document-id", "accounting-doc-1",
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
        "claim": {"C1", "C2", "C3", "C5", "C5b", "C6", "C7", "C8", "C9", "C10", "C11", "C12"},
        "mark_done": {"M1", "M2", "M3a", "M3b", "M3c", "M3d", "M3e", "M3f", "M4", "M-i", "M-d", "M-o", "M3g", "M-h"},
        "begin": {"BG1", "BG2"},
        "park": {"P1", "P2"},
        "block": {"B1", "B2"},
        "un-park": {"U1", "U2"},
        "cancel": {"X1"},
        "close-map": {"CM1", "CM3", "CM-a", "CM6", "CM7", "CM9"},
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
        """C10/C11/M4/R4/P2/B2/CM9 live in linear_bridge.py's mutation
        subcommands, not in cone_preflight's own runtime checks (which never
        mutates) — confirmed absent from a representative ADMIT run."""
        execution_only = {
            "claim": {"C10", "C11"},
            "mark_done": {"M4"},
            "park": {"P2"},
            "block": {"B2"},
            "close-map": {"CM9"},
        }
        fixtures = {
            "claim": (fx.claim_full_ctx(), fx.claim_flags()),
            "mark_done": (fx.mark_done_full_ctx(), fx.mark_done_flags()),
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

    def test_mark_done_map_child_handoff_posts_before_state(self):
        # GAP 2 (deliverable-check): M-h's [HANDOFF]-before-Done sequencing
        # law needs a runtime witness — a reorder to set_state-before-comment
        # in _execute_mark_done would otherwise pass every check-level test.
        # Mirrors the park sequencing E2E. Label-less map child also exercises
        # the compatibility window through the full execute path.
        issue_node = _e2e_issue_node(
            identifier="ACR-70", id="uuid-md-handoff",
            state={"name": "In Progress", "type": "started"},
            parent=fx.map_parent(),
            labels={"nodes": []},
            description=fx.BASE_OBJECTIVE + "## Done When\nValidation mandate: conformance\n\n" + fx.BASE_CTX,
            comments={"nodes": [
                {"id": "c1", "body": "[VALIDATION] — conformance\nVerdict: CONFIRMED\nIntent: it works\nSpecifics: ran the suite",
                 "createdAt": "2026-02-01T12:00:00Z", "user": {"id": "viewer-1"}},
            ]},
            history={"nodes": [
                {"createdAt": "2026-01-30T09:00:00Z", "fromState": {"name": "Todo", "type": "unstarted"},
                 "toState": {"name": "In Progress", "type": "started"}},
            ]},
        )
        log_path = tlb.script_log()
        tlb.script_responses([
            _issue_resp(issue_node),
            _viewer_resp("viewer-1"),
            _states_resp([("Done", "state-done", "completed"), ("Needs Input", "state-ni", "triage")]),
            _issue_resp({**fx.map_parent(), "comments": {"nodes": []}}),  # map-child parent-comments fetch
            _comment_create_resp("c-handoff-1"),                          # execute: post [HANDOFF] ...
            _comments_readback_resp([{"id": "c-handoff-1", "body": "[HANDOFF] next: slice B."}]),  # ... read-back
            _mutation_ok_resp(),                                          # execute: set-state Done ...
            _set_state_readback_resp("uuid-md-handoff", "state-done", "Done", "completed"),  # ... read-back
        ])

        def run(path):
            return _run_main_capture([
                "mark_done", "ACR-70", "--execute-if-clean", "--handoff-file", path,
                "--bridge-cmd", " ".join(tlb.STUB_CMD),
            ])

        code, out = _with_comment_file("[HANDOFF] next: slice B.", run)
        self.assertEqual(code, lb.EXIT_OK)
        self.assertEqual(out["verdict"], "ADMIT", out)
        self.assertTrue(out["executed"])
        self.assertTrue(out["result"]["handoff_comment"]["verified"])
        self.assertTrue(out["result"]["set_state"]["verified"])
        # Sequencing law: the [HANDOFF] comment posts BEFORE the Done state
        # change — commentCreate must precede the stateId-bearing issueUpdate.
        queries = tlb.read_log(log_path)
        comment_idx = next(i for i, q in enumerate(queries) if "commentCreate" in q)
        state_idx = next(i for i, q in enumerate(queries) if "stateId" in q and "issueUpdate" in q)
        self.assertLess(comment_idx, state_idx, "[HANDOFF]-before-Done sequencing law violated")

    def test_begin_admit_executed(self):
        issue_node = _e2e_issue_node(
            identifier="ACR-65", id="uuid-begin-e2e",
            state={"name": "Planning", "type": "started"},
            parent=fx.map_parent(),
        )
        tlb.script_responses([
            _issue_resp(issue_node),
            _viewer_resp("viewer-1"),
            _states_resp([("In Progress", "state-ip", "started")]),
            _mutation_ok_resp(),
            _set_state_readback_resp("uuid-begin-e2e", "state-ip", "In Progress", "started"),
        ])
        code, out = _run_main_capture([
            "begin", "ACR-65", "--plan-attested", "--execute-if-clean", "--bridge-cmd", " ".join(tlb.STUB_CMD),
        ])
        self.assertEqual(code, lb.EXIT_OK)
        self.assertEqual(out["verdict"], "ADMIT")
        self.assertTrue(out["executed"])
        self.assertTrue(out["result"]["set_state"]["verified"])
        self.assertIn("BG2", out["ruled"])

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

    def test_begin_defers_not_executed(self):
        issue_node = _e2e_issue_node(
            identifier="ACR-84", id="uuid-begin-defer",
            state={"name": "Planning", "type": "started"},
            parent=fx.map_parent(),
        )
        counter = tlb.script_responses([
            _issue_resp(issue_node),
            _viewer_resp("viewer-1"),
            _states_resp([("In Progress", "state-ip", "started")]),
        ])
        code, out = _run_main_capture([
            "begin", "ACR-84", "--execute-if-clean", "--bridge-cmd", " ".join(tlb.STUB_CMD),
        ])
        self.assertEqual(code, lb.EXIT_OK)
        self.assertEqual(out["verdict"], "JUDGMENT_REQUIRED")
        self.assertFalse(out["executed"])
        self.assertEqual(tlb.call_count(counter), 3, "BG2's default defer makes zero mutation calls")


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

    def test_begin_refuses_not_executed(self):
        # state is Todo, not Planning -> BG1 guard fails (the forbidden
        # Todo->In-Progress edge).
        issue_node = _e2e_issue_node(identifier="ACR-78", id="uuid-begin-refuse")
        counter = tlb.script_responses([
            _issue_resp(issue_node),
            _viewer_resp("viewer-1"),
            _states_resp([("In Progress", "state-ip", "started")]),
        ])
        code, out = _run_main_capture([
            "begin", "ACR-78", "--plan-attested", "--execute-if-clean", "--bridge-cmd", " ".join(tlb.STUB_CMD),
        ])
        self.assertEqual(code, lb.EXIT_OK)
        self.assertEqual(out["verdict"], "REFUSE")
        self.assertFalse(out["executed"])
        self.assertEqual(tlb.call_count(counter), 3)

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
