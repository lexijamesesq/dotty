# Invoking @attack-kitty

## Spawn prompt shape

Three things: **mandate type**, **parameters**, **caller depth**.

- **Mandate type:** one of the twelve cards under `playbooks/`
- **Parameters:** what the card requires (ticket id, map id, charter doc id — varies by type)
- **Caller depth:** `Caller: L0 orchestrator` or `Caller: L1 teammate`

Example: `map-close-eval mandate for <map-id>. Caller: L0 orchestrator`

Gate and formal-verification mandates require L0; thinking-aid mandates are any depth. Missing declaration defaults to L1. Model override per the mandate card's stated tier — sonnet default, Fable for `pressure-test` and `pre-mortem`.
