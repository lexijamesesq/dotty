#!/usr/bin/env python3
"""
map_sweep.py — read-only map + frontier sweep mechanics for wayfinder's
work-through step 1, and (via --frontier-only) /linear's frontier.md
Map-frontier query. Never mutates.

This script never talks to Linear directly — every fetch goes through
linear_bridge.py (imported, not shelled out), per that module's transport,
retry, and error-class discipline. Two beats, same split cone_preflight.py
established: `gather_context()` does the live fetching and returns a plain
dict; `compute_sweep()` is a pure function over that dict, so its detection
logic is unit-tested against hand-built fixtures rather than a scripted
bridge-response sequence (test_map_sweep.py's ComputeSweepTests) — the live
wiring itself gets its own, smaller stub-bridge integration coverage.

Output — one JSON object to stdout:

    {
      "map": {identifier, uuid, title, state, body_sections_present[]},
      "children": [{identifier, title, state, type_label, loop_label,
                     delegate_set, assignee_set, updatedAt}, ...],
      "frontier": [{identifier, title, type_label, priority, createdAt}, ...],
      "frontier_rule": "<string naming the ordering rule — no session
                          re-derives it>",
      "open_challenges": [{comment_id, excerpt}, ...],
      "orphaned_research": [{identifier, findings_doc_id,
                              resolution_comment_id}, ...],
      "parked": [{identifier, title, ask_excerpt}, ...],
      "blocked": [{identifier, title, condition_excerpt}, ...],
      "stale_claims": [{identifier, title, updatedAt, days_stale}, ...],
      "decisions_missing": [{identifier, title,
                              resolution_comment_text}, ...],
      "last_resolved": {identifier, title,
                         handoff: {present, text}} | None,
      "charter_state": "absent" | "present" | "finalized",
      "ending_due": bool,
      "wedged": {"bool": bool, "reason": str | None}
    }

Frontier comparator (operator-ruled, 2026-08-10): Linear priority values
1=Urgent .. 4=Low sort ascending (Urgent first); 0/no-priority sorts LAST —
an unprioritized ticket never outranks a prioritized one. Tie -> `createdAt`
ascending (oldest first). Same rule /linear's frontier.md Ordering line
names; frontier.md's Map-frontier section invokes this script's
`--frontier-only` mode instead of hand-running the query.

Pinned detection rules (no guessing at runtime):
  - `[CHALLENGE]` is open when no comment created LATER begins
    `[CHALLENGE-RESOLVED]` — a temporal rule, not 1:1 pairing. The bridge's
    comment fetch carries no threading, so this is a codification of
    wayfinder's "reply" prose into a checkable form.
  - `stale_claims` activity = the issue's own `updatedAt` (any activity
    counts) — deliberately a DIFFERENT field from `last_resolved`, which
    uses `completedAt` (never `updatedAt`, which drifts on any later
    comment). Correct for staleness, wrong for "when did this actually
    finish" — the two fields serve different questions by design.
  - `charter_state`: no live (non-archived) document on the map -> absent;
    a live document exists but none carries the FINALIZED marker ->
    present; a live document carries the marker -> finalized. This
    three-way reading is this script's own smallest-reasonable choice
    where the spec names the three states without pinning "present"'s
    exact test (see the implementation report's DEVIATIONS entry).
  - `decisions_missing`: a Done child is "missing" when its identifier
    string does not appear anywhere in the map body's Decisions-so-far
    section text. Linear issue URLs embed the identifier as a path
    segment, so a normal `[<title>](<url>)` entry satisfies this without
    needing the issue's own `url` field (children-full doesn't fetch it —
    out of the spec's named field list for that subcommand).

Pagination: refuse-on-incomplete-page — inherited from
`linear_bridge.fetch_children_full`'s own guard (archive-sweep.py
precedent); this script does no paging of its own.

Usage:
    python3 map_sweep.py <map-id> [--stale-days N] [--frontier-only]
        [--bridge-cmd CMD]
    LINEAR_GQL_CMD=/path/to/bridge python3 map_sweep.py ACR-1

Exit codes: mirrors linear_bridge.py's transport codes (1/2/3/4/5) — this
script's own logic never fails destructively beyond those.
"""

import argparse
import json
import os
import re
import sys
from datetime import datetime, timezone

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import linear_bridge as lb  # noqa: E402


# --------------------------------------------------------------------------
# Constants
# --------------------------------------------------------------------------

DECISION_TYPE_LABELS = {"research", "prototype", "grilling", "task"}
TYPE_LABELS = DECISION_TYPE_LABELS | {"build"}
LOOP_LABELS = {"hitl", "afk"}
COMPLETED_STATE_TYPES = {"completed", "canceled"}
FINALIZED_MARKER = "**FINALIZED**"
MAP_SECTION_ORDER = ["Destination", "Notes", "Decisions so far", "Not yet specified", "Out of scope"]
SECTION_RE = re.compile(r"^##\s+(.+?)\s*$", re.MULTILINE)
EXCERPT_LIMIT = 200

FRONTIER_RULE = (
    "Todo, unblocked, delegate null, assignee null — priority ascending "
    "(Urgent=1 first .. Low=4 last-among-prioritized; 0/no-priority sorts "
    "after every prioritized ticket), tie-break createdAt ascending "
    "(oldest first). /linear frontier.md Map-frontier rule."
)


# --------------------------------------------------------------------------
# Small local helpers (deliberately not imported from cone_preflight.py —
# this script's only import is linear_bridge, per its read-only,
# stdlib-only contract)
# --------------------------------------------------------------------------

def parse_sections(description):
    """Split a ticket/map description into {heading: body} by `## Heading`
    lines. Duplicated from cone_preflight.py's own helper of the same name
    rather than imported — map_sweep.py imports linear_bridge only."""
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


def type_label_of(labels):
    hits = labels & TYPE_LABELS
    return next(iter(hits)) if len(hits) == 1 else "none"


def loop_label_of(labels):
    hits = labels & LOOP_LABELS
    return next(iter(hits)) if len(hits) == 1 else None


def excerpt(text, limit=EXCERPT_LIMIT):
    if not text:
        return text
    t = text.strip()
    return t if len(t) <= limit else t[:limit].rstrip() + "…"


def newest_nonempty_comment(comments):
    matches = [c for c in (comments or []) if (c.get("body") or "").strip()]
    if not matches:
        return None
    return sorted(matches, key=lambda c: c["createdAt"])[-1]


def parse_dt(value):
    v = value.strip()
    if v.endswith("Z"):
        v = v[:-1] + "+00:00"
    dt = datetime.fromisoformat(v)
    if dt.tzinfo is None:
        dt = dt.replace(tzinfo=timezone.utc)
    return dt.astimezone(timezone.utc)


def priority_sort_key(priority):
    """0 and None both mean 'no priority' in Linear's model — both sort
    after every real priority value (1=Urgent .. 4=Low), never before."""
    if not priority:
        return 5
    return priority


def find_open_markers(comments, open_prefix, close_prefix):
    """Every `open_prefix`-led comment with no `close_prefix`-led comment
    created LATER than it — a temporal rule, not 1:1 pairing (see module
    docstring's Pinned detection rules)."""
    comments = comments or []
    opens = sorted(
        (c for c in comments if (c.get("body") or "").strip().startswith(open_prefix)),
        key=lambda c: c["createdAt"],
    )
    closes = sorted(
        (c for c in comments if (c.get("body") or "").strip().startswith(close_prefix)),
        key=lambda c: c["createdAt"],
    )
    out = []
    for op in opens:
        if not any(cl["createdAt"] > op["createdAt"] for cl in closes):
            out.append({"comment_id": op.get("id"), "excerpt": excerpt(op.get("body"))})
    return out


def charter_state_of(documents):
    """absent (no live document) -> present (a live document, no FINALIZED
    marker) -> finalized (a live document carries it). See module
    docstring's Pinned detection rules for the smallest-reasonable-choice
    note on 'present'."""
    live_docs = [d for d in (documents or []) if not d.get("archivedAt")]
    if not live_docs:
        return "absent"
    for doc in live_docs:
        if FINALIZED_MARKER in (doc.get("content") or ""):
            return "finalized"
    return "present"


# --------------------------------------------------------------------------
# compute_frontier — shared by the full sweep and --frontier-only
# --------------------------------------------------------------------------

def compute_frontier(children):
    frontier = []
    for c in children or []:
        state_type = (c.get("state") or {}).get("type")
        if state_type != "unstarted":
            continue
        if c.get("blocked_by_open"):
            continue
        if c.get("delegate"):
            continue
        if c.get("assignee"):
            continue
        frontier.append({
            "identifier": c.get("identifier"),
            "title": c.get("title"),
            "type_label": type_label_of(labels_of(c)),
            "priority": c.get("priority"),
            "createdAt": c.get("createdAt"),
        })
    frontier.sort(key=lambda t: (priority_sort_key(t.get("priority")), t.get("createdAt") or ""))
    return frontier


# --------------------------------------------------------------------------
# compute_sweep — pure function; ctx is fully assembled, no network calls
# --------------------------------------------------------------------------

def compute_sweep(ctx, stale_days=7.0, now=None):
    if now is None:
        now = datetime.now(timezone.utc)
    elif isinstance(now, str):
        now = parse_dt(now)

    map_issue = ctx["map_issue"]
    map_documents = ctx.get("map_documents") or []
    children = ctx.get("children") or []
    child_comments = ctx.get("child_comments") or {}
    child_documents = ctx.get("child_documents") or {}

    sections = parse_sections(map_issue.get("description") or "")
    body_sections_present = [s for s in MAP_SECTION_ORDER if s in sections]
    decisions_text = sections.get("Decisions so far", "")

    map_obj = {
        "identifier": map_issue.get("identifier"),
        "uuid": map_issue.get("id"),
        "title": map_issue.get("title"),
        "state": map_issue.get("state"),
        "body_sections_present": body_sections_present,
    }

    children_out = []
    for c in children:
        labels = labels_of(c)
        children_out.append({
            "identifier": c.get("identifier"),
            "title": c.get("title"),
            "state": c.get("state"),
            "type_label": type_label_of(labels),
            "loop_label": loop_label_of(labels),
            "delegate_set": bool(c.get("delegate")),
            "assignee_set": bool(c.get("assignee")),
            "updatedAt": c.get("updatedAt"),
        })

    frontier = compute_frontier(children)

    open_challenges = find_open_markers(comments_of(map_issue), "[CHALLENGE]", "[CHALLENGE-RESOLVED]")

    done_children = [c for c in children if (c.get("state") or {}).get("type") in COMPLETED_STATE_TYPES]

    missing_done = [c for c in done_children if c.get("identifier") and c["identifier"] not in decisions_text]
    decisions_missing = []
    for c in missing_done:
        resolution = newest_nonempty_comment(child_comments.get(c["id"], []))
        decisions_missing.append({
            "identifier": c.get("identifier"),
            "title": c.get("title"),
            "resolution_comment_text": resolution.get("body") if resolution else None,
        })

    orphaned_research = []
    for c in children:
        state_type = (c.get("state") or {}).get("type")
        if state_type in COMPLETED_STATE_TYPES:
            continue
        if "research" not in labels_of(c):
            continue
        docs = child_documents.get(c["id"], [])
        comments = child_comments.get(c["id"], [])
        resolution = newest_nonempty_comment(comments)
        if docs and resolution:
            orphaned_research.append({
                "identifier": c.get("identifier"),
                "findings_doc_id": docs[0].get("id"),
                "resolution_comment_id": resolution.get("id"),
            })

    parked, blocked = [], []
    for c in children:
        state_name = (c.get("state") or {}).get("name")
        if state_name not in ("Needs Input", "Blocked"):
            continue
        comment = newest_nonempty_comment(child_comments.get(c["id"], []))
        entry = {"identifier": c.get("identifier"), "title": c.get("title")}
        if state_name == "Needs Input":
            entry["ask_excerpt"] = excerpt(comment.get("body")) if comment else None
            parked.append(entry)
        else:
            entry["condition_excerpt"] = excerpt(comment.get("body")) if comment else None
            blocked.append(entry)

    stale_claims = []
    for c in children:
        if not c.get("delegate"):
            continue
        updated = c.get("updatedAt")
        if not updated:
            continue
        days_since = (now - parse_dt(updated)).total_seconds() / 86400.0
        if days_since >= stale_days:
            stale_claims.append({
                "identifier": c.get("identifier"),
                "title": c.get("title"),
                "updatedAt": updated,
                "days_stale": round(days_since, 1),
            })

    last_resolved = None
    completed_done = [c for c in done_children if c.get("completedAt")]
    if completed_done:
        newest = max(completed_done, key=lambda c: c["completedAt"])
        comments = sorted(child_comments.get(newest["id"], []), key=lambda c: c["createdAt"], reverse=True)
        handoff_comment = next(
            (cm for cm in comments if (cm.get("body") or "").strip().startswith("[HANDOFF]")),
            None,
        )
        last_resolved = {
            "identifier": newest.get("identifier"),
            "title": newest.get("title"),
            "handoff": {
                "present": handoff_comment is not None,
                "text": handoff_comment.get("body") if handoff_comment else None,
            },
        }

    charter_state = charter_state_of(map_documents)

    wedged_reasons = []
    if not frontier:
        if parked:
            wedged_reasons.append(f"{len(parked)} parked ticket(s): {', '.join(p['identifier'] for p in parked)}")
        if blocked:
            wedged_reasons.append(f"{len(blocked)} blocked ticket(s): {', '.join(b['identifier'] for b in blocked)}")
    wedged = {"bool": bool(wedged_reasons), "reason": "; ".join(wedged_reasons) if wedged_reasons else None}

    all_children_closed = bool(children) and all(
        (c.get("state") or {}).get("type") in COMPLETED_STATE_TYPES for c in children
    )
    ending_due = (not frontier) and all_children_closed and charter_state == "finalized"

    return {
        "map": map_obj,
        "children": children_out,
        "frontier": frontier,
        "frontier_rule": FRONTIER_RULE,
        "open_challenges": open_challenges,
        "orphaned_research": orphaned_research,
        "parked": parked,
        "blocked": blocked,
        "stale_claims": stale_claims,
        "decisions_missing": decisions_missing,
        "last_resolved": last_resolved,
        "charter_state": charter_state,
        "ending_due": ending_due,
        "wedged": wedged,
    }


# --------------------------------------------------------------------------
# gather_context — the only network-touching function
# --------------------------------------------------------------------------

def gather_context(bridge_cmd_parts, map_id):
    """Live fetch, assembled into the dict compute_sweep() consumes. Fetches
    comments/documents only for children a detection class actually needs
    them for (open research children, Done children missing from
    Decisions-so-far, the single most-recently-completed Done child, parked
    children, blocked children) — never every child, and never the map body
    twice. Candidate ids are collected into an order-preserving list (not a
    set) so a scripted bridge-response sequence in a test is deterministic."""
    map_node = lb.resolve_issue_ref(bridge_cmd_parts, map_id, body=True, comments=True)
    map_uuid = map_node["id"]
    map_documents = lb.fetch_documents(bridge_cmd_parts, map_uuid, content=True)
    children = lb.fetch_children_full(bridge_cmd_parts, map_uuid)

    sections = parse_sections(map_node.get("description") or "")
    decisions_text = sections.get("Decisions so far", "")

    done_children = [c for c in children if (c.get("state") or {}).get("type") in COMPLETED_STATE_TYPES]
    missing_done = [c for c in done_children if c.get("identifier") and c["identifier"] not in decisions_text]
    completed_done = [c for c in done_children if c.get("completedAt")]
    newest_done = max(completed_done, key=lambda c: c["completedAt"]) if completed_done else None
    open_research = [
        c for c in children
        if (c.get("state") or {}).get("type") not in COMPLETED_STATE_TYPES and "research" in labels_of(c)
    ]
    parked_or_blocked = [c for c in children if (c.get("state") or {}).get("name") in ("Needs Input", "Blocked")]

    comment_fetch_ids = []
    seen = set()
    for c in [*missing_done, *open_research, *parked_or_blocked]:
        if c["id"] not in seen:
            seen.add(c["id"])
            comment_fetch_ids.append(c["id"])
    if newest_done is not None and newest_done["id"] not in seen:
        comment_fetch_ids.append(newest_done["id"])

    child_comments = {}
    for cid in comment_fetch_ids:
        node = lb.resolve_issue_ref(bridge_cmd_parts, cid, comments=True)
        child_comments[cid] = comments_of(node)

    child_documents = {}
    for c in open_research:
        child_documents[c["id"]] = lb.fetch_documents(bridge_cmd_parts, c["id"])

    return {
        "map_issue": map_node,
        "map_documents": map_documents,
        "children": children,
        "child_comments": child_comments,
        "child_documents": child_documents,
    }


# --------------------------------------------------------------------------
# CLI
# --------------------------------------------------------------------------

def _print(obj):
    print(json.dumps(obj, indent=2))


def main(argv=None):
    parser = argparse.ArgumentParser(
        description="Read-only map + frontier sweep for wayfinder work-through step 1 / /linear frontier.md."
    )
    parser.add_argument("map_id")
    parser.add_argument("--stale-days", type=float, default=7.0)
    parser.add_argument("--frontier-only", action="store_true")
    parser.add_argument("--bridge-cmd", default=None, help="Bridge command; falls back to LINEAR_GQL_CMD.")
    args = parser.parse_args(argv)

    try:
        bridge_cmd_parts = lb.resolve_bridge_cmd(args.bridge_cmd)

        if args.frontier_only:
            map_node = lb.resolve_issue_ref(bridge_cmd_parts, args.map_id)
            children = lb.fetch_children_full(bridge_cmd_parts, map_node["id"])
            frontier = compute_frontier(children)
            _print({"map_id": map_node.get("identifier"), "frontier": frontier, "frontier_rule": FRONTIER_RULE})
        else:
            ctx = gather_context(bridge_cmd_parts, args.map_id)
            report = compute_sweep(ctx, args.stale_days)
            _print(report)

        return lb.EXIT_OK

    except lb.BridgeConfigError as e:
        print(f"ERROR (config gap): {e}", file=sys.stderr)
        return lb.EXIT_CONFIG_GAP
    except lb.BridgeAuthError as e:
        print(f"ERROR (auth failure): {e}", file=sys.stderr)
        return lb.EXIT_AUTH
    except lb.AmbiguousOperatorError as e:
        print(f"ERROR (ambiguous operator): {e}", file=sys.stderr)
        return lb.EXIT_GRAPHQL
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
