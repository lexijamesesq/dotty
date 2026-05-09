#!/usr/bin/env bash
# git-gate.sh
#
# PreToolUse hook on Bash: blocks direct git mutating verbs unless an authorized
# skill (e.g. /github-push) has set a sentinel file. Mirrors vault-mcp-redirect's
# shape but inverts the fail-open posture — gating is the security primitive,
# so missing dependencies must NOT silently allow mutating ops through.
#
# Scope: mutating verbs only. Read git operations (status, diff, log, show, branch,
# rev-parse, ls-files, fetch, pull-without-rebase) pass without sentinel.
#
# Pattern coverage (anti-mistake threat model):
#   - git push|commit|tag|reset --hard|push --force|--mirror|--all
#   - gh api|repo sync|pr merge|release create
#   - curl ... api.github.com|uploads.github.com
#   - hardened: --no-verify, core.hooksPath=, GIT_*= env-overrides
#   - inline payloads: bash|sh|zsh -c "...mutating..."
#
# Residual risk (deliberately accepted):
#   - bash /path/to/script.sh where script content contains git push (hook can't read script)
#   - shell expansion tricks (git$IFS push, encoded commands)
#   - custom git clients over SSH
#
# Spec: ~/Vaults/Notes/Claude/System/Knowledge/github-skills-implementation.md
# Methodology: ~/Vaults/Notes/Claude/System/Knowledge/git-gating-methodology.md

set -uo pipefail

CACHE="${HOME}/.cache/claude"
MODE_FILE="$CACHE/git-gate.mode"
LOG="$CACHE/git-gate.log"

# Read mode (default: enforce)
MODE="enforce"
if [[ -r "$MODE_FILE" ]]; then
    MODE=$(cat "$MODE_FILE" 2>/dev/null | tr -d '[:space:]' || echo "enforce")
fi

# Fail-CLOSED on missing jq (inverted from vault-mcp-redirect)
if ! command -v jq >/dev/null 2>&1; then
    if [[ "$MODE" == "observe" ]]; then
        mkdir -p "$CACHE" 2>/dev/null
        echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] [observe] git-gate degraded: jq missing" >> "$LOG" 2>/dev/null
        exit 0
    fi
    {
        echo "git-gate hook requires jq."
        echo "Install: brew install jq"
        echo ""
        echo "Read-only git operations are unaffected; mutating verbs are blocked until jq is installed."
    } >&2
    exit 2
fi

INPUT=$(cat)
CMD=$(jq -r '.tool_input.command // empty' <<<"$INPUT" 2>/dev/null || true)
SESSION_ID=$(jq -r '.session_id // empty' <<<"$INPUT" 2>/dev/null || true)

# No command or no session — nothing to gate
[[ -z "$CMD" || -z "$SESSION_ID" ]] && exit 0

# Mutating verb detection. Whole-command scan; case-sensitive (git is lowercase).
# Boundary: leading [^a-zA-Z0-9_] treats `/` as a boundary character so that
# absolute paths (/usr/bin/git, /opt/homebrew/bin/git) match correctly.
MUTATING_RE='(^|[^a-zA-Z0-9_])(git[[:space:]]+(push|commit|tag|reset[[:space:]]+--hard|push[[:space:]]+(--force|--mirror|--all))|gh[[:space:]]+(api|repo[[:space:]]+sync|pr[[:space:]]+merge|release[[:space:]]+create))'
HARDENED_RE='(--no-verify|core\.hooksPath=|GIT_[A-Z_]+=)'
CURL_API_RE='curl[^|;&]*((api|uploads)\.github\.com)'
INLINE_PAYLOAD_RE='(bash|sh|zsh)[[:space:]]+-c[[:space:]]+["'"'"'].*(git[[:space:]]+(push|commit|tag|reset[[:space:]]+--hard))'

GATED=0
if [[ "$CMD" =~ $MUTATING_RE ]] || [[ "$CMD" =~ $HARDENED_RE ]] || [[ "$CMD" =~ $CURL_API_RE ]] || [[ "$CMD" =~ $INLINE_PAYLOAD_RE ]]; then
    GATED=1
fi

# Not gated — pass through silently
[[ $GATED -eq 0 ]] && exit 0

MARKER="$CACHE/git-authorized-$SESSION_ID"

# Sentinel present — consume and authorize
if [[ -f "$MARKER" ]]; then
    rm -f "$MARKER" 2>/dev/null
    if [[ "$MODE" == "observe" ]]; then
        echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] [observe] authorized: $CMD" >> "$LOG" 2>/dev/null
    fi
    exit 0
fi

# Observe mode — log would-block and pass through
if [[ "$MODE" == "observe" ]]; then
    mkdir -p "$CACHE" 2>/dev/null
    echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] [observe] would-block: $CMD" >> "$LOG" 2>/dev/null || {
        echo "git-gate observe log unwritable; failing closed" >&2
        exit 2
    }
    exit 0
fi

# Enforce mode — block with redirect message
# Increment deny counter (file-backed; per-session)
COUNT_FILE="$CACHE/git-gate-deny-count-$SESSION_ID"
COUNT=$(cat "$COUNT_FILE" 2>/dev/null || echo 0)
COUNT=$((COUNT + 1))
echo "$COUNT" > "$COUNT_FILE" 2>/dev/null || true

{
    echo "Direct git mutation blocked: $CMD"
    echo ""
    echo "Use /github-push (the gated commit-and-push flow)."
    echo "For MBP sync, /update-mbp delegates to /github-push for commit+push."
    echo ""
    echo "If you are /github-push and seeing this: re-touch the sentinel marker"
    echo "in a separate Bash call before each gated git op:"
    echo "  Bash 1: touch \"\$HOME/.cache/claude/git-authorized-\$CLAUDE_SESSION_ID\""
    echo "  Bash 2: <git mutating command>"
    echo ""
    echo "Spec: ~/Vaults/Notes/Claude/System/Knowledge/github-skills-implementation.md"
} >&2
exit 2
