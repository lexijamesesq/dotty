# Shared Claude Code Infrastructure

Two repos combine into profile directories via `~/bin/dotty/setup-claude-profiles.sh`:

- **Public tools** (`~/bin/dotty/.claude/`): skills, agents, rules
- **Private config** (`~/bin/dotty-private/.claude/`): CLAUDE.md, settings.json, plugins

Symlinked into `~/.claude-professional/` and `~/.claude-personal/`. NOT managed by stow.

## Shared Resources

Edit at the canonical source, not the symlink.

| Resource | Source | Loading |
|----------|--------|---------|
| `CLAUDE.md` | dotty-private | Auto-loaded every session |
| `settings.json` | dotty-private | Auto-loaded every session |
| `skills/` | dotty | On-demand (loaded when invoked) |
| `rules/` | dotty | Always-on (auto-loaded, separate budget from CLAUDE.md) |
| `agents/` | dotty | On-demand |
| `plugins/` | dotty-private | On-demand |

## Modifying Shared Resources

- **Adding to public dirs (skills, agents, rules):** Create the file in `~/bin/dotty/.claude/{dir}/`. Symlink covers the directory.
- **Adding to private dirs (plugins):** Create in `~/bin/dotty-private/.claude/{dir}/`.
- **Adding a new shared resource type:** Update `setup-claude-profiles.sh` arrays, then re-run the script.
- **Skills vs rules:** Skills load when invoked. Rules auto-load every session. Behavioral instructions that must always be in context go in rules, not skills.
