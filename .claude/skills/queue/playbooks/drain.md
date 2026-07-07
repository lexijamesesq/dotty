# Playbook: drain

The session-closeout drain: conditionally present up to 3 pending queue items for operator adjudication. This playbook owns ALL the conditional logic — the closeout orchestrator carries one invocation line and no conditions.

## Input

- `session_scope` — the closing session's project/domain identity: its `project/<name>` tag(s) and, if the session touched Wiki-hosted content, the relevant `area/<hierarchy>` tag(s). The orchestrator passes what it knows from type detection; free-form is fine, this playbook normalizes to tag form.
- `today` — ISO date (caller passes for testability)

## Protocol

1. **Collect pending items.** Resolve `{workspace_root}/Wiki/Queue/` (vault root via the `workspace_root` config key). Read frontmatter of every item file (`mcp__obsidian__get_frontmatter` / `mcp__obsidian__get_notes_info`; the dashboard file has no `status: pending` and self-excludes). Keep only `status: pending`. For each, note: `queue-kind`, `created`, scope tags, `source`, `reasons`.

2. **Evaluate the fire conditions.** The drain fires when ANY of:
   - **(a) Scope-match:** at least one pending item carries a scope tag (`project/*` or `area/*`) matching the session's project/domain from `session_scope`.
   - **(b) Age:** any pending item's age (`today` − `created`) exceeds 14 days.
   - **(c) Backpressure:** pending count exceeds 15.

3. **If NO condition holds → silent.** Produce zero output, ask the operator nothing, return control to the orchestrator. A closeout with no queue nexus and a quiet queue must add zero cost. Do not report "queue is quiet" — silence is the success signal.

4. **If firing → select up to 3 items:**
   - Scope-matched items first, oldest first among them.
   - Then remaining items, oldest first.
   - Cap at 3 total. Everything else stays pending for a future drain.

5. **Present the selection** to the operator, one compact block per item: kind, age in days, source, reasons, scope tags, payload summary (from the body's H1 + first lines), and the item's path. **Items older than 30 days are presented as expire-candidates** — lead with `EXPIRE-CANDIDATE (Nd old)` and recommend expiry unless the operator says otherwise (prune-bias; expiry is an operator click, never silent).

6. **Adjudicate each presented item** — the operator picks exactly one action per item:

   | Action | Meaning | Execution | Resulting `status` |
   |---|---|---|---|
   | `file` | Payload belongs in the vault | Route through the filing skills (`/wiki-intake` or `/knowledge-layer query-and-file` per payload class) — their gates apply in full | `resolved` |
   | `promote` | Payload becomes tracked work | `/linear update issues` `create_followup` per `[[linear-discipline]]` integrity-on-creation | `resolved` |
   | `discard` | Judgment made: not worth acting on | No payload action | `resolved` |
   | `expire` | Aged out without adjudication | No payload action | `expired` |
   | `keep` | Operator wants it to stay pending | Nothing | `pending` (untouched) |

   Every execution runs within the EXISTING decision authority of the executing skill. The drain grants no new write authority; if a `file` action's target skill would escalate, it still escalates.

7. **Mark status** via `mcp__obsidian__update_frontmatter` — only for items the operator actually adjudicated, only to the status the table above dictates. Never mark an unadjudicated item; never mark `resolved` to make the drain look complete.

8. **Report** one line to the orchestrator: items presented, actions taken (e.g. `1 filed, 1 expired, 1 kept`), pending count remaining.

## Discipline

- **Bounded ask.** 3 items max, warm context, operator present. When the backpressure condition fired, state in the report whether the remaining pending count is still above the threshold (a 3-item pass usually won't clear an escalation — the debt line stays escalated until it does) — the operator may choose to run additional drain passes ad hoc (`/queue drain`), but this playbook never auto-extends the cap.
- **Fire conditions are exhaustive and closed.** Do not invent a fourth reason to fire ("interesting item", "operator seems available"). Zero-condition closeouts stay zero-cost or the drain becomes the interruption it exists to prevent.
- **Age math from `created` frontmatter**, not file mtime (sync and status updates touch mtime).

## What this playbook does NOT do

- Does NOT create items (that's `create-item`), and does NOT emit the passive debt line (that's `status` / the SessionStart hook).
- Does NOT delete item files — resolved/expired items stay on disk as adjudication records; pruning the directory is a separate operator decision.
- Does NOT adjudicate. Ever. Recommendation on expire-candidates is the ceiling; the click is the operator's.
