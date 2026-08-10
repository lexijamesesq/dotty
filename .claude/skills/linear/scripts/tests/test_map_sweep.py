#!/usr/bin/env python3
"""
Unit tests for map_sweep.py.

Two layers, matching the module's own split:
  - ComputeSweepTests — the detection logic (compute_sweep, a pure function)
    against hand-built ctx fixtures (map_sweep_fixtures.py), fictional
    ACR-* identifiers throughout. Per detection class: one fixture where it
    fires, one where it's absent. Plus a healthy-map fixture (all-empty
    detection arrays + ordered frontier + frontier_rule asserted), an
    ending_due fixture (including the charter_state gate — the premature
    map-close-dispatch case the gate exists to prevent), a wedged fixture,
    and a mixed-priority comparator fixture (including a None-priority
    ticket, asserting None sorts last).
  - GatherContextStubBridgeTests / CLI tests — the live-fetch wiring and
    the `main()` dispatch, via the same stub_bridge.py replay mechanism
    test_linear_bridge.py uses (never a network call).
"""
import copy
import json
import os
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
import map_sweep  # noqa: E402
import linear_bridge as lb  # noqa: E402

from tests import map_sweep_fixtures as f  # noqa: E402

STUB_BRIDGE = os.path.join(os.path.dirname(os.path.abspath(__file__)), "fixtures", "stub_bridge.py")
STUB_CMD = [sys.executable, STUB_BRIDGE]

NOW = "2026-02-10T00:00:00Z"


def script_responses(responses):
    fd, counter_path = tempfile.mkstemp(prefix="stub-counter-")
    os.close(fd)
    os.unlink(counter_path)
    os.environ["STUB_BRIDGE_RESPONSES"] = json.dumps(responses)
    os.environ["STUB_BRIDGE_COUNTER_FILE"] = counter_path
    return counter_path


def call_count(counter_path):
    if not os.path.exists(counter_path):
        return 0
    with open(counter_path) as fh:
        return int(fh.read().strip() or "0")


# ---------------------------------------------------------------------
# ComputeSweepTests — detection logic, pure function
# ---------------------------------------------------------------------

class FrontierComparatorTests(unittest.TestCase):
    def test_mixed_priority_none_sorts_last_tie_break_by_created_at(self):
        children = [
            f.child("ACR-10", priority=2, created_at="2026-01-02T00:00:00Z"),
            f.child("ACR-11", priority=1, created_at="2026-01-03T00:00:00Z"),
            f.child("ACR-12", priority=None, created_at="2026-01-01T00:00:00Z"),
            f.child("ACR-13", priority=4, created_at="2026-01-04T00:00:00Z"),
            f.child("ACR-14", priority=0, created_at="2026-01-05T00:00:00Z"),
            # tie on priority 1 with ACR-11, but created earlier -> sorts first among ties
            f.child("ACR-15", priority=1, created_at="2026-01-01T12:00:00Z"),
        ]
        ctx = f.base_ctx(children=children)
        report = map_sweep.compute_sweep(ctx, stale_days=7, now=NOW)
        order = [t["identifier"] for t in report["frontier"]]
        self.assertEqual(order, ["ACR-15", "ACR-11", "ACR-10", "ACR-13", "ACR-12", "ACR-14"])
        self.assertIn("frontier_rule", report)
        self.assertTrue(report["frontier_rule"])

    def test_frontier_excludes_blocked_delegated_assigned_and_non_todo(self):
        children = [
            f.child("ACR-20", state_name="Todo", state_type="unstarted"),  # takeable
            f.child("ACR-21", state_name="In Progress", state_type="started"),  # not Todo
            f.child("ACR-22", delegate="viewer-1"),  # claimed
            f.child("ACR-23", assignee="operator-1"),  # assigned
            f.child("ACR-24", blocked_by_open=[{"identifier": "ACR-9"}]),  # blocked
        ]
        ctx = f.base_ctx(children=children)
        report = map_sweep.compute_sweep(ctx, stale_days=7, now=NOW)
        self.assertEqual([t["identifier"] for t in report["frontier"]], ["ACR-20"])


class MapAndChildrenShapeTests(unittest.TestCase):
    def test_body_sections_present_full(self):
        ctx = f.base_ctx()
        report = map_sweep.compute_sweep(ctx, now=NOW)
        self.assertEqual(
            report["map"]["body_sections_present"],
            ["Destination", "Notes", "Decisions so far", "Not yet specified", "Out of scope"],
        )
        self.assertEqual(report["map"]["identifier"], "ACR-1")
        self.assertEqual(report["map"]["uuid"], "map-uuid-1")

    def test_body_sections_present_partial(self):
        body = "## Destination\n\nShip it.\n\n## Notes\n\nNone.\n"
        ctx = f.base_ctx(map_issue=f.map_issue(description=body))
        report = map_sweep.compute_sweep(ctx, now=NOW)
        self.assertEqual(report["map"]["body_sections_present"], ["Destination", "Notes"])

    def test_children_shape_labels_and_sets(self):
        children = [
            f.child("ACR-30", labels=["research", "afk"], delegate="viewer-1"),
            f.child("ACR-31", labels=["build"], assignee="operator-1"),
            f.child("ACR-32", labels=[]),  # malformed — no type label
        ]
        ctx = f.base_ctx(children=children)
        report = map_sweep.compute_sweep(ctx, now=NOW)
        by_id = {c["identifier"]: c for c in report["children"]}
        self.assertEqual(by_id["ACR-30"]["type_label"], "research")
        self.assertEqual(by_id["ACR-30"]["loop_label"], "afk")
        self.assertTrue(by_id["ACR-30"]["delegate_set"])
        self.assertFalse(by_id["ACR-30"]["assignee_set"])
        self.assertEqual(by_id["ACR-31"]["type_label"], "build")
        self.assertTrue(by_id["ACR-31"]["assignee_set"])
        self.assertEqual(by_id["ACR-32"]["type_label"], "none")
        self.assertIsNone(by_id["ACR-32"]["loop_label"])


class OpenChallengesTests(unittest.TestCase):
    def test_present_when_no_later_resolved(self):
        comments = [f.comment("c1", "[CHALLENGE] the calibration claim looks stale", "2026-02-01T00:00:00Z")]
        ctx = f.base_ctx(map_issue=f.map_issue(comments=comments))
        report = map_sweep.compute_sweep(ctx, now=NOW)
        self.assertEqual(len(report["open_challenges"]), 1)
        self.assertEqual(report["open_challenges"][0]["comment_id"], "c1")
        self.assertIn("calibration", report["open_challenges"][0]["excerpt"])

    def test_absent_when_later_resolved_reply_exists(self):
        comments = [
            f.comment("c1", "[CHALLENGE] the calibration claim looks stale", "2026-02-01T00:00:00Z"),
            f.comment("c2", "[CHALLENGE-RESOLVED] operator confirmed it holds", "2026-02-02T00:00:00Z"),
        ]
        ctx = f.base_ctx(map_issue=f.map_issue(comments=comments))
        report = map_sweep.compute_sweep(ctx, now=NOW)
        self.assertEqual(report["open_challenges"], [])


class OrphanedResearchTests(unittest.TestCase):
    def test_present_when_open_research_has_doc_and_resolution_comment(self):
        c = f.child("ACR-40", labels=["research", "afk"], state_name="In Progress", state_type="started")
        ctx = f.base_ctx(
            children=[c],
            child_documents={"uuid-ACR-40": [{"id": "doc-1", "title": "Findings"}]},
            child_comments={"uuid-ACR-40": [f.comment("rc1", "Resolution: findings attached.", "2026-02-01T00:00:00Z")]},
        )
        report = map_sweep.compute_sweep(ctx, now=NOW)
        self.assertEqual(len(report["orphaned_research"]), 1)
        entry = report["orphaned_research"][0]
        self.assertEqual(entry["identifier"], "ACR-40")
        self.assertEqual(entry["findings_doc_id"], "doc-1")
        self.assertEqual(entry["resolution_comment_id"], "rc1")

    def test_absent_when_missing_resolution_comment(self):
        c = f.child("ACR-41", labels=["research", "afk"], state_name="In Progress", state_type="started")
        ctx = f.base_ctx(
            children=[c],
            child_documents={"uuid-ACR-41": [{"id": "doc-1", "title": "Findings"}]},
            child_comments={"uuid-ACR-41": []},
        )
        report = map_sweep.compute_sweep(ctx, now=NOW)
        self.assertEqual(report["orphaned_research"], [])

    def test_absent_when_ticket_is_closed(self):
        c = f.child("ACR-42", labels=["research", "afk"], state_name="Done", state_type="completed",
                     completed_at="2026-01-05T00:00:00Z")
        ctx = f.base_ctx(
            children=[c],
            child_documents={"uuid-ACR-42": [{"id": "doc-1", "title": "Findings"}]},
            child_comments={"uuid-ACR-42": [f.comment("rc1", "Resolution: done.", "2026-01-05T00:00:00Z")]},
        )
        report = map_sweep.compute_sweep(ctx, now=NOW)
        self.assertEqual(report["orphaned_research"], [])


class ParkedBlockedTests(unittest.TestCase):
    def test_parked_present_with_ask_excerpt(self):
        c = f.child("ACR-50", state_name="Needs Input", state_type="backlog")
        ctx = f.base_ctx(
            children=[c],
            child_comments={"uuid-ACR-50": [f.comment("c1", "Need a decision on X.", "2026-02-01T00:00:00Z")]},
        )
        report = map_sweep.compute_sweep(ctx, now=NOW)
        self.assertEqual(len(report["parked"]), 1)
        self.assertEqual(report["parked"][0]["identifier"], "ACR-50")
        self.assertIn("decision", report["parked"][0]["ask_excerpt"])
        self.assertEqual(report["blocked"], [])

    def test_parked_absent_when_no_needs_input_children(self):
        c = f.child("ACR-51", state_name="Todo", state_type="unstarted")
        ctx = f.base_ctx(children=[c])
        report = map_sweep.compute_sweep(ctx, now=NOW)
        self.assertEqual(report["parked"], [])

    def test_blocked_present_with_condition_excerpt(self):
        c = f.child("ACR-52", state_name="Blocked", state_type="backlog")
        ctx = f.base_ctx(
            children=[c],
            child_comments={"uuid-ACR-52": [f.comment("c1", "Blocked on PR #482 merging.", "2026-02-01T00:00:00Z")]},
        )
        report = map_sweep.compute_sweep(ctx, now=NOW)
        self.assertEqual(len(report["blocked"]), 1)
        self.assertEqual(report["blocked"][0]["identifier"], "ACR-52")
        self.assertIn("PR #482", report["blocked"][0]["condition_excerpt"])
        self.assertEqual(report["parked"], [])

    def test_blocked_absent_when_no_blocked_children(self):
        c = f.child("ACR-53", state_name="Todo", state_type="unstarted")
        ctx = f.base_ctx(children=[c])
        report = map_sweep.compute_sweep(ctx, now=NOW)
        self.assertEqual(report["blocked"], [])


class StaleClaimsTests(unittest.TestCase):
    def test_present_when_delegated_and_quiet_past_threshold(self):
        c = f.child("ACR-60", delegate="viewer-1", updated_at="2026-01-25T00:00:00Z")  # 16 days before NOW
        ctx = f.base_ctx(children=[c])
        report = map_sweep.compute_sweep(ctx, stale_days=7, now=NOW)
        self.assertEqual(len(report["stale_claims"]), 1)
        self.assertEqual(report["stale_claims"][0]["identifier"], "ACR-60")
        self.assertGreaterEqual(report["stale_claims"][0]["days_stale"], 7)

    def test_absent_when_recently_active(self):
        c = f.child("ACR-61", delegate="viewer-1", updated_at="2026-02-09T00:00:00Z")  # 1 day before NOW
        ctx = f.base_ctx(children=[c])
        report = map_sweep.compute_sweep(ctx, stale_days=7, now=NOW)
        self.assertEqual(report["stale_claims"], [])

    def test_absent_when_unclaimed(self):
        c = f.child("ACR-62", delegate=None, updated_at="2026-01-01T00:00:00Z")
        ctx = f.base_ctx(children=[c])
        report = map_sweep.compute_sweep(ctx, stale_days=7, now=NOW)
        self.assertEqual(report["stale_claims"], [])


class DecisionsMissingTests(unittest.TestCase):
    def test_present_when_identifier_not_in_decisions_section(self):
        c = f.child("ACR-70", state_name="Done", state_type="completed", completed_at="2026-01-05T00:00:00Z")
        ctx = f.base_ctx(
            children=[c],
            child_comments={"uuid-ACR-70": [f.comment("rc1", "Resolution: chose approach B.", "2026-01-05T00:00:00Z")]},
        )
        report = map_sweep.compute_sweep(ctx, now=NOW)
        self.assertEqual(len(report["decisions_missing"]), 1)
        entry = report["decisions_missing"][0]
        self.assertEqual(entry["identifier"], "ACR-70")
        self.assertEqual(entry["resolution_comment_text"], "Resolution: chose approach B.")

    def test_absent_when_identifier_already_linked_in_body(self):
        # DEFAULT_MAP_BODY's Decisions-so-far links https://.../issue/ACR-2/... — the
        # identifier ACR-2 is embedded in the URL, satisfying detection without a
        # literal id mention in the visible link text.
        c = f.child("ACR-2", state_name="Done", state_type="completed", completed_at="2026-01-02T00:00:00Z")
        ctx = f.base_ctx(children=[c])
        report = map_sweep.compute_sweep(ctx, now=NOW)
        self.assertEqual(report["decisions_missing"], [])

    def test_absent_when_ticket_still_open(self):
        c = f.child("ACR-71", state_name="Todo", state_type="unstarted")
        ctx = f.base_ctx(children=[c])
        report = map_sweep.compute_sweep(ctx, now=NOW)
        self.assertEqual(report["decisions_missing"], [])


class LastResolvedTests(unittest.TestCase):
    def test_none_when_no_done_children(self):
        ctx = f.base_ctx(children=[f.child("ACR-80", state_name="Todo", state_type="unstarted")])
        report = map_sweep.compute_sweep(ctx, now=NOW)
        self.assertIsNone(report["last_resolved"])

    def test_handoff_present_and_text_captured(self):
        c = f.child("ACR-81", state_name="Done", state_type="completed", completed_at="2026-01-05T00:00:00Z")
        ctx = f.base_ctx(
            children=[c],
            child_comments={"uuid-ACR-81": [
                f.comment("rc1", "Resolution: chose approach B.", "2026-01-05T00:00:00Z"),
                f.comment("hc1", "[HANDOFF] Next: pick up ACR-82. Carry-forward: watch the API rate limit.", "2026-01-05T00:05:00Z"),
            ]},
        )
        report = map_sweep.compute_sweep(ctx, now=NOW)
        self.assertEqual(report["last_resolved"]["identifier"], "ACR-81")
        self.assertTrue(report["last_resolved"]["handoff"]["present"])
        self.assertIn("ACR-82", report["last_resolved"]["handoff"]["text"])

    def test_handoff_absent_when_no_handoff_comment(self):
        c = f.child("ACR-82", state_name="Done", state_type="completed", completed_at="2026-01-05T00:00:00Z")
        ctx = f.base_ctx(
            children=[c],
            child_comments={"uuid-ACR-82": [f.comment("rc1", "Resolution: chose approach B.", "2026-01-05T00:00:00Z")]},
        )
        report = map_sweep.compute_sweep(ctx, now=NOW)
        self.assertFalse(report["last_resolved"]["handoff"]["present"])
        self.assertIsNone(report["last_resolved"]["handoff"]["text"])

    def test_picks_max_completed_at_never_updated_at(self):
        # ACR-90 completed earlier but was TOUCHED later (a later comment bumped
        # updatedAt) — last_resolved must still pick ACR-91, the later completedAt.
        older_completed_but_recently_touched = f.child(
            "ACR-90", state_name="Done", state_type="completed",
            completed_at="2026-01-01T00:00:00Z", updated_at="2026-02-09T00:00:00Z",
        )
        newer_completed = f.child(
            "ACR-91", state_name="Done", state_type="completed",
            completed_at="2026-01-10T00:00:00Z", updated_at="2026-01-10T00:00:00Z",
        )
        ctx = f.base_ctx(
            children=[older_completed_but_recently_touched, newer_completed],
            child_comments={
                "uuid-ACR-90": [f.comment("rc1", "Resolution: A.", "2026-01-01T00:00:00Z")],
                "uuid-ACR-91": [f.comment("rc2", "Resolution: B.", "2026-01-10T00:00:00Z")],
            },
        )
        report = map_sweep.compute_sweep(ctx, now=NOW)
        self.assertEqual(report["last_resolved"]["identifier"], "ACR-91")


class CharterStateAndEndingDueTests(unittest.TestCase):
    def _closed_children(self):
        return [
            f.child("ACR-100", state_name="Done", state_type="completed", completed_at="2026-01-05T00:00:00Z"),
            f.child("ACR-101", state_name="Canceled", state_type="canceled", completed_at="2026-01-06T00:00:00Z"),
        ]

    def test_ending_due_true_when_frontier_empty_all_closed_and_charter_finalized(self):
        ctx = f.base_ctx(children=self._closed_children(), map_documents=[f.finalized_charter()])
        report = map_sweep.compute_sweep(ctx, now=NOW)
        self.assertEqual(report["charter_state"], "finalized")
        self.assertTrue(report["ending_due"])

    def test_ending_due_false_when_charter_absent(self):
        """The gate this test protects: without it, an empty frontier on an
        all-closed child set would mechanize a premature map-close dispatch
        at the decide->build transition, before a charter even exists."""
        ctx = f.base_ctx(children=self._closed_children(), map_documents=[])
        report = map_sweep.compute_sweep(ctx, now=NOW)
        self.assertEqual(report["charter_state"], "absent")
        self.assertFalse(report["ending_due"])

    def test_ending_due_false_when_charter_present_but_not_finalized(self):
        ctx = f.base_ctx(children=self._closed_children(), map_documents=[f.draft_charter()])
        report = map_sweep.compute_sweep(ctx, now=NOW)
        self.assertEqual(report["charter_state"], "present")
        self.assertFalse(report["ending_due"])

    def test_ending_due_false_when_frontier_not_empty(self):
        children = self._closed_children() + [f.child("ACR-102", state_name="Todo", state_type="unstarted")]
        ctx = f.base_ctx(children=children, map_documents=[f.finalized_charter()])
        report = map_sweep.compute_sweep(ctx, now=NOW)
        self.assertFalse(report["ending_due"])

    def test_charter_state_ignores_archived_documents(self):
        archived = f.finalized_charter(archivedAt="2026-01-06T00:00:00Z")
        ctx = f.base_ctx(children=self._closed_children(), map_documents=[archived])
        report = map_sweep.compute_sweep(ctx, now=NOW)
        self.assertEqual(report["charter_state"], "absent")


class WedgedTests(unittest.TestCase):
    def test_wedged_true_when_frontier_empty_with_parked_children(self):
        children = [f.child("ACR-110", state_name="Needs Input", state_type="backlog")]
        ctx = f.base_ctx(
            children=children,
            child_comments={"uuid-ACR-110": [f.comment("c1", "Need a call on scope.", "2026-02-01T00:00:00Z")]},
        )
        report = map_sweep.compute_sweep(ctx, now=NOW)
        self.assertTrue(report["wedged"]["bool"])
        self.assertIn("ACR-110", report["wedged"]["reason"])
        self.assertFalse(report["ending_due"], "parked children are not Done/Canceled — not an ending condition")

    def test_wedged_false_when_frontier_has_takeable_tickets(self):
        children = [
            f.child("ACR-111", state_name="Needs Input", state_type="backlog"),
            f.child("ACR-112", state_name="Todo", state_type="unstarted"),
        ]
        ctx = f.base_ctx(children=children)
        report = map_sweep.compute_sweep(ctx, now=NOW)
        self.assertFalse(report["wedged"]["bool"])
        self.assertIsNone(report["wedged"]["reason"])

    def test_wedged_false_when_map_empty_of_children(self):
        ctx = f.base_ctx(children=[])
        report = map_sweep.compute_sweep(ctx, now=NOW)
        self.assertFalse(report["wedged"]["bool"])
        self.assertFalse(report["ending_due"])


class HealthyMapFixtureTests(unittest.TestCase):
    """The ADMIT-analog: a well-formed map mid-flight. Every detection array
    empty, frontier ordered, frontier_rule asserted — proves the sweep
    doesn't fire false positives on ordinary, unremarkable state."""

    def test_healthy_map_all_empty_detection_arrays_ordered_frontier(self):
        done = f.child("ACR-2", state_name="Done", state_type="completed", completed_at="2026-01-02T00:00:00Z")
        frontier_a = f.child("ACR-120", priority=1, created_at="2026-01-03T00:00:00Z")
        frontier_b = f.child("ACR-121", priority=3, created_at="2026-01-04T00:00:00Z")
        in_progress = f.child("ACR-122", state_name="In Progress", state_type="started",
                               delegate="viewer-2", updated_at="2026-02-09T12:00:00Z")
        ctx = f.base_ctx(
            children=[done, frontier_a, frontier_b, in_progress],
            child_comments={"uuid-ACR-2": [f.comment("rc1", "Resolution: shipped.", "2026-01-02T00:00:00Z")]},
        )
        report = map_sweep.compute_sweep(ctx, stale_days=7, now=NOW)

        self.assertEqual(report["open_challenges"], [])
        self.assertEqual(report["orphaned_research"], [])
        self.assertEqual(report["parked"], [])
        self.assertEqual(report["blocked"], [])
        self.assertEqual(report["stale_claims"], [])
        self.assertEqual(report["decisions_missing"], [])
        self.assertFalse(report["wedged"]["bool"])
        self.assertFalse(report["ending_due"])
        self.assertEqual([t["identifier"] for t in report["frontier"]], ["ACR-120", "ACR-121"])
        self.assertEqual(report["frontier_rule"], map_sweep.FRONTIER_RULE)


# ---------------------------------------------------------------------
# GatherContextStubBridgeTests — live-fetch wiring, stub bridge
# ---------------------------------------------------------------------

class GatherContextStubBridgeTests(unittest.TestCase):
    def test_no_children_minimal_call_sequence(self):
        counter = script_responses([
            {"stdout": {"data": {"issue": {
                "id": "map-uuid-1", "identifier": "ACR-1", "title": "The Map",
                "state": {"name": "In Progress", "type": "started"},
                "description": f.DEFAULT_MAP_BODY,
                "comments": {"nodes": []},
            }}}, "returncode": 0},
            {"stdout": {"data": {"issue": {"documents": {"nodes": []}}}}, "returncode": 0},
            {"stdout": {"data": {"issues": {"nodes": [], "pageInfo": {"hasNextPage": False, "endCursor": None}}}}, "returncode": 0},
        ])
        ctx = map_sweep.gather_context(STUB_CMD, "ACR-1")
        self.assertEqual(ctx["map_issue"]["identifier"], "ACR-1")
        self.assertEqual(ctx["map_documents"], [])
        self.assertEqual(ctx["children"], [])
        self.assertEqual(ctx["child_comments"], {})
        self.assertEqual(ctx["child_documents"], {})
        self.assertEqual(call_count(counter), 3)

    def test_open_research_child_triggers_comment_and_document_fetch(self):
        child_node = {
            "id": "uuid-r1", "identifier": "ACR-40", "title": "Research angle",
            "state": {"name": "In Progress", "type": "started"},
            "labels": {"nodes": [{"name": "research"}, {"name": "afk"}]},
            "delegate": {"id": "viewer-1"}, "assignee": None,
            "priority": 2, "createdAt": "2026-01-01T00:00:00Z",
            "completedAt": None, "updatedAt": "2026-01-01T00:00:00Z",
            "inverseRelations": {"nodes": []},
        }
        counter = script_responses([
            {"stdout": {"data": {"issue": {
                "id": "map-uuid-1", "identifier": "ACR-1", "title": "The Map",
                "state": {"name": "In Progress", "type": "started"},
                "description": f.DEFAULT_MAP_BODY,
                "comments": {"nodes": []},
            }}}, "returncode": 0},
            {"stdout": {"data": {"issue": {"documents": {"nodes": []}}}}, "returncode": 0},
            {"stdout": {"data": {"issues": {"nodes": [child_node], "pageInfo": {"hasNextPage": False, "endCursor": None}}}}, "returncode": 0},
            # comment_fetch_ids loop: ACR-40's own comments
            {"stdout": {"data": {"issue": {
                "id": "uuid-r1", "identifier": "ACR-40", "title": "Research angle",
                "state": {"name": "In Progress", "type": "started"},
                "labels": {"nodes": [{"name": "research"}, {"name": "afk"}]},
                "parent": None, "delegate": {"id": "viewer-1"}, "assignee": None,
                "team": {"key": "ACR"}, "inverseRelations": {"nodes": []},
                "comments": {"nodes": [{"id": "rc1", "body": "Resolution: found it.", "createdAt": "2026-01-02T00:00:00Z", "user": {"id": "viewer-1"}}]},
            }}}, "returncode": 0},
            # open_research doc-fetch loop: ACR-40's documents
            {"stdout": {"data": {"issue": {"documents": {"nodes": [{"id": "doc-1", "title": "Findings", "archivedAt": None}]}}}}, "returncode": 0},
        ])
        ctx = map_sweep.gather_context(STUB_CMD, "ACR-1")
        self.assertEqual(len(ctx["children"]), 1)
        self.assertEqual(ctx["child_comments"]["uuid-r1"][0]["id"], "rc1")
        self.assertEqual(ctx["child_documents"]["uuid-r1"][0]["id"], "doc-1")
        self.assertEqual(call_count(counter), 5)

        # And it feeds compute_sweep cleanly into an orphaned_research finding.
        report = map_sweep.compute_sweep(ctx, now=NOW)
        self.assertEqual(len(report["orphaned_research"]), 1)
        self.assertEqual(report["orphaned_research"][0]["identifier"], "ACR-40")


# ---------------------------------------------------------------------
# CLI tests — main() dispatch
# ---------------------------------------------------------------------

class MainCliTests(unittest.TestCase):
    def setUp(self):
        self.saved = os.environ.pop("LINEAR_GQL_CMD", None)

    def tearDown(self):
        if self.saved is not None:
            os.environ["LINEAR_GQL_CMD"] = self.saved

    def test_missing_bridge_cmd_exit_config_gap(self):
        code = map_sweep.main(["ACR-1"])
        self.assertEqual(code, lb.EXIT_CONFIG_GAP)

    def test_full_sweep_happy_path_via_patched_gather_context(self):
        fake_ctx = f.base_ctx(children=[f.child("ACR-1", state_name="Todo", state_type="unstarted")])
        with patch("map_sweep.gather_context", return_value=fake_ctx):
            code = map_sweep.main(["--bridge-cmd", " ".join(STUB_CMD), "ACR-1"])
        self.assertEqual(code, lb.EXIT_OK)

    def test_frontier_only_path(self):
        map_node = {"id": "map-uuid-1", "identifier": "ACR-1"}
        children = [f.child("ACR-130", priority=1), f.child("ACR-131", priority=None)]
        with patch("map_sweep.lb.resolve_issue_ref", return_value=map_node), \
             patch("map_sweep.lb.fetch_children_full", return_value=children):
            code = map_sweep.main(["--bridge-cmd", " ".join(STUB_CMD), "ACR-1", "--frontier-only"])
        self.assertEqual(code, lb.EXIT_OK)


if __name__ == "__main__":
    unittest.main()
