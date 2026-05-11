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
# Spec: ~/Vaults/Notes/System/Knowledge/github-skills-implementation.md
# Methodology: ~/Vaults/Notes/System/Knowledge/git-gating-methodology.md

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

# Token-based mutating verb detection.
#
# Splits the command on shell separators (;, &&, ||, |, newline) into tokens,
# strips leading env-var assignments / sudo / exec / nice / time per token, then
# checks the leading executable of each token. This avoids false positives on
# quoted-string mentions of git inside echo/grep/printf/etc.
#
# Returns 0 (gated) on first match; 1 (not gated) if no token matches.
is_command_gated() {
    local cmd="$1"

    # Inline-payload detection runs first because the OUTER token is bash/sh/zsh/eval
    # whose ARGUMENT contains the mutating verb. Token-based scan below would miss it.
    if [[ "$cmd" =~ (bash|sh|zsh)[[:space:]]+-c[[:space:]]+[\"\'].*git[[:space:]]+(push|commit|tag|reset[[:space:]]+--hard) ]]; then
        return 0
    fi
    if [[ "$cmd" =~ eval[[:space:]]+[\"\'].*git[[:space:]]+(push|commit|tag|reset[[:space:]]+--hard) ]]; then
        return 0
    fi

    # curl-to-GitHub-API match (any position, since curl can be hidden in pipelines)
    if [[ "$cmd" =~ curl[^\|\;\&]*((api|uploads)\.github\.com) ]]; then
        return 0
    fi

    # Split on shell separators. We use awk to convert separators to newlines
    # because pure bash splitting on multi-char tokens (&&, ||) is messy.
    local tokens
    tokens=$(printf '%s' "$cmd" | awk '
        BEGIN { RS=""; ORS="" }
        {
            gsub(/&&|\|\|/, "\n", $0)
            gsub(/[;|]/, "\n", $0)
            print $0
        }')

    while IFS= read -r token; do
        # Strip leading whitespace
        token="${token#"${token%%[![:space:]]*}"}"
        [[ -z "$token" ]] && continue

        # Strip leading env-var assignments (FOO=bar BAZ=qux ...) and sudo/env/exec/nice/time prefixes
        while true; do
            if [[ "$token" =~ ^[A-Za-z_][A-Za-z_0-9]*=[^[:space:]]*[[:space:]]+ ]]; then
                token="${token#${BASH_REMATCH[0]}}"
            elif [[ "$token" =~ ^(sudo|env|exec|nice|time|nohup|stdbuf)[[:space:]]+ ]]; then
                token="${token#${BASH_REMATCH[0]}}"
            else
                break
            fi
        done

        # Now check the leading executable.
        # Bare `git <mutating-verb>`
        if [[ "$token" =~ ^git[[:space:]]+(push|commit|tag|reset[[:space:]]+--hard|push[[:space:]]+(--force|--mirror|--all))($|[[:space:]]) ]]; then
            return 0
        fi
        # Bare `gh <mutating-verb>`
        if [[ "$token" =~ ^gh[[:space:]]+(api|repo[[:space:]]+sync|pr[[:space:]]+merge|release[[:space:]]+create)($|[[:space:]]) ]]; then
            return 0
        fi
        # Absolute-path git/gh (e.g. /usr/bin/git push, /opt/homebrew/bin/gh api)
        if [[ "$token" =~ ^/[^[:space:]\"\']+/git[[:space:]]+(push|commit|tag|reset[[:space:]]+--hard|push[[:space:]]+(--force|--mirror|--all))($|[[:space:]]) ]]; then
            return 0
        fi
        if [[ "$token" =~ ^/[^[:space:]\"\']+/gh[[:space:]]+(api|repo[[:space:]]+sync|pr[[:space:]]+merge|release[[:space:]]+create)($|[[:space:]]) ]]; then
            return 0
        fi
        # Hardened patterns (--no-verify, core.hooksPath=) only when the token's leading
        # executable is git or gh, regardless of subcommand. Catches `git -c core.hooksPath=...`
        # which wouldn't match the verb regex above (subcommand is preceded by -c flag).
        if [[ "$token" =~ ^(git|/[^[:space:]\"\']+/git|gh|/[^[:space:]\"\']+/gh)[[:space:]] ]]; then
            if [[ "$token" =~ (--no-verify|core\.hooksPath=) ]]; then
                return 0
            fi
        fi
    done <<<"$tokens"

    return 1
}

GATED=0
if is_command_gated "$CMD"; then
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
    echo "Spec: see /github-push skill documentation"
} >&2
exit 2
