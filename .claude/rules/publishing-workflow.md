# Publishing Workflow

How code gets from local repos to public GitHub. Applies to all repos under the operator's account.

## The workflow

1. **Work on a branch.** Create a branch (Linear-named if tied to a ticket: `lex-123-description`).
2. **Commit.** `git commit` fires pre-commit hooks automatically:
   - gitleaks scans the staged diff for secrets + operator-specific patterns (<100ms)
   - a `commit-msg` hook scans the commit message text — gitleaks never reads commit messages in git mode, so this is the only thing that does
   - File-presence check verifies README.md + LICENSE exist
   - Any failure blocks the commit. **Fix the finding; do not bypass.** `--no-verify`, `-n` (including bundled forms like `-an`), `SKIP=<hook-id>`, and `core.hooksPath` overrides are denied in Claude Code sessions by `permissions.deny` plus the `git-hook-bypass-guard.sh` PreToolUse hook — verified to bind subagents too. Both layers are tool-scoped and Bash-porous: defense-in-depth, not a boundary. The operator can still bypass from a plain shell.
3. **Push the branch.** `git push origin <branch>` — Claude Code's `permissions.ask` requires explicit approval. A `pre-push` hook scans the **full outgoing commit range** with the operator ruleset first. This is the authoritative choke point — the last place the complete config runs against the complete data before anything leaves the machine. It fails closed: a missing gitleaks binary, an unresolvable `[extend]` target, or a commit range that does not resolve all block the push.
4. **Create a PR.** `gh pr create` — Claude Code's `permissions.ask` requires explicit approval. Include `Closes <TEAM>-N` in the PR body for Linear auto-sync (ticket → Done on merge).
5. **Merge.** `gh pr merge --merge --delete-branch` — Claude Code's `permissions.ask` requires explicit approval.

GitHub push protection (server-side, 39 detectors) fires at step 3.

**Hooks do not clone.** `git clone` installs no hooks — a fresh clone or a fresh machine has zero local scanning until someone runs `pre-commit install`. The tracked `.pre-commit-config.yaml` declares `default_install_hook_types: [pre-commit, pre-push, commit-msg]`, so a bare `pre-commit install` wires all three. The gitleaks operator ruleset is a **gitignored symlink** (`.gitleaks-operator-rules.toml`) that also does not clone; `setup-claude-profiles.sh` creates it. Until it exists, gitleaks hard-fails with `FTL Failed to load config` and blocks every commit — fail-closed, but bewildering if you don't know why. A skipped provisioning step is a silent tier downgrade; that is what the repo-provisioning script exists to prevent.

## Advisory security review

The third safety layer — after gitleaks (commit) and push protection (push) — is an LLM review of the branch diff before push, catching logic/design vulnerabilities the pattern scanners miss. CI-triggered review via `claude-code-action` is blocked on an upstream bug, so it runs locally. Skipping it silently drops the workflow to two layers.

**`/security-review` is cwd-scoped.** The built-in skill diffs `git diff origin/HEAD...` in the **session's own repo** (the cwd Claude Code launched in) and takes no repo argument. Two consequences:

- It reviews whatever repo the session is rooted in. Editing a dotty skill/rule/agent from a vault-rooted session is the normal workflow — there, `/security-review` reviews the vault repo, not `~/bin/dotty`.
- Its base ref is `origin/HEAD`. That symbolic ref must exist in the target repo, or every `origin/HEAD...` command fails with `fatal: ambiguous argument 'origin/HEAD...'`. Set it once per repo: `git remote set-head origin --auto`. Fresh `git clone`s have it; repos created via `git init` + remote-add do not.

**Two paths — pick by where the session is rooted:**

- **Session rooted in the target repo:** run `/security-review` directly. Preferred — it is the tuned built-in skill.
- **Publishing from another session** (the common case — e.g. editing dotty from a vault session): do *not* call `/security-review`, it would review the wrong repo. Claude reviews the diff inline instead — take `git -C <target-repo> diff origin/HEAD...` and assess it for high-confidence exploitable vulnerabilities: injection, auth/authz bypass, path traversal, unsafe deserialization, hardcoded secrets, data exposure. Same bar as the skill — only >80%-confidence exploitable findings; skip style, DoS, and theoretical issues.

## PR title and body scanning

gitleaks scans file diffs, not `gh` arguments — so a PR title or body is a public
surface that the commit/push scanners never see. A fourth layer closes that gap: a
fail-closed `PreToolUse` guard (`.claude/hooks/gh-pr-body-guard.sh`) that scans the
`gh pr create` invocation before it runs.

- **Titles are in scope.** PR titles are frequently synced from Linear issue titles,
  which routinely carry employer + internal product names — a guarded class. The
  guard scans the title as well as the body.
- **How it scans.** Rather than parse gh's flags (fragile), it writes the ENTIRE
  command string to a temp file and runs `gitleaks dir` with the target repo's
  `.gitleaks.toml` (operator ruleset). `--body-file`/`-F` contents are read and
  scanned too. This *over-blocks on purpose*: a guarded literal ANYWHERE in the
  command blocks the create, not only one in the body. That is the safe direction.
- **Ticket refs are allowed.** `Closes <TEAM>-N` in a PR body is not a guarded class
  and does not match — the operator ruleset carries no ticket-id rule.
- **Fail-closed, so run it from the repo.** The guard must run from inside the target
  repo (gitleaks resolves the config's `[extend]` path relative to the process cwd).
  If cwd is not a git repo carrying `.gitleaks.toml`, it BLOCKS and tells you to
  `cd` into the checkout. A `gh pr create -R owner/repo` from an unrelated directory
  is not covered — cd into that repo's local checkout to publish. This is a
  deliberate trade: blocking the occasional cross-repo `gh pr create` beats fail-open
  on the most leak-prone surface.

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

## Sample files

Files matching `*.sample.md` ship with public repos as templates for GitHub consumers — they show what config to create, with placeholders (`TODO:`, `path/to/your/...`, `YOUR_VALUE_HERE`) where personal or org-specific values belong.

- **Never read `*.sample.md` for project context.** The real file (e.g., `CLAUDE.md`) is the authoritative source.
- **Never edit `*.sample.md` in place of the real config.** Edit the real file.
- **When editing the real file, flag whether the sample needs updating.** New fields, renamed sections, or removed fields may need to be reflected for consumers. Surface, don't silently update.
- **Placeholders stay placeholders.** They're never filled in — that's the real file's job.

## What NOT to do

- Do NOT use `/github-prep` or `/github-push` — removed. The workflow above replaces them.
- Do NOT put ticket IDs in codebase content — source, config, YAML comments, automation descriptions, fixtures. They belong in commit messages, PR bodies, and context docs. In artifact content they rot when the ticket closes and mean nothing to a reader who can't see the tracker.
- Do NOT use `git push` to main directly on public repos — use branch + PR.
- Do NOT use `git add -A` or `git add .` — stage specific files by path.

## Tools

- `gitleaks`: local secret scanner (Homebrew). Config per repo at `.gitleaks.toml`.
- `pre-commit`: hook orchestrator (Homebrew). Config per repo at `.pre-commit-config.yaml`.
- `gh`: GitHub CLI for PR operations.
- GitHub push protection: server-side, enabled on all public repos, unbypassable.
