# Shared Claude Code Infrastructure

Two repos combine into profile directories via `~/bin/dotty/setup-claude-profiles.sh`:

- **Public tools** (`~/bin/dotty/.claude/`): skills, agents, rules
- **Private config** (`~/bin/dotty-private/.claude/`): CLAUDE.md, settings.json, plugins

Symlinked into `~/.claude-professional/` and `~/.claude-personal/`. NOT managed by stow.

## Why the split exists

`~/bin/` is not backed up by CrashPlan, so GitHub provides the version history and recovery path for everything under `~/bin/dotty/`. To get that backup, `dotty` is committed to a **public** GitHub repo. `dotty-private` is the companion **private** GitHub repo holding anything that can't ship publicly. Both repos live on GitHub; one is public, one is private.

**The classification is "does this file live in a location that pushes to public GitHub?" — not "is this file's current content sensitive?"** A future edit adding a real credential to `settings.json` would expose it the moment the public repo is pushed. The private-by-category rule for `CLAUDE.md`, `settings.*`, and `plugins/` is load-bearing and non-negotiable.

**Do NOT propose promoting** `CLAUDE.md`, `settings.*`, or `plugins/` from dotty-private to dotty on the grounds that their current contents look non-sensitive. The rule is about the commit boundary, not the content snapshot.

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
- **Editing private files (CLAUDE.md, settings.json):** Edit the canonical source in `~/bin/dotty-private/.claude/`. If the edit adds a new section or schema field, also update the corresponding `*.sample.*` companion in `~/bin/dotty/` so public consumers see the shape. See `rules/sample-files.md` for the sample convention.
- **Adding a new shared resource type:** Update `setup-claude-profiles.sh` arrays, then re-run the script.
- **Skills vs rules:** Skills load when invoked. Rules auto-load every session. Behavioral instructions that must always be in context go in rules, not skills.

## Files inside the Obsidian vault

This split applies only to `~/bin/` configuration. Files under `~/Vaults/Notes/` are covered by Obsidian Sync for backup and are not committed from the vault's top level. When a specific vault subfolder has its own git repo that pushes to GitHub (e.g., HA project, Metrics project), real `CLAUDE.md` is gitignored per-folder and a `CLAUDE.sample.md` ships in its place. See `rules/sample-files.md`.
