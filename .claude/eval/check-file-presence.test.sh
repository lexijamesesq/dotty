#!/usr/bin/env bash
# Test suite for the exported pre-commit hook:
#   git-hooks/check-file-presence.sh
#
# Takes required file names as argv (the hook's own `args:` in a consumer's
# .pre-commit-config.yaml), so every case here invokes it directly with the
# file names as positional args — no git repo fixture needed, unlike the
# house-scaffold hooks (which read `git ls-files`).
#
# Run: bash ~/bin/dotty/.claude/eval/check-file-presence.test.sh

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/assert.sh"

HOOKS_DIR="${HOOKS_DIR:-${SCRIPT_DIR}/../../git-hooks}"
HOOK="$HOOKS_DIR/check-file-presence.sh"

[[ -f "$HOOK" ]] || {
	echo "FATAL: missing $HOOK"
	exit 2
}

TMP="$(mktemp -d -t check-file-presence-test.XXXXXX)"
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT INT TERM

section "Hook: check-file-presence — single required file (README.md)"

DIR="$TMP/readme-present"
mkdir -p "$DIR"
echo "x" >"$DIR/README.md"
OUT="$(cd "$DIR" && "$HOOK" README.md 2>&1)"
RC=$?
assert_eq "README.md present: exits 0" "0" "$RC"

DIR="$TMP/readme-missing"
mkdir -p "$DIR"
OUT="$(cd "$DIR" && "$HOOK" README.md 2>&1)"
RC=$?
assert_eq "README.md missing: exits 1" "1" "$RC"
printf '%s' "$OUT" | grep -q "BLOCKED: missing required file(s): README.md" &&
	pass "names the missing file" || fail "missing-file message" "$OUT"

section "Hook: check-file-presence — two required files (README.md, LICENSE)"

DIR="$TMP/both-present"
mkdir -p "$DIR"
echo "x" >"$DIR/README.md"
echo "x" >"$DIR/LICENSE"
OUT="$(cd "$DIR" && "$HOOK" README.md LICENSE 2>&1)"
RC=$?
assert_eq "README.md + LICENSE both present: exits 0" "0" "$RC"

DIR="$TMP/one-missing"
mkdir -p "$DIR"
echo "x" >"$DIR/README.md"
OUT="$(cd "$DIR" && "$HOOK" README.md LICENSE 2>&1)"
RC=$?
assert_eq "LICENSE missing (README.md present): exits 1" "1" "$RC"
printf '%s' "$OUT" | grep -q "BLOCKED: missing required file(s): LICENSE" &&
	pass "names only the missing file, not the present one" || fail "partial-miss message" "$OUT"
printf '%s' "$OUT" | grep -q "README.md" &&
	fail "false positive on present file" "$OUT" || pass "does not also name the present file"

DIR="$TMP/both-missing"
mkdir -p "$DIR"
OUT="$(cd "$DIR" && "$HOOK" README.md LICENSE 2>&1)"
RC=$?
assert_eq "both missing: exits 1" "1" "$RC"
printf '%s' "$OUT" | grep -q "README.md" && printf '%s' "$OUT" | grep -q "LICENSE" &&
	pass "names both missing files" || fail "both-missing message" "$OUT"

section "Hook: check-file-presence — no required files given (misconfiguration)"

DIR="$TMP/no-args"
mkdir -p "$DIR"
OUT="$(cd "$DIR" && "$HOOK" 2>&1)"
RC=$?
assert_eq "no args: fails closed, exits 2" "2" "$RC"
printf '%s' "$OUT" | grep -q "no required files given" &&
	pass "names the misconfiguration" || fail "no-args message" "$OUT"

finish
