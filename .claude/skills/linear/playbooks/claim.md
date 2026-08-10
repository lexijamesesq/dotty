# Playbook: claim

Set the claim (stored in the `delegate` field) with the discipline the ticket's shape demands. Three variants — full, map-child, build thin-redirect — selected by the ticket's parent and type label.

## Input

```yaml
issue_id: <TEAM>-N                  # required
operator_directed: true|false       # permits claiming a non-Todo ticket at the operator's direction
autonomous: true|false              # suppresses assignee-setting on autonomous frontier pickups (work frontier)
```

## Protocol

**Step 0 — Select the variant.** Fetch the issue via `mcp__linear-tactic__linear_getIssueById`. The issue itself carrying the `map` label → refuse: maps are never claimed — map close is `` `@traffic-cone` ``'s `close-map` playbook, which verifies this skill's `transitions.md` map-lane conditions directly and executes the transition itself. Claim requires state Todo unless the caller passes `operator_directed: true`.

**Mapped-ticket check (direct pickups).** If the fetched issue has a `parent`, fetch the parent (once — cache it) and check its labels — a `map` label makes this a map child. Mapped → announce it ("mapped ticket — child of `<parent title>`, type `<label>`") and, unless this session is already running **the map that is this ticket's parent** (wayfinder's own flows invoke claim from inside work-through and charting), or is `` `@traffic-cone` `` executing a delegated claim (the orchestrator already verified routing — wayfinder selected the ticket or `/implement` pre-flighted it; `` `@traffic-cone` ``'s own `claim.md` ran its admission checks before invoking this protocol), do NOT complete a bare claim here: surface the wayfinder invocation to the operator — "run `/wayfinder`, work the map with this ticket named" — since wayfinder is operator-invoked; the map's flow then claims it under the right discipline. **Exception: a `build` child labeled `ready-for-agent`** — the selector below thin-redirects to `/implement` rather than to wayfinder; the claiming session becomes the ticket's conductor once `/implement`'s pre-flight check and claim complete, no map session required. A closed or canceled parent → surface, don't route: "mapped to a closed map — needs disposition." Parent without a `map` label = an ordinary sub-task; no parent = standalone — both announce "un-mapped ticket — standard lifecycle" and run the full variant below.

**Selector — parent + type label:**
- Parent is `map`-labeled + type label `research`/`prototype`/`grilling`/`task` → **map-child variant**: skip Steps 1–5; go to the assignee gate, then Step 6 (delegate-set + In Progress, read-back verified). The ticket body is the brief; no attestation.
- Parent is `map`-labeled + type label `build` → **thin redirect**: the build-ticket pre-flight check — contract verification, the charter's FINALIZED check, the `ready-for-agent` check, the open-challenge check, and their refusal routing — is `/implement`'s law now. Surface "build ticket detected — invoke `/implement <id>`" and stop, unless this session is already running `/implement` for this ticket and its pre-flight has already passed, or is `` `@traffic-cone` `` executing the claim after `/implement`'s pre-flight admitted it: then proceed straight to the assignee gate and Step 6 below.
- Conflict cells, all refuse with a routing comment + Needs Input: `build` label with a `## Question` body; a map child with no type label; a `build` label on a ticket with no map parent.
- No map parent → **full variant**: Steps 1–6 below, unchanged.

Regardless of variant: announce a `model:*` label when present; if this session will author the work itself and its own model mismatches the label (class — or exact version when pinned), surface to the operator before any work: proceed here or relaunch at the labeled model. Headless, park at Needs Input per the standard routing.

**Step 1 — Read the ticket.** Read comments via `mcp__linear-tactic__linear_getComments`. Check relations for blockers.

**Step 2 — WIP check.** Scoped to claims *this session* made — tickets this conversation has itself claimed. A sibling session's In Progress ticket isn't a switch candidate — the frontier already excludes it (unclaimed only). If this session has already claimed a ticket, surface it: "You have ABC-12 in progress (claimed this session). Is this work related (dependent chain) or a switch?" If a switch, the prior ticket moves to Needs Input with a comment explaining the pause.

**Step 3 — Understand the problem.** Parse the description for the four sections:

- **Objective:** must be present and non-empty.
  - Present and current → proceed.
  - Present but stale or missing → propose an update as a comment on the ticket and route to the operator. The Objective is what the validator grades intent against — it carries the same authority as Done When.
- **Done When:** the operator's spec — what the work is measured against.
  - Concrete conditions present → these are the spec. Quote them verbatim in the attestation.
  - Deferral marker present (`_to be set at claim_`) or missing → propose conditions as a comment on the ticket, move the ticket to Needs Input, stop. Do not proceed to Steps 5–6. When the operator confirms, a new `claim` invocation picks up the ticket with hardened conditions.
- **Constraints and Context:** review for currency.

**Objective and Done When edits are spec changes.** Any edit to either — by any action, at any point in the lifecycle — routes to the operator. The session does not self-classify edits as fact corrections vs. intent changes.

**Step 4 — Size the ticket.** If Done When contains multiple independently shippable outcomes, apply the **Too Big** label and propose a decomposition to the operator.

**Step 5 — Break down the work.** Before the middle starts, plan proof-first:

- **Objective:** one-line restatement of what the work achieves
- **Done When:** quoted verbatim from the ticket
- **Pieces:** the session's breakdown of the work, each piece named by the proof that will complete it and the seam where that proof gets observed — `<piece> — proven when <proof> at <seam>`. A piece with no named proof isn't a piece yet.

The pieces run proof-first — the proof is named before the piece is built, and the proof existing is what completes it. This is the plan for the middle, held before the middle starts.

**The seams are the operator's beat.** When she's in the session, put them to her before the work starts and adjust to her answer — the validation plan is hers to agree, and after that the middle is the session's to run.

Each piece's proof becomes a dated progress comment naming its artifact; that accumulation is the `evidence` manifest `mark_done` requires. The validator there grades the ticket's Done When, not the session's own breakdown.

**Map-child assignee gate (all map children, before Step 6).** For any map child — map-child variant or build variant — check the issue's labels: `hitl` loop label → set `assigneeId` alongside delegate in Step 6 (co-engagement — the operator is in the exchange). `afk` loop label or `build` type label → skip assignee-setting (autonomous resolution, no operator present).

**Step 6 — Set In Progress.** The claim is one GraphQL mutation: resolve the claiming actor's id via `mcp__linear-tactic__linear_getViewer`, then resolve the operator's user id via `mcp__linear-tactic__linear_getUsers`. Set `stateId=<In Progress for issue's team>` and `delegateId=<viewer id>` together — self-delegation is the claim. By default, the same mutation also sets `assigneeId=<operator id>` — a ruled exception to assignee-is-the-operator's-field (co-engagement record). Two opt-outs suppress the assignee-set: (1) `autonomous: true` (frontier pickups — no operator present); (2) the map-child assignee gate above ruled it out (afk loop label / build type label). Assignee is additive — claim sets it, but never clears it; clearing is the operator's act.

`delegateId` isn't exposed by the tactic MCP, so the write goes through `linear_bridge.py claim-write <issue-uuid> --state <state-id> --delegate <viewer-id> [--assignee <operator-id>]` (`.claude/skills/linear/scripts/`; `--bridge-cmd` or `LINEAR_GQL_CMD` resolved via `linear.gql_bridge_cmd` per CLAUDE.md > Configuration — never a literal bridge or secret path in skill text, public repo). The script performs the mutation and its own read-back in one call, reporting `verified`/`race_lost` in its JSON output.

- **Read-back verify (the race check).** Built into `claim-write`: `issueUpdate` is last-write-wins, so after the write it re-fetches the delegate. Not this session's actor → a concurrent session won the claim; back off and report — never proceed on a lost race.
- **Discipline (delegation is the claim).** The delegate is the claim; an In Progress ticket with no delegate is a data error to surface — with one exception: an issue that ITSELF carries the `map` label. In Progress with no delegate is the map's normal signature (maps are never claimed); the rule stands for everything else, including map children.

## What this playbook does NOT do

- Does NOT pick a ticket or drive the loop to close — frontier selection and one-per-session looping are the calling orchestrator's job (a conductor or frontier-pickup session, using `playbooks/frontier.md` to find candidates). This playbook is the mechanical protocol `` `@traffic-cone` ``'s `claim` verification runs directly once a ticket is selected and admitted.
- Does NOT run the build-ticket pre-flight check — that's `/implement`'s.
- Does NOT decide when `mark_done`/`resolve` are legal — `playbooks/transitions.md` (mechanics) and `` `@traffic-cone` `` (the gate).
