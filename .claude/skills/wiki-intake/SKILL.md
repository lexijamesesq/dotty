---
name: wiki-intake
description: >
  Single entry point for all Wiki-axis content. Checks for registered
  specialized handlers (e.g., /capture-meeting for recurring meeting docs)
  and delegates when matched. Otherwise classifies intent and routes:
  knowledge-intent captures are packaged as typed candidates for the
  knowledge-integration gatekeeper (which owns coherence, destination,
  filing, and validation), explore/triage captures become Wiki/Queue/
  items, and data corrections run the mutation chain. Triggers on
  "/wiki-intake", "file this to wiki", "wiki intake", or router delivery
  of wiki-axis captures.
user_invokable: true
---

# wiki-intake (global name-forwarder)

This is a thin forwarder: the skill's logic is vault-resident so the Wiki project stays self-contained. This global name exists because consumers (the Router, direct operator invocation) invoke it by name from arbitrary session cwds where ancestor-walk resolution cannot see Wiki-hosted skills.

1. Resolve the vault root: `VAULT_ROOT` env var if set; otherwise global CLAUDE.md > Configuration > `workspace_root`. Unresolvable → halt and say so.
2. Read `<vault>/Wiki/claude/skills/wiki-intake/SKILL.md` and execute it exactly as if it had been invoked directly, loading any files it references from that same directory.
3. If the vault is not accessible from this session, do NOT classify or route content from memory — report the gap instead.
