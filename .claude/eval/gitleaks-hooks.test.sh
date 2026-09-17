#!/usr/bin/env bash
# Test suite for the gitleaks git-lifecycle hooks and the thin shared layer
# under them:
#   git-hooks/gitleaks-pre-push.sh   (FAIL-CLOSED scan of the outgoing range)
#   git-hooks/gitleaks-commit-msg.sh (scans the commit message text)
#   git-hooks/gitleaks-staged.sh     (scans staged content only)
#   git-hooks/gitleaks-common.sh     (gl_resolve — config composition)
#
# The AUTHORITATIVE diff-scoped scan these delegate to has its own suite
# (gitleaks-range-scan.test.sh): its identity guard and its #2129/#1729
# fail-open backstops are asserted there, not re-asserted here.
#
# What this suite exists to hold down, in one line each:
#   * the pre-push hook GATES — a finding, and an unresolvable range, both block
#   * composition is gitleaks' own [extend], driven from gl_resolve's resolution
#     directory — a file of the token's name sitting in the CHECKOUT is never
#     consulted, and the repo's own rules/allowlist/.gitleaksignore still are
#   * a private repo's relaxation is declared in its OWN config
#     ([extend] disabledRules) and needs no runtime detection
#   * findings name rule ids and locations, never the matched literal
#
# Self-contained; synthetic config (never the real ruleset). Canaries: random
# AKIA + 16 [A-Z2-7], never ...EXAMPLE. No operator PII.
# Run: bash .claude/eval/gitleaks-hooks.test.sh

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/assert.sh"
source "$SCRIPT_DIR/lib/gitleaks-fixtures.sh"

HOOKS_DIR="${HOOKS_DIR:-${SCRIPT_DIR}/../../git-hooks}"
PREPUSH="$HOOKS_DIR/gitleaks-pre-push.sh"
COMMITMSG="$HOOKS_DIR/gitleaks-commit-msg.sh"
STAGED="$HOOKS_DIR/gitleaks-staged.sh"
for f in "$PREPUSH" "$COMMITMSG" "$STAGED" "$HOOKS_DIR/gitleaks-common.sh" \
         "$HOOKS_DIR/gitleaks-range-scan.sh"; do
    [[ -f "$f" ]] || { echo "FATAL: missing $f"; exit 2; }
done
# pre-commit is REQUIRED, not optional: the real-push case below is the only
# proof the hook gates an actual `git push`, and a suite that silently skips it
# would report green on a fail-open hook — the exact regression this slice fixes.
require_gitleaks_tools 1

TMP="$(mktemp -d -t gitleaks-hooks-test.XXXXXX)"
cleanup() { chmod -R u+rw "$TMP" 2>/dev/null; rm -rf "$TMP"; }
trap cleanup EXIT INT TERM
ERRFILE="$TMP/stderr.txt"
gl_fixtures_init "$TMP"

REPO="$TMP/repo"; ORIGIN="$TMP/origin.git"
git_init_repo "$REPO"
write_config_chain "$REPO"
echo "clean base" > "$REPO/base.txt"
git -C "$REPO" add base.txt .gitleaks.toml
git -C "$REPO" commit -q -m base --no-verify
CLEAN_SHA="$(git -C "$REPO" rev-parse HEAD)"
git clone -q --bare "$REPO" "$ORIGIN"; assert_repo_identity "$ORIGIN"
git -C "$REPO" remote add origin "$ORIGIN"; git -C "$REPO" fetch -q origin

run_commitmsg() {
    ( cd "$REPO" && env XDG_CONFIG_HOME="${XDG_OVERRIDE:-$XDG_CONFIG_HOME}" bash "$COMMITMSG" "$1" ) >/dev/null 2>"$ERRFILE"
    RC=$?
}
run_staged() {
    ( cd "$REPO" && env XDG_CONFIG_HOME="${XDG_OVERRIDE:-$XDG_CONFIG_HOME}" bash "$STAGED" ) >"$ERRFILE" 2>&1
    RC=$?
}
run_prepush_env() { # <from> <to>
    ( cd "$REPO" && env XDG_CONFIG_HOME="${XDG_OVERRIDE:-$XDG_CONFIG_HOME}" \
        PRE_COMMIT_FROM_REF="$1" PRE_COMMIT_TO_REF="$2" PRE_COMMIT_REMOTE_NAME="origin" \
        bash "$PREPUSH" ) >/dev/null 2>"$ERRFILE"
    RC=$?
}

CLEAN2_SHA="$(cd "$REPO" && git checkout -q -b advance main && echo "another clean line" > c2.txt && git add c2.txt && git commit -q -m advance --no-verify && git rev-parse HEAD)"
BAD_SHA="$(cd "$REPO" && git checkout -q -b bad-branch "$CLEAN_SHA" && printf 'leak %s\n' "$CANARY" > bad.txt && git add bad.txt && git commit -q -m bad --no-verify && git rev-parse HEAD)"
git -C "$REPO" checkout -q main

# ============================================================================
# FAIL-CLOSED pre-push. Every path ends in a block with a stated reason; the
# only exits with 0 are a branch deletion, an empty range, and a clean scan.
# ============================================================================
section "pre-push: a clean range passes (exit 0)"
run_prepush_env "$CLEAN_SHA" "$CLEAN2_SHA"
assert_eq "clean outgoing range exits 0" "0" "$RC"

section "pre-push (i): a secret in an outgoing commit BLOCKS, naming the rule, withholding the literal"
run_prepush_env "$CLEAN_SHA" "$BAD_SHA"
assert_eq "dirty outgoing range exits 1 (blocked)" "1" "$RC"
grep -q "aws-access-token" "$ERRFILE" && pass "block names the rule id" || fail "block names the rule id" "$(cat "$ERRFILE")"
grep -qi "BLOCKED" "$ERRFILE" && pass "block states that the push is refused" || fail "block states the refusal" "$(cat "$ERRFILE")"
grep -q "$CANARY" "$ERRFILE" && fail "block withholds the literal" "CANARY leaked!" || pass "block withholds the literal (redacted)"

section "pre-push: a branch deletion (all-zeros to-ref) is a clean pass, not an unresolved range"
run_prepush_env "$CLEAN_SHA" "0000000000000000000000000000000000000000"
assert_eq "branch deletion exits 0" "0" "$RC"

section "pre-push (ii): an unresolvable range BLOCKS with the reason (never a silent pass)"
NOUP="$TMP/no-upstream"; git_init_repo "$NOUP"; write_config_chain "$NOUP"
echo "solo" > "$NOUP/s.txt"; git -C "$NOUP" add s.txt .gitleaks.toml; git -C "$NOUP" commit -q -m base --no-verify
( cd "$NOUP" && env XDG_CONFIG_HOME="$XDG_CONFIG_HOME" bash "$PREPUSH" ) >/dev/null 2>"$ERRFILE"; RC=$?
assert_eq "no upstream and no default-branch remote ref exits 1" "1" "$RC"
grep -qi "cannot resolve the outgoing commit range" "$ERRFILE" && pass "names the unresolvable range as the cause" || fail "names the cause" "$(cat "$ERRFILE")"
grep -qi "fetch the remote\|upstream" "$ERRFILE" && pass "states how to fix it" || fail "states the fix" "$(cat "$ERRFILE")"

section "pre-push: a NEW branch with no upstream falls back to the default-branch merge-base and still gates"
NB="$TMP/newbranch"; NB_ORIGIN="$TMP/newbranch-origin.git"
git_init_repo "$NB"; write_config_chain "$NB"
echo "clean base" > "$NB/a.txt"; git -C "$NB" add a.txt .gitleaks.toml; git -C "$NB" commit -q -m base --no-verify
git clone -q --bare "$NB" "$NB_ORIGIN"; git -C "$NB" remote add origin "$NB_ORIGIN"; git -C "$NB" fetch -q origin
git -C "$NB" checkout -q -b feature
printf 'leak %s\n' "$CANARY" > "$NB/f.txt"; git -C "$NB" add f.txt; git -C "$NB" commit -q -m feat --no-verify
( cd "$NB" && env XDG_CONFIG_HOME="$XDG_CONFIG_HOME" bash "$PREPUSH" ) >/dev/null 2>"$ERRFILE"; RC=$?
assert_eq "new branch, no upstream: merge-base resolves and the secret blocks" "1" "$RC"
grep -q "aws-access-token" "$ERRFILE" && pass "new-branch fallback actually scanned the new commits" || fail "new-branch fallback scanned" "$(cat "$ERRFILE")"

section "pre-push (i, end to end): a REAL git push carrying a secret is refused and the remote ref is never created"
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
        name: gitleaks (outgoing commit-range scan)
        entry: git-hooks/gitleaks-pre-push.sh
        language: script
        pass_filenames: false
        always_run: true
        stages: [pre-push]
YAML
( cd "$FTP" && pre-commit install --install-hooks -t pre-push >/dev/null 2>&1 )
git -C "$FTP" checkout -q -b dirty main
printf 'key = %s\n' "$CANARY" > "$FTP/leak.txt"; git -C "$FTP" add leak.txt; git -C "$FTP" commit -q -m oops --no-verify
( cd "$FTP" && env XDG_CONFIG_HOME="$XDG_CONFIG_HOME" git push origin dirty ) >"$ERRFILE" 2>&1
PUSH_RC=$?
AFTER="$(git -C "$FTP_ORIGIN" rev-parse --verify refs/heads/dirty 2>/dev/null || echo ABSENT)"
[[ $PUSH_RC -ne 0 ]] && pass "the real push FAILS (the hook gates)" || fail "the real push must fail" "$(cat "$ERRFILE")"
assert_eq "the remote ref was NOT created" "ABSENT" "$AFTER"
grep -q "$CANARY" "$ERRFILE" && fail "push refusal withholds the literal" "CANARY leaked!" || pass "push refusal withholds the literal"
# Control: the same repo pushes a CLEAN branch successfully, so the case above
# is the hook blocking a finding, not the hook blocking everything.
git -C "$FTP" checkout -q -b tidy main
echo "harmless" > "$FTP/ok.txt"; git -C "$FTP" add ok.txt; git -C "$FTP" commit -q -m ok --no-verify
( cd "$FTP" && env XDG_CONFIG_HOME="$XDG_CONFIG_HOME" git push origin tidy ) >"$ERRFILE" 2>&1
CLEAN_PUSH_RC=$?
assert_eq "control: a clean branch pushes successfully" "0" "$CLEAN_PUSH_RC"

section "pre-push (iii): the overlay the repo config requires is missing — BLOCKS with the reason"
XDG_OVERRIDE="$XDG_EMPTY"; run_prepush_env "$CLEAN_SHA" "$CLEAN2_SHA"; XDG_OVERRIDE=""
assert_eq "missing operator ruleset exits 1 (fail-closed)" "1" "$RC"
grep -qi "operator ruleset is not installed" "$ERRFILE" && pass "names the not-installed ruleset and its expected path" || fail "names the missing ruleset" "$(cat "$ERRFILE")"

# ---- commit-msg hook -------------------------------------------------------
section "commit-msg (vi): a canary in the message text is blocked"
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
export GL_TEXT_FILE="$MSG_BAD"
run_commitmsg ""
assert_eq "GL_TEXT_FILE: canary text exits 1 (blocked)" "1" "$RC"
export GL_TEXT_FILE="$MSG_OK"
run_commitmsg ""
assert_eq "GL_TEXT_FILE: clean text exits 0 (passes)" "0" "$RC"
export GL_TEXT_FILE="$MSG_BAD"
run_commitmsg "$MSG_OK"
assert_eq "positional \$1 takes priority over GL_TEXT_FILE when both are set" "0" "$RC"
unset GL_TEXT_FILE
run_commitmsg "$MSG_BAD"
assert_eq "control: GL_TEXT_FILE unset behaves as before (positional \$1 alone)" "1" "$RC"

section "GL_CONFIG_PATH: overrides the config path for the commit-msg hook (trusted-lane base-ref pin)"
WIDENED_CONFIG="$TMP/widened.gitleaks.toml"
cat > "$WIDENED_CONFIG" <<EOF
title = "widened (simulates a PR's own .gitleaks.toml)"
[extend]
useDefault = true
[allowlist]
regexes = ['''$CANARY''']
EOF
PINNED_CONFIG="$TMP/pinned.gitleaks.toml"
printf 'title="pinned"\n[extend]\nuseDefault = true\n' > "$PINNED_CONFIG"
cp "$WIDENED_CONFIG" "$REPO/.gitleaks.toml"
run_commitmsg "$MSG_BAD"
assert_eq "no GL_CONFIG_PATH: the repo's own (widened) config is used, canary passes" "0" "$RC"
export GL_CONFIG_PATH="$PINNED_CONFIG"
run_commitmsg "$MSG_BAD"
assert_eq "GL_CONFIG_PATH set: the pinned config is used instead, canary blocks" "1" "$RC"
run_commitmsg "$MSG_OK"
assert_eq "GL_CONFIG_PATH set: clean text still passes" "0" "$RC"
unset GL_CONFIG_PATH
write_config_chain "$REPO"

section "GL_CONFIG_PATH + GL_NO_OVERLAY: an ABSOLUTE pinned config carrying a RELATIVE token (the trusted lane's own shape)"
# estate-gate.yml materialises the base ref's .gitleaks.toml into $RUNNER_TEMP
# and exports it as GL_CONFIG_PATH. That pinned copy still carries the
# repo-relative [extend] token, and it is nowhere near the repo — so the token
# can only resolve from gl_resolve's own resolution directory.
PINNED_TOKEN_CONFIG="$TMP/pinned-with-token.gitleaks.toml"
cat > "$PINNED_TOKEN_CONFIG" <<'EOF'
title = "pinned base-ref config (carries the repo-relative token)"
[extend]
path = ".gitleaks-operator-rules.toml"
EOF
printf 'token FIXEDPATHMARKER and key %s\n' "$CANARY" > "$TMP/pinned-probe.txt"
export GL_CONFIG_PATH="$PINNED_TOKEN_CONFIG"
GL_TEXT_FILE="$TMP/pinned-probe.txt" run_commitmsg ""
assert_eq "pinned config + overlay: the overlay marker rule fires" "1" "$RC"
grep -q "fixture-fixedpath-marker" "$ERRFILE" && pass "the relative token in an out-of-tree pinned config resolved to the installed overlay" || fail "pinned token resolved" "$(cat "$ERRFILE")"
( cd "$REPO" && env XDG_CONFIG_HOME="$XDG_CONFIG_HOME" GL_NO_OVERLAY=1 GL_CONFIG_PATH="$PINNED_TOKEN_CONFIG" \
    GL_TEXT_FILE="$TMP/pinned-probe.txt" bash "$COMMITMSG" ) >/dev/null 2>"$ERRFILE"; RC=$?
assert_eq "GL_NO_OVERLAY: the same pinned config loads and the stock rules still fire" "1" "$RC"
grep -q "aws-access-token" "$ERRFILE" && pass "GL_NO_OVERLAY keeps gitleaks' stock ruleset (useDefault through the nested extend)" || fail "GL_NO_OVERLAY keeps stock rules" "$(cat "$ERRFILE")"
grep -q "fixture-fixedpath-marker" "$ERRFILE" && fail "GL_NO_OVERLAY must NOT load operator content" "$(cat "$ERRFILE")" || pass "GL_NO_OVERLAY loads no operator content"
unset GL_CONFIG_PATH

# ---- staged hook -----------------------------------------------------------
section "staged (v): blocks a staged secret, ignores an unstaged one, fails closed without a ruleset"
git -C "$REPO" checkout -q main
echo "token FIXEDPATHMARKER staged" > "$REPO/staged-bad.txt"; git -C "$REPO" add staged-bad.txt
run_staged
assert_eq "staged marker exits 1 (blocked)" "1" "$RC"
grep -q "fixture-fixedpath-marker" "$ERRFILE" && pass "staged scan reports the overlay rule id" || fail "staged scan reports the rule id" "$(cat "$ERRFILE")"
grep -q "FIXEDPATHMARKER" "$ERRFILE" && fail "staged scan withholds the literal" "marker leaked!" || pass "staged scan withholds the literal (redacted)"
git -C "$REPO" reset -q staged-bad.txt; rm -f "$REPO/staged-bad.txt"
# The same secret, written to the tree but NEVER staged: the staged scan covers
# staged content only, so this must pass.
printf 'key %s\n' "$CANARY" > "$REPO/unstaged-bad.txt"
echo "nothing to see" > "$REPO/staged-ok.txt"; git -C "$REPO" add staged-ok.txt
run_staged
assert_eq "an UNSTAGED secret is not scanned (staged content only)" "0" "$RC"
rm -f "$REPO/unstaged-bad.txt"
XDG_OVERRIDE="$XDG_EMPTY"; run_staged; XDG_OVERRIDE=""
assert_eq "staged scan with no ruleset installed exits 1 (fail-closed)" "1" "$RC"
grep -qi "operator ruleset is not installed" "$ERRFILE" && pass "staged scan names the not-installed ruleset" || fail "staged scan names the not-installed ruleset" "$(cat "$ERRFILE")"
git -C "$REPO" reset -q staged-ok.txt; rm -f "$REPO/staged-ok.txt"

section "staged: the repo's own [allowlist] is still honoured (gl_resolve loads the repo config unmodified)"
cat > "$REPO/.gitleaks.toml" <<'EOF'
title = "fixture with allowlist"
[extend]
path = ".gitleaks-operator-rules.toml"
[allowlist]
paths = ['''allowed\.txt$''']
EOF
echo "token FIXEDPATHMARKER in an allowlisted path" > "$REPO/allowed.txt"; git -C "$REPO" add allowed.txt
run_staged
assert_eq "an allowlisted path passes" "0" "$RC"
git -C "$REPO" reset -q allowed.txt
write_config_chain "$REPO"; git -C "$REPO" add allowed.txt
run_staged
assert_eq "without the allowlist the same staged file blocks" "1" "$RC"
git -C "$REPO" reset -q allowed.txt; rm -f "$REPO/allowed.txt"; write_config_chain "$REPO"

section "staged: the repo's own .gitleaksignore is still honoured from the resolution directory"
# gitleaks' --gitleaks-ignore-path defaults to ".", which is the resolution
# directory now — so the hooks pass it explicitly. Without that, a repo's
# .gitleaksignore would be silently dropped. The fingerprint is read back from a
# real scan rather than hand-built, so this asserts the wiring, not a format guess.
echo "token FIXEDPATHMARKER ignorable" > "$REPO/ignorable.txt"; git -C "$REPO" add ignorable.txt
IGN_REPORT="$TMP/ign.json"
( cd "$XDG_CONFIG_HOME/gitleaks" && ln -sfn "$FIXED" .gitleaks-operator-rules.toml \
  && gitleaks git --staged "$REPO" --config "$REPO/.gitleaks.toml" \
       --no-banner --redact=100 --report-format json --report-path "$IGN_REPORT" ) >/dev/null 2>&1
rm -f "$XDG_CONFIG_HOME/gitleaks/.gitleaks-operator-rules.toml"
FPR="$(jq -r '.[0].Fingerprint // empty' "$IGN_REPORT" 2>/dev/null)"
if [[ -n "$FPR" ]]; then
    run_staged
    assert_eq "precondition: the staged file blocks before it is ignored" "1" "$RC"
    printf '%s\n' "$FPR" > "$REPO/.gitleaksignore"
    run_staged
    assert_eq "with a matching .gitleaksignore at the repo root, the same file passes" "0" "$RC"
    rm -f "$REPO/.gitleaksignore"
else
    fail "could not read a fingerprint to build the .gitleaksignore fixture" "report: $(cat "$IGN_REPORT" 2>/dev/null)"
fi
git -C "$REPO" reset -q ignorable.txt; rm -f "$REPO/ignorable.txt"

section "composition: a file of the token's name sitting in the CHECKOUT is never consulted"
# The retired resolver rewrote the token to an absolute path precisely because a
# leftover checkout-relative file could otherwise decide which ruleset loaded.
# Running gitleaks from the resolution directory removes that possibility
# structurally: cwd is never the checkout, so the checkout copy cannot win.
write_checkout_rules "$REPO"
echo "token SYMLINKMARKER here" > "$REPO/decoy.txt"
echo "token FIXEDPATHMARKER here" > "$REPO/real.txt"
git -C "$REPO" add decoy.txt real.txt
run_staged
assert_eq "still blocks (the installed overlay's rule fires)" "1" "$RC"
grep -q "fixture-fixedpath-marker" "$ERRFILE" && pass "the INSTALLED overlay decided the scan" || fail "installed overlay decided" "$(cat "$ERRFILE")"
grep -q "fixture-symlink-marker" "$ERRFILE" && fail "the checkout copy must never be consulted" "$(cat "$ERRFILE")" || pass "the checkout copy was not consulted"
git -C "$REPO" reset -q decoy.txt real.txt
rm -f "$REPO/decoy.txt" "$REPO/real.txt" "$REPO/.gitleaks-operator-rules.toml"

# ============================================================================
# Private-repo relaxation, declared in the repo's own config.
# ============================================================================
section "private repo (iv): a declared relaxation passes by config alone where the public config blocks"
PRIVREPO="$TMP/privrepo"; git_init_repo "$PRIVREPO"
echo "init" > "$PRIVREPO/README.md"
echo "value IDENTITYMARKER here" > "$PRIVREPO/net.txt"

write_config_chain "$PRIVREPO"          # the ordinary public shape
git -C "$PRIVREPO" add -A
( cd "$PRIVREPO" && env XDG_CONFIG_HOME="$XDG_CONFIG_HOME" bash "$STAGED" ) >"$ERRFILE" 2>&1; RC=$?
assert_eq "control: with the PUBLIC config the operator identity rule blocks" "1" "$RC"
grep -q "fixture-identity-marker" "$ERRFILE" && pass "control: fixture-identity-marker fired" || fail "control: rule fired" "$(cat "$ERRFILE")"

write_config_chain_private "$PRIVREPO"  # the same repo, declaring its relaxation
git -C "$PRIVREPO" add -A
( cd "$PRIVREPO" && env XDG_CONFIG_HOME="$XDG_CONFIG_HOME" bash "$STAGED" ) >"$ERRFILE" 2>&1; RC=$?
assert_eq "with the declared relaxation the same content passes" "0" "$RC"
grep -q "fixture-identity-marker" "$ERRFILE" && fail "fixture-identity-marker must be suppressed" "$(cat "$ERRFILE")" || pass "fixture-identity-marker suppressed by the repo's own config"

section "private repo: the relaxation is SURGICAL — every other rule stays active"
echo "value FIXEDPATHMARKER here" > "$PRIVREPO/other.txt"
git -C "$PRIVREPO" add -A
( cd "$PRIVREPO" && env XDG_CONFIG_HOME="$XDG_CONFIG_HOME" bash "$STAGED" ) >"$ERRFILE" 2>&1; RC=$?
assert_eq "an unrelated overlay rule still blocks" "1" "$RC"
grep -q "fixture-fixedpath-marker" "$ERRFILE" && pass "the unrelated overlay rule is still active" || fail "unrelated rule active" "$(cat "$ERRFILE")"
printf 'key %s\n' "$CANARY" > "$PRIVREPO/cred.txt"; git -C "$PRIVREPO" add -A
( cd "$PRIVREPO" && env XDG_CONFIG_HOME="$XDG_CONFIG_HOME" bash "$STAGED" ) >"$ERRFILE" 2>&1
grep -q "aws-access-token" "$ERRFILE" && pass "credential-class rules are untouched by the relaxation" || fail "credential rules active" "$(cat "$ERRFILE")"
rm -f "$PRIVREPO/other.txt" "$PRIVREPO/cred.txt"; git -C "$PRIVREPO" add -A

section "private repo: the declaration also loads cleanly when NO overlay is present (the CI base-rules lane)"
# A rule-id + allowlist override does not survive this: gitleaks refuses the
# config with "both |regex| and |path| are empty" when the extended layer that
# DEFINES the rule is absent. disabledRules does, which is why it is the shape.
printf 'key %s\n' "$CANARY" > "$PRIVREPO/cred.txt"; git -C "$PRIVREPO" add -A
( cd "$PRIVREPO" && env XDG_CONFIG_HOME="$XDG_CONFIG_HOME" GL_NO_OVERLAY=1 bash "$STAGED" ) >"$ERRFILE" 2>&1; RC=$?
grep -qE 'FTL|Failed to load config|both \|regex\|' "$ERRFILE" && fail "the declaration must load cleanly with no overlay" "$(cat "$ERRFILE")" || pass "the declaration loads cleanly with no overlay"
assert_eq "GL_NO_OVERLAY: the credential canary still blocks on a private repo" "1" "$RC"
grep -q "aws-access-token" "$ERRFILE" && pass "GL_NO_OVERLAY on a private repo keeps every credential class" || fail "credential class kept" "$(cat "$ERRFILE")"

section "composition: there is no runtime private-repo detection left to bypass"
# The retired mechanism read .house-code.json and dotty's declared map, then
# called `gh` live. None of that can influence a scan any more: a repo that
# merely CLAIMS private, without declaring the relaxation in its own config,
# gets no relaxation at all.
CLAIMREPO="$TMP/claimrepo"; git_init_repo "$CLAIMREPO"; write_config_chain "$CLAIMREPO"
git -C "$CLAIMREPO" remote add origin "git@github.com:fixtureorg/fixture-private-repo.git"
printf '{"private_repo": true}\n' > "$CLAIMREPO/.house-code.json"
echo "value IDENTITYMARKER here" > "$CLAIMREPO/net.txt"
git -C "$CLAIMREPO" add -A
( cd "$CLAIMREPO" && env XDG_CONFIG_HOME="$XDG_CONFIG_HOME" bash "$STAGED" ) >"$ERRFILE" 2>&1; RC=$?
assert_eq "a .house-code.json private_repo claim alone grants nothing" "1" "$RC"
grep -q "fixture-identity-marker" "$ERRFILE" && pass "the claim did not suppress the operator identity rule" || fail "claim granted a relaxation" "$(cat "$ERRFILE")"
grep -rqi 'gh api\|house-code-common\|private_repo' "$HOOKS_DIR/gitleaks-common.sh" && fail "gitleaks-common.sh still carries private-repo detection" "$(grep -n 'gh api\|house-code-common\|private_repo' "$HOOKS_DIR/gitleaks-common.sh")" || pass "gitleaks-common.sh carries no private-repo detection and no live gh call"

finish
