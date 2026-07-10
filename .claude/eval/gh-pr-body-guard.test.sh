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

# Synthetic operator ruleset for the GITLEAKS_OPERATOR_RULES path (NEVER the real
# private ruleset). useDefault=true so gitleaks' aws-access-token rule fires.
OPRULES="$TMP/synthetic-operator-rules.toml"
cat > "$OPRULES" <<'EOF'
title = "synthetic operator rules"
[extend]
useDefault = true
EOF

# provision_repo <dir> — git repo + .gitleaks.toml -> operator-rules(useDefault).
provision_repo() {
    init_repo "$1"
    cat > "$1/.gitleaks.toml" <<'EOF'
title = "fixture"
[extend]
path = ".gitleaks-operator-rules.toml"
EOF
    cat > "$1/.gitleaks-operator-rules.toml" <<'EOF'
title = "fixture operator rules"
[extend]
useDefault = true
EOF
}

# A provisioned repo whose PATH carries a synthetic infra-path marker, plus a rule
# that matches that marker — to exercise the cd-prefix / body-file-path exclusion
# (an infra path in a cd prefix or a --body-file path is NOT published). SYNTHINFRA
# is a synthetic stand-in for the guarded class; it is NEVER the operator's real path.
PREPO="$TMP/SYNTHINFRA-repo"
init_repo "$PREPO"
cat > "$PREPO/.gitleaks.toml" <<'EOF'
title = "fixture"
[extend]
path = ".gitleaks-operator-rules.toml"
EOF
cat > "$PREPO/.gitleaks-operator-rules.toml" <<'EOF'
title = "fixture operator rules"
[extend]
useDefault = true
[[rules]]
id = "synthetic-infra-path"
description = "synthetic infra-path marker (test only)"
regex = '''SYNTHINFRA'''
EOF
PREPO_CLEAN="$PREPO/clean-body.md"
PREPO_LEAK="$PREPO/leak-body.md"
printf 'A clean PR body.\nNothing sensitive here.\n' > "$PREPO_CLEAN"
printf 'A PR body.\nleftover credential %s\n' "$CANARY" > "$PREPO_LEAK"

# A provisioned repo under a FAKE HOME, to exercise `cd ~/<repo>` expansion
# end-to-end WITHOUT touching the operator's real home directory.
FAKEHOME="$TMP/fakehome"
provision_repo "$FAKEHOME/tilde-repo"

# Isolated hook COPIES for testing path 3 (guard's OWN repo) and the genuine
# "no ruleset" fail-closed / env-var override — deterministically and WITHOUT the
# real private ruleset. The real hook's own repo (HERE/../..) is dotty, whose
# ruleset must never be a fixture and is CI-absent; so we drive a copy whose own
# repo we control. Each copy mirrors the layout the hook needs to source
# gitleaks-common.sh (HERE/../../git-hooks/...), making HERE/../.. its "own repo".
COMMON_SRC="${SCRIPT_DIR}/../../git-hooks/gitleaks-common.sh"
make_iso() { # <dir> — lay out a runnable hook copy under <dir>
    mkdir -p "$1/.claude/hooks" "$1/git-hooks"
    cp "$HOOK" "$1/.claude/hooks/gh-pr-body-guard.sh"
    cp "$COMMON_SRC" "$1/git-hooks/gitleaks-common.sh"
}
# (a) own repo IS a provisioned repo (synthetic ruleset) -> path 3 resolves.
ISO_PROV="$TMP/iso-prov"; make_iso "$ISO_PROV"; provision_repo "$ISO_PROV"
ISO_PROV_HOOK="$ISO_PROV/.claude/hooks/gh-pr-body-guard.sh"
# (b) own repo is NOT a git repo -> path 3 fails (genuine fail-closed / override).
ISO_BARE="$TMP/iso-bare"; make_iso "$ISO_BARE"
ISO_BARE_HOOK="$ISO_BARE/.claude/hooks/gh-pr-body-guard.sh"

# Chained-cd fixtures: two provisioned repos so the DECOY at the first cd dir and
# the REAL body at the effective (last cd) dir can carry different content. A
# relative --body-file always resolves against the effective dir where gh runs.
CR1="$TMP/chain-repo-1"; provision_repo "$CR1"; mkdir -p "$CR1/sub" "$CR1/abssub"
printf 'clean decoy at the repo root (first cd)\n'      > "$CR1/body.md"
printf 'real body in the effective dir\nleak %s\n' "$CANARY" > "$CR1/sub/body.md"
printf 'body reached via an absolute mid-chain cd\nleak %s\n' "$CANARY" > "$CR1/abssub/body.md"
CR2="$TMP/chain-repo-2"; provision_repo "$CR2"; mkdir -p "$CR2/sub"
printf 'CANARY DECOY at the repo root (first cd)\nleak %s\n' "$CANARY" > "$CR2/body.md"
printf 'a genuinely clean body in the effective dir\n'  > "$CR2/sub/body.md"

# --- Runners -------------------------------------------------------------------
ERRFILE="$TMP/stderr.txt"

mkjson() { # <command> <cwd>
    jq -n --arg tn "Bash" --arg cmd "$1" --arg cwd "$2" \
        '{tool_name:$tn, tool_input:{command:$cmd}, cwd:$cwd}'
}
# run_hook clears GITLEAKS_OPERATOR_RULES (the path-4 override) so a stray value in
# the tester's own environment cannot mask behaviour. The REAL hook's own repo
# (path 3) is dotty, which resolves on a provisioned machine — so run_hook is used
# only for path 1 / path 2 tests, where an earlier path wins before path 3.
run_hook() { # <json> [pathspec]
    local json="$1" pathspec="${2:-$PATH}"
    printf '%s' "$json" | env -u GITLEAKS_OPERATOR_RULES PATH="$pathspec" bash "$HOOK" >/dev/null 2>"$ERRFILE"
    RC=$?
}
# run_hook_home overrides HOME so `cd ~/<repo>` expands into a fixture dir, not
# the operator's real home. Clears GITLEAKS_OPERATOR_RULES like run_hook.
run_hook_home() { # <json> <home>
    printf '%s' "$1" | env -u GITLEAKS_OPERATOR_RULES HOME="$2" PATH="$PATH" bash "$HOOK" >/dev/null 2>"$ERRFILE"
    RC=$?
}
# ISO runners drive an isolated hook COPY (own repo per make_iso), so path 3 and
# the fail-closed / override cases are deterministic and ruleset-independent.
run_iso_prov() { # <json>   (copy whose own repo IS provisioned; no env var)
    printf '%s' "$1" | env -u GITLEAKS_OPERATOR_RULES PATH="$PATH" bash "$ISO_PROV_HOOK" >/dev/null 2>"$ERRFILE"
    RC=$?
}
run_iso_bare() { # <json>   (copy whose own repo is NOT a repo; no env var)
    printf '%s' "$1" | env -u GITLEAKS_OPERATOR_RULES PATH="$PATH" bash "$ISO_BARE_HOOK" >/dev/null 2>"$ERRFILE"
    RC=$?
}
run_iso_bare_rules() { # <json> <rules-file>   (own repo NOT a repo; env-var override)
    printf '%s' "$1" | env GITLEAKS_OPERATOR_RULES="$2" PATH="$PATH" bash "$ISO_BARE_HOOK" >/dev/null 2>"$ERRFILE"
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
# Ruleset location — four ways, then fail-closed. Path 3 (guard's own repo) and
# the genuine "no ruleset" / env-var-override cases use ISOLATED hook copies: the
# REAL hook's own repo is dotty, whose private ruleset must never be a fixture and
# is CI-absent. Path 1 is exercised by every cwd=REPO test above.
# ============================================================================

# --- Path 2: honour a `cd <provisioned repo> && ...` prefix (wins before own-repo). -
section "ruleset path 2: 'cd <REPO> && gh pr create' from a non-repo cwd scans -> canary blocks"
run_hook "$(mkjson "cd $REPO && gh pr create --title \"x\" --body \"leak $CANARY\"" "$NOREPO")"
assert_eq "cd-prefix canary exits 2 (block — path 2 resolved, then scanned)" "2" "$RC"
grep -q "aws-access-token" "$ERRFILE" && pass "cd-prefix scan reports the rule id" || fail "cd-prefix scan reports the rule id" "$(cat "$ERRFILE")"

section "ruleset path 2: 'cd <REPO> && gh pr create' clean body from a non-repo cwd -> PASSES (no over-block)"
run_hook "$(mkjson "cd $REPO && gh pr create --title \"x\" --body \"entirely clean\"" "$NOREPO")"
assert_eq "cd-prefix clean exits 0 (allow)" "0" "$RC"

# --- Path 3: the guard's OWN repo (zero-config). Isolated copy whose HERE/../..
# IS a provisioned repo (synthetic ruleset); the real hook runs identical code. --
section "ruleset path 3: own repo resolves from a non-repo cwd (no cd, no env) -> canary blocks"
run_iso_prov "$(mkjson "gh pr create --title \"x\" --body \"leak $CANARY\"" "$NOREPO")"
assert_eq "own-repo canary exits 2 (block — path 3 resolved, then scanned)" "2" "$RC"
grep -q "aws-access-token" "$ERRFILE" && pass "own-repo scan reports the rule id" || fail "own-repo scan reports the rule id" "$(cat "$ERRFILE")"

section "ruleset path 3: own repo resolves, clean body -> PASSES (zero-config, no over-block)"
run_iso_prov "$(mkjson 'gh pr create --title "x" --body "entirely clean"' "$NOREPO")"
assert_eq "own-repo clean exits 0 (allow)" "0" "$RC"

# --- Genuine fail-closed: own repo NOT reachable AND no cd AND no env var. -------
section "no ruleset: own repo unreachable, no cd, no env -> BLOCK (names all four ways)"
run_iso_bare "$(mkjson "gh pr create --title \"x\" --body \"leak $CANARY\"" "$NOREPO")"
assert_eq "no-ruleset exits 2 (block)" "2" "$RC"
grep -qi "could not locate the operator gitleaks ruleset" "$ERRFILE" && pass "names the no-ruleset cause" || fail "names the no-ruleset cause" "$(cat "$ERRFILE")"
grep -q "setup-claude-profiles.sh" "$ERRFILE" && pass "names own-repo provisioning" || fail "names own-repo provisioning" "none"
grep -q "GITLEAKS_OPERATOR_RULES" "$ERRFILE" && pass "names the override" || fail "names the override" "none"
grep -qi "cd <repo" "$ERRFILE" && pass "names the cd-prefix way" || fail "names the cd-prefix way" "none"

section "no ruleset: 'cd /nonexistent && gh pr create' with own repo unreachable -> BLOCK"
run_iso_bare "$(mkjson 'cd /nonexistent && gh pr create --title "x" --body "y"' "$NOREPO")"
assert_eq "cd-nonexistent exits 2 (block)" "2" "$RC"
grep -qi "could not locate the operator gitleaks ruleset" "$ERRFILE" && pass "falls through to the no-ruleset block" || fail "falls through to the no-ruleset block" "$(cat "$ERRFILE")"

# --- Path 4: GITLEAKS_OPERATOR_RULES override (only when paths 1-3 fail). --------
section "ruleset path 4: env var override when own repo unreachable -> canary blocks"
run_iso_bare_rules "$(mkjson "gh pr create --title \"x\" --body \"leak $CANARY\"" "$NOREPO")" "$OPRULES"
assert_eq "env-var override canary exits 2 (block — path 4 scanned)" "2" "$RC"
grep -q "aws-access-token" "$ERRFILE" && pass "override scan reports the rule id" || fail "override scan reports the rule id" "$(cat "$ERRFILE")"

section "ruleset path 4: env var override clean body -> PASSES (no over-block)"
run_iso_bare_rules "$(mkjson 'gh pr create --title "x" --body "entirely clean"' "$NOREPO")" "$OPRULES"
assert_eq "env-var override clean exits 0 (allow)" "0" "$RC"

section "ruleset path 4: env var override pointing at a nonexistent file -> BLOCK (fail-closed)"
run_iso_bare_rules "$(mkjson "gh pr create --title \"x\" --body \"leak $CANARY\"" "$NOREPO")" "$TMP/no-such-rules.toml"
assert_eq "env-var override missing exits 2 (block)" "2" "$RC"
grep -q "GITLEAKS_OPERATOR_RULES" "$ERRFILE" && pass "names the env var" || fail "names the env var" "$(cat "$ERRFILE")"
grep -qi "unreadable" "$ERRFILE" && pass "names the unreadable reason" || fail "names the unreadable reason" "none"

# ============================================================================
# Never-published spans are excluded from the scan (fix false blocks) WITHOUT
# weakening what stays scanned. SYNTHINFRA marks a synthetic guarded infra-path.
# ============================================================================
section "cd-prefix excluded: 'cd <ABS provisioned repo> && gh pr create' clean body -> PASSES"
run_hook "$(mkjson "cd $PREPO && gh pr create --title \"x\" --body \"clean\"" "$NOREPO")"
assert_eq "cd-prefix abs-path clean exits 0 (fix — cd path not scanned)" "0" "$RC"

section "cd-prefix regression: 'cd ~/<repo> && gh pr create' clean body -> PASSES (~ expands)"
run_hook_home "$(mkjson 'cd ~/tilde-repo && gh pr create --title "x" --body "clean"' "$NOREPO")" "$FAKEHOME"
assert_eq "cd ~/repo clean exits 0 (allow)" "0" "$RC"

section "cd-prefix: a canary in the body still blocks (the canary, not the cd path)"
run_hook "$(mkjson "cd $PREPO && gh pr create --title \"x\" --body \"leak $CANARY\"" "$NOREPO")"
assert_eq "cd-prefix canary exits 2 (block)" "2" "$RC"
grep -q "aws-access-token" "$ERRFILE" && pass "blocks on the canary rule" || fail "blocks on the canary rule" "$(cat "$ERRFILE")"

section "cd-prefix strip is leading-only: the same infra path repeated in the BODY still blocks"
run_hook "$(mkjson "cd $PREPO && gh pr create --title \"x\" --body \"notes at $PREPO/n\"" "$NOREPO")"
assert_eq "repeated infra path in body exits 2 (block)" "2" "$RC"
grep -q "synthetic-infra-path" "$ERRFILE" && pass "blocks on the body copy (true positive)" || fail "blocks on the body copy" "$(cat "$ERRFILE")"

section "body-file path excluded: --body-file <ABS clean file> -> PASSES (path not scanned, contents are)"
run_hook "$(mkjson "gh pr create --title \"x\" --body-file $PREPO_CLEAN" "$PREPO")"
assert_eq "body-file clean-file path excluded exits 0 (allow)" "0" "$RC"

section "body-file contents still scanned: --body-file <ABS file with a canary> -> BLOCKS on contents"
run_hook "$(mkjson "gh pr create --title \"x\" --body-file $PREPO_LEAK" "$PREPO")"
assert_eq "body-file leak-file exits 2 (block)" "2" "$RC"
grep -q "aws-access-token" "$ERRFILE" && pass "blocks on the body-file contents (canary)" || fail "blocks on the body-file contents" "$(cat "$ERRFILE")"

section "true positive preserved: an infra-path in the BODY itself still blocks"
run_hook "$(mkjson 'gh pr create --title "x" --body "the config lives at /home/SYNTHINFRA/app.conf"' "$PREPO")"
assert_eq "infra-path in body exits 2 (block)" "2" "$RC"
grep -q "synthetic-infra-path" "$ERRFILE" && pass "blocks on the synthetic-infra-path rule (true positive)" || fail "blocks on the synthetic-infra-path rule" "$(cat "$ERRFILE")"

# ============================================================================
# Chained `cd A && cd B && ...` — the EFFECTIVE working dir (where gh runs) is the
# LAST cd, not the first. Getting this wrong scanned the wrong body = fail-open.
# Each test carries a live canary so a fail-open is caught.
# ============================================================================
section "chained cd: effective dir is the LAST cd — canary in A/sub/body.md blocks (A/body.md clean decoy)"
run_hook "$(mkjson "cd $CR1 && cd sub && gh pr create --title \"x\" --body-file body.md" "$NOREPO")"
assert_eq "chained-cd canary exits 2 (block — the effective-dir body was scanned)" "2" "$RC"
grep -q "aws-access-token" "$ERRFILE" && pass "scanned A/sub/body.md (canary), not the A/ decoy" || fail "scanned the effective-dir body" "$(cat "$ERRFILE")"

section "chained cd: clean body in the effective dir PASSES; the canary DECOY at A/ is NOT scanned"
run_hook "$(mkjson "cd $CR2 && cd sub && gh pr create --title \"x\" --body-file body.md" "$NOREPO")"
assert_eq "chained-cd clean exits 0 (decoy at A/ not scanned, no over-block)" "0" "$RC"

section "chained cd: an ABSOLUTE mid-chain target replaces the running dir — its canary blocks"
run_hook "$(mkjson "cd $CR1 && cd $CR1/abssub && gh pr create --title \"x\" --body-file body.md" "$NOREPO")"
assert_eq "abs-mid-chain canary exits 2 (block)" "2" "$RC"
grep -q "aws-access-token" "$ERRFILE" && pass "absolute target replaced (canary in /abs/body.md found)" || fail "absolute target replaced" "$(cat "$ERRFILE")"

section "chained cd: a mid-chain cd that fails to resolve -> resolve NOTHING -> fall through -> BLOCK"
run_iso_bare "$(mkjson "cd $CR1 && cd nonexistent && gh pr create --title \"x\" --body \"clean\"" "$NOREPO")"
assert_eq "chain-fails exits 2 (block)" "2" "$RC"
grep -qi "could not locate the operator gitleaks ruleset" "$ERRFILE" && pass "chain-fails falls through (no guessed dir)" || fail "chain-fails falls through" "$(cat "$ERRFILE")"

section "chained cd regression: a single 'cd A && gh pr create --body-file body.md' still resolves to A"
run_hook "$(mkjson "cd $CR2 && gh pr create --title \"x\" --body-file body.md" "$NOREPO")"
assert_eq "single-cd resolves to A (canary at A/body.md) exits 2 (block)" "2" "$RC"
grep -q "aws-access-token" "$ERRFILE" && pass "single-cd BODY_CWD = A (A/body.md canary found)" || fail "single-cd BODY_CWD = A" "$(cat "$ERRFILE")"

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
