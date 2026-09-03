#!/usr/bin/env bash
# Test suite for the fail-closed gitleaks git-lifecycle hooks:
#   git-hooks/gitleaks-pre-push.sh   (dual-mode: pre-commit env + native stdin)
#   git-hooks/gitleaks-commit-msg.sh
#   git-hooks/gitleaks-staged.sh
#   git-hooks/gitleaks-common.sh     (operator-rules resolution: fixed path first)
#
# Coverage:
#   * operator-rules resolution: the suite's DEFAULT fixture is the fixed
#     install path (under a private XDG_CONFIG_HOME, never the machine's real
#     one) with NO checkout-relative rules file; that file appears only in
#     sections labelled "fallback:";
#   * direct-invocation of the hooks (both invocation contexts);
#   * cross-remote fail-open regression — the hook must scan against the ACTUAL
#     push target, not a hardcoded `origin`;
#   * empty-remote bootstrap (first push to a refless remote) — clean passes and
#     is actually scanned, dirty blocks ON THE FINDING (not "cannot determine");
#   * REAL-SHIM end-to-end: the actual hook, under pre-commit's generated
#     .git/hooks/pre-push, driven exactly as git drives it (argv = remote name +
#     url, stdin = the pre-push protocol).
#
# Self-contained: local bare remotes populated via `git clone --bare` + fetch
# (NO `git push` anywhere), synthetic config (never the real private ruleset),
# no dotty state touched. Runs identically locally and in CI (CI installs
# gitleaks + pre-commit; see .github/workflows/test.yml).
#
# Canaries are randomly generated AKIA + 16 chars of [A-Z2-7] — NEVER ending in
# EXAMPLE (gitleaks' aws-access-token rule allowlists '.+EXAMPLE$', which would
# yield a false "clean"). No operator PII appears anywhere in this suite.
#
# Run: bash ~/bin/dotty/.claude/eval/gitleaks-hooks.test.sh

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/assert.sh"

HOOKS_DIR="${HOOKS_DIR:-${SCRIPT_DIR}/../../git-hooks}"
PREPUSH="$HOOKS_DIR/gitleaks-pre-push.sh"
COMMITMSG="$HOOKS_DIR/gitleaks-commit-msg.sh"
STAGED="$HOOKS_DIR/gitleaks-staged.sh"
ZERO="0000000000000000000000000000000000000000"

for f in "$PREPUSH" "$COMMITMSG" "$STAGED" "$HOOKS_DIR/gitleaks-common.sh"; do
    [[ -f "$f" ]] || { echo "FATAL: missing $f"; exit 2; }
done
# gitleaks AND pre-commit are REQUIRED. A missing tool is a hard failure of this
# suite, never a silent skip (a silently-green no-op is a gamed metric). CI
# installs both before invoking run-all.sh.
command -v gitleaks >/dev/null 2>&1   || { echo "FATAL: gitleaks not on PATH — suite cannot run. Install gitleaks 8.30.1."; exit 2; }
command -v pre-commit >/dev/null 2>&1 || { echo "FATAL: pre-commit not on PATH — the real-shim cases cannot run. Install pre-commit==4.6.0."; exit 2; }

rand_akia() { echo "AKIA$(LC_ALL=C tr -dc 'A-Z2-7' </dev/urandom | head -c 16)"; }
CANARY="$(rand_akia)"

TMP="$(mktemp -d -t gitleaks-hooks-test.XXXXXX)"
cleanup() { chmod -R u+rw "$TMP" 2>/dev/null; rm -rf "$TMP"; }
trap cleanup EXIT INT TERM
ERRFILE="$TMP/stderr.txt"

# Operator-rules fixtures. The suite owns a PRIVATE XDG_CONFIG_HOME so the fixed
# path the hooks read is a fixture, never this machine's real install — without
# this, every case would silently scan with the real ruleset once it exists.
# The fixed-path fixture carries useDefault (so gitleaks' aws-access-token rule
# fires on the canary) plus ONE marker rule that exists nowhere else, so a case
# can prove WHICH ruleset loaded, not merely that one did. XDG_EMPTY stands in
# for "no ruleset installed" in the fallback sections (via XDG_OVERRIDE).
export XDG_CONFIG_HOME="$TMP/xdg"
XDG_EMPTY="$TMP/xdg-empty"; mkdir -p "$XDG_EMPTY"
FIXED="$XDG_CONFIG_HOME/gitleaks/operator-rules.toml"
XDG_OVERRIDE=""
write_fixed_rules() {
    mkdir -p "$(dirname "$FIXED")"
    cat > "$FIXED" <<'EOF'
title = "fixture operator rules (fixed path)"
[extend]
useDefault = true
[[rules]]
id = "fixture-fixedpath-marker"
description = "marker present ONLY in the fixed-path fixture (test only)"
regex = '''FIXEDPATHMARKER'''
EOF
}
write_fixed_rules

# The repo config every estate repo carries: a checkout-relative [extend] token
# the resolver rewrites to the fixed path. No rules file is written beside it.
write_config_chain() { # <repo-dir>
    cat > "$1/.gitleaks.toml" <<'EOF'
title = "fixture"
[extend]
path = ".gitleaks-operator-rules.toml"
EOF
}
# fallback-only: the checkout-relative rules file (in the estate, a gitignored
# symlink). Carries a DIFFERENT marker so precedence is provable.
write_checkout_rules() { # <repo-dir>
    cat > "$1/.gitleaks-operator-rules.toml" <<'EOF'
title = "fixture operator rules (checkout-relative)"
[extend]
useDefault = true
[[rules]]
id = "fixture-symlink-marker"
description = "marker present ONLY in the checkout-relative fixture (test only)"
regex = '''SYMLINKMARKER'''
EOF
}
git_init_repo() { # <dir>
    git init -q -b main "$1" 2>/dev/null || { git init -q "$1"; git -C "$1" symbolic-ref HEAD refs/heads/main; }
    # noreply address: the pre-push identity guard (LEX-321 class) blocks any
    # non-noreply author/committer email, so fixture commits must comply for
    # the clean-pass assertions to isolate the gitleaks behavior under test.
    git -C "$1" config user.email "test@users.noreply.github.com"
    git -C "$1" config user.name "Test Runner"
    git -C "$1" config commit.gpgsign false
}
# Writes the pre-commit scaffold (config + hook copies) into <repo> but leaves
# it UNTRACKED — so it persists across branch checkouts and never lands inside a
# scanned commit range. Call AFTER the base commit; commit test files with
# targeted `git add`, never `git add -A`.
write_shim_scaffold() { # <repo>
    mkdir -p "$1/git-hooks"; cp "$HOOKS_DIR"/gitleaks-*.sh "$1/git-hooks/"; chmod +x "$1/git-hooks/"*.sh
    cat > "$1/.pre-commit-config.yaml" <<'YAML'
default_install_hook_types: [pre-commit, pre-push, commit-msg]
default_stages: [pre-commit]
repos:
  - repo: local
    hooks:
      - id: gitleaks-pre-push
        name: gitleaks (pre-push range)
        entry: git-hooks/gitleaks-pre-push.sh
        language: script
        pass_filenames: false
        always_run: true
        stages: [pre-push]
YAML
}
pc_install() { ( cd "$1" && pre-commit install --install-hooks -t pre-push >/dev/null 2>&1 ); }
# Invoke the generated shim exactly as git does: argv=(remote url), stdin=protocol.
shim_fire() { # <repo> <origin-path> <branch> <tip-sha> <remote-sha>
    ( cd "$1" && printf 'refs/heads/%s %s refs/heads/%s %s\n' "$3" "$4" "$3" "$5" \
        | env XDG_CONFIG_HOME="${XDG_OVERRIDE:-$XDG_CONFIG_HOME}" .git/hooks/pre-push origin "$2" ) >"$ERRFILE" 2>&1
    RC=$?
}

# ============================================================================
# Fixture A — direct-invocation assertions. origin/main established WITHOUT push.
# ============================================================================
REPO="$TMP/repo"; ORIGIN="$TMP/origin.git"
git_init_repo "$REPO"
write_config_chain "$REPO"
echo "clean base" > "$REPO/base.txt"
git -C "$REPO" add -A
git -C "$REPO" commit -q -m "base" --no-verify
CLEAN_SHA="$(git -C "$REPO" rev-parse HEAD)"
git clone -q --bare "$REPO" "$ORIGIN"          # origin/main = CLEAN_SHA (no push)
git -C "$REPO" remote add origin "$ORIGIN"
git -C "$REPO" fetch -q origin

commit_on() { # <new-branch> <base> <file> <content> -> echoes sha
    git -C "$REPO" checkout -q -b "$1" "$2"
    printf '%s\n' "$4" > "$REPO/$3"
    git -C "$REPO" add -A
    git -C "$REPO" commit -q -m "$1" --no-verify
    git -C "$REPO" rev-parse HEAD
}
CLEAN2_SHA="$(commit_on advance main clean2.txt "another clean line")"
BAD_SHA="$(commit_on bad-branch "$CLEAN_SHA" bad.txt "leak $CANARY")"
FEAT_SHA="$(commit_on feature-bad "$CLEAN_SHA" feat.txt "leak $CANARY")"
FEATOK_SHA="$(commit_on feature-clean "$CLEAN_SHA" featok.txt "clean feature content")"
git -C "$REPO" checkout -q main

# Every runner passes XDG_CONFIG_HOME explicitly: the suite's private fixture
# dir by default, XDG_EMPTY when a fallback section sets XDG_OVERRIDE.
# pre-commit-framework path: FROM/TO + REMOTE_NAME in env, EMPTY stdin.
run_env() { # <from> <to> [remote_name=origin] [pathspec]
    ( cd "$REPO" && env PATH="${4:-$PATH}" XDG_CONFIG_HOME="${XDG_OVERRIDE:-$XDG_CONFIG_HOME}" \
        PRE_COMMIT_FROM_REF="$1" PRE_COMMIT_TO_REF="$2" \
        PRE_COMMIT_REMOTE_NAME="${3:-origin}" PRE_COMMIT_REMOTE_BRANCH="refs/heads/test" \
        bash "$PREPUSH" </dev/null ) >/dev/null 2>"$ERRFILE"
    RC=$?
}
# native git-hook path: raw protocol on stdin, remote name as $1, NO PRE_COMMIT_* env.
run_stdin() { # <stdin-string> [remote_name=origin]
    ( cd "$REPO" && printf '%s\n' "$1" \
        | env -u PRE_COMMIT_FROM_REF -u PRE_COMMIT_TO_REF -u PRE_COMMIT_REMOTE_NAME PATH="$PATH" \
            XDG_CONFIG_HOME="${XDG_OVERRIDE:-$XDG_CONFIG_HOME}" \
            bash "$PREPUSH" "${2:-origin}" "$ORIGIN" ) >/dev/null 2>"$ERRFILE"
    RC=$?
}
run_neither() {   # no stdin, no refs, no remote name — the genuinely indeterminate case
    ( cd "$REPO" && env -u PRE_COMMIT_FROM_REF -u PRE_COMMIT_TO_REF -u PRE_COMMIT_REMOTE_NAME \
        XDG_CONFIG_HOME="${XDG_OVERRIDE:-$XDG_CONFIG_HOME}" \
        bash "$PREPUSH" </dev/null ) >/dev/null 2>"$ERRFILE"
    RC=$?
}
run_commitmsg() {
    ( cd "$REPO" && env XDG_CONFIG_HOME="${XDG_OVERRIDE:-$XDG_CONFIG_HOME}" bash "$COMMITMSG" "$1" ) >/dev/null 2>"$ERRFILE"
    RC=$?
}
# staged hook: scans the index of $REPO as pre-commit's pre-commit stage would.
# Both streams are captured: gitleaks prints --verbose findings on stdout and
# its log on stderr, and pre-commit shows both on failure.
run_staged() {
    ( cd "$REPO" && env XDG_CONFIG_HOME="${XDG_OVERRIDE:-$XDG_CONFIG_HOME}" bash "$STAGED" ) >"$ERRFILE" 2>&1
    RC=$?
}

# ---- pre-commit framework path (the deployment path) ------------------------
section "pre-commit path (a): bad existing-branch range is blocked"
run_env "$CLEAN_SHA" "$BAD_SHA"
assert_eq "bad range exits 1 (blocked)" "1" "$RC"
grep -q "aws-access-token" "$ERRFILE" && pass "reports the rule id" || fail "reports the rule id" "$(cat "$ERRFILE")"
grep -q "$CANARY" "$ERRFILE" && fail "matched literal withheld" "CANARY leaked into output!" || pass "matched literal withheld (redacted)"
grep -qiE 'filter-repo|amend|rebase' "$ERRFILE" && pass "gives a remediation path" || fail "gives a remediation path" "none"

section "pre-commit path (b): clean existing-branch range passes"
run_env "$CLEAN_SHA" "$CLEAN2_SHA"
assert_eq "clean range exits 0 (passes)" "0" "$RC"

section "pre-commit path (c): new branch (from=ancestor) carrying a bad commit is blocked"
run_env "$CLEAN_SHA" "$FEAT_SHA"
assert_eq "new-branch bad range exits 1 (blocked)" "1" "$RC"
grep -q "aws-access-token" "$ERRFILE" && pass "new-branch scan reports the rule id" || fail "new-branch scan reports the rule id" "none"

section "pre-commit path (c2): new branch, clean, passes"
run_env "$CLEAN_SHA" "$FEATOK_SHA"
assert_eq "new-branch clean range exits 0 (passes)" "0" "$RC"

section "pre-commit path: empty FROM_REF falls back to '--not --remotes' (trap-safe) and blocks a bad tip"
run_env "" "$FEAT_SHA"
assert_eq "empty-from bad tip exits 1 (blocked)" "1" "$RC"
grep -q "aws-access-token" "$ERRFILE" && pass "empty-from fallback still scans + reports" || fail "empty-from fallback still scans + reports" "none"

section "pre-commit path: TO_REF all-zeros (deletion) passes"
run_env "$CLEAN_SHA" "$ZERO"
assert_eq "deletion (to=zero) exits 0 (nothing to scan)" "0" "$RC"

# ---- identity guard (LEX-321): non-noreply email in the range blocks --------
section "identity guard: non-noreply author email blocks, names SHA + field, withholds the value"
git -C "$REPO" checkout -q -b ident-stale "$CLEAN_SHA"
echo "innocuous content" > "$REPO/ident.txt"
git -C "$REPO" add ident.txt
GIT_AUTHOR_EMAIL="stale@example.com" git -C "$REPO" commit -q -m "stale-clone-shaped commit" --no-verify
STALE_SHA="$(git -C "$REPO" rev-parse HEAD)"
git -C "$REPO" checkout -q main
run_env "$CLEAN_SHA" "$STALE_SHA"
assert_eq "stale-email range exits 1 (blocked)" "1" "$RC"
grep -q "non-noreply author email" "$ERRFILE" && pass "names the offending field" || fail "names the offending field" "$(cat "$ERRFILE")"
grep -q "$STALE_SHA" "$ERRFILE" && pass "names the offending commit SHA" || fail "names the offending commit SHA" "none"
grep -q "stale@example.com" "$ERRFILE" && fail "email value withheld" "email leaked into output!" || pass "email value withheld"

section "identity guard: GitHub squash shape (committer noreply@github.com) passes"
git -C "$REPO" checkout -q -b ident-squash "$CLEAN_SHA"
echo "squash-shaped content" > "$REPO/squash.txt"
git -C "$REPO" add squash.txt
GIT_COMMITTER_NAME="GitHub" GIT_COMMITTER_EMAIL="noreply@github.com" git -C "$REPO" commit -q -m "squash-shaped" --no-verify
SQUASH_SHA="$(git -C "$REPO" rev-parse HEAD)"
git -C "$REPO" checkout -q main
run_env "$CLEAN_SHA" "$SQUASH_SHA"
assert_eq "squash-shape range exits 0 (passes)" "0" "$RC"

section "identity guard: space-in-author-email cannot column-shift a bad committer past the check"
# git accepts a SPACE inside an env-supplied email; under space-delimited
# parsing the committer column inherits a noreply substring and passes. The
# tab-delimited format makes this shape block on the committer field.
git -C "$REPO" checkout -q -b ident-shift "$CLEAN_SHA"
echo "shift-probe content" > "$REPO/shift.txt"
git -C "$REPO" add shift.txt
GIT_AUTHOR_EMAIL="noreply@a noreply@b" GIT_COMMITTER_EMAIL="bad@example.com" git -C "$REPO" commit -q -m "column-shift-shaped" --no-verify
SHIFT_SHA="$(git -C "$REPO" rev-parse HEAD)"
git -C "$REPO" checkout -q main
run_env "$CLEAN_SHA" "$SHIFT_SHA"
assert_eq "space-email column-shift range exits 1 (blocked)" "1" "$RC"
grep -q "non-noreply committer email" "$ERRFILE" && pass "blocks on the committer field (no shift past it)" || fail "blocks on the committer field" "$(cat "$ERRFILE")"

# ---- native git-hook path (raw stdin protocol) ------------------------------
section "native path (c): NEW-BRANCH push with remote_sha=ZERO is blocked [FAIL-OPEN REGRESSION]"
run_stdin "refs/heads/feature-bad $FEAT_SHA refs/heads/feature-bad $ZERO"
assert_eq "native new-branch bad push exits 1 (blocked)" "1" "$RC"
grep -q "aws-access-token" "$ERRFILE" && pass "native new-branch scan reports the rule id" || fail "native new-branch scan reports the rule id" "none"
# Prove the trap is real in this fixture: the NAIVE zero-based range fails OPEN.
# --config is the fixed-path fixture itself (it carries useDefault) so this
# proves gitleaks' log-opts behaviour and nothing about extend resolution.
NAIVE_RC=0
( cd "$REPO" && gitleaks git . --log-opts="$ZERO..$FEAT_SHA" --config "$FIXED" --no-banner >/dev/null 2>&1 ) || NAIVE_RC=$?
assert_eq "naive ZERO..sha range fails OPEN (exit 0) — the trap the hook defends" "0" "$NAIVE_RC"

section "native path: existing-branch bad push is blocked; deletion + clean pass"
run_stdin "refs/heads/main $BAD_SHA refs/heads/main $CLEAN_SHA"
assert_eq "native existing bad push exits 1 (blocked)" "1" "$RC"
run_stdin "refs/heads/main $ZERO refs/heads/main $CLEAN_SHA"
assert_eq "native branch deletion (local zero) exits 0 (skipped)" "0" "$RC"
run_stdin "refs/heads/feature-clean $FEATOK_SHA refs/heads/feature-clean $ZERO"
assert_eq "native new-branch clean push exits 0 (passes)" "0" "$RC"

# ---- cross-remote fail-open regression (FIX 1) ------------------------------
# A canary commit already on origin's tracking ref, pushed as a NEW branch to a
# DIFFERENT remote (upstream), must BLOCK. A hook hardcoded to `--not
# --remotes=origin` would exclude the commit -> count 0 -> pass unscanned.
section "cross-remote (FIX 1): commit on origin, pushed as new branch to 'upstream', blocks"
XR="$TMP/xremote"
git_init_repo "$XR"
write_config_chain "$XR"
echo "base" > "$XR/a.txt"; git -C "$XR" add -A; git -C "$XR" commit -q -m base --no-verify
printf 'key = %s\n' "$CANARY" > "$XR/leak.txt"; git -C "$XR" add -A; git -C "$XR" commit -q -m "leaky" --no-verify
XR_LEAK="$(git -C "$XR" rev-parse HEAD)"
git clone -q --bare "$XR" "$TMP/xr-origin.git"      # origin has the canary commit on main
git -C "$XR" remote add origin "$TMP/xr-origin.git"; git -C "$XR" fetch -q origin
git init --bare -q "$TMP/xr-upstream.git"           # upstream is empty
git -C "$XR" remote add upstream "$TMP/xr-upstream.git"; git -C "$XR" fetch -q upstream 2>/dev/null || true

( cd "$XR" && printf 'refs/heads/feat %s refs/heads/feat %s\n' "$XR_LEAK" "$ZERO" \
    | env -u PRE_COMMIT_REMOTE_NAME bash "$PREPUSH" upstream "$TMP/xr-upstream.git" ) >/dev/null 2>"$ERRFILE"
assert_eq "native push-to-upstream exits 1 (blocked, not excluded via origin)" "1" "$?"
grep -q "aws-access-token" "$ERRFILE" && pass "cross-remote native scan reports the finding" || fail "cross-remote native scan reports the finding" "$(cat "$ERRFILE")"
( cd "$XR" && env PRE_COMMIT_REMOTE_NAME=upstream PRE_COMMIT_FROM_REF="" PRE_COMMIT_TO_REF="$XR_LEAK" \
    bash "$PREPUSH" </dev/null ) >/dev/null 2>"$ERRFILE"
assert_eq "pre-commit push-to-upstream exits 1 (blocked)" "1" "$?"
( cd "$XR" && printf 'refs/heads/feat %s refs/heads/feat %s\n' "$XR_LEAK" "$ZERO" \
    | env -u PRE_COMMIT_REMOTE_NAME bash "$PREPUSH" origin "$TMP/xr-origin.git" ) >/dev/null 2>"$ERRFILE"
assert_eq "control push-to-origin passes (commit already on origin)" "0" "$?"
( cd "$XR" && printf 'refs/heads/feat %s refs/heads/feat %s\n' "$XR_LEAK" "$ZERO" \
    | env -u PRE_COMMIT_REMOTE_NAME bash "$PREPUSH" ) >/dev/null 2>"$ERRFILE"
assert_eq "unknown-remote fallback over-scans and blocks" "1" "$?"

# ---- fail-closed: genuinely indeterminate -----------------------------------
section "fail-closed: no stdin + no refs + no remote name blocks (never a silent pass)"
run_neither
assert_eq "indeterminate context exits 1 (blocked)" "1" "$RC"
grep -qi "cannot determine what is being pushed" "$ERRFILE" && pass "names the unknown-range block" || fail "names the unknown-range block" "$(cat "$ERRFILE")"

# ---- fail-closed preflight --------------------------------------------------
section "preflight (d): missing gitleaks binary blocks"
run_env "$CLEAN_SHA" "$BAD_SHA" "origin" "/usr/bin:/bin"
assert_eq "missing gitleaks exits 1 (blocked)" "1" "$RC"
grep -qi "not installed" "$ERRFILE" && pass "names the missing binary" || fail "names the missing binary" "$(cat "$ERRFILE")"
grep -qi "brew install gitleaks" "$ERRFILE" && pass "gives install instruction" || fail "gives install instruction" "none"

# ---- operator-rules resolution: the fixed path ------------------------------
section "fixed path (e): rules load from the fixed install path — no checkout-relative file exists"
[[ ! -e "$REPO/.gitleaks-operator-rules.toml" ]] && pass "fixture has no checkout-relative rules file" || fail "fixture has no checkout-relative rules file" "present"
MARK_SHA="$(commit_on marker-fixed "$CLEAN_SHA" marker.txt "token FIXEDPATHMARKER here")"
git -C "$REPO" checkout -q main
run_env "$CLEAN_SHA" "$MARK_SHA"
assert_eq "fixed-path marker range exits 1 (blocked)" "1" "$RC"
grep -q "fixture-fixedpath-marker" "$ERRFILE" && pass "reports the FIXED-PATH fixture's rule id (proves which ruleset loaded)" || fail "reports the fixed-path rule id" "$(cat "$ERRFILE")"
run_env "$CLEAN_SHA" "$BAD_SHA"
assert_eq "default rules still fire through the fixed path (canary blocked)" "1" "$RC"

section "fixed path beats a checkout-relative file pointing at a DIFFERENT ruleset"
write_checkout_rules "$REPO"
SYM_SHA="$(commit_on marker-symlink "$CLEAN_SHA" symmark.txt "token SYMLINKMARKER here")"
git -C "$REPO" checkout -q main
run_env "$CLEAN_SHA" "$SYM_SHA"
assert_eq "checkout-relative marker range exits 0 (its file was NOT consulted)" "0" "$RC"
run_env "$CLEAN_SHA" "$MARK_SHA"
assert_eq "fixed-path marker still blocks with the checkout file present" "1" "$RC"
grep -q "fixture-symlink-marker" "$ERRFILE" && fail "checkout-relative rule id absent" "symlink ruleset leaked into the scan" || pass "checkout-relative rule id absent from the report"
rm -f "$REPO/.gitleaks-operator-rules.toml"

section "fixed path present but unreadable blocks (never falls back)"
write_checkout_rules "$REPO"          # a valid fallback exists — must NOT be used
chmod 000 "$FIXED"
run_env "$CLEAN_SHA" "$SYM_SHA"
chmod 644 "$FIXED"
rm -f "$REPO/.gitleaks-operator-rules.toml"
assert_eq "unreadable fixed path exits 1 (blocked)" "1" "$RC"
grep -qi "unreadable" "$ERRFILE" && pass "names the unreadable install" || fail "names the unreadable install" "$(cat "$ERRFILE")"

section "fixed path is a broken symlink: blocks (never falls back)"
mv "$FIXED" "$FIXED.keep"; ln -s "/nonexistent/operator-rules.toml" "$FIXED"
run_env "$CLEAN_SHA" "$CLEAN2_SHA"
rm -f "$FIXED"; mv "$FIXED.keep" "$FIXED"
assert_eq "broken fixed-path symlink exits 1 (blocked)" "1" "$RC"
grep -qi "unreadable" "$ERRFILE" && pass "names the broken install" || fail "names the broken install" "$(cat "$ERRFILE")"

section "repo config's own [allowlist] survives the rewritten effective config"
# The scan reads the WORKING-TREE config, so the allowlist is written after the
# marker commit exists and main is checked out again (a committed config on the
# side branch would not be the one the hook resolves).
git -C "$REPO" checkout -q -b allowlisted "$CLEAN_SHA"
echo "token FIXEDPATHMARKER in an allowlisted path" > "$REPO/allowed.txt"
git -C "$REPO" add allowed.txt; git -C "$REPO" commit -q -m "allowlisted" --no-verify
ALLOW_SHA="$(git -C "$REPO" rev-parse HEAD)"
git -C "$REPO" checkout -q main
cat > "$REPO/.gitleaks.toml" <<'EOF'
title = "fixture with allowlist"
[extend]
path = ".gitleaks-operator-rules.toml"
[allowlist]
paths = ['''allowed\.txt$''']
EOF
run_env "$CLEAN_SHA" "$ALLOW_SHA"
assert_eq "allowlisted path passes under the effective config" "0" "$RC"
write_config_chain "$REPO"
run_env "$CLEAN_SHA" "$ALLOW_SHA"
assert_eq "control: without the allowlist the same range blocks" "1" "$RC"

section "useDefault-only config (no operator extend) passes through unchanged"
cat > "$REPO/.gitleaks.toml" <<'EOF'
title = "fixture, base rules only"
[extend]
useDefault = true
EOF
run_env "$CLEAN_SHA" "$BAD_SHA"
assert_eq "base rules still fire (canary blocked)" "1" "$RC"
run_env "$CLEAN_SHA" "$MARK_SHA"
assert_eq "operator marker does NOT fire (no extend was injected)" "0" "$RC"
write_config_chain "$REPO"

section "parse guard: an [extend] path this parser cannot read blocks (never pass-through)"
cat > "$REPO/.gitleaks.toml" <<'EOF'
title = "fixture, unquoted extend"
[extend]
path = .gitleaks-operator-rules.toml
EOF
run_env "$CLEAN_SHA" "$CLEAN2_SHA"
assert_eq "unreadable extend value exits 1 (blocked)" "1" "$RC"
grep -qi "cannot parse" "$ERRFILE" && pass "names the parse failure" || fail "names the parse failure" "$(cat "$ERRFILE")"
write_config_chain "$REPO"

# ---- fallback: the checkout-relative file -----------------------------------
section "fallback: fixed path absent, checkout-relative file present -> its rules load"
XDG_OVERRIDE="$XDG_EMPTY"
write_checkout_rules "$REPO"
run_env "$CLEAN_SHA" "$SYM_SHA"
assert_eq "fallback: checkout-relative marker exits 1 (blocked)" "1" "$RC"
grep -q "fixture-symlink-marker" "$ERRFILE" && pass "fallback: reports the CHECKOUT-RELATIVE fixture's rule id" || fail "fallback: reports the checkout-relative rule id" "$(cat "$ERRFILE")"
run_env "$CLEAN_SHA" "$MARK_SHA"
assert_eq "fallback: fixed-path marker does not fire (that file is absent)" "0" "$RC"
rm -f "$REPO/.gitleaks-operator-rules.toml"
XDG_OVERRIDE=""

section "fallback: fixed path absent AND checkout symlink broken -> blocks, naming BOTH remedies"
XDG_OVERRIDE="$XDG_EMPTY"
ln -s "/nonexistent/operator-rules.toml" "$REPO/.gitleaks-operator-rules.toml"
run_env "$CLEAN_SHA" "$BAD_SHA"
rm -f "$REPO/.gitleaks-operator-rules.toml"
XDG_OVERRIDE=""
assert_eq "broken extend path, no install: exits 1 (blocked)" "1" "$RC"
grep -qi "unresolvable" "$ERRFILE" && pass "names the unresolvable ruleset" || fail "names the unresolvable ruleset" "$(cat "$ERRFILE")"
grep -q "gitleaks-rules apply" "$ERRFILE" && pass "names the blueprint install" || fail "names the blueprint install" "none"
grep -q "setup-claude-profiles.sh" "$ERRFILE" && pass "names the checkout provisioning step" || fail "names the checkout provisioning step" "none"

section "fallback: fixed path absent AND no checkout file at all -> blocks"
XDG_OVERRIDE="$XDG_EMPTY"
run_env "$CLEAN_SHA" "$BAD_SHA"
XDG_OVERRIDE=""
assert_eq "nothing installed anywhere: exits 1 (blocked)" "1" "$RC"
grep -qi "unresolvable" "$ERRFILE" && pass "names the unresolvable ruleset" || fail "names the unresolvable ruleset" "$(cat "$ERRFILE")"

# ---- commit-msg hook --------------------------------------------------------
section "commit-msg (f): a canary in the message text is blocked"
MSG_BAD="$TMP/msg-bad.txt"; MSG_OK="$TMP/msg-ok.txt"
printf 'Add feature\n\nleftover key %s\n' "$CANARY" > "$MSG_BAD"
printf 'Add feature\n\nan ordinary, clean commit message\n' > "$MSG_OK"
run_commitmsg "$MSG_BAD"
assert_eq "canary message exits 1 (blocked)" "1" "$RC"
grep -q "aws-access-token" "$ERRFILE" && pass "commit-msg reports the rule id" || fail "commit-msg reports the rule id" "none"
grep -q "$CANARY" "$ERRFILE" && fail "commit-msg withholds the literal" "CANARY leaked!" || pass "commit-msg withholds the literal"
run_commitmsg "$MSG_OK"
assert_eq "clean message exits 0 (passes)" "0" "$RC"
run_commitmsg "$TMP/does-not-exist.txt"
assert_eq "missing message file exits 1 (fail-closed)" "1" "$RC"

# ---- staged hook (pre-commit stage) ----------------------------------------
section "staged (g): gitleaks-staged.sh blocks a staged marker, passes clean, fails closed without a ruleset"
git -C "$REPO" checkout -q main
echo "token FIXEDPATHMARKER staged" > "$REPO/staged-bad.txt"; git -C "$REPO" add staged-bad.txt
run_staged
assert_eq "staged marker exits 1 (blocked)" "1" "$RC"
grep -q "fixture-fixedpath-marker" "$ERRFILE" && pass "staged scan reports the fixed-path rule id" || fail "staged scan reports the fixed-path rule id" "$(cat "$ERRFILE")"
grep -q "FIXEDPATHMARKER" "$ERRFILE" && fail "staged scan withholds the literal" "marker leaked into output!" || pass "staged scan withholds the literal (redacted)"
git -C "$REPO" reset -q staged-bad.txt; rm -f "$REPO/staged-bad.txt"
echo "nothing to see" > "$REPO/staged-ok.txt"; git -C "$REPO" add staged-ok.txt
run_staged
assert_eq "clean staged file exits 0 (passes)" "0" "$RC"
XDG_OVERRIDE="$XDG_EMPTY"
run_staged
XDG_OVERRIDE=""
assert_eq "staged scan with no ruleset anywhere exits 1 (fail-closed)" "1" "$RC"
grep -qi "unresolvable" "$ERRFILE" && pass "staged scan names the unresolvable ruleset" || fail "staged scan names the unresolvable ruleset" "$(cat "$ERRFILE")"
git -C "$REPO" reset -q staged-ok.txt; rm -f "$REPO/staged-ok.txt"

# ============================================================================
# REAL-SHIM end-to-end (FIX 2): the actual hook, via pre-commit's generated
# .git/hooks/pre-push, driven with git's exact argv + stdin. No `git push`.
# Populated origin (base already present).
# ============================================================================
section "real-shim (FIX 2): populated-remote new-branch pushes via the real pre-commit hook"
SHIM="$TMP/shim"
git_init_repo "$SHIM"
write_config_chain "$SHIM"
echo "clean base" > "$SHIM/a.txt"
git -C "$SHIM" add a.txt .gitleaks.toml
git -C "$SHIM" commit -q -m base --no-verify
SHIM_ORIGIN="$TMP/shim-origin.git"
git clone -q --bare "$SHIM" "$SHIM_ORIGIN"                 # origin has base on main (no push)
git -C "$SHIM" remote add origin "$SHIM_ORIGIN"; git -C "$SHIM" fetch -q origin
write_shim_scaffold "$SHIM"; pc_install "$SHIM"            # scaffold stays UNTRACKED

git -C "$SHIM" checkout -q -b feat-clean
echo "nothing to see" > "$SHIM/b.txt"; git -C "$SHIM" add b.txt; git -C "$SHIM" commit -q -m "clean work" --no-verify
shim_fire "$SHIM" "$SHIM_ORIGIN" feat-clean "$(git -C "$SHIM" rev-parse HEAD)" "$ZERO"
assert_eq "real-shim clean new-branch passes" "0" "$RC"

git -C "$SHIM" checkout -q -b feat-dirty main
printf 'key = %s\n' "$CANARY" > "$SHIM/leak.txt"; git -C "$SHIM" add leak.txt; git -C "$SHIM" commit -q -m "oops" --no-verify
shim_fire "$SHIM" "$SHIM_ORIGIN" feat-dirty "$(git -C "$SHIM" rev-parse HEAD)" "$ZERO"
assert_eq "real-shim dirty new-branch blocks" "1" "$RC"
grep -q "aws-access-token" "$ERRFILE" && pass "real-shim reports the finding" || fail "real-shim reports the finding" "$(cat "$ERRFILE")"
grep -q "$CANARY" "$ERRFILE" && fail "real-shim withholds the literal" "CANARY leaked!" || pass "real-shim withholds the literal"

git -C "$SHIM" checkout -q -b feat-buried main
printf 'key = %s\n' "$CANARY" > "$SHIM/buried.txt"; git -C "$SHIM" add buried.txt; git -C "$SHIM" commit -q -m "buried" --no-verify
echo "later" > "$SHIM/tip.txt"; git -C "$SHIM" add tip.txt; git -C "$SHIM" commit -q -m "clean tip" --no-verify
shim_fire "$SHIM" "$SHIM_ORIGIN" feat-buried "$(git -C "$SHIM" rev-parse HEAD)" "$ZERO"
assert_eq "real-shim buried-canary (clean tip) blocks" "1" "$RC"

# ============================================================================
# EMPTY-REMOTE bootstrap (FIX 3): first push to a genuinely refless remote via
# the real shim. This is `gh repo create` + `git push -u origin main`.
# ============================================================================
section "empty-remote (FIX 3): clean bootstrap passes and is actually scanned; dirty blocks on finding"
# clean bootstrap
BOOT="$TMP/boot-clean"
git_init_repo "$BOOT"; write_config_chain "$BOOT"
echo "readme" > "$BOOT/README.md"; git -C "$BOOT" add -A; git -C "$BOOT" commit -q -m "initial" --no-verify
git init --bare -q "$TMP/boot-clean-origin.git"            # EMPTY, never fetched
git -C "$BOOT" remote add origin "$TMP/boot-clean-origin.git"
write_shim_scaffold "$BOOT"; pc_install "$BOOT"
# Prove the over-scan range is NON-EMPTY (so "pass" means "scanned + clean", not "empty").
BOOT_RANGE_N="$(git -C "$BOOT" rev-list --count --all --not --remotes=origin)"
[[ "$BOOT_RANGE_N" -gt 0 ]] && pass "clean bootstrap over-scan range is non-empty ($BOOT_RANGE_N commit(s))" || fail "clean bootstrap over-scan range is non-empty" "count=$BOOT_RANGE_N"
shim_fire "$BOOT" "$TMP/boot-clean-origin.git" main "$(git -C "$BOOT" rev-parse HEAD)" "$ZERO"
assert_eq "clean bootstrap first push passes" "0" "$RC"

# dirty bootstrap — canary in the ROOT commit
BOOTD="$TMP/boot-dirty"
git_init_repo "$BOOTD"; write_config_chain "$BOOTD"
printf 'key = %s\n' "$CANARY" > "$BOOTD/leak.txt"; git -C "$BOOTD" add -A; git -C "$BOOTD" commit -q -m "initial" --no-verify
git init --bare -q "$TMP/boot-dirty-origin.git"
git -C "$BOOTD" remote add origin "$TMP/boot-dirty-origin.git"
write_shim_scaffold "$BOOTD"; pc_install "$BOOTD"
shim_fire "$BOOTD" "$TMP/boot-dirty-origin.git" main "$(git -C "$BOOTD" rev-parse HEAD)" "$ZERO"
assert_eq "dirty bootstrap first push blocks" "1" "$RC"
grep -q "aws-access-token" "$ERRFILE" && pass "dirty bootstrap blocks ON THE FINDING" || fail "dirty bootstrap blocks ON THE FINDING" "$(cat "$ERRFILE")"
grep -qi "cannot determine" "$ERRFILE" && fail "dirty bootstrap NOT blocked by 'cannot determine'" "wrong-reason block" || pass "dirty bootstrap not a 'cannot determine' block"

# dirty bootstrap where the TIP is NOT the root commit (canary buried below tip)
BOOTN="$TMP/boot-dirty-nonroot"
git_init_repo "$BOOTN"; write_config_chain "$BOOTN"
printf 'key = %s\n' "$CANARY" > "$BOOTN/leak.txt"; git -C "$BOOTN" add -A; git -C "$BOOTN" commit -q -m "root leak" --no-verify
echo "later" > "$BOOTN/tip.txt"; git -C "$BOOTN" add -A; git -C "$BOOTN" commit -q -m "clean tip" --no-verify
git init --bare -q "$TMP/boot-nonroot-origin.git"
git -C "$BOOTN" remote add origin "$TMP/boot-nonroot-origin.git"
write_shim_scaffold "$BOOTN"; pc_install "$BOOTN"
shim_fire "$BOOTN" "$TMP/boot-nonroot-origin.git" main "$(git -C "$BOOTN" rev-parse HEAD)" "$ZERO"
assert_eq "dirty bootstrap (canary below a clean tip) blocks" "1" "$RC"
grep -q "aws-access-token" "$ERRFILE" && pass "non-root bootstrap blocks on the finding" || fail "non-root bootstrap blocks on the finding" "$(cat "$ERRFILE")"

finish
