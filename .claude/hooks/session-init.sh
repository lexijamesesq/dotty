#!/usr/bin/env bash
# session-init.sh
#
# SessionStart hook: bootstraps per-session state for the git-gate hook.
#   - Ensures ~/.cache/claude/ exists with 0700 permissions
#   - Parses session_id from stdin JSON, exports CLAUDE_SESSION_ID via
#     $CLAUDE_ENV_FILE so it propagates into every Bash tool call in the
#     session. The env var is the AUTHORITATIVE source of session id —
#     skills must use $CLAUDE_SESSION_ID, never a cache file. Reason: a
#     single-file cache is overwritten by every session-init across all
#     concurrent sessions on the machine, introducing a race on sentinel
#     filenames.
#   - Clears stale sentinel markers and deny counters from prior sessions
#
# Tolerant: failures here would block all sessions. Stderr-warn but exit 0.
#
# Spec: ~/Vaults/Notes/Claude/System/Knowledge/github-skills-implementation.md
# Methodology: ~/Vaults/Notes/Claude/System/Knowledge/git-gating-methodology.md

set -uo pipefail

CACHE="${HOME}/.cache/claude"
mkdir -p "$CACHE" 2>/dev/null || {
    echo "session-init: failed to mkdir $CACHE" >&2
    exit 0
}
chmod 700 "$CACHE" 2>/dev/null || true

# Parse session_id from stdin JSON if jq is available; else fallback
INPUT=$(cat 2>/dev/null || true)
SESSION_ID=""
if command -v jq >/dev/null 2>&1 && [[ -n "$INPUT" ]]; then
    SESSION_ID=$(jq -r '.session_id // empty' <<<"$INPUT" 2>/dev/null || true)
fi

# Fallback: timestamp + pid keeps sessions distinct enough for cleanup purposes,
# though the gate hook's session_id parsing path (its own stdin JSON) is canonical.
if [[ -z "$SESSION_ID" ]]; then
    SESSION_ID="$(date +%s)-$$"
    if ! command -v jq >/dev/null 2>&1; then
        echo "session-init: jq missing — using fallback session id. Install: brew install jq" >&2
    fi
fi

# Authoritative: env propagation. Bash tool calls in the session inherit
# CLAUDE_SESSION_ID from the env file Claude Code sources after SessionStart.
if [[ -n "${CLAUDE_ENV_FILE:-}" && -w "$(dirname "$CLAUDE_ENV_FILE" 2>/dev/null)" ]]; then
    echo "export CLAUDE_SESSION_ID=$SESSION_ID" >> "$CLAUDE_ENV_FILE" 2>/dev/null || true
fi
# Note: no cache file written. Earlier versions wrote ~/.cache/claude/session-id
# but that single-file cache races across concurrent sessions and tempted skills
# to read it instead of $CLAUDE_SESSION_ID. Removed to eliminate the footgun.

# Clear stale state from prior sessions
# Markers older than 60 minutes are conservatively assumed stale
find "$CACHE" -maxdepth 1 -name 'git-authorized-*' -mmin +60 -delete 2>/dev/null || true
# Deny counters from prior sessions (only this session's stays — recreated on demand)
find "$CACHE" -maxdepth 1 -name 'git-gate-deny-count-*' -mmin +60 -delete 2>/dev/null || true

exit 0
