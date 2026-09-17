#!/usr/bin/env bash
# Test suite for the gitleaks git-lifecycle hooks that REMAIN after the
# diff-scoped-CI-floor slice:
#   git-hooks/gitleaks-pre-push.sh   (now a THIN ADVISORY local heads-up — never blocks)
#   git-hooks/gitleaks-commit-msg.sh (unchanged)
#   git-hooks/gitleaks-staged.sh     (unchanged)
#   git-hooks/gitleaks-common.sh     (gl_scan_tree_at + gl_apply_private_profile)
#
# The AUTHORITATIVE diff-scoped scan (gitleaks-range-scan.sh) has its own suite
# (gitleaks-range-scan.test.sh). The old pre-push hook's blocking
# range/native-stdin/cross-remote/whole-tree behavior was retired with that
# hook's demotion and is covered there or deliberately removed (Cluster A).
#
# Self-contained; synthetic config (never the real ruleset); no `git push`
# except one control that proves the advisory hook does NOT block a push.
# Canaries: random AKIA + 16 [A-Z2-7], never ...EXAMPLE. No operator PII.
# Run: bash .claude/eval/gitleaks-hooks.test.sh

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/assert.sh"
source "$SCRIPT_DIR/lib/gitleaks-fixtures.sh"

HOOKS_DIR="${HOOKS_DIR:-${SCRIPT_DIR}/../../git-hooks}"
PREPUSH="$HOOKS_DIR/gitleaks-pre-push.sh"
COMMITMSG="$HOOKS_DIR/gitleaks-commit-msg.sh"
STAGED="$HOOKS_DIR/gitleaks-staged.sh"
for f in "$PREPUSH" "$COMMITMSG" "$STAGED" "$HOOKS_DIR/gitleaks-common.sh"; do
    [[ -f "$f" ]] || { echo "FATAL: missing $f"; exit 2; }
done
require_gitleaks_tools 0

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

# ============================================================================
# THIN ADVISORY pre-push: a best-effort local heads-up that NEVER blocks.
# The authoritative gate is the CI range scan; this hook must not be able to
# false-block a push (the exact failure the demotion removes). It prints a
# finding heads-up to stderr but always exits 0.
# ============================================================================
run_prepush_env() { # <from> <to>
    ( cd "$REPO" && env XDG_CONFIG_HOME="${XDG_OVERRIDE:-$XDG_CONFIG_HOME}" \
        PRE_COMMIT_FROM_REF="$1" PRE_COMMIT_TO_REF="$2" PRE_COMMIT_REMOTE_NAME="origin" \
        bash "$PREPUSH" ) >/dev/null 2>"$ERRFILE"
    RC=$?
}
CLEAN2_SHA="$(cd "$REPO" && git checkout -q -b advance main && echo "another clean line" > c2.txt && git add c2.txt && git commit -q -m advance --no-verify && git rev-parse HEAD)"
BAD_SHA="$(cd "$REPO" && git checkout -q -b bad-branch "$CLEAN_SHA" && printf 'leak %s\n' "$CANARY" > bad.txt && git add bad.txt && git commit -q -m bad --no-verify && git rev-parse HEAD)"
git -C "$REPO" checkout -q main

section "advisory pre-push: a clean range passes (exit 0)"
run_prepush_env "$CLEAN_SHA" "$CLEAN2_SHA"
assert_eq "advisory pre-push clean exits 0" "0" "$RC"

section "advisory pre-push: a DIRTY range still exits 0 (advisory) but prints a heads-up"
run_prepush_env "$CLEAN_SHA" "$BAD_SHA"
assert_eq "advisory pre-push dirty STILL exits 0 (never blocks)" "0" "$RC"
grep -qiE 'advisory|heads-up|CI is the authoritative gate|aws-access-token' "$ERRFILE" && pass "prints a local heads-up on a finding" || fail "prints a local heads-up" "$(cat "$ERRFILE")"
grep -q "$CANARY" "$ERRFILE" && fail "advisory heads-up withholds the literal" "CANARY leaked!" || pass "advisory heads-up withholds the literal (redacted)"

section "advisory pre-push: an unresolvable local base exits 0 with a notice (never blocks)"
NOUP="$TMP/no-upstream"; git_init_repo "$NOUP"; write_config_chain "$NOUP"
echo "solo" > "$NOUP/s.txt"; git -C "$NOUP" add s.txt .gitleaks.toml; git -C "$NOUP" commit -q -m base --no-verify
( cd "$NOUP" && env XDG_CONFIG_HOME="$XDG_CONFIG_HOME" bash "$PREPUSH" ) >/dev/null 2>"$ERRFILE"; RC=$?
assert_eq "advisory pre-push with no resolvable base exits 0" "0" "$RC"
grep -qi "could not resolve a local base\|skipping" "$ERRFILE" && pass "notes the unresolvable base (CI will scan)" || fail "notes the unresolvable base" "$(cat "$ERRFILE")"

section "advisory pre-push: a real dirty push is NOT blocked by the hook (control — the demotion)"
FTP="$TMP/ft-push"; FTP_ORIGIN="$TMP/ft-push-origin.git"
git_init_repo "$FTP"; write_config_chain "$FTP"
echo "clean base" > "$FTP/a.txt"; git -C "$FTP" add a.txt .gitleaks.toml; git -C "$FTP" commit -q -m base --no-verify
git clone -q --bare "$FTP" "$FTP_ORIGIN"; git -C "$FTP" remote add origin "$FTP_ORIGIN"; git -C "$FTP" fetch -q origin
mkdir -p "$FTP/git-hooks"; cp "$HOOKS_DIR"/gitleaks-*.sh "$HOOKS_DIR"/house-code-common.sh "$FTP/git-hooks/"; chmod +x "$FTP/git-hooks/"*.sh
cat > "$FTP/.pre-commit-config.yaml" <<'YAML'
default_install_hook_types: [pre-commit, pre-push, commit-msg]
default_stages: [pre-commit]
repos:
  - repo: local
    hooks:
      - id: gitleaks-pre-push
        name: gitleaks (advisory pre-push)
        entry: git-hooks/gitleaks-pre-push.sh
        language: script
        pass_filenames: false
        always_run: true
        stages: [pre-push]
YAML
if command -v pre-commit >/dev/null 2>&1; then
    ( cd "$FTP" && pre-commit install --install-hooks -t pre-push >/dev/null 2>&1 )
    git -C "$FTP" checkout -q -b dirty main
    printf 'key = %s\n' "$CANARY" > "$FTP/leak.txt"; git -C "$FTP" add leak.txt; git -C "$FTP" commit -q -m oops --no-verify
    ( cd "$FTP" && env XDG_CONFIG_HOME="$XDG_CONFIG_HOME" git push -q origin dirty ) >/dev/null 2>&1
    PUSH_RC=$?
    AFTER="$(git -C "$FTP_ORIGIN" rev-parse --verify refs/heads/dirty 2>/dev/null || echo ABSENT)"
    assert_eq "advisory hook does NOT block the push (push succeeds)" "0" "$( [[ $PUSH_RC -eq 0 ]] && echo 0 || echo 1 )"
    [[ "$AFTER" != "ABSENT" ]] && pass "the remote ref was created (advisory hook let the push through)" || fail "push should have succeeded (advisory)" "ref absent"
else
    pass "advisory-hook real-push control skipped (pre-commit not installed) — direct-invocation cases above already prove the never-block posture"
fi
git -C "$REPO" checkout -q main 2>/dev/null || true

# ---- commit-msg hook (unchanged) -------------------------------------------
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

# ---- staged hook (unchanged) -----------------------------------------------
section "staged (g): gitleaks-staged.sh blocks a staged marker, passes clean, fails closed without a ruleset"
git -C "$REPO" checkout -q main
echo "token FIXEDPATHMARKER staged" > "$REPO/staged-bad.txt"; git -C "$REPO" add staged-bad.txt
run_staged
assert_eq "staged marker exits 1 (blocked)" "1" "$RC"
grep -q "fixture-fixedpath-marker" "$ERRFILE" && pass "staged scan reports the fixed-path rule id" || fail "staged scan reports the fixed-path rule id" "$(cat "$ERRFILE")"
grep -q "FIXEDPATHMARKER" "$ERRFILE" && fail "staged scan withholds the literal" "marker leaked!" || pass "staged scan withholds the literal (redacted)"
git -C "$REPO" reset -q staged-bad.txt; rm -f "$REPO/staged-bad.txt"
echo "nothing to see" > "$REPO/staged-ok.txt"; git -C "$REPO" add staged-ok.txt
run_staged
assert_eq "clean staged file exits 0 (passes)" "0" "$RC"
XDG_OVERRIDE="$XDG_EMPTY"; run_staged; XDG_OVERRIDE=""
assert_eq "staged scan with no ruleset anywhere exits 1 (fail-closed)" "1" "$RC"
grep -qi "operator ruleset is not installed" "$ERRFILE" && pass "staged scan names the not-installed ruleset" || fail "staged scan names the not-installed ruleset" "$(cat "$ERRFILE")"
git -C "$REPO" reset -q staged-ok.txt; rm -f "$REPO/staged-ok.txt"

section "staged: gl_preflight HONORS the repo's own [allowlist] (the staged/commit-msg contract)"
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
# gl_scan_tree_at — the shared whole-tree scan primitive (gitleaks-common.sh).
# No live caller currently (its one caller, gitleaks-resident-scan.sh, was
# retired); this suite is what exercises it directly.
# Direct-function test: clean tree -> 0, planted canary -> 1 with a redacted report.
# ============================================================================
section "gl_scan_tree_at: clean tree returns 0; canary tree returns 1 (redacted); base+overlay via gl_mandatory_preflight"
GST="$TMP/gst"; git_init_repo "$GST"
echo "nothing to see here" > "$GST/a.txt"; git -C "$GST" add a.txt; git -C "$GST" commit -q -m base --no-verify
GST_CLEAN="$(git -C "$GST" rev-parse HEAD)"
( source "$HOOKS_DIR/gitleaks-common.sh"
  gl_mandatory_preflight || { echo "PREFLIGHT_FAILED"; exit 9; }
  gl_scan_tree_at "$GST" "$TMP/gst-clean.json" "$GST_CLEAN"; echo "clean_rc=$?" ) >"$ERRFILE" 2>&1
grep -q 'clean_rc=0' "$ERRFILE" && pass "gl_scan_tree_at: clean HEAD tree returns 0" || fail "gl_scan_tree_at: clean HEAD tree returns 0" "$(cat "$ERRFILE")"
printf 'k = %s\n' "$CANARY" > "$GST/secret.txt"; git -C "$GST" add secret.txt; git -C "$GST" commit -q -m dirty --no-verify
GST_DIRTY="$(git -C "$GST" rev-parse HEAD)"
( source "$HOOKS_DIR/gitleaks-common.sh"
  gl_mandatory_preflight || { echo "PREFLIGHT_FAILED"; exit 9; }
  gl_scan_tree_at "$GST" "$TMP/gst-dirty.json" "$GST_DIRTY"; echo "dirty_rc=$?"
  command -v jq >/dev/null 2>&1 && echo "rules=$(jq -r '[.[].RuleID]|join(",")' "$TMP/gst-dirty.json" 2>/dev/null)"
  grep -q "$CANARY" "$TMP/gst-dirty.json" && echo "LEAKED" || echo "redacted" ) >"$ERRFILE" 2>&1
grep -q 'dirty_rc=1' "$ERRFILE" && pass "gl_scan_tree_at: canary tree returns 1 (findings)" || fail "gl_scan_tree_at: canary tree returns 1" "$(cat "$ERRFILE")"
grep -q 'rules=aws-access-token' "$ERRFILE" && pass "gl_scan_tree_at: report names the rule id" || fail "gl_scan_tree_at: report names the rule id" "$(cat "$ERRFILE")"
grep -q 'redacted' "$ERRFILE" && pass "gl_scan_tree_at: matched value redacted in the report" || fail "gl_scan_tree_at: value redacted" "$(cat "$ERRFILE")"

# ============================================================================
# Private-repo profile (gl_apply_private_profile) via the STAGED hook — unchanged
# by this slice. Disables ONLY operator-network-domain-1, live-verified, never a
# path-scoped allowlist. Mirrors house-code.test.sh's stubbed-`gh` pattern.
# ============================================================================
section "private-repo profile: verified-private disables operator-network-domain-1 only"
STUBBIN="$TMP/stubbin-gl"; mkdir -p "$STUBBIN"
cat > "$STUBBIN/gh" <<'STUBEOF'
#!/usr/bin/env bash
if [[ "$1" == "api" && "$2" == "repos/fixtureorg/fixture-private-repo" ]]; then echo "private"; exit 0; fi
if [[ "$1" == "api" && "$2" == "repos/fixtureorg/fixture-public-repo" ]]; then echo "public"; exit 0; fi
echo "STUB: unexpected gh invocation: $*" >&2; exit 90
STUBEOF
chmod +x "$STUBBIN/gh"

PRIVREPO="$TMP/privrepo"; git_init_repo "$PRIVREPO"; write_config_chain "$PRIVREPO"
git -C "$PRIVREPO" remote add origin "git@github.com:fixtureorg/fixture-private-repo.git"
echo "init" > "$PRIVREPO/README.md"; git -C "$PRIVREPO" add -A && git -C "$PRIVREPO" commit -q -m init --no-verify
printf '{"private_repo": true}\n' > "$PRIVREPO/.house-code.json"
echo "value NETWORKDOMAINMARKER here" > "$PRIVREPO/net.txt"
echo "value FIXEDPATHMARKER here" > "$PRIVREPO/other.txt"
git -C "$PRIVREPO" add -A
( cd "$PRIVREPO" && env PATH="$STUBBIN:$PATH" XDG_CONFIG_HOME="$XDG_CONFIG_HOME" bash "$STAGED" ) >"$ERRFILE" 2>&1; RC=$?
assert_eq "verified private repo: still blocks (another rule still fires)" "1" "$RC"
grep -q "fixture-fixedpath-marker" "$ERRFILE" && pass "verified private: unrelated rule (fixedpath-marker) still active" || fail "verified private: unrelated rule active" "$(cat "$ERRFILE")"
grep -q "operator-network-domain-1" "$ERRFILE" && fail "verified private: operator-network-domain-1 must be suppressed" "$(cat "$ERRFILE")" || pass "verified private: operator-network-domain-1 suppressed"

PUBREPO="$TMP/pubrepo"; git_init_repo "$PUBREPO"; write_config_chain "$PUBREPO"
git -C "$PUBREPO" remote add origin "git@github.com:fixtureorg/fixture-public-repo.git"
echo "init" > "$PUBREPO/README.md"; git -C "$PUBREPO" add -A && git -C "$PUBREPO" commit -q -m init --no-verify
printf '{"private_repo": true}\n' > "$PUBREPO/.house-code.json"
echo "value NETWORKDOMAINMARKER here" > "$PUBREPO/net.txt"
git -C "$PUBREPO" add -A
( cd "$PUBREPO" && env PATH="$STUBBIN:$PATH" XDG_CONFIG_HOME="$XDG_CONFIG_HOME" bash "$STAGED" ) >"$ERRFILE" 2>&1; RC=$?
assert_eq "declared private but live-verified PUBLIC: profile not applied, still blocks" "1" "$RC"
grep -q "operator-network-domain-1" "$ERRFILE" && pass "verified-public: operator-network-domain-1 stays active" || fail "verified-public: rule stays active" "$(cat "$ERRFILE")"

NOVERIFYREPO="$TMP/noverifyrepo"; git_init_repo "$NOVERIFYREPO"; write_config_chain "$NOVERIFYREPO"
git -C "$NOVERIFYREPO" remote add origin "git@github.com:fixtureorg/fixture-unknown-repo.git"
echo "init" > "$NOVERIFYREPO/README.md"; git -C "$NOVERIFYREPO" add -A && git -C "$NOVERIFYREPO" commit -q -m init --no-verify
printf '{"private_repo": true}\n' > "$NOVERIFYREPO/.house-code.json"
echo "value NETWORKDOMAINMARKER here" > "$NOVERIFYREPO/net.txt"
git -C "$NOVERIFYREPO" add -A
( cd "$NOVERIFYREPO" && env PATH="$STUBBIN:$PATH" XDG_CONFIG_HOME="$XDG_CONFIG_HOME" bash "$STAGED" ) >"$ERRFILE" 2>&1; RC=$?
assert_eq "declared private, verification errors: fails toward NOT private, still blocks" "1" "$RC"
grep -q "operator-network-domain-1" "$ERRFILE" && pass "unverifiable: operator-network-domain-1 stays active (fail stricter)" || fail "unverifiable: rule stays active" "$(cat "$ERRFILE")"

section "private profile: gh-not-found and jq-not-found branches are LOUD; resolver needs no python3"
LOUD="$TMP/loud-priv"; git_init_repo "$LOUD"; write_config_chain "$LOUD"
git -C "$LOUD" remote add origin "git@github.com:fixtureorg/fixture-private-repo.git"
echo "init" > "$LOUD/README.md"; git -C "$LOUD" add -A && git -C "$LOUD" commit -q -m init --no-verify
printf '{"private_repo": true}\n' > "$LOUD/.house-code.json"
echo "value NETWORKDOMAINMARKER here" > "$LOUD/net.txt"
git -C "$LOUD" add -A
( cd "$LOUD" && env PATH="$STUBBIN:$PATH" GH="/nonexistent/gh-does-not-exist" XDG_CONFIG_HOME="$XDG_CONFIG_HOME" bash "$STAGED" ) >"$ERRFILE" 2>&1; RC=$?
assert_eq "gh-not-found on a declared-private repo: still blocks (overlay kept)" "1" "$RC"
grep -qi "gh not found" "$ERRFILE" && pass "gh-not-found branch prints its one clear line" || fail "gh-not-found notice" "$(cat "$ERRFILE")"
grep -q "operator-network-domain-1" "$ERRFILE" && pass "gh-not-found: operator identity rule kept active" || fail "gh-not-found: rule kept" "$(cat "$ERRFILE")"

MINBIN="$TMP/minbin"; mkdir -p "$MINBIN"
for t in bash sh env jq git gitleaks mktemp cat grep sed awk rm cp mv ln dirname basename sort tr head tail wc chmod mkdir touch date od sleep kill expr id uniq comm; do
  p="$(command -v "$t" 2>/dev/null || true)"; [[ -n "$p" ]] && ln -sf "$p" "$MINBIN/$t"
done
ln -sf "$STUBBIN/gh" "$MINBIN/gh"
( PATH="$MINBIN" command -v python3 >/dev/null 2>&1 ) && fail "minimal-PATH sanity: python3 must be ABSENT" "python3 present" || pass "minimal-PATH sanity: python3 absent"
( cd "$LOUD" && env PATH="$MINBIN" HOME="$HOME" XDG_CONFIG_HOME="$XDG_CONFIG_HOME" bash "$STAGED" ) >"$ERRFILE" 2>&1
grep -q "operator-network-domain-1" "$ERRFILE" && fail "minimal-PATH: profile did NOT resolve" "$(cat "$ERRFILE")" || pass "minimal-PATH (no python3): private profile RESOLVES, operator-network-domain-1 suppressed"
rm -f "$MINBIN/jq"
( cd "$LOUD" && env PATH="$MINBIN" HOME="$HOME" XDG_CONFIG_HOME="$XDG_CONFIG_HOME" bash "$STAGED" ) >"$ERRFILE" 2>&1
grep -qi "jq not found" "$ERRFILE" && pass "jq-not-found branch prints its one clear line" || fail "jq-not-found notice" "$(cat "$ERRFILE")"

section "private profile: dotty's declared MAP (no .house-code.json) resolves private; undeclared does not"
MAPBIN="$TMP/mapstub"; mkdir -p "$MAPBIN"
cat > "$MAPBIN/gh" <<'STUBEOF'
#!/usr/bin/env bash
case "${2:-}" in
    repos/fixtureorg/fixture-map-private)    echo "private"; exit 0 ;;
    repos/fixtureorg/fixture-map-undeclared) echo "private"; exit 0 ;;
esac
echo "STUB: unexpected gh invocation: $*" >&2; exit 90
STUBEOF
chmod +x "$MAPBIN/gh"
MAPJSON="$TMP/declared-map.json"
printf '{"repos": {"fixtureorg/fixture-map-private": {"private_repo": true}}}\n' > "$MAPJSON"
MAPREPO="$TMP/maprepo"; git_init_repo "$MAPREPO"; write_config_chain "$MAPREPO"
git -C "$MAPREPO" remote add origin "git@github.com:fixtureorg/fixture-map-private.git"
echo "value NETWORKDOMAINMARKER here" > "$MAPREPO/net.txt"
echo "value FIXEDPATHMARKER here" > "$MAPREPO/other.txt"
git -C "$MAPREPO" add -A
[[ -f "$MAPREPO/.house-code.json" ]] && fail "map precondition: repo must have NO .house-code.json" "it has one" || pass "map precondition: repo has no .house-code.json"
( cd "$MAPREPO" && env PATH="$MAPBIN:$PATH" GL_DECLARED_JSON="$MAPJSON" XDG_CONFIG_HOME="$XDG_CONFIG_HOME" bash "$STAGED" ) >"$ERRFILE" 2>&1; RC=$?
assert_eq "map-declared (no .house-code.json): still blocks (an unrelated rule fires)" "1" "$RC"
grep -q "operator-network-domain-1" "$ERRFILE" && fail "map-declared: operator-network-domain-1 must be suppressed" "$(cat "$ERRFILE")" || pass "map-declared: operator-network-domain-1 suppressed via the map source"
grep -q "fixture-fixedpath-marker" "$ERRFILE" && pass "map-declared: an unrelated rule still fires" || fail "map-declared: unrelated rule fires" "$(cat "$ERRFILE")"

UNDREPO="$TMP/undrepo"; git_init_repo "$UNDREPO"; write_config_chain "$UNDREPO"
git -C "$UNDREPO" remote add origin "git@github.com:fixtureorg/fixture-map-undeclared.git"
echo "value NETWORKDOMAINMARKER here" > "$UNDREPO/net.txt"
git -C "$UNDREPO" add -A
( cd "$UNDREPO" && env PATH="$MAPBIN:$PATH" GL_DECLARED_JSON="$MAPJSON" XDG_CONFIG_HOME="$XDG_CONFIG_HOME" bash "$STAGED" ) >"$ERRFILE" 2>&1; RC=$?
assert_eq "undeclared (not in map, no .house-code.json): blocks" "1" "$RC"
grep -q "operator-network-domain-1" "$ERRFILE" && pass "undeclared: operator-network-domain-1 stays active (declaration gates, not gh)" || fail "undeclared: rule stays active" "$(cat "$ERRFILE")"

finish
