#!/usr/bin/env bash
# Test suite for git-hooks/gitleaks-resident-scan.sh — the SCHEDULED
# default-branch resident secret/PII backstop (Option A: the whole-tree coverage
# relocated OFF the per-push path). Covers:
#   * public profile (GATE_SKIP_OVERLAY=0): base+overlay -> catches resident
#     operator-PII (overlay-class marker) AND a base credential;
#   * private profile (GATE_SKIP_OVERLAY=1): base-only -> does NOT re-flag the
#     overlay-class marker (incident #2's false-positive fix) but STILL catches
#     a base credential;
#   * a clean tree passes under both profiles;
#   * export-ignore-hidden resident content is still caught (cat-file, not
#     git-archive — the blind spot gl_scan_tree_at closes);
#   * a repo [allowlist] does NOT suppress the backstop (it scans under
#     GL_MANDATORY_CONFIG, not the repo's PR-controlled config);
#   * missing / malformed overlay refuses (fail-closed);
#   * findings output is de-duped, repo-relative `rule<TAB>file:line`, value
#     withheld (the structured payload the operator issue carries).
#
# Self-contained; synthetic overlay; no network. Canaries: random AKIA + 16
# [A-Z2-7], never ...EXAMPLE. No operator PII.
# Run: bash .claude/eval/gitleaks-resident-scan.test.sh

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/assert.sh"
source "$SCRIPT_DIR/lib/gitleaks-fixtures.sh"

HOOKS_DIR="${HOOKS_DIR:-${SCRIPT_DIR}/../../git-hooks}"
RESIDENT="$HOOKS_DIR/gitleaks-resident-scan.sh"
[[ -f "$RESIDENT" ]] || { echo "FATAL: missing $RESIDENT"; exit 2; }
require_gitleaks_tools 0

TMP="$(mktemp -d -t gitleaks-resident-test.XXXXXX)"
cleanup() { chmod -R u+rw "$TMP" 2>/dev/null; rm -rf "$TMP"; }
trap cleanup EXIT INT TERM
ERRFILE="$TMP/stderr.txt"; OUTFILE="$TMP/stdout.txt"
gl_fixtures_init "$TMP"

# run_resident <skip:0|1> <repo> — capture stdout (findings) + stderr + RC.
run_resident() {
    ( env XDG_CONFIG_HOME="${XDG_OVERRIDE:-$XDG_CONFIG_HOME}" \
        GATE_SKIP_OVERLAY="$1" GL_RESIDENT_REPO="$2" \
        bash "$RESIDENT" ) >"$OUTFILE" 2>"$ERRFILE"
    RC=$?
}
# mk_repo <dir> — an initialized repo with a clean base commit. Caller adds files.
mk_repo() { git_init_repo "$1"; echo "clean base" > "$1/base.txt"; git -C "$1" add base.txt; git -C "$1" commit -q -m base --no-verify; }
commit_all() { git -C "$1" add -A; git -C "$1" commit -q -m "$2" --no-verify; }

# ---- overlay-class content: public catches, private does NOT re-flag ---------
section "public profile catches resident overlay-class content (operator-network-domain-1)"
R1="$TMP/r-overlay"; mk_repo "$R1"
echo "value NETWORKDOMAINMARKER resident" > "$R1/net.txt"; commit_all "$R1" net
run_resident 0 "$R1"
assert_eq "public: overlay-class content exits 1 (caught)" "1" "$RC"
grep -q "operator-network-domain-1" "$OUTFILE" && pass "public: reports the overlay rule id" || fail "public: overlay rule id" "$(cat "$OUTFILE"; cat "$ERRFILE")"

section "private profile does NOT re-flag the overlay-class content (incident #2 false-positive fix)"
run_resident 1 "$R1"
assert_eq "private: overlay-class content exits 0 (overlay pass skipped, not re-flagged)" "0" "$RC"
grep -q "operator-network-domain-1" "$OUTFILE" && fail "private: overlay rule must NOT fire" "$(cat "$OUTFILE")" || pass "private: overlay rule not fired (base-only)"

# ---- base credential: caught under BOTH profiles ----------------------------
section "base credential is caught under BOTH profiles (private keeps credential coverage)"
R2="$TMP/r-cred"; mk_repo "$R2"
printf 'aws_key = %s\n' "$CANARY" > "$R2/cred.txt"; commit_all "$R2" cred
run_resident 0 "$R2"
assert_eq "public: base credential exits 1 (caught)" "1" "$RC"
grep -q "aws-access-token" "$OUTFILE" && pass "public: reports aws-access-token" || fail "public: aws-access-token" "$(cat "$OUTFILE")"
run_resident 1 "$R2"
assert_eq "private: base credential STILL exits 1 (base-rules pass retained)" "1" "$RC"
grep -q "aws-access-token" "$OUTFILE" && pass "private: base credential still caught" || fail "private: base credential caught" "$(cat "$OUTFILE")"

# ---- clean tree passes both -------------------------------------------------
section "a clean tree passes under both profiles"
R3="$TMP/r-clean"; mk_repo "$R3"; echo "nothing to see here" > "$R3/ok.txt"; commit_all "$R3" ok
run_resident 0 "$R3"; assert_eq "public: clean tree exits 0" "0" "$RC"
run_resident 1 "$R3"; assert_eq "private: clean tree exits 0" "0" "$RC"

# ---- findings output shape: repo-relative rule<TAB>file:line, value withheld -
section "findings output is de-duped, repo-relative rule<TAB>file:line, value withheld"
R4="$TMP/r-shape"; mk_repo "$R4"
mkdir -p "$R4/src"; printf 'aws_key = %s\n' "$CANARY" > "$R4/src/config.txt"; commit_all "$R4" shape
run_resident 0 "$R4"
assert_eq "shape: exits 1" "1" "$RC"
grep -qE '^aws-access-token'$'\t''src/config\.txt:[0-9]+$' "$OUTFILE" && pass "output line is 'rule<TAB>repo-relative-file:line'" || fail "output shape" "$(cat -A "$OUTFILE")"
grep -q "$CANARY" "$OUTFILE" && fail "value withheld in output" "canary leaked!" || pass "value withheld (redacted)"
grep -q "$CANARY" "$ERRFILE" && fail "value withheld in stderr" "canary leaked to stderr!" || pass "value withheld in stderr too"

# ---- export-ignore-hidden resident content is still caught (cat-file) --------
section "export-ignore-hidden resident content is still caught (cat-file, not git-archive)"
R5="$TMP/r-exportignore"; mk_repo "$R5"
printf 'aws_key = %s\n' "$CANARY" > "$R5/hidden.txt"
printf 'hidden.txt export-ignore\n' > "$R5/.gitattributes"
commit_all "$R5" exportignore
# control: git archive OMITS it (the blind spot a git-archive scan would have)
ARCH="$TMP/r5-arch"; mkdir -p "$ARCH"; git -C "$R5" archive HEAD | tar -x -C "$ARCH" 2>/dev/null
[[ -f "$ARCH/hidden.txt" ]] && fail "control: git archive should OMIT the export-ignored file" "present" || pass "control: git archive omits it (the blind spot)"
run_resident 0 "$R5"
assert_eq "export-ignored resident secret is caught (cat-file reads it)" "1" "$RC"
grep -q "aws-access-token" "$OUTFILE" && pass "caught the export-ignored content" || fail "caught export-ignored content" "$(cat "$OUTFILE")"

# ---- a repo [allowlist] does NOT suppress the backstop ----------------------
section "a repo [allowlist] does NOT suppress the backstop (scans under GL_MANDATORY_CONFIG, not repo config)"
R6="$TMP/r-allowlist"; mk_repo "$R6"
printf 'aws_key = %s\n' "$CANARY" > "$R6/allowed.txt"
cat > "$R6/.gitleaks.toml" <<'EOF'
title = "repo config that tries to allowlist the leak"
[extend]
useDefault = true
[allowlist]
paths = ['''allowed\.txt$''']
EOF
commit_all "$R6" allowlist
run_resident 0 "$R6"
assert_eq "repo [allowlist] does NOT suppress the backstop (still blocks)" "1" "$RC"
grep -q "aws-access-token" "$OUTFILE" && pass "backstop ignored the repo allowlist and caught it" || fail "backstop ignored repo allowlist" "$(cat "$OUTFILE")"

# ---- missing / malformed overlay refuses (fail-closed) ----------------------
section "missing overlay refuses (public profile, fail-closed)"
R7="$TMP/r-clean2"; mk_repo "$R7"; echo "clean" > "$R7/x.txt"; commit_all "$R7" x
XDG_OVERRIDE="$XDG_EMPTY"; run_resident 0 "$R7"; XDG_OVERRIDE=""
assert_eq "missing overlay: public profile refuses (exit 2)" "2" "$RC"

section "malformed overlay refuses (public profile, fail-closed)"
XDG_BAD="$TMP/xdg-bad"; mkdir -p "$XDG_BAD/gitleaks"
printf 'this = not [[ valid toml\n' > "$XDG_BAD/gitleaks/operator-rules.toml"
XDG_OVERRIDE="$XDG_BAD"; run_resident 0 "$R7"; XDG_OVERRIDE=""
assert_eq "malformed overlay: public profile refuses (exit 2)" "2" "$RC"

section "private profile with NO overlay installed still runs (base-only needs no overlay)"
# GATE_SKIP_OVERLAY=1 sets GL_NO_OVERLAY, so gl_mandatory_preflight builds a
# base-only config and never requires the overlay — a clean private tree passes
# even with the fixed path absent.
XDG_OVERRIDE="$XDG_EMPTY"; run_resident 1 "$R7"; XDG_OVERRIDE=""
assert_eq "private profile, no overlay installed: clean tree still exits 0" "0" "$RC"

finish
