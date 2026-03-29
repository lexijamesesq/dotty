# dotty

Claude Code infrastructure, skills, and Mac setup. This is a public dotfiles repo — it contains the non-sensitive parts of my Mac development environment, focused on how I use Claude Code.

## What's here

### Claude Code dual-profile architecture

Two isolated Claude Code profiles (professional/personal) that share tools but have independent configs. `setup-claude-profiles.sh` symlinks skills, agents, and rules from this repo into both profile directories, while private config (CLAUDE.md, settings.json) comes from a separate private repo.

See `setup-claude-profiles.sh` and `.claude/rules/shared-infrastructure.md` for how it works.

### Skills

| Skill | Trigger | What it does |
|-------|---------|-------------|
| `session-start` | "I'm working on [project]" | Loads project state, recent progress, pending backlog |
| `session-closeout` | "Close out this session" | Updates project state, archives completed items, writes progress log |
| `github-prep` | "github prep [path]" | Scans artifacts for secrets, PII, hardcoded paths before publishing |
| `github-push` | "push to github" | Gated publish workflow with confirmation |
| `github-readme` | "generate readme" | Generates typed READMEs for skills, agents, rules, projects |
| `new-project` | "create a new project" | Interactive setup for new projects/hubs with intake routing and intent engineering |

The session skills reference `~/Vaults/Notes/Claude/System/` paths for project templates and protocols. If you use these, update the paths in your own CLAUDE.md to point to your workspace.

### Agents

- **github-prep** — Read-only evaluator that classifies content by sensitivity (BLOCK/REVIEW/FLAG) before publishing.

### Rules (auto-loaded every session)

- **execution-model** — Orchestrator/worker pattern for the main context window vs subagents, with model selection heuristics and evaluator/critic pattern for quality assurance.
- **search-modes** — Search mode detection (exploratory vs lookup) with behavioral directives for query construction.
- **sample-files** — Convention for `*.sample.md` files as tracked templates.
- **shared-infrastructure** — Documents the two-repo architecture and how shared resources are managed.

### Setup scripts

- `setup-terminal.sh` — Full terminal bootstrap: Oh My Zsh, stow, zsh plugins, iTerm, Claude profiles, SSH hardening
- `setup-apps.sh` — Rosetta, Brewfile, git remote switching
- `setup-ssh.sh` — Inter-machine SSH hardening with 1Password agent, IP-restricted authorized_keys
- `setup-claude-profiles.sh` — Creates `~/.claude-professional/` and `~/.claude-personal/`, symlinks shared resources
- `claude-statusline.sh` — Claude Code status bar showing account, model, and project
- `ssh-sshd-hardening.conf` — sshd template: key-only auth, no forwarding

### Other

- `.config/starship.toml` — Starship prompt theme
- `.claude/hooks/fix-obsidian-claude-sync.sh` — SessionStart hook that works around Obsidian Sync not syncing dot-prefixed directories

## Setup

### New machine

```bash
# Prerequisites: Homebrew, git, gh
gh repo clone lexijamesesq/dotty ~/bin/dotty
gh repo clone lexijamesesq/dotty-private ~/bin/dotty-private

# Bootstrap
chmod +x ~/bin/dotty/setup-*.sh ~/bin/dotty/claude-statusline.sh
~/bin/dotty/setup-apps.sh
~/bin/dotty/setup-terminal.sh
```

`setup-terminal.sh` handles stow, starship, Claude profiles, and SSH setup.

### Manual steps after setup

1. **1Password SSH agent** — Enable in 1Password > Settings > Developer
2. **SSH public key** — Export your inter-machine key to `~/.ssh/home-network.pub`
3. **sshd hardening** — `sudo cp ~/bin/dotty/ssh-sshd-hardening.conf /etc/ssh/sshd_config.d/000-local.conf`
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
3. Copy `settings.sample.json` to your private repo as `settings.json` and customize
4. Update paths in `setup-claude-profiles.sh` to point to your repos
5. Modify skills to reference your own workspace paths

## Paired with

[dotty-private](https://github.com/lexijamesesq/dotty-private) (private) — personal shell config, SSH network config, app preferences, Claude Code private config (CLAUDE.md, settings.json).

## License

MIT
