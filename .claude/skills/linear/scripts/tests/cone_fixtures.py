"""
Shared context/fixture builders for test_cone_preflight.py. All identifiers
are fictional per the sample-universe convention — team ACR, tickets ACR-N —
never a real ticket id or the real team key.

cone_preflight.run_checks(verb, ctx, flags) is a pure function once handed a
context dict, so these tests build that context directly rather than
routing through a stub GraphQL bridge — the bridge's own transport mechanics
(retry, error classification, subcommand shaping) are linear_bridge.py's
concern and are covered in test_linear_bridge.py. What's under test here is
check *logic*: given a fetched state, does the right verdict and evidence
come out.
"""
import copy

BASE_OBJECTIVE = "## Objective\nShip the thing.\n\n"
BASE_CTX = "## Constraints and Context\nNone notable."


def _issue(**overrides):
    issue = {
        "id": "uuid-base",
        "identifier": "ACR-1",
        "title": "Base ticket",
        "description": BASE_OBJECTIVE + "## Done When\n- Tests pass\n\n" + BASE_CTX,
        "state": {"name": "Todo", "type": "unstarted"},
        "labels": {"nodes": [{"name": "task"}]},
        "parent": None,
        "delegate": None,
        "assignee": None,
        "team": {"key": "ACR"},
        "blocked_by_open": [],
        "comments": {"nodes": []},
        "history": {"nodes": []},
    }
    issue.update(overrides)
    return issue


def map_parent(**overrides):
    parent = {
        "id": "map-uuid-1",
        "identifier": "ACR-1",
        "title": "The Map",
        "state": {"name": "In Progress", "type": "started"},
        "labels": {"nodes": [{"name": "map"}]},
    }
    parent.update(overrides)
    return parent


def finalized_charter(finalized_date="2026-01-01", **overrides):
    doc = {
        "id": "charter-doc-1",
        "title": "Build Charter",
        "archivedAt": None,
        "content": f"Charter body.\n\n**FINALIZED** — {finalized_date} — operator sign-off recorded",
    }
    doc.update(overrides)
    return doc


# ------------------------------------------------------------------ claim

def claim_full_ctx(**overrides):
    ctx = {
        "issue": _issue(identifier="ACR-20", id="uuid-claim-full"),
        "viewer_id": "viewer-1",
        "operator_id": "operator-1",
        "state_ids": {"in_progress": "state-ip", "needs_input": "state-ni"},
        "wip_conflict": None,
    }
    ctx.update(overrides)
    return ctx


def claim_build_ctx(**overrides):
    issue = _issue(
        identifier="ACR-21",
        id="uuid-claim-build",
        labels={"nodes": [{"name": "build"}, {"name": "ready-for-agent"}]},
        parent=map_parent(),
        description=BASE_OBJECTIVE + "## Done When\nValidation mandate: conformance\n\n" + BASE_CTX,
    )
    ctx = {
        "issue": issue,
        "viewer_id": "viewer-1",
        "operator_id": "operator-1",
        "state_ids": {"in_progress": "state-ip", "needs_input": "state-ni"},
        "wip_conflict": None,
        "parent_documents": [finalized_charter()],
        "parent_comments": [],
    }
    ctx.update(overrides)
    return ctx


def claim_map_child_ctx(**overrides):
    issue = _issue(
        identifier="ACR-22",
        id="uuid-claim-mapchild",
        labels={"nodes": [{"name": "research"}]},
        parent=map_parent(),
    )
    ctx = {
        "issue": issue,
        "viewer_id": "viewer-1",
        "operator_id": "operator-1",
        "state_ids": {"in_progress": "state-ip", "needs_input": "state-ni"},
        "wip_conflict": None,
        "parent_documents": [],
        "parent_comments": [],
    }
    ctx.update(overrides)
    return ctx


CLAIM_FLAGS_DEFAULT = {
    "operator_directed": False,
    "autonomous": False,
    "caller_ack_wip": False,
    "delegated_preflight_passed": False,
    "conductor_preflight": False,
}


def claim_flags(**overrides):
    flags = dict(CLAIM_FLAGS_DEFAULT)
    flags.update(overrides)
    return flags


# --------------------------------------------------------------- mark_done

def mark_done_full_ctx(**overrides):
    # No type label — mark_done's M2 refuses on any of the decision-type
    # labels (research/grilling/prototype/task) regardless of map-child-ness,
    # so a standalone full-variant ticket here carries none of them.
    issue = _issue(
        identifier="ACR-30",
        id="uuid-md-full",
        state={"name": "In Progress", "type": "started"},
        labels={"nodes": []},
        description=BASE_OBJECTIVE + "## Done When\nValidation mandate: conformance\n\n" + BASE_CTX,
        comments={"nodes": [
            {"id": "c1", "body": "[VALIDATION] — conformance\nVerdict: CONFIRMED\nIntent: it works\nSpecifics: ran the suite",
             "createdAt": "2026-02-01T12:00:00Z", "user": {"id": "viewer-1"}},
        ]},
        history={"nodes": [
            {"createdAt": "2026-01-30T09:00:00Z", "fromState": {"name": "Todo", "type": "unstarted"},
             "toState": {"name": "In Progress", "type": "started"}},
        ]},
    )
    ctx = {
        "issue": issue,
        "viewer_id": "viewer-1",
        "state_ids": {"done": "state-done", "needs_input": "state-ni"},
    }
    ctx.update(overrides)
    return ctx


def mark_done_build_ctx(**overrides):
    issue = _issue(
        identifier="ACR-31",
        id="uuid-md-build",
        state={"name": "In Progress", "type": "started"},
        labels={"nodes": [{"name": "build"}]},
        parent=map_parent(),
        description=BASE_OBJECTIVE + "## Done When\nValidation mandate: conformance\n\n" + BASE_CTX,
        comments={"nodes": [
            {"id": "c1", "body": "[VALIDATION] — conformance\nVerdict: CONFIRMED\nIntent: it works\nSpecifics: ran the suite",
             "createdAt": "2026-02-01T12:00:00Z", "user": {"id": "viewer-1"}},
        ]},
        history={"nodes": [
            {"createdAt": "2026-01-30T09:00:00Z", "fromState": {"name": "Todo", "type": "unstarted"},
             "toState": {"name": "In Progress", "type": "started"}},
        ]},
    )
    ctx = {
        "issue": issue,
        "viewer_id": "viewer-1",
        "state_ids": {"done": "state-done", "needs_input": "state-ni"},
        "parent_documents": [finalized_charter(finalized_date="2026-01-15")],
        "parent_comments": [],
    }
    ctx.update(overrides)
    return ctx


MARK_DONE_FLAGS_DEFAULT = {"deterministic_exempt": False, "deterministic_exempt_context": ""}


def mark_done_flags(**overrides):
    flags = dict(MARK_DONE_FLAGS_DEFAULT)
    flags.update(overrides)
    return flags


# ----------------------------------------------------------------- resolve

def resolve_research_afk_ctx(**overrides):
    issue = _issue(
        identifier="ACR-40",
        id="uuid-r-afk",
        state={"name": "In Progress", "type": "started"},
        labels={"nodes": [{"name": "research"}, {"name": "afk"}]},
        parent=map_parent(),
        comments={"nodes": [
            {"id": "c1", "body": "Resolution: findings attached, thesis holds.", "createdAt": "2026-02-01T12:00:00Z", "user": {"id": "viewer-1"}},
        ]},
    )
    ctx = {
        "issue": issue,
        "documents": [{"id": "doc-findings-1", "title": "Findings", "archivedAt": None}],
        "state_ids": {"done": "state-done"},
    }
    ctx.update(overrides)
    return ctx


def resolve_grilling_hitl_ctx(**overrides):
    issue = _issue(
        identifier="ACR-41",
        id="uuid-r-hitl",
        state={"name": "In Progress", "type": "started"},
        labels={"nodes": [{"name": "grilling"}, {"name": "hitl"}]},
        parent=map_parent(),
        comments={"nodes": [
            {"id": "c1", "body": "Resolution: operator aligned on X in the live exchange.", "createdAt": "2026-02-01T12:00:00Z", "user": {"id": "operator-1"}},
        ]},
    )
    ctx = {
        "issue": issue,
        "documents": [],
        "state_ids": {"done": "state-done"},
    }
    ctx.update(overrides)
    return ctx


# ---------------------------------------------------------- park/block/etc

def park_ctx(**overrides):
    issue = _issue(
        identifier="ACR-50",
        id="uuid-park-1",
        state={"name": "In Progress", "type": "started"},
        comments={"nodes": [
            {"id": "c1", "body": "Need a decision on the routing convention before continuing.", "createdAt": "2026-02-01T12:00:00Z", "user": {"id": "viewer-1"}},
        ]},
    )
    ctx = {"issue": issue, "state_ids": {"needs_input": "state-ni"}}
    ctx.update(overrides)
    return ctx


def block_ctx(**overrides):
    issue = _issue(
        identifier="ACR-51",
        id="uuid-block-1",
        state={"name": "In Progress", "type": "started"},
        comments={"nodes": [
            {"id": "c1", "body": "Blocked on PR #482 merging upstream — poll its status.", "createdAt": "2026-02-01T12:00:00Z", "user": {"id": "viewer-1"}},
        ]},
    )
    ctx = {"issue": issue, "state_ids": {"blocked": "state-blocked"}}
    ctx.update(overrides)
    return ctx


def unpark_ctx(**overrides):
    issue = _issue(
        identifier="ACR-52",
        id="uuid-unpark-1",
        state={"name": "Blocked", "type": "backlog"},
        comments={"nodes": [
            {"id": "c1", "body": "Blocked on PR #482 merging upstream — poll its status.", "createdAt": "2026-02-01T12:00:00Z", "user": {"id": "viewer-1"}},
        ]},
    )
    ctx = {"issue": issue, "state_ids": {"todo": "state-todo"}}
    ctx.update(overrides)
    return ctx


UNPARK_FLAGS_DEFAULT = {"operator_directed": False}


def unpark_flags(**overrides):
    flags = dict(UNPARK_FLAGS_DEFAULT)
    flags.update(overrides)
    return flags


def cancel_ctx(**overrides):
    issue = _issue(
        identifier="ACR-53",
        id="uuid-cancel-1",
        comments={"nodes": [
            {"id": "c1", "body": "Superseded by ACR-9 — canceling.", "createdAt": "2026-02-01T12:00:00Z", "user": {"id": "viewer-1"}},
        ]},
    )
    ctx = {"issue": issue, "state_ids": {"canceled": "state-canceled"}}
    ctx.update(overrides)
    return ctx


# --------------------------------------------------------------- close-map

def close_map_ctx(**overrides):
    map_issue = _issue(
        identifier="ACR-1",
        id="map-uuid-1",
        state={"name": "In Progress", "type": "started"},
        labels={"nodes": [{"name": "map"}]},
        comments={"nodes": []},
    )
    children = [
        {"id": "child-1", "identifier": "ACR-2", "title": "Build slice one",
         "state": {"name": "Done", "type": "completed"},
         "labels": {"nodes": [{"name": "build"}]}, "delegate": None},
        {"id": "child-2", "identifier": "ACR-3", "title": "Research angle",
         "state": {"name": "Done", "type": "completed"},
         "labels": {"nodes": [{"name": "research"}]}, "delegate": None},
    ]
    children_comments = {
        "child-1": [
            {"id": "vc1", "body": "[VALIDATION] — conformance\nVerdict: CONFIRMED\nIntent: it works\nSpecifics: ran the suite",
             "createdAt": "2026-02-01T10:00:00Z", "user": {"id": "viewer-1"}},
        ],
        "child-2": [
            {"id": "rc1", "body": "Resolution: angle explored, thesis holds.", "createdAt": "2026-02-01T09:00:00Z", "user": {"id": "viewer-1"}},
        ],
    }
    ctx = {
        "issue": map_issue,
        "children": children,
        "children_comments": children_comments,
        "documents": [finalized_charter(finalized_date="2026-01-01")],
        "state_ids": {"done": "state-done"},
    }
    ctx["issue"]["comments"] = {"nodes": [
        {"id": "mc1", "body": "[VALIDATION] — map-conformance\nVerdict: CONFIRMED\nIntent: map holds\nSpecifics: e2e ran clean",
         "createdAt": "2026-02-01T11:00:00Z", "user": {"id": "viewer-1"}},
    ]}
    ctx.update(overrides)
    return ctx


def deepcopy_ctx(ctx):
    return copy.deepcopy(ctx)
