Claude Code infrastructure, skills, and Mac setup. This is a public dotfiles repo — it contains the non-sensitive parts of my Mac development environment, focused on how I use Claude Code.

## Installation

Requires Homebrew, git, gh, and stow.

This repo is the public half. The private half — `CLAUDE.md`, `settings.json`, shell and SSH config — lives in a companion repo. Mine is private, so fork this one and build your own companion from the sample files first; see [Customization](#customization).

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
bash ~/bin/dotty/setup-claude-profiles.sh
```

Plugins are gitignored, so copy them across too: `scp -r user@other:~/bin/dotty-private/.claude/plugins/ ~/bin/dotty-private/.claude/plugins/`

### Dependencies

- **Linear + the [linear-tactic](https://github.com/tacticlaunch/mcp-linear) MCP server** — required by `/session-start`, `/session-closeout`, and `/new-project`. Without it the Linear calls error out — `/new-project` stops outright, and the session skills run with an incomplete picture.
- **A dotty-private companion repo** — required by `/system-blueprint`, which expects blueprint slices — the declared machine config that lives outside git — at `~/bin/dotty-private/.claude/blueprint/`. It also holds the private `CLAUDE.md` and `settings.json`.
- **The [wiki](https://github.com/lexijamesesq/wiki) companion repo** — required by `/session-start` and `/session-closeout`, which invoke its knowledge-layer skills by name. Without it the session skills' knowledge steps have nothing to invoke.
- **`gitleaks` and `pre-commit`** — the git hooks refuse to run without them, which blocks every commit and push. `jq` and `python3` are both hard dependencies of `gh-pr-body-guard.sh`, which fails closed without either.
- **An Obsidian vault** *(optional)* — used by `fix-obsidian-claude-sync.sh` and `vault-mcp-redirect.sh`. Without one, those two hooks have nothing to act on.
- **1Password CLI** *(optional)* — used by SSH setup and the credential indirection in the blueprint slices.

## What's Included

### Session orchestration

Bracket a working session — load state at the start, write it back at the end.

| Artifact | Type | What it does |
|----------|------|--------------|
| `/session-start` | Skill | Loads project state, recent progress, and the pending backlog |
| `/session-closeout` | Skill | Writes state back, records what changed |
| `/project-state` | Skill | Reads and writes the Project State section of a project's CLAUDE.md |

### Projects and backlog

| Artifact | Type | What it does |
|----------|------|--------------|
| `/new-project` | Skill | Walks you through creating a project or hub, and wires up where its notes land |
| `/linear` | Skill | Protocol reference for Linear operations — ticket creation, claiming, state transitions, and structured comment formats |

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
| `/grilling` | Skill | Interviews me one question at a time to stress-test a plan or decision — looks up facts instead of asking, puts decisions to me with a recommendation, and holds off acting until we agree |
| `/domain-modeling` | Skill | Builds and sharpens a project's domain model — challenges fuzzy terminology, stress-tests edge cases, and records architectural decisions |
| `/smoke` | Skill | Makes each layer of local config prove it's still wired — hooks fire, lint runs, registered paths exist |
| `/system-blueprint` | Skill | Records the machine config that lives outside git, and reapplies it elsewhere |
| `/update-mbp` | Skill | Audits my laptop over SSH and brings it back in sync with this machine |

### Research and delegation

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
| `ways-of-working` | Six principles — solve real problems, leave no orphans, close what you open, self-graded work is incomplete, the operator's words are the measure, no reflexive memory writes |

### Agents

Domain-specific agents — spawned by skills, never invoked directly. Each owns a narrow surface and carries its own tools, model tier, and refusal walls.

| Artifact | Type | What it does |
|----------|------|--------------|
| `@attack-kitty` | Agent | Non-author verification — receives a typed mandate, fetches its own evidence, judges independently, and posts or returns a verdict. Twelve mandate types covering gate checks, formal verification, and thinking aids. Mandate authority enforcement: gate mandates require L0 callers; thinking-aid mandates are available at any depth |
| `@traffic-cone` | Agent | Correctness agent for lifecycle transitions — claim, park, block, un-park, cancel, mark_done, resolve, close-map. Every state mutation in the system routes through it; no other agent or skill writes ticket state directly |

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

### Git hooks

Portable, and consumed through `pre-commit`. Run `pre-commit install` in a fresh clone — `default_install_hook_types` wires all three types at once.

| File | What it does |
|------|--------------|
| `git-hooks/gitleaks-commit-msg.sh` | Scans the commit message for secrets |
| `git-hooks/gitleaks-pre-push.sh` | Scans the full outgoing commit range — the authoritative choke point |
| `git-hooks/gitleaks-common.sh` | Shared helpers for the two hooks above |

### Shell integration

| File | What it does |
|------|--------------|
| `.claude/statusline/statusline.sh` | Shows deliverable-repo git state and knowledge-queue depth in the Claude Code statusline |
| `.config/starship.toml` | Themes the Starship prompt |
| `tool-update-check` | Warns at shell startup when a manually-updated tool has gone stale |

## Configuration

The system separates what you configure from what skills handle.

**You configure:**
- `CLAUDE.md` in your private repo — the keys skills resolve at runtime: `workspace_root`, `projects_root`, `user_timezone`, Linear team UUIDs, and template and reference paths
- `settings.json` in your private repo — hook registrations, permissions, environment
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

Two Claude Code profiles — professional and personal — share one public toolchain and keep separate private config. `setup-claude-profiles.sh` symlinks `skills/` and `rules/` from this repo into `~/.claude-professional/` and `~/.claude-personal/`, then symlinks `CLAUDE.md` and `settings.json` in from the private companion repo. Hooks are the exception: they are not symlinked, and `settings.json` names each one by path.

```
  ~/bin/dotty  (public)             ~/bin/dotty-private  (private)
  ├── skills/    ─┐                 ├── CLAUDE.md       ─┐
  ├── rules/      ├─ symlinked      ├── settings.json    ├─ symlinked
  └── hooks/ *   ─┘                 └── plugins/        ─┘
                  │                                      │
                  └───────────────┬──────────────────────┘
                                  ▼
            ~/.claude-professional/    ~/.claude-personal/
                                  │
                                  ▼
                        Claude Code session
              rules auto-load · skills load on demand

  * hooks are not symlinked — settings.json names each by path
```

Skills never hardcode locations. They reference paths through keys like `workspace_root` that resolve against your `CLAUDE.md` when the skill runs. That is what lets the same skill serve two profiles pointing at different workspaces.

The agent architecture uses a receipt-based trust chain: no actor trusts another's word. `@traffic-cone` independently verifies every state transition; `@attack-kitty` independently validates every artifact. A three-level depth model governs who spawns whom: L0 orchestrators (wayfinder, implement) spawn discipline teammates and both agents; L1 teammates may invoke `/dispatch` to fan out unnamed L2 subagents for complex work; L2 subagents are true leaves. Discipline teammates are session-scoped — spawned once per effort, they receive sequential work via SendMessage and persist until the session ends.

Secret scanning is a line, not a single gate. `pre-commit` scans the staged diff at commit time and the message at `commit-msg`. `pre-push` scans the full outgoing commit range — the last place the complete ruleset meets the complete data before anything leaves the machine. Two `PreToolUse` hooks add another layer inside Claude Code itself.

## Customization

The skills assume my setup: a Linear backlog, an Obsidian vault, and a private companion repo. To adapt them:

- **Different repo paths:** update the paths in `setup-claude-profiles.sh`.
- **Your own private repo:** fork this, then copy `CLAUDE.sample.md` and `.claude/settings.sample.json` into it as `CLAUDE.md` and `settings.json`.
- **Without Obsidian:** set `VAULT_ROOT`, or drop the two vault hooks from `settings.json`.
- **Without Linear:** delete `/session-start`, `/session-closeout`, and `/new-project` from `.claude/skills/`. Everything else is unaffected.

## Security

Review skills before installing. They load into Claude's context and execute with your permissions. Audit the contents of `.claude/skills/` and `.claude/hooks/` before use.

This repo carries more executable surface than a typical skills project. `setup-terminal.sh` rewrites your shell configuration and applies SSH hardening. The two guard hooks block unsafe operations inside Claude Code sessions, but both are tool-scoped and porous to a plain shell — defense-in-depth, not a boundary.

## Acknowledgments

- **[Matt Pocock's skills](https://github.com/mattpocock/skills)** (MIT) — the foundation of `/wayfinder`, and the source of `/grilling`, `/prototype`, and `/domain-modeling`; adapted files carry per-file attribution.
- **[HumanLayer](https://github.com/humanlayer/humanlayer)** — the research-contamination discipline (blind researchers, question-only briefs), the documentarian identity, and validation-mandate concepts adapted into the research lane and the slice-validation gates.
- **[Ringer](https://github.com/NateBJones-Projects/ringer)** (Nate B. Jones) — check-hygiene concepts: proofs written as claims with checks that say why they fail; the `verified`-sentence discipline.

## License

MIT. See [LICENSE](LICENSE).
