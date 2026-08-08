# Playbook: project-updates-review (load-boundary guard)

**LOAD BOUNDARY:** This playbook migrated to `` `@attack-kitty` ``'s `pu-review` mandate. The write path (`project-updates.md`) NEVER spawns `@attack-kitty` for this — review happens after the Project Update is written, as a fresh non-author spawn given only the written body, per the structural self-evaluation guard in `[[composable-skills-methodology]]`.

The orchestrator (typically `/session-closeout`) spawns `` `@attack-kitty` `` via the Agent tool AFTER the Project Update is written, with a `pu-review` mandate, model override **sonnet**:

```
Caller: L0 orchestrator

Mandate type: pu-review

Project Update body: <the written PU body, verbatim>
```

`@attack-kitty` reads nothing else — no closeout reasoning, no session context, no orchestrator state. It returns findings per its `pu-review` mandate card (in the attack-kitty skill's `playbooks/`), which carries the full six-criterion rubric and the PASS/REVISE/FAIL verdict shape.

The orchestrator decides whether to revise. Iteration cap 3.

## What this playbook does NOT do

Carry the rubric — that lives in `@attack-kitty`'s `pu-review` mandate card now. Author Project Update content — the write path composes; `project-updates.md` owns that.
