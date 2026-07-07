# Triage

Playbook for `triage` (current-project scope) and `triage-all` (everything). **Pull-only: this playbook runs ONLY when the operator explicitly invokes it** — never from session-start, session-closeout, or any automated lane. The statusline's `📥 Knowledge Triage Queue (scoped) → All (total)` line is the standing signal; this is the verb.

## Scope resolution

- `triage` → items whose scope tags match the current context: cwd under `Projects/<Name>` → `project/<kebab-name>`; `System/` → `project/system`. **Wiki-rooted → the WHOLE queue** (Wiki is the queue's home, not a project silo — operator ruling 2026-07-06 after the first live run caught 1 of 11 items; a Wiki-rooted `triage` behaves as `triage-all`, grouped by scope). No matches → say so in one line and offer `triage-all`.
- `triage-all` → every pending item, grouped by scope.

## Flow

### 1. Opening frame (one short block)

Read all pending items in scope (frontmatter + body). Summarize:

> N pending — {by scope: 6 Home Assistant, 3 Strategy, 1 System}. {M} look mechanical (frontmatter/link fixes with a clear proposed action), {K} need judgment.

"Mechanical" = the item's proposed action is a deterministic edit within existing decision authority (frontmatter fields, tag additions, index entries, link fixes). "Judgment" = anything touching substance, destination choices, contradictions, proposals, expiry decisions.

### 2. Menu (AskUserQuestion — clickable, one question)

Offer paths (only those that apply):
- **Mechanical batch** — apply all mechanical items' proposed actions in one confirmed sweep
- **By scope** (triage-all only) — pick a project/domain group to work through
- **One by one** — oldest first
- **Just list them** — table (item, kind, age, one-line ask), then stop

The menu is optional scaffolding: if the operator gives a direct instruction at any point ("fix the HA ones, expire the rest"), drop the menu and execute.

### 3. Per-item / per-batch adjudication

For each item (or batch), present: the question, the evidence, the proposed action — then AskUserQuestion options: **Apply / Skip / Expire / Discuss**.

- **Apply** → execute the proposed action within existing decision authority (mechanical edits autonomous; substance edits still require the item to carry explicit approval semantics — when in doubt, the action was judgment, confirm what was decided). Mark item `status: resolved` via `update_frontmatter`, append a one-line `resolution:` note.
- **Skip** → stays `pending`, untouched. No aging escalation exists; skipped means skipped.
- **Expire** → `status: expired`. Guilt-free discard of a question that stopped mattering.
- **Discuss** → converse; land on one of the above.

Batched items (one file covering N subjects) resolve atomically — that is why they were batched.

### 4. Exit

Whenever the operator says stop, or scope is exhausted. Close with one line: `Resolved X, expired Y, skipped Z — queue now (scoped)/(total).` Anything untouched simply remains; there is no follow-up nag surface.

## Hard rules

- Never auto-fire. Never run from an orchestrator. (History: a closeout-attached drain was built and operator-rejected 2026-07-06 — session boundaries are not task surfaces.)
- Resolved/expired items are never deleted by this playbook (deletion is the operator's, per Wiki stop rules); they stop counting everywhere and a later cleanup can prune them.
- Zero writes outside `Wiki/Queue/` item frontmatter and the Apply actions' own targets.
