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

| Skill | Trigger | What it does |
|-------|---------|-------------|
| `session-start` | "I'm working on [project]" | Loads project state, recent progress, pending backlog |
| `session-closeout` | "Close out this session" | Updates project state, archives completed items, writes progress log |
| `github-readme` | "generate readme" | Generates typed READMEs for skills, agents, rules, projects |
| `new-project` | "create a new project" | Interactive setup for new projects/hubs with intake routing and intent engineering |
| `update-mbp` | "update mbp", "pre-travel update" | Audits a target machine via SSH and brings it back into sync with the source (brew/MAS/VS Code/git/dotty/dotty-private/blueprint). Replace the `mbp` alias with your own target. |

Skills reference paths via config keys (e.g., `workspace_root`, `templates.project`) rather than hardcoding locations. Define these in the `Configuration` section of your CLAUDE.md — see `CLAUDE.sample.md` for the full key list.

### Agents

- **github-prep** — Read-only evaluator that judges content for sharing readiness (Allow / Block / Revise / Escalate) before publishing.

### Rules (auto-loaded every session)

- **execution-model** — Orchestrator/worker pattern for the main context window vs subagents, with model selection heuristics and evaluator/critic pattern for quality assurance.
- **search-modes** — Search mode detection (exploratory vs lookup) with behavioral directives for query construction.
- **shared-infrastructure** — Documents the two-repo architecture and how shared resources are managed.
- **publishing-workflow** — How code gets from local repos to public GitHub, with safety layers.

### Setup scripts

- `setup-terminal.sh` — Full terminal bootstrap: Oh My Zsh, stow, zsh plugins, Ghostty, Claude profiles, SSH hardening
- `setup-claude-profiles.sh` — Creates `~/.claude-professional/` and `~/.claude-personal/`, symlinks shared resources and gitleaks operator rules

Machine-specific setup scripts (SSH hardening, app installation, sshd config) live in the companion private repo.

### Other

- `.config/starship.toml` — Starship prompt theme
- `.claude/hooks/fix-obsidian-claude-sync.sh` — SessionStart hook that works around Obsidian Sync not syncing dot-prefixed directories

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
