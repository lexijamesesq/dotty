# Playbook: status

Report queue + Inbox state on demand. This playbook is the CANONICAL definition of the count semantics; the statusline (`statusline/statusline.sh`) renders the passive form — `📥 Knowledge Triage Queue (scoped) → All (total)`, absent at zero, tail collapsed when equal, orange past backpressure. Change semantics here first, then mirror in the statusline.

## Input

- `today` — ISO date (optional; defaults to the current date)

## Protocol

1. **Queue side.** Resolve `{workspace_root}/Wiki/Queue/` (vault root via the `workspace_root` config key). Count item files with `status: pending` in frontmatter (the dashboard file self-excludes — it has no `status: pending`). Oldest age = max of (`today` − `created`) across pending items, in whole days.

2. **Inbox side.** Count `.md` files directly in `{workspace_root}/Inbox/` EXCLUDING the `Unprocessed Captures.md` dashboard. Oldest age = max days since file modification (Inbox items carry no `created` frontmatter; modification date is the proxy).

3. **Compose the line** — the shared format:

   ```
   Vault debt: Queue <N> pending (oldest <A>d) | Inbox <M> items (oldest <B>d)
   ```

   - A zero-count side drops its `(oldest …)` clause: `Queue 0 pending`.
   - **Escalation:** when Queue pending > 15 (the backpressure threshold), prefix and suffix:

   ```
   [QUEUE BACKPRESSURE] Queue <N> pending (oldest <A>d) | Inbox <M> items (oldest <B>d) — triage recommended
   ```

4. **Emit the line.** An explicit `/queue status` invocation always answers, even at zero debt (`Vault debt: Queue 0 pending | Inbox 0 items`). The HOOK differs deliberately: it emits nothing when both counts are zero — it is a passive signal and silence is its success state.

## Discipline

- **Signal, not triage.** Status never presents items or asks for adjudication — it counts. `/queue triage` pays the debt, only when invoked.
- **Pure counting.** No lint run, no body reads — frontmatter and file metadata only.

## What this playbook does NOT do

- Does NOT modify anything (read-only).
- Does NOT trigger anything — counts and ages are display only; triage runs solely on operator invocation (`playbooks/triage.md`).
