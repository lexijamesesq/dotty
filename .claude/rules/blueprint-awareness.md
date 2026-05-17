# Blueprint Awareness

**Prerequisite:** this rule applies only when a dotty-private companion repo exists at `~/bin/dotty-private/.claude/blueprint/`. If that path doesn't exist, this rule does not fire and is not relevant to the current session.

The system blueprint at `~/bin/dotty-private/.claude/blueprint/` is the canonical declared state for harness-managed config that lives outside git: MCP servers, hooks, plugins, settings sections. Each slice script declares one slice; CHANGELOG.md records when and why each change was made.

## When to consult the blueprint

Before declaring that a capability gap is unrecoverable — e.g., an MCP server isn't available, a plugin/skill the user expects is missing, a hook didn't fire — check whether the capability is **declared in the blueprint but not applied** on this device.

This applies to any session on any device, not just `/update-mbp` flows. The blueprint exists so harness state can be reproduced; this rule makes the user not have to remember to sync — the moment they hit a gap, surface the right next step.

## How to consult

1. List slice files: `ls ~/bin/dotty-private/.claude/blueprint/*.sh`
2. For the relevant slice (filename matches the gap's class + scope, e.g. `mcp-personal.sh` for an MCP gap on the personal profile), run `bash <slice> describe` to read declared state as JSON
3. Read the tail of `~/bin/dotty-private/.claude/blueprint/CHANGELOG.md` for provenance — when this state was added, with what context

## What to report to the user

If the missing capability is declared but not applied:
- Name the missing capability
- Quote the relevant CHANGELOG line so the user sees when and why it was added
- Propose: "Run `/system-blueprint apply` to reconcile this device with the blueprint?"

If the capability is not declared:
- Standard troubleshooting applies — the gap isn't a blueprint sync issue. The user may want to add the capability and `/system-blueprint capture <type>` afterwards.

## Scope

Applies to any class of declared state the blueprint manages today or in the future:
- MCP servers (live: `~/.claude-{profile}/.claude.json` mcpServers)
- Hooks (live: `~/.claude-{profile}/settings.json` hooks)
- Plugins (live: profile settings + `~/bin/dotty-private/.claude/plugins/`)
- Settings sections (live: `~/.claude-{profile}/settings.json` other keys)
- Future types as added

## When NOT to fire

- The user is intentionally exploring a configuration that diverges from the blueprint — don't push them to reconcile
- The capability gap is from a `claude.ai *` connector or `plugin:*` server — those are managed by claude.ai / plugin system, not blueprint scope
- Standard runtime errors unrelated to declared state (e.g., a server is configured but its endpoint is down)
