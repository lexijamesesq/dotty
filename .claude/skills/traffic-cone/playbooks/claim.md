# Playbook: claim

## Purpose

Admit and execute a ticket claim: run `cone_preflight.py`'s deterministic checks, rule on any deferred judgment items, then execute via `linear_bridge.py`.

## Input

```yaml
issue_id: <TEAM>-N
project_id: <uuid>                  # required for a real C6 check — absent it, wip_check never runs and C6 auto-PASSes unchecked
operator_directed: true|false       # permits claiming a non-Todo ticket at the operator's direction
autonomous: true|false              # suppresses assignee-setting (frontier pickups)
caller_ack_wip: true|false          # explicit override of a WIP collision (C6) — a related/dependent chain, not a silent switch
delegated_preflight_passed: true|false   # /implement's pre-flight already admitted this build ticket
```

## Run

1. Resolve `linear.gql_bridge_cmd` (CLAUDE.md > Configuration) into `LINEAR_GQL_CMD` first — exit 2 means this step was skipped.
2. `cone_preflight.py claim <issue_id> --project-id <project_id> [flags]`. `REFUSE`/`NEEDS_INPUT` → stop; return exactly what's missing. `JUDGMENT_REQUIRED` → rule on every `judgment_items` entry before proceeding.
3. `ADMIT` (or judgment cleared) → `linear_bridge.py claim-write <uuid> --state <facts.state_ids.in_progress> --delegate <facts.viewer_id> [--assignee <op id> when facts.assignee_gate=="set"]`. Read-back + race check are built in — a lost race means back off and report, never proceed.
4. `NEEDS_INPUT` itself executes: `set-state` to Needs Input plus a routing/proposed-conditions comment via `mcp__linear-tactic__linear_createComment` (through `lint-body` first) — no delegate release; no claim exists yet.

`/linear`'s `playbooks/claim.md` stays the source of variant *law* (selector semantics, the mapped-ticket sanction) — this card runs the mechanics, not a re-derivation.

The script also serves `/implement`'s own pre-flight via `--conductor-preflight` (check-only, per `/implement` § Pre-flight check) — that flag is never an input to this card: `/implement` invokes the script directly and spawns this card with `delegated_preflight_passed` only after its check admits. A spawn prompt carrying `conductor_preflight` is mis-composed; field it to that shape.

## Judgment kernel

- **J-C8 — model label.** A `model:*` label is present: does the session's own model match (class, or exact version if pinned)? Disposition rule: `/linear`'s `playbooks/claim.md:25`.
- **C6 override disposition.** Before `--caller-ack-wip`: a related/dependent chain, or a silent switch? Disposition rule: `/linear`'s `playbooks/claim.md:29`.
- **C2 proposal composition.** Routing a deferred/missing Done When to Needs Input means composing proposed conditions as the routing comment.
- **C12 — full variant only.** What the script can't adjudicate: session-scoped WIP dialogue, Objective currency, sizing (Too Big), proof-first breakdown — `<piece> — proven when <proof> at <seam>`.

## Refusal law

Return exactly what's missing — never fix, retry, or negotiate a ticket into passing.

## What this playbook does NOT do

- Does NOT pick a ticket — frontier selection is the caller's job.
- Does NOT author or repair ticket content — a missing Objective or Done When is reported, not filled in.
- Does NOT run the build-ticket pre-flight check — that's `/implement`'s.
- Does NOT decide when `mark_done`/`resolve` are legal — `playbooks/closing.md`.
