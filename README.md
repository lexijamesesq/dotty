Claude Code infrastructure, skills, and Mac setup. This is a public dotfiles repo — it contains the non-sensitive parts of my Mac development environment, focused on how I use Claude Code.

## Installation

Clone both repos, then bootstrap:

```
gh repo clone <user>/dotty ~/bin/dotty
gh repo clone <user>/dotty-private ~/bin/dotty-private
```

```
chmod +x ~/bin/dotty/setup-*.sh
~/bin/dotty/setup-terminal.sh
```

Prerequisites: Homebrew, git, gh.

### Manual steps

1. **1Password SSH agent** — Enable in 1Password > Settings > Developer
2. **SSH public key** — Export your inter-machine key to `~/.ssh/home-network.pub`
3. **sshd hardening** — `sudo cp ~/bin/dotty-private/ssh-sshd-hardening.conf /etc/ssh/sshd_config.d/000-local.conf`
4. **Remote Login** — Enable in System Settings > General > Sharing
5. **Claude Code auth** — Open each iTerm profile, run `claude`, then `/login`
6. **Plugins** — Gitignored; copy them from another machine

### Second machine

```
cd ~/bin/dotty && git pull
cd ~/bin/dotty-private && git pull
stow -D -d ~/bin -t ~ dotty-private
stow -d ~/bin -t ~ dotty-private
bash ~/bin/dotty/setup-claude-profiles.sh
```

### Dependencies

- **Linear + the [linear-tactic](https://github.com/tacticlaunch/mcp-linear) MCP server** — required by `/session-start`, `/session-closeout`, and `/new-project`. Without it every Linear call fails silently and the skill never completes.
- **A dotty-private companion repo** — required by `/system-blueprint` and the `blueprint-awareness` rule, which expect blueprint slices at `~/bin/dotty-private/.claude/blueprint/`. It also holds the private `CLAUDE.md` and `settings.json`.
- **An Obsidian vault** *(optional)* — `fix-obsidian-claude-sync.sh` and `vault-mcp-redirect.sh` assume one exists. Set `VAULT_ROOT`, or drop both hooks.
- **1Password CLI** *(optional)* — used by SSH setup and the credential indirection in the blueprint slices.

## What's Included

### Session orchestration

Bracket a working session — load state at the start, write it back at the end.

| Artifact | Type | What it does |
|----------|------|--------------|
| `/session-start` | Skill | Loads project state, recent progress, and the pending backlog |
| `/session-closeout` | Skill | Writes state back, archives finished items, records what changed |
| `/project-state` | Skill | Reads and writes the Project State section of a project's CLAUDE.md |

### Projects and backlog

| Artifact | Type | What it does |
|----------|------|--------------|
| `/new-project` | Skill | Walks you through creating a project or hub, and wires up where its notes land |
| `/linear` | Skill | Reads and writes Linear issues, posts project updates, archives closed work |

### Knowledge layer

Everything that files, sorts, or maintains what a session learns. One gatekeeper owns every write into the knowledge base; the rest either feed it or maintain what it filed.

| Artifact | Type | What it does |
|----------|------|--------------|
| `/gatekeeper` | Skill | Decides where each new piece of knowledge goes: file it, queue it, or drop it |
| `/capture` | Skill | Pulls the durable facts out of a conversation and sends them to the gatekeeper |
| `/capture-meeting` | Skill | Captures a recurring meeting into a rolling log, and files what it learned |
| `/wiki-intake` | Skill | Single front door for notes headed to the wiki; sorts them and routes them on |
| `/router` | Skill | Sorts an inbox of raw captures and delivers each to the right destination |
| `/queue` | Skill | Holds decisions that need a human, and walks you through them one at a time |
| `/knowledge-layer` | Skill | Finds stale notes, checks their structure, and keeps the index current |
| `/lint-knowledge` | Skill + Script | Reports broken tags, orphaned notes, stale dates, and contradictions |
| `filing-validator` | Agent | Checks a newly filed note against the structural contract, in a fresh context |

### Publishing and quality

Checks that run before anything leaves the machine.

| Artifact | Type | What it does |
|----------|------|--------------|
| `/publish` | Skill | Runs every check a repo must pass before it ships — scans, conformance, review |
| `/house-qa` | Skill + Script | Judges whether a new file reads like it belongs beside the ones already there |
| `/github-readme` | Skill | Writes or refreshes a README for a skill, agent, rule, or project |
| `/sample-universe` | Skill | Supplies the fictional company that public examples borrow their names from |

### Authoring and machine state

| Artifact | Type | What it does |
|----------|------|--------------|
| `/lexi-persona` | Skill | Drafts and reviews writing in my voice |
| `/system-blueprint` | Skill | Records the machine config that lives outside git, and reapplies it elsewhere |
| `/update-mbp` | Skill | Audits my laptop over SSH and brings it back in sync with this machine |

### Rules

Loaded into every session, so each line costs context on every turn.

| Rule | What it enforces |
|------|------------------|
| `execution-model` | Delegate deliverables to subagents; pick the model to match the task |
| `search-modes` | Tell an exploratory search from a lookup, and query accordingly |
| `shared-infrastructure` | Which of the two repos a file belongs in, and why |
| `publishing-workflow` | How code reaches public GitHub, and which gate catches what |
| `linear-discipline` | Ticket state must match reality; blocked and waiting mean different things |
| `blueprint-awareness` | Check the blueprint before calling a missing capability unrecoverable |
| `vault-as-data-source` | Search the vault before answering; tags before content |

### Hooks

| Hook | Event | What it does |
|------|-------|--------------|
| `session-init.sh` | SessionStart | Runs session initialization tasks |
| `fix-obsidian-claude-sync.sh` | SessionStart | Works around Obsidian Sync skipping dot-prefixed directories |
| `vault-mcp-redirect.sh` | PreToolUse | Sends vault file edits through the Obsidian MCP tools |
| `gh-pr-body-guard.sh` | PreToolUse | Scans a PR title and body for secrets, and fails closed |
| `git-hook-bypass-guard.sh` | PreToolUse | Blocks `--no-verify` and other attempts to skip the git hooks |
| `pr-cache.sh` | SessionStart, PostToolUse | Caches PR metadata to cut redundant API calls |

### Scripts

| Script | What it does |
|--------|--------------|
| `setup-terminal.sh` | Stows the private dotfiles, links Starship and Ghostty, sets up the Claude profiles, applies SSH hardening |
| `setup-claude-profiles.sh` | Creates the two profile directories and symlinks the shared resources into them |
| `provision-public-repo.sh` | Brings a public repo up to baseline — hooks, branch rules, push protection |
| `git-hooks/gitleaks-*.sh` | Portable secret-scanning hooks, consumed through `pre-commit` |

## Configuration

The system separates what you configure from what skills handle.

**You configure:**
- `CLAUDE.md` in your private repo — the keys skills resolve at runtime: `workspace_root`, `projects_root`, `user_timezone`, Linear team UUIDs, and template and reference paths
- `settings.json` in your private repo — hook registrations, permissions, environment
- Repo paths in `setup-claude-profiles.sh`, if your checkouts live somewhere else

**Skills handle:**
- Turning those keys into real paths at invocation, so nothing is hardcoded
- Reading and writing project state, and filing Linear issues
- Sorting, filing, and linting everything that enters the knowledge base
- Gating a publish and generating READMEs

See `CLAUDE.sample.md` and `.claude/settings.sample.json` for every field.

## Usage

### Session orchestration

Bracket the work. Everything else is invoked as needed inside those bounds.

```
/session-start <project>
```
Loads project state, recent progress, and the pending Linear queue.

```
/session-closeout
```
Writes state back, archives finished items, files what the session learned.

### Knowledge capture

```
/capture
```
Pulls durable facts out of the live conversation and hands each to the gatekeeper.

```
/queue triage
```
Walks you through the decisions the gatekeeper would not make alone.

### Publishing

```
/publish
```
Runs the pre-publish gate: scaffold check, sample-file audit, house-qa conformance, a full gitleaks scan, and an advisory security review.

## How It Works

Two Claude Code profiles — professional and personal — share one public toolchain and keep separate private config. `setup-claude-profiles.sh` symlinks `skills/`, `agents/`, and `rules/` from this repo into `~/.claude-professional/` and `~/.claude-personal/`, then symlinks `CLAUDE.md` and `settings.json` in from the private companion repo. Hooks are the exception: they are not symlinked, and `settings.json` names each one by path.

Skills never hardcode locations. They reference paths through keys like `workspace_root` that resolve against your `CLAUDE.md` when the skill runs. That is what lets the same skill serve two profiles pointing at different workspaces.

Secret scanning is a line, not a single gate. `pre-commit` scans the staged diff at commit time and the message at `commit-msg`. `pre-push` scans the full outgoing commit range — the last place the complete ruleset meets the complete data before anything leaves the machine. Two `PreToolUse` hooks add another layer inside Claude Code itself.

## Customization

The skills assume my setup: a Linear backlog, an Obsidian vault, and a private companion repo. To adapt them:

- **Different repo paths:** update the paths in `setup-claude-profiles.sh`.
- **Your own private repo:** fork this, then copy `CLAUDE.sample.md` and `.claude/settings.sample.json` into it as `CLAUDE.md` and `settings.json`.
- **Without Obsidian:** set `VAULT_ROOT`, or drop the two vault hooks from `settings.json`.
- **Without Linear:** `/session-start`, `/session-closeout`, and `/new-project` will not complete. Everything else is unaffected.

## Security

Review skills before installing. They load into Claude's context and execute with your permissions. Audit the contents of `.claude/skills/`, `.claude/agents/`, and `.claude/hooks/` before use.

This repo carries more executable surface than a typical skills project. `setup-terminal.sh` rewrites your shell configuration and applies SSH hardening. The two guard hooks block unsafe operations inside Claude Code sessions, but both are tool-scoped and porous to a plain shell — defense-in-depth, not a boundary.

## License

MIT. See [LICENSE](LICENSE).
