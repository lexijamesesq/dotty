---
name: capture-meeting
description: Captures meeting content. Registered meetings (Tier 1) DUAL-WRITE per-area rolling logs in {workspace_root}/Wiki/Knowledge/ PLUS every extracted entry emitted as a typed candidate to /knowledge-integration. Unregistered meetings (Tiers 2/3) are ROUTED-ONLY. Triggers on "/capture-meeting", a matched meeting-registry entry, or wiki-intake delegation.
---

# capture-meeting (global name-forwarder)

This is a thin forwarder: the skill's logic is vault-resident so the Wiki project stays self-contained. This global name exists because the skill is invoked from arbitrary session cwds (wiki-intake delegation, direct operator invocation for self-sourced meetings) where ancestor-walk resolution cannot see Wiki-hosted skills.

1. Resolve the vault root: `VAULT_ROOT` env var if set; otherwise global CLAUDE.md > Configuration > `workspace_root`. Unresolvable → halt and say so.
2. Read `<vault>/Wiki/claude/skills/capture-meeting/SKILL.md` and execute it exactly as if it had been invoked directly, loading any files it references from that same directory.
3. If the vault is not accessible from this session, do NOT improvise meeting processing — report the gap instead.
