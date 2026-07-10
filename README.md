Claude Code infrastructure and macOS setup — the skills, agents, rules, and hooks that load into every session, the gitleaks hooks that gate every commit and push, and the scripts that provision a machine from scratch. Two isolated Claude Code profiles share this public layer; their private config lives in a companion repo. This is the half that ships publicly.

## What's Included

### Claude Code dual-profile architecture

Two isolated Claude Code profiles (professional/personal) that share tools but have independent configs. `setup-claude-profiles.sh` symlinks skills, agents, and rules from this repo into both profile directories, while private config (CLAUDE.md, settings.json) comes from a separate private repo.

See `setup-claude-profiles.sh` and `.claude/rules/shared-infrastructure.md` for how it works.

### Skills

Skills reference paths via config keys (e.g., `workspace_root`, `templates.project`) rather than hardcoding locations. Define these in the `Configuration` section of your CLAUDE.md — see `CLAUDE.sample.md` for the full key list.

#### Session orchestrators

These bracket a working session, reading project state at the start and writing it back at the end.

| Skill | Trigger | What it does |
|-------|---------|--------------|
| `session-start` | "I'm working on [project]" | Loads project state, recent progress, pending backlog |
| `session-closeout` | "Close out this session" | Updates project state, archives completed items, writes progress log |

#### Project management

Linear holds the backlog and the project narrative; these read and write it.

| Skill | Trigger | What it does |
|-------|---------|--------------|
| `new-project` | "create a new project" | Sets up a project or hub interactively, wiring its intake routing |
| `linear` | "/linear" | Reads and writes Linear issues, posts project updates, analyzes the queue, archives closed work |
| `project-state` | "/project-state read/write" | Reads and writes CLAUDE.md Project State sections |

#### Knowledge layer

One gatekeeper resolves every candidate entering the knowledge layer. The rest either feed it or maintain what it filed.

| Skill | Trigger | What it does |
|-------|---------|--------------|
| `gatekeeper` | "/gatekeeper" | Routes every knowledge-layer candidate to a terminal disposition — file, queue, or discard |
| `capture` | "/capture", "capture this" | Extracts knowledge candidates from conversation and routes to gatekeeper |
| `capture-meeting` | "/capture-meeting" | Captures meeting content with dual-write (rolling logs + typed candidates) |
| `wiki-intake` | "/wiki-intake" | Takes in Wiki-axis content at one entry point, then delegates, or classifies and routes it |
| `router` | "/router process" | Classifies Inbox/ captures and delivers to intake entry points |
| `queue` | "/queue triage" | Creates and triages operator-judgment queue items |
| `knowledge-layer` | "/knowledge-layer" | Scans freshness, checks hygiene, files queried content, and syncs the index |
| `lint-knowledge` | "/lint-knowledge" | Lints structure — tag taxonomy, orphans, stale frontmatter, contradictions |

#### Publishing and quality

Gates and generators that run before anything leaves the machine.

| Skill | Trigger | What it does |
|-------|---------|--------------|
| `publish` | "/publish" | Gates a publish behind scaffold, sample-file, house-qa, gitleaks, and security-review checks |
| `house-qa` | "/house-qa check/review" | Checks whether an authored artifact conforms to the corpus it is joining |
| `github-readme` | "generate readme" | Generates typed READMEs for skills, agents, rules, projects |
| `sample-universe` | (loaded before authoring examples) | Supplies the canonical fictional universe that public-facing examples draw from |

#### Authoring and system management

These cover authorial voice, declared machine state, and remote-machine upkeep.

| Skill | Trigger | What it does |
|-------|---------|--------------|
| `lexi-persona` | "in Lexi's voice" | Produces and reviews content in the operator's authorial voice |
| `system-blueprint` | "/system-blueprint" | Captures or applies declared state for harness-managed config |
| `update-mbp` | "update mbp" | Audits a remote Mac over SSH and brings it into sync |

### Agents

One agent runs today, invoked by the filing skills rather than directly.

| Agent | What it does |
|-------|--------------|
| `filing-validator` | Validates a newly filed knowledge-layer file against the structural contract, in a clean context |

### Rules

Rules load into every session's context, so each line costs attention on every turn.

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

Registered in `settings.json`, these fire on Claude Code lifecycle events.

| Hook | Event | What it does |
|------|-------|--------------|
| `session-init.sh` | SessionStart | Runs session initialization tasks |
| `fix-obsidian-claude-sync.sh` | SessionStart | Works around Obsidian Sync not syncing dot-prefixed directories |
| `vault-mcp-redirect.sh` | PreToolUse | Redirects vault file operations to Obsidian MCP tools |
| `gh-pr-body-guard.sh` | PreToolUse | Scans `gh pr create` titles and bodies for secrets, and fails closed |
| `git-hook-bypass-guard.sh` | PreToolUse | Blocks `--no-verify` and other hook-bypass attempts |
| `pr-cache.sh` | SessionStart, PostToolUse | Caches PR metadata to reduce redundant API calls |

### Git hooks

Portable git hooks, consumed through `pre-commit`. Run `pre-commit install` in a fresh clone — `default_install_hook_types` wires all three types at once. `setup-claude-profiles.sh` separately creates the gitleaks operator-rules symlink these depend on.

- `gitleaks-commit-msg.sh` — Scans commit messages for secrets
- `gitleaks-pre-push.sh` — Full-range gitleaks scan of outgoing commits (authoritative choke point)
- `gitleaks-common.sh` — Shared utilities for the gitleaks hooks

### Setup scripts

- `setup-terminal.sh` — Bootstraps the terminal: stows private dotfiles, links the Starship and Ghostty configs, sets up the Claude profiles, applies SSH hardening
- `setup-claude-profiles.sh` — Creates `~/.claude-professional/` and `~/.claude-personal/`, symlinks shared resources and gitleaks operator rules
- `provision-public-repo.sh` — Converges a public GitHub repo onto estate baseline (hooks, rulesets, push protection, squash-only merges)

### Other

- `.claude/statusline/statusline.sh` — Custom Claude Code statusline showing deliverable-repo git state and knowledge queue depth
- `.config/starship.toml` — Starship prompt theme
- `tool-update-check` — Shell-startup notifier for manually-updated tools (reads blueprint `tools.json`)

## Requirements

Hard dependencies for the skills and rules in this repo:

- **Linear + linear-tactic MCP server** — required by `/session-start`, `/session-closeout`, and `/new-project`, which call `mcp__linear-tactic__linear_*` to read project state and file issues.
  - Without it, every Linear call fails silently and the skills never complete. Install [linear-tactic](https://github.com/tacticlaunch/mcp-linear) as an MCP server in your profile, scoped to your usage.
- **dotty-private companion repo** — required by the `system-blueprint` skill and the `blueprint-awareness` rule, which expect blueprint slice scripts at `~/bin/dotty-private/.claude/blueprint/`.
  - Without a checkout there, the rule fires but finds no slices, and the skill's subcommands error out. Clone a companion private repo at that path, or fork this setup and adapt the paths.
  - It also holds personal shell config, SSH network config, app preferences, and the private Claude Code config (`CLAUDE.md`, `settings.json`).

Soft expectations (won't break things but inform behavior):

- **Obsidian-synced vault** — `fix-obsidian-claude-sync.sh` and `vault-mcp-redirect.sh` assume a vault exists. Set `VAULT_ROOT` to override the default path, or skip both hooks.
- **1Password CLI (`op`) + SSH agent** — used by SSH setup (in dotty-private) and the MCP credential indirection pattern in blueprint slices.

## Installation

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

## Customization

1. Fork this repo
2. Copy `CLAUDE.sample.md` to your private repo as `CLAUDE.md` and customize
3. Copy `.claude/settings.sample.json` to your private repo as `settings.json` and customize
4. Update paths in `setup-claude-profiles.sh` to point to your repos
5. Modify skills to reference your own workspace paths

## Security

Review skills before installing. They load into Claude's context and execute with your permissions. Audit the contents of `.claude/skills/`, `.claude/agents/`, and `.claude/hooks/` before use.

This repo carries more executable surface than a typical skills project. `setup-claude-profiles.sh` symlinks its skills, agents, and rules into your Claude Code profile directories, so all of them load in every session on that profile. Hooks are wired separately, by path in your private `settings.json`, and intercept tool calls before they run. `setup-terminal.sh` goes further still — it installs shell configuration and applies SSH hardening.

Two of the hooks, `gh-pr-body-guard.sh` and `git-hook-bypass-guard.sh`, exist to block unsafe operations. Both are tool-scoped and porous to a plain shell: defense-in-depth, not a boundary.

## License

MIT. See [LICENSE](LICENSE).
