# Playbook: close-map

Verifies preconditions and the map-close `[VALIDATION]` receipt, then executes the map-close ending sequence — the executable form of wayfinder's "The ending" (SKILL.md § Decide, then build). Where `closing.md`'s `mark_done` and `resolve` close individual tickets, this playbook closes the map itself. Dispatching the non-author e2e eval — `@attack-kitty`'s `map-close-eval` mandate — happens before this playbook is invoked; the caller runs it, this playbook verifies its verdict landed and executes on it.

## Input

```yaml
map_id: <TEAM>-N
```

## Protocol

1. **Verify preconditions.** Run all checks before refusing — aggregate failures into a single checklist so the caller sees everything that's missing, not one item per invocation. Read everything directly.

   a. **Load the map.** `linear_getIssueById` on `<map_id>`. Verify it carries the `map` label. Verify it is In Progress.

   b. **Check for open challenges.** `linear_getComments` on `<map_id>`. Check for an open `[CHALLENGE]`-prefixed comment — open meaning no `[CHALLENGE-RESOLVED]` reply follows it.

   c. **Check children.** Query the map's children (issues filtered to `<map_id>` as parent). Every child must be Done or Canceled — name each open child with id, title, and current state.

   d. **Locate the charter.** `linear_getDocuments` on `<map_id>`. Find the document carrying the `FINALIZED` marker (`mutation-record-spec.md`). Record its document id — every later step uses this id, never a fresh search.

   e. **Verify build-ticket validations exist.** For each Done child labeled `build`, `linear_getComments` and confirm a `[VALIDATION]`-prefixed CONFIRMED verdict comment exists. A Done build child with no `[VALIDATION]` comment is a data error — `closing.md`'s `mark_done` never lets a build ticket reach Done without one, so its absence means something bypassed that gate. Add it to the failures list. Note each verified ticket's `[VALIDATION]` comment timestamp — Step 2's freshness check uses the latest of these.

   **If any check failed**, refuse with the full list — no partial execution, no eval-verdict check, nothing archived.

2. **Verify the map-close `[VALIDATION]` receipt.** From the comments read in Step 1b, find the newest `[VALIDATION] — map-conformance` comment.

   - **Exists.** None found → refuse: "no map-conformance receipt — run `@attack-kitty`'s `map-close-eval` mandate first."
   - **Fresh.** Its timestamp postdates every build child's own `[VALIDATION]` comment (Step 1e) — an eval that ran before the last child closed graded an incomplete map.
   - **Verdict.** `Verdict: CONFIRMED` — per `linear`'s `playbooks/comments.md`, any other verdict is never posted as a `[VALIDATION]` comment, so a non-CONFIRMED verdict landing here at all is a data error to refuse on.
   - **Schema.** Carries all four lines of the `linear` skill's `playbooks/comments.md` format.

   Any failure → refuse, return exactly what's missing. Stop — the map stays In Progress; this playbook never re-dispatches or negotiates the verdict.

3. **Write the accounting.** Read each Done child's comments — its receipts. Compose a plain-speech accounting document — "Accounting — <map title>", content drawn from the tickets' own receipts, not this playbook's summary of the eval — and attach it to the map (`linear_createDocument`).

4. **Archive the charter.** `linear_archiveDocument` on the charter (the id recorded in Step 1d) — post a comment on the map with the retained link.

5. **Set Done.** `linear_updateIssue` on `<map_id>` with `stateId=Done`, having independently re-verified all four gates immediately before the write: the `[VALIDATION]`-prefixed CONFIRMED map-conformance comment, zero open children, the accounting document, the archived charter. If any gate no longer holds — a late comment, a reopened child — refuse instead of transitioning; that disagreement between Step 2's check and this re-check is itself the signal worth surfacing, not something to paper over.

## Output

```yaml
map_id: <TEAM>-N
status: done | refused
accounting_document_id: <id, if written>
charter_archived: <bool>
refusal_reasons: [<string>, ...]
```

- `status: done` — Step 5 succeeded; the map is Done.
- `status: refused` — a precondition or receipt check failed (Step 1 or Step 2); `refusal_reasons` names what.

## What this playbook does NOT do

- Does NOT dispatch the e2e eval — the caller runs `@attack-kitty`'s `map-close-eval` mandate before invoking this playbook; this playbook verifies the verdict already landed.
- Does NOT define what the eval should find — that's the eval's own reading of the Destination and charter.
- Does NOT handle mid-map work — charting, sweeping, and decision-ticket resolution live in wayfinder; this playbook starts only once the last build ticket has closed.
- Does NOT re-validate individual build tickets — slice-level validation happened at each ticket's `mark_done`; Step 1e verifies those verdicts exist, it doesn't re-run them.
