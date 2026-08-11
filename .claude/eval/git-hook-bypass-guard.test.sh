#!/usr/bin/env bash
# Test suite for ~/bin/dotty/.claude/hooks/git-hook-bypass-guard.sh
#
# The hook is a PreToolUse (Bash) guard that denies commands bypassing git's
# commit/push hook chain. Tests drive it with crafted stdin JSON and assert on
# exit code: 2 = blocked (deny), 0 = allowed / no-opinion (fail-open).
#
# Covers:
#   - The four bypass vectors (--no-verify, -n incl. bundled clusters, SKIP=,
#     core.hooksPath)
#   - Regression: shell-operator-abutted -n (git commit -n;echo / -n&&.. / -n|..)
#   - Negatives: long flags and legit short combos must pass
#   - Regression: the honesty-note "porous" examples must actually pass, and
#     the env -i prefix must NOT create a bypass
#   - Fail-open posture on infra errors (jq absent, empty/garbage stdin,
#     non-Bash tool)
#   - Documented accepted over-blocks (safe direction)
#
# Run: bash ~/bin/dotty/.claude/eval/git-hook-bypass-guard.test.sh

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/assert.sh"

HOOK="${HOOK:-${SCRIPT_DIR}/../hooks/git-hook-bypass-guard.sh}"
[[ -x "$HOOK" ]] || { echo "FATAL: $HOOK not executable"; exit 2; }

command -v jq >/dev/null 2>&1 || { echo "FATAL: jq required to build test fixtures"; exit 2; }

# mkjson <command-string> -> PreToolUse stdin JSON for the Bash tool
mkjson() { jq -n --arg c "$1" '{tool_name:"Bash",tool_input:{command:$c}}'; }

# fire <json> -> hook exit code (in RC)
fire() { printf '%s' "$1" | bash "$HOOK" >/dev/null 2>&1; RC=$?; }

expect_block() { fire "$(mkjson "$1")"; assert_eq "BLOCK: $1" "2" "$RC"; }
expect_allow() { fire "$(mkjson "$1")"; assert_eq "allow: $1" "0" "$RC"; }

# === Vector 1: commit --no-verify / -n (incl. bundled clusters) ===
section "Vector 1 — commit hook bypass"
expect_block 'git commit --no-verify -m "x"'
expect_block 'git commit -n -m "x"'
expect_block 'git commit -m "x" -n'
expect_block 'git commit "-n" -m "x"'
expect_block 'git commit -an -m "x"'
expect_block 'git commit -nm "x"'
expect_block 'git commit -vn -m "x"'
expect_block 'GIT COMMIT --NO-VERIFY'          # case-insensitive match

# === Regression: shell operator abutting -n (Defect 1) ===
section "Vector 1 regression — -n abutting a shell operator"
expect_block 'git commit -n; echo'
expect_block 'git commit -n;echo'
expect_block 'git commit -n && git push'
expect_block 'git commit -n&&git push'
expect_block 'git commit -n | cat'
expect_block 'git commit -n|cat'
expect_block 'git commit -an;echo'

# === Whitespace normalization ===
section "Vector 1 — whitespace normalization"
expect_block 'git   commit   -n -m "x"'
printf -v tabcmd 'git\tcommit\t-n -m "x"'
expect_block "$tabcmd"

# === Vector 2: push --no-verify (push -n is --dry-run, not a bypass) ===
section "Vector 2 — push hook bypass"
expect_block 'git push --no-verify origin main'
expect_allow 'git push -n origin main'
expect_allow 'git push -vn origin main'
expect_allow 'git push -an origin main'

# === Vector 3: SKIP= on commit/push ===
section "Vector 3 — pre-commit SKIP var"
expect_block 'SKIP=gitleaks git commit -m "x"'
expect_block 'SKIP=gitleaks git push origin main'
expect_allow 'SKIP=gitleaks make build'        # SKIP= without git commit/push

# === Vector 4: core.hooksPath override ===
section "Vector 4 — hooksPath override"
expect_block 'git -c core.hooksPath=/dev/null commit -m "x"'
expect_block 'git config core.hooksPath /dev/null'

# === Negatives — legit commands must pass ===
section "Negatives — must NOT block"
expect_allow 'git commit --no-edit -m "x"'
expect_allow 'git commit --no-gpg-sign -m "x"'
expect_allow 'git commit --amend --no-edit'
expect_allow 'git commit -am "x"'
expect_allow 'git commit -m "x"'
expect_allow 'grep -n foo file.txt'
expect_allow 'git status && git log'
expect_allow 'PRE_COMMIT_ALLOW_NO_CONFIG=1 git commit -m "x"'
expect_allow "git commit -m 'fix; done'"

# === Honesty-note claims (Defect 2) ===
section "Honesty note — porous examples pass, env -i does NOT bypass"
expect_block 'env -i git commit --no-verify'   # NOT porous — still blocked
# shellcheck disable=SC2016  # literal $c is the point — guard sees it unexpanded
expect_allow 'c=commit; git $c --no-verify'    # variable-assembled: porous
# shellcheck disable=SC2016  # literal $cmd is the point — guard sees it unexpanded
expect_allow 'eval "$cmd"'                     # eval indirection: porous
expect_allow 'gc'                              # alias/function name: porous

# === Accepted over-blocks (documented, safe direction) ===
section "Accepted over-blocks (safe direction)"
expect_block 'git commit -m "use -n for dry run"'   # -n inside message
expect_block 'git commit -m x && echo -n done'      # unrelated -n in compound

# === Fail-open posture on infra errors ===
section "Fail-open — infra errors never block"
# jq absent: run with a PATH that has bash but no jq (portable temp dir).
# The fixture is built BEFORE the PATH strip — inline, mkjson itself would
# run jq-less and emit empty stdin, making this branch indistinguishable
# from the empty-stdin test below.
NOJQ=$(mktemp -d -t ghbg-nojq.XXXXXX)
ln -s "$(command -v bash)" "$NOJQ/bash" 2>/dev/null
NOJQ_FIXTURE=$(mkjson 'git commit --no-verify')
PATH="$NOJQ" bash "$HOOK" <<<"$NOJQ_FIXTURE" >/dev/null 2>&1
assert_eq "jq absent -> exit 0 (fail-open)" "0" "$?"
rm -rf "$NOJQ"

printf 'not-json-at-all {{{' | bash "$HOOK" >/dev/null 2>&1
assert_eq "garbage stdin -> exit 0" "0" "$?"

printf '' | bash "$HOOK" >/dev/null 2>&1
assert_eq "empty stdin -> exit 0" "0" "$?"

printf '%s' '{"tool_name":"Read","tool_input":{"file_path":"/tmp/x"}}' | bash "$HOOK" >/dev/null 2>&1
assert_eq "non-Bash tool -> exit 0" "0" "$?"

finish
