#!/usr/bin/env bash
# vault-debt-line.sh
#
# SessionStart hook: emits a one-line vault-debt signal into session context
# for vault-rooted sessions.
#   - Counts Wiki/Queue/*.md items with `status: pending` frontmatter
#   - Counts Inbox/*.md items (excluding the "Unprocessed Captures.md" dashboard)
#   - Reports oldest-item age for each side
#   - Escalates the line when pending queue count exceeds the backpressure
#     threshold (15)
#
# The line format is defined canonically in the /queue skill's
# skills/queue/playbooks/status.md — keep the two in lockstep.
#
# Pure file counting: no lint run, no model call. Budget <1s.
# Gated on cwd under $VAULT_ROOT. Silent (exit 0, no output) when:
#   - VAULT_ROOT is unset, or cwd is outside the vault
#   - both counts are zero (passive signal; silence is the success state)
#
# Tolerant: failures here must never block or pollute sessions. Fail-open —
# stderr-warn at most, always exit 0.

set -uo pipefail

# --- Vault gate (same convention as fix-obsidian-claude-sync.sh) ---
VAULT_ROOT="${VAULT_ROOT:-}"
[[ -z "$VAULT_ROOT" ]] && exit 0
VAULT_ROOT="${VAULT_ROOT/#\~/$HOME}"

# Read hook input from stdin (JSON with session context), parse cwd
INPUT=$(cat 2>/dev/null || true)
SESSION_CWD=""
if command -v jq >/dev/null 2>&1 && [[ -n "$INPUT" ]]; then
    SESSION_CWD=$(jq -r '.cwd // empty' <<<"$INPUT" 2>/dev/null || true)
fi
[[ -z "$SESSION_CWD" ]] && exit 0

case "$SESSION_CWD" in
    "$VAULT_ROOT"*) ;;
    *) exit 0 ;;
esac

QUEUE_DIR="$VAULT_ROOT/Wiki/Queue"
INBOX_DIR="$VAULT_ROOT/Inbox"
THRESHOLD=15   # backpressure threshold, per the queue design default
NOW=$(date +%s 2>/dev/null || echo 0)

# YYYY-MM-DD -> epoch seconds; BSD date first, GNU fallback; empty on failure
epoch_of() {
    date -j -f "%Y-%m-%d" "$1" +%s 2>/dev/null \
        || date -d "$1" +%s 2>/dev/null \
        || true
}

# --- Queue: pending count + oldest age from `created` frontmatter ---
QUEUE_COUNT=0
QUEUE_OLDEST=0
if [[ -d "$QUEUE_DIR" ]]; then
    while IFS= read -r f; do
        [[ -z "$f" ]] && continue
        [[ "$(basename "$f")" == "Queue Dashboard.md" ]] && continue
        QUEUE_COUNT=$((QUEUE_COUNT + 1))
        created=$(grep -m1 '^created:' "$f" 2>/dev/null \
            | sed -E "s/^created:[[:space:]]*['\"]?([0-9]{4}-[0-9]{2}-[0-9]{2})['\"]?.*/\1/" || true)
        if [[ "$created" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
            cs=$(epoch_of "$created")
            if [[ -n "$cs" && "$NOW" -gt 0 ]]; then
                age=$(( (NOW - cs) / 86400 ))
                (( age > QUEUE_OLDEST )) && QUEUE_OLDEST=$age
            fi
        fi
    done < <(grep -l '^status: pending' "$QUEUE_DIR"/*.md 2>/dev/null || true)
fi

# --- Inbox: .md count (minus dashboard) + oldest age by file mtime ---
INBOX_COUNT=0
INBOX_OLDEST=0
if [[ -d "$INBOX_DIR" ]]; then
    while IFS= read -r f; do
        [[ -z "$f" ]] && continue
        [[ "$(basename "$f")" == "Unprocessed Captures.md" ]] && continue
        INBOX_COUNT=$((INBOX_COUNT + 1))
        mt=$(stat -f %m "$f" 2>/dev/null || stat -c %Y "$f" 2>/dev/null || true)
        if [[ -n "$mt" && "$NOW" -gt 0 ]]; then
            age=$(( (NOW - mt) / 86400 ))
            (( age > INBOX_OLDEST )) && INBOX_OLDEST=$age
        fi
    done < <(find "$INBOX_DIR" -maxdepth 1 -name '*.md' 2>/dev/null || true)
fi

# --- Emit (format: skills/queue/playbooks/status.md) ---
(( QUEUE_COUNT == 0 && INBOX_COUNT == 0 )) && exit 0

if (( QUEUE_COUNT > 0 )); then
    QUEUE_SEG="Queue ${QUEUE_COUNT} pending (oldest ${QUEUE_OLDEST}d)"
else
    QUEUE_SEG="Queue 0 pending"
fi
if (( INBOX_COUNT > 0 )); then
    INBOX_SEG="Inbox ${INBOX_COUNT} items (oldest ${INBOX_OLDEST}d)"
else
    INBOX_SEG="Inbox 0 items"
fi

LINE="Vault debt: ${QUEUE_SEG} | ${INBOX_SEG}"
if (( QUEUE_COUNT > THRESHOLD )); then
    LINE="[QUEUE BACKPRESSURE] ${LINE} — drain overdue"
fi

echo "$LINE"
exit 0
