# Playbook: discipline-brief

Brief structure for spawning a session-scoped discipline teammate (the Engineer — SKILL.md § Roles). Relocated from the DSA agent template: a discipline teammate is `/implement`'s machinery, not a DSA, and this structure's only consumer is the conductor's dispatch step.

```
Discipline: <what you own>
Ticket: <the specific ticket this session is working>
Your scope: <what you take on vs. return to caller>
Work arrives: via SendMessage from your caller
Work returns: via SendMessage — results and receipts
Per-task proof: <convention>
Decomposition: invoke /dispatch for complex work — fan out unnamed subagents for independent pieces; L2 subagents are true leaves
Model: <tier>
You never: <discipline walls>
End: when this session ends, you end
```

## What this playbook does NOT do

- Does NOT define the Engineer role or its model pairing — SKILL.md § Roles owns that.
- Does NOT apply to DSA agents (`@traffic-cone`, `@attack-kitty`) — they are spawned per task with verb/mandate prompts, never briefed as teammates.
