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

GitHub push protection (server-side, 39 detectors) fires at step 3.

## Advisory security review

The third safety layer — after gitleaks (commit) and push protection (push) — is an LLM review of the branch diff before push, catching logic/design vulnerabilities the pattern scanners miss. CI-triggered review via `claude-code-action` is blocked on an upstream bug, so it runs locally. Skipping it silently drops the workflow to two layers.

**`/security-review` is cwd-scoped.** The built-in skill diffs `git diff origin/HEAD...` in the **session's own repo** (the cwd Claude Code launched in) and takes no repo argument. Two consequences:

- It reviews whatever repo the session is rooted in. Editing a dotty skill/rule/agent from a vault-rooted session is the normal workflow — there, `/security-review` reviews the vault repo, not `~/bin/dotty`.
- Its base ref is `origin/HEAD`. That symbolic ref must exist in the target repo, or every `origin/HEAD...` command fails with `fatal: ambiguous argument 'origin/HEAD...'`. Set it once per repo: `git remote set-head origin --auto`. Fresh `git clone`s have it; repos created via `git init` + remote-add do not.

**Two paths — pick by where the session is rooted:**

- **Session rooted in the target repo:** run `/security-review` directly. Preferred — it is the tuned built-in skill.
- **Publishing from another session** (the common case — e.g. editing dotty from a vault session): do *not* call `/security-review`, it would review the wrong repo. Claude reviews the diff inline instead — take `git -C <target-repo> diff origin/HEAD...` and assess it for high-confidence exploitable vulnerabilities: injection, auth/authz bypass, path traversal, unsafe deserialization, hardcoded secrets, data exposure. Same bar as the skill — only >80%-confidence exploitable findings; skip style, DoS, and theoretical issues.

## HA Pi workflow

The Pi's HA config repo pushes directly to GitHub `origin`. SSH into the Pi
lands in an ephemeral add-on container that's rebuilt on every update, so
durable dev tooling (`gh`, full `gitleaks`, the `pre-commit` framework) lives
on the workstation, not the Pi. The Pi carries one self-contained safety tool:
a dependency-free `pre-commit` shell hook that greps staged diffs for
credential patterns.

1. Read the diff from the Pi over SSH.
2. Scan on the workstation: pipe the diff through `gitleaks stdin`.
3. On the Pi via SSH: branch, commit (the Pi's `pre-commit` hook fires),
   push to `origin`.
4. Create the PR from the workstation using `gh pr create` (the Pi has no `gh`).
5. Advisory security review runs in CI on the PR (pending upstream fix).
6. Merge from the workstation, then pull on the Pi.

Operational details (SSH host, repo slug, exact commands) are in the HA
project's CLAUDE.md and Configuration and Current State Git.

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
