#!/usr/bin/env bash
# Test suite for ~/bin/dotty/.claude/hooks/git-gate.sh
#
# Covers:
#   - Pattern detection (mutating verbs, hardened flags, inline payloads, curl-API)
#   - False-positive suppression (echo / grep / printf strings; comments)
#   - Sentinel mechanics (consume on match, single-use, replay protection)
#   - Mode handling (enforce vs observe)
#   - Read-only ops pass through silently
#
# Run: bash ~/bin/dotty/.claude/eval/git-gate.test.sh
# Run all suites: bash ~/bin/dotty/.claude/eval/run-all.sh

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/assert.sh"

HOOK="$HOME/bin/dotty/.claude/hooks/git-gate.sh"
TEST_SESSION="git-gate-test-$$"
CACHE="$HOME/.cache/claude"
TEST_MARKER="$CACHE/git-authorized-$TEST_SESSION"
TEST_COUNT="$CACHE/git-gate-deny-count-$TEST_SESSION"

# Setup: ensure the hook exists
[[ -x "$HOOK" ]] || { echo "FATAL: $HOOK not executable"; exit 2; }
mkdir -p "$CACHE" 2>/dev/null

# Save and restore mode file
ORIGINAL_MODE_FILE="$CACHE/git-gate.mode"
ORIGINAL_MODE=""
[[ -f "$ORIGINAL_MODE_FILE" ]] && ORIGINAL_MODE=$(cat "$ORIGINAL_MODE_FILE")

cleanup() {
    rm -f "$TEST_MARKER" "$TEST_COUNT"
    if [[ -n "$ORIGINAL_MODE" ]]; then
        echo "$ORIGINAL_MODE" > "$ORIGINAL_MODE_FILE"
    else
        rm -f "$ORIGINAL_MODE_FILE"
    fi
}
trap cleanup EXIT INT TERM

# Force enforce mode for these tests
rm -f "$ORIGINAL_MODE_FILE"

# fire <command-string>
# Returns the hook's exit code via $?. Stderr suppressed (deny messages
# would otherwise pollute test output).
fire() {
    local cmd="$1"
    local payload
    payload=$(jq -cn --arg c "$cmd" --arg s "$TEST_SESSION" \
        '{"tool_input":{"command":$c},"session_id":$s}')
    rm -f "$TEST_COUNT"
    echo "$payload" | bash "$HOOK" >/dev/null 2>&1
}

# Helper: assert hook exit code on a command
hook_exit() {
    local desc="$1" expected="$2" cmd="$3"
    fire "$cmd"
    local actual=$?
    if [[ "$actual" == "$expected" ]]; then
        pass "$desc"
    else
        fail "$desc" "[$cmd] expected exit $expected, got $actual"
    fi
}

# === Read-only ops pass through ===
section "Read-only ops pass (no sentinel needed)"
hook_exit "git status"           0 'git status'
hook_exit "git status --porcelain" 0 'git status --porcelain'
hook_exit "git diff"             0 'git diff HEAD~1'
hook_exit "git log"              0 'git log --oneline -10'
hook_exit "git show"             0 'git show HEAD'
hook_exit "git branch"           0 'git branch -a'
hook_exit "git rev-parse"        0 'git rev-parse HEAD'
hook_exit "git ls-files"         0 'git ls-files'
hook_exit "git fetch origin"     0 'git fetch origin'
hook_exit "ls (no git verb)"     0 'ls -la'

# === False-positive suppression ===
section "False-positive suppression (quoted/grep/comment)"
hook_exit "echo with git push string"            0 'echo "TODO: git push pending"'
hook_exit "grep for git push pattern"            0 'grep "git push" docs/*.md'
hook_exit "printf with git commit"               0 'printf "git commit ready\n"'
hook_exit "shell comment line"                   0 '# git push later'
hook_exit "echo discussing --no-verify"          0 'echo "do not use --no-verify"'
hook_exit "echo discussing core.hooksPath"       0 'echo "core.hooksPath= override is dangerous"'

# === Direct mutating verbs denied ===
section "Direct mutating verbs denied (no sentinel)"
hook_exit "Bare git push"                        2 'git push origin main'
hook_exit "git commit"                           2 'git commit -m foo'
hook_exit "git tag"                              2 'git tag v1.0.0'
hook_exit "git reset --hard"                     2 'git reset --hard origin/main'
hook_exit "git push --force"                     2 'git push --force origin main'
hook_exit "git push --force-with-lease"          2 'git push --force-with-lease origin main'
hook_exit "git push --mirror"                    2 'git push --mirror origin'
hook_exit "git push --all"                       2 'git push --all origin'

# === Hardened bypass patterns ===
section "Hardened bypass patterns denied"
hook_exit "git commit --no-verify"               2 'git commit --no-verify -m foo'
hook_exit "git -c core.hooksPath=/dev/null"      2 'git -c core.hooksPath=/dev/null commit -m foo'

# === Multi-statement chains ===
section "Multi-statement chains denied"
hook_exit "&& chain"                             2 'git status && git push'
hook_exit "; chain"                              2 'git status; git push'
hook_exit "|| chain"                             2 'true || git push'
hook_exit "Pipe to tee"                          2 'git push | tee log.txt'

# === Background invocation ===
section "Background invocation denied"
hook_exit "& background"                         2 'git push &'

# === Absolute path invocations ===
section "Absolute-path git/gh denied"
hook_exit "/usr/bin/git push"                    2 '/usr/bin/git push origin main'
hook_exit "/opt/homebrew/bin/git push"           2 '/opt/homebrew/bin/git push origin main'
hook_exit "/usr/local/bin/git push"              2 '/usr/local/bin/git push origin main'

# === Env-var and sudo prefixes ===
section "Env-var prefixes and sudo stripped before check"
hook_exit "GIT_DIR=foo git push"                 2 'GIT_DIR=foo git push'
hook_exit "FOO=bar BAZ=qux git push"             2 'FOO=bar BAZ=qux git push'
hook_exit "sudo git push"                        2 'sudo git push'
hook_exit "env git push"                         2 'env git push'

# === Inline payloads ===
section "Inline payloads (bash -c, sh -c, eval) denied"
hook_exit "bash -c with git push"                2 'bash -c "git push origin main"'
hook_exit "sh -c with git commit"                2 'sh -c "git commit -m foo"'
hook_exit "eval with git push"                   2 'eval "git push"'

# === gh and curl-to-API ===
section "gh and curl-to-GitHub-API denied"
hook_exit "gh api ref creation"                  2 'gh api -X POST /repos/foo/bar/git/refs'
hook_exit "gh repo sync"                         2 'gh repo sync owner/fork'
hook_exit "gh pr merge"                          2 'gh pr merge 123 --squash'
hook_exit "gh release create"                    2 'gh release create v1.0.0'
hook_exit "curl POST api.github.com"             2 'curl -X POST https://api.github.com/repos/foo/bar/git/refs'
hook_exit "curl uploads.github.com"              2 'curl https://uploads.github.com/repos/foo/bar/releases/123/assets'

# === Sentinel mechanics ===
section "Sentinel: authorize + single-use consume"
touch "$TEST_MARKER"
hook_exit "Sentinel-authorized git push"         0 'git push origin main'
if [[ -f "$TEST_MARKER" ]]; then
    fail "Sentinel consumed atomically" "marker still present after authorize"
else
    pass "Sentinel consumed atomically"
fi
hook_exit "Replay denied (marker consumed)"      2 'git push origin main'

# === Observe mode ===
section "Observe mode logs but does not block"
echo "observe" > "$ORIGINAL_MODE_FILE"
> "$CACHE/git-gate.log"
hook_exit "Observe: gated op exits 0"            0 'git push origin main'
if grep -q 'would-block: git push origin main' "$CACHE/git-gate.log"; then
    pass "Observe: would-block entry logged"
else
    fail "Observe: would-block entry logged" "log: $(cat "$CACHE/git-gate.log")"
fi
rm -f "$ORIGINAL_MODE_FILE"

finish
