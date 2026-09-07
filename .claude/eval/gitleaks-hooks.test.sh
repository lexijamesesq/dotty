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
#     one) with NO checkout-relative rules file — there is no checkout-relative
#     fallback; the file appears only to prove it is NEVER consulted, even when
#     it names a different ruleset than the fixed path;
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
# for "no ruleset installed at the fixed path" (via XDG_OVERRIDE) — there is no
# checkout-relative fallback to fall through to.
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
[[rules]]
id = "operator-network-domain-1"
description = "stands in for the real public-disclosure rule the private-repo profile disables (test only)"
regex = '''NETWORKDOMAINMARKER'''
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
# Never consulted (in the estate, a gitignored symlink) — written only to prove
# precedence: it carries a DIFFERENT marker, so a case can show the fixed path
# wins even when this file exists and names a different ruleset.
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
    assert_repo_identity "$1"
    # noreply address: the pre-push identity guard (scrubbed-email-resurfacing class) blocks any
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
git clone -q --bare "$REPO" "$ORIGIN"; assert_repo_identity "$ORIGIN"  # origin/main = CLEAN_SHA (no push)
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
# dir by default, XDG_EMPTY when a case sets XDG_OVERRIDE to prove the
# not-installed fail-closed path (no checkout-relative fallback to catch it).
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

# ---- identity guard: non-noreply email in the range blocks ------------------
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
git clone -q --bare "$XR" "$TMP/xr-origin.git"; assert_repo_identity "$TMP/xr-origin.git"  # origin has the canary commit on main
git -C "$XR" remote add origin "$TMP/xr-origin.git"; git -C "$XR" fetch -q origin
git init --bare -q -b main "$TMP/xr-upstream.git"; assert_repo_identity "$TMP/xr-upstream.git"  # upstream is empty
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
# This used to pass (the commit is already published on origin, so
# the not-yet-pushed RANGE is empty). The widened tracked-HEAD-tree scan
# (Done When 5) now also runs on every push, independent of publication
# history — and $XR_LEAK's tree still literally contains the canary. That is
# the gap this widening exists to close: a resident secret is not made safe
# by having been pushed once already. The cross-remote assertion this
# section exists for (the ORIGIN exclusion isn't hardcoded — see FIX 1 above)
# is unaffected; only this control's own expectation was stale.
assert_eq "control push-to-origin now blocks too (tree-scan finds the resident canary)" "1" "$?"
# The full-tree backstop reports counts + commit ids only (no rule id, no
# filename — either can carry a secret), so assert that shape, not a rule id.
grep -qiE 'outgoing commit trees|finding' "$ERRFILE" && pass "control push-to-origin: blocked on the tree scan, not a range regression" || fail "control push-to-origin: blocked on the tree scan, not a range regression" "$(cat "$ERRFILE")"
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
# CHANGED (config independence): the pre-push full-tree backstop uses the
# operator overlay directly, so a PR-authored [allowlist] does NOT suppress it —
# it blocks regardless. gl_preflight STILL honors the repo allowlist for the
# staged/commit-msg hooks; that is proven in the staged section below.
assert_eq "pre-push: a repo [allowlist] does NOT suppress the backstop (blocks)" "1" "$RC"
write_config_chain "$REPO"
run_env "$CLEAN_SHA" "$ALLOW_SHA"
assert_eq "control: also blocks without the allowlist" "1" "$RC"

section "useDefault-only config (no operator extend) passes through unchanged"
cat > "$REPO/.gitleaks.toml" <<'EOF'
title = "fixture, base rules only"
[extend]
useDefault = true
EOF
run_env "$CLEAN_SHA" "$BAD_SHA"
assert_eq "base rules still fire (canary blocked)" "1" "$RC"
run_env "$CLEAN_SHA" "$MARK_SHA"
# CHANGED (config independence): the differential layer honors a useDefault-only
# repo config (no overlay injected), but the pre-push backstop applies the
# operator overlay directly in local mode, so the overlay marker DOES fire and
# the push blocks. (Under GL_NO_OVERLAY the backstop is base-only — proven in the
# GL_NO_OVERLAY section, where the marker correctly does not fire.)
assert_eq "pre-push: the operator overlay marker fires via the backstop (blocks)" "1" "$RC"
write_config_chain "$REPO"

section "GL_NO_OVERLAY: base rules only, repo's own extend token left untouched on disk"
# Unlike the useDefault-only fixture above, this repo's REAL .gitleaks.toml
# (write_config_chain, just restored) still carries the relative extend
# TOKEN — GL_NO_OVERLAY must substitute the extend TARGET via gl_preflight,
# never require the repo to declare useDefault itself.
export GL_NO_OVERLAY=1
run_env "$CLEAN_SHA" "$BAD_SHA"
assert_eq "GL_NO_OVERLAY: base rules still fire (canary blocked)" "1" "$RC"
run_env "$CLEAN_SHA" "$MARK_SHA"
assert_eq "GL_NO_OVERLAY: operator marker (fixed-path only) does NOT fire" "0" "$RC"
# Same allowlist fixture as the case above, now under GL_NO_OVERLAY — proves
# the repo's own [allowlist] survives the synthetic-extend rewrite exactly as
# it survives the real fixed-path rewrite (same gl_rewrite_extend call).
cat > "$REPO/.gitleaks.toml" <<'EOF'
title = "fixture with allowlist"
[extend]
path = ".gitleaks-operator-rules.toml"
[allowlist]
paths = ['''allowed\.txt$''']
EOF
run_env "$CLEAN_SHA" "$ALLOW_SHA"
assert_eq "GL_NO_OVERLAY: allowlisted path still passes" "0" "$RC"
unset GL_NO_OVERLAY
run_env "$CLEAN_SHA" "$ALLOW_SHA"
# CHANGED (config independence): with GL_NO_OVERLAY unset (local mode) the
# backstop applies the overlay and ignores the repo [allowlist], so it blocks —
# the mirror of the GL_NO_OVERLAY case above, which correctly passes the
# overlay-marker-only content because the overlay is not applied there.
assert_eq "control: GL_NO_OVERLAY unset -> backstop applies overlay, ignores repo allowlist (blocks)" "1" "$RC"
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

section "GL_TEXT_FILE: named-env-var alternative source, positional \$1 contract unchanged"
# run_commitmsg "" passes an EMPTY positional $1 (pre-commit never does this
# locally — it always supplies a real path) so the script's own
# "${1:-${GL_TEXT_FILE:-}}" falls through to the env var, exactly as a CI
# caller (branch name / PR title / PR body / a looped commit message) would.
export GL_TEXT_FILE="$MSG_BAD"
run_commitmsg ""
assert_eq "GL_TEXT_FILE: canary text exits 1 (blocked)" "1" "$RC"
export GL_TEXT_FILE="$MSG_OK"
run_commitmsg ""
assert_eq "GL_TEXT_FILE: clean text exits 0 (passes)" "0" "$RC"
# Positional $1 still wins when both are present — GL_TEXT_FILE never
# overrides pre-commit's own real argument, only fills in when it's absent.
export GL_TEXT_FILE="$MSG_BAD"
run_commitmsg "$MSG_OK"
assert_eq "positional \$1 takes priority over GL_TEXT_FILE when both are set" "0" "$RC"
unset GL_TEXT_FILE
run_commitmsg "$MSG_BAD"
assert_eq "control: GL_TEXT_FILE unset behaves as before (positional \$1 alone)" "1" "$RC"

# ============================================================================
# GL_CONFIG_PATH: a pressure-test finding on the live trusted lane. Only
# gitleaks-pre-push.sh consumed this override; gitleaks-commit-msg.sh (and
# gitleaks-staged.sh) still hardcoded ".gitleaks.toml", so a PR widening its
# OWN config silently un-pinned the trusted lane's base-rules pass over
# commit messages, branch name, PR title, and PR body -- exactly the surfaces
# this script covers. Proven live: identical canary, a clean vs a
# PR-widened-allowlist config, clean blocked / widened passed green. This
# section is the reason the eval suite didn't catch it the first time: zero
# prior cases here ever set GL_CONFIG_PATH.
# ============================================================================
section "GL_CONFIG_PATH: overrides the config path (the fix for the trusted-lane finding above)"
WIDENED_CONFIG="$TMP/widened.gitleaks.toml"
cat > "$WIDENED_CONFIG" <<EOF
title = "widened (simulates a PR's own .gitleaks.toml)"
[extend]
useDefault = true
[allowlist]
regexes = ['''$CANARY''']
EOF
PINNED_CONFIG="$TMP/pinned.gitleaks.toml"
cat > "$PINNED_CONFIG" <<'EOF'
title = "pinned (simulates the base ref's real config)"
[extend]
useDefault = true
EOF

# Baseline: $REPO's OWN config is the widened one, GL_CONFIG_PATH unset.
# Not itself a bug -- there is no "base ref" concept for a local/native run --
# this just proves the default (no override) still resolves the repo's own
# file, so the override case below is a genuine A/B, not a tautology.
cp "$WIDENED_CONFIG" "$REPO/.gitleaks.toml"
run_commitmsg "$MSG_BAD"
assert_eq "no GL_CONFIG_PATH: the repo's own (widened) config is used, canary passes" "0" "$RC"

# The fix: GL_CONFIG_PATH points at the pinned copy instead -- the widened
# repo config is never consulted, canary blocks.
export GL_CONFIG_PATH="$PINNED_CONFIG"
run_commitmsg "$MSG_BAD"
assert_eq "GL_CONFIG_PATH set: the pinned config is used instead, canary blocks" "1" "$RC"
run_commitmsg "$MSG_OK"
assert_eq "GL_CONFIG_PATH set: clean text still passes" "0" "$RC"
unset GL_CONFIG_PATH
write_config_chain "$REPO"   # restore $REPO's normal fixed-path-extending config

section "GL_CONFIG_PATH: same override, gitleaks-pre-push.sh (had the fix already -- this closes ITS coverage gap too)"
cp "$WIDENED_CONFIG" "$REPO/.gitleaks.toml"
run_env "$CLEAN_SHA" "$BAD_SHA"
# CHANGED (config independence): even with no GL_CONFIG_PATH, the pre-push
# backstop uses the fixed overlay (not the repo's widened config), so the canary
# blocks. The GL_CONFIG_PATH A/B for the differential/config-resolution layer is
# proven via the commit-msg hook above (which has no backstop).
assert_eq "no GL_CONFIG_PATH: the backstop's fixed overlay catches the canary regardless (blocks)" "1" "$RC"
export GL_CONFIG_PATH="$PINNED_CONFIG"
run_env "$CLEAN_SHA" "$BAD_SHA"
assert_eq "GL_CONFIG_PATH set: the pinned config is used instead, bad range blocks" "1" "$RC"
run_env "$CLEAN_SHA" "$CLEAN2_SHA"
assert_eq "GL_CONFIG_PATH set: clean range still passes" "0" "$RC"
unset GL_CONFIG_PATH
write_config_chain "$REPO"

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
grep -qi "operator ruleset is not installed" "$ERRFILE" && pass "staged scan names the not-installed ruleset" || fail "staged scan names the not-installed ruleset" "$(cat "$ERRFILE")"
git -C "$REPO" reset -q staged-ok.txt; rm -f "$REPO/staged-ok.txt"

section "staged: gl_preflight HONORS the repo's own [allowlist] (the staged/commit-msg contract the pre-push backstop deliberately does not share)"
cat > "$REPO/.gitleaks.toml" <<'EOF'
title = "fixture with allowlist"
[extend]
path = ".gitleaks-operator-rules.toml"
[allowlist]
paths = ['''allowed\.txt$''']
EOF
echo "token FIXEDPATHMARKER in an allowlisted path" > "$REPO/allowed.txt"; git -C "$REPO" add allowed.txt
run_staged
assert_eq "staged: an allowlisted path passes (gl_preflight preserves the repo allowlist)" "0" "$RC"
git -C "$REPO" reset -q allowed.txt
write_config_chain "$REPO"; git -C "$REPO" add allowed.txt
run_staged
assert_eq "staged: without the allowlist the same staged file blocks" "1" "$RC"
git -C "$REPO" reset -q allowed.txt; rm -f "$REPO/allowed.txt"; write_config_chain "$REPO"

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
git clone -q --bare "$SHIM" "$SHIM_ORIGIN"; assert_repo_identity "$SHIM_ORIGIN"  # origin has base on main (no push)
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
git init --bare -q -b main "$TMP/boot-clean-origin.git"; assert_repo_identity "$TMP/boot-clean-origin.git"  # EMPTY, never fetched
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
git init --bare -q -b main "$TMP/boot-dirty-origin.git"; assert_repo_identity "$TMP/boot-dirty-origin.git"
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
git init --bare -q -b main "$TMP/boot-nonroot-origin.git"; assert_repo_identity "$TMP/boot-nonroot-origin.git"
git -C "$BOOTN" remote add origin "$TMP/boot-nonroot-origin.git"
write_shim_scaffold "$BOOTN"; pc_install "$BOOTN"
shim_fire "$BOOTN" "$TMP/boot-nonroot-origin.git" main "$(git -C "$BOOTN" rev-parse HEAD)" "$ZERO"
assert_eq "dirty bootstrap (canary below a clean tip) blocks" "1" "$RC"
grep -q "aws-access-token" "$ERRFILE" && pass "non-root bootstrap blocks on the finding" || fail "non-root bootstrap blocks on the finding" "$(cat "$ERRFILE")"

# ============================================================================
# The receipted gap the two widened ranges close ("Done When 5"):
#
# A push already on the remote is never rescanned by the ORIGINAL
# not-yet-pushed range (count 0 -> scan_logopts quietly no-ops), and it is
# STILL never rescanned by the new whole-branch-vs-default range for the
# identical reason (default branch == tip == 0 commits between them). Only
# the tracked-HEAD-TREE scan (content, not history) has no "nothing new"
# escape hatch: it re-reads the actual files at the tip on every single
# invocation. This is the exact scenario named in the ticket: a value
# published once, then made forbidden by a LATER ruleset change, resurfaces
# on a subsequent push with no new commits.
# ============================================================================
section "resident content survives a ruleset change until the tree scan (not the range scans)"

RESIDENT="$TMP/resident"; RESIDENT_ORIGIN="$TMP/resident-origin.git"
git_init_repo "$RESIDENT"; write_config_chain "$RESIDENT"
echo "clean base" > "$RESIDENT/base.txt"; git -C "$RESIDENT" add -A; git -C "$RESIDENT" commit -q -m base --no-verify
git init --bare -q -b main "$RESIDENT_ORIGIN"; assert_repo_identity "$RESIDENT_ORIGIN"
git -C "$RESIDENT" remote add origin "$RESIDENT_ORIGIN"
write_shim_scaffold "$RESIDENT"; pc_install "$RESIDENT"
shim_fire "$RESIDENT" "$RESIDENT_ORIGIN" main "$(git -C "$RESIDENT" rev-parse HEAD)" "$ZERO"
assert_eq "resident: clean base push passes" "0" "$RC"
git -C "$RESIDENT" push -q origin main   # advance the real remote so origin/main tracks it

# A value the CURRENT fixed ruleset does not flag — plain text, no gitleaks
# default rule matches this shape, and the fixture's marker rule names a
# different literal (FIXEDPATHMARKER).
NOT_YET_FORBIDDEN="RESIDENT-LEGACY-VALUE-9f3c1a"
printf 'legacy_value = "%s"\n' "$NOT_YET_FORBIDDEN" > "$RESIDENT/legacy.txt"
git -C "$RESIDENT" add -A; git -C "$RESIDENT" commit -q -m "legacy value, not yet forbidden" --no-verify
LEGACY_SHA="$(git -C "$RESIDENT" rev-parse HEAD)"
shim_fire "$RESIDENT" "$RESIDENT_ORIGIN" main "$LEGACY_SHA" "$(git -C "$RESIDENT" rev-parse origin/main)"
assert_eq "resident: pushes clean under the OLD ruleset (value not yet forbidden)" "0" "$RC"
git -C "$RESIDENT" push -q origin main   # publish it — now resident on the remote AND in the tree

# The ruleset changes: the fixed-path rules gain a rule for that value.
cat >> "$FIXED" <<EOF
[[rules]]
id = "fixture-resident-legacy-rule"
description = "marker added AFTER the legacy value was already published (test only)"
regex = '''${NOT_YET_FORBIDDEN}'''
EOF

# "A second push with no new commits": re-fire the hook with remote-sha ==
# tip-sha (nothing new relative to the remote — the exact condition a real
# `git push` would not even invoke a hook for, and precisely the condition
# the original not-yet-pushed range scan silently no-ops on). The whole-
# branch-vs-default range is ALSO empty here for the same reason (default
# branch already equals the tip) — only the tracked-tree scan has no empty-
# range escape hatch.
shim_fire "$RESIDENT" "$RESIDENT_ORIGIN" main "$LEGACY_SHA" "$LEGACY_SHA"
assert_eq "resident: second push (no new commits) now BLOCKS under the new ruleset" "1" "$RC"
# The full-tree backstop reports counts + commit ids only (no rule id, no
# filename), and it is the layer that now catches a resident secret with no new
# commit (the tip's own tree is materialized unconditionally).
grep -qiE '[0-9]+ finding|outgoing commit' "$ERRFILE" && pass "resident: blocked with a finding count (counts+ids only)" || fail "resident: blocked with a finding count" "$(cat "$ERRFILE")"
grep -qi "outgoing commit trees" "$ERRFILE" && pass "resident: names the full-tree scan as the layer that caught it" || fail "resident: names the full-tree scan as the layer that caught it" "$(cat "$ERRFILE")"
if [[ "$(cat "$ERRFILE")" == *"$NOT_YET_FORBIDDEN"* ]]; then
    fail "resident: never prints the matched value" "$(cat "$ERRFILE")"
else
    pass "resident: never prints the matched value"
fi

# ============================================================================
# Private-repo profile (gl_apply_private_profile): disables ONLY
# operator-network-domain-1, live-verified, never a path-scoped allowlist.
# Mirrors house-code.test.sh's stubbed-`gh` pattern.
# ============================================================================
section "private-repo profile: verified-private disables operator-network-domain-1 only"

STUBBIN="$TMP/stubbin-gl"; mkdir -p "$STUBBIN"
cat > "$STUBBIN/gh" <<'STUBEOF'
#!/usr/bin/env bash
if [[ "$1" == "api" && "$2" == "repos/fixtureorg/fixture-private-repo" ]]; then
    echo "private"; exit 0
fi
if [[ "$1" == "api" && "$2" == "repos/fixtureorg/fixture-public-repo" ]]; then
    echo "public"; exit 0
fi
echo "STUB: unexpected gh invocation: $*" >&2; exit 90
STUBEOF
chmod +x "$STUBBIN/gh"

PRIVREPO="$TMP/privrepo"; mkdir -p "$PRIVREPO"
git_init_repo "$PRIVREPO"
write_config_chain "$PRIVREPO"
git -C "$PRIVREPO" remote add origin "git@github.com:fixtureorg/fixture-private-repo.git"
echo "init" > "$PRIVREPO/README.md"
git -C "$PRIVREPO" add -A && git -C "$PRIVREPO" commit -q -m init --no-verify
cat > "$PRIVREPO/.house-code.json" <<'EOF'
{"private_repo": true}
EOF
echo "value NETWORKDOMAINMARKER here" > "$PRIVREPO/net.txt"
echo "value FIXEDPATHMARKER here" > "$PRIVREPO/other.txt"
git -C "$PRIVREPO" add -A

( cd "$PRIVREPO" && env PATH="$STUBBIN:$PATH" XDG_CONFIG_HOME="$XDG_CONFIG_HOME" bash "$STAGED" ) >"$ERRFILE" 2>&1
RC=$?
assert_eq "verified private repo: still blocks (another rule still fires)" "1" "$RC"
grep -q "fixture-fixedpath-marker" "$ERRFILE" && pass "verified private repo: unrelated rule (fixedpath-marker) still active" || fail "verified private repo: unrelated rule still active" "$(cat "$ERRFILE")"
grep -q "operator-network-domain-1" "$ERRFILE" && fail "verified private repo: operator-network-domain-1 must be suppressed" "$(cat "$ERRFILE")" || pass "verified private repo: operator-network-domain-1 suppressed"

PUBREPO="$TMP/pubrepo"; mkdir -p "$PUBREPO"
git_init_repo "$PUBREPO"
write_config_chain "$PUBREPO"
git -C "$PUBREPO" remote add origin "git@github.com:fixtureorg/fixture-public-repo.git"
echo "init" > "$PUBREPO/README.md"
git -C "$PUBREPO" add -A && git -C "$PUBREPO" commit -q -m init --no-verify
cat > "$PUBREPO/.house-code.json" <<'EOF'
{"private_repo": true}
EOF
echo "value NETWORKDOMAINMARKER here" > "$PUBREPO/net.txt"
git -C "$PUBREPO" add -A
( cd "$PUBREPO" && env PATH="$STUBBIN:$PATH" XDG_CONFIG_HOME="$XDG_CONFIG_HOME" bash "$STAGED" ) >"$ERRFILE" 2>&1
RC=$?
assert_eq "declared private but live-verified PUBLIC: profile not applied, still blocks" "1" "$RC"
grep -q "operator-network-domain-1" "$ERRFILE" && pass "verified-public repo: operator-network-domain-1 stays active" || fail "verified-public repo: operator-network-domain-1 stays active" "$(cat "$ERRFILE")"

NOVERIFYREPO="$TMP/noverifyrepo"; mkdir -p "$NOVERIFYREPO"
git_init_repo "$NOVERIFYREPO"
write_config_chain "$NOVERIFYREPO"
git -C "$NOVERIFYREPO" remote add origin "git@github.com:fixtureorg/fixture-unknown-repo.git"
echo "init" > "$NOVERIFYREPO/README.md"
git -C "$NOVERIFYREPO" add -A && git -C "$NOVERIFYREPO" commit -q -m init --no-verify
cat > "$NOVERIFYREPO/.house-code.json" <<'EOF'
{"private_repo": true}
EOF
echo "value NETWORKDOMAINMARKER here" > "$NOVERIFYREPO/net.txt"
git -C "$NOVERIFYREPO" add -A
( cd "$NOVERIFYREPO" && env PATH="$STUBBIN:$PATH" XDG_CONFIG_HOME="$XDG_CONFIG_HOME" bash "$STAGED" ) >"$ERRFILE" 2>&1
RC=$?
assert_eq "declared private, verification errors (unknown repo): fails toward NOT private, still blocks" "1" "$RC"
grep -q "operator-network-domain-1" "$ERRFILE" && pass "unverifiable repo: operator-network-domain-1 stays active (fail toward stricter)" || fail "unverifiable repo: operator-network-domain-1 stays active" "$(cat "$ERRFILE")"

# ============================================================================
# GL_BASE_REF: CI already knows the PR's base branch as a workflow fact — no
# reason for the widen scan to resolve it over the network. The gap this
# closes: actions/checkout never writes refs/remotes/<remote>/HEAD, and a
# trusted-lane checkout runs with persist-credentials: false, so on a
# private repo BOTH of default_branch_ref()'s fallbacks (local symref, then
# `git ls-remote --symref`) fail once the job's token is gone — the widen
# scan then BLOCKs "cannot resolve the default branch" unconditionally,
# regardless of content. An unreachable local path stands in for that
# unreachable/de-credentialed remote without needing a real network fixture.
# ============================================================================
section "GL_BASE_REF: CI-supplied base ref bypasses local/network resolution"

BASEREPO="$TMP/baseref-repo"
git_init_repo "$BASEREPO"
write_config_chain "$BASEREPO"
echo "clean base" > "$BASEREPO/base.txt"
git -C "$BASEREPO" add -A; git -C "$BASEREPO" commit -q -m base --no-verify
BASEREF_CLEAN_SHA="$(git -C "$BASEREPO" rev-parse HEAD)"
printf 'another clean line\n' >> "$BASEREPO/base.txt"
git -C "$BASEREPO" add -A; git -C "$BASEREPO" commit -q -m advance --no-verify
BASEREF_TIP_SHA="$(git -C "$BASEREPO" rev-parse HEAD)"
# Never created — models a remote actions/checkout fetched from but can no
# longer reach (private repo, credential dropped after checkout).
git -C "$BASEREPO" remote add origin "$TMP/baseref-origin-unreachable.git"

run_baseref() { # <from> <to> [gl_base_ref]
    ( cd "$BASEREPO" && env PATH="$PATH" XDG_CONFIG_HOME="${XDG_OVERRIDE:-$XDG_CONFIG_HOME}" \
        PRE_COMMIT_FROM_REF="$1" PRE_COMMIT_TO_REF="$2" \
        PRE_COMMIT_REMOTE_NAME="origin" PRE_COMMIT_REMOTE_BRANCH="refs/heads/test" \
        GL_BASE_REF="${3:-}" \
        bash "$PREPUSH" </dev/null ) >/dev/null 2>"$ERRFILE"
    RC=$?
}

run_baseref "$BASEREF_CLEAN_SHA" "$BASEREF_TIP_SHA" ""
assert_eq "control: unreachable remote, no GL_BASE_REF -> fails closed (cannot resolve default branch)" "1" "$RC"
grep -q "cannot resolve the default branch" "$ERRFILE" && pass "control: names the real gap (not a content finding)" || fail "control: names the real gap" "$(cat "$ERRFILE")"

run_baseref "$BASEREF_CLEAN_SHA" "$BASEREF_TIP_SHA" "$BASEREF_CLEAN_SHA"
assert_eq "GL_BASE_REF supplied: unreachable remote never consulted, clean range passes" "0" "$RC"
grep -q "cannot resolve the default branch" "$ERRFILE" && fail "GL_BASE_REF: must not touch default-branch resolution at all" "$(cat "$ERRFILE")" || pass "GL_BASE_REF: default-branch resolution never attempted"

run_baseref "$BASEREF_CLEAN_SHA" "$BASEREF_TIP_SHA" "not-a-real-ref-xyz"
assert_eq "GL_BASE_REF garbage value: fails closed (unresolvable range), never silently passes" "1" "$RC"
grep -qi "unresolvable commit range" "$ERRFILE" && pass "GL_BASE_REF garbage: reports the real problem (unresolvable range), not a false clean" || fail "GL_BASE_REF garbage: reports the real problem" "$(cat "$ERRFILE")"

# ============================================================================
# GL_OVERLAY_ONLY: the trusted lane's private-pattern-only scan, standalone
# from the base-rules scan. Proves the fix for a real, live-verified bypass:
# under the fixed-path config's normal useDefault=true, a PR-chosen filename
# matching gitleaks' stock global allowlist (a common binary/doc extension,
# node_modules/, a lockfile, ...) makes ANY content in that file invisible to
# the operator overlay too, since the allowlist is inherited along with the
# stock ruleset. GL_OVERLAY_ONLY flips useDefault to false on a standalone
# copy of the fixed-path config -- no stock ruleset, no stock allowlist,
# operator [[rules]] only.
# ============================================================================
section "GL_OVERLAY_ONLY: standalone operator overlay, no inherited stock ruleset or allowlist"

OVERLAY_TEST="$TMP/overlay-only-test"
mkdir -p "$OVERLAY_TEST"
echo "value FIXEDPATHMARKER here" > "$OVERLAY_TEST/plain.txt"
echo "value FIXEDPATHMARKER here" > "$OVERLAY_TEST/leak.png"
mkdir -p "$OVERLAY_TEST/node_modules"
echo "value FIXEDPATHMARKER here" > "$OVERLAY_TEST/node_modules/leak.txt"

run_gl_preflight() { # <config>
    ( source "$HOOKS_DIR/gitleaks-common.sh"
      gl_preflight "$1" || exit 1
      echo "EFFECTIVE_CONFIG=$GL_EFFECTIVE_CONFIG"
      echo "RULES_SOURCE=$GL_RULES_SOURCE"
      cat "$GL_EFFECTIVE_CONFIG"
    )
}

# gl_preflight fail-closed when the fixed path is absent, under GL_OVERLAY_ONLY too.
XDG_OVERRIDE="$XDG_EMPTY"
OUT="$(GL_OVERLAY_ONLY=1 XDG_CONFIG_HOME="$XDG_OVERRIDE" run_gl_preflight "$REPO/.gitleaks.toml" 2>"$ERRFILE")"; RC=$?
assert_eq "GL_OVERLAY_ONLY: fixed path absent -> BLOCK, no fallback" "1" "$RC"
grep -q "operator ruleset is not installed" "$ERRFILE" && pass "GL_OVERLAY_ONLY: names the real gap" || fail "GL_OVERLAY_ONLY: names the real gap" "$(cat "$ERRFILE")"
XDG_OVERRIDE=""

# The rewrite itself: useDefault flips to false, the fixture's own [[rules]] survive.
OUT="$(GL_OVERLAY_ONLY=1 run_gl_preflight "$REPO/.gitleaks.toml" 2>"$ERRFILE")"; RC=$?
assert_eq "GL_OVERLAY_ONLY: preflight succeeds against the installed fixed-path fixture" "0" "$RC"
echo "$OUT" | grep -q "^useDefault = false$" && pass "GL_OVERLAY_ONLY: useDefault rewritten to false" || fail "GL_OVERLAY_ONLY: useDefault rewritten to false" "$OUT"
echo "$OUT" | grep -q "fixture-fixedpath-marker" && pass "GL_OVERLAY_ONLY: the fixture's own [[rules]] survive the rewrite" || fail "GL_OVERLAY_ONLY: fixture rules survive" "$OUT"

# The actual bypass this closes, proven with a real gitleaks scan of the same
# three files under each config shape.
EFFECTIVE_OVERLAY_ONLY="$(GL_OVERLAY_ONLY=1 run_gl_preflight "$REPO/.gitleaks.toml" 2>/dev/null | sed -n 's/^EFFECTIVE_CONFIG=//p')"
gitleaks detect --no-git --source "$OVERLAY_TEST" --config "$EFFECTIVE_OVERLAY_ONLY" --no-banner --report-format json --report-path "$TMP/overlay-report.json" >/dev/null 2>&1
CAUGHT="$(python3 -c "import json; print(sorted(set(f['File'] for f in json.load(open('$TMP/overlay-report.json')))))" 2>/dev/null)"
echo "$CAUGHT" | grep -q "plain.txt" && pass "GL_OVERLAY_ONLY: plain-named file caught" || fail "GL_OVERLAY_ONLY: plain-named file caught" "$CAUGHT"
echo "$CAUGHT" | grep -q "leak.png" && pass "GL_OVERLAY_ONLY: .png-named file ALSO caught (the bypass this closes)" || fail "GL_OVERLAY_ONLY: .png-named file caught" "$CAUGHT"
echo "$CAUGHT" | grep -q "node_modules" && pass "GL_OVERLAY_ONLY: node_modules/ file ALSO caught" || fail "GL_OVERLAY_ONLY: node_modules/ file caught" "$CAUGHT"

EFFECTIVE_NORMAL="$(run_gl_preflight "$REPO/.gitleaks.toml" 2>/dev/null | sed -n 's/^EFFECTIVE_CONFIG=//p')"
gitleaks detect --no-git --source "$OVERLAY_TEST" --config "$EFFECTIVE_NORMAL" --no-banner --report-format json --report-path "$TMP/normal-report.json" >/dev/null 2>&1
CAUGHT_NORMAL="$(python3 -c "import json; print(sorted(set(f['File'] for f in json.load(open('$TMP/normal-report.json')))))" 2>/dev/null)"
echo "$CAUGHT_NORMAL" | grep -q "leak.png" && fail "control: normal (useDefault=true) config should NOT catch leak.png" "$CAUGHT_NORMAL" || pass "control: normal config demonstrates the original bypass (leak.png NOT caught)"

rm -f "$TMP/overlay-report.json" "$TMP/normal-report.json"

# ============================================================================
# Native full-tree scanner (step 3): the config-independent backstop's own
# Done When clauses — full tree of every outgoing commit (blobs read directly,
# no export-ignore blind spot), raw message, destination ref name; ancestry off
# the advertised remote_sha; refuse on missing/malformed overlay or a scanner
# crash; counts and commit ids only. Repo-config independence and the
# GL_NO_OVERLAY / GL_CONFIG_PATH lane matrix are covered in the sections above.
# ============================================================================
MISSING_SHA="deadbeefdeadbeefdeadbeefdeadbeefdeadbeef"
XDG_BAD="$TMP/xdg-bad"; mkdir -p "$XDG_BAD/gitleaks"
printf 'this = not [[ valid toml\n' > "$XDG_BAD/gitleaks/operator-rules.toml"
git -C "$REPO" checkout -q main

section "full-tree: a secret in an INTERMEDIATE commit's tree, scrubbed at the tip, is caught [finding 2: sha-sharded, not path-keyed]"
git -C "$REPO" checkout -q -b ft-inter "$CLEAN_SHA"
printf 'k = %s\n' "$CANARY" > "$REPO/secret.py"; git -C "$REPO" add secret.py; git -C "$REPO" commit -q -m "add secret" --no-verify
printf 'k = SCRUBBED\n' > "$REPO/secret.py"; git -C "$REPO" add secret.py; git -C "$REPO" commit -q -m "scrub at same path" --no-verify
FT_TIP="$(git -C "$REPO" rev-parse HEAD)"
git -C "$REPO" checkout -q main
run_stdin "refs/heads/ft-inter $FT_TIP refs/heads/ft-inter $CLEAN_SHA"
assert_eq "intermediate secret scrubbed at the tip still blocks" "1" "$RC"
grep -qi "outgoing commit trees" "$ERRFILE" && pass "the full-tree scan caught it (sha-sharding preserved the intermediate blob)" || fail "the full-tree scan caught it" "$(cat "$ERRFILE")"
grep -q "$CANARY" "$ERRFILE" && fail "canary withheld (counts+ids only)" "leaked!" || pass "canary withheld (counts+ids only)"

section "full-tree: a secret only in a commit MESSAGE is blocked at pre-push (distinct from the commit-msg hook)"
git -C "$REPO" checkout -q -b ft-msg "$CLEAN_SHA"
echo "ordinary content" > "$REPO/mm.txt"; git -C "$REPO" add mm.txt
git -C "$REPO" commit -q -m "leftover key $CANARY in the message" --no-verify
FTM_TIP="$(git -C "$REPO" rev-parse HEAD)"
git -C "$REPO" checkout -q main
run_stdin "refs/heads/ft-msg $FTM_TIP refs/heads/ft-msg $CLEAN_SHA"
assert_eq "commit-message secret blocks at pre-push" "1" "$RC"
grep -qi "commit messages" "$ERRFILE" && pass "named the message scan" || fail "named the message scan" "$(cat "$ERRFILE")"

section "full-tree: a secret in the DESTINATION REF NAME is blocked (clean content)"
run_stdin "refs/heads/leak-$CANARY $CLEAN2_SHA refs/heads/leak-$CANARY $CLEAN_SHA"
assert_eq "ref-name secret blocks" "1" "$RC"
grep -qi "ref names" "$ERRFILE" && pass "named the ref-name scan" || fail "named the ref-name scan" "$(cat "$ERRFILE")"
grep -q "$CANARY" "$ERRFILE" && fail "ref-name withheld from output" "leaked!" || pass "ref-name withheld from output"

section "full-tree: EXPORT-IGNORE blind spot closed — cat-file reads what git archive would skip (resident, no new commit)"
FTEXP="$TMP/ft-exportignore"; FTEXP_ORIGIN="$TMP/ft-exportignore-origin.git"
git_init_repo "$FTEXP"; write_config_chain "$FTEXP"
printf 'k = %s\n' "$CANARY" > "$FTEXP/hidden.txt"
printf 'hidden.txt export-ignore\n' > "$FTEXP/.gitattributes"
git -C "$FTEXP" add hidden.txt .gitattributes .gitleaks.toml; git -C "$FTEXP" commit -q -m "resident export-ignored secret" --no-verify
FTEXP_TIP="$(git -C "$FTEXP" rev-parse HEAD)"
git clone -q --bare "$FTEXP" "$FTEXP_ORIGIN"; git -C "$FTEXP" remote add origin "$FTEXP_ORIGIN"; git -C "$FTEXP" fetch -q origin
ARCH="$TMP/ft-arch"; mkdir -p "$ARCH"; git -C "$FTEXP" archive "$FTEXP_TIP" | tar -x -C "$ARCH" 2>/dev/null
[[ -f "$ARCH/hidden.txt" ]] && fail "control: git archive should OMIT the export-ignored file" "present" || pass "control: git archive omits it (the blind spot a git-archive tree scan had)"
( cd "$FTEXP" && printf 'refs/heads/main %s refs/heads/main %s\n' "$FTEXP_TIP" "$FTEXP_TIP" \
    | env XDG_CONFIG_HOME="$XDG_CONFIG_HOME" bash "$PREPUSH" origin "$FTEXP_ORIGIN" ) >"$ERRFILE" 2>&1
assert_eq "re-push (no new commits): cat-file full-tree scan catches the resident export-ignored secret" "1" "$?"
grep -qi "outgoing commit trees" "$ERRFILE" && pass "caught by the full-tree tip-tree scan, not the differential range" || fail "caught by the full-tree tip-tree scan" "$(cat "$ERRFILE")"
rm -rf "$ARCH"

section "full-tree: missing overlay refuses; malformed overlay refuses (local mode)"
XDG_OVERRIDE="$XDG_EMPTY"; run_env "$CLEAN_SHA" "$CLEAN2_SHA"; XDG_OVERRIDE=""
assert_eq "missing overlay: local push refuses" "1" "$RC"
XDG_OVERRIDE="$XDG_BAD"; run_env "$CLEAN_SHA" "$CLEAN2_SHA"; XDG_OVERRIDE=""
assert_eq "malformed overlay: refuses" "1" "$RC"
grep -qiE 'overlay failed to load|config failed to load|Failed to load config' "$ERRFILE" && pass "malformed overlay named" || fail "malformed overlay named" "$(cat "$ERRFILE")"

section "full-tree: a scanner crash refuses (wholly broken binary, and a crash on the content scan)"
mkdir -p "$TMP/stub-dead"; printf '#!/bin/sh\necho "panic: broken" >&2\nexit 2\n' > "$TMP/stub-dead/gitleaks"; chmod +x "$TMP/stub-dead/gitleaks"
run_env "$CLEAN_SHA" "$CLEAN2_SHA" "origin" "$TMP/stub-dead:$PATH"
assert_eq "wholly broken gitleaks refuses" "1" "$RC"
mkdir -p "$TMP/stub-batch"
cat > "$TMP/stub-batch/gitleaks" <<'STUB'
#!/bin/sh
src=""; prev=""
for a in "$@"; do [ "$prev" = "--source" ] && src="$a"; prev="$a"; done
if [ -n "$src" ] && [ -n "$(ls -A "$src" 2>/dev/null)" ]; then echo "panic: simulated crash" >&2; exit 2; fi
exit 0
STUB
chmod +x "$TMP/stub-batch/gitleaks"
run_env "$CLEAN_SHA" "$CLEAN2_SHA" "origin" "$TMP/stub-batch:$PATH"
assert_eq "content-scan crash refuses (batch backstop, survives the empty-dir preflight probe)" "1" "$RC"
grep -qi "scanner error" "$ERRFILE" && pass "named the content-scan crash" || fail "named the content-scan crash" "$(cat "$ERRFILE")"

section "full-tree: ancestry — force-push over-scans (never refuses); shallow/missing remote object refuses"
run_stdin "refs/heads/advance $CLEAN2_SHA refs/heads/advance $BAD_SHA"
assert_eq "force-push, clean tip: over-scan passes (a rewrite is not refused)" "0" "$RC"
run_stdin "refs/heads/bad-branch $BAD_SHA refs/heads/bad-branch $CLEAN2_SHA"
assert_eq "force-push over a rewrite still catches a secret in the tip's history" "1" "$RC"
run_stdin "refs/heads/advance $CLEAN2_SHA refs/heads/advance $MISSING_SHA"
assert_eq "missing remote object refuses (never trusts an unverifiable range)" "1" "$RC"
grep -qi "remote object missing" "$ERRFILE" && pass "named the missing-object refusal" || fail "named the missing-object refusal" "$(cat "$ERRFILE")"

section "full-tree: a blocked push leaves the remote ref UNCHANGED (genuine local push, hook installed)"
FTP="$TMP/ft-push"; FTP_ORIGIN="$TMP/ft-push-origin.git"
git_init_repo "$FTP"; write_config_chain "$FTP"
echo "clean base" > "$FTP/a.txt"; git -C "$FTP" add a.txt .gitleaks.toml; git -C "$FTP" commit -q -m base --no-verify
git clone -q --bare "$FTP" "$FTP_ORIGIN"; git -C "$FTP" remote add origin "$FTP_ORIGIN"; git -C "$FTP" fetch -q origin
mkdir -p "$FTP/git-hooks"; cp "$HOOKS_DIR"/gitleaks-*.sh "$FTP/git-hooks/"; chmod +x "$FTP/git-hooks/"*.sh
cat > "$FTP/.pre-commit-config.yaml" <<'YAML'
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
( cd "$FTP" && pre-commit install --install-hooks -t pre-push >/dev/null 2>&1 )
git -C "$FTP" checkout -q -b dirty main
printf 'key = %s\n' "$CANARY" > "$FTP/leak.txt"; git -C "$FTP" add leak.txt; git -C "$FTP" commit -q -m "oops" --no-verify
FTP_BEFORE="$(git -C "$FTP_ORIGIN" rev-parse --verify refs/heads/dirty 2>/dev/null || echo ABSENT)"
( cd "$FTP" && env XDG_CONFIG_HOME="$XDG_CONFIG_HOME" git push -q origin dirty ) >/dev/null 2>&1
FTP_PUSH_RC=$?
FTP_AFTER="$(git -C "$FTP_ORIGIN" rev-parse --verify refs/heads/dirty 2>/dev/null || echo ABSENT)"
assert_eq "the dirty push is rejected (non-zero)" "1" "$( [[ $FTP_PUSH_RC -ne 0 ]] && echo 1 || echo 0 )"
assert_eq "the remote ref never came into existence" "ABSENT" "$FTP_AFTER"
[[ "$FTP_BEFORE" == "ABSENT" ]] && pass "remote ref absent before and after the blocked push" || fail "remote ref state" "before=$FTP_BEFORE after=$FTP_AFTER"

git -C "$REPO" checkout -q main

finish
