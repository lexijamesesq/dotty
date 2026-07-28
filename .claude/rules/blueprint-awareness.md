# Blueprint Awareness

**Prerequisite:** this rule applies only when a dotty-private companion repo exists at `~/bin/dotty-private/.claude/blueprint/`. If that path doesn't exist, this rule does not fire.

Before declaring that a capability gap is unrecoverable — an MCP server isn't available, a plugin/skill the user expects is missing, a hook didn't fire — check whether the capability is **declared in the blueprint but not applied** on this device. If declared, name the gap, quote the CHANGELOG provenance, and propose `/system-blueprint apply`.

A deferred-tool schema-loading error (InputValidationError from an unloaded MCP tool) is not a capability gap — use ToolSearch to load it.

Consult, report, and scope details live in the `/system-blueprint` skill.
