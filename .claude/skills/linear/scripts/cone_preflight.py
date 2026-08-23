#!/usr/bin/env python3
"""
cone_preflight.py — per-verb deterministic admission checks for traffic-cone
lifecycle transitions.

By default this script never mutates. It reads a target ticket (and whatever
else its verb's checks require — parent map, children, comments, history)
via linear_bridge.py, runs the deterministic checks for
the named verb, and prints a single verdict report as JSON. Execution — the
actual state-change mutation — is normally a separate, explicit invocation of
linear_bridge.py's mutation subcommands by the calling contract card, once
any JUDGMENT_REQUIRED items are ruled on. Check -> judgment -> execute stays
three distinct beats.

`--execute-if-clean` fuses the third beat into this same process for seven
verbs (claim, resolve, mark_done, park, block, un-park, cancel — never
close-map, which keeps its own staged `--reverify` shape): an ADMIT verdict
with zero judgment items executes its mutation(s) in-process, read-back
verified, in one invocation; REFUSE or JUDGMENT_REQUIRED stop before any
mutation call. NEEDS_INPUT (reachable only for claim's C2/C3) executes its
own routing mutation rather than stopping — see
`execute_if_clean()`'s docstring for the exact per-verb shape and the
comment-before-state-change sequencing law. Judgment items that were already
ruled in a prior invocation resume mechanically via a per-item assertion
flag (`--model-ruled`, `--exempt-ruled`, `--mandate-type`, `--blocker-verified`,
`--receipt-audited`, `--caller-ack-wip`) instead of deferring again — see
`run_checks()`'s `ruled` field.

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
      "children": [<map children>] | None,               # close-map only
      "children_comments": {child_id: [<comments>]} | None,  # close-map only
      "viewer_id": "...", "operator_id": "..." | None,
      "state_ids": {"in_progress": "...", "done": "...", ...},
      "wip_conflict": {...} | None,
    }

Verdict contract (printed to stdout for a plain check-only run — the shape
`run_checks()` returns and every existing test asserts against):

    {
      "verb": "...", "target": "...", "uuid": "...",
      "verdict": "ADMIT | REFUSE | NEEDS_INPUT | JUDGMENT_REQUIRED",
      "checks": [{"id", "name", "result": "PASS|FAIL|SKIP|DEFER", "detail"}],
      "facts": {...},
      "judgment_items": [{"id", "question", "evidence"}],
      "ruled": ["C6", ...]   # check ids cleared this run by an assertion flag
    }

`--execute-if-clean` window-prices this at the CLI print boundary only (this
in-memory shape is unchanged) — see `format_output()`: ADMIT by default
prints a compact block (verb/target/uuid/verdict/executed/elapsed_ms/ruled/
result), full `checks`/`facts`/`judgment_items` print only on non-ADMIT. Both
shapes add `"executed": true|false` and, when a mutation ran, `"result"`
with that mutation's own read-back-verified data.

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
    python3 cone_preflight.py claim ACR-12 --project-id <uuid> [--operator-directed] [--autonomous]
        [--caller-ack-wip] [--delegated-preflight-passed] [--conductor-preflight] [--bridge-cmd CMD]
        # --project-id is required for claim — absent it, refuses with a
        # config-gap message (without it wip_check never runs and C6 would
        # auto-pass unchecked).
    python3 cone_preflight.py mark_done ACR-12 [--deterministic-exempt]
    python3 cone_preflight.py --list-checks claim
    python3 cone_preflight.py close-map ACR-1 --reverify \
        --accounting-document-id <id>
        # CM9's scripted re-verify — run immediately before set-state,
        # after the accounting doc is created.

    # Fused mode — checks -> execute -> read-back in one process:
    python3 cone_preflight.py claim ACR-12 --project-id <uuid> --execute-if-clean
    python3 cone_preflight.py mark_done ACR-12 --execute-if-clean --receipt-audited <comment-id>
    python3 cone_preflight.py park ACR-12 --execute-if-clean --comment-file /path/to/ask.txt
    python3 cone_preflight.py cancel ACR-12 --execute-if-clean --related-id <uuid>
"""

import argparse
import json
import os
import re
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import linear_bridge as lb

DECISION_TYPE_LABELS = {"research", "grilling", "prototype", "task"}
TYPE_LABELS = DECISION_TYPE_LABELS | {"build"}
COMPLETED_STATE_TYPES = {"completed", "canceled"}
DEFERRAL_MARKER = "_to be set at claim_"
MANDATE_RE = re.compile(r"validation mandate:\s*`?([A-Za-z0-9_-]+)`?", re.IGNORECASE)
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
        {"id": "C1", "name": "Objective present, non-empty — full and build variants; map-child decision tickets SKIP always, including stance (research+hitl — body is the brief, not an Objective)", "home": "Script"},
        {"id": "C2", "name": "Done When concrete; deferral marker/missing -> NEEDS_INPUT routing (never silent pass) — full and build variants; map-child decision tickets SKIP EXCEPT the stance sub-rule (research+hitl): enforced, same as full/build — wayfinder law requires Done When on stance tickets, never a bare question", "home": "Script (detect); proposal-composition is Judgment"},
        {"id": "C3", "name": "Type label present; conflict cells -> refuse + NEEDS_INPUT", "home": "Script"},
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
        {"id": "M3g", "name": "Full-variant (no map parent) structural defer: receipt coherence has no downstream audit on this lane, routes to @attack-kitty ticket-close; --receipt-audited <comment-id> resumes mechanically (CONFIRMED ticket-close [VALIDATION], postdates the In Progress claim)", "home": "Script+J"},
    ],
    "resolve": [
        {"id": "R1", "name": "Guard: map child + decision-type label, else refuse to mark_done", "home": "Script"},
        {"id": "R2", "name": "research+afk: findings document exists AND resolution comment exists", "home": "Script"},
        {"id": "R3", "name": "research+hitl / grilling / prototype / task: resolution comment exists", "home": "Script"},
        {"id": "R4", "name": "Execute Done", "home": "Script"},
    ],
    "park": [
        {"id": "P1", "name": "R-A: not map-labeled; ask comment present by live fetch OR a supplied --comment-file (posted at execute, before the state change) — checkability is the composing session's own, no longer a scripted judgment call", "home": "Script"},
        {"id": "P2", "name": "Needs Input + ask comment + release delegate (read-back) + assignee untouched", "home": "Script (execute)"},
    ],
    "block": [
        {"id": "B1", "name": "R-A: not map; condition comment present by live fetch OR a supplied --comment-file (posted at execute, before the state change) — checkability is the composing session's own, no longer a scripted judgment call", "home": "Script"},
        {"id": "B2", "name": "Blocked + condition comment + release delegate", "home": "Script (execute)"},
    ],
    "un-park": [
        {"id": "U1", "name": "Blocker verifiably resolved OR operator-directed OR --blocker-verified (R-C: caller re-checked the condition itself); else refuse", "home": "Script+J"},
        {"id": "U2", "name": "-> Todo only; claim already clear else surface (never silently clear); In Progress = fresh claim, route to claim", "home": "Script"},
    ],
    "cancel": [
        {"id": "X1", "name": "Reason present by live fetch OR a supplied --comment-file (posted at execute, before the state change) -> Canceled + reason comment; optional duplicate_of relation", "home": "Script"},
    ],
    "close-map": [
        {"id": "CM1", "name": "map label + In Progress", "home": "Script"},
        {"id": "CM3", "name": "All children Done/Canceled; name each open child (id, title, state)", "home": "Script"},
        {"id": "CM5", "name": "Every Done build child has [VALIDATION] CONFIRMED (absence = data error); collect timestamps", "home": "Script"},
        {"id": "CM-a", "name": "Aggregate ALL failures into one checklist (no partial refusals)", "home": "Script (report shape)"},
        {"id": "CM6", "name": "map-conformance receipt: exists, fresh (postdates all CM5 timestamps), CONFIRMED, schema", "home": "Script"},
        {"id": "CM7", "name": "Accounting document composed from children's own receipts", "home": "Judgment"},
        {"id": "CM9", "name": "Done write with immediate re-verify of the close gates + accounting doc exists; any drift -> refuse and surface", "home": "Script (cone_preflight.py close-map --reverify, run immediately before execute's set-state)"},
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
    return max(matches, key=lambda c: c["createdAt"])


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
    ruled = []

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
            if flags.get("conductor_preflight"):
                # /implement's own pre-flight: run the build-variant checks
                # without asserting the delegated flag, which is structurally
                # false at this call site — the cone sets it only AFTER this
                # check admits.
                variant = "build"
                c7_result, c7_detail = "PASS", (
                    "build child — conductor pre-flight (checks only; the claim "
                    "itself is `@traffic-cone`'s, spawned with --delegated-preflight-passed)"
                )
            elif not flags.get("delegated_preflight_passed"):
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

    # C1/C2 — shape checks are variant-scoped: full and build variants carry
    # Objective/Done When; a map-child decision ticket's body is the brief
    # (## Question) per /linear claim.md's map-child variant law. Ruled
    # 2026-08-10 after the first live run refused a well-formed grilling child.
    #
    # Sub-rule (team-lead addendum, same date): the map-child SKIP was
    # loop-label-blind — a "stance" ticket (research + hitl together) is a
    # map-child body-shape (Question + Destination, not Objective — C1
    # stays SKIP) that ALSO carries a Done When under wayfinder law ("never
    # a bare question"), so C2 is enforced exactly like the full/build path
    # instead of skipped. Every other map-child combination (grilling,
    # task, prototype, research+afk, ...) keeps both SKIP as specced.
    objective = sections.get("Objective", "")
    is_stance = variant == "map-child" and {"research", "hitl"} <= labels
    if variant == "map-child" and not is_stance:
        checks.append(mk_check("C1", "claim", "SKIP",
                               "map-child decision ticket — body is the brief (## Question); "
                               "shape checks apply to full and build variants"))
        checks.append(mk_check("C2", "claim", "SKIP",
                               "map-child decision ticket — Done When shape not required"))
    elif is_stance:
        checks.append(mk_check("C1", "claim", "SKIP",
                               "stance ticket (research+hitl) — body carries Question + Destination, "
                               "not Objective; Objective not required"))
        dw_state, _ = done_when_state(sections)
        if dw_state == "concrete":
            checks.append(mk_check("C2", "claim", "PASS",
                                   "stance ticket — Done When carries concrete conditions "
                                   "(wayfinder law: stance tickets are never a bare question)"))
        else:
            detail = f"stance ticket — Done When {dw_state} — wayfinder law requires Done When on stance tickets; propose conditions, route to Needs Input"
            checks.append(mk_check("C2", "claim", "FAIL", detail))
            needs_input_reasons.append(detail)
    else:
        if objective:
            checks.append(mk_check("C1", "claim", "PASS", "Objective present and non-empty"))
        else:
            detail = "## Objective missing or empty"
            checks.append(mk_check("C1", "claim", "FAIL", detail))
            refuse_reasons.append(detail)

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
        ruled.append("C6")
    else:
        checks.append(mk_check("C6", "claim", "PASS", "no other In Progress ticket delegated to actor on project"))

    # C8 — model label. --model-ruled is the caller's post-ruling resume
    # attestation (pressure-test v2 Gap 1): the model already compared
    # itself to the label in a prior invocation of this same check; this
    # re-run terminates instead of deferring again.
    model_labels = [l for l in labels if l.startswith("model:")]
    if model_labels:
        facts["model_label"] = model_labels[0]
        if flags.get("model_ruled"):
            checks.append(mk_check("C8", "claim", "PASS", f"model label {model_labels[0]!r} present — ruled via --model-ruled"))
            ruled.append("C8")
        else:
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
    return checks, facts, judgment_items, verdict, ruled


# ---------------------------------------------------------------------
# mark_done
# ---------------------------------------------------------------------

def run_mark_done_checks(ctx, flags):
    checks = []
    judgment_items = []
    refuse_reasons = []
    needs_input_reasons = []
    ruled = []

    issue = ctx["issue"]
    labels = labels_of(issue)
    comments = comments_of(issue)
    sections = parse_sections(issue.get("description") or "")
    is_build = "build" in labels
    # R-B: "full variant" = no map parent. build tickets always carry a map
    # parent (claim's build variant requires it), so this is never true for
    # a build ticket, so the full-variant M3g never fires for one.
    parent = issue.get("parent")
    is_full_variant = not (parent is not None and "map" in labels_of(parent))

    facts = {
        "team_key": (issue.get("team") or {}).get("key"),
        "state_ids": ctx.get("state_ids", {}),
        "viewer_id": ctx.get("viewer_id"),
        "refusal_reasons": [],
        "idempotent": False,
    }

    checks.append(mk_check("M1", "mark_done", "PASS", "ticket and comments read directly"))

    state_type = (issue.get("state") or {}).get("type")
    already_done = state_type == "completed"

    # M3a-f's receipt is the Done-When-mandated one — never M3g's
    # ticket-close review-of-the-receipt, which is a second, parallel
    # [VALIDATION] comment judging receipt coherence itself (same exclusion
    # shape as CM6 isolating "map-conformance" from a build child's own
    # receipt at close-map).
    receipt_comment = newest_matching_comment(
        comments,
        lambda c: (c.get("body") or "").strip().startswith("[VALIDATION]")
        and not (c.get("body") or "").strip().startswith("[VALIDATION] — ticket-close"),
    )
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
        elif flags.get("mandate_type"):
            # Post-ruling resume (pressure-test v2 Gap 1): the caller already
            # ruled what the Done When text names in other words — --mandate-type
            # supplies the resolved type and this re-run matches mechanically,
            # exactly like the regex-hit branch above, instead of deferring again.
            required_type = flags["mandate_type"]
            actual_type = (receipt.get("validation_type") or "").strip()
            if actual_type == required_type:
                checks.append(mk_check("M3c", "mark_done", "PASS", f"receipt type {actual_type!r} matches ruled mandate {required_type!r} (--mandate-type)"))
                ruled.append("M3c")
            else:
                detail = f"receipt type {actual_type!r} != ruled mandate {required_type!r} (--mandate-type) — mismatch is never waved through"
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
        elif flags.get("exempt_ruled"):
            # Post-ruling resume (pressure-test v2 Gap 1): the caller already
            # ruled applicability — this re-run terminates instead of deferring.
            checks.append(mk_check("M-d", "mark_done", "PASS", "non-build exemption claimed — ruled applicable via --exempt-ruled"))
            ruled.append("M-d")
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

    # M3g — R-B's structural defer: every full-variant (no map parent)
    # mark_done run routes receipt coherence to @attack-kitty's ticket-close
    # mandate, unconditionally — map children get CM5/CM6 at close-map
    # instead, the one lane with no downstream audit otherwise. Fires
    # regardless of the M-i idempotent path (still no downstream audit for
    # an already-Done full-variant ticket). --receipt-audited <comment-id>
    # is the post-ruling resume: it must resolve to a CONFIRMED
    # ticket-close [VALIDATION] comment postdating the current In Progress
    # claim, verified mechanically — an unresolvable id refuses outright.
    if not is_full_variant:
        checks.append(mk_check("M3g", "mark_done", "SKIP", "map child — CM5/CM6 audit this at close-map, not here"))
    elif flags.get("receipt_audited"):
        audited_id = flags["receipt_audited"]
        audited_comment = next((c for c in comments if c.get("id") == audited_id), None)
        audited_parsed = parse_validation_comment(audited_comment["body"]) if audited_comment else None
        history = history_of(issue)
        in_progress_entries = [h for h in history if (h.get("toState") or {}).get("type") == "started"]
        claim_ts = max((h["createdAt"] for h in in_progress_entries), default=None)
        m3g_failures = []
        if audited_comment is None:
            m3g_failures.append(f"--receipt-audited {audited_id!r} does not resolve to a comment on this ticket")
        else:
            if not audited_parsed or (audited_parsed.get("validation_type") or "").strip() != "ticket-close":
                m3g_failures.append(f"--receipt-audited {audited_id!r} is not a ticket-close [VALIDATION] comment")
            if not audited_parsed or audited_parsed.get("verdict") != "CONFIRMED":
                m3g_failures.append(f"--receipt-audited {audited_id!r} is not Verdict: CONFIRMED")
            if not audited_parsed or not audited_parsed.get("schema_complete"):
                m3g_failures.append(f"--receipt-audited {audited_id!r} is malformed — missing schema lines")
            if claim_ts is None:
                m3g_failures.append("no In Progress transition found in history — cannot establish freshness")
            elif audited_comment and audited_comment["createdAt"] <= claim_ts:
                m3g_failures.append(f"--receipt-audited {audited_id!r} ({audited_comment['createdAt']}) predates the In Progress claim ({claim_ts})")
        if m3g_failures:
            detail = "; ".join(m3g_failures)
            checks.append(mk_check("M3g", "mark_done", "FAIL", detail))
            refuse_reasons.append(detail)
        else:
            checks.append(mk_check("M3g", "mark_done", "PASS", f"--receipt-audited {audited_id!r} verified: CONFIRMED ticket-close, postdates claim"))
            ruled.append("M3g")
    else:
        item = {
            "id": "J-M3g",
            "question": "Full-variant mark_done has no downstream audit lane — route receipt coherence to @attack-kitty's ticket-close mandate.",
            "evidence": None,
        }
        judgment_items.append(item)
        checks.append(mk_check("M3g", "mark_done", "DEFER", "full variant — no map parent, no downstream audit; structural defer per R-B"))

    facts["refusal_reasons"] = refuse_reasons + needs_input_reasons
    verdict = aggregate_verdict(refuse_reasons, needs_input_reasons, judgment_items)
    return checks, facts, judgment_items, verdict, ruled


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
        return checks, facts, [], "REFUSE", []

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
    return checks, facts, [], verdict, []


# ---------------------------------------------------------------------
# park / block / un-park / cancel
# ---------------------------------------------------------------------

def run_park_checks(ctx, flags):
    # R-A (operator, 2026-08-10): the composing session owns its ask's
    # specificity — "you composed the ask, you own it." J-P1 retires as a
    # defer; presence stays scripted via live fetch. P1 also passes when
    # the ask hasn't been posted yet but --comment-file supplies text to
    # post at execute (pressure-test v2 Gap 2) — the sequencing law posts
    # it before the state change, so no ask-less parked ticket if the
    # caller dies mid-execute.
    checks = []
    refuse_reasons = []
    issue = ctx["issue"]
    comments = comments_of(issue)
    facts = {"team_key": (issue.get("team") or {}).get("key"), "state_ids": ctx.get("state_ids", {}), "refusal_reasons": []}

    if "map" in labels_of(issue):
        detail = "maps never park — a wedged map is a sweep finding, not a park target"
        checks.append(mk_check("P1", "park", "FAIL", detail))
        refuse_reasons.append(detail)
        facts["refusal_reasons"] = refuse_reasons
        return checks, facts, [], "REFUSE", []

    ask_comment = newest_matching_comment(comments, lambda c: bool((c.get("body") or "").strip()))
    if ask_comment is not None:
        checks.append(mk_check("P1", "park", "PASS", "ask comment present by live fetch"))
    elif flags.get("comment_file"):
        checks.append(mk_check("P1", "park", "PASS", "no ask comment yet — --comment-file supplied, posted at execute"))
    else:
        detail = "no ask comment on record and no --comment-file supplied — refuse rather than invent one"
        checks.append(mk_check("P1", "park", "FAIL", detail))
        refuse_reasons.append(detail)

    facts["refusal_reasons"] = refuse_reasons
    verdict = aggregate_verdict(refuse_reasons, [], [])
    return checks, facts, [], verdict, []


def run_block_checks(ctx, flags):
    # R-A: J-B1 retires as a defer, same as park's J-P1 — checkability is no
    # longer a scripted judgment call; the composing session owns it. Ruled
    # (team-lead, oversight in the item-4 enumeration): B1 is symmetric with
    # P1/X1 — passes on live-fetch presence OR a supplied --comment-file,
    # posted at execute before the state change.
    checks = []
    refuse_reasons = []
    issue = ctx["issue"]
    comments = comments_of(issue)
    facts = {"team_key": (issue.get("team") or {}).get("key"), "state_ids": ctx.get("state_ids", {}), "refusal_reasons": []}

    if "map" in labels_of(issue):
        detail = "maps never park/block — a wedged map is a sweep finding"
        checks.append(mk_check("B1", "block", "FAIL", detail))
        refuse_reasons.append(detail)
        facts["refusal_reasons"] = refuse_reasons
        return checks, facts, [], "REFUSE", []

    condition_comment = newest_matching_comment(comments, lambda c: bool((c.get("body") or "").strip()))
    if condition_comment is not None:
        checks.append(mk_check("B1", "block", "PASS", "condition comment present by live fetch"))
    elif flags.get("comment_file"):
        checks.append(mk_check("B1", "block", "PASS", "no condition comment yet — --comment-file supplied, posted at execute"))
    else:
        detail = "no condition comment on record and no --comment-file supplied — refuse rather than invent one"
        checks.append(mk_check("B1", "block", "FAIL", detail))
        refuse_reasons.append(detail)

    facts["refusal_reasons"] = refuse_reasons
    verdict = aggregate_verdict(refuse_reasons, [], [])
    return checks, facts, [], verdict, []


def run_unpark_checks(ctx, flags):
    checks = []
    refuse_reasons = []
    judgment_items = []
    ruled = []
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
        return checks, facts, [], "REFUSE", []

    if flags.get("operator_directed"):
        checks.append(mk_check("U1", "un-park", "PASS", "operator directed the un-park explicitly"))
    else:
        condition_comment = newest_matching_comment(comments, lambda c: bool((c.get("body") or "").strip()))
        if condition_comment is None:
            detail = "no blocker condition on record and no --operator-directed — refuse"
            checks.append(mk_check("U1", "un-park", "FAIL", detail))
            refuse_reasons.append(detail)
        elif flags.get("blocker_verified"):
            # R-C (operator, 2026-08-10): un-parking session re-checks the
            # condition itself — self-knowledge, ADMIT path alongside
            # --operator-directed, no defer.
            checks.append(mk_check("U1", "un-park", "PASS", "blocker condition re-checked by the caller — --blocker-verified"))
            ruled.append("U1")
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
    return checks, facts, judgment_items, verdict, ruled


def run_cancel_checks(ctx, flags):
    # Item 4 (pressure-test v2 Gap 2): X1 passes when the reason comment
    # exists by live fetch OR --comment-file supplies text to post at
    # execute (sequencing law: comment before the state change).
    checks = []
    refuse_reasons = []
    issue = ctx["issue"]
    comments = comments_of(issue)
    facts = {"team_key": (issue.get("team") or {}).get("key"), "state_ids": ctx.get("state_ids", {}), "refusal_reasons": []}

    reason_comment = newest_matching_comment(comments, lambda c: bool((c.get("body") or "").strip()))
    if reason_comment is not None:
        checks.append(mk_check("X1", "cancel", "PASS", "reason present by live fetch"))
    elif flags.get("comment_file"):
        checks.append(mk_check("X1", "cancel", "PASS", "no reason on record — --comment-file supplied, posted at execute"))
    else:
        detail = "no reason given and no --comment-file supplied — refuse"
        checks.append(mk_check("X1", "cancel", "FAIL", detail))
        refuse_reasons.append(detail)

    facts["refusal_reasons"] = refuse_reasons
    verdict = aggregate_verdict(refuse_reasons, [], [])
    return checks, facts, [], verdict, []


# ---------------------------------------------------------------------
# close-map
# ---------------------------------------------------------------------

def _cm_gates_123(issue, children):
    """CM1 (map label + In Progress), CM3 (zero
    open children) — shared between initial admission (run_close_map_checks)
    and the CM9 re-verify (run_close_map_reverify_checks)."""
    checks = []
    refuse_reasons = []
    labels = labels_of(issue)
    open_children_identifiers = []

    if "map" not in labels or (issue.get("state") or {}).get("type") != "started":
        detail = f"not a map In Progress (labels={sorted(labels)}, state={issue.get('state')})"
        checks.append(mk_check("CM1", "close-map", "FAIL", detail))
        refuse_reasons.append(detail)
    else:
        checks.append(mk_check("CM1", "close-map", "PASS", "map label + In Progress"))

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
        "open_children": [],
        "done_children": [],
    }

    checks, refuse_reasons, open_children = _cm_gates_123(issue, children)
    facts["open_children"] = open_children

    cm5_check, cm5_failures, done_children_facts, latest_validation_ts = _cm_gate_5(children, children_comments)
    checks.append(cm5_check)
    refuse_reasons.extend(cm5_failures)
    facts["done_children"] = done_children_facts

    checks.append(mk_check("CM-a", "close-map", "PASS" if not refuse_reasons else "FAIL",
                            "all Step-1 checks aggregated — no partial refusals" if not refuse_reasons else "one or more Step-1 checks failed; aggregated above, no partial execution"))

    if refuse_reasons:
        checks.append(mk_check("CM6", "close-map", "SKIP", "Step 1 preconditions failed — CM6 not evaluated"))
        facts["refusal_reasons"] = refuse_reasons
        return checks, facts, [], "REFUSE", []

    cm6_check, cm6_failures = _cm_gate_6(comments, latest_validation_ts)
    checks.append(cm6_check)
    refuse_reasons.extend(cm6_failures)

    facts["refusal_reasons"] = refuse_reasons
    verdict = aggregate_verdict(refuse_reasons, [], [])
    return checks, facts, [], verdict, []


def run_close_map_reverify_checks(ctx, accounting_document_id):
    """CM9 — the scripted re-verify path, run immediately before the
    execute step's set-state. Re-checks CM1/CM3/CM5/CM6 fresh (a
    reopened child, a build child's receipt disappearing, the
    map-conformance receipt) plus the one artifact the execute step just
    produced: the accounting document exists — the gates close-map.md
    Step 5 names. Any drift on any gate refuses; this never mutates — the
    caller only proceeds to `set-state` on ADMIT."""
    issue = ctx["issue"]
    comments = comments_of(issue)
    children = ctx.get("children") or []
    children_comments = ctx.get("children_comments") or {}
    documents = ctx.get("documents") or []

    facts = {
        "team_key": (issue.get("team") or {}).get("key"),
        "state_ids": ctx.get("state_ids", {}),
        "refusal_reasons": [],
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

    all_failures = refuse_reasons + cm9_failures
    if all_failures:
        detail = "; ".join(all_failures)
        checks.append(mk_check("CM9", "close-map", "FAIL", detail))
        facts["refusal_reasons"] = all_failures
        return checks, facts, [], "REFUSE"

    checks.append(mk_check("CM9", "close-map", "PASS", "all close gates + accounting doc re-verified clean immediately before the write"))
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
    checks, facts, judgment_items, verdict, ruled = VERB_RUNNERS[verb](ctx, flags)
    issue = ctx["issue"]
    return {
        "verb": verb,
        "target": issue.get("identifier"),
        "uuid": issue.get("id"),
        "verdict": verdict,
        "checks": checks,
        "facts": facts,
        "judgment_items": judgment_items,
        # Post-ruling resume (pressure-test v2 Gap 1): the assertion flags
        # (--model-ruled, --exempt-ruled, --mandate-type, --caller-ack-wip,
        # --blocker-verified, --receipt-audited) that actually cleared a
        # would-be DEFER this run, named by their check id, for the audit
        # trail. Empty unless a ruled re-run supplied one.
        "ruled": ruled,
    }


def run_close_map_reverify(ctx, accounting_document_id):
    """CLI-facing wrapper around run_close_map_reverify_checks — same output
    contract shape as run_checks, so the card's Step 5 can invoke this
    exactly like any other verb call."""
    checks, facts, judgment_items, verdict = run_close_map_reverify_checks(
        ctx, accounting_document_id
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
        "ruled": [],
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
        "mark_done": ["Done", "Needs Input"],
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
# --execute-if-clean — checks -> execute -> read-back, one process.
#
# Fused only for claim, resolve, mark_done, park, block, un-park, cancel
# (close-map keeps its own staged --reverify shape; main() refuses the
# combination outright). Dispatch:
#   verdict REFUSE or JUDGMENT_REQUIRED -> stop, executed=False, no bridge
#     calls at all.
#   verdict ADMIT -> execute the verb's "success" mutation, executed=True
#     (claim's lost-race is the one exception: executed=False even though a
#     write happened, since this session's claim was not achieved).
#   verdict NEEDS_INPUT (claim's C2/C3) -> executes its own routing
#     mutation, executed=True.
# Sequencing law (F2): a comment-bearing execute posts the comment BEFORE
# the state change — no ask-less parked/blocked/canceled ticket if the
# caller dies mid-execute.
# ---------------------------------------------------------------------

EXECUTABLE_VERBS = {"claim", "mark_done", "resolve", "park", "block", "un-park", "cancel"}


def _read_text_file(path):
    """Read a caller-composed comment file. A missing/unreadable file is a
    config gap, not a script bug — reuses linear_bridge's own exception
    class so main()'s existing handler maps it to EXIT_CONFIG_GAP."""
    try:
        with open(path, "r", encoding="utf-8") as f:
            return f.read()
    except OSError as e:
        raise lb.BridgeConfigError(f"failed to read comment file {path!r}: {e}") from e


def _execute_claim(bridge_cmd_parts, verdict, uuid, facts, state_ids, args):
    if verdict == "ADMIT":
        assignee_id = facts.get("operator_id") if facts.get("assignee_gate") == "set" else None
        result = lb.claim_write(bridge_cmd_parts, uuid, state_ids.get("in_progress"), facts.get("viewer_id"), assignee_id)
        # A lost race means back off and report, never proceed (claim.md) —
        # a write happened, but this session's claim was not achieved.
        return (not result.get("race_lost", False)), {"claim_write": result}

    # NEEDS_INPUT (C2/C3): a routing/proposed-conditions comment is
    # integral to this execution, not optional — no delegate release (no
    # claim exists yet, the ticket was never claimed).
    if not args.comment_file:
        return False, {"note": "NEEDS_INPUT routing comment required — no --comment-file supplied"}
    body = _read_text_file(args.comment_file)
    comment_result = lb.create_comment(bridge_cmd_parts, uuid, body)
    state_result = lb.set_state(bridge_cmd_parts, uuid, state_ids.get("needs_input"))
    return True, {"comment": comment_result, "set_state": state_result}


def _execute_mark_done(bridge_cmd_parts, verdict, uuid, facts, state_ids, args):
    if verdict == "ADMIT":
        if facts.get("idempotent"):
            return True, {"note": "already Done with a valid receipt — no re-transition"}
        result = {}
        if args.closing_comment_file:
            body = _read_text_file(args.closing_comment_file)
            result["comment"] = lb.create_comment(bridge_cmd_parts, uuid, body)
        result["set_state"] = lb.set_state(bridge_cmd_parts, uuid, state_ids.get("done"))
        return True, result

    # NEEDS_INPUT: set-state only, no delegate ops.
    result = {"set_state": lb.set_state(bridge_cmd_parts, uuid, state_ids.get("needs_input"))}
    return True, result


def _execute_resolve(bridge_cmd_parts, verdict, uuid, state_ids):
    if verdict != "ADMIT":
        return False, {}
    result = lb.set_state(bridge_cmd_parts, uuid, state_ids.get("done"))
    return True, {"set_state": result}


def _execute_park_or_block(bridge_cmd_parts, verdict, uuid, ctx, state_id, comment_file):
    """Shared park/block execute shape: post the ask/condition comment
    (already present by live fetch, or supplied fresh via --comment-file)
    BEFORE the state change, then release the delegate — read-back
    verified — leaving assignee untouched."""
    if verdict != "ADMIT":
        return False, {}
    comments = comments_of(ctx["issue"])
    existing = newest_matching_comment(comments, lambda c: bool((c.get("body") or "").strip()))
    result = {}
    if existing is None:
        if not comment_file:
            return False, {"note": "no ask/condition on record and no --comment-file supplied"}
        body = _read_text_file(comment_file)
        result["comment"] = lb.create_comment(bridge_cmd_parts, uuid, body)
    result["set_state"] = lb.set_state(bridge_cmd_parts, uuid, state_id)
    result["release_delegate"] = lb.release_delegate(bridge_cmd_parts, uuid)
    return True, result


def _execute_unpark(bridge_cmd_parts, verdict, uuid, state_ids):
    if verdict != "ADMIT":
        return False, {}
    result = lb.set_state(bridge_cmd_parts, uuid, state_ids.get("todo"))
    # Never clear delegate — U2 already surfaced it if present; this never
    # silently clears it.
    return True, {"set_state": result}


def _execute_cancel(bridge_cmd_parts, verdict, uuid, ctx, state_ids, comment_file, related_id):
    if verdict != "ADMIT":
        return False, {}
    comments = comments_of(ctx["issue"])
    existing = newest_matching_comment(comments, lambda c: bool((c.get("body") or "").strip()))
    result = {}
    if existing is None:
        if not comment_file:
            return False, {"note": "no reason on record and no --comment-file supplied"}
        body = _read_text_file(comment_file)
        result["comment"] = lb.create_comment(bridge_cmd_parts, uuid, body)
    result["set_state"] = lb.set_state(bridge_cmd_parts, uuid, state_ids.get("canceled"))
    if related_id:
        result["create_relation"] = lb.create_relation(bridge_cmd_parts, uuid, related_id, "duplicate_of")
    return True, result


def execute_if_clean(bridge_cmd_parts, verb, report, ctx, args):
    """Dispatch --execute-if-clean's execute step by verb. Returns
    (executed: bool, execution: dict|None). Never called for close-map —
    main() refuses that combination before reaching here."""
    verdict = report["verdict"]
    uuid = report["uuid"]
    facts = report["facts"]
    state_ids = facts.get("state_ids", {})

    if verdict not in ("ADMIT", "NEEDS_INPUT"):
        return False, None

    if verb == "claim":
        return _execute_claim(bridge_cmd_parts, verdict, uuid, facts, state_ids, args)
    if verb == "mark_done":
        return _execute_mark_done(bridge_cmd_parts, verdict, uuid, facts, state_ids, args)
    if verdict != "ADMIT":
        # resolve/park/block/un-park/cancel never reach NEEDS_INPUT per
        # their Check Inventory — nothing left to execute.
        return False, None
    if verb == "resolve":
        return _execute_resolve(bridge_cmd_parts, verdict, uuid, state_ids)
    if verb == "park":
        return _execute_park_or_block(bridge_cmd_parts, verdict, uuid, ctx, state_ids.get("needs_input"), args.comment_file)
    if verb == "block":
        return _execute_park_or_block(bridge_cmd_parts, verdict, uuid, ctx, state_ids.get("blocked"), args.comment_file)
    if verb == "un-park":
        return _execute_unpark(bridge_cmd_parts, verdict, uuid, state_ids)
    if verb == "cancel":
        return _execute_cancel(bridge_cmd_parts, verdict, uuid, ctx, state_ids, args.comment_file, args.related_id)
    return False, None


def format_output(report, executed_if_clean, executed, execution, elapsed_ms):
    """Window-priced output (item 3): only shapes --execute-if-clean runs —
    a plain check-only call keeps the full report dict unchanged. On ADMIT,
    the default is a compact verdict block (verdict, executed, elapsed_ms,
    ruled, and the execution result — the facts that matter post-execution
    are the mutation's own read-back, not the pre-execution check facts);
    full check arrays and facts dumps print only on non-ADMIT, where the
    caller needs the detail to fix a refusal or rule on a defer. Exact
    field selection is this implementation's own choice where the spec
    names the behavior but not the literal shape — see DEVIATIONS."""
    if not executed_if_clean:
        return report

    base = {
        "verb": report["verb"],
        "target": report["target"],
        "uuid": report["uuid"],
        "verdict": report["verdict"],
        "executed": executed,
        "elapsed_ms": elapsed_ms,
    }
    if report.get("ruled"):
        base["ruled"] = report["ruled"]
    if execution:
        base["result"] = execution

    if report["verdict"] == "ADMIT":
        return base

    base["checks"] = report["checks"]
    base["facts"] = report["facts"]
    base["judgment_items"] = report["judgment_items"]
    return base


# ---------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------

def print_list_checks(verb):
    rows = CHECK_INVENTORY[verb] + CROSS_CUTTING
    print(json.dumps({"verb": verb, "checks": rows}, indent=2))


def main(argv=None):
    parser = argparse.ArgumentParser(
        description="Traffic-cone per-verb admission checks. Never mutates by default; "
                     "--execute-if-clean fuses execution in-process on a clean ADMIT/NEEDS_INPUT verdict."
    )
    parser.add_argument("verb", nargs="?", choices=VERBS)
    parser.add_argument("target", nargs="?", default=None)
    parser.add_argument("--list-checks", metavar="VERB", choices=VERBS, default=None)
    parser.add_argument("--bridge-cmd", default=None)
    parser.add_argument("--operator-directed", action="store_true")
    parser.add_argument("--autonomous", action="store_true")
    parser.add_argument("--caller-ack-wip", action="store_true")
    parser.add_argument("--delegated-preflight-passed", action="store_true")
    parser.add_argument("--conductor-preflight", action="store_true",
                        help="/implement's own pre-flight on a build child: run the "
                             "build-variant checks without asserting the delegated flag "
                             "(checks only — the claim itself stays traffic-cone's)")
    parser.add_argument("--deterministic-exempt", action="store_true")
    parser.add_argument("--deterministic-exempt-context", default="")
    parser.add_argument("--project-id", default=None,
                         help="required for claim — absent it, refuses with a config-gap message "
                              "(without it wip_check never runs and C6 would auto-pass unchecked).")
    parser.add_argument("--reverify", action="store_true",
                         help="close-map only: CM9's scripted re-verify, run immediately before set-state.")
    parser.add_argument("--accounting-document-id", default=None,
                         help="close-map --reverify: the document id the execute step's createDocument just returned.")
    parser.add_argument("--execute-if-clean", action="store_true",
                         help="Fused mode: checks -> execute -> read-back in one process. "
                              "ADMIT (zero judgment items) executes; REFUSE/JUDGMENT_REQUIRED stop. "
                              "Not valid for close-map (keeps its own --reverify shape).")
    parser.add_argument("--model-ruled", action="store_true",
                         help="Post-ruling resume for J-C8: the session already compared itself to a model:* label.")
    parser.add_argument("--exempt-ruled", action="store_true",
                         help="Post-ruling resume for J-M-d: the non-build deterministic exemption's applicability was already ruled.")
    parser.add_argument("--mandate-type", default=None,
                         help="Post-ruling resume for J-M3c: the type the caller already ruled the Done When text names.")
    parser.add_argument("--blocker-verified", action="store_true",
                         help="R-C: the un-parking session re-checked the named blocker condition itself.")
    parser.add_argument("--receipt-audited", default=None, metavar="COMMENT-ID",
                         help="Post-ruling resume for M3g: a CONFIRMED ticket-close [VALIDATION] comment id, "
                              "verified mechanically (postdates the In Progress claim).")
    parser.add_argument("--comment-file", default=None,
                         help="Caller-composed ask/reason/routing text to post at execute when none exists yet "
                              "(claim's NEEDS_INPUT routing, park's ask, cancel's reason).")
    parser.add_argument("--closing-comment-file", default=None,
                         help="mark_done only: optional closing note posted before the Done transition.")
    parser.add_argument("--related-id", default=None,
                         help="cancel only, optional: duplicate_of relation target (UUID).")
    args = parser.parse_args(argv)

    if args.list_checks:
        print_list_checks(args.list_checks)
        return lb.EXIT_OK

    if not args.verb or not args.target:
        parser.error("verb and target are required unless --list-checks is given")

    if args.reverify and args.verb != "close-map":
        parser.error("--reverify is close-map only")

    if args.execute_if_clean and args.verb == "close-map":
        parser.error("--execute-if-clean does not apply to close-map — it keeps its own staged --reverify shape")

    if args.verb == "claim" and not args.project_id:
        print(
            "ERROR (config gap): --project-id is required for claim — resolve the project's id "
            "(CLAUDE.md > Configuration) and pass --project-id. Absent it, wip_check never runs "
            "and C6 would auto-pass unchecked.",
            file=sys.stderr,
        )
        return lb.EXIT_CONFIG_GAP

    flags = {
        "operator_directed": args.operator_directed,
        "autonomous": args.autonomous,
        "caller_ack_wip": args.caller_ack_wip,
        "delegated_preflight_passed": args.delegated_preflight_passed,
        "conductor_preflight": args.conductor_preflight,
        "deterministic_exempt": args.deterministic_exempt,
        "deterministic_exempt_context": args.deterministic_exempt_context,
        "project_id": args.project_id,
        "model_ruled": args.model_ruled,
        "exempt_ruled": args.exempt_ruled,
        "mandate_type": args.mandate_type,
        "blocker_verified": args.blocker_verified,
        "receipt_audited": args.receipt_audited,
        "comment_file": args.comment_file,
    }

    start = time.monotonic()
    try:
        bridge_cmd_parts = lb.resolve_bridge_cmd(args.bridge_cmd)
        ctx = gather_context(bridge_cmd_parts, args.verb, args.target, flags)
        if args.reverify:
            report = run_close_map_reverify(ctx, args.accounting_document_id)
        else:
            report = run_checks(args.verb, ctx, flags)

        executed, execution = (False, None)
        if args.execute_if_clean and args.verb in EXECUTABLE_VERBS:
            executed, execution = execute_if_clean(bridge_cmd_parts, args.verb, report, ctx, args)

        elapsed_ms = int((time.monotonic() - start) * 1000)
        output = format_output(report, args.execute_if_clean, executed, execution, elapsed_ms)
        # Window-priced (item 3): the compact ADMIT block prints without
        # indentation — pretty-printing a "compact verdict block" would
        # spend back exactly the tokens the contraction is meant to save.
        # Every other shape (plain check-only runs, non-ADMIT full detail)
        # keeps indent=2 for human/model readability.
        compact = args.execute_if_clean and report["verdict"] == "ADMIT"
        print(json.dumps(output) if compact else json.dumps(output, indent=2))
        return lb.EXIT_OK
    except lb.BridgeConfigError as e:
        print(f"ERROR (config gap): {e}", file=sys.stderr)
        return lb.EXIT_CONFIG_GAP
    except lb.BridgeAuthError as e:
        print(f"ERROR (auth failure): {e}", file=sys.stderr)
        return lb.EXIT_AUTH
    except lb.LintViolationError as e:
        print(f"ERROR (lint violation): {e}", file=sys.stderr)
        return lb.EXIT_LINT_VIOLATION
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
