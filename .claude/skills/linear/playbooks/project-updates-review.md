# Playbook: project-updates-review (load-boundary guard)

**LOAD BOUNDARY:** This playbook migrated to `` `@attack-kitty` ``'s `pu-review` mandate. The write path (`project-updates.md`) NEVER spawns `@attack-kitty` for this — review happens after the Project Update is written, as a fresh non-author spawn given only the written body, per the structural self-evaluation guard in `[[composable-skills-methodology]]`.

The caller spawns `@attack-kitty` via the Agent tool AFTER the Project Update is written, with a `pu-review` mandate, model override **sonnet**:

```
Caller: L0 orchestrator
Mandate type: pu-review
Project Update body: <the written PU body, verbatim>
```

Single pass — one review, one verdict. The caller acts on REVISE findings at their discretion; no re-invocation.

## What this playbook does NOT do

Carry the rubric — that lives in `@attack-kitty`'s `pu-review` mandate card now. Author Project Update content — the write path composes; `project-updates.md` owns that.
