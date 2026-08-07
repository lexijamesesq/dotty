# Playbook: close-map

Orchestrates the map-close ending sequence end to end — the executable form of wayfinder's "The ending" (SKILL.md § Decide, then build). Where `closing.md`'s `mark_done` and `resolve` close individual tickets, this playbook closes the map itself: it dispatches the non-author e2e eval, gates on its verdict, writes the accounting, archives the charter, and calls through `issue-management.md`'s guarded map lane as its final gate. One invocation replaces what the operator previously drove by hand through batched `update issues` calls.

## Input

```yaml
map_id: <TEAM>-N                     # required
consistency_lens:                    # optional — for system-of-text deliverables
  scope: <string>
  description: <string>
```

## Protocol

1. **Verify preconditions.** Run all checks before refusing — aggregate failures into a single checklist so the operator sees everything that's missing, not one item per invocation.

   a. **Load the map.** Fetch `<map_id>` via `mcp__linear-tactic__linear_getIssueById`. Verify it carries the `map` label. Verify it is In Progress.

   b. **Check for open challenges.** Fetch the map's comments (`mcp__linear-tactic__linear_getComments`) and check for an open `[CHALLENGE]`-prefixed comment — open meaning no `[CHALLENGE-RESOLVED]` reply follows it.

   c. **Check children.** Query the map's children via `mcp__linear-tactic__linear_getIssues` filtered to the map's id as parent. Every child must be Done or Canceled — name each open child with id, title, and current state.

   d. **Locate the charter.** Fetch the map's documents via `mcp__linear-tactic__linear_getIssueDocuments`. Find the document carrying the `FINALIZED` marker. Record its document id — every later step that touches the charter uses this id, never a fresh search.

   e. **Verify build-ticket validations exist.** For each Done child labeled `build`, fetch its comments and confirm a `[VALIDATION]`-prefixed verdict comment exists. A Done build child with no `[VALIDATION]` comment is a data error — closing never lets a build ticket reach Done without one, so its absence means something bypassed the gate. Add it to the failures list. Collect each verified ticket's id and title — Step 2's eval brief carries these as pointers; the eval fetches the verdict content itself.

   **If any check failed**, refuse with the full list in `refusal_reasons` — no partial orchestration, no eval dispatch. The operator gets one checklist covering everything that needs attention.

2. **Dispatch the e2e eval.** Spawn `` `@attack-kitty` `` via the Agent tool at model `fable` with a `map-close-eval` mandate — the tier the mandate card itself calls for (`playbooks/map-close-eval.md` in the attack-kitty skill), never the work's label. **The brief carries pointers, not pre-digested content** — `@attack-kitty` fetches its own evidence, matching the estate's validator-fetches-its-own-evidence law (`closing.md` Step 1: the validator fetches the ticket itself and checks its labels, never trusting the caller's assembly). Record the dispatch time before spawning — Step 3's freshness anchor needs it.

   The mandate inputs:

   ```
   Mandate type: map-close-eval

   Map issue id: <map_id>

   Charter document id: <charter_doc_id>

   Build tickets (pointers only — attack-kitty fetches each one's own
   [VALIDATION] comments itself):
     <id> — <title>
     ...

   Consistency lens (system-of-text deliverables only — omitted otherwise):
     Scope:       <consistency_lens.scope>
     Description: <consistency_lens.description>
   ```

`@attack-kitty` carries the full eval protocol — fetching the map's Destination and charter itself, attacking the seam between ticket verdicts, and the `[VALIDATION]` verdict format — in its `map-close-eval` mandate card. This playbook hands it the inputs; it does not restate the protocol.

3. **Gate on the verdict.** After the subagent completes, read the map's comments. Find the newest `[VALIDATION]`-prefixed comment **postdating the dispatch recorded in Step 2** — a stale CONFIRMED from a prior attempt must not close a different assembly (the same anchoring pattern as `closing.md`'s idempotent recovery and `fidelity-gate.md`'s consumption check, both keyed off a timestamp that scopes the receipt to the work it actually graded). Verify its Mode line carries a spawn execution id — an id-less verdict is treated as self-posted, not a verdict.

   - `CONFIRMED` → proceed to Step 4.
   - Any other verdict (`REFUTED`, `CONFIRMED-WITH-GAPS`, `CHARTER-CONFLICT`) → post a `[HANDOFF]`-prefixed comment on the map summarizing the verdict and what it names — `[HANDOFF]` because wayfinder's sweep already reads it, and a non-CONFIRMED close attempt is the next session's entry context. Stop. The map stays In Progress; the operator adjudicates from here — this playbook never re-dispatches or negotiates the verdict.

4. **Write the accounting.** Fetch each Done child's comments — its receipts. Write a plain-speech accounting document on the map via `issue-management.md`'s `attach_document` action. Title: "Accounting — <map title>". Content: what each ticket delivered, drawn from the tickets' own receipts — not this playbook's summary of the eval.

5. **Archive the charter.** Archive the charter document (the id recorded in Step 1d) via `issue-management.md`'s `archive_document` action — it posts a comment on the map with the retained link.

6. **Set Done.** Call through to `move_state` with `state: Done` on `<map_id>` (`issue-management.md`). Its guarded map lane re-verifies all four gates independently — the `[VALIDATION]`-prefixed CONFIRMED comment, zero open children, the accounting document, the archived charter. This playbook does not shortcut that re-check by asserting the gates are already met. If `move_state` refuses, surface exactly what it names as missing — the two checks are meant to disagree only when something changed between Step 3 and Step 6 (a late comment, a reopened child), and that disagreement is itself the signal worth surfacing.

## Output

```yaml
map_id: <TEAM>-N
status: done | routed_to_operator | refused
verdict: <verdict from e2e eval, if dispatched>
accounting_document_id: <id, if written>
charter_archived: <bool>
refusal_reasons: [<string>, ...]
```

- `status: done` — Step 6 succeeded; the map is Done.
- `status: routed_to_operator` — the eval returned a non-CONFIRMED verdict (Step 3); the map stays In Progress awaiting her adjudication.
- `status: refused` — a precondition failed before the eval ever dispatched (Step 1); `refusal_reasons` names what.

## What this playbook does NOT do

- Does NOT bypass `move_state`'s map lane — Step 6 calls through it, and its independent re-verification of all four gates is the actual close; this playbook's own gate-checking is a precondition, not a substitute.
- Does NOT define what the e2e eval should find — the eval assesses the Destination and charter on its own reading; this playbook hands it pointers, never a verdict to confirm.
- Does NOT handle mid-map work — charting, sweeping, and decision-ticket resolution live in wayfinder; this playbook starts only once the last build ticket has closed.
- Does NOT re-validate individual build tickets — slice-level validation happened at each ticket's `mark_done`; Step 1e verifies those verdicts exist, it doesn't re-run them.
