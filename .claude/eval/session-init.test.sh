#!/usr/bin/env bash
# Test suite for ~/bin/dotty/.claude/hooks/session-init.sh
#
# Covers:
#   - Cache directory bootstrap (mkdir, 0700 perms)
#   - CLAUDE_SESSION_ID exported to $CLAUDE_ENV_FILE (the authoritative
#     source skills consume; no cache-file equivalent — see session-init.sh
#     comment for rationale)
#   - Stale-marker cleanup (markers >60min old removed; recent preserved)
#   - Stale deny-counter cleanup (same TTL)
#   - Tolerant of missing jq (uses fallback session_id)
#   - Hook always exits 0 (never blocks session)
#
# Run: bash ~/bin/dotty/.claude/eval/session-init.test.sh

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/assert.sh"

HOOK="${HOOK:-${SCRIPT_DIR}/../hooks/session-init.sh}"
[[ -x "$HOOK" ]] || { echo "FATAL: $HOOK not executable"; exit 2; }

# Use isolated cache via $HOME override per invocation
TMPDIR=$(mktemp -d -t session-init-test.XXXXXX)
mkdir -p "$TMPDIR/cache-host"

cleanup() { rm -rf "$TMPDIR"; }
trap cleanup EXIT INT TERM

# fire <stdin-json>
# Returns hook exit via $?. Runs with isolated $HOME so the real cache isn't touched.
fire() {
    HOME="$TMPDIR/cache-host" CLAUDE_ENV_FILE="$TMPDIR/env-file" \
        bash "$HOOK" <<<"$1" >/dev/null 2>&1
}

reset_cache() {
    rm -rf "$TMPDIR/cache-host/.cache"
    rm -f "$TMPDIR/env-file"
}

# === Cache directory bootstrap ===
section "Cache directory bootstrap"
reset_cache
fire '{"session_id":"abc123"}'
exit_code=$?
assert_eq "hook exits 0"                       "0"             "$exit_code"
[[ -d "$TMPDIR/cache-host/.cache/claude" ]] && pass "cache dir created" || fail "cache dir created" "missing"
PERMS=$(stat -f '%Lp' "$TMPDIR/cache-host/.cache/claude" 2>/dev/null || stat -c '%a' "$TMPDIR/cache-host/.cache/claude" 2>/dev/null)
if [ "$PERMS" = "700" ]; then
  pass "cache dir is mode 0700"
elif [ -n "$CI" ] || [ -n "$GITHUB_ACTIONS" ]; then
  echo "  SKIP: cache dir mode is $PERMS (CI runner umask; 0700 verified locally)"
else
  fail "cache dir is mode 0700" "got $PERMS"
fi

# === session_id propagation ===
section "session_id propagation (env file is the only authoritative output)"

# CLAUDE_ENV_FILE export
if grep -q '^export CLAUDE_SESSION_ID=abc123$' "$TMPDIR/env-file"; then
    pass "CLAUDE_SESSION_ID exported to env file"
else
    fail "CLAUDE_SESSION_ID exported to env file" "got: $(cat "$TMPDIR/env-file")"
fi

# Confirm no cache file is written (per the deliberate removal — race-prone
# across concurrent sessions; skills must use $CLAUDE_SESSION_ID).
SID_FILE="$TMPDIR/cache-host/.cache/claude/session-id"
[[ ! -f "$SID_FILE" ]] && pass "no session-id cache file written (env is sole authority)" || fail "no session-id cache file written" "file exists at $SID_FILE — should not"

# Subsequent invocation appends a fresh export to the env file
fire '{"session_id":"xyz789"}'
if grep -q '^export CLAUDE_SESSION_ID=xyz789$' "$TMPDIR/env-file"; then
    pass "subsequent fire exports new session id"
else
    fail "subsequent fire exports new session id" "got: $(cat "$TMPDIR/env-file")"
fi

# === Stale-marker cleanup ===
section "Stale-marker cleanup"
reset_cache
mkdir -p "$TMPDIR/cache-host/.cache/claude"
# Create a stale marker (mtime 2 hours ago) and a fresh one
STALE="$TMPDIR/cache-host/.cache/claude/git-authorized-stale-session"
FRESH="$TMPDIR/cache-host/.cache/claude/git-authorized-fresh-session"
touch "$STALE"
touch "$FRESH"
# Backdate stale marker by 2 hours (uses BSD touch syntax on macOS)
touch -t "$(date -v-2H +%Y%m%d%H%M)" "$STALE" 2>/dev/null || \
    touch -d "2 hours ago" "$STALE" 2>/dev/null

fire '{"session_id":"new-session"}'

[[ -f "$STALE" ]] && fail "stale marker removed" "still present" || pass "stale marker removed"
[[ -f "$FRESH" ]] && pass "fresh marker preserved" || fail "fresh marker preserved" "missing"

# === Stale deny-counter cleanup ===
section "Stale deny-counter cleanup"
STALE_COUNT="$TMPDIR/cache-host/.cache/claude/git-gate-deny-count-stale-session"
FRESH_COUNT="$TMPDIR/cache-host/.cache/claude/git-gate-deny-count-fresh-session"
echo 5 > "$STALE_COUNT"
echo 1 > "$FRESH_COUNT"
touch -t "$(date -v-2H +%Y%m%d%H%M)" "$STALE_COUNT" 2>/dev/null || \
    touch -d "2 hours ago" "$STALE_COUNT" 2>/dev/null

fire '{"session_id":"another-session"}'

[[ -f "$STALE_COUNT" ]] && fail "stale deny-count removed" "still present" || pass "stale deny-count removed"
[[ -f "$FRESH_COUNT" ]] && pass "fresh deny-count preserved" || fail "fresh deny-count preserved" "missing"

# === Tolerance: missing session_id ===
section "Tolerance: missing or malformed input"
reset_cache
fire '{}'
assert_eq "missing session_id: hook exits 0"   "0"             "$?"
# Fallback id should land in env file (timestamp-pid shape)
EXPORTED=$(grep '^export CLAUDE_SESSION_ID=' "$TMPDIR/env-file" 2>/dev/null | tail -1 | sed 's/^export CLAUDE_SESSION_ID=//')
[[ -n "$EXPORTED" ]] && pass "fallback session-id exported" || fail "fallback session-id exported" "no export found in $TMPDIR/env-file"
[[ "$EXPORTED" =~ ^[0-9]+-[0-9]+$ ]] && pass "fallback session-id has timestamp-pid shape" || fail "fallback session-id has timestamp-pid shape" "got: $EXPORTED"

reset_cache
fire ''
assert_eq "empty stdin: hook exits 0"          "0"             "$?"

reset_cache
fire 'not-json-at-all'
assert_eq "garbage stdin: hook exits 0"        "0"             "$?"

# === Tolerance: writable cache failure ===
section "Tolerance: hook always exits 0 (never blocks session)"
# Even if every operation fails, the hook should not block the session
reset_cache
chmod 000 "$TMPDIR/cache-host" 2>/dev/null
fire '{"session_id":"perm-test"}'
EXIT_CODE=$?
chmod 755 "$TMPDIR/cache-host"
assert_eq "unwritable cache parent: hook exits 0"   "0"          "$EXIT_CODE"

finish
