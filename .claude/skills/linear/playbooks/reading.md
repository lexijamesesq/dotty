# Playbook: reading

Read operations across Linear: issues, projects, queue, narrative (Project Updates). All read paths; no mutations.

## Operations

### 1. Read narrative (recent Project Updates)

**Input:**
- `project_id` (UUID, required)
- `limit` (default 3, max 10)

**Protocol:**
1. Call `mcp__linear-tactic__linear_getProjectUpdates` with the `projectId` and `limit`. Sort by `createdAt` descending.
2. Return the most-recent updates.

**Output:**
```yaml
updates:
  - id: <uuid>
    createdAt: <ISO timestamp>
    health: onTrack | atRisk | offTrack
    body: <markdown>
    user: <name>
```

### 2. Read queue (active issues for a project)

**Input:**
- `project_id` (UUID, required)
- `state_filter` (optional list — default: `[Todo, In Progress, Needs Input, Blocked]`; exclude Done + Canceled unless explicitly requested)

**Protocol:**
1. Call `mcp__linear-tactic__linear_getProjectIssues` with `projectId`.
2. Filter client-side by `state_filter`.
3. Return ordered by priority (Urgent → Low), then by `sortOrder`.

**Output:**
```yaml
issues:
  - id: <uuid>
    identifier: <TEAM>-N
    title: <string>
    state: Todo | In Progress | Needs Input | Blocked
    priority: 1|2|3|4|0  # Urgent|High|Normal|Low|None
    updatedAt: <ISO timestamp>
    sortOrder: <number>
    labels: [<label name>, ...]
```

### 3. Read individual issue (with optional blockers/blocking)

**Input:**
- `issue_id` (e.g. `<TEAM>-N`, required)
- `include_blockers` (default true — fetch issues this one is `blocked_by` or `blocks`)

**Protocol:**
1. Call `mcp__linear-tactic__linear_getIssueById` with the identifier.
2. If `include_blockers`, query the relations and fetch each related issue's summary (id + title + state).

**Output:**
```yaml
issue:
  id: <uuid>
  identifier: <TEAM>-N
  title: <string>
  description: <markdown>
  state: <name>
  priority: <number>
  project: { id, name }
  labels: [...]
  assignee: <name or null>
  createdAt: <ISO>
  updatedAt: <ISO>
  url: <linear URL>
blockers:    # if include_blockers
  blocked_by: [{identifier, title, state}, ...]
  blocks: [{identifier, title, state}, ...]
related: [{identifier, title, state}, ...]
```

### 4. Read map-frontier (takeable children of a map)

**Input:** `map_id` (the map issue's UUID or identifier).

**Protocol:**
1. Fetch the map's children (sub-issues). Filter to: state Todo, unclaimed — delegate null (query via the GraphQL bridge — `delegate` isn't exposed by the tactic MCP; same token reference as issue-management claim Step 6), `assignee: null`, no open `blocked_by` relation.
2. Return with type labels — the caller routes by label (`research`/`prototype`/`grilling`/`task` → their resolvers; `build` → a conductor). Ordering: priority (Urgent → Low), then `createdAt` ascending. Note: `build` children labeled `ready-for-agent` also surface in the generic `work frontier` (SKILL.md > Frontier convention) — they are takeable without a map session.

**Output:**
```yaml
frontier:
  - identifier: <TEAM>-N
    title: <string>
    type_label: research | prototype | grilling | task | build | none  # none = malformed, surface it
    priority: <number>
```

### 5. Read documents (on an issue)

**Input:** `issue_id`; optional `document_id` for one document's content.

**Protocol:** `mcp__linear-tactic__linear_getIssueDocuments` for the list; `mcp__linear-tactic__linear_getDocumentById` for content. Note for gate callers: the charter is always fetched by `document_id` directly — never by walking the map issue.

### 6. Read project metadata (rarely-needed)

**Input:**
- `project_id` (UUID) OR `project_name`

**Protocol:**
1. If only `project_name` given: this is the ONLY case where `linear_getProjects` name-match is acceptable — a help-the-user-find-the-UUID operation, never a fallback for a missing frontmatter UUID (SKILL.md > Project ID handling). Match by name; if 0 or >1 matches, surface to caller.
2. Otherwise call `mcp__linear-tactic__linear_getProjects` with filter for the UUID.

**Output:**
```yaml
project:
  id: <uuid>
  name: <string>
  description: <string>
  state: <status>
  health: <health>
  url: <linear URL>
  teamId: <uuid>
```

## Failure modes

- **Project ID not found:** Linear API returns null or error; surface with clear message including the queried UUID.
- **Issue identifier malformed:** validate the `<TEAM>-<N>` shape before calling; reject early.
- **Linear API down or rate-limited:** propagate the error; do not retry blindly (the caller decides — closeout might pause; a read-only session-start can degrade gracefully).

## What this playbook does NOT do

- Does NOT write. Mutations live in `issue-management.md` and `project-updates.md`.
- Does NOT analyze (stale-debt, themes). Returns raw lists; analysis is `analysis.md`.
- Does NOT cache across invocations. Each call is fresh.
