# Triage

Playbook for `triage` (current-project scope) and `triage-all` (everything). **Pull-only: this playbook runs ONLY when the operator explicitly invokes it** — never from session-start, session-closeout, or any automated lane. The statusline's `📥 Knowledge Triage Queue (scoped) → All (total)` line is the standing signal; this is the verb.

## Scope resolution

- `triage` → items whose scope tags match the current context: cwd under `Projects/<Name>` → `project/<kebab-name>`; `System/` → `project/system`. **Wiki-rooted → the WHOLE queue**, grouped by scope (Wiki is the queue's home, not a project silo). No matches → say so in one line and offer `triage-all`.
- `triage-all` → every pending item, grouped by scope.

## Voice — how items reach the operator

Triage is a conversation with a person, not a report to a session. Hard presentation rules:

- **Speak each item's three parts conversationally** — what this is, why I'm stuck, what her answer changes — read from the item body. Never paraphrase back into machine terms.
- **Never render machine vocabulary.** No filenames, slugs, check ids, kind enums, tag syntax, frontmatter keys, or lane names in anything shown to the operator. That detail stays in the items' `## Mechanics` sections and in this playbook's bookkeeping.
- **Never render a slug table.** Any list of items (grouped by scope or not) uses each item's plain question as the line item — one question per line, grouped under plain domain names ("Home Assistant", "Strategy"), nothing else.
- **Options are her answers, not our verbs.** AskUserQuestion options carry the natural answers to the item's question, labeled by consequence — e.g. "Finished (I'll archive them)" / "Still active (leave as-is)" / "Skip for now" — never the internal dispositions (apply/skip/expire). Map her choice to the internal disposition afterward, silently.
- **Legacy items get translated.** If an item's body predates the three-part voice (no human ask, machine-voiced finding), compose the three parts at presentation time from its content — never read a machine body at her verbatim.

## Flow

### 1. Opening frame (one short block, plain terms)

Read all pending items in scope (frontmatter + body). Summarize in words a person plans around — how many, how heavy, what domains:

> 11 waiting — 7 you can answer in a word or two; 4 need you to tell me where something lives or make a small call. Mostly Home Assistant and Strategy, a few System.

"A word or two" = the item's fork closes with a one-word answer (yes/no, finished/active) and the consequence is a deterministic edit within existing decision authority. "Need more" = anything requiring her to supply a location, a fact, a destination choice, or a policy call.

### 2. Menu (AskUserQuestion — clickable, one question)

Offer paths (only those that apply), in plain terms:

- **Do the quick ones** — walk the one-word-answer items in one fast pass
- **By area** (triage-all only) — pick a domain group ("Home Assistant", "Strategy", …) to work through
- **One at a time** — oldest first
- **Just show me the list** — the plain questions, one per line with age, then stop

The menu is optional scaffolding: if the operator gives a direct instruction at any point ("archive all the alarm stuff, drop the rest"), drop the menu and execute.

### 3. Per-item / per-batch adjudication

For each item (or batch), speak the three parts, then AskUserQuestion with:

- the item's own **natural answers**, each labeled with its consequence ("Finished — I'll archive all six", "I have the PDF — I'll ask where"),
- **Skip for now** — always present,
- **Drop it** — the question stopped mattering; guilt-free.

Any freeform reply is a conversation — discuss, then land on one of the above. Never force the menu.

Internal mapping (bookkeeping — never shown):

- Natural answer chosen → execute its consequence within existing decision authority (mechanical edits autonomous; substance edits still require the item to carry explicit approval semantics — when in doubt, confirm what was decided). Mark item `status: resolved` via `update_frontmatter`, append a one-line `resolution:` note.
- **Skip for now** → stays `pending`, untouched. No aging escalation exists; skipped means skipped.
- **Drop it** → `status: expired`.

Batched items (one file covering N subjects) resolve atomically — that is why they were batched.

### 4. Exit

Whenever the operator says stop, or scope is exhausted. Close in the same plain register: `Answered 4, dropped 1, left 6 for later — 6 still waiting.` Anything untouched simply remains; there is no follow-up nag surface.

## Hard rules

- Never auto-fire. Never run from an orchestrator. Session boundaries are not task surfaces.
- Never render slugs, filenames, check ids, kind enums, or tag syntax to the operator — presentation is content-level only.
- Resolved/expired items are never deleted by this playbook (deletion is the operator's, per Wiki stop rules); they stop counting everywhere and a later cleanup can prune them.
- Zero writes outside `Wiki/Queue/` item frontmatter and the adjudicated consequences' own targets.
