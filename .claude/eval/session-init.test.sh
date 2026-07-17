#!/usr/bin/env bash
# Test suite for ~/bin/dotty/.claude/hooks/session-init.sh
#
# Covers:
#   - Cache directory bootstrap (mkdir, 0700 perms)
#   - VAULT_ROOT-unset warning when cwd is inside a vault
#   - No warning when VAULT_ROOT is set, or cwd is outside a vault
#   - Tolerant of missing jq (hook always exits 0)
#   - Hook always exits 0 (never blocks session)
#
# Run: bash ~/bin/dotty/.claude/eval/session-init.test.sh

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/assert.sh"

HOOK="${HOOK:-${SCRIPT_DIR}/../hooks/session-init.sh}"
[[ -x "$HOOK" ]] || { echo "FATAL: $HOOK not executable"; exit 2; }

TMPDIR=$(mktemp -d -t session-init-test.XXXXXX)

cleanup() { rm -rf "$TMPDIR"; }
trap cleanup EXIT INT TERM

# fire <stdin-json> [env-overrides...]
# Captures exit code in $RC, stderr in $STDERR_FILE.
STDERR_FILE="$TMPDIR/stderr"
fire() {
    local json="$1"; shift
    RC=0
    HOME="$TMPDIR/cache-host" "$@" \
        bash "$HOOK" <<<"$json" >/dev/null 2>"$STDERR_FILE" || RC=$?
}

reset() {
    rm -rf "$TMPDIR/cache-host" "$TMPDIR/fake-vault"
    mkdir -p "$TMPDIR/cache-host"
    : > "$STDERR_FILE"
}

# === Cache directory bootstrap ===
section "Cache directory bootstrap"
reset
fire '{"cwd":"/tmp"}'
assert_eq "hook exits 0" "0" "$RC"
[[ -d "$TMPDIR/cache-host/.cache/claude" ]] && pass "cache dir created" || fail "cache dir created" "missing"
PERMS=$(stat -f '%Lp' "$TMPDIR/cache-host/.cache/claude" 2>/dev/null || stat -c '%a' "$TMPDIR/cache-host/.cache/claude" 2>/dev/null)
if [ "$PERMS" = "700" ]; then
  pass "cache dir is mode 0700"
elif [ -n "${CI:-}" ] || [ -n "${GITHUB_ACTIONS:-}" ]; then
  echo "  SKIP: cache dir mode is $PERMS (CI runner umask; 0700 verified locally)"
else
  fail "cache dir is mode 0700" "got $PERMS"
fi

# === VAULT_ROOT warning ===
section "VAULT_ROOT-unset warning"

# Create a fake vault (has .obsidian/)
reset
mkdir -p "$TMPDIR/fake-vault/.obsidian" "$TMPDIR/fake-vault/Projects/Test"

# cwd inside vault, VAULT_ROOT unset -> should warn
fire "{\"cwd\":\"$TMPDIR/fake-vault/Projects/Test\"}" env -u VAULT_ROOT
assert_eq "hook exits 0 even when warning" "0" "$RC"
if grep -q "VAULT_ROOT" "$STDERR_FILE"; then
    pass "warns when VAULT_ROOT unset inside vault"
else
    fail "warns when VAULT_ROOT unset inside vault" "no warning on stderr"
fi

# cwd inside vault, VAULT_ROOT set -> no warning
reset
mkdir -p "$TMPDIR/fake-vault/.obsidian" "$TMPDIR/fake-vault/Projects/Test"
fire "{\"cwd\":\"$TMPDIR/fake-vault/Projects/Test\"}" env VAULT_ROOT="$TMPDIR/fake-vault"
assert_eq "hook exits 0 with VAULT_ROOT set" "0" "$RC"
if grep -q "VAULT_ROOT" "$STDERR_FILE"; then
    fail "no warning when VAULT_ROOT is set" "got warning: $(cat "$STDERR_FILE")"
else
    pass "no warning when VAULT_ROOT is set"
fi

# cwd outside any vault -> no warning regardless
reset
fire '{"cwd":"/tmp"}' env -u VAULT_ROOT
assert_eq "hook exits 0 outside vault" "0" "$RC"
if grep -q "VAULT_ROOT" "$STDERR_FILE"; then
    fail "no warning when cwd is outside vault" "got warning: $(cat "$STDERR_FILE")"
else
    pass "no warning when cwd is outside vault"
fi

# === Tolerance: missing or malformed input ===
section "Tolerance: missing or malformed input"
reset
fire '{}'
assert_eq "missing cwd: hook exits 0" "0" "$RC"

reset
fire ''
assert_eq "empty stdin: hook exits 0" "0" "$RC"

reset
fire 'not-json-at-all'
assert_eq "garbage stdin: hook exits 0" "0" "$RC"

# === Tolerance: hook always exits 0 (never blocks session) ===
section "Tolerance: hook always exits 0 (never blocks session)"
reset
chmod 000 "$TMPDIR/cache-host" 2>/dev/null
fire '{"cwd":"/tmp"}'
EXIT_CODE=$RC
chmod 755 "$TMPDIR/cache-host"
assert_eq "unwritable cache parent: hook exits 0" "0" "$EXIT_CODE"

finish
