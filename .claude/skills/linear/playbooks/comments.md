# Playbook: comments

Two structured comment formats, exactly specified so agents don't improvise the shape. A plain progress comment (`createComment` with a body, ISO-date-prefixed) needs no playbook — call the MCP tool directly.

## `[VALIDATION]` receipt

Posted by `` `@attack-kitty` `` on the relevant issue, and only when the verdict is CONFIRMED (any other verdict returns directly to the caller, never as a Linear comment):

```
[VALIDATION] — {validation_type}
Verdict: CONFIRMED
Intent: {one-line human-readable conclusion}
Specifics: {what was verified — concise}
```

This is the comment the map lane's guard (`playbooks/transitions.md`) and `` `@traffic-cone` ``'s `mark_done` gate check for. A verdict of anything other than CONFIRMED never lands here.

## `[HANDOFF]`

Posted on the worked ticket at session end — never on the map. Two to three lines max, no re-summary of what was done:

- Recommended next act (one line)
- Carry-forward context not obvious from the ticket body (one to two lines)

## What this playbook does NOT do

- Does NOT cover plain progress comments — call `mcp__linear-tactic__linear_createComment` directly.
- Does NOT decide the verdict or compose the `[HANDOFF]` content — the caller judges; this playbook fixes the shape.
