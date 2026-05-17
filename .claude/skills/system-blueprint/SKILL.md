---
name: system-blueprint
description: Capture or apply the system blueprint — the canonical declared state for harness-managed config (MCP servers, hooks, plugins, settings sections) that lives at ~/bin/dotty-private/.claude/blueprint/. Triggers on "/system-blueprint", "system blueprint", "capture blueprint", "apply blueprint", "sync with blueprint", or similar phrases.
---

# system-blueprint

**Prerequisite:** this skill requires a dotty-private companion repo with blueprint slice scripts at `~/bin/dotty-private/.claude/blueprint/`. Without it, both subcommands below fail (capture has no slices to refresh; apply has no bootstrap.sh to run). See the project README's Requirements section.

The blueprint is the canonical declared state for harness-managed config that otherwise lives outside git. Each blueprint slice script declares one orthogonal slice of that state and implements three verbs: apply, describe, capture.

## Subcommands

### `/system-blueprint capture <type>`

Refresh blueprint slices of the given type from this device's live state.

```bash
for slice in ~/bin/dotty-private/.claude/blueprint/<type>-*.sh ~/bin/dotty-private/.claude/blueprint/<type>.sh; do
  [[ -f "$slice" ]] && bash "$slice" capture
done
```

Workflow:
1. Glob `<type>-*.sh` and `<type>.sh` in the blueprint directory
2. For each match, run `bash slice capture`
3. Report what was captured
4. Suggest `cd ~/bin/dotty-private && git diff blueprint/ && git commit -m "..."` for review

Does NOT commit. The user reviews via git diff and commits at their own boundary so they can batch with other dotty-private edits if desired.

### `/system-blueprint apply [--prune]`

Apply all blueprint slices to the current device.

```bash
bash ~/bin/dotty-private/.claude/blueprint/bootstrap.sh [--prune]
```

- Default: additive — add missing, update changed, leave undeclared alone
- `--prune`: full reconcile — slices remove items in live state but not declared

## Slice contract (for authoring new slice types)

Every slice script in `blueprint/` must implement three verbs:

| Verb | Behavior |
|---|---|
| `apply` (default) | Additive reconciliation against this slice's state class. `--prune` flag enables full reconcile. |
| `describe` | Print declared state as JSON to stdout. Format is type-specific; consumers (Claude during point-of-use reasoning) handle interpretation. |
| `capture` | Read live state for this slice's class+scope, write to sibling `.json` data file, append CHANGELOG stub. |

Naming convention:
- `<type>-<scope>.sh` for profile-scoped state (e.g. `mcp-personal.sh`, `hooks-professional.sh`)
- `<type>.sh` for global state (e.g. `plugins-enabled.sh`)

Each slice colocates its declared state in a sibling `.json` file with the same basename.

## Files

- `~/bin/dotty-private/.claude/blueprint/bootstrap.sh` — composition: runs all slices in apply mode
- `~/bin/dotty-private/.claude/blueprint/CHANGELOG.md` — narrative log of captures
- `~/bin/dotty-private/.claude/blueprint/<slice>.sh` + `<slice>.json` — individual slices

## Coverage today (v1 pilot)

- `mcp-personal.sh` — MCP servers in `~/.claude-personal/.claude.json`
- `mcp-professional.sh` — MCP servers in `~/.claude-professional/.claude.json`

Future slice types follow the same contract: hooks-{profile}.sh, plugins-{profile}.sh, etc.

## Related

- `~/bin/dotty/.claude/rules/blueprint-awareness.md` — point-of-use reasoning rule that fires when Claude hits a capability gap
- `~/bin/dotty/.claude/skills/update-mbp/SKILL.md` — pre-travel MBP sync that includes a blueprint-apply lane after dotty-private pull
