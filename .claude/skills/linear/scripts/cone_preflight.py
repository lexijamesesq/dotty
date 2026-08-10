#!/usr/bin/env python3
"""
cone_preflight.py — per-verb deterministic admission checks for traffic-cone
lifecycle transitions.

This script never mutates. It reads a target ticket (and whatever else its
verb's checks require — parent map, charter document, children, comments,
history) via linear_bridge.py, runs the deterministic checks for the named
verb, and prints a single verdict report as JSON. Execution — the actual
state-change mutation — is a separate, explicit invocation of
linear_bridge.py's mutation subcommands by the calling contract card, once
any JUDGMENT_REQUIRED items are ruled on. Check -> judgment -> execute stays
three distinct beats; this script is only the first.

Every check below corresponds 1:1 to a row in the Check Inventory conformance
artifact (`--list-checks <verb>` prints that table for the named verb, plus
the cross-cutting rows that apply to every verb). A check whose home is pure
`Judgment` never appears in this script's runtime `checks`/`judgment_items`
output — it is deterministically un-scriptable, and lives instead as a named
line in the matching contract card's Judgment kernel section. A check whose
home is `Script+J` appears in `checks` and, when its non-deterministic branch
fires, produces a `DEFER` result plus a matching entry in `judgment_items`
carrying the evidence the model needs to rule on it.

Context shape this script's checks operate on (either gathered live via
`gather_context()` or built directly by a caller/test):

    {
      "issue": <linear_bridge issue node — includes description, comments
                {nodes:[...]}, history {nodes:[...]} when those were fetched>,
      "documents": [<issue's own documents>],
      "parent_comments": [<parent map's comments>] | None,
      "parent_documents": [<parent map's documents>] | None,
      "children": [<map children>] | None,               # close-map only
      "children_comments": {child_id: [<comments>]} | None,  # close-map only
      "viewer_id": "...", "operator_id": "..." | None,
      "state_ids": {"in_progress": "...", "done": "...", ...},
      "wip_conflict": {...} | None,
    }

Verdict contract (printed to stdout):

    {
      "verb": "...", "target": "...", "uuid": "...",
      "verdict": "ADMIT | REFUSE | NEEDS_INPUT | JUDGMENT_REQUIRED",
      "checks": [{"id", "name", "result": "PASS|FAIL|SKIP|DEFER", "detail"}],
      "facts": {...},
      "judgment_items": [{"id", "question", "evidence"}]
    }

Verdict precedence when multiple failure classes fire in the same run: a
plain REFUSE-class failure wins over a NEEDS_INPUT-class one (a REFUSE
signals the ticket is malformed in a way routing can't fix), which wins over
JUDGMENT_REQUIRED (a DEFER with no hard failure), which falls through to
ADMIT only when nothing else fired. This ordering is this implementation's
own smallest-reasonable choice where the spec's Check Inventory is silent on
simultaneous multi-class failures.

Exit codes: this script's own logic never fails destructively — a REFUSE
verdict is a normal, successful run (exit 0). Exit codes mirror
linear_bridge.py's transport codes (1/2/3/4/5) only when a live fetch this
script depends on fails outright. `--list-checks` always exits 0.

Usage:
    python3 cone_preflight.py claim ACR-12 [--operator-directed] [--autonomous]
        [--caller-ack-wip] [--delegated-preflight-passed] [--bridge-cmd CMD]
    python3 cone_preflight.py mark_done ACR-12 [--deterministic-exempt]
    python3 cone_preflight.py --list-checks claim
    python3 cone_preflight.py close-map ACR-1 --reverify \
        --accounting-document-id <id> --charter-document-id <id>
        # CM9's scripted re-verify — run immediately before set-state,
        # after the accounting doc is created and the charter archived.
"""

import argparse
import json
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import linear_bridge as lb  # noqa: E402


DECISION_TYPE_LABELS = {"research", "grilling", "prototype", "task"}
TYPE_LABELS = DECISION_TYPE_LABELS | {"build"}
COMPLETED_STATE_TYPES = {"completed", "canceled"}
DEFERRAL_MARKER = "_to be set at claim_"
FINALIZED_MARKER = "**FINALIZED**"
MANDATE_RE = re.compile(r"validation mandate:\s*`?([A-Za-z0-9_-]+)`?", re.IGNORECASE)
FINALIZED_DATE_RE = re.compile(r"\*\*FINALIZED\*\*\s*—\s*(\d{4}-\d{2}-\d{2})")
SECTION_RE = re.compile(r"^##\s+(.+?)\s*$", re.MULTILINE)


# ---------------------------------------------------------------------
# Check Inventory registry — static, for --list-checks. Mirrors
# cone-restructure-spec DRAFT v2, 2026-08-10, Check Inventory tables 1:1
# (id, name, home). If the spec revises, this registry is the artifact
# that drifts — bump the identity/date above when it's re-synced.
# ---------------------------------------------------------------------

CROSS_CUTTING = [
    {"id": "X-esc", "name": "Mention escaping in every posted body", "home": "Script (lint-body) + Judgment (authors bodies)"},
    {"id": "X-team", "name": "Team-aware stateId resolution, cached per invocation", "home": "Script"},
    {"id": "X-rb", "name": "No mutation trusted; read-back everything", "home": "Script"},
    {"id": "X-retry", "name": "Transient scope failures retry 2x (1s/3s) then surface", "home": "Script"},
    {"id": "X-park", "name": "Operator decision points degrade to park", "home": "Judgment"},
]

CHECK_INVENTORY = {
    "claim": [
        {"id": "C1", "name": "Objective present, non-empty", "home": "Script"},
        {"id": "C2", "name": "Done When concrete; deferral marker/missing -> NEEDS_INPUT routing (never silent pass)", "home": "Script (detect); proposal-composition is Judgment"},
        {"id": "C3", "name": "Type label present; conflict cells -> refuse + NEEDS_INPUT", "home": "Script"},
        {"id": "C4a", "name": "build: ready-for-agent label present", "home": "Script"},
        {"id": "C4b", "name": "build: charter FINALIZED marker on pinned doc", "home": "Script"},
        {"id": "C4c", "name": "build: no open [CHALLENGE] on parent map", "home": "Script"},
        {"id": "C5", "name": "Claimable: Todo (unless operator-directed), no open blocked-by, delegate null", "home": "Script"},
        {"id": "C5b", "name": "Closed/canceled parent map -> distinct REFUSE, no routing", "home": "Script"},
        {"id": "C6", "name": "WIP: no other In Progress delegated to actor on project; override only on caller ack", "home": "Script (detect); override disposition is Judgment"},
        {"id": "C7", "name": "Variant select (map / map-child / build / full)", "home": "Script (emits facts.variant)"},
        {"id": "C8", "name": "model:* label surfaced; session-model mismatch -> operator surface / NEEDS_INPUT headless", "home": "Script+J"},
        {"id": "C9", "name": "Assignee decision table, all variants", "home": "Script (emits facts.assignee_gate)"},
        {"id": "C10", "name": "Claim write: viewer+operator resolution, single mutation state+delegate(+assignee)", "home": "Script (linear_bridge.py claim-write)"},
        {"id": "C11", "name": "Read-back race check; lost race -> back off, report, never proceed", "home": "Script (built into claim-write)"},
        {"id": "C12", "name": "Full-variant Steps 1-5 (comments/blockers, WIP dialogue, Objective currency, sizing, proof-first breakdown)", "home": "Judgment"},
    ],
    "mark_done": [
        {"id": "M1", "name": "Direct read of ticket + comments (never caller's summary)", "home": "Script (fetch is the read)"},
        {"id": "M2", "name": "Objective present; Done When concrete; In Progress; NOT decision-type label", "home": "Script"},
        {"id": "M2.5", "name": "build: open [CHALLENGE] -> NEEDS_INPUT (park, no further checks); charter FINALIZED, date precedes receipt", "home": "Script"},
        {"id": "M3a", "name": "[VALIDATION] exists (newest)", "home": "Script"},
        {"id": "M3b", "name": "Fresh: postdates latest In Progress transition (issue history)", "home": "Script"},
        {"id": "M3c", "name": "Type match: mandate regex hit=Script decides; regex miss=DEFER with full Done When text", "home": "Script+J"},
        {"id": "M3d", "name": "Verdict: CONFIRMED (anything else present = data error, refuse)", "home": "Script"},
        {"id": "M3e", "name": "Schema: all four lines per /linear comments.md", "home": "Script"},
        {"id": "M3f", "name": "Author = app actor (viewer id)", "home": "Script"},
        {"id": "M4", "name": "Execute Done + optional caller closing comment", "home": "Script (set-state)"},
        {"id": "M-i", "name": "Idempotent recovery: already Done + valid receipt -> success, no re-transition", "home": "Script"},
        {"id": "M-d", "name": "Deterministic exemption: never-on-build is a hard Script refusal; non-build applicability is Judgment", "home": "Script+J"},
        {"id": "M-o", "name": "Feedback that would change the Objective -> refuse, route to operator", "home": "Judgment"},
    ],
    "resolve": [
        {"id": "R1", "name": "Guard: map child + decision-type label, else refuse to mark_done", "home": "Script"},
        {"id": "R2", "name": "research+afk: findings document exists AND resolution comment exists", "home": "Script"},
        {"id": "R3", "name": "research+hitl / grilling / prototype / task: resolution comment exists", "home": "Script"},
        {"id": "R4", "name": "Execute Done", "home": "Script"},
    ],
    "park": [
        {"id": "P1", "name": "Not map-labeled; ask comment present by live fetch (presence=Script; 'names a specific ask'=Judgment DEFER); not-yet-posted -> caller text posted at execute, presence re-verified", "home": "Script+J"},
        {"id": "P2", "name": "Needs Input + ask comment + release delegate (read-back) + assignee untouched", "home": "Script (execute)"},
    ],
    "block": [
        {"id": "B1", "name": "Not map; condition comment present; checkable condition", "home": "Script (presence) + Judgment (checkability)"},
        {"id": "B2", "name": "Blocked + condition comment + release delegate", "home": "Script (execute)"},
    ],
    "un-park": [
        {"id": "U1", "name": "Blocker verifiably resolved OR operator-directed; else refuse", "home": "Script+J"},
        {"id": "U2", "name": "-> Todo only; claim already clear else surface (never silently clear); In Progress = fresh claim, route to claim", "home": "Script"},
    ],
    "cancel": [
        {"id": "X1", "name": "Reason present -> Canceled + reason comment; optional duplicate_of relation", "home": "Script"},
    ],
    "close-map": [
        {"id": "CM1", "name": "map label + In Progress", "home": "Script"},
        {"id": "CM2", "name": "No open [CHALLENGE]", "home": "Script"},
        {"id": "CM3", "name": "All children Done/Canceled; name each open child (id, title, state)", "home": "Script"},
        {"id": "CM4", "name": "Locate FINALIZED charter doc; record id (reused by all later steps)", "home": "Script"},
        {"id": "CM5", "name": "Every Done build child has [VALIDATION] CONFIRMED (absence = data error); collect timestamps", "home": "Script"},
        {"id": "CM-a", "name": "Aggregate ALL failures into one checklist (no partial refusals)", "home": "Script (report shape)"},
        {"id": "CM6", "name": "map-conformance receipt: exists, fresh (postdates all CM5 timestamps), CONFIRMED, schema", "home": "Script"},
        {"id": "CM7", "name": "Accounting document composed from children's own receipts", "home": "Judgment"},
        {"id": "CM8", "name": "Archive charter + retained-link comment", "home": "Script (execute)"},
        {"id": "CM9", "name": "Done write with immediate re-verify of all four gates; any drift -> refuse and surface", "home": "Script (cone_preflight.py close-map --reverify, run immediately before execute's set-state)"},
    ],
}

VERBS = list(CHECK_INVENTORY.keys())


def check_name(verb, check_id):
    for row in CHECK_INVENTORY[verb]:
        if row["id"] == check_id:
            return row["name"]
    raise KeyError(f"unknown check id {check_id!r} for verb {verb!r}")


def mk_check(check_id, verb, result, detail=""):
    return {"id": check_id, "name": check_name(verb, check_id), "result": result, "detail": detail}


# ---------------------------------------------------------------------
# Shared parsing helpers
# ---------------------------------------------------------------------

def parse_sections(description):
    """Split a ticket description into {heading: body} by `## Heading` lines."""
    if not description:
        return {}
    sections = {}
    matches = list(SECTION_RE.finditer(description))
    for i, m in enumerate(matches):
        heading = m.group(1).strip()
        start = m.end()
        end = matches[i + 1].start() if i + 1 < len(matches) else len(description)
        sections[heading] = description[start:end].strip()
    return sections


def labels_of(node):
    return {l["name"] for l in ((node or {}).get("labels") or {}).get("nodes", [])}


def comments_of(node):
    return ((node or {}).get("comments") or {}).get("nodes", [])


def history_of(node):
    return ((node or {}).get("history") or {}).get("nodes", [])


def done_when_state(sections):
    body = sections.get("Done When", "")
    if not body:
        return "missing", body
    if DEFERRAL_MARKER in body:
        return "deferred", body
    return "concrete", body


def has_open_marker_pair(comments, open_prefix, close_prefix):
    """True if any comment starting with open_prefix has no comment starting
    with close_prefix posted after it. Returns (is_open, opening_comment)."""
    opens = sorted(
        (c for c in comments if (c.get("body") or "").startswith(open_prefix)),
        key=lambda c: c["createdAt"],
    )
    closes = sorted(
        (c for c in comments if (c.get("body") or "").startswith(close_prefix)),
        key=lambda c: c["createdAt"],
    )
    for op in opens:
        if not any(cl["createdAt"] > op["createdAt"] for cl in closes):
            return True, op
    return False, None


def parse_validation_comment(body):
    """Parse a [VALIDATION] comment per /linear playbooks/comments.md schema:
    [VALIDATION] — {type} / Verdict: / Intent: / Specifics: (4 lines)."""
    lines = [l for l in (body or "").splitlines() if l.strip()]
    if not lines or not lines[0].strip().startswith("[VALIDATION]"):
        return None
    header = re.match(r"^\[VALIDATION\]\s*—\s*(.+)$", lines[0].strip())
    validation_type = header.group(1).strip() if header else None
    verdict = intent = specifics = None
    for l in lines[1:]:
        s = l.strip()
        if s.startswith("Verdict:"):
            verdict = s[len("Verdict:"):].strip()
        elif s.startswith("Intent:"):
            intent = s[len("Intent:"):].strip()
        elif s.startswith("Specifics:"):
            specifics = s[len("Specifics:"):].strip()
    schema_complete = bool(header) and verdict is not None and intent is not None and specifics is not None
    return {
        "validation_type": validation_type,
        "verdict": verdict,
        "schema_complete": schema_complete,
    }


def newest_matching_comment(comments, predicate):
    matches = [c for c in comments if predicate(c)]
    if not matches:
        return None
    return sorted(matches, key=lambda c: c["createdAt"])[-1]


def find_finalized_doc(documents):
    for doc in documents or []:
        content = doc.get("content") or ""
        if FINALIZED_MARKER in content and not doc.get("archivedAt"):
            m = FINALIZED_DATE_RE.search(content)
            return doc, (m.group(1) if m else None)
    return None, None


# ---------------------------------------------------------------------
# Verdict aggregation
# ---------------------------------------------------------------------

def aggregate_verdict(refuse_reasons, needs_input_reasons, judgment_items):
    """REFUSE beats NEEDS_INPUT beats JUDGMENT_REQUIRED beats ADMIT. This
    precedence is this implementation's own choice where the Check Inventory
    doesn't specify simultaneous multi-class ordering."""
    if refuse_reasons:
        return "REFUSE"
    if needs_input_reasons:
        return "NEEDS_INPUT"
    if judgment_items:
        return "JUDGMENT_REQUIRED"
    return "ADMIT"


# ---------------------------------------------------------------------
# claim
# ---------------------------------------------------------------------

def run_claim_checks(ctx, flags):
    checks = []
    judgment_items = []
    refuse_reasons = []
    needs_input_reasons = []

    issue = ctx["issue"]
    labels = labels_of(issue)
    parent = issue.get("parent")
    sections = parse_sections(issue.get("description") or "")

    facts = {
        "variant": None,
        "team_key": (issue.get("team") or {}).get("key"),
        "state_ids": ctx.get("state_ids", {}),
        "viewer_id": ctx.get("viewer_id"),
        "operator_id": ctx.get("operator_id"),
        "assignee_gate": None,
        "model_label": None,
        "refusal_reasons": [],
    }

    # C7 — variant select
    variant = None
    if "map" in labels:
        c7_result, c7_detail = "FAIL", "issue itself carries the map label — maps are never claimed"
        refuse_reasons.append(c7_detail)
    elif parent is None:
        variant = "full"
        c7_result, c7_detail = "PASS", "no map parent — full variant"
    else:
        parent_labels = labels_of(parent)
        if "map" not in parent_labels:
            variant = "full"
            c7_result, c7_detail = "PASS", "parent present but not map-labeled — ordinary sub-task, full variant"
        elif "build" in labels:
            if not flags.get("delegated_preflight_passed"):
                c7_result = "FAIL"
                c7_detail = f"build child of map {parent.get('identifier')} — invoke /implement <id> (no --delegated-preflight-passed)"
                refuse_reasons.append(c7_detail)
            else:
                variant = "build"
                c7_result, c7_detail = "PASS", "build child, /implement pre-flight already admitted — proceeding"
        elif labels & DECISION_TYPE_LABELS:
            variant = "map-child"
            c7_result, c7_detail = "PASS", f"map child, type label {sorted(labels & DECISION_TYPE_LABELS)}"
        else:
            c7_result = "FAIL"
            c7_detail = "map child with no recognized type label — conflict cell"
            needs_input_reasons.append(c7_detail)
    facts["variant"] = variant
    checks.append(mk_check("C7", "claim", c7_result, c7_detail))

    # C5b — closed/canceled parent map
    if parent is not None and "map" in labels_of(parent) and (parent.get("state") or {}).get("type") in COMPLETED_STATE_TYPES:
        detail = f"mapped to a closed map ({parent.get('identifier')}) — needs disposition"
        checks.append(mk_check("C5b", "claim", "FAIL", detail))
        refuse_reasons.append(detail)
    else:
        checks.append(mk_check("C5b", "claim", "SKIP" if parent is None else "PASS", "parent map not closed/canceled" if parent else "no parent"))

    # C1 — objective present
    objective = sections.get("Objective", "")
    if objective:
        checks.append(mk_check("C1", "claim", "PASS", "Objective present and non-empty"))
    else:
        detail = "## Objective missing or empty"
        checks.append(mk_check("C1", "claim", "FAIL", detail))
        refuse_reasons.append(detail)

    # C2 — Done When concrete
    dw_state, _ = done_when_state(sections)
    if dw_state == "concrete":
        checks.append(mk_check("C2", "claim", "PASS", "Done When carries concrete conditions"))
    else:
        detail = f"Done When {dw_state} — propose conditions, route to Needs Input"
        checks.append(mk_check("C2", "claim", "FAIL", detail))
        needs_input_reasons.append(detail)

    # C3 — type label present / conflict cells
    has_question_body = "## Question" in (issue.get("description") or "")
    if "build" in labels and has_question_body:
        detail = "build label with a ## Question body — conflict cell"
        checks.append(mk_check("C3", "claim", "FAIL", detail))
        needs_input_reasons.append(detail)
    elif parent is not None and "map" in labels_of(parent) and not (labels & TYPE_LABELS):
        detail = "map child with no type label — conflict cell"
        checks.append(mk_check("C3", "claim", "FAIL", detail))
        needs_input_reasons.append(detail)
    elif "build" in labels and parent is None:
        detail = "build label on a ticket with no map parent — conflict cell"
        checks.append(mk_check("C3", "claim", "FAIL", detail))
        needs_input_reasons.append(detail)
    else:
        checks.append(mk_check("C3", "claim", "PASS", "no type-label conflict cell"))

    # C4a/b/c — build-only gates
    is_build_active = variant == "build"
    if not is_build_active:
        for cid in ("C4a", "C4b", "C4c"):
            checks.append(mk_check(cid, "claim", "SKIP", "not the build variant"))
    else:
        if "ready-for-agent" in labels:
            checks.append(mk_check("C4a", "claim", "PASS", "ready-for-agent label present"))
        else:
            detail = "build ticket not marked ready — finalization hasn't opened the lane"
            checks.append(mk_check("C4a", "claim", "FAIL", detail))
            refuse_reasons.append(detail)

        parent_docs = ctx.get("parent_documents") or []
        doc, finalized_date = find_finalized_doc(parent_docs)
        if doc:
            checks.append(mk_check("C4b", "claim", "PASS", f"charter {doc.get('id')} carries FINALIZED marker ({finalized_date})"))
        else:
            detail = "charter not finalized"
            checks.append(mk_check("C4b", "claim", "FAIL", detail))
            refuse_reasons.append(detail)

        parent_comments = ctx.get("parent_comments") or []
        is_open, opening = has_open_marker_pair(parent_comments, "[CHALLENGE]", "[CHALLENGE-RESOLVED]")
        if is_open:
            detail = "charter under challenge — operator adjudicates"
            checks.append(mk_check("C4c", "claim", "FAIL", detail))
            refuse_reasons.append(detail)
        else:
            checks.append(mk_check("C4c", "claim", "PASS", "no open [CHALLENGE] on parent map"))

    # C5 — claimable state
    state_type = (issue.get("state") or {}).get("type")
    delegate = issue.get("delegate")
    blocked_by_open = issue.get("blocked_by_open") or []
    c5_failures = []
    if state_type != "unstarted" and not flags.get("operator_directed"):
        c5_failures.append(f"state is {issue.get('state', {}).get('name')!r}, not Todo (no --operator-directed)")
    if blocked_by_open:
        c5_failures.append(f"open blocked-by relation(s): {[b.get('identifier') for b in blocked_by_open]}")
    if delegate:
        c5_failures.append(f"already delegated to {delegate.get('id')}")
    if c5_failures:
        detail = "; ".join(c5_failures)
        checks.append(mk_check("C5", "claim", "FAIL", detail))
        refuse_reasons.append(detail)
    else:
        checks.append(mk_check("C5", "claim", "PASS", "Todo (or operator-directed), unblocked, unclaimed"))

    # C6 — WIP check
    wip_conflict = ctx.get("wip_conflict")
    if wip_conflict and not flags.get("caller_ack_wip"):
        detail = f"actor already has {wip_conflict.get('identifier')} In Progress on this project — no --caller-ack-wip"
        checks.append(mk_check("C6", "claim", "FAIL", detail))
        refuse_reasons.append(detail)
    elif wip_conflict:
        checks.append(mk_check("C6", "claim", "PASS", f"WIP collision with {wip_conflict.get('identifier')} — override acknowledged"))
    else:
        checks.append(mk_check("C6", "claim", "PASS", "no other In Progress ticket delegated to actor on project"))

    # C8 — model label
    model_labels = [l for l in labels if l.startswith("model:")]
    if model_labels:
        facts["model_label"] = model_labels[0]
        item = {"id": "J-C8", "question": "Does the session's own model match this label (class, or exact version if pinned)?", "evidence": model_labels[0]}
        judgment_items.append(item)
        checks.append(mk_check("C8", "claim", "DEFER", f"model label {model_labels[0]!r} present — model compares to itself"))
    else:
        checks.append(mk_check("C8", "claim", "PASS", "no model:* label"))

    # C9 — assignee gate (informational derivation, never fails)
    if variant == "map-child":
        assignee_gate = "set" if "hitl" in labels else "skip"
    elif variant == "build":
        assignee_gate = "skip"
    elif variant == "full":
        assignee_gate = "skip" if flags.get("autonomous") else "set"
    else:
        assignee_gate = None
    facts["assignee_gate"] = assignee_gate
    checks.append(mk_check("C9", "claim", "PASS", f"assignee_gate={assignee_gate}"))

    facts["refusal_reasons"] = refuse_reasons + needs_input_reasons
    verdict = aggregate_verdict(refuse_reasons, needs_input_reasons, judgment_items)
    return checks, facts, judgment_items, verdict


# ---------------------------------------------------------------------
# mark_done
# ---------------------------------------------------------------------

def run_mark_done_checks(ctx, flags):
    checks = []
    judgment_items = []
    refuse_reasons = []
    needs_input_reasons = []

    issue = ctx["issue"]
    labels = labels_of(issue)
    comments = comments_of(issue)
    sections = parse_sections(issue.get("description") or "")
    is_build = "build" in labels

    facts = {
        "team_key": (issue.get("team") or {}).get("key"),
        "state_ids": ctx.get("state_ids", {}),
        "viewer_id": ctx.get("viewer_id"),
        "refusal_reasons": [],
        "idempotent": False,
        "charter_document_id": None,
    }

    checks.append(mk_check("M1", "mark_done", "PASS", "ticket and comments read directly"))

    state_type = (issue.get("state") or {}).get("type")
    already_done = state_type == "completed"

    receipt_comment = newest_matching_comment(comments, lambda c: (c.get("body") or "").strip().startswith("[VALIDATION]"))
    receipt = parse_validation_comment(receipt_comment["body"]) if receipt_comment else None

    # M2 — pre-check bundle
    m2_failures = []
    objective = sections.get("Objective", "")
    if not objective:
        m2_failures.append("## Objective missing or empty — run claim first")
    dw_state, done_when_text = done_when_state(sections)
    if dw_state != "concrete":
        m2_failures.append(f"Done When {dw_state} — run claim first")
    if not already_done and state_type != "started":
        m2_failures.append(f"state is {issue.get('state', {}).get('name')!r}, not In Progress — nothing to close")
    if labels & DECISION_TYPE_LABELS:
        m2_failures.append("decision-type label present — decision tickets close through resolve, not mark_done")

    if already_done:
        checks.append(mk_check("M2", "mark_done", "SKIP", "idempotent path: already Done, M2 in-progress requirement bypassed"))
    elif m2_failures:
        detail = "; ".join(m2_failures)
        checks.append(mk_check("M2", "mark_done", "FAIL", detail))
        refuse_reasons.append(detail)
    else:
        checks.append(mk_check("M2", "mark_done", "PASS", "Objective present, Done When concrete, In Progress, not decision-type"))

    short_circuited = False

    # M2.5 — build-only charter check
    if not is_build:
        checks.append(mk_check("M2.5", "mark_done", "SKIP", "not a build-labeled ticket"))
    else:
        parent_comments = ctx.get("parent_comments") or []
        is_open, opening = has_open_marker_pair(parent_comments, "[CHALLENGE]", "[CHALLENGE-RESOLVED]")
        if is_open:
            detail = "open [CHALLENGE] on parent map — park to Needs Input, no further checks"
            checks.append(mk_check("M2.5", "mark_done", "FAIL", detail))
            needs_input_reasons.append(detail)
            short_circuited = True
        else:
            parent_docs = ctx.get("parent_documents") or []
            doc, finalized_date = find_finalized_doc(parent_docs)
            if not doc:
                detail = "charter not finalized"
                checks.append(mk_check("M2.5", "mark_done", "FAIL", detail))
                refuse_reasons.append(detail)
            elif receipt_comment and finalized_date and finalized_date >= receipt_comment["createdAt"][:10]:
                detail = f"charter finalized {finalized_date} on/after receipt {receipt_comment['createdAt'][:10]} — finalized after the receipt it's meant to ground"
                checks.append(mk_check("M2.5", "mark_done", "FAIL", detail))
                refuse_reasons.append(detail)
            else:
                facts["charter_document_id"] = doc.get("id")
                checks.append(mk_check("M2.5", "mark_done", "PASS", f"charter {doc.get('id')} finalized {finalized_date}, predates receipt"))

    if short_circuited:
        for cid in ("M3a", "M3b", "M3c", "M3d", "M3e", "M3f", "M-i", "M-d"):
            checks.append(mk_check(cid, "mark_done", "SKIP", "short-circuited by M2.5 open challenge"))
        facts["refusal_reasons"] = refuse_reasons + needs_input_reasons
        return checks, facts, judgment_items, aggregate_verdict(refuse_reasons, needs_input_reasons, judgment_items)

    # M3a — receipt exists
    if not receipt_comment:
        detail = "no validation receipt — run @attack-kitty first"
        checks.append(mk_check("M3a", "mark_done", "FAIL", detail))
        refuse_reasons.append(detail)
    else:
        checks.append(mk_check("M3a", "mark_done", "PASS", f"newest [VALIDATION] comment at {receipt_comment['createdAt']}"))

    # M3b — fresh (postdates latest In Progress transition)
    if receipt_comment:
        history = history_of(issue)
        in_progress_entries = [h for h in history if (h.get("toState") or {}).get("type") == "started"]
        claim_ts = max((h["createdAt"] for h in in_progress_entries), default=None)
        if claim_ts is None:
            detail = "no In Progress transition found in history — cannot establish freshness"
            checks.append(mk_check("M3b", "mark_done", "FAIL", detail))
            refuse_reasons.append(detail)
        elif receipt_comment["createdAt"] <= claim_ts:
            detail = f"receipt ({receipt_comment['createdAt']}) predates claim ({claim_ts}) — stale receipt, graded different work"
            checks.append(mk_check("M3b", "mark_done", "FAIL", detail))
            refuse_reasons.append(detail)
        else:
            checks.append(mk_check("M3b", "mark_done", "PASS", f"receipt postdates claim at {claim_ts}"))
    else:
        checks.append(mk_check("M3b", "mark_done", "SKIP", "no receipt to check freshness of"))

    # M3c — type match
    if receipt_comment:
        mandate = MANDATE_RE.search(done_when_text or "")
        if mandate:
            required_type = mandate.group(1).strip()
            actual_type = (receipt.get("validation_type") or "").strip()
            if actual_type == required_type:
                checks.append(mk_check("M3c", "mark_done", "PASS", f"receipt type {actual_type!r} matches Done When mandate"))
            else:
                detail = f"receipt type {actual_type!r} != Done When mandate {required_type!r} — mismatch is never waved through"
                checks.append(mk_check("M3c", "mark_done", "FAIL", detail))
                refuse_reasons.append(detail)
        else:
            item = {
                "id": "J-M3c",
                "question": "Does the Done When text name a validation mandate in other words? If not, apply build->conformance / neither->refuse fallback.",
                "evidence": done_when_text or "",
            }
            judgment_items.append(item)
            checks.append(mk_check("M3c", "mark_done", "DEFER", "no literal 'Validation mandate: <type>' regex hit — judgment rules before any fallback applies"))
    else:
        checks.append(mk_check("M3c", "mark_done", "SKIP", "no receipt to type-match"))

    # M3d — verdict CONFIRMED
    if receipt_comment:
        if receipt and receipt.get("verdict") == "CONFIRMED":
            checks.append(mk_check("M3d", "mark_done", "PASS", "Verdict: CONFIRMED"))
        else:
            detail = f"Verdict is {receipt.get('verdict') if receipt else None!r}, not CONFIRMED — data error"
            checks.append(mk_check("M3d", "mark_done", "FAIL", detail))
            refuse_reasons.append(detail)
    else:
        checks.append(mk_check("M3d", "mark_done", "SKIP", "no receipt to check verdict of"))

    # M3e — schema
    if receipt_comment:
        if receipt and receipt.get("schema_complete"):
            checks.append(mk_check("M3e", "mark_done", "PASS", "all four schema lines present"))
        else:
            detail = "malformed receipt — missing one or more of the four schema lines"
            checks.append(mk_check("M3e", "mark_done", "FAIL", detail))
            refuse_reasons.append(detail)
    else:
        checks.append(mk_check("M3e", "mark_done", "SKIP", "no receipt to check schema of"))

    # M3f — author is app actor
    if receipt_comment:
        author_id = (receipt_comment.get("user") or {}).get("id")
        if author_id == ctx.get("viewer_id"):
            checks.append(mk_check("M3f", "mark_done", "PASS", "receipt authored by app actor"))
        else:
            detail = f"receipt authored by {author_id!r}, not the app actor ({ctx.get('viewer_id')!r})"
            checks.append(mk_check("M3f", "mark_done", "FAIL", detail))
            refuse_reasons.append(detail)
    else:
        checks.append(mk_check("M3f", "mark_done", "SKIP", "no receipt to check authorship of"))

    # M-i — idempotent recovery
    if already_done:
        receipt_valid = bool(receipt_comment) and not refuse_reasons
        if receipt_valid:
            facts["idempotent"] = True
            checks.append(mk_check("M-i", "mark_done", "PASS", "already Done with a valid receipt — success, no re-transition"))
        else:
            detail = "already Done but existing receipt is invalid — data error"
            checks.append(mk_check("M-i", "mark_done", "FAIL", detail))
            refuse_reasons.append(detail)
    else:
        checks.append(mk_check("M-i", "mark_done", "SKIP", "ticket not already Done"))

    # M-d — deterministic exemption
    if flags.get("deterministic_exempt"):
        if is_build:
            detail = "deterministic exemption never applies on build-labeled tickets — hard refusal, no deferral"
            checks.append(mk_check("M-d", "mark_done", "FAIL", detail))
            refuse_reasons.append(detail)
        else:
            item = {
                "id": "J-M-d",
                "question": "Is the captured deterministic output (fixture suite, linter, byte-diff) actually applicable here? When in doubt, not exempt.",
                "evidence": flags.get("deterministic_exempt_context", ""),
            }
            judgment_items.append(item)
            checks.append(mk_check("M-d", "mark_done", "DEFER", "non-build exemption claimed — applicability is Judgment"))
    else:
        checks.append(mk_check("M-d", "mark_done", "SKIP", "no --deterministic-exempt asserted"))

    facts["refusal_reasons"] = refuse_reasons + needs_input_reasons
    verdict = aggregate_verdict(refuse_reasons, needs_input_reasons, judgment_items)
    return checks, facts, judgment_items, verdict


# ---------------------------------------------------------------------
# resolve
# ---------------------------------------------------------------------

def run_resolve_checks(ctx, flags):
    checks = []
    refuse_reasons = []
    issue = ctx["issue"]
    labels = labels_of(issue)
    comments = comments_of(issue)
    parent = issue.get("parent")

    facts = {"team_key": (issue.get("team") or {}).get("key"), "state_ids": ctx.get("state_ids", {}), "refusal_reasons": []}

    is_map_child = parent is not None and "map" in labels_of(parent)
    decision_label = next(iter(labels & DECISION_TYPE_LABELS), None)
    if not (is_map_child and decision_label):
        detail = "resolve closes decision tickets; use mark_done" if not decision_label else "not a map child"
        checks.append(mk_check("R1", "resolve", "FAIL", detail))
        refuse_reasons.append(detail)
        checks.append(mk_check("R2", "resolve", "SKIP", "guard failed"))
        checks.append(mk_check("R3", "resolve", "SKIP", "guard failed"))
        facts["refusal_reasons"] = refuse_reasons
        return checks, facts, [], "REFUSE"

    checks.append(mk_check("R1", "resolve", "PASS", f"map child, decision label {decision_label!r}"))

    loop_label = "afk" if "afk" in labels else ("hitl" if "hitl" in labels else None)
    has_resolution_comment = any((c.get("body") or "").strip() for c in comments)

    if decision_label == "research" and loop_label == "afk":
        documents = ctx.get("documents") or []
        has_findings_doc = bool(documents)
        missing = []
        if not has_findings_doc:
            missing.append("findings document")
        if not has_resolution_comment:
            missing.append("resolution comment")
        if missing:
            detail = f"missing: {', '.join(missing)}"
            checks.append(mk_check("R2", "resolve", "FAIL", detail))
            refuse_reasons.append(detail)
        else:
            checks.append(mk_check("R2", "resolve", "PASS", "findings document and resolution comment both present"))
        checks.append(mk_check("R3", "resolve", "SKIP", "research+afk uses R2"))
    else:
        checks.append(mk_check("R2", "resolve", "SKIP", "not research+afk"))
        if has_resolution_comment:
            checks.append(mk_check("R3", "resolve", "PASS", "resolution comment present"))
        else:
            detail = "no resolution comment present"
            checks.append(mk_check("R3", "resolve", "FAIL", detail))
            refuse_reasons.append(detail)

    facts["refusal_reasons"] = refuse_reasons
    verdict = aggregate_verdict(refuse_reasons, [], [])
    return checks, facts, [], verdict


# ---------------------------------------------------------------------
# park / block / un-park / cancel
# ---------------------------------------------------------------------

def run_park_checks(ctx, flags):
    checks = []
    refuse_reasons = []
    judgment_items = []
    issue = ctx["issue"]
    comments = comments_of(issue)
    facts = {"team_key": (issue.get("team") or {}).get("key"), "state_ids": ctx.get("state_ids", {}), "refusal_reasons": []}

    if "map" in labels_of(issue):
        detail = "maps never park — a wedged map is a sweep finding, not a park target"
        checks.append(mk_check("P1", "park", "FAIL", detail))
        refuse_reasons.append(detail)
        facts["refusal_reasons"] = refuse_reasons
        return checks, facts, [], "REFUSE"

    ask_comment = newest_matching_comment(comments, lambda c: bool((c.get("body") or "").strip()))
    if ask_comment is None:
        item = {"id": "J-P1", "question": "No ask comment posted yet — compose the specific ask now; it will be posted at execute and presence re-verified.", "evidence": None}
        judgment_items.append(item)
        checks.append(mk_check("P1", "park", "DEFER", "not map-labeled; no ask comment posted yet"))
    else:
        item = {"id": "J-P1", "question": "Does this comment name a specific ask — what the operator needs to decide or provide?", "evidence": ask_comment.get("body")}
        judgment_items.append(item)
        checks.append(mk_check("P1", "park", "DEFER", "not map-labeled; ask comment present — checkability is judgment"))

    facts["refusal_reasons"] = refuse_reasons
    verdict = aggregate_verdict(refuse_reasons, [], judgment_items)
    return checks, facts, judgment_items, verdict


def run_block_checks(ctx, flags):
    checks = []
    refuse_reasons = []
    judgment_items = []
    issue = ctx["issue"]
    comments = comments_of(issue)
    facts = {"team_key": (issue.get("team") or {}).get("key"), "state_ids": ctx.get("state_ids", {}), "refusal_reasons": []}

    if "map" in labels_of(issue):
        detail = "maps never park/block — a wedged map is a sweep finding"
        checks.append(mk_check("B1", "block", "FAIL", detail))
        refuse_reasons.append(detail)
        facts["refusal_reasons"] = refuse_reasons
        return checks, facts, [], "REFUSE"

    condition_comment = newest_matching_comment(comments, lambda c: bool((c.get("body") or "").strip()))
    if condition_comment is None:
        detail = "no condition comment present — a block with no checkable condition is refused, not deferred"
        checks.append(mk_check("B1", "block", "FAIL", detail))
        refuse_reasons.append(detail)
    else:
        item = {"id": "J-B1", "question": "Is this a checkable condition — a URL to poll, a version, a PR, a date — something probeable mechanically?", "evidence": condition_comment.get("body")}
        judgment_items.append(item)
        checks.append(mk_check("B1", "block", "DEFER", "not map-labeled; condition comment present — checkability is judgment"))

    facts["refusal_reasons"] = refuse_reasons
    verdict = aggregate_verdict(refuse_reasons, [], judgment_items)
    return checks, facts, judgment_items, verdict


def run_unpark_checks(ctx, flags):
    checks = []
    refuse_reasons = []
    judgment_items = []
    issue = ctx["issue"]
    comments = comments_of(issue)
    facts = {"team_key": (issue.get("team") or {}).get("key"), "state_ids": ctx.get("state_ids", {}), "refusal_reasons": []}

    state_type = (issue.get("state") or {}).get("type")
    state_name = (issue.get("state") or {}).get("name")

    if state_type == "started":
        detail = "In Progress = a fresh claim, not an un-park — route to claim"
        checks.append(mk_check("U2", "un-park", "FAIL", detail))
        refuse_reasons.append(detail)
        checks.append(mk_check("U1", "un-park", "SKIP", "U2 guard failed"))
        facts["refusal_reasons"] = refuse_reasons
        return checks, facts, [], "REFUSE"

    if flags.get("operator_directed"):
        checks.append(mk_check("U1", "un-park", "PASS", "operator directed the un-park explicitly"))
    else:
        condition_comment = newest_matching_comment(comments, lambda c: bool((c.get("body") or "").strip()))
        if condition_comment is None:
            detail = "no blocker condition on record and no --operator-directed — refuse"
            checks.append(mk_check("U1", "un-park", "FAIL", detail))
            refuse_reasons.append(detail)
        else:
            item = {"id": "J-U1", "question": "Is the named blocker verifiably resolved? Re-check the condition from the Blocked/Needs Input comment.", "evidence": condition_comment.get("body")}
            judgment_items.append(item)
            checks.append(mk_check("U1", "un-park", "DEFER", "blocker condition on record — resolution verification is judgment"))

    delegate = issue.get("delegate")
    if delegate:
        checks.append(mk_check("U2", "un-park", "PASS", f"-> Todo; delegate NOT cleared ({delegate.get('id')}) — surfacing, never silently clearing"))
    else:
        checks.append(mk_check("U2", "un-park", "PASS", f"-> Todo from {state_name}; claim already clear"))

    facts["refusal_reasons"] = refuse_reasons
    verdict = aggregate_verdict(refuse_reasons, [], judgment_items)
    return checks, facts, judgment_items, verdict


def run_cancel_checks(ctx, flags):
    checks = []
    refuse_reasons = []
    issue = ctx["issue"]
    comments = comments_of(issue)
    facts = {"team_key": (issue.get("team") or {}).get("key"), "state_ids": ctx.get("state_ids", {}), "refusal_reasons": []}

    reason_comment = newest_matching_comment(comments, lambda c: bool((c.get("body") or "").strip()))
    if reason_comment is None:
        detail = "no reason given — refuse"
        checks.append(mk_check("X1", "cancel", "FAIL", detail))
        refuse_reasons.append(detail)
    else:
        checks.append(mk_check("X1", "cancel", "PASS", "reason present"))

    facts["refusal_reasons"] = refuse_reasons
    verdict = aggregate_verdict(refuse_reasons, [], [])
    return checks, facts, [], verdict


# ---------------------------------------------------------------------
# close-map
# ---------------------------------------------------------------------

def _cm_gates_123(issue, children):
    """CM1 (map label + In Progress), CM2 (no open [CHALLENGE]), CM3 (zero
    open children) — shared between initial admission (run_close_map_checks)
    and the CM9 re-verify (run_close_map_reverify_checks)."""
    checks = []
    refuse_reasons = []
    labels = labels_of(issue)
    comments = comments_of(issue)
    open_children_identifiers = []

    if "map" not in labels or (issue.get("state") or {}).get("type") != "started":
        detail = f"not a map In Progress (labels={sorted(labels)}, state={issue.get('state')})"
        checks.append(mk_check("CM1", "close-map", "FAIL", detail))
        refuse_reasons.append(detail)
    else:
        checks.append(mk_check("CM1", "close-map", "PASS", "map label + In Progress"))

    is_open, _opening = has_open_marker_pair(comments, "[CHALLENGE]", "[CHALLENGE-RESOLVED]")
    if is_open:
        detail = "open [CHALLENGE] on the map"
        checks.append(mk_check("CM2", "close-map", "FAIL", detail))
        refuse_reasons.append(detail)
    else:
        checks.append(mk_check("CM2", "close-map", "PASS", "no open [CHALLENGE]"))

    open_children = [c for c in children if (c.get("state") or {}).get("type") not in COMPLETED_STATE_TYPES]
    if open_children:
        detail = "; ".join(f"{c.get('identifier')} ({c.get('title')}) — {(c.get('state') or {}).get('name')}" for c in open_children)
        checks.append(mk_check("CM3", "close-map", "FAIL", detail))
        refuse_reasons.append(detail)
        open_children_identifiers = [c.get("identifier") for c in open_children]
    else:
        checks.append(mk_check("CM3", "close-map", "PASS", f"all {len(children)} children Done/Canceled"))

    return checks, refuse_reasons, open_children_identifiers


def _cm_gate_5(children, children_comments):
    """CM5 — every Done build child carries a CONFIRMED [VALIDATION].
    Also gathers CM7's accounting evidence for every Done child (build and
    non-build — original close-map.md Step 3: "Read each Done child's
    comments"), and returns the latest build-child [VALIDATION] timestamp
    CM6's freshness check needs. Shared between admission and re-verify."""
    done_build_children = [
        c for c in children
        if (c.get("state") or {}).get("type") == "completed" and "build" in {l["name"] for l in (c.get("labels") or {}).get("nodes", [])}
    ]
    cm5_failures = []
    latest_validation_ts = None
    done_children_facts = []
    for child in done_build_children:
        child_comments = children_comments.get(child.get("id"), [])
        vc = newest_matching_comment(child_comments, lambda c: (c.get("body") or "").strip().startswith("[VALIDATION]"))
        parsed = parse_validation_comment(vc["body"]) if vc else None
        if not vc or not parsed or parsed.get("verdict") != "CONFIRMED":
            cm5_failures.append(f"{child.get('identifier')} — Done build child with no CONFIRMED [VALIDATION] comment (data error)")
        else:
            done_children_facts.append({"identifier": child.get("identifier"), "validation_comment": vc.get("body")})
            if latest_validation_ts is None or vc["createdAt"] > latest_validation_ts:
                latest_validation_ts = vc["createdAt"]

    done_build_ids = {c.get("id") for c in done_build_children}
    other_done_children = [
        c for c in children
        if (c.get("state") or {}).get("type") == "completed" and c.get("id") not in done_build_ids
    ]
    for child in other_done_children:
        child_comments = children_comments.get(child.get("id"), [])
        done_children_facts.append({
            "identifier": child.get("identifier"),
            "comments": [c.get("body") for c in child_comments if (c.get("body") or "").strip()],
        })

    if cm5_failures:
        detail = "; ".join(cm5_failures)
        check = mk_check("CM5", "close-map", "FAIL", detail)
    else:
        check = mk_check("CM5", "close-map", "PASS", f"all {len(done_build_children)} Done build children carry a CONFIRMED [VALIDATION]")

    return check, cm5_failures, done_children_facts, latest_validation_ts


def _cm_gate_6(comments, latest_validation_ts):
    """CM6 — the map-conformance receipt: exists, fresh (postdates every
    build child's own [VALIDATION]), CONFIRMED, schema-complete. Shared
    between admission and re-verify."""
    receipt_comment = newest_matching_comment(comments, lambda c: (c.get("body") or "").strip().startswith("[VALIDATION] — map-conformance"))
    if not receipt_comment:
        detail = "no map-conformance receipt — run @attack-kitty's map-close-eval mandate first"
        return mk_check("CM6", "close-map", "FAIL", detail), [detail]

    parsed = parse_validation_comment(receipt_comment["body"])
    cm6_failures = []
    if latest_validation_ts and receipt_comment["createdAt"] <= latest_validation_ts:
        cm6_failures.append(f"receipt ({receipt_comment['createdAt']}) does not postdate all build children's own [VALIDATION] ({latest_validation_ts})")
    if not parsed or parsed.get("verdict") != "CONFIRMED":
        cm6_failures.append(f"Verdict is {parsed.get('verdict') if parsed else None!r}, not CONFIRMED")
    if not parsed or not parsed.get("schema_complete"):
        cm6_failures.append("malformed receipt — missing schema lines")

    if cm6_failures:
        detail = "; ".join(cm6_failures)
        return mk_check("CM6", "close-map", "FAIL", detail), cm6_failures
    return mk_check("CM6", "close-map", "PASS", "map-conformance receipt exists, fresh, CONFIRMED, schema-complete"), []


def run_close_map_checks(ctx, flags):
    issue = ctx["issue"]
    comments = comments_of(issue)
    children = ctx.get("children") or []
    children_comments = ctx.get("children_comments") or {}

    facts = {
        "team_key": (issue.get("team") or {}).get("key"),
        "state_ids": ctx.get("state_ids", {}),
        "refusal_reasons": [],
        "charter_document_id": None,
        "open_children": [],
        "done_children": [],
    }

    checks, refuse_reasons, open_children = _cm_gates_123(issue, children)
    facts["open_children"] = open_children

    # CM4 — locate the FINALIZED charter. Admission-time only: by re-verify
    # time (run_close_map_reverify_checks) the charter is expected to
    # already be archived, the opposite of this check's requirement — the
    # re-verify checks archival directly against the id this check found,
    # instead of re-deriving it.
    documents = ctx.get("documents") or []
    charter_doc, finalized_date = find_finalized_doc(documents)
    if charter_doc is None:
        detail = "no FINALIZED charter document found"
        checks.append(mk_check("CM4", "close-map", "FAIL", detail))
        refuse_reasons.append(detail)
    else:
        facts["charter_document_id"] = charter_doc.get("id")
        checks.append(mk_check("CM4", "close-map", "PASS", f"charter {charter_doc.get('id')} finalized {finalized_date}"))

    cm5_check, cm5_failures, done_children_facts, latest_validation_ts = _cm_gate_5(children, children_comments)
    checks.append(cm5_check)
    refuse_reasons.extend(cm5_failures)
    facts["done_children"] = done_children_facts

    checks.append(mk_check("CM-a", "close-map", "PASS" if not refuse_reasons else "FAIL",
                            "all Step-1 checks aggregated — no partial refusals" if not refuse_reasons else "one or more Step-1 checks failed; aggregated above, no partial execution"))

    if refuse_reasons:
        checks.append(mk_check("CM6", "close-map", "SKIP", "Step 1 preconditions failed — CM6 not evaluated"))
        facts["refusal_reasons"] = refuse_reasons
        return checks, facts, [], "REFUSE"

    cm6_check, cm6_failures = _cm_gate_6(comments, latest_validation_ts)
    checks.append(cm6_check)
    refuse_reasons.extend(cm6_failures)

    facts["refusal_reasons"] = refuse_reasons
    verdict = aggregate_verdict(refuse_reasons, [], [])
    return checks, facts, [], verdict


def run_close_map_reverify_checks(ctx, accounting_document_id, charter_document_id):
    """CM9 — the scripted re-verify path, run immediately before the
    execute step's set-state. Re-checks CM1/CM2/CM5/CM6 fresh (a late
    challenge, a reopened child, a build child's receipt disappearing, the
    map-conformance receipt) plus the two artifacts the execute step just
    produced: the accounting document exists, and the charter is archived —
    the four gates close-map.md Step 5 names. CM4 does NOT re-run: by
    re-verify time the charter is expected to already be archived, the
    opposite of CM4's admission-time "not yet archived" requirement — the
    charter_document_id from the original ADMIT run's facts is passed in
    directly and its archival is checked here instead. Any drift on any
    gate refuses; this never mutates — the caller only proceeds to
    `set-state` on ADMIT."""
    issue = ctx["issue"]
    comments = comments_of(issue)
    children = ctx.get("children") or []
    children_comments = ctx.get("children_comments") or {}
    documents = ctx.get("documents") or []

    facts = {
        "team_key": (issue.get("team") or {}).get("key"),
        "state_ids": ctx.get("state_ids", {}),
        "refusal_reasons": [],
        "charter_document_id": charter_document_id,
        "open_children": [],
        "done_children": [],
    }

    checks, refuse_reasons, open_children = _cm_gates_123(issue, children)
    facts["open_children"] = open_children

    cm5_check, cm5_failures, done_children_facts, latest_validation_ts = _cm_gate_5(children, children_comments)
    checks.append(cm5_check)
    refuse_reasons.extend(cm5_failures)
    facts["done_children"] = done_children_facts

    cm6_check, cm6_failures = _cm_gate_6(comments, latest_validation_ts)
    checks.append(cm6_check)
    refuse_reasons.extend(cm6_failures)

    cm9_failures = []
    if not accounting_document_id:
        cm9_failures.append("no accounting_document_id supplied to re-verify")
    else:
        acct_doc = next((d for d in documents if d.get("id") == accounting_document_id), None)
        if acct_doc is None:
            cm9_failures.append(f"accounting document {accounting_document_id} not found on re-fetch")
        elif acct_doc.get("archivedAt"):
            cm9_failures.append(f"accounting document {accounting_document_id} is archived — drift since the write")

    if not charter_document_id:
        cm9_failures.append("no charter_document_id supplied to re-verify")
    else:
        charter_doc = next((d for d in documents if d.get("id") == charter_document_id), None)
        if charter_doc is None:
            cm9_failures.append(f"charter document {charter_document_id} not found on re-fetch — cannot confirm archival")
        elif not charter_doc.get("archivedAt"):
            cm9_failures.append(f"charter document {charter_document_id} is not archived")

    all_failures = refuse_reasons + cm9_failures
    if all_failures:
        detail = "; ".join(all_failures)
        checks.append(mk_check("CM9", "close-map", "FAIL", detail))
        facts["refusal_reasons"] = all_failures
        return checks, facts, [], "REFUSE"

    checks.append(mk_check("CM9", "close-map", "PASS", "all four gates re-verified clean immediately before the write"))
    facts["refusal_reasons"] = []
    return checks, facts, [], "ADMIT"


VERB_RUNNERS = {
    "claim": run_claim_checks,
    "mark_done": run_mark_done_checks,
    "resolve": run_resolve_checks,
    "park": run_park_checks,
    "block": run_block_checks,
    "un-park": run_unpark_checks,
    "cancel": run_cancel_checks,
    "close-map": run_close_map_checks,
}


def run_checks(verb, ctx, flags):
    checks, facts, judgment_items, verdict = VERB_RUNNERS[verb](ctx, flags)
    issue = ctx["issue"]
    return {
        "verb": verb,
        "target": issue.get("identifier"),
        "uuid": issue.get("id"),
        "verdict": verdict,
        "checks": checks,
        "facts": facts,
        "judgment_items": judgment_items,
    }


def run_close_map_reverify(ctx, accounting_document_id, charter_document_id):
    """CLI-facing wrapper around run_close_map_reverify_checks — same output
    contract shape as run_checks, so the card's Step 5 can invoke this
    exactly like any other verb call."""
    checks, facts, judgment_items, verdict = run_close_map_reverify_checks(
        ctx, accounting_document_id, charter_document_id
    )
    issue = ctx["issue"]
    return {
        "verb": "close-map",
        "target": issue.get("identifier"),
        "uuid": issue.get("id"),
        "verdict": verdict,
        "checks": checks,
        "facts": facts,
        "judgment_items": judgment_items,
    }


# ---------------------------------------------------------------------
# Live context gathering
# ---------------------------------------------------------------------

def gather_context(bridge_cmd_parts, verb, issue_id, flags):
    issue = lb.resolve_issue_ref(bridge_cmd_parts, issue_id, body=True, comments=True, history=True)
    # resolve_issue_ref (unlike linear_bridge.py's own `issue` CLI handler)
    # does not populate blocked_by_open on its own — C5's open-blocker check
    # depends on it, so it's computed here, once, right after the fetch.
    issue["blocked_by_open"] = lb._blocked_by_open(issue)
    ctx = {"issue": issue}

    ctx["viewer_id"] = (lb.resolve_viewer(bridge_cmd_parts) or {}).get("id")
    if verb == "claim":
        try:
            ctx["operator_id"] = (lb.resolve_operator(bridge_cmd_parts) or {}).get("id")
        except (lb.GraphQLAPIError, lb.AmbiguousOperatorError):
            ctx["operator_id"] = None

    team_key = (issue.get("team") or {}).get("key")
    state_names = {
        "claim": ["In Progress", "Needs Input"],  # Needs Input funds the C2/C3 NEEDS_INPUT execution path
        "mark_done": ["Done", "Needs Input"],  # Needs Input funds the M2.5 NEEDS_INPUT execution path
        "resolve": ["Done"],
        "park": ["Needs Input"],
        "block": ["Blocked"],
        "un-park": ["Todo"],
        "cancel": ["Canceled"],
        "close-map": ["Done"],
    }.get(verb, [])
    state_ids = {}
    if team_key:
        for name in state_names:
            try:
                st = lb.resolve_state(bridge_cmd_parts, team_key, name)
                state_ids[name.lower().replace(" ", "_")] = st.get("id")
            except lb.GraphQLAPIError:
                pass
    ctx["state_ids"] = state_ids

    if verb in ("claim", "mark_done"):
        parent = issue.get("parent")
        if parent and "map" in {l["name"] for l in (parent.get("labels") or {}).get("nodes", [])}:
            parent_node = lb.resolve_issue_ref(bridge_cmd_parts, parent["id"], comments=True)
            ctx["parent_comments"] = comments_of(parent_node)
            ctx["parent_documents"] = lb.fetch_documents(bridge_cmd_parts, parent["id"], content=True)

    if verb == "resolve":
        ctx["documents"] = lb.fetch_documents(bridge_cmd_parts, issue["id"])

    if verb == "claim":
        actor_id = ctx["viewer_id"]
        project_id = flags.get("project_id")
        if actor_id and project_id:
            conflicts = lb.wip_check(bridge_cmd_parts, actor_id, project_id)
            ctx["wip_conflict"] = conflicts[0] if conflicts else None

    if verb == "close-map":
        ctx["children"] = lb.fetch_children(bridge_cmd_parts, issue["id"])
        ctx["documents"] = lb.fetch_documents(bridge_cmd_parts, issue["id"], content=True)
        children_comments = {}
        for child in ctx["children"]:
            # Every Done child's comments are fetched — CM5's [VALIDATION]
            # check needs build children's; CM7's accounting authorship
            # needs every Done child's own receipts (original close-map.md
            # Step 3), not build children alone.
            if (child.get("state") or {}).get("type") == "completed":
                child_node = lb.resolve_issue_ref(bridge_cmd_parts, child["id"], comments=True)
                children_comments[child["id"]] = comments_of(child_node)
        ctx["children_comments"] = children_comments

    return ctx


# ---------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------

def print_list_checks(verb):
    rows = CHECK_INVENTORY[verb] + CROSS_CUTTING
    print(json.dumps({"verb": verb, "checks": rows}, indent=2))


def main(argv=None):
    parser = argparse.ArgumentParser(description="Traffic-cone per-verb admission checks (never mutates).")
    parser.add_argument("verb", nargs="?", choices=VERBS)
    parser.add_argument("target", nargs="?", default=None)
    parser.add_argument("--list-checks", metavar="VERB", choices=VERBS, default=None)
    parser.add_argument("--bridge-cmd", default=None)
    parser.add_argument("--operator-directed", action="store_true")
    parser.add_argument("--autonomous", action="store_true")
    parser.add_argument("--caller-ack-wip", action="store_true")
    parser.add_argument("--delegated-preflight-passed", action="store_true")
    parser.add_argument("--deterministic-exempt", action="store_true")
    parser.add_argument("--deterministic-exempt-context", default="")
    parser.add_argument("--project-id", default=None)
    parser.add_argument("--reverify", action="store_true",
                         help="close-map only: CM9's scripted re-verify, run immediately before set-state.")
    parser.add_argument("--accounting-document-id", default=None,
                         help="close-map --reverify: the document id the execute step's createDocument just returned.")
    parser.add_argument("--charter-document-id", default=None,
                         help="close-map --reverify: the charter document id (facts.charter_document_id from the ADMIT run).")
    args = parser.parse_args(argv)

    if args.list_checks:
        print_list_checks(args.list_checks)
        return lb.EXIT_OK

    if not args.verb or not args.target:
        parser.error("verb and target are required unless --list-checks is given")

    if args.reverify and args.verb != "close-map":
        parser.error("--reverify is close-map only")

    flags = {
        "operator_directed": args.operator_directed,
        "autonomous": args.autonomous,
        "caller_ack_wip": args.caller_ack_wip,
        "delegated_preflight_passed": args.delegated_preflight_passed,
        "deterministic_exempt": args.deterministic_exempt,
        "deterministic_exempt_context": args.deterministic_exempt_context,
        "project_id": args.project_id,
    }

    try:
        bridge_cmd_parts = lb.resolve_bridge_cmd(args.bridge_cmd)
        ctx = gather_context(bridge_cmd_parts, args.verb, args.target, flags)
        if args.reverify:
            report = run_close_map_reverify(ctx, args.accounting_document_id, args.charter_document_id)
        else:
            report = run_checks(args.verb, ctx, flags)
        print(json.dumps(report, indent=2))
        return lb.EXIT_OK
    except lb.BridgeConfigError as e:
        print(f"ERROR (config gap): {e}", file=sys.stderr)
        return lb.EXIT_CONFIG_GAP
    except lb.BridgeAuthError as e:
        print(f"ERROR (auth failure): {e}", file=sys.stderr)
        return lb.EXIT_AUTH
    except lb.GraphQLAPIError as e:
        print(f"ERROR (GraphQL): {e}", file=sys.stderr)
        return lb.EXIT_GRAPHQL
    except lb.TransientBridgeError as e:
        print(f"ERROR (transient, retries exhausted): {e}", file=sys.stderr)
        return lb.EXIT_TRANSIENT
    except (RuntimeError, KeyError, TypeError, ValueError) as e:
        print(f"ERROR (script bug): {e}", file=sys.stderr)
        return lb.EXIT_SCRIPT_BUG


if __name__ == "__main__":
    sys.exit(main())
