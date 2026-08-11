#!/usr/bin/env bash
# linear-transition-guard.sh
#
# PreToolUse hook (matchers: Bash + mcp__linear-tactic__linear_updateIssue):
# the ROAD guard for the transition gate. Linear lifecycle state mutations
# route through traffic-cone's fused scripts (cone_preflight.py
# --execute-if-clean) — never raw MCP stateId writes, never hand-built
# bridge payloads. Receipt: 2026-08-10 — every prior occupant of the gate
# was voluntary; a session willing to skip simply never engaged it. This
# hook is the first non-voluntary layer: it stands in the road, not the gate.
#
# WARN-ONLY phase (stderr, exit 0). Deny-mode is a separate later commit,
# gated on a quiet warn phase; /linear transitions.md's MCP protocol text is
# the named deny-flip prerequisite edit.
#
# Layer 1 (structured, tight): updateIssue WITH stateId — post-contraction
# nothing legitimate writes state via MCP; the scripts mutate via the
# GraphQL bridge, so an MCP stateId write is definitionally a hand-rolled
# transition. updateIssue WITHOUT stateId (descriptions, labels, titles)
# is legitimate everywhere and stays silent.
# Layer 2 (string-match, porous — same documented posture as
# git-hook-bypass-guard): a Bash command carrying a linear-gql payload with
# stateId/delegateId that is not an invocation of the sanctioned scripts.
# Variable assembly slips past; the tripwires (CM5, the sweep, read-back
# law) are the backstop. Fail-open on infra errors, like the sibling guards.

set -uo pipefail

command -v jq >/dev/null 2>&1 || exit 0
INPUT=$(cat 2>/dev/null)
[[ -z "$INPUT" ]] && exit 0
TOOL=$(jq -r '.tool_name // empty' <<<"$INPUT" 2>/dev/null)

warn() {
    echo "linear-transition-guard (warn-only): $1 — transitions route through traffic-cone's fused scripts: cone_preflight.py <verb> <id> --execute-if-clean (see the traffic-cone skill's Dispatch table)." >&2
}

case "$TOOL" in
  mcp__linear-tactic__linear_updateIssue)
    STATEID=$(jq -r '.tool_input.stateId // empty' <<<"$INPUT" 2>/dev/null)
    [[ -n "$STATEID" ]] && warn "raw MCP state write (updateIssue with stateId)"
    ;;
  Bash)
    CMD=$(jq -r '.tool_input.command // empty' <<<"$INPUT" 2>/dev/null)
    [[ -z "$CMD" ]] && exit 0
    if grep -q "linear-gql" <<<"$CMD" && grep -qE "stateId|delegateId" <<<"$CMD"; then
        if ! grep -qE "cone_preflight\.py|linear_bridge\.py|map_sweep\.py" <<<"$CMD"; then
            warn "hand-built bridge payload carrying stateId/delegateId"
        fi
    fi
    ;;
esac

exit 0
