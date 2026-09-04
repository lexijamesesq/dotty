Claude Code infrastructure, skills, and Mac setup. This is a public dotfiles repo — it contains the non-sensitive parts of my Mac development environment, focused on how I use Claude Code.

## Installation

Requires Homebrew, git, gh, stow, and the Claude Code CLI.

This repo is the public half — skills, the agent, and Claude Code hooks are consumed at runtime via installed Claude Code plugins rather than symlinked from a `settings.json` path into this checkout; the blueprint's core slice still symlinks `rules/` (see How It Works below). The Git hooks table below is a separate, pre-commit-based mechanism this doesn't touch — every file there stays tracked here. The private half — `CLAUDE.md`, `settings.json`, shell and SSH config, and the blueprint slices that install and enable the plugins — lives in a companion repo. Mine is private, so fork this one and build your own companion from the sample files first; see [Customization](#customization).

```
gh repo clone <user>/dotty ~/bin/dotty
gh repo clone <user>/dotty-private ~/bin/dotty-private
```

Then bootstrap:

```
chmod +x ~/bin/dotty/setup-*.sh
~/bin/dotty/setup-terminal.sh
```

### Manual steps

1. **1Password SSH agent** — Enable in 1Password > Settings > Developer
2. **SSH public key** — Export your inter-machine key to `~/.ssh/home-network.pub`
3. **sshd hardening** — `sudo cp ~/bin/dotty-private/ssh-sshd-hardening.conf /etc/ssh/sshd_config.d/000-local.conf`
4. **Remote Login** — Enable in System Settings > General > Sharing
5. **Claude Code auth** — Open each Ghostty profile, run `claude`, then `/login`

### Second machine

```
cd ~/bin/dotty && git pull
cd ~/bin/dotty-private && git pull
stow -D -d ~/bin -t ~ dotty-private
stow -d ~/bin -t ~ dotty-private
```

Install the Claude Code CLI and log into each Ghostty profile (`claude`, then `/login`) before running the installer — the private blueprint's `plugins` slice needs an authenticated CLI to install and enable the harness plugins, and it runs as the last step of the installer itself:

```
bash ~/bin/dotty/setup-claude-profiles.sh
```

Nothing to copy across for plugins — the `plugins` slice installs the declared plugins fresh from the operator's marketplaces on every machine (which ones: How It Works below).

### Dependencies

- **Linear + the [linear-tactic](https://github.com/tacticlaunch/mcp-linear) MCP server** — required by `/session-start` and `/session-closeout` (in the `work-lifecycle` plugin) and by `/new-project` (in the `wiki` plugin). Without it the Linear calls error out — `/new-project` stops outright, and the session skills run with an incomplete picture.
- **A dotty-private companion repo** — the blueprint slices that install the plugins and apply the private config (`CLAUDE.md`, `settings.json`, the statusline). Without it, nothing installs the harness or applies a profile's settings — `setup-claude-profiles.sh` stops after creating the directories.
- **The [wiki](https://github.com/lexijamesesq/wiki) companion repo** — required by `/session-start` and `/session-closeout`, which invoke its knowledge-layer skills by name. Without it the session skills' knowledge steps have nothing to invoke.
- **`gitleaks` and `pre-commit`** — the git hooks refuse to run without them, which blocks every commit and push. `jq` and `python3` are both hard dependencies of `gh-pr-body-guard.sh`, which fails closed without either.
- **An Obsidian vault** *(optional)* — used by `fix-obsidian-claude-sync.sh` and `vault-mcp-redirect.sh`. Without one, those two hooks have nothing to act on.
- **1Password CLI** *(optional)* — used by SSH setup and the credential indirection in the blueprint slices.

## What's Included

### Skills (shipped inside the `work-lifecycle` plugin — not tracked in this repo)

Every skill below installs from the operator's `work-lifecycle` marketplace (see How It Works); this repo carries none of them. The knowledge-layer skills live in the [wiki](https://github.com/lexijamesesq/wiki) repo and its `wiki` plugin; the operator-specific ones in the private companion repo's `operator` plugin.

#### Session orchestration

Bracket a working session — load state at the start, write it back at the end.

| Artifact | Type | What it does |
|----------|------|--------------|
| `/session-start` | Skill | Loads project state, recent progress, and the pending backlog |
| `/session-closeout` | Skill | Writes state back, records what changed |
| `/project-state` | Skill | Reads and writes the Project State section of a project's CLAUDE.md |

#### Projects and backlog

| Artifact | Type | What it does |
|----------|------|--------------|
| `/linear` | Skill | Protocol reference for Linear operations — ticket creation, claiming, state transitions, and structured comment formats |

#### Publishing and quality

Checks that run before anything leaves the machine.

| Artifact | Type | What it does |
|----------|------|--------------|
| `/publish` | Skill | Runs every check a repo must pass before it ships — scans, conformance, review |
| `/house-qa` | Skill + Script | Judges whether a new file reads like it belongs beside the ones already there |
| `/github-readme` | Skill | Writes or refreshes a README for a skill, agent, rule, or project |
| `/sample-universe` | Skill | Supplies the fictional company that public examples borrow their names from |

#### Authoring and machine state

| Artifact | Type | What it does |
|----------|------|--------------|
| `/grilling` | Skill | Interviews me one question at a time to stress-test a plan or decision — looks up facts instead of asking, puts decisions to me with a recommendation, and holds off acting until we agree |
| `/domain-modeling` | Skill | Builds and sharpens a project's domain model — challenges fuzzy terminology, stress-tests edge cases, and records architectural decisions |
| `/smoke` | Skill | Makes each layer of local config prove it's still wired — hooks fire, lint runs, registered paths exist |

#### Research and delegation

| Artifact | Type | What it does |
|----------|------|--------------|
| `/research` | Skill | Classifies a search task (exploratory vs lookup), runs the right retrieval strategy, and knows when to stop |
| `/dispatch` | Skill | Pre-spawn gate — decides whether to delegate, what shape the execution takes, and equips each delegate's brief. Enforces a depth model: L0 orchestrators, L1 discipline teammates, L2 leaf subagents |
| `/wayfinder` | Skill | Charts a loose idea as a map of decision tickets on Linear, resolves them with the operator, then builds from the operator-confirmed Destination and Done When through validated slices |
| `/prototype` | Skill | Builds a throwaway prototype to answer a design question — the decision lands on the ticket; the code stays disposable |

### Rules

Loaded into every session, on both profiles.

| Rule | What it enforces |
|------|------------------|
| `ways-of-working` | Four hard boundaries — self-graded work is incomplete, no reflexive memory writes, the operator's words are the spec, configured tooling before raw shell — and four expected behaviors: name the failure a mechanism came from, name what a cut still covers, retire what a replacement replaced, surface problems you won't fix |

### Agents (shipped inside the `work-lifecycle` plugin — not tracked in this repo)

Domain-specific agents — spawned by skills, never invoked directly. Each owns a narrow surface and carries its own tools, model tier, and refusal walls.

Lifecycle transitions (claim, park, block, un-park, cancel, mark_done, resolve, close-map) are not an agent: they are the `/traffic-cone` skill and the `traffic-cone` script, run in-process by the caller. The `@traffic-cone` name in skill text refers to that transition law, not to a spawnable agent.

| Artifact | Type | What it does |
|----------|------|--------------|
| `@attack-kitty` | Agent | Non-author verification — receives a typed mandate, fetches its own evidence, judges independently, and posts or returns a verdict. Twelve mandate types covering gate checks, formal verification, and thinking aids. Mandate authority enforcement: gate mandates require L0 callers; thinking-aid mandates are available at any depth |

### Hooks

Claude Code lifecycle hooks — shipped inside the `estate-hooks` plugin, not tracked in this repo (see How It Works below).

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
| `setup-claude-profiles.sh` | Creates the two profile directories, prepares the `rules/` dir the blueprint's core slice still populates by symlink, and points each profile's plugin cache at the shared install directory the `plugins` slice installs into |
| `provision-public-repo.sh` | Brings a public repo up to baseline — hooks, branch rules, push protection |

### Git hooks

Portable, and consumed through `pre-commit`. Run `pre-commit install` in a fresh clone — `default_install_hook_types` wires all three types at once.

| File | What it does |
|------|--------------|
| `git-hooks/gitleaks-staged.sh` | Scans the staged diff before a commit is created |
| `git-hooks/gitleaks-commit-msg.sh` | Scans the commit message for secrets |
| `git-hooks/gitleaks-pre-push.sh` | Scans the full outgoing commit range — the authoritative choke point |
| `git-hooks/gitleaks-common.sh` | Shared helpers for the three hooks above |

### Shell integration

| File | What it does |
|------|--------------|
| `.config/starship.toml` | Themes the Starship prompt |
| `tool-update-check` | Warns at shell startup when a manually-updated tool has gone stale |

The Claude Code statusline is thin-layer content declared in the private companion repo and installed to the fixed path `~/.config/claude-estate/statusline.sh` by the blueprint's `statusline` slice, showing deliverable-repo git state and knowledge-queue depth. Both profiles' `settings.json` point `statusLine.command` there.

## Configuration

The system separates what you configure from what skills handle.

**You configure:**
- `CLAUDE.md` in your private repo — the keys skills resolve at runtime: `workspace_root`, `projects_root`, `user_timezone`, Linear team UUIDs, and template and reference paths
- `settings.json` in your private repo — which plugins are enabled, permissions, environment. Hook registration itself lives inside the enabled `estate-hooks` plugin, not in this file — `hooks` stays `{}`
- `setup-claude-profiles.sh` — the repo paths, if your checkouts live somewhere else

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
Writes state back, files what the session learned.

### Publishing

```
/publish
```
Runs the pre-publish gate: scaffold check, sample-file audit, house-qa conformance, a full gitleaks scan, and an advisory security review.

## How It Works

Two Claude Code profiles — professional and personal — install the same harness plugins and keep separate private config. Skills, the agent, and hooks ship inside Claude Code plugins — `work-lifecycle` and `estate-hooks` from the operator's `work-lifecycle` marketplace, plus the `wiki` plugin (the knowledge-layer skills, from the [wiki](https://github.com/lexijamesesq/wiki) repo) and the private `operator` plugin (operator-specific skills, from the companion repo); the private blueprint's `plugins` slice installs and enables them, machine-wide, in both profiles. `setup-claude-profiles.sh` only prepares the ground for that: it creates the profile directories, the `rules/` dir the blueprint's core slice still populates by symlink, and points each profile's plugin cache at one real directory outside any git checkout. This repo carries no skills of its own.

Each profile owns a real `settings.json`, applied from declared state in the private companion repo rather than symlinked. With `estate-hooks` enabled, a profile's `hooks` block is `{}` — its hooks ship inside the plugin and Claude Code resolves them from there, not from a path this repo names. The statusline installs the same way — see [Shell integration](#shell-integration) above.

```
  marketplaces: work-lifecycle,     ~/bin/dotty-private  (private)
  wiki, operator (skills · agent ·  ├── CLAUDE.md        ─┐
  hooks)                            │                     │
        │ installed & enabled       ├── settings-*.json   ├─ applied
        ▼ by the `plugins` slice    └── blueprint/       ─┘
  ~/.local/share/claude-estate/           plugins · statusline slices
  plugins  (real dir, shared)                   │
        │                                       │
        ├───────────────┬───────────────────────┘
        ▼               ▼
  ~/.claude-professional/      ~/.claude-personal/
    plugins    (symlink)         plugins    (symlink)
    settings.json (applied)      settings.json (applied)
    rules/ (symlinked            rules/ (symlinked
    from dotty)                  from dotty)
        │               │
        └───────┬───────┘
                ▼
        Claude Code session
   skills, agent, hooks resolve from the enabled plugins
   rules auto-load from the one remaining symlink
```

Skills never hardcode locations. They reference paths through keys like `workspace_root` that resolve against your `CLAUDE.md` when the skill runs. That is what lets the same skill serve two profiles pointing at different workspaces.

The architecture uses a receipt-based trust chain: no actor trusts another's word. The `traffic-cone` scripts verify every state transition is earned before executing it; `@attack-kitty` independently validates every artifact. A three-level depth model governs who spawns whom: L0 orchestrators (wayfinder) spawn discipline teammates and `@attack-kitty`; L1 teammates may invoke `/dispatch` to fan out unnamed L2 subagents for complex work; L2 subagents are true leaves. Discipline teammates are session-scoped — spawned once per effort, they receive sequential work via SendMessage and persist until the session ends.

Secret scanning is a line, not a single gate. `pre-commit` scans the staged diff at commit time and the message at `commit-msg`. `pre-push` scans the full outgoing commit range — the last place the complete ruleset meets the complete data before anything leaves the machine. Two `PreToolUse` hooks add another layer inside Claude Code itself.

## Customization

The skills assume my setup: a Linear backlog, an Obsidian vault, and a private companion repo. To adapt them:

- **Different repo paths:** update the paths in `setup-claude-profiles.sh`.
- **Your own private repo:** fork this, then copy `CLAUDE.sample.md` and `.claude/settings.sample.json` into it as `CLAUDE.md` and `settings.json`.
- **Without Obsidian:** set `VAULT_ROOT`, or drop the two vault hooks from `settings.json`.
- **Without Linear:** drop `wiki@wiki` from your blueprint's `plugins` slice (`/new-project` is its only Linear-dependent skill), and fork `work-lifecycle` to remove `/session-start` and `/session-closeout` — a plugin installs whole, so the alternative is leaving it enabled and not invoking those two.

## Security

Review skills before installing. They load into Claude's context and execute with your permissions. Audit the contents of `git-hooks/`, `setup-terminal.sh`, `setup-claude-profiles.sh`, `provision-public-repo.sh`, `traffic-cone`, `tool-update-check`, and `.claude/eval/` — the executable surface this repo ships — and each enabled plugin's cache (How It Works), which is where the skills, the agent, and the hooks arrive from, before use.

This repo carries more executable surface than a typical skills project. `setup-terminal.sh` rewrites your shell configuration and applies SSH hardening. The two guard hooks block unsafe operations inside Claude Code sessions, but both are tool-scoped and porous to a plain shell — defense-in-depth, not a boundary.

## Acknowledgments

- **[Matt Pocock's skills](https://github.com/mattpocock/skills)** (MIT) — the seed of `/wayfinder` (since rebuilt estate-native), and the source of `/grilling`, `/prototype`, and `/domain-modeling`; adapted files carry per-file attribution.
- **[HumanLayer](https://github.com/humanlayer/humanlayer)** — the research-contamination discipline (blind researchers, question-only briefs), the documentarian identity, and validation-mandate concepts adapted into the research lane and the slice-validation gates.
- **[Ringer](https://github.com/NateBJones-Projects/ringer)** (Nate B. Jones) — check-hygiene concepts: proofs written as claims with checks that say why they fail; the `verified`-sentence discipline.

## License

MIT. See [LICENSE](LICENSE).
