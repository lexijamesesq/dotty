---
name: queue
description: Operator-judgment queue expert — create Wiki/Queue/ item files and run the operator-invoked triage flow (menu-guided; scoped or all). Signal surface is the statusline Knowledge Triage Queue line; this skill is the verb. Invoked by /knowledge-layer scope-lint (create-item), automated lanes (create-item), and the operator (triage). Triggers on "/queue triage", "/queue triage-all", "triage the queue", "/queue <operation>".
---

# queue (global name-forwarder)

This is a thin forwarder: the skill's logic is vault-resident so the Wiki project stays self-contained. This global name exists because consumers (`/knowledge-layer scope-lint`, `/router`, `/wiki-intake`, automated lanes, and the operator) invoke it by name from arbitrary session cwds where ancestor-walk resolution cannot see Wiki-hosted skills.

1. Resolve the vault root: `VAULT_ROOT` env var if set; otherwise global CLAUDE.md > Configuration > `workspace_root`. Unresolvable → halt and say so.
2. Read `<vault>/Wiki/claude/skills/queue/SKILL.md` and execute it exactly as if it had been invoked directly, loading its playbooks from that same directory.
3. If the vault is not accessible from this session, do NOT create queue items or run triage from memory — report the gap instead.
