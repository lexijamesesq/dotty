---
name: traffic-cone
description: Correctness layer for lifecycle transitions — verifies tickets are well-formed, receipts are legitimate, and transitions are earned, then executes them directly via the fused script path. Invoked at the point a ticket or map needs to move through claim, begin, mark_done, park, block, un-park, cancel, or close-map.
---

# /traffic-cone

The transition law for a mission record's lifecycle — `claim`, `begin`, `mark_done`, `park`, `block`, `un-park`, `cancel`, `close-map` — and the scripts that carry it. There is no agent: the caller (map session, ad-hoc session, headless lane) runs the fused script itself, in its own process, and consumes the verdict. "Routes through traffic-cone" means through `cone_preflight.py` and `linear_bridge.py` — never a spawn.

Lifecycle transitions route through `` `@traffic-cone` ``; `` `@attack-kitty` `` executes none.

## Scripts

`cone_preflight.py` (`.claude/skills/linear/scripts/`) runs the per-verb deterministic checks — never mutates on its own — and prints `ADMIT | REFUSE | NEEDS_INPUT | JUDGMENT_REQUIRED` plus the `facts` an execute step needs. `linear_bridge.py` carries the GraphQL bridge transport and every mutation's built-in read-back. `--execute-if-clean` fuses check → judgment-free execute → read-back into one process: an ADMIT with zero judgment items executes in-process; REFUSE/JUDGMENT_REQUIRED stop before any mutation call. `LINEAR_GQL_CMD` is set in the environment (`settings.json`, mirroring `linear.gql_bridge_cmd` — CLAUDE.md > Configuration), so scripts resolve the bridge with no per-call step; `--bridge-cmd <path>` overrides it as the escape hatch. Exit 2 means neither resolved. `--list-checks <verb>` prints the full Check Inventory for that verb — the audit surface for which check lives where.

## Dispatch table

| Verb | Fused invocation |
|---|---|
| `claim` | `cone_preflight.py claim <id> --project-id <uuid> --execute-if-clean` — `--project-id` **required**: absent it, refuses with a config-gap message (without it `wip_check` never runs and C6 auto-passes unchecked). Conditional flags: `--operator-directed` (claim a non-Todo ticket at the operator's direction), `--autonomous` (frontier pickup, no operator present — suppresses the assignee-set), `--caller-ack-wip` (acknowledge a WIP collision as a related chain — C6 kernel) |
| `begin` | `cone_preflight.py begin <id> --execute-if-clean` — Planning → In-Progress, once the slice's plan is attacked. `--plan-attested` asserts BG2's judgment kernel (hitl: operator-aligned + plan-attack ran; afk: plan-attack ran); absent it, the gate returns `JUDGMENT_REQUIRED` and the slice stays in Planning |
| `mark_done` | `cone_preflight.py mark_done <id> --execute-if-clean` — optional `--closing-comment-file <f>`, `--deterministic-exempt --deterministic-exempt-context <ctx>` |
| `park` | `cone_preflight.py park <id> --execute-if-clean --comment-file <ask.txt>` |
| `block` | `cone_preflight.py block <id> --execute-if-clean --comment-file <condition.txt>` |
| `un-park` | `cone_preflight.py un-park <id> --execute-if-clean` — with `--operator-directed` or `--blocker-verified` |
| `cancel` | `cone_preflight.py cancel <id> --execute-if-clean --comment-file <reason.txt>` — optional `--related-id <uuid>` |
| `close-map` | never fused — `playbooks/close-map.md`'s own staged `--reverify` shape, run by the map session itself |

## Result handling

- **ADMIT, `executed: true`** → done. The report's `result` carries the mutation's own read-back-verified data — never a mutation call's raw return value.
- **REFUSE** → binding. Return exactly what's missing, from the report's `checks`/`facts`. Never re-run hoping for a different verdict; never hand-edit ticket state around a refusal.
- **NEEDS_INPUT** → already executed in-process — the routing or park state-change and its comment are posted. Nothing further.
- **JUDGMENT_REQUIRED** → rule on every `judgment_items` entry per the kernel below, then re-run with the matching assertion flag — except M3g, which resumes only after `@attack-kitty`'s `ticket-close` mandate lands its receipt.

## Judgment kernels

Each item: the question, who rules it, how a ruled re-run resumes.

- **J-C8 — model label.** A `model:*` label is present: does the session's own model match (class, or exact version if pinned)? Caller — only the session knows its own model. Resumes: `--model-ruled`.
- **C6 — WIP override.** Before `--caller-ack-wip`: a related/dependent chain, or a silent switch? Caller — its own intent; disposition rule is `/linear`'s `playbooks/claim.md` Step 2 law, absorbed here by pointer.
- **C2 — proposal composition.** Routing a deferred/missing Done When to Needs Input means composing proposed conditions as the routing comment. Caller composes it; no spawn occurs on this path.
- **C12 — full-variant claim judgment.** What the script can't adjudicate: session-scoped WIP dialogue, Objective currency, sizing (Too Big), proof-first breakdown — `<piece> — proven when <proof> at <seam>`. Caller — absorbed from `/linear`'s `playbooks/claim.md` Steps 3–5 by pointer; the law itself stays there.
- **R-A — attestation line.** The composing session owns its ask's specificity — park's ask, block's condition, cancel's reason is the caller's to compose and supply via `--comment-file`; the script posts it and executes, never judges whether it's specific enough.
- **U1 — blocker resolution.** Absent `--operator-directed`, is the named blocker verifiably resolved against the condition on record? Caller/operator-directed — the un-parking session re-checks the condition itself (self-knowledge) and attests via `--blocker-verified` (R-C). (`--operator-directed` is verb-scoped: here it means the operator directed the un-park; on `claim` it separately gates non-Todo claims.)
- **M-d — deterministic exemption.** `--deterministic-exempt` asserted: is the captured output actually applicable? Caller judgment; when in doubt, not exempt. Resumes: `--exempt-ruled`.
- **M-o — Objective drift.** Feedback that would change the Objective is not receipt input — refuse, route to the operator, never fold it into the transition. No resume flag — this always refuses.
- **M3c — type match on regex miss.** No literal `Validation mandate: <type>` found: does the Done When text name a mandate in other words? Caller rules; if the Done When is genuinely silent, refuse — no mandate named. Resumes: `--mandate-type <t>`.
- **M3g — receipt coherence (full variant only).** No map, so no downstream audit ever reaches this ticket (map children get CM6 at close-map instead) — dispatch `@attack-kitty`'s `ticket-close` mandate (existing, unmodified; judgment, zero execution) and get a CONFIRMED `[VALIDATION]` receipt. Resumes: `--receipt-audited <comment-id>`, verified mechanically — must postdate the ticket's current In Progress claim.

## X-park posture

Every point that would otherwise ask a live operator degrades to a park — Needs Input, with the specific ask in a comment. No check in `claim`, `mark_done`, or `close-map` assumes a live foreground exchange; "operator not present" is the default case this law is built for. The one place a live exchange genuinely matters — a HITL decision ticket's resolution — sits outside the gate's mechanical scope: the map session produces the decision in live exchange, and the session posts the `[VALIDATION]` recording it (as the app actor — never the operator's own account), before `mark_done` ever runs.

## Read it yourself

Every check runs against the script's own fresh fetch — the ticket, its comments, its parent map, as the verb requires — never a caller's summary of where things stand. A check run against a caller's framing instead of a fresh read is not a check.

## Refusal law

Return exactly what's missing — no receipt, stale receipt, type mismatch, malformed receipt, missing resolution comment, an ask/condition/reason with nothing on record and no `--comment-file` supplied. Never fix, retry, negotiate, or re-spawn a validator hoping for a different answer — that's the caller's next act, not this law's.

## Mention escaping

Backtick-escape agent names in anything these scripts post — `` `@linear` ``'s SKILL.md carries the full rule; what's new here is that `linear_bridge.py`'s `lint-body` enforces it mechanically before every post.

## Pointers

- `playbooks/close-map.md` — the one surviving playbook; `close-map`'s staged shape, run by the map session.
- `playbooks/mutation-record-spec.md` — how mission records may legally be mutated: mutate-in-place vs. append, current-truth vs. evolution mode, foundation-record authorization, the marking scheme. Load before any check step that touches something other than a fresh append (ticket description edits, map body edits).

## What this law does NOT do

- Direct work — pick which ticket to work, decide what the work should be, or author it. That's the caller's job; this law enforces shape and executes transitions.
- Judge a gate beyond receipt verification — `@attack-kitty` judges the work itself; the scripts verify a `[VALIDATION]` receipt exists, is fresh, and matches what's required.
- Compose a mandate for `@attack-kitty` — the caller dispatches the validator before running a closing verb; these scripts check that the verdict landed, never negotiate or re-dispatch it.
- Author ticket content (objectives, done-when, descriptions) — the caller authors; shape is enforced (the admission test, the decision-type guard), intent is never composed here.
- Chart maps, cut tickets, or resolve HITL decisions — that's wayfinder's live-exchange work, upstream of everything here.
- Author or dispatch a slice's work — that's the working session's job, not the gate's.
- Pick which ticket to work next — frontier selection is the caller's job; these scripts act on a named ticket or map.
