---
name: knowledge-integration
description: Universal router + gatekeeper for everything entering the vault's knowledge layer. Receives typed candidates from any ingress surface and resolves each to a terminal disposition — file, queue, or discard — under the trust/mode authority model. No candidate bypasses it; no extractor writes destinations. Triggers on "/knowledge-integration assess candidates" or "/knowledge-integration assess single".
---

# knowledge-integration (global name-forwarder)

This is a thin forwarder: the gatekeeper's logic is vault-resident so the Wiki project stays self-contained. This global name exists because consumers (/capture, wiki-intake, capture-meeting, session-closeout chain) invoke it by name from arbitrary session cwds where ancestor-walk resolution cannot see Wiki-hosted skills.

1. Resolve the vault root: `VAULT_ROOT` env var if set; otherwise global CLAUDE.md > Configuration > `workspace_root`. Unresolvable → halt and say so.
2. Read `<vault>/Wiki/claude/skills/knowledge-integration/SKILL.md` and execute it exactly as if it had been invoked directly, loading its playbooks and calibration surface from that same directory.
3. If the vault is not accessible from this session, do NOT adjudicate candidates from memory — report the gap instead.
