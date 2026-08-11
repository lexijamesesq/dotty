#!/usr/bin/env python3
"""
archive-sweep.py — topology rebuild + eligibility check for the archive playbook.

Pure data processing, no network calls. Reads the GraphQL topology response
from the archive playbook's Step 3 fetch (.claude/skills/linear/playbooks/archive.md),
rebuilds cluster topology by walking each issue's parent.id to its topmost
ancestor, checks eligibility at a given quiet-hold threshold, and prints the
candidate list as JSON to stdout.

Input shape (stdin or a file argument):
    {"data": {"issues": {"nodes": [
        {"id": ..., "identifier": ..., "title": ..., "parent": {"id": ...} | null,
         "state": {"type": ...}, "updatedAt": ..., "team": {"key": ...}},
        ...
    ], "pageInfo": {"hasNextPage": ...}}}}

The caller (the playbook) is responsible for paging through the GraphQL
query and concatenating every page's `nodes` into one list before invoking
this script — see archive.md Step 3. If `pageInfo.hasNextPage` is still
true, the input is an incomplete page and this script refuses to guess at
eligibility from it.

Usage:
    python3 archive-sweep.py [FILE] [--hold-hours H] [--now ISO] [--exclude-roots ID,ID,...]
    cat topology.json | python3 archive-sweep.py --hold-hours 84

Exit codes:
    0  success
    1  processing error (malformed issue node — missing an expected field)
    2  usage / input error (bad JSON, wrong shape, incomplete pagination)
"""

import argparse
import json
import sys
from datetime import datetime, timezone

COMPLETED_STATE_TYPES = {"completed", "canceled"}


def parse_datetime(value: str) -> datetime:
    """Parse an ISO 8601 datetime string (Linear's updatedAt format) into an aware UTC datetime."""
    v = value.strip()
    if v.endswith("Z"):
        v = v[:-1] + "+00:00"
    dt = datetime.fromisoformat(v)
    if dt.tzinfo is None:
        dt = dt.replace(tzinfo=timezone.utc)
    return dt.astimezone(timezone.utc)


def load_nodes(raw: dict) -> list:
    """Extract and validate the issue node list from the GraphQL topology response."""
    try:
        issues = raw["data"]["issues"]
    except (KeyError, TypeError) as e:
        raise ValueError(f"input is not a topology response: missing data.issues ({e})") from e

    nodes = issues.get("nodes")
    if not isinstance(nodes, list):
        raise TypeError("input is not a topology response: data.issues.nodes is not a list")

    page_info = issues.get("pageInfo")
    if isinstance(page_info, dict) and page_info.get("hasNextPage"):
        raise ValueError(
            "topology response is incomplete: pageInfo.hasNextPage is true. "
            "The caller must page through the full result (concatenating nodes across "
            "pages, per archive.md Step 3) before invoking this script — eligibility on "
            "a partial issue set risks a false-positive all-closed read."
        )

    return nodes


def build_clusters(nodes: list) -> tuple:
    """
    Rebuild cluster topology client-side: walk parent.id upward to each
    issue's topmost ancestor (root), group by resolved root id.

    Edge case: if an issue's parent.id points to an id not present in the
    fetched set, treat that issue as its own root for this pass — its true
    parent was already archived in a prior sweep and is no longer part of
    the live topology. This inference is sound only when the fetch covers
    all Configuration teams (the default). A `teams:` subset filter makes a
    cross-team parent indistinguishable from an archived one — if the
    operator adds a second team to Configuration, this edge case needs
    revisiting. (archive.md Step 4.)

    Returns (clusters, by_id): clusters maps root id -> list of member
    nodes; by_id is the id -> node lookup used to resolve root metadata.
    """
    by_id = {n["id"]: n for n in nodes}
    root_cache = {}

    def resolve_root(issue_id: str) -> str:
        if issue_id in root_cache:
            return root_cache[issue_id]
        visited = set()
        current = issue_id
        while True:
            if current in visited:
                # Cycle guard — shouldn't occur in real data; stop rather
                # than loop forever if it ever does.
                break
            visited.add(current)
            node = by_id.get(current)
            if node is None:
                break
            parent = node.get("parent")
            parent_id = parent.get("id") if parent else None
            if not parent_id or parent_id not in by_id:
                # No parent, or parent outside the fetched set — prior-sweep
                # archived parent (or a cross-team parent; see guard above).
                break
            current = parent_id
        for seen_id in visited:
            root_cache[seen_id] = current
        return current

    clusters = {}
    for node in nodes:
        root_id = resolve_root(node["id"])
        clusters.setdefault(root_id, []).append(node)
    return clusters, by_id


def check_eligibility(members: list, hold_hours: float, now: datetime) -> tuple:
    """
    A cluster is eligible at hold H when every member's state.type is in
    {completed, canceled} (the all-closed invariant) AND the newest
    updatedAt across every member is at least H hours in the past (the
    quiet-hold clock — a touch on any member resets it; completedAt /
    canceledAt play no role). Returns (all_closed, newest_updated_at_str,
    hours_since_newest_update).
    """
    all_closed = all(
        m["state"]["type"] in COMPLETED_STATE_TYPES
        for m in members
    )
    newest_str, newest_dt = max(
        ((m["updatedAt"], parse_datetime(m["updatedAt"])) for m in members),
        key=lambda pair: pair[1],
    )
    hours_since = (now - newest_dt).total_seconds() / 3600.0
    return all_closed, newest_str, hours_since


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Archive playbook: cluster topology rebuild + eligibility check."
    )
    parser.add_argument(
        "input", nargs="?", metavar="FILE",
        help="Path to the topology JSON response. Reads stdin if omitted.",
    )
    parser.add_argument(
        "--hold-hours", type=float, default=168.0,
        help="Quiet-hold threshold in hours for this pass (default: 168).",
    )
    parser.add_argument(
        "--now", default=None, metavar="ISO_DATETIME",
        help="Override current time for elapsed-hours math (ISO 8601). Default: current UTC time.",
    )
    parser.add_argument(
        "--exclude-roots", default="",
        help="Comma-separated root issue ids to exclude — clusters already archived earlier this run.",
    )
    args = parser.parse_args()

    try:
        if args.input is None:
            raw_text = sys.stdin.read()
        else:
            with open(args.input, encoding="utf-8") as f:
                raw_text = f.read()
        raw = json.loads(raw_text)
    except (OSError, json.JSONDecodeError) as e:
        print(f"ERROR: failed to read/parse input: {e}", file=sys.stderr)
        return 2

    try:
        nodes = load_nodes(raw)
    except (ValueError, TypeError) as e:
        print(f"ERROR: {e}", file=sys.stderr)
        return 2

    try:
        now = parse_datetime(args.now) if args.now else datetime.now(timezone.utc)
    except ValueError as e:
        print(f"ERROR: could not parse --now value: {e}", file=sys.stderr)
        return 2

    exclude_roots = {r.strip() for r in args.exclude_roots.split(",") if r.strip()}

    try:
        clusters, by_id = build_clusters(nodes)
    except (KeyError, TypeError) as e:
        print(f"ERROR: malformed issue node while building topology: {e}", file=sys.stderr)
        return 1

    candidates = []
    has_open_member = 0
    within_hold = 0

    try:
        for root_id, members in clusters.items():
            if root_id in exclude_roots:
                continue

            all_closed, newest_str, hours_since = check_eligibility(members, args.hold_hours, now)

            if not all_closed:
                has_open_member += 1
                continue
            if hours_since < args.hold_hours:
                within_hold += 1
                continue

            root_node = by_id[root_id]
            candidates.append({
                "root_id": root_id,
                "root_identifier": root_node["identifier"],
                "root_title": root_node["title"],
                "root_team": root_node["team"]["key"],
                "cluster_size": len(members),
                "member_identifiers": [m["identifier"] for m in members],
                "newest_updated_at": newest_str,
                "hours_since_newest_update": round(hours_since, 1),
                "hold_hours_applied": args.hold_hours,
            })
    except (KeyError, TypeError) as e:
        print(f"ERROR: malformed issue node while checking eligibility: {e}", file=sys.stderr)
        return 1

    result = {
        "total_issues": len(nodes),
        "total_clusters": len(clusters),
        "hold_hours": args.hold_hours,
        "candidates": candidates,
        "ineligible_summary": {
            "has_open_member": has_open_member,
            "within_hold": within_hold,
        },
    }

    print(json.dumps(result, indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main())
