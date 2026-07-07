# Playbook: status

Report queue + Inbox debt as one line. This playbook is the CANONICAL definition of the debt-line format; the SessionStart hook (`hooks/vault-debt-line.sh`) emits the same format from pure file counting. Change the format here first, then mirror it in the hook.

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
   [QUEUE BACKPRESSURE] Vault debt: Queue <N> pending (oldest <A>d) | Inbox <M> items (oldest <B>d) — drain overdue
   ```

4. **Emit the line.** An explicit `/queue status` invocation always answers, even at zero debt (`Vault debt: Queue 0 pending | Inbox 0 items`). The HOOK differs deliberately: it emits nothing when both counts are zero — it is a passive signal and silence is its success state.

## Discipline

- **Signal, not drain.** Status never presents items or asks for adjudication — it counts. The drain pays the debt.
- **Pure counting.** No lint run, no body reads — frontmatter and file metadata only.

## What this playbook does NOT do

- Does NOT modify anything (read-only).
- Does NOT evaluate drain fire-conditions — count and age thresholds shown here are display escalation, not drain triggers (the drain evaluates its own conditions in `drain.md`).
