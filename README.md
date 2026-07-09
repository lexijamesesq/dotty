# dotty

Claude Code infrastructure, skills, and Mac setup. This is a public dotfiles repo — it contains the non-sensitive parts of my Mac development environment, focused on how I use Claude Code.

## Requirements

Hard dependencies for the skills and rules in this repo:

- **Linear + linear-tactic MCP server** — Required for `/session-start`, `/session-closeout`, and `/new-project`. These skills call `mcp__linear-tactic__linear_*` tools to read project state and create/update issues. Without the MCP server configured, every Linear call fails silently and the skills won't complete. Set up: install [linear-tactic](https://github.com/tacticlaunch/mcp-linear) as an MCP server in your profile, scoped per your usage.
- **dotty-private companion repo** — Required for the `system-blueprint` skill and `blueprint-awareness` rule. These expect blueprint slice scripts at `~/bin/dotty-private/.claude/blueprint/`. Without a dotty-private checkout, the rule fires but finds no slices; the skill subcommands error out. Either clone a companion private repo at that path or fork this setup and adapt the paths.

Soft expectations (won't break things but inform behavior):

- **Obsidian-synced vault** — the `fix-obsidian-claude-sync.sh` hook and `vault-mcp-redirect.sh` hook assume a vault exists. Set `VAULT_ROOT` to override the default path, or skip these hooks if you don't use Obsidian.
- **1Password CLI (`op`) + SSH agent** — used by SSH setup (in dotty-private) and the MCP credential indirection pattern in blueprint slices.

## What's here

### Claude Code dual-profile architecture

Two isolated Claude Code profiles (professional/personal) that share tools but have independent configs. `setup-claude-profiles.sh` symlinks skills, agents, and rules from this repo into both profile directories, while private config (CLAUDE.md, settings.json) comes from a separate private repo.

See `setup-claude-profiles.sh` and `.claude/rules/shared-infrastructure.md` for how it works.

### Skills

Skills reference paths via config keys (e.g., `workspace_root`, `templates.project`) rather than hardcoding locations. Define these in the `Configuration` section of your CLAUDE.md — see `CLAUDE.sample.md` for the full key list.

**Session orchestrators**

| Skill | Trigger | What it does |
|-------|---------|--------------|
| `session-start` | "I'm working on [project]" | Loads project state, recent progress, pending backlog |
| `session-closeout` | "Close out this session" | Updates project state, archives completed items, writes progress log |

**Project management**

| Skill | Trigger | What it does |
|-------|---------|--------------|
| `new-project` | "create a new project" | Interactive setup for new projects/hubs with intake routing |
| `linear` | "/linear" | Linear domain expert — issues, project updates, queue analysis, archival |
| `project-state` | "/project-state read/write" | Reads and writes CLAUDE.md Project State sections |

**Knowledge layer**

| Skill | Trigger | What it does |
|-------|---------|--------------|
| `knowledge-layer` | "/knowledge-layer" | Freshness scan, hygiene checks, query-and-file, index sync |
| `lint-knowledge` | "/lint-knowledge" | Structural lint for tag taxonomy, orphans, stale frontmatter, contradictions |
| `gatekeeper` | "/gatekeeper" | Universal router for all knowledge-layer ingress; resolves file/queue/discard |
| `capture` | "/capture", "capture this" | Extracts knowledge candidates from conversation and routes to gatekeeper |
| `capture-meeting` | "/capture-meeting" | Captures meeting content with dual-write (rolling logs + typed candidates) |
| `wiki-intake` | "/wiki-intake" | Single entry point for Wiki-axis content; delegates or classifies and routes |
| `router` | "/router process" | Classifies Inbox/ captures and delivers to intake entry points |
| `queue` | "/queue triage" | Creates and triages operator-judgment queue items |

**Publishing and quality**

| Skill | Trigger | What it does |
|-------|---------|--------------|
| `publish` | "/publish" | Pre-publish gate: scaffold, sample-file, house-qa, gitleaks, security review |
| `house-qa` | "/house-qa check/review" | Corpus-conformance QA for authored artifacts |
| `github-readme` | "generate readme" | Generates typed READMEs for skills, agents, rules, projects |
| `sample-universe` | (loaded before authoring examples) | Canonical fictional universe for public-facing example content |

**Authoring and system management**

| Skill | Trigger | What it does |
|-------|---------|--------------|
| `lexi-persona` | "in Lexi's voice" | Produces and reviews content in the operator's authorial voice |
| `system-blueprint` | "/system-blueprint" | Captures or applies declared state for harness-managed config |
| `update-mbp` | "update mbp" | Audits a remote Mac over SSH and brings it into sync |

### Agents

| Agent | What it does |
|-------|--------------|
| `filing-validator` | Filing-time structural critic; validates new knowledge-layer files against the structural contract |

### Rules (auto-loaded every session)

| Rule | What it enforces |
|------|-----------------|
| `execution-model` | Orchestrator/worker delegation, model selection heuristics, evaluator pattern |
| `search-modes` | Search mode detection (exploratory vs lookup) with query construction directives |
| `shared-infrastructure` | Two-repo architecture and shared resource management |
| `publishing-workflow` | Local-to-GitHub workflow with gitleaks, push protection, and advisory review |
| `linear-discipline` | Linear state hygiene, waiting/blocked semantics, integrity on creation |
| `blueprint-awareness` | Consults the system blueprint before declaring a capability gap unrecoverable |
| `vault-as-data-source` | Search the vault before answering domain questions; tags before content search |

### Hooks

| Hook | Event | What it does |
|------|-------|--------------|
| `session-init.sh` | SessionStart | Runs session initialization tasks |
| `vault-mcp-redirect.sh` | PreToolUse | Redirects vault file operations to Obsidian MCP tools |
| `fix-obsidian-claude-sync.sh` | SessionStart | Works around Obsidian Sync not syncing dot-prefixed directories |
| `gh-pr-body-guard.sh` | PreToolUse | Fail-closed gitleaks scan of `gh pr create` titles and bodies |
| `git-hook-bypass-guard.sh` | PreToolUse | Blocks `--no-verify` and other hook-bypass attempts |
| `pr-cache.sh` | PreToolUse | Caches PR metadata to reduce redundant API calls |

### Git hooks

Portable git hooks for use with `pre-commit` (installed via `setup-claude-profiles.sh`):

- `gitleaks-commit-msg.sh` — Scans commit messages for secrets
- `gitleaks-pre-push.sh` — Full-range gitleaks scan of outgoing commits (authoritative choke point)
- `gitleaks-common.sh` — Shared utilities for the gitleaks hooks

### Statusline

- `statusline.sh` — Custom Claude Code statusline showing deliverable-repo git state and knowledge queue depth

### Setup scripts

- `setup-terminal.sh` — Full terminal bootstrap: Oh My Zsh, stow, zsh plugins, Ghostty, Claude profiles, SSH hardening
- `setup-claude-profiles.sh` — Creates `~/.claude-professional/` and `~/.claude-personal/`, symlinks shared resources and gitleaks operator rules
- `provision-public-repo.sh` — Converges a public GitHub repo onto estate baseline (hooks, rulesets, push protection, squash-only merges)

### Other

- `.config/starship.toml` — Starship prompt theme
- `tool-update-check` — Shell-startup notifier for manually-updated tools (reads blueprint `tools.json`)

## Setup

### New machine

```bash
# Prerequisites: Homebrew, git, gh
# Clone both repos (replace <user> with your GitHub username):
gh repo clone <user>/dotty ~/bin/dotty
gh repo clone <user>/dotty-private ~/bin/dotty-private

# Bootstrap
chmod +x ~/bin/dotty/setup-*.sh
~/bin/dotty/setup-terminal.sh
```

`setup-terminal.sh` handles stow, starship, Claude profiles, and SSH setup.

### Manual steps after setup

1. **1Password SSH agent** — Enable in 1Password > Settings > Developer
2. **SSH public key** — Export your inter-machine key to `~/.ssh/home-network.pub`
3. **sshd hardening** — Apply the config from dotty-private: `sudo cp ~/bin/dotty-private/ssh-sshd-hardening.conf /etc/ssh/sshd_config.d/000-local.conf`
4. **Remote Login** — Enable in System Settings > General > Sharing
5. **Claude Code auth** — Open each iTerm profile, run `claude`, then `/login`
6. **Plugins** — Gitignored; copy from another machine: `scp -r user@other:~/bin/dotty-private/.claude/plugins/ ~/bin/dotty-private/.claude/plugins/`

### Second machine

```bash
cd ~/bin/dotty && git pull
cd ~/bin/dotty-private && git pull
stow -D -d ~/bin -t ~ dotty-private   # remove old symlinks
stow -d ~/bin -t ~ dotty-private      # re-stow
bash ~/bin/dotty/setup-claude-profiles.sh
```

## Using with your own config

1. Fork this repo
2. Copy `CLAUDE.sample.md` to your private repo as `CLAUDE.md` and customize
3. Copy `.claude/settings.sample.json` to your private repo as `settings.json` and customize
4. Update paths in `setup-claude-profiles.sh` to point to your repos
5. Modify skills to reference your own workspace paths

## Paired with

A companion private repo holds personal shell config, SSH network config, app preferences, and Claude Code private config (CLAUDE.md, settings.json).

## License

MIT
