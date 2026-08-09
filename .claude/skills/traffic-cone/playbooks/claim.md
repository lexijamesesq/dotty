# Playbook: claim

Verify a ticket is well-formed and claimable, then execute the claim directly. The mechanical protocol — variant selection, the GraphQL bridge write for `delegateId`, the read-back race check — is `/linear`'s `playbooks/claim.md`; this playbook runs that protocol itself (traffic-cone carries the same Linear tools) once its own correctness checks admit the ticket.

## Input

```yaml
issue_id: <TEAM>-N                  # required
operator_directed: true|false       # permits claiming a non-Todo ticket at the operator's direction
autonomous: true|false              # suppresses assignee-setting on autonomous frontier pickups
```

## Checks

Read the ticket directly via `mcp__linear-tactic__linear_getIssueById` — never trust the caller's framing of where it stands.

- **Objective present.** `## Objective` exists with non-empty text.
- **Done When set.** `## Done When` carries concrete conditions, not the deferral marker `_to be set at claim_` — unless the caller is deliberately setting conditions now as part of this claim, per `/linear`'s `playbooks/claim.md` Step 3 routing (a missing/deferred Done When with no conditions supplied routes to Needs Input, it does not silently pass).
- **Type label present.** One of `build`, `research`, `grilling`, `prototype`, `task` — a map child with no type label, or a `build` label with no map parent, is a conflict cell: refuse and route to Needs Input per `/linear`'s claim selector.
- **Build-lane gates (`build`-labeled tickets only).** These checks exist because `/implement`'s pre-flight runs them, and traffic-cone verifies independently — no actor trusts another's word:
  - `ready-for-agent` label is present → else refuse: "build ticket not marked ready — finalization hasn't opened the lane."
  - Charter FINALIZED: the ticket's `## Context` carries the charter's pinned document id; fetch it via `linear_getDocumentById` and verify the `**FINALIZED**` marker stands → else refuse: "charter not finalized."
  - No open `[CHALLENGE]` on parent map: fetch the parent map's comments and check for `[CHALLENGE]`-prefixed comments with no `[CHALLENGE-RESOLVED]` reply → else refuse: "charter under challenge — operator adjudicates."
- **Claimable state.** Todo (unless `operator_directed: true`), unblocked (no open `blocked_by` relation), unassigned (`delegate: null`).
- **WIP check.** No other In Progress ticket already delegated to the same claiming actor on this project. `delegate` isn't exposed by the tactic MCP — check via the GraphQL bridge. A collision blocks the claim unless the caller explicitly acknowledges the override (a related/dependent chain, not a silent switch).

The gate catches malformed tickets — structural checks that prevent work from starting on a ticket that isn't ready. It does not evaluate whether the Objective encodes purpose well or whether the Done When achieves fitness — that's the cutter's discipline. Quality lives in the cutting, not the gate.

Any check failing → refuse. Return exactly what's missing — do not propose a fix or edit the ticket to make it pass; a missing Objective or Done When is the caller's or the operator's to supply.

## Execute

All checks pass → run `/linear`'s `playbooks/claim.md` protocol directly, using the ticket already read above:

1. **Select the variant** (full / map-child / build thin-redirect) per that playbook's Step 0 selector — a mapped ticket routes to wayfinder or `/implement` per its rules rather than completing a bare claim here.
2. **Run its Steps 1–6** as written for the selected variant — WIP check, Objective/Done When parsing, sizing (the Too Big label), the map-child assignee gate, and the claim write itself.
3. **The claim write.** `delegateId` isn't exposed by the tactic MCP: write the mutation payload to a file, run the GraphQL bridge with it (resolved via `secrets.op_read` / `linear.app_token_ref` per CLAUDE.md > Configuration), read back to verify the claiming actor won the race (not a concurrent session). Set `stateId=<In Progress for the issue's team>` in the same mutation.

Reference `/linear`'s `playbooks/claim.md` for the mechanical detail — this playbook does not restate the bridge protocol, the variant selector, or the read-back verify logic; it runs them.

## Return

- **Claimed:** the ticket's new state (In Progress), the variant applied, and whether it redirected (`build` → `/implement`, map-child → wayfinder).
- **Rejected:** what's missing, named specifically enough that the caller can fix it and re-invoke. Includes a routing-to-Needs-Input outcome (deferred Done When, conflict-cell labels) — that is a legitimate claim-protocol result, not an error, but it is not a claim either.

## What this playbook does NOT do

- Does NOT pick which ticket to claim — the caller names `issue_id`; frontier selection is the caller's job.
- Does NOT author or repair ticket content — a missing Objective or Done When is reported, not filled in.
- Does NOT duplicate `/linear`'s mechanical protocol — it executes that protocol directly, with traffic-cone's own Linear tools, once its own checks admit the ticket.
