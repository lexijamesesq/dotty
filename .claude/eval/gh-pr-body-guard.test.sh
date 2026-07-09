#!/usr/bin/env bash
# Test suite for the fail-closed PR-body/title guard:
#   .claude/hooks/gh-pr-body-guard.sh   (PreToolUse guard for `gh pr create`)
#
# Self-contained: builds a throwaway git repo with a SYNTHETIC .gitleaks.toml ->
# operator-rules chain (title + [extend] useDefault only — NEVER the real private
# ruleset, and NEVER a real PII pattern in this public repo). Drives the hook by
# feeding it PreToolUse JSON on stdin — it never runs `gh` for real. Runs
# identically locally and in CI (CI installs gitleaks; see .github/workflows/test.yml).
#
# Canaries are randomly generated AKIA + 16 chars of [A-Z2-7] — NEVER ending in
# EXAMPLE (gitleaks' aws-access-token rule allowlists '.+EXAMPLE$', which would
# yield a false "clean"). No operator PII appears anywhere in this suite.
#
# Run: bash ~/bin/dotty/.claude/eval/gh-pr-body-guard.test.sh

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/assert.sh"

HOOK="${HOOK:-${SCRIPT_DIR}/../hooks/gh-pr-body-guard.sh}"
COMMON="${SCRIPT_DIR}/../../git-hooks/gitleaks-common.sh"

for f in "$HOOK" "$COMMON"; do
    [[ -f "$f" ]] || { echo "FATAL: missing $f"; exit 2; }
done
# gitleaks is REQUIRED. A missing binary is a hard failure of this suite, never a
# silent skip. CI installs it before invoking run-all.sh.
command -v gitleaks >/dev/null 2>&1 || { echo "FATAL: gitleaks not on PATH — suite cannot run. Install gitleaks 8.30.1."; exit 2; }
command -v jq >/dev/null 2>&1 || { echo "FATAL: jq not on PATH — suite cannot run."; exit 2; }

rand_akia() { echo "AKIA$(LC_ALL=C tr -dc 'A-Z2-7' </dev/urandom | head -c 16)"; }
CANARY="$(rand_akia)"

# --- Fixture -------------------------------------------------------------------
TMP="$(mktemp -d -t gh-pr-guard-test.XXXXXX)"
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT INT TERM

REPO="$TMP/repo"          # publish-provisioned repo (synthetic config chain)
NOREPO="$TMP/norepo"      # not a git repo at all
BARE="$TMP/plainrepo"     # git repo WITHOUT a .gitleaks.toml
mkdir -p "$NOREPO"

init_repo() { # <path>
    git init -q "$1"
    git -C "$1" config user.email "test@example.com"
    git -C "$1" config user.name "Test Runner"
    git -C "$1" config commit.gpgsign false
}
init_repo "$REPO"
init_repo "$BARE"

cat > "$REPO/.gitleaks.toml" <<'EOF'
title = "fixture"
[extend]
path = ".gitleaks-operator-rules.toml"
EOF
write_operator_rules() {
cat > "$REPO/.gitleaks-operator-rules.toml" <<'EOF'
title = "fixture operator rules"
[extend]
useDefault = true
EOF
}
write_operator_rules

# Body-file fixtures.
GOOD_BODY="$TMP/good-body.md"
BAD_BODY="$TMP/bad-body.md"
printf 'PR body line one.\nEntirely clean content here. Closes ACME-123\n' > "$GOOD_BODY"
printf 'PR body line one.\nleftover credential %s\nfinal line\n' "$CANARY" > "$BAD_BODY"

# --- Runners -------------------------------------------------------------------
ERRFILE="$TMP/stderr.txt"

mkjson() { # <command> <cwd>
    jq -n --arg tn "Bash" --arg cmd "$1" --arg cwd "$2" \
        '{tool_name:$tn, tool_input:{command:$cmd}, cwd:$cwd}'
}
run_hook() { # <json> [pathspec]
    local json="$1" pathspec="${2:-$PATH}"
    printf '%s' "$json" | env PATH="$pathspec" bash "$HOOK" >/dev/null 2>"$ERRFILE"
    RC=$?
}

# Build a PATH bin dir containing every tool the hook uses EXCEPT one (for the
# missing-dependency tests). Platform-independent — no assumptions about /usr/bin.
HOOK_TOOLS=(bash dirname jq git gitleaks python3 mktemp cat grep tr cp rm)
make_bin() { # <exclude-tool> -> prints bindir
    local d t p; d="$(mktemp -d)"
    for t in "${HOOK_TOOLS[@]}"; do
        [[ "$t" == "$1" ]] && continue
        p="$(command -v "$t" 2>/dev/null)" && ln -s "$p" "$d/$t" 2>/dev/null
    done
    printf '%s' "$d"
}

# ============================================================================
# Allow paths.
# ============================================================================
section "clean inline title/body passes (and 'Closes ACME-123' is not a match)"
run_hook "$(mkjson 'gh pr create --title "Fix parser bug" --body "Straightforward fix. Closes ACME-123"' "$REPO")"
assert_eq "clean create exits 0 (allow)" "0" "$RC"

section "non-Bash tool call is ignored (allow)"
run_hook "$(jq -n --arg cwd "$REPO" '{tool_name:"Read", tool_input:{file_path:"/x"}, cwd:$cwd}')"
assert_eq "non-Bash tool exits 0 (not our concern)" "0" "$RC"

section "self-scope: a non-PR Bash command is out of scope (allow, even with a canary)"
run_hook "$(mkjson "echo $CANARY" "$REPO")"
assert_eq "non-PR command exits 0 (self-scope skip, not scanned)" "0" "$RC"

section "self-scope: 'gh pr edit' is in scope — a canary in its --body blocks"
run_hook "$(mkjson "gh pr edit 42 --body \"leak $CANARY\"" "$REPO")"
assert_eq "gh pr edit canary exits 2 (block)" "2" "$RC"
grep -q "aws-access-token" "$ERRFILE" && pass "gh pr edit scan reports the rule id" || fail "gh pr edit scan reports the rule id" "$(cat "$ERRFILE")"

# --- self-scope: shell quoting must not evade the scope match (canary in body) --
section "self-scope: quoted subcommand 'gh pr \"create\"' is in scope — canary blocks"
run_hook "$(mkjson "gh pr \"create\" --body \"leak $CANARY\"" "$REPO")"
assert_eq "quoted-create canary exits 2 (block)" "2" "$RC"
grep -q "aws-access-token" "$ERRFILE" && pass "quoted-create scan reports the rule id" || fail "quoted-create scan reports the rule id" "$(cat "$ERRFILE")"

section "self-scope: quoted subcommand 'gh pr '\''edit'\''' is in scope — canary blocks"
run_hook "$(mkjson "gh pr 'edit' 12 --body \"leak $CANARY\"" "$REPO")"
assert_eq "quoted-edit canary exits 2 (block)" "2" "$RC"

section "self-scope: every word quoted (\"gh\" \"pr\" \"create\") is in scope — canary blocks"
run_hook "$(mkjson "\"gh\" \"pr\" \"create\" --body \"leak $CANARY\"" "$REPO")"
assert_eq "all-quoted canary exits 2 (block)" "2" "$RC"

section "self-scope: command substitution 'out=\$(gh pr create ...)' stays in scope — canary blocks"
run_hook "$(mkjson "out=\$(gh pr create --body \"leak $CANARY\")" "$REPO")"
assert_eq "command-subst canary exits 2 (block)" "2" "$RC"

# --- self-scope: no over-block on commands that merely MENTION the string --------
section "no over-block: 'echo \"gh pr create now ...\"' from a repo without config stays out of scope"
run_hook "$(mkjson "echo \"gh pr create now $CANARY\"" "$BARE")"
assert_eq "mere-mention echo exits 0 (out of scope, not scanned, no over-block)" "0" "$RC"

section "no over-block: 'grep '\''gh pr create'\'' f.txt' stays out of scope"
run_hook "$(mkjson "grep 'gh pr create' f.txt" "$BARE")"
assert_eq "grep mention exits 0 (out of scope)" "0" "$RC"

# --- DISCLOSED porosity: string matching cannot see through variable substitution.
# The command below WOULD create a real PR with a canary in its body, yet exits 0
# unscanned. This asserts the CURRENT (fail-open) behaviour and labels it as the
# porosity the hook header discloses — it is NOT a claim that this case is blocked.
section "DISCLOSED porosity: variable-substituted subcommand evades scope (fail-open, documented)"
run_hook "$(mkjson "c=create; gh pr \$c --body \"leak $CANARY\"" "$REPO")"
assert_eq "var-subst 'gh pr \$c' exits 0 — DISCLOSED string-match porosity (see hook header)" "0" "$RC"

# ============================================================================
# Inline title/body/command blocks (whole-command scan).
# ============================================================================
section "canary in --body is blocked; literal withheld"
run_hook "$(mkjson "gh pr create --title \"Fix\" --body \"leftover cred $CANARY here\"" "$REPO")"
assert_eq "body canary exits 2 (block)" "2" "$RC"
grep -q "aws-access-token" "$ERRFILE" && pass "reports the rule id" || fail "reports the rule id" "$(cat "$ERRFILE")"
grep -q "$CANARY" "$ERRFILE" && fail "matched literal withheld" "CANARY leaked into output!" || pass "matched literal withheld (redacted)"

section "canary in --title is blocked (titles in scope — Linear-sync class)"
run_hook "$(mkjson "gh pr create --title \"$CANARY rollout\" --body \"clean body\"" "$REPO")"
assert_eq "title canary exits 2 (block)" "2" "$RC"
grep -q "aws-access-token" "$ERRFILE" && pass "title scan reports the rule id" || fail "title scan reports the rule id" "none"

section "canary in a multi-line body is blocked (whole-command scan preserves newlines)"
run_hook "$(mkjson "$(printf 'gh pr create --title "x" --body "line1\nsecret %s\nline3"' "$CANARY")" "$REPO")"
assert_eq "multi-line body canary exits 2 (block)" "2" "$RC"
grep -q "aws-access-token" "$ERRFILE" && pass "multi-line scan reports the rule id" || fail "multi-line scan reports the rule id" "none"

section "over-block (honest): a guarded literal ANYWHERE in the command blocks"
run_hook "$(mkjson "gh pr create -R owner/$CANARY --title \"clean\" --body \"clean\"" "$REPO")"
assert_eq "canary in -R value exits 2 (intentional over-block)" "2" "$RC"

# ============================================================================
# --body-file / -F (contents not present in the command string).
# ============================================================================
section "canary in --body-file contents is blocked; literal withheld"
run_hook "$(mkjson "gh pr create --title \"Fix\" --body-file $BAD_BODY" "$REPO")"
assert_eq "body-file canary exits 2 (block)" "2" "$RC"
grep -q "aws-access-token" "$ERRFILE" && pass "body-file scan reports the rule id" || fail "body-file scan reports the rule id" "none"
grep -q "$CANARY" "$ERRFILE" && fail "body-file literal withheld" "CANARY leaked!" || pass "body-file literal withheld"

section "clean --body-file passes"
run_hook "$(mkjson "gh pr create --title \"Fix\" --body-file $GOOD_BODY" "$REPO")"
assert_eq "clean body-file exits 0 (allow)" "0" "$RC"

section "--body-file relative path resolves against cwd, and its canary blocks"
printf 'relative body\nleak %s\n' "$CANARY" > "$REPO/rel-body.md"
run_hook "$(mkjson 'gh pr create --title "x" --body-file rel-body.md' "$REPO")"
assert_eq "relative body-file canary exits 2 (block)" "2" "$RC"
rm -f "$REPO/rel-body.md"

section "--body-file nonexistent path is fail-closed (block)"
run_hook "$(mkjson "gh pr create --title \"Fix\" --body-file $TMP/nope-does-not-exist.md" "$REPO")"
assert_eq "missing body-file exits 2 (block)" "2" "$RC"
grep -qi "body-file" "$ERRFILE" && pass "names the body-file" || fail "names the body-file" "$(cat "$ERRFILE")"
grep -qi "unreadable\|fail-closed" "$ERRFILE" && pass "names the fail-closed reason" || fail "names the fail-closed reason" "none"

section "-F (short form) file contents are scanned; its canary blocks (fail-closed)"
printf 'short-form body\nleak %s\n' "$CANARY" > "$TMP/short-body.md"
run_hook "$(mkjson "gh pr create --title \"x\" -F $TMP/short-body.md" "$REPO")"
assert_eq "-F body-file canary exits 2 (block)" "2" "$RC"

section "-F with a spaced/quoted path is parsed correctly and its canary blocks"
printf 'spaced body\nleak %s\n' "$CANARY" > "$TMP/path with spaces.md"
run_hook "$(mkjson "gh pr create --title \"x\" -F \"$TMP/path with spaces.md\"" "$REPO")"
assert_eq "-F quoted-spaced body-file canary exits 2 (block)" "2" "$RC"
grep -q "aws-access-token" "$ERRFILE" && pass "spaced-path scan reports the rule id" || fail "spaced-path scan reports the rule id" "$(cat "$ERRFILE")"

section "-F nonexistent path is fail-closed (block) — no longer best-effort"
run_hook "$(mkjson "gh pr create --title \"x\" -F $TMP/nope-F-does-not-exist.md" "$REPO")"
assert_eq "-F missing path exits 2 (block)" "2" "$RC"
grep -qi "unreadable\|fail-closed" "$ERRFILE" && pass "names the fail-closed reason" || fail "names the fail-closed reason" "$(cat "$ERRFILE")"

section "-F as the final token with no argument is fail-closed (block)"
run_hook "$(mkjson 'gh pr create --title "x" -F' "$REPO")"
assert_eq "-F no-arg exits 2 (block)" "2" "$RC"
grep -qi "no path argument" "$ERRFILE" && pass "names the missing argument" || fail "names the missing argument" "$(cat "$ERRFILE")"

section "shell-aware tokenizer: a '-F' mentioned inside a quoted body is NOT the flag (allow)"
run_hook "$(mkjson 'gh pr create --title "x" --body "you can use gh -F to pass a file"' "$REPO")"
assert_eq "clean body mentioning -F exits 0 (no spurious block)" "0" "$RC"

# ============================================================================
# Fail-closed: target repo / config resolution.
# ============================================================================
section "cwd not inside a git repo is fail-closed (block, names the fix)"
run_hook "$(mkjson 'gh pr create --title "x" --body "y"' "$NOREPO")"
assert_eq "not-in-repo exits 2 (block)" "2" "$RC"
grep -qi "not inside a git repository" "$ERRFILE" && pass "names the not-in-repo cause" || fail "names the not-in-repo cause" "$(cat "$ERRFILE")"
grep -qi "repo root" "$ERRFILE" && pass "tells the operator to run from the repo root" || fail "tells the operator to run from the repo root" "none"

section "git repo without a .gitleaks.toml is fail-closed (block, names provisioning)"
run_hook "$(mkjson 'gh pr create --title "x" --body "y"' "$BARE")"
assert_eq "no-config repo exits 2 (block)" "2" "$RC"
grep -qi "config not found" "$ERRFILE" && pass "names the missing config" || fail "names the missing config" "$(cat "$ERRFILE")"
grep -q "setup-claude-profiles.sh" "$ERRFILE" && pass "names the provisioning step" || fail "names the provisioning step" "none"

section "unresolvable [extend] target (broken symlink) is fail-closed (block)"
rm -f "$REPO/.gitleaks-operator-rules.toml"
ln -s "/nonexistent/operator-rules.toml" "$REPO/.gitleaks-operator-rules.toml"
run_hook "$(mkjson 'gh pr create --title "x" --body "clean"' "$REPO")"
assert_eq "broken extend exits 2 (block even for a clean body)" "2" "$RC"
grep -qi "unresolvable" "$ERRFILE" && pass "names the unresolvable ruleset" || fail "names the unresolvable ruleset" "$(cat "$ERRFILE")"
grep -q "setup-claude-profiles.sh" "$ERRFILE" && pass "names the provisioning step" || fail "names the provisioning step" "none"
rm -f "$REPO/.gitleaks-operator-rules.toml"; write_operator_rules

# ============================================================================
# Fail-closed: missing dependencies (feed a BAD canary so a fail-open would slip).
# ============================================================================
section "missing gitleaks binary is fail-closed (block, names install)"
run_hook "$(mkjson "gh pr create --body \"$CANARY\"" "$REPO")" "/usr/bin:/bin"
assert_eq "missing gitleaks exits 2 (block)" "2" "$RC"
grep -qi "not installed" "$ERRFILE" && pass "names the missing binary" || fail "names the missing binary" "$(cat "$ERRFILE")"
grep -qi "brew install gitleaks" "$ERRFILE" && pass "gives the install instruction" || fail "gives the install instruction" "none"

section "missing jq is fail-closed (block, names install)"
BIN_NO_JQ="$(make_bin jq)"
run_hook "$(mkjson "gh pr create --body \"$CANARY\"" "$REPO")" "$BIN_NO_JQ"
assert_eq "missing jq exits 2 (block)" "2" "$RC"
grep -qi "jq is not installed" "$ERRFILE" && pass "names the missing jq" || fail "names the missing jq" "$(cat "$ERRFILE")"
grep -qi "brew install jq" "$ERRFILE" && pass "gives the jq install instruction" || fail "gives the jq install instruction" "none"

section "missing python3 is fail-closed (block, names install)"
BIN_NO_PY="$(make_bin python3)"
run_hook "$(mkjson "gh pr create --body-file $BAD_BODY" "$REPO")" "$BIN_NO_PY"
assert_eq "missing python3 exits 2 (block)" "2" "$RC"
grep -qi "python3 is not installed" "$ERRFILE" && pass "names the missing python3" || fail "names the missing python3" "$(cat "$ERRFILE")"
grep -qi "brew install python3" "$ERRFILE" && pass "gives the python3 install instruction" || fail "gives the python3 install instruction" "none"

finish
