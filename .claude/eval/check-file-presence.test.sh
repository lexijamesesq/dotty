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
# shellcheck disable=SC2317,SC2329 # Invoked by the EXIT/INT/TERM trap below.
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

section "Staged presence uses index state, including deletion and rename"
# Disposable fixture commands cannot inherit the caller's object store.
while IFS= read -r key; do unset "$key"; done < <(git rev-parse --local-env-vars)
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
INDEX_REPO="$TMP/index"
mkdir -p "$INDEX_REPO"
git -C "$INDEX_REPO" init -q
printf 'readme\n' >"$INDEX_REPO/README.md"
printf 'license\n' >"$INDEX_REPO/LICENSE"
printf 'repos: []\n' >"$INDEX_REPO/.pre-commit-config.yaml"
git -C "$INDEX_REPO" add .
git -C "$INDEX_REPO" -c user.name=Fixture -c user.email=fixture@example.invalid commit -qm seed
staged() {
	(cd "$INDEX_REPO" && "$HOOK" --staged README.md LICENSE) >"$TMP/staged-output" 2>&1
	RC=$?
}
git -C "$INDEX_REPO" rm --cached -q README.md
staged
assert_eq "rm --cached fails although working README remains" 1 "$RC"
(cd "$INDEX_REPO" && "$HOOK" --staged ./README.md LICENSE) >"$TMP/staged-output" 2>&1
assert_eq "relative filename spelling cannot hide a staged deletion" 1 "$?"
git -C "$INDEX_REPO" add README.md
staged
assert_eq "restored index file passes" 0 "$RC"
git -C "$INDEX_REPO" mv README.md renamed.md
staged
assert_eq "rename away from required name fails" 1 "$RC"
git -C "$INDEX_REPO" mv renamed.md README.md
staged
assert_eq "rename back restores required name" 0 "$RC"
# A pre-existing missing requirement is irrelevant to an unrelated staged edit.
git -C "$INDEX_REPO" rm --cached -q LICENSE
git -C "$INDEX_REPO" -c user.name=Fixture -c user.email=fixture@example.invalid commit -qm 'fixture missing license'
printf 'unrelated\n' >"$INDEX_REPO/other.txt"
git -C "$INDEX_REPO" add other.txt
staged
assert_eq "unrelated change skips existing missing requirement" 0 "$RC"
printf '# declaration change\nrepos: []\n' >"$INDEX_REPO/.pre-commit-config.yaml"
git -C "$INDEX_REPO" add .pre-commit-config.yaml
staged
assert_eq "declaration-only change validates missing index file" 1 "$RC"
# Exercise native always_run selection: it must not drop a deleted required file.
git -C "$INDEX_REPO" add LICENSE
cat >"$INDEX_REPO/.pre-commit-config.yaml" <<YAML
repos:
- repo: local
  hooks:
  - id: check-file-presence
    name: required files
    entry: $HOOK --staged
    language: script
    args: [README.md, LICENSE]
    pass_filenames: false
    always_run: true
    stages: [pre-commit]
YAML
git -C "$INDEX_REPO" add .pre-commit-config.yaml
(cd "$INDEX_REPO" && PRE_COMMIT_HOME="$TMP/precommit-cache" pre-commit run check-file-presence --all-files) >"$TMP/native-output" 2>&1
assert_eq "native hook passes corrected declaration" 0 "$?"
git -C "$INDEX_REPO" rm --cached -q README.md
(cd "$INDEX_REPO" && PRE_COMMIT_HOME="$TMP/precommit-cache" pre-commit run check-file-presence --all-files) >"$TMP/native-output" 2>&1
assert_eq "native hook still runs for staged deletion" 1 "$?"

finish
