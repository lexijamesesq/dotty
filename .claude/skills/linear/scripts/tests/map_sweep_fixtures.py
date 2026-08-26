"""
Shared context/fixture builders for test_map_sweep.py. All identifiers are
fictional per the sample-universe convention — team ACR, tickets ACR-N —
never a real ticket id or the real team key.

map_sweep.compute_sweep(ctx, stale_days, now) is a pure function once handed
a context dict, so these tests build that context directly rather than
routing every detection-class case through a stub GraphQL bridge — same
precedent as cone_fixtures.py for cone_preflight.py. The live-fetch wiring
(gather_context) gets its own, smaller stub-bridge integration coverage in
test_map_sweep.py's GatherContextStubBridgeTests.
"""

DEFAULT_MAP_BODY = """## Destination

Ship the thing worth shipping.

## Notes

Nothing unusual for this effort.

## Decisions

See the **Decisions — The Map** document attached to this map.

## Fog

Some fog remains toward the destination.

## Out of scope

Nothing ruled out yet.
"""

# The decision index is an attached document's content, not a body
# section — this is that content, in the shape detection reads.
DEFAULT_DECISIONS_DOC_CONTENT = (
    "# Decisions — The Map\n\n"
    "- [Build slice one](https://linear.app/acme/issue/ACR-2/build-slice-one)"
    " — shipped the core path.\n"
)


def map_issue(description=None, comments=None, **overrides):
    issue = {
        "id": "map-uuid-1",
        "identifier": "ACR-1",
        "title": "The Map",
        "state": {"name": "In Progress", "type": "started"},
        "description": DEFAULT_MAP_BODY if description is None else description,
        "comments": {"nodes": comments or []},
    }
    issue.update(overrides)
    return issue


def child(identifier, uuid=None, state_name="Todo", state_type="unstarted", labels=None,
          delegate=None, assignee=None, priority=2, created_at="2026-01-01T00:00:00Z",
          completed_at=None, updated_at="2026-01-01T00:00:00Z", blocked_by_open=None,
          title=None):
    return {
        "id": uuid or f"uuid-{identifier}",
        "identifier": identifier,
        "title": title or f"Ticket {identifier}",
        "state": {"name": state_name, "type": state_type},
        "labels": {"nodes": [{"name": l} for l in (labels or [])]},
        "delegate": {"id": delegate} if delegate else None,
        "assignee": {"id": assignee} if assignee else None,
        "priority": priority,
        "createdAt": created_at,
        "completedAt": completed_at,
        "updatedAt": updated_at,
        "blocked_by_open": blocked_by_open or [],
    }


def comment(comment_id, body, created_at, user_id="viewer-1"):
    return {"id": comment_id, "body": body, "createdAt": created_at, "user": {"id": user_id}}


def decisions_doc(content=DEFAULT_DECISIONS_DOC_CONTENT, title="Decisions — The Map", **overrides):
    """The map's attached Decisions document. `decisions_missing`
    checks a Done child's identifier against this doc's content, not the
    map body. Title carries the `Decisions — ` prefix map_sweep matches on."""
    doc = {
        "id": "decisions-doc-1",
        "title": title,
        "archivedAt": None,
        "content": content,
    }
    doc.update(overrides)
    return doc


def base_ctx(**overrides):
    ctx = {
        "map_issue": map_issue(),
        "map_documents": [],
        "children": [],
        "child_comments": {},
        "child_documents": {},
    }
    ctx.update(overrides)
    return ctx
