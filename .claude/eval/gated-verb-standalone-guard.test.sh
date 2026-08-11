#!/usr/bin/env bash
# Test suite for ~/bin/dotty/.claude/hooks/gated-verb-standalone-guard.sh
#
# The hook is a PreToolUse (Bash) guard that denies gated git verbs
# (git push, gh pr merge, gh pr create) in any shape the estate's
# permissions.ask glob rules cannot match. Tests drive it with crafted
# stdin JSON and assert on exit code: 2 = blocked, 0 = allowed /
# no-opinion (fail-open).
#
# Covers:
#   - Askable shapes allowed: bare verbs, args, git -C <path> push
#   - The receipted bypass: gated verbs mid-chain
#   - Askable start with chain operators (one prompt, two actions)
#   - Prefixed/wrong-case forms outside the ask globs
#   - Regression: the header's accepted-over-block claims must hold as
#     written — a MENTION of a gated verb without an askable start is
#     denied with no chain operator present, and chain characters inside
#     quoted args of an askable start are denied too
#   - Honesty-note porous examples must actually pass
#   - Fail-open posture on infra errors
#
# Run: bash ~/bin/dotty/.claude/eval/gated-verb-standalone-guard.test.sh

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/assert.sh"

HOOK="${HOOK:-${SCRIPT_DIR}/../hooks/gated-verb-standalone-guard.sh}"
[[ -x "$HOOK" ]] || { echo "FATAL: $HOOK not executable"; exit 2; }

command -v jq >/dev/null 2>&1 || { echo "FATAL: jq required to build test fixtures"; exit 2; }

# mkjson <command-string> -> PreToolUse stdin JSON for the Bash tool
mkjson() { jq -n --arg c "$1" '{tool_name:"Bash",tool_input:{command:$c}}'; }

# fire <json> -> hook exit code (in RC)
fire() { printf '%s' "$1" | bash "$HOOK" >/dev/null 2>&1; RC=$?; }

expect_block() { fire "$(mkjson "$1")"; assert_eq "BLOCK: $1" "2" "$RC"; }
expect_allow() { fire "$(mkjson "$1")"; assert_eq "allow: $1" "0" "$RC"; }

# === Askable shapes — must pass ===
section "Askable shapes — the entire command, bare or with args"
expect_allow 'git push'
expect_allow 'git push -u origin my-branch'
expect_allow 'git push origin main --force-with-lease'
expect_allow 'git -C /some/repo push'
expect_allow 'git -C /some/repo push -u origin b'
expect_allow 'gh pr merge'
expect_allow 'gh pr merge 141 --squash --delete-branch'
expect_allow 'gh pr create'
expect_allow 'gh pr create --repo o/r --title x --body y'

# === Whitespace normalization on askable shapes ===
section "Whitespace normalization"
expect_allow 'git   push'
printf -v tabcmd 'git\tpush -u origin b'
expect_allow "$tabcmd"

# === The receipted bypass: gated verb mid-chain ===
section "Mid-chain gated verbs — the receipted failure shape"
expect_block 'cd /repo && git log && git push'
expect_block 'cd /repo && git push'
expect_block 'git add -A; git push'
expect_block 'true || git push'
expect_block 'make build && gh pr merge 7 --squash'
expect_block 'echo hi && gh pr create --title x --body y'

# === Askable start but chained/piped — one prompt would cover two actions ===
section "Askable start with chain operators"
expect_block 'git push 2>&1 | tail -1'
expect_block 'git push && gh pr merge'
expect_block 'git push; ls'
expect_block 'gh pr merge 140 --squash && git log --oneline -1'
expect_block 'git -C /x push && ls'

# === Prefixed / wrong-case forms outside the ask globs ===
section "Prefixed and wrong-case forms"
expect_block 'git -c user.name=x push'
expect_block 'GIT_DIR=/x/.git git push'
expect_block 'VAR=1 git push'
expect_block 'Git Push'
expect_block 'GH PR MERGE 7'

# === Regression: accepted-over-block claims hold as written ===
section "Over-block claims — mention without askable start, no chain needed"
expect_block 'rg "git push" /some/dir'
expect_block 'grep -R "gh pr create" docs/'
expect_block 'echo remember to gh pr merge later'
expect_block 'gh pr comment 5 --body "then run git push"'

section "Over-block claims — chain characters inside quoted args"
expect_block 'gh pr create --body "a && b"'
expect_block 'git push origin "br|anch"'

# === Ungated commands — must pass, chained or not ===
section "Negatives — ungated commands must NOT block"
expect_allow 'ls -la'
expect_allow 'git status && git log'
expect_allow 'cd /repo && git commit -m hi'
expect_allow 'gh pr checks 140 --watch | tail -2'
expect_allow 'gh pr view 12 | cat'
expect_allow 'git log --oneline | head'
expect_allow 'echo pushing code soon'

# === Honesty-note claims — porous examples must actually pass ===
section "Honesty note — shell indirection is porous, as documented"
# shellcheck disable=SC2016  # literal $v is the point — guard sees it unexpanded
expect_allow 'v=push; git $v'
# shellcheck disable=SC2016  # literal $cmd is the point — guard sees it unexpanded
expect_allow 'eval "$cmd"'
expect_allow 'gp'

# === Fail-open posture on infra errors ===
section "Fail-open — infra errors never block"
# The fixture is built BEFORE the PATH strip — inline, mkjson itself would
# run jq-less and emit empty stdin, making this branch indistinguishable
# from the empty-stdin test below.
NOJQ=$(mktemp -d -t gvsg-nojq.XXXXXX)
ln -s "$(command -v bash)" "$NOJQ/bash" 2>/dev/null
NOJQ_FIXTURE=$(mkjson 'cd /repo && git push')
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
