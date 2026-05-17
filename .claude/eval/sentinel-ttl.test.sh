#!/usr/bin/env bash
# sentinel-ttl.test.sh — verify the LEX-144 sentinel TTL behavior in resolve-path.sh
#
# Asserts:
# 1. JSON sentinel with fresh timestamp is used (path resolves to the sentinel value)
# 2. JSON sentinel with stale timestamp (older than 5 min) is treated as absent (PWD fallback)
# 3. Sentinel is NOT auto-deleted on read (file still present after invocation)
# 4. Bare-path sentinel (no JSON) is used for backward compat (no staleness check)
#
# Run from anywhere; uses a tmp sentinel and a tmp PWD to avoid touching real config.

set -euo pipefail

RESOLVER="${RESOLVER:-$HOME/bin/dotty/.claude/lib/resolve-path.sh}"
TMP=$(mktemp -d)
SENTINEL="$TMP/sentinel"
PWD_TARGET="$TMP/pwd-target"

cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

# Create the PWD target so resolve-path doesn't error on "Path not found"
mkdir -p "$PWD_TARGET"
cd "$PWD_TARGET"

pass=0
fail=0

assert_eq() {
  local name="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then
    echo "PASS: $name"
    pass=$((pass + 1))
  else
    echo "FAIL: $name"
    echo "  expected: $expected"
    echo "  actual:   $actual"
    fail=$((fail + 1))
  fi
}

# Test 1: fresh JSON sentinel is used
NOW_UTC=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
TARGET_DIR=$(mktemp -d)
printf '{"path": "%s", "created_at": "%s"}\n' "$TARGET_DIR" "$NOW_UTC" > "$SENTINEL"
RESULT=$("$RESOLVER" "" "$SENTINEL")
EXPECTED=$(realpath "$TARGET_DIR")
assert_eq "fresh JSON sentinel resolves to sentinel path" "$EXPECTED" "$RESULT"

# Test 2: sentinel is NOT auto-deleted on read
if [ -f "$SENTINEL" ]; then
  echo "PASS: sentinel file present after read (not auto-deleted)"
  pass=$((pass + 1))
else
  echo "FAIL: sentinel was auto-deleted on read (LEX-144 regression)"
  fail=$((fail + 1))
fi

# Test 3: stale JSON sentinel is treated as absent → falls back to PWD
OLD_UTC=$(date -u -v-10M +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null \
  || date -u -d '10 minutes ago' +"%Y-%m-%dT%H:%M:%SZ")
printf '{"path": "%s", "created_at": "%s"}\n' "$TARGET_DIR" "$OLD_UTC" > "$SENTINEL"
RESULT=$("$RESOLVER" "" "$SENTINEL")
EXPECTED=$(realpath "$PWD_TARGET")
assert_eq "stale (>5min) JSON sentinel falls back to PWD" "$EXPECTED" "$RESULT"

# Test 4: bare-path sentinel is honored (backward compat) — no staleness check
printf '%s\n' "$TARGET_DIR" > "$SENTINEL"
RESULT=$("$RESOLVER" "" "$SENTINEL")
EXPECTED=$(realpath "$TARGET_DIR")
assert_eq "bare-path sentinel resolves to sentinel path (backward compat)" "$EXPECTED" "$RESULT"

# Test 5: explicit arg overrides sentinel
NOW_UTC=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
OTHER_DIR=$(mktemp -d)
printf '{"path": "%s", "created_at": "%s"}\n' "$TARGET_DIR" "$NOW_UTC" > "$SENTINEL"
RESULT=$("$RESOLVER" "$OTHER_DIR" "$SENTINEL")
EXPECTED=$(realpath "$OTHER_DIR")
assert_eq "explicit arg overrides sentinel" "$EXPECTED" "$RESULT"
rm -rf "$OTHER_DIR"

# Test 6: no arg, no sentinel → PWD fallback
rm -f "$SENTINEL"
RESULT=$("$RESOLVER" "" "$SENTINEL")
EXPECTED=$(realpath "$PWD_TARGET")
assert_eq "no arg, no sentinel → PWD fallback" "$EXPECTED" "$RESULT"

rm -rf "$TARGET_DIR"

echo ""
echo "Total: $((pass + fail)) | Passed: $pass | Failed: $fail"
[ "$fail" -eq 0 ]
