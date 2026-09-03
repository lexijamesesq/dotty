---
name: update-mbp
description: Audit the MacBook Pro from the Mac Mini and bring it back into sync — Homebrew (formulae + casks), Mac App Store, VS Code extensions, dotty/oh-my-zsh repos, and macOS minor security updates. Runs over SSH using the `mbp` alias. Triggers on "/update-mbp", "update mbp", "pre-travel update", "sync the laptop", or anything similar to "is the MBP up to date".
---

# update-mbp

Audit and update the MacBook Pro from the Mac Mini. The Mini is the source of truth for which apps and tools should be present; this skill measures the gap and closes it.

Designed for the pre-travel scenario: WFH happens on the Mini, the MBP drifts between trips, and before leaving you want a quick "is the laptop ready" pass.

## Configuration assumptions

- The skill runs on a "source" machine and updates a "target" machine reachable via SSH alias `mbp` in `~/.ssh/config`. Replace `mbp` with whatever alias matches your target; the name in this skill is illustrative.
- Credentials come from the 1Password SSH agent (`IdentityAgent Host *` in the same config). The user does not pass keys explicitly. Adapt if you use a different agent.
- macOS major versions are intentionally divergent across machines. **Never propose a major macOS upgrade.** Only minor (security) bumps inside the target's existing major track are surfaced.
- The Obsidian vault is synced by Obsidian Sync, not by this skill. If plugin counts diverge, flag it as an Obsidian Sync configuration issue — do not try to copy plugin folders.
- `~/bin/dotty` is public (skills, agents, rules); `~/bin/dotty-private` is private (CLAUDE.md, settings.json, plugins/, blueprint slices). This skill lives in dotty; its own script paths below reflect that. The blueprint apply lane references dotty-private because the blueprint slices live there.

## Workflow

### 1. Collect

```bash
~/bin/dotty/.claude/skills/update-mbp/scripts/collect-state.sh > /tmp/update-mbp-state/mini.txt
scp -q ~/bin/dotty/.claude/skills/update-mbp/scripts/collect-state.sh mbp:/tmp/collect-state.sh
ssh mbp '/tmp/collect-state.sh' > /tmp/update-mbp-state/mbp.txt
```

The collector is self-contained and re-deployable; it always overwrites the remote copy. It prepends `/opt/homebrew/bin` to PATH internally so non-interactive SSH sessions can find brew/mas/code/gh.

### 2. Diff

```bash
~/bin/dotty/.claude/skills/update-mbp/scripts/diff-state.sh \
  /tmp/update-mbp-state/mini.txt /tmp/update-mbp-state/mbp.txt \
  > /tmp/update-mbp-state/report.txt
```

Produces a sectioned report with `APPLY:` lines that the apply phase consumes. Read it and present the summary to the user. Always look for:

- **Dirty files in baseline (Mini) dotty repos.** If the Mini has uncommitted changes in dotty/dotty-private, those changes will NOT be on the MBP after a pull from origin. Flag and ask whether to commit + push first.
- **Obsidian plugin count = 0 on target while baseline > 0.** Indicates Obsidian Sync isn't syncing plugins to the MBP. Do not auto-fix; flag for the user to enable plugin sync in Obsidian settings.
- **Safari major-version updates** (e.g., Safari 26.x offered to a 15.x machine). Filtered out of auto-apply by both diff (it's reported as "Safari update") and apply (regex skip).
- **macOS minor update available** but `--macos` requires opt-in because it restarts the machine.

### 3. Apply

```bash
~/bin/dotty/.claude/skills/update-mbp/scripts/apply-updates.sh \
  /tmp/update-mbp-state/report.txt mbp [flags]
```

**Default lanes** (always applied, low risk — only touch things already installed):
- `brew upgrade --formula` for outdated formulae
- `brew upgrade --cask` for outdated casks
- `mas upgrade` per outdated MAS app id
- `code --install-extension --force` for VS Code extensions
- `git pull --ff-only` for dotty, dotty-private, oh-my-zsh — guarded: before any pull, the generated remote script refuses (exit 1, no pull) if a profile still symlinks a packaged skill into the dotty checkout without the `work-lifecycle` plugin enabled there, so an unattended run can never strand a profile mid-cutover
- `pre-commit install` in dotty + dotty-private (skipped if `pre-commit` isn't installed — arrives via the Homebrew lane above)
- symlink Capture One **Styles** (`~/Library/Application Support/Capture One/Styles` → `dotty-private/capture-one/Styles`) so `.costyle` masters travel with you — idempotent, guarded against clobbering a non-empty folder
- `bash ~/bin/dotty-private/.claude/blueprint/bootstrap.sh` (system-blueprint apply, additive — reproduces declared MCP/hook/plugin state on the target)

**Opt-in lanes** (require explicit flag — installs new things, human decides relevance):
- `--new-formulae` — install formulae present on Mini but missing on MBP
- `--new-casks` — install GUI apps present on Mini but missing on MBP
- `--new-mas` — install MAS apps present on Mini but missing on MBP
- `--macos` — apply macOS minor (security) update with `--restart`
- `--blueprint-prune` — run blueprint apply with `--prune` (removes undeclared items, full reconcile)
- `--no-vscode`, `--no-git`, `--no-blueprint` — disable specific default lanes
- `--dry-run` — print the generated remote script without executing

The apply script builds a single bash script and pipes it over one SSH connection (`ssh mbp 'bash -s' < script`) — efficient and lets the user watch progress stream back.

### 4. Re-verify

After apply, re-run collect+diff and report what's still outstanding (typically: items requiring a restart, App Store apps requiring sign-in, or items in the opt-in lanes that the user chose to skip).

## Decision rules when invoking the skill

When the user says `/update-mbp` (or equivalent) without flags:

1. Always run collect + diff first, present the categorized summary.
2. Apply the default lanes (upgrades + extensions + git pulls) without further confirmation.
3. For **opt-in lanes**, present each list and ask the user to pick which items to include — Claude must NOT decide what is "relevant" for the user:
   - **Missing formulae** — list each one and let the user select; never blanket-install them.
   - **Missing casks** — same. The diff already filters obvious machine-specific ones (logitech-, elgato-, displaylink, etc.); for the rest, ask.
   - **Missing MAS apps** — same. Some are large (GarageBand, iMovie); always ask.
   - **macOS minor (security) update** — confirm explicitly because it restarts the laptop.

Translate selections into the appropriate `--new-*` / `--macos` flag invocations, or run a second pass with a tailored APPLY: subset if the user wants only some items from a list.

When the user adds `--auto`, `--all`, or "go ahead with everything," do NOT take that as license to skip the per-item review for new installs — confirm at minimum a one-shot list-confirm before installing new software.

## Known failure modes

- **MBP unreachable.** The skill cannot operate from a stale snapshot. Tell the user to bring the MBP online or run the collector on the MBP directly and bring back the output.
- **Anything that calls `sudo` fails over non-interactive SSH.** Confirmed offenders observed in practice:
  - `mas 7.x upgrade` and `mas install` shell out to `sudo` for some operations and fail with `sudo: a terminal is required` when run from `ssh mbp 'bash …'`.
  - Some casks (e.g. `adobe-dng-converter`) run `sudo` during their uninstall/cleanup phase and break with `Error: <cask>: Broken pipe`.
  - `softwareupdate --install --restart` always needs `sudo` + interactive session.
  After apply, surface these as "run on the MBP directly" with the exact commands. Do not try to bypass sudo with `-S` and a piped password.
- **GitHub SSH-key auth fails from SSH-into-MBP.** OpenSSH 10's `ssh-agent-bind-hostkey` requirement vs 1Password's agent (which doesn't yet implement that extension) silently disables agent forwarding. So `git pull git@github.com:…` over a forwarded session can't reach a signer. The skill works around this only for the pull lane and only for itself: when the repo's origin is `git@github.com:*`, the apply script fetches via the HTTPS form of the same URL (`https://github.com/owner/repo.git`) using a **scoped** `git -c credential.helper='!gh auth git-credential'` override that lasts only for that one invocation. Nothing is written to the MBP's `~/.gitconfig`; the repo's stored origin remote stays SSH; the user's interactive workflow on the MBP (push/pull while 1P is alive) is unaffected and continues to use SSH + 1P. **Prerequisite:** `gh auth login --insecure-storage` has been run once on the MBP so a token exists in `~/.config/gh/hosts.yml` as plain text. The `--insecure-storage` flag is required because without it, gh stores the token in macOS Keychain, which (like 1Password's agent) is not accessible from a non-interactive SSH session. The skill does *not* run `gh auth setup-git` (that would register gh globally for all github.com git ops on the MBP, which is out of scope) and does not perform first-run setup.
- **mas not signed in on MBP.** `mas install` for new apps additionally requires a signed-in App Store session — failure mode is silent on top of the sudo issue above.
- **Local commits on Mini not yet pushed.** A `git pull` on the MBP only fetches what's on origin. If the Mini has unpushed work, surface it before applying so the user can `git push` from the Mini first.
- **SSH session drops mid-apply.** Long brew operations on a flaky link can sever the pipe. The apply script mitigates this with `ServerAliveInterval=30` and by uploading the script as a file (so the remote bash process isn't reading from a stdin pipe). If a drop still occurs, just re-run `apply-updates.sh` — every lane is idempotent.

## Self-updating apps

Many casks (Chrome, Slack, Arc, 1Password, Discord, Signal, Raycast, Obsidian, etc.) update themselves outside Homebrew. The collector calls `brew outdated --cask` **without** `--greedy-auto-updates`, so the cask-upgrade lane only acts on casks brew is confident need help. A second informational section (`brew_outdated_cask_auto_update_informational`) lists self-updating casks brew sees as drifted — these are reported but never auto-upgraded; let the apps update themselves.

If you ever need to force-upgrade a self-updating cask via brew, do it manually with `brew upgrade --cask --greedy-auto-updates <name>` rather than changing the skill's defaults.

## Skip vs exclude

Two distinct intents the user expresses during the picker:

- **Skip X** — don't install in *this run*, but keep asking next time. Transient. Nothing is written to disk; the item simply isn't passed to apply. Use when the answer is "not tonight" / "maybe later" / "I'm not on the right network for that download."
- **Exclude X** — stop asking entirely; this item isn't relevant for the MBP. Durable. Append to `exclusions.txt` with a comment so it never reappears in the picker. Use when the answer is "never" / "not on the laptop" / "Mini-only tool."

If the user is ambiguous ("don't bother with X"), default to **skip** and confirm before excluding. Excluding is the stronger commitment.

## Exclusions

`exclusions.txt` next to the scripts records the durable "exclude" decisions. Format:

```
formula=<formula-name>   # YYYY-MM-DD: short reason
cask=<cask-name>         # YYYY-MM-DD: short reason
mas=<numeric-app-id>     # YYYY-MM-DD: short reason
repo=<path-under-home>   # YYYY-MM-DD: exact-match example
repo=<dir>/*             # YYYY-MM-DD: glob example — covers all entries under <dir>/
```

Values are matched as shell globs, so `repo=.gemini/*` excludes every repo path under `.gemini/`, while plain values like `gitstatus` are exact matches. Always include the date and a short reason in the trailing comment so future you can decide whether the exclusion still applies. To un-exclude, delete or comment out the line.

When the user says "exclude X" mid-run, append the entry immediately so the next collect+diff cycle reflects it. Skipped items get no record — they simply don't go into the apply flags this round.

`exclusions.txt` is gitignored — same treatment as the repo's other private-config files (see `.gitignore` + `rules/shared-infrastructure.md`), since it reflects one person's real machine and stays local-only. `exclusions.sample.txt` ships as the format template; copy it to `exclusions.txt` on first use (or just let entries accumulate — the file is created empty and grown by the "exclude" flow above).

## Files

- `scripts/collect-state.sh` — sectioned state dump, runs on either machine
- `scripts/diff-state.sh` — produces report.txt with APPLY: hint lines, honors exclusions.txt
- `scripts/apply-updates.sh` — generates and runs remote apply script over SSH
- `exclusions.txt` — items the user has marked irrelevant for the MBP (gitignored, personal)
- `exclusions.sample.txt` — template showing the exclusions.txt format
