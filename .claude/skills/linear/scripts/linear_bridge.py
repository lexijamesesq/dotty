#!/usr/bin/env python3
"""
linear_bridge.py — GraphQL bridge transport + Linear primitives for the traffic-cone
lifecycle scripts (cone_preflight.py is the other half; see that module's docstring).

Everything that talks to Linear's GraphQL API through the operator's authenticated
bridge command lives here, in one place. The bridge command itself is never named or
embedded in this file — it comes from `--bridge-cmd` or the `LINEAR_GQL_CMD`
environment variable (see `linear.gql_bridge_cmd` in the consumer's private
CLAUDE.md > Configuration). This script never touches op paths, tokens, or vault
refs; neither may appear in any file in this repo (public).

Subcommands:
    viewer                                   resolve app-actor id
    operator [--email E]                     resolve operator user id (first
                                              non-app admin, or --email filter)
    issue <id> [--body] [--comments] [--history]
                                              field-selected issue fetch
    children <map-id>                        children of a map issue
    children-full <map-id>                   children of a map issue, fuller
                                              field selection (state, labels,
                                              delegate, assignee, priority,
                                              createdAt, completedAt,
                                              updatedAt, blocked-by) — for
                                              map_sweep.py
    documents <id> [--content]                documents attached to an issue
    lint-body [FILE]                         reject bare @mentions (stdin or FILE)
    wip-check --actor ID --project ID        In Progress issues delegated to actor
    claim-write UUID --state ID --delegate ID [--assignee ID] [--dry-run]
                                              claim mutation + built-in read-back
    release-delegate UUID                    clear delegateId, read-back verified
    set-state UUID --state ID                stateId mutation, read-back verified
    resolve-state TEAM-KEY STATE-NAME        workflow-state id lookup (cached
                                              per process)
    create-comment UUID --body-file FILE     post a comment (lint-body applied
                                              in-process before posting — a
                                              violation refuses, never posts),
                                              read-back verified
    create-relation UUID RELATED-UUID --type TYPE
                                              issue relation (e.g. duplicate_of
                                              for cancel), read-back verified

Identifier resolution: every subcommand taking an issue reference accepts both
`TEAM-N` identifiers and UUIDs. `issue(id:)` is tried as given first; if Linear's
GraphQL rejects it, the script falls back to an `issues` filter on team key +
number. Callers never pre-resolve.

Read-back law: every mutation subcommand (claim-write, release-delegate,
set-state) performs its own independent re-fetch after the mutation and reports
`verified: true|false` plus the observed values. No mutation result is ever
reported trusted on its own say-so.

Exit codes:
    0  success
    1  script bug (internal error, malformed API response the script cannot
       safely proceed on)
    2  bridge command missing/not executable, or a usage/config gap — the
       message names which env var or flag to set
    3  bridge auth failure (401/403-shaped bridge stderr/response)
    4  GraphQL-level error returned by the API (the error payload is echoed),
       or an ambiguous `operator` resolution (candidates are echoed)
    5  transient/network failure, reported only after 2 retries (1s, 3s
       backoff) — this includes Linear's "App user not valid" scope glitch,
       which is transient per existing `/linear` law, now enforced in code
    6  create-comment's body failed the in-process lint-body check (bare
       @mentions) — refused before any network call was made

All output is one JSON object to stdout per invocation. `lint-body` is the one
subcommand with its own local exit-code meaning (0 clean, 1 violations found,
2 usage) since it does no network I/O — see its docstring below.

Usage:
    python3 linear_bridge.py viewer
    python3 linear_bridge.py issue ACR-12 --comments
    LINEAR_GQL_CMD=/path/to/bridge python3 linear_bridge.py children ACR-1
"""

import argparse
import json
import os
import re
import shlex
import subprocess
import sys
import tempfile
import time

# --------------------------------------------------------------------------
# Exit codes
# --------------------------------------------------------------------------

EXIT_OK = 0
EXIT_SCRIPT_BUG = 1
EXIT_CONFIG_GAP = 2
EXIT_AUTH = 3
EXIT_GRAPHQL = 4
EXIT_TRANSIENT = 5
EXIT_LINT_VIOLATION = 6

RETRY_BACKOFFS = (1, 3)  # seconds; existing /linear law for transient scope failures


# --------------------------------------------------------------------------
# Error classes — each maps to one exit code in main()
# --------------------------------------------------------------------------

class BridgeConfigError(Exception):
    """Bridge command missing, not executable, or not configured. Exit 2."""


class BridgeAuthError(Exception):
    """Bridge reported an auth failure (401/403-shaped). Exit 3."""


class GraphQLAPIError(Exception):
    """A real GraphQL-level error came back from the API. Exit 4."""

    def __init__(self, message, payload=None):
        super().__init__(message)
        self.payload = payload


class TransientBridgeError(Exception):
    """Network/transient failure, or a scope glitch ('App user not valid')
    that the existing /linear law treats as transient. Exit 5 after retries."""


class AmbiguousOperatorError(Exception):
    """operator resolution found >1 candidate and no --email filter. Exit 4."""

    def __init__(self, message, candidates=None):
        super().__init__(message)
        self.candidates = candidates or []


class LintViolationError(Exception):
    """create-comment's body carries an unescaped @mention — lint-body ran
    in-process before any network call, and the violation refuses the post
    outright rather than sending it. Exit 6."""

    def __init__(self, message, violations=None):
        super().__init__(message)
        self.violations = violations or []


# --------------------------------------------------------------------------
# Identifier resolution
# --------------------------------------------------------------------------

UUID_RE = re.compile(
    r"^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$"
)
IDENTIFIER_RE = re.compile(r"^([A-Za-z]+)-(\d+)$")


def is_uuid(value: str) -> bool:
    return bool(UUID_RE.match(value or ""))


def parse_identifier(value: str):
    """Return (TEAM_KEY, number) if value looks like TEAM-N, else None."""
    m = IDENTIFIER_RE.match(value or "")
    if not m:
        return None
    return m.group(1).upper(), int(m.group(2))


# --------------------------------------------------------------------------
# Bridge transport
# --------------------------------------------------------------------------

AUTH_PATTERN = re.compile(
    r"\b(401|403|unauthorized|unauthenticated|forbidden|invalid[ _-]?token|access[ _-]?denied)\b",
    re.IGNORECASE,
)
SCOPE_TRANSIENT_PATTERN = re.compile(r"app user not valid", re.IGNORECASE)
TRANSIENT_PATTERN = re.compile(
    r"(could not resolve host|connection refused|timed? ?out|"
    r"empty reply from server|recv failure|network is unreachable|"
    r"temporary failure|ssl connect error|connection reset)",
    re.IGNORECASE,
)
# curl exit codes that are unambiguously network-layer, not application-layer
TRANSIENT_RETURNCODES = {6, 7, 28, 35, 52, 56}


def resolve_bridge_cmd(bridge_cmd_arg: str):
    """Resolve the bridge command from --bridge-cmd or LINEAR_GQL_CMD. Never
    from a literal path in this file — the value is a caller-supplied secret
    reference, never embedded here (public repo)."""
    raw = bridge_cmd_arg or os.environ.get("LINEAR_GQL_CMD")
    if not raw:
        raise BridgeConfigError(
            "no bridge command configured — pass --bridge-cmd or set LINEAR_GQL_CMD. "
            "Resolve linear.gql_bridge_cmd from CLAUDE.md > Configuration into "
            "LINEAR_GQL_CMD before the first script call."
        )
    parts = shlex.split(raw)
    if not parts:
        raise BridgeConfigError("LINEAR_GQL_CMD / --bridge-cmd resolved to an empty command")
    return parts


def _invoke_bridge(bridge_cmd_parts, payload):
    fd, path = tempfile.mkstemp(suffix=".json", prefix="linear-bridge-payload-")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            json.dump(payload, f)
        try:
            return subprocess.run(
                [*bridge_cmd_parts, path],
                capture_output=True,
                text=True,
                timeout=60,
                check=False,
            )
        except FileNotFoundError as e:
            raise BridgeConfigError(
                f"bridge command not found: {bridge_cmd_parts[0]!r} ({e})"
            ) from e
        except PermissionError as e:
            raise BridgeConfigError(
                f"bridge command not executable: {bridge_cmd_parts[0]!r} ({e})"
            ) from e
        except subprocess.TimeoutExpired as e:
            raise TransientBridgeError(f"bridge command timed out: {e}") from e
    finally:
        try:
            os.unlink(path)
        except OSError:
            pass


def run_graphql(bridge_cmd_parts, query, variables=None, retries=2, backoffs=RETRY_BACKOFFS):
    """POST a GraphQL query through the bridge command and return the parsed
    `{"data": ...}` response. Raises a typed error on any non-success shape;
    transient failures (network, or Linear's 'App user not valid' scope
    glitch) retry `retries` times with the given backoff before raising."""
    payload = {"query": query}
    if variables is not None:
        payload["variables"] = variables

    attempt = 0
    last_exc = None
    while True:
        proc = _invoke_bridge(bridge_cmd_parts, payload)
        stdout = proc.stdout or ""
        stderr = proc.stderr or ""
        combined = f"{stdout}\n{stderr}".strip()

        parsed = None
        if stdout.strip():
            try:
                parsed = json.loads(stdout)
            except json.JSONDecodeError:
                parsed = None

        if proc.returncode == 0 and isinstance(parsed, dict) and "errors" not in parsed:
            return parsed

        if isinstance(parsed, dict) and isinstance(parsed.get("errors"), list) and parsed["errors"]:
            messages = " | ".join(e.get("message", "") for e in parsed["errors"])
            if SCOPE_TRANSIENT_PATTERN.search(messages):
                last_exc = TransientBridgeError(f"transient scope failure: {messages}")
            elif AUTH_PATTERN.search(messages):
                raise BridgeAuthError(f"bridge auth failure: {messages}")
            else:
                raise GraphQLAPIError(f"GraphQL error: {messages}", payload={"errors": parsed["errors"]})
        elif AUTH_PATTERN.search(combined):
            raise BridgeAuthError(f"bridge auth failure: {combined[:500]}")
        elif TRANSIENT_PATTERN.search(combined) or proc.returncode in TRANSIENT_RETURNCODES:
            last_exc = TransientBridgeError(
                f"transient/network failure (exit {proc.returncode}): {combined[:500]}"
            )
        else:
            # Unrecognized failure shape. Never silently drop it — retry it
            # like any other transient fault, then surface the raw output
            # verbatim on the final attempt so the caller can diagnose it.
            last_exc = TransientBridgeError(
                f"unrecognized bridge failure (exit {proc.returncode}): {combined[:500]}"
            )

        attempt += 1
        if attempt > retries:
            raise last_exc
        time.sleep(backoffs[min(attempt - 1, len(backoffs) - 1)])


# --------------------------------------------------------------------------
# Field selections
# --------------------------------------------------------------------------

ISSUE_FIELDS = """
    id
    identifier
    title
    state { name type }
    labels { nodes { name } }
    parent {
      id
      identifier
      title
      state { name type }
      labels { nodes { name } }
    }
    delegate { id }
    assignee { id }
    team { key }
    inverseRelations { nodes { type issue { id identifier state { type } } } }
"""


def _issue_fields(body=False, comments=False, history=False):
    extra = ""
    if body:
        extra += "\n    description"
    if comments:
        extra += "\n    comments { nodes { id body createdAt user { id } } }"
    if history:
        extra += "\n    history { nodes { createdAt fromState { name type } toState { name type } } }"
    return ISSUE_FIELDS + extra


def _blocked_by_open(issue_node):
    """Open blocked-by relations only, from inverseRelations (relations where
    this issue is the target — i.e. another issue blocks this one). Per a
    live-smoke finding (2026-08-10): on an inverseRelations node, `.issue` is
    the OTHER side of the relation (the blocker) — `.relatedIssue` resolves
    back to the issue you queried, since inverseRelations is the mirror of
    `issue { relatedIssue }` from the other issue's perspective."""
    completed_types = {"completed", "canceled"}
    out = []
    for rel in (issue_node.get("inverseRelations") or {}).get("nodes", []):
        if rel.get("type") != "blocks":
            continue
        blocker = rel.get("issue") or {}
        state = (blocker.get("state") or {}).get("type")
        if state not in completed_types:
            out.append(blocker)
    return out


def resolve_issue_ref(bridge_cmd_parts, id_str, body=False, comments=False, history=False):
    """Fetch an issue by UUID or TEAM-N identifier. Tries `issue(id:)` first;
    on a GraphQL-level rejection, falls back to an `issues` filter on team key
    + number, per this module's identifier-resolution contract."""
    fields = _issue_fields(body, comments, history)
    query = f'query {{ issue(id: "{id_str}") {{ {fields} }} }}'
    try:
        resp = run_graphql(bridge_cmd_parts, query)
        node = resp.get("data", {}).get("issue")
        if node is not None:
            return node
    except GraphQLAPIError:
        pass

    parsed = parse_identifier(id_str)
    if parsed is None:
        raise GraphQLAPIError(f"issue not found and {id_str!r} is not a TEAM-N identifier to fall back on")
    team_key, number = parsed
    fallback_query = (
        f'query {{ issues(filter: {{ team: {{ key: {{ eq: "{team_key}" }} }}, '
        f'number: {{ eq: {number} }} }}) {{ nodes {{ {fields} }} }} }}'
    )
    resp = run_graphql(bridge_cmd_parts, fallback_query)
    nodes = resp.get("data", {}).get("issues", {}).get("nodes", [])
    if not nodes:
        raise GraphQLAPIError(f"no issue found for {id_str!r} via id or team/number fallback")
    return nodes[0]


def fetch_children(bridge_cmd_parts, map_uuid, page_size=100):
    """All children of a map issue, paged. Refuses to return a partial set —
    follows archive-sweep.py's refuse-on-incomplete-page precedent: if paging
    is interrupted by a malformed response, this raises rather than returning
    what it has so far."""
    nodes = []
    after = None
    while True:
        after_clause = f', after: "{after}"' if after else ""
        query = (
            f'query {{ issues(first: {page_size}{after_clause}, '
            f'filter: {{ parent: {{ id: {{ eq: "{map_uuid}" }} }} }}) '
            f'{{ nodes {{ id identifier title state {{ name type }} '
            f'labels {{ nodes {{ name }} }} delegate {{ id }} }} '
            f'pageInfo {{ hasNextPage endCursor }} }} }}'
        )
        resp = run_graphql(bridge_cmd_parts, query)
        issues = resp.get("data", {}).get("issues")
        if not isinstance(issues, dict) or "nodes" not in issues or "pageInfo" not in issues:
            raise RuntimeError(
                "children fetch returned a malformed page (missing nodes/pageInfo) — "
                "refusing to report a partial child set"
            )
        nodes.extend(issues["nodes"])
        page_info = issues["pageInfo"]
        if not page_info.get("hasNextPage"):
            break
        after = page_info.get("endCursor")
        if not after:
            raise RuntimeError(
                "children fetch reports hasNextPage=true with no endCursor — "
                "refusing to guess at the next page"
            )
    return nodes


CHILDREN_FULL_FIELDS = """
    id
    identifier
    title
    state { name type }
    labels { nodes { name } }
    delegate { id }
    assignee { id }
    priority
    createdAt
    completedAt
    updatedAt
    inverseRelations { nodes { type issue { id identifier state { type } } } }
"""


def fetch_children_full(bridge_cmd_parts, map_uuid, page_size=100):
    """All children of a map issue, paged, with the fuller field selection
    map_sweep.py needs (state, labels, delegate, assignee, priority,
    createdAt, completedAt, updatedAt, blocked-by relations) — a read-only
    sibling of `fetch_children` above, which keeps its narrower selection
    untouched for its existing callers. Same refuse-on-incomplete-page
    discipline (archive-sweep.py precedent): a malformed page raises rather
    than returning a partial child set.

    Each returned node carries `blocked_by_open` pre-computed (via
    `_blocked_by_open`, same helper the `issue` subcommand uses) — done here,
    in the library function, rather than deferred to CLI dispatch, so an
    importer (map_sweep.py) gets a complete node without reaching into a
    private helper itself."""
    nodes = []
    after = None
    while True:
        after_clause = f', after: "{after}"' if after else ""
        query = (
            f'query {{ issues(first: {page_size}{after_clause}, '
            f'filter: {{ parent: {{ id: {{ eq: "{map_uuid}" }} }} }}) '
            f'{{ nodes {{ {CHILDREN_FULL_FIELDS} }} '
            f'pageInfo {{ hasNextPage endCursor }} }} }}'
        )
        resp = run_graphql(bridge_cmd_parts, query)
        issues = resp.get("data", {}).get("issues")
        if not isinstance(issues, dict) or "nodes" not in issues or "pageInfo" not in issues:
            raise RuntimeError(
                "children-full fetch returned a malformed page (missing nodes/pageInfo) — "
                "refusing to report a partial child set"
            )
        nodes.extend(issues["nodes"])
        page_info = issues["pageInfo"]
        if not page_info.get("hasNextPage"):
            break
        after = page_info.get("endCursor")
        if not after:
            raise RuntimeError(
                "children-full fetch reports hasNextPage=true with no endCursor — "
                "refusing to guess at the next page"
            )
    for node in nodes:
        node["blocked_by_open"] = _blocked_by_open(node)
    return nodes


def fetch_documents(bridge_cmd_parts, issue_uuid, content=False):
    content_field = "\n        content" if content else ""
    query = (
        f'query {{ issue(id: "{issue_uuid}") {{ documents {{ nodes {{ '
        f'id title archivedAt{content_field} }} }} }} }}'
    )
    resp = run_graphql(bridge_cmd_parts, query)
    node = resp.get("data", {}).get("issue")
    if node is None:
        raise GraphQLAPIError(f"no issue found for {issue_uuid!r} while fetching documents")
    return node.get("documents", {}).get("nodes", [])


# --------------------------------------------------------------------------
# lint-body — pure text processing, no bridge call
# --------------------------------------------------------------------------

MENTION_NAMES = ("linear", "attack-kitty", "traffic-cone")


def find_bare_mentions(text):
    """Return a list of {"name", "index"} for every bare (non-backtick-escaped)
    @name occurrence of an agent name. `` `@linear` `` is escaped; `@linear`
    is not."""
    violations = []
    for name in MENTION_NAMES:
        token = f"@{name}"
        start = 0
        while True:
            idx = text.find(token, start)
            if idx == -1:
                break
            before = text[idx - 1] if idx > 0 else ""
            after_idx = idx + len(token)
            after = text[after_idx] if after_idx < len(text) else ""
            if before == "`" and after == "`":
                pass  # escaped — fine
            else:
                violations.append({"name": name, "index": idx})
            start = idx + len(token)
    return violations


# --------------------------------------------------------------------------
# Mutations (all read-back verified)
# --------------------------------------------------------------------------

def claim_write(bridge_cmd_parts, issue_uuid, state_id, delegate_id, assignee_id=None, dry_run=False):
    input_fields = f'stateId: "{state_id}", delegateId: "{delegate_id}"'
    if assignee_id:
        input_fields += f', assigneeId: "{assignee_id}"'
    mutation = (
        f'mutation {{ issueUpdate(id: "{issue_uuid}", '
        f'input: {{ {input_fields} }}) {{ success }} }}'
    )
    if dry_run:
        return {"dry_run": True, "mutation": mutation}

    run_graphql(bridge_cmd_parts, mutation)

    readback = run_graphql(
        bridge_cmd_parts,
        f'query {{ issue(id: "{issue_uuid}") {{ id delegate {{ id }} state {{ id name type }} assignee {{ id }} }} }}',
    )
    node = readback.get("data", {}).get("issue") or {}
    observed_delegate = (node.get("delegate") or {}).get("id")
    race_lost = observed_delegate != delegate_id
    return {
        "dry_run": False,
        "verified": not race_lost,
        "race_lost": race_lost,
        "observed_delegate": observed_delegate,
        "observed_state": node.get("state"),
        "observed_assignee": (node.get("assignee") or {}).get("id"),
    }


def release_delegate(bridge_cmd_parts, issue_uuid):
    mutation = f'mutation {{ issueUpdate(id: "{issue_uuid}", input: {{ delegateId: null }}) {{ success }} }}'
    run_graphql(bridge_cmd_parts, mutation)
    readback = run_graphql(
        bridge_cmd_parts,
        f'query {{ issue(id: "{issue_uuid}") {{ id delegate {{ id }} }} }}',
    )
    node = readback.get("data", {}).get("issue") or {}
    observed_delegate = (node.get("delegate") or {}).get("id")
    return {"verified": observed_delegate is None, "observed_delegate": observed_delegate}


def set_state(bridge_cmd_parts, issue_uuid, state_id):
    mutation = f'mutation {{ issueUpdate(id: "{issue_uuid}", input: {{ stateId: "{state_id}" }}) {{ success }} }}'
    run_graphql(bridge_cmd_parts, mutation)
    readback = run_graphql(
        bridge_cmd_parts,
        f'query {{ issue(id: "{issue_uuid}") {{ id state {{ id name type }} }} }}',
    )
    node = readback.get("data", {}).get("issue") or {}
    observed_state = node.get("state") or {}
    return {
        "verified": observed_state.get("id") == state_id,
        "observed_state": observed_state,
    }


def create_comment(bridge_cmd_parts, issue_uuid, body):
    """Post a comment on an issue. `lint-body` runs in-process first (see
    `find_bare_mentions`) — a violation raises `LintViolationError` before
    any network call is made, never posting a bad body. The mutation body is
    sent as a GraphQL variable (not string-interpolated) since comment text
    is free-form markdown that can carry quotes, backticks, and newlines.
    Read-back verified: re-fetches the issue's comments and confirms the new
    id and body are both present."""
    violations = find_bare_mentions(body)
    if violations:
        raise LintViolationError(
            f"body carries {len(violations)} unescaped @mention(s) — refusing to post",
            violations=violations,
        )

    mutation = (
        "mutation($issueId: String!, $body: String!) { "
        "commentCreate(input: { issueId: $issueId, body: $body }) { "
        "success comment { id } } }"
    )
    resp = run_graphql(bridge_cmd_parts, mutation, variables={"issueId": issue_uuid, "body": body})
    comment_id = (((resp.get("data") or {}).get("commentCreate") or {}).get("comment") or {}).get("id")

    readback = run_graphql(
        bridge_cmd_parts,
        f'query {{ issue(id: "{issue_uuid}") {{ comments {{ nodes {{ id body }} }} }} }}',
    )
    nodes = (((readback.get("data") or {}).get("issue") or {}).get("comments") or {}).get("nodes", [])
    observed = next((n for n in nodes if n.get("id") == comment_id), None)
    return {
        "verified": observed is not None and observed.get("body") == body,
        "comment_id": comment_id,
        "observed_body": observed.get("body") if observed else None,
    }


def create_relation(bridge_cmd_parts, issue_uuid, related_uuid, relation_type):
    """Create an issue relation (e.g. `duplicate_of` — cancel's optional
    relation). `relation_type` is passed through as a bare GraphQL enum
    token, never quoted. Read-back verified: re-fetches the issue's forward
    `relations` and confirms a matching type + relatedIssue.id is present."""
    mutation = (
        f'mutation {{ issueRelationCreate(input: {{ issueId: "{issue_uuid}", '
        f'relatedIssueId: "{related_uuid}", type: {relation_type} }}) '
        f'{{ success issueRelation {{ id type relatedIssue {{ id }} }} }} }}'
    )
    run_graphql(bridge_cmd_parts, mutation)

    readback = run_graphql(
        bridge_cmd_parts,
        f'query {{ issue(id: "{issue_uuid}") {{ relations {{ nodes {{ type relatedIssue {{ id }} }} }} }} }}',
    )
    nodes = (((readback.get("data") or {}).get("issue") or {}).get("relations") or {}).get("nodes", [])
    observed = next(
        (n for n in nodes if n.get("type") == relation_type and (n.get("relatedIssue") or {}).get("id") == related_uuid),
        None,
    )
    return {"verified": observed is not None, "observed": observed}


_STATE_CACHE = {}


def resolve_state(bridge_cmd_parts, team_key, state_name):
    """Workflow-state id lookup by team key (never a team UUID — Linear's
    filter accepts the key directly, so this never needs the private
    prefix->UUID mapping). Cached per process."""
    key = team_key.upper()
    if key not in _STATE_CACHE:
        query = f'query {{ workflowStates(filter: {{ team: {{ key: {{ eq: "{key}" }} }} }}) {{ nodes {{ id name type }} }} }}'
        resp = run_graphql(bridge_cmd_parts, query)
        _STATE_CACHE[key] = resp.get("data", {}).get("workflowStates", {}).get("nodes", [])
    for state in _STATE_CACHE[key]:
        if state.get("name", "").lower() == state_name.lower():
            return state
    raise GraphQLAPIError(f"no workflow state named {state_name!r} for team {key!r}")


def wip_check(bridge_cmd_parts, actor_id, project_id):
    query = (
        f'query {{ issues(filter: {{ project: {{ id: {{ eq: "{project_id}" }} }}, '
        f'delegate: {{ id: {{ eq: "{actor_id}" }} }}, state: {{ type: {{ eq: "started" }} }} }}) '
        f'{{ nodes {{ id identifier title }} }} }}'
    )
    resp = run_graphql(bridge_cmd_parts, query)
    return resp.get("data", {}).get("issues", {}).get("nodes", [])


def resolve_operator(bridge_cmd_parts, email=None):
    if email:
        query = f'query {{ users(filter: {{ email: {{ eq: "{email}" }} }}) {{ nodes {{ id name email admin app }} }} }}'
        resp = run_graphql(bridge_cmd_parts, query)
        nodes = resp.get("data", {}).get("users", {}).get("nodes", [])
        if not nodes:
            raise GraphQLAPIError(f"no user found for --email {email!r}")
        return nodes[0]

    query = 'query { users(filter: { admin: { eq: true }, active: { eq: true } }) { nodes { id name email admin app } } }'
    resp = run_graphql(bridge_cmd_parts, query)
    nodes = resp.get("data", {}).get("users", {}).get("nodes", [])
    candidates = [u for u in nodes if not u.get("app")]
    if len(candidates) == 1:
        return candidates[0]
    if len(candidates) == 0:
        raise GraphQLAPIError("no non-app admin user found")
    raise AmbiguousOperatorError(
        "multiple non-app admin users found and no --email filter given — "
        "the script never picks",
        candidates=candidates,
    )


def resolve_viewer(bridge_cmd_parts):
    resp = run_graphql(bridge_cmd_parts, "query { viewer { id name email } }")
    return resp.get("data", {}).get("viewer")


# --------------------------------------------------------------------------
# CLI
# --------------------------------------------------------------------------

def _print(obj):
    print(json.dumps(obj, indent=2))


def main(argv=None):
    parser = argparse.ArgumentParser(description="Linear GraphQL bridge transport + primitives.")
    parser.add_argument("--bridge-cmd", default=None, help="Bridge command; falls back to LINEAR_GQL_CMD.")
    sub = parser.add_subparsers(dest="subcommand", required=True)

    sub.add_parser("viewer")

    p_operator = sub.add_parser("operator")
    p_operator.add_argument("--email", default=None)

    p_issue = sub.add_parser("issue")
    p_issue.add_argument("id")
    p_issue.add_argument("--body", action="store_true")
    p_issue.add_argument("--comments", action="store_true")
    p_issue.add_argument("--history", action="store_true")

    p_children = sub.add_parser("children")
    p_children.add_argument("map_id")

    p_children_full = sub.add_parser("children-full")
    p_children_full.add_argument("map_id")

    p_documents = sub.add_parser("documents")
    p_documents.add_argument("id")
    p_documents.add_argument("--content", action="store_true")

    p_lint = sub.add_parser("lint-body")
    p_lint.add_argument("file", nargs="?", default=None)

    p_wip = sub.add_parser("wip-check")
    p_wip.add_argument("--actor", required=True)
    p_wip.add_argument("--project", required=True)

    p_claim = sub.add_parser("claim-write")
    p_claim.add_argument("uuid")
    p_claim.add_argument("--state", required=True)
    p_claim.add_argument("--delegate", required=True)
    p_claim.add_argument("--assignee", default=None)
    p_claim.add_argument("--dry-run", action="store_true")

    p_release = sub.add_parser("release-delegate")
    p_release.add_argument("uuid")

    p_set_state = sub.add_parser("set-state")
    p_set_state.add_argument("uuid")
    p_set_state.add_argument("--state", required=True)

    p_resolve_state = sub.add_parser("resolve-state")
    p_resolve_state.add_argument("team_key")
    p_resolve_state.add_argument("state_name")

    p_create_comment = sub.add_parser("create-comment")
    p_create_comment.add_argument("uuid")
    p_create_comment.add_argument("--body-file", required=True)

    p_create_relation = sub.add_parser("create-relation")
    p_create_relation.add_argument("uuid")
    p_create_relation.add_argument("related_uuid")
    p_create_relation.add_argument("--type", required=True)

    args = parser.parse_args(argv)

    if args.subcommand == "lint-body":
        try:
            if args.file is None:
                text = sys.stdin.read()
            else:
                with open(args.file, "r", encoding="utf-8") as f:
                    text = f.read()
        except OSError as e:
            print(f"ERROR: failed to read input: {e}", file=sys.stderr)
            return EXIT_CONFIG_GAP
        violations = find_bare_mentions(text)
        _print({"clean": not violations, "violations": violations})
        return EXIT_OK if not violations else 1

    # claim-write --dry-run never touches the bridge (see claim_write()) —
    # resolving a bridge command for it would refuse the dry-run on a
    # config gap it doesn't actually have. Every other subcommand resolves
    # the bridge cmd up front, same as before.
    dry_run_no_bridge_needed = args.subcommand == "claim-write" and args.dry_run

    try:
        bridge_cmd_parts = None if dry_run_no_bridge_needed else resolve_bridge_cmd(args.bridge_cmd)

        if args.subcommand == "viewer":
            _print({"viewer": resolve_viewer(bridge_cmd_parts)})

        elif args.subcommand == "operator":
            _print({"operator": resolve_operator(bridge_cmd_parts, args.email)})

        elif args.subcommand == "issue":
            node = resolve_issue_ref(bridge_cmd_parts, args.id, args.body, args.comments, args.history)
            node = dict(node)
            node["blocked_by_open"] = _blocked_by_open(node)
            _print({"issue": node})

        elif args.subcommand == "children":
            map_node = resolve_issue_ref(bridge_cmd_parts, args.map_id)
            children = fetch_children(bridge_cmd_parts, map_node["id"])
            _print({"map_id": map_node.get("identifier"), "children": children})

        elif args.subcommand == "children-full":
            map_node = resolve_issue_ref(bridge_cmd_parts, args.map_id)
            children = fetch_children_full(bridge_cmd_parts, map_node["id"])
            _print({"map_id": map_node.get("identifier"), "children": children})

        elif args.subcommand == "documents":
            node = resolve_issue_ref(bridge_cmd_parts, args.id)
            docs = fetch_documents(bridge_cmd_parts, node["id"], args.content)
            _print({"issue_id": node.get("identifier"), "documents": docs})

        elif args.subcommand == "wip-check":
            _print({"in_progress": wip_check(bridge_cmd_parts, args.actor, args.project)})

        elif args.subcommand == "claim-write":
            _print(claim_write(bridge_cmd_parts, args.uuid, args.state, args.delegate, args.assignee, args.dry_run))

        elif args.subcommand == "release-delegate":
            _print(release_delegate(bridge_cmd_parts, args.uuid))

        elif args.subcommand == "set-state":
            _print(set_state(bridge_cmd_parts, args.uuid, args.state))

        elif args.subcommand == "resolve-state":
            _print(resolve_state(bridge_cmd_parts, args.team_key, args.state_name))

        elif args.subcommand == "create-comment":
            try:
                with open(args.body_file, "r", encoding="utf-8") as f:
                    body = f.read()
            except OSError as e:
                print(f"ERROR: failed to read --body-file: {e}", file=sys.stderr)
                return EXIT_CONFIG_GAP
            _print(create_comment(bridge_cmd_parts, args.uuid, body))

        elif args.subcommand == "create-relation":
            _print(create_relation(bridge_cmd_parts, args.uuid, args.related_uuid, args.type))

        return EXIT_OK

    except BridgeConfigError as e:
        print(f"ERROR (config gap): {e}", file=sys.stderr)
        return EXIT_CONFIG_GAP
    except BridgeAuthError as e:
        print(f"ERROR (auth failure): {e}", file=sys.stderr)
        return EXIT_AUTH
    except AmbiguousOperatorError as e:
        print(f"ERROR (ambiguous operator): {e}", file=sys.stderr)
        _print({"candidates": e.candidates})
        return EXIT_GRAPHQL
    except LintViolationError as e:
        print(f"ERROR (lint violation): {e}", file=sys.stderr)
        _print({"violations": e.violations})
        return EXIT_LINT_VIOLATION
    except GraphQLAPIError as e:
        print(f"ERROR (GraphQL): {e}", file=sys.stderr)
        if e.payload is not None:
            _print(e.payload)
        return EXIT_GRAPHQL
    except TransientBridgeError as e:
        print(f"ERROR (transient, retries exhausted): {e}", file=sys.stderr)
        return EXIT_TRANSIENT
    except (RuntimeError, KeyError, TypeError, ValueError) as e:
        print(f"ERROR (script bug): {e}", file=sys.stderr)
        return EXIT_SCRIPT_BUG


if __name__ == "__main__":
    sys.exit(main())
