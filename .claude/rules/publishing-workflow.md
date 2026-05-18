# Publishing Workflow

How code gets from local repos to public GitHub. Applies to all repos under the operator's account.

## The workflow

1. **Work on a branch.** Create a branch (Linear-named if tied to a ticket: `lex-123-description`).
2. **Commit.** `git commit` fires pre-commit hooks automatically:
   - gitleaks scans the staged diff for secrets + operator-specific patterns (<100ms)
   - File-presence check verifies README.md + LICENSE exist
   - Any failure blocks the commit; fix or `SKIP=hook-id` to bypass selectively
3. **Push the branch.** `git push origin <branch>` — Claude Code's `permissions.ask` requires explicit approval.
4. **Create a PR.** `gh pr create` — Claude Code's `permissions.ask` requires explicit approval. Include `Closes <TEAM>-N` in the PR body for Linear auto-sync (ticket → Done on merge). Ticket IDs are allowed in PR bodies but NOT in commit messages.
5. **Merge.** `gh pr merge --merge --delete-branch` — Claude Code's `permissions.ask` requires explicit approval.

GitHub push protection (server-side, 39 detectors) fires at step 3. For advisory LLM review, run `/security-review` locally before pushing (uses Claude Pro/Max OAuth). CI-triggered review via `claude-code-action` is blocked on an upstream bug.

## HA Pi workflow (relay pattern)

The Pi's HA config repo (`/config`) publishes via the Mini as relay. Claude on Mini:

1. Read diff: `ssh <pi-ssh> 'cd /config && git diff'`
2. Scan: pipe diff through `gitleaks stdin` on the Mini
3. Branch + commit on Pi via SSH
4. Clone Pi repo to Mini temp dir: `git clone <pi-ssh>:/config <tmp-clone>`
5. Push branch from Mini: add GitHub remote, `git push github <branch>`
6. Create + merge PR from Mini: `gh pr create --repo <ha-repo>` + `gh pr merge`
7. Update Pi: `ssh <pi-ssh> 'cd /config && git checkout master && git merge <branch> && git branch -d <branch>'`
8. Clean temp: `rm -rf <tmp-clone>`

Safety checks run on the Mini. No tools needed on the Pi.

## Private repos (dotty-private)

Direct push (no PR workflow). gitleaks at commit time is the safety floor. No server-side push protection on free tier.

## What NOT to do

- Do NOT use `/github-prep` or `/github-push` — removed. The workflow above replaces them.
- Do NOT put Linear ticket IDs in commit messages — they go in PR bodies only.
- Do NOT use `git push` to main directly on public repos — use branch + PR.
- Do NOT use `git add -A` or `git add .` — stage specific files by path.

## Tools

- `gitleaks`: local secret scanner (Homebrew). Config per repo at `.gitleaks.toml`.
- `pre-commit`: hook orchestrator (Homebrew). Config per repo at `.pre-commit-config.yaml`.
- `gh`: GitHub CLI for PR operations.
- GitHub push protection: server-side, enabled on all public repos, unbypassable.
