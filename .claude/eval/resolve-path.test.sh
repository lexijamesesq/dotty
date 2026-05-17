#!/usr/bin/env bash
# Test suite for ~/bin/dotty/.claude/lib/resolve-path.sh
# Background: <TEAM>-N — github-prep/github-push were relying on $ARGUMENTS as a
# shell variable, which the Skill tool does not populate. The fix extracts path
# resolution to this script; the agent passes the user's arg explicitly.

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/assert.sh"

RESOLVER="$HOME/bin/dotty/.claude/lib/resolve-path.sh"

section "resolver exists and is executable"
[[ -x "$RESOLVER" ]] && pass "resolve-path.sh is executable" || fail "resolve-path.sh missing or not executable"

section "empty argument falls back to PWD"
expected="$(cd /tmp && pwd -P)"
actual="$(cd /tmp && "$RESOLVER" "")"
assert_eq "empty arg from /tmp resolves to /tmp" "$expected" "$actual"

section "no argument at all falls back to PWD"
actual="$(cd /tmp && "$RESOLVER")"
assert_eq "no arg from /tmp resolves to /tmp" "$expected" "$actual"

section "tilde expansion"
expected="$(realpath "$HOME")"
actual="$("$RESOLVER" "~")"
assert_eq "~ resolves to \$HOME" "$expected" "$actual"

expected="$(realpath "$HOME/bin")"
actual="$("$RESOLVER" "~/bin")"
assert_eq "~/bin resolves to \$HOME/bin" "$expected" "$actual"

section "absolute path passes through"
expected="$(realpath /tmp)"
actual="$("$RESOLVER" "/tmp")"
assert_eq "/tmp resolves to canonical /tmp" "$expected" "$actual"

section "relative path resolves against PWD"
expected="$(realpath /tmp)"
actual="$(cd / && "$RESOLVER" "tmp")"
assert_eq "relative 'tmp' from / resolves to /tmp" "$expected" "$actual"

actual="$(cd /tmp && "$RESOLVER" ".")"
assert_eq "'.' from /tmp resolves to /tmp" "$expected" "$actual"

section "nonexistent path exits non-zero"
assert_exit "nonexistent absolute path exits 1" 1 "$RESOLVER" "/this/path/should/not/exist/lex112"
assert_exit "nonexistent tilde path exits 1" 1 "$RESOLVER" "~/does/not/exist/lex112"

section "error message goes to stderr, not stdout"
stdout="$("$RESOLVER" "/nope/lex112" 2>/dev/null)" || true
assert_eq "stdout is empty on failure" "" "$stdout"
stderr="$("$RESOLVER" "/nope/lex112" 2>&1 >/dev/null)" || true
case "$stderr" in
  "Path not found:"*) pass "stderr contains 'Path not found:' prefix" ;;
  *) fail "stderr missing expected prefix" "got: $stderr" ;;
esac

section "output is single-line (no trailing chatter)"
out="$("$RESOLVER" "/tmp")"
line_count="$(printf '%s' "$out" | wc -l | tr -d ' ')"
assert_eq "single-line output (0 newlines via printf)" "0" "$line_count"

section "sentinel file fallback (orchestrator-invocation contract)"
TMPSENT="$(mktemp -t resolvepath.XXXXXX)"
echo "/tmp" > "$TMPSENT"
expected="$(realpath /tmp)"
actual="$("$RESOLVER" "" "$TMPSENT")"
assert_eq "empty arg + sentinel resolves to sentinel content" "$expected" "$actual"
[[ -f "$TMPSENT" ]] && pass "sentinel file preserved after read (<TEAM>-N — no auto-delete)" || fail "sentinel file should be preserved, not deleted"
rm -f "$TMPSENT"

section "sentinel preserved on consecutive reads (<TEAM>-N chained-call fix)"
TMPSENT="$(mktemp -t resolvepath.XXXXXX)"
echo "/tmp" > "$TMPSENT"
expected="$(realpath /tmp)"
first="$("$RESOLVER" "" "$TMPSENT")"
second="$("$RESOLVER" "" "$TMPSENT")"
assert_eq "first read resolves correctly" "$expected" "$first"
assert_eq "second read resolves correctly (no silent fallback)" "$expected" "$second"
rm -f "$TMPSENT"

section "explicit arg overrides sentinel; sentinel preserved"
TMPSENT="$(mktemp -t resolvepath.XXXXXX)"
echo "/tmp" > "$TMPSENT"
expected="$(realpath /Users)"
actual="$("$RESOLVER" "/Users" "$TMPSENT")"
assert_eq "non-empty arg wins over sentinel" "$expected" "$actual"
[[ -f "$TMPSENT" ]] && pass "sentinel file preserved when not consumed" || fail "sentinel file unexpectedly deleted"
rm -f "$TMPSENT"

section "sentinel arg pointing at non-existent file is harmless"
expected="$(realpath /tmp)"
actual="$(cd /tmp && "$RESOLVER" "" "/nonexistent/sentinel/lex112")"
assert_eq "missing sentinel falls through to PWD" "$expected" "$actual"

section "sentinel with trailing whitespace/CR is trimmed (bare-path backward compat)"
TMPSENT="$(mktemp -t resolvepath.XXXXXX)"
printf '/tmp\r\n' > "$TMPSENT"
expected="$(realpath /tmp)"
actual="$("$RESOLVER" "" "$TMPSENT")"
assert_eq "sentinel with CRLF is read cleanly" "$expected" "$actual"
rm -f "$TMPSENT"

section "JSON-format sentinel with fresh created_at (<TEAM>-N)"
TMPSENT="$(mktemp -t resolvepath.XXXXXX)"
NOW_ISO="$(date -u "+%Y-%m-%dT%H:%M:%SZ")"
printf '{"path":"/tmp","created_at":"%s"}\n' "$NOW_ISO" > "$TMPSENT"
expected="$(realpath /tmp)"
actual="$("$RESOLVER" "" "$TMPSENT")"
assert_eq "JSON sentinel with fresh timestamp resolves" "$expected" "$actual"
[[ -f "$TMPSENT" ]] && pass "JSON sentinel preserved after read" || fail "JSON sentinel should be preserved"
rm -f "$TMPSENT"

section "JSON-format sentinel with stale created_at (>5 min) falls through (<TEAM>-N)"
TMPSENT="$(mktemp -t resolvepath.XXXXXX)"
# 10 minutes ago in ISO 8601 (BSD date)
STALE_ISO="$(date -u -v -10M "+%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || date -u -d '10 minutes ago' "+%Y-%m-%dT%H:%M:%SZ")"
printf '{"path":"/Users","created_at":"%s"}\n' "$STALE_ISO" > "$TMPSENT"
expected="$(cd /tmp && pwd -P)"
actual="$(cd /tmp && "$RESOLVER" "" "$TMPSENT")"
assert_eq "stale JSON sentinel falls through to PWD" "$expected" "$actual"
[[ -f "$TMPSENT" ]] && pass "stale sentinel file preserved (not auto-deleted; operator must rm)" || fail "stale sentinel file should be preserved"
rm -f "$TMPSENT"

section "JSON sentinel missing created_at treated as fresh"
TMPSENT="$(mktemp -t resolvepath.XXXXXX)"
printf '{"path":"/tmp"}\n' > "$TMPSENT"
expected="$(realpath /tmp)"
actual="$("$RESOLVER" "" "$TMPSENT")"
assert_eq "JSON sentinel without created_at resolves (treated as fresh)" "$expected" "$actual"
rm -f "$TMPSENT"

finish
