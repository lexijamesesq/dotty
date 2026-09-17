#!/usr/bin/env bash
# Test suite for git-hooks/gitleaks-range-scan.sh — the AUTHORITATIVE
# diff-scoped secret/PII scan (the required CI check on a PR's base..head).
# Replaces the hand-rolled range/history/widen/whole-tree logic the old
# gitleaks-pre-push.sh carried (Cluster A). Covers:
#   * diff-scoped range behavior: clean/dirty/new-branch/empty/merge/empty-commit;
#   * intermediate-commit coverage (secret added then scrubbed within the range);
#   * out-of-range history is NEVER seen (the incident-#1 proof — base..head only);
#   * the #1729 over-scan backstop and the unresolvable-range fail-closed guard;
#   * the identity guard (non-noreply author/committer, tab-delimited anti-shift);
#   * operator-rules composition via gl_resolve (installed overlay, GL_NO_OVERLAY,
#     GL_OVERLAY_ONLY, GL_CONFIG_PATH, repo allowlist, parse guard).
#
# Self-contained; synthetic config (never the real ruleset); no `git push`.
# Canaries: random AKIA + 16 [A-Z2-7], never ...EXAMPLE. No operator PII.
# Run: bash .claude/eval/gitleaks-range-scan.test.sh

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/assert.sh"
source "$SCRIPT_DIR/lib/gitleaks-fixtures.sh"

HOOKS_DIR="${HOOKS_DIR:-${SCRIPT_DIR}/../../git-hooks}"
RANGE="$HOOKS_DIR/gitleaks-range-scan.sh"
[[ -f "$RANGE" ]] || { echo "FATAL: missing $RANGE"; exit 2; }
require_gitleaks_tools 0

TMP="$(mktemp -d -t gitleaks-range-test.XXXXXX)"
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

commit_on() { # <new-branch> <base> <file> <content> -> echoes sha
    git -C "$REPO" checkout -q -b "$1" "$2"
    printf '%s\n' "$4" > "$REPO/$3"
    git -C "$REPO" add "$3"
    git -C "$REPO" commit -q -m "$1" --no-verify
    git -C "$REPO" rev-parse HEAD
}

# run_range <from> <to> — invoke the authoritative scan over an explicit range.
# GL_NO_OVERLAY=1 by default (base rules) unless the caller pre-exports a mode.
run_range() { # <from> <to>
    ( cd "$REPO" && env XDG_CONFIG_HOME="${XDG_OVERRIDE:-$XDG_CONFIG_HOME}" \
        GL_NO_OVERLAY="${GL_NO_OVERLAY:-1}" \
        GL_RANGE_BASE="$1" GL_RANGE_HEAD="$2" \
        bash "$RANGE" ) >/dev/null 2>"$ERRFILE"
    RC=$?
}
# run_range_mode <mode-assignments...> -- e.g. run_range_mode "GL_OVERLAY_ONLY=1" <from> <to>
run_range_mode() { # <envassign> <from> <to>
    local assign="$1" from="$2" to="$3"
    # shellcheck disable=SC2086  # $assign is deliberately word-split into >=1 VAR=val env args
    ( cd "$REPO" && env XDG_CONFIG_HOME="${XDG_OVERRIDE:-$XDG_CONFIG_HOME}" $assign \
        GL_RANGE_BASE="$from" GL_RANGE_HEAD="$to" \
        bash "$RANGE" ) >/dev/null 2>"$ERRFILE"
    RC=$?
}

CLEAN2_SHA="$(commit_on advance main clean2.txt "another clean line")"
BAD_SHA="$(commit_on bad-branch "$CLEAN_SHA" bad.txt "leak $CANARY")"
FEAT_SHA="$(commit_on feature-bad "$CLEAN_SHA" feat.txt "leak $CANARY")"
FEATOK_SHA="$(commit_on feature-clean "$CLEAN_SHA" featok.txt "clean feature content")"
git -C "$REPO" checkout -q main

# ---- core diff-scoped range behavior ----------------------------------------
section "range (a): a bad range is blocked, reports the rule id, withholds the value, gives remediation"
run_range "$CLEAN_SHA" "$BAD_SHA"
assert_eq "bad range exits 1 (blocked)" "1" "$RC"
grep -q "aws-access-token" "$ERRFILE" && pass "reports the rule id" || fail "reports the rule id" "$(cat "$ERRFILE")"
grep -q "$CANARY" "$ERRFILE" && fail "matched literal withheld" "CANARY leaked into output!" || pass "matched literal withheld (redacted)"
grep -qiE 'filter-repo|amend|rebase' "$ERRFILE" && pass "gives a remediation path" || fail "gives a remediation path" "none"

section "range (b): a clean range passes"
run_range "$CLEAN_SHA" "$CLEAN2_SHA"
assert_eq "clean range exits 0 (passes)" "0" "$RC"

section "range (c): a new-branch range (from=ancestor) carrying a bad commit is blocked"
run_range "$CLEAN_SHA" "$FEAT_SHA"
assert_eq "new-branch bad range exits 1 (blocked)" "1" "$RC"
grep -q "aws-access-token" "$ERRFILE" && pass "new-branch scan reports the rule id" || fail "new-branch scan reports the rule id" "none"

section "range (c2): a new-branch clean range passes"
run_range "$CLEAN_SHA" "$FEATOK_SHA"
assert_eq "new-branch clean range exits 0 (passes)" "0" "$RC"

section "range: an empty range (base==head) passes (nothing to scan, not a failure)"
run_range "$CLEAN2_SHA" "$CLEAN2_SHA"
assert_eq "empty range exits 0" "0" "$RC"

# ---- #1729 N<expected must NOT false-block (the incident-#1-adjacent guard) --
section "range: a clean MERGE-only range passes (merge commit emits no fragment -> N<expected, must not block)"
git -C "$REPO" checkout -q -b mfeat "$CLEAN_SHA"
printf 'feature line\n' > "$REPO/mfeat.txt"; git -C "$REPO" add mfeat.txt; git -C "$REPO" commit -q -m mfeat --no-verify
git -C "$REPO" checkout -q -b mmain "$CLEAN_SHA"
printf 'main line\n' > "$REPO/mmain.txt"; git -C "$REPO" add mmain.txt; git -C "$REPO" commit -q -m mmain --no-verify
MERGE_BASE="$(git -C "$REPO" rev-parse HEAD)"
git -C "$REPO" merge -q --no-ff mfeat -m "merge mfeat"
MERGE_TIP="$(git -C "$REPO" rev-parse HEAD)"
git -C "$REPO" checkout -q main
EXP_MERGE="$(git -C "$REPO" rev-list --count "$MERGE_BASE..$MERGE_TIP")"
[[ "$EXP_MERGE" -ge 2 ]] && pass "merge range spans >=2 commits incl. the merge ($EXP_MERGE)" || fail "merge range spans the merge commit" "count=$EXP_MERGE"
run_range "$MERGE_BASE" "$MERGE_TIP"
assert_eq "clean merge-only range exits 0 (N<expected not blocked)" "0" "$RC"

section "range: a clean EMPTY-COMMIT-only range passes (empty commit emits no fragment)"
git -C "$REPO" checkout -q -b emptyc "$CLEAN_SHA"
git -C "$REPO" commit -q --allow-empty -m "empty commit" --no-verify
EMPTYC_TIP="$(git -C "$REPO" rev-parse HEAD)"
git -C "$REPO" checkout -q main
run_range "$CLEAN_SHA" "$EMPTYC_TIP"
assert_eq "empty-commit-only range exits 0 (N==0 with expected>0 is legitimate)" "0" "$RC"

# ---- intermediate-commit coverage + out-of-range proof ----------------------
section "range: a secret in an INTERMEDIATE commit, scrubbed at the tip, is still caught (--log-opts scans each patch)"
git -C "$REPO" checkout -q -b inter "$CLEAN_SHA"
printf 'k = %s\n' "$CANARY" > "$REPO/inter.txt"; git -C "$REPO" add inter.txt; git -C "$REPO" commit -q -m "add secret" --no-verify
printf 'k = SCRUBBED\n' > "$REPO/inter.txt"; git -C "$REPO" add inter.txt; git -C "$REPO" commit -q -m "scrub at tip" --no-verify
INTER_TIP="$(git -C "$REPO" rev-parse HEAD)"
git -C "$REPO" checkout -q main
run_range "$CLEAN_SHA" "$INTER_TIP"
assert_eq "intermediate secret scrubbed at tip still blocks" "1" "$RC"
grep -q "aws-access-token" "$ERRFILE" && pass "the intermediate-commit patch was scanned" || fail "intermediate-commit patch scanned" "$(cat "$ERRFILE")"

section "range: an out-of-range legit pattern (only in history BEFORE base) is NEVER seen (incident #1 proof)"
# A canary committed BEFORE base; the scanned range base..head is clean. A
# whole-history/widen scan (the removed Cluster-A behavior) would re-trip on it;
# the diff-scoped range must not.
git -C "$REPO" checkout -q -b outrange "$CLEAN_SHA"
printf 'k = %s\n' "$CANARY" > "$REPO/deep.txt"; git -C "$REPO" add deep.txt; git -C "$REPO" commit -q -m "deep history canary" --no-verify
OUT_BASE="$(git -C "$REPO" rev-parse HEAD)"
printf 'clean tip content\n' > "$REPO/clean-after.txt"; git -C "$REPO" add clean-after.txt; git -C "$REPO" commit -q -m "clean after" --no-verify
OUT_TIP="$(git -C "$REPO" rev-parse HEAD)"
git -C "$REPO" checkout -q main
run_range "$OUT_BASE" "$OUT_TIP"
assert_eq "range base..head with the canary BEFORE base passes (deep history never scanned)" "0" "$RC"

# ---- unresolvable range fail-closed (#2129-shape) ---------------------------
section "range: an unresolvable range (nonexistent base) BLOCKS, never a silent pass"
run_range "deadbeefdeadbeefdeadbeefdeadbeefdeadbeef" "$CLEAN2_SHA"
assert_eq "nonexistent base exits 1 (blocked, fail-closed)" "1" "$RC"
grep -qiE 'unresolvable commit range|scanner could not resolve' "$ERRFILE" && pass "names the unresolvable range (not a false clean)" || fail "names the unresolvable range" "$(cat "$ERRFILE")"

# ---- identity guard ---------------------------------------------------------
section "identity guard: non-noreply AUTHOR email blocks, names SHA + field, withholds the value"
git -C "$REPO" checkout -q -b ident-stale "$CLEAN_SHA"
echo "innocuous" > "$REPO/ident.txt"; git -C "$REPO" add ident.txt
GIT_AUTHOR_EMAIL="stale@example.com" git -C "$REPO" commit -q -m "stale-clone-shaped" --no-verify
STALE_SHA="$(git -C "$REPO" rev-parse HEAD)"
git -C "$REPO" checkout -q main
run_range "$CLEAN_SHA" "$STALE_SHA"
assert_eq "stale-email range exits 1 (blocked)" "1" "$RC"
grep -q "non-noreply author email" "$ERRFILE" && pass "names the offending field" || fail "names the offending field" "$(cat "$ERRFILE")"
grep -q "$STALE_SHA" "$ERRFILE" && pass "names the offending commit SHA" || fail "names the offending commit SHA" "none"
grep -q "stale@example.com" "$ERRFILE" && fail "email value withheld" "email leaked!" || pass "email value withheld"

section "identity guard: GitHub squash shape (committer noreply@github.com) passes"
git -C "$REPO" checkout -q -b ident-squash "$CLEAN_SHA"
echo "squash content" > "$REPO/squash.txt"; git -C "$REPO" add squash.txt
GIT_COMMITTER_NAME="GitHub" GIT_COMMITTER_EMAIL="noreply@github.com" git -C "$REPO" commit -q -m "squash-shaped" --no-verify
SQUASH_SHA="$(git -C "$REPO" rev-parse HEAD)"
git -C "$REPO" checkout -q main
run_range "$CLEAN_SHA" "$SQUASH_SHA"
assert_eq "squash-shape range exits 0 (passes)" "0" "$RC"

section "identity guard: space-in-author-email cannot column-shift a bad committer past the check"
git -C "$REPO" checkout -q -b ident-shift "$CLEAN_SHA"
echo "shift probe" > "$REPO/shift.txt"; git -C "$REPO" add shift.txt
GIT_AUTHOR_EMAIL="noreply@a noreply@b" GIT_COMMITTER_EMAIL="bad@example.com" git -C "$REPO" commit -q -m "column-shift" --no-verify
SHIFT_SHA="$(git -C "$REPO" rev-parse HEAD)"
git -C "$REPO" checkout -q main
run_range "$CLEAN_SHA" "$SHIFT_SHA"
assert_eq "space-email column-shift range exits 1 (blocked)" "1" "$RC"
grep -q "non-noreply committer email" "$ERRFILE" && pass "blocks on the committer field (no shift past it)" || fail "blocks on the committer field" "$(cat "$ERRFILE")"

# ---- operator-rules composition via gl_resolve ------------------------------
section "fixed path (default mode): base+overlay resolves from the fixed install path, marker proves which ruleset loaded"
MARK_SHA="$(commit_on marker-fixed "$CLEAN_SHA" marker.txt "token FIXEDPATHMARKER here")"
git -C "$REPO" checkout -q main
run_range_mode "" "$CLEAN_SHA" "$MARK_SHA"
assert_eq "fixed-path marker range exits 1 (blocked)" "1" "$RC"
grep -q "fixture-fixedpath-marker" "$ERRFILE" && pass "reports the FIXED-PATH fixture's rule id" || fail "reports the fixed-path rule id" "$(cat "$ERRFILE")"
run_range_mode "" "$CLEAN_SHA" "$BAD_SHA"
assert_eq "default rules still fire through the fixed path (canary blocked)" "1" "$RC"

section "fixed path beats a checkout-relative file naming a DIFFERENT ruleset"
write_checkout_rules "$REPO"
SYM_SHA="$(commit_on marker-symlink "$CLEAN_SHA" symmark.txt "token SYMLINKMARKER here")"
git -C "$REPO" checkout -q main
run_range_mode "" "$CLEAN_SHA" "$SYM_SHA"
assert_eq "checkout-relative marker range exits 0 (its file was NOT consulted)" "0" "$RC"
grep -q "fixture-symlink-marker" "$ERRFILE" && fail "checkout-relative rule id absent" "symlink ruleset leaked" || pass "checkout-relative rule id absent"
rm -f "$REPO/.gitleaks-operator-rules.toml"

section "fixed path unreadable blocks (never falls back)"
write_checkout_rules "$REPO"; chmod 000 "$FIXED"
run_range_mode "" "$CLEAN_SHA" "$SYM_SHA"
chmod 644 "$FIXED"; rm -f "$REPO/.gitleaks-operator-rules.toml"
assert_eq "unreadable fixed path exits 1 (blocked)" "1" "$RC"
grep -qi "readable file at" "$ERRFILE" && pass "names the unreadable install and its expected path" || fail "names the unreadable install" "$(cat "$ERRFILE")"

section "fixed path broken symlink blocks (never falls back)"
mv "$FIXED" "$FIXED.keep"; ln -s "/nonexistent/operator-rules.toml" "$FIXED"
run_range_mode "" "$CLEAN_SHA" "$CLEAN2_SHA"
rm -f "$FIXED"; mv "$FIXED.keep" "$FIXED"
assert_eq "broken fixed-path symlink exits 1 (blocked)" "1" "$RC"
grep -qi "readable file at" "$ERRFILE" && pass "names the broken install and its expected path" || fail "names the broken install" "$(cat "$ERRFILE")"

section "GL_NO_OVERLAY: base rules only; overlay marker does NOT fire; repo [allowlist] is honored"
run_range_mode "GL_NO_OVERLAY=1" "$CLEAN_SHA" "$BAD_SHA"
assert_eq "GL_NO_OVERLAY: base rules still fire (canary blocked)" "1" "$RC"
run_range_mode "GL_NO_OVERLAY=1" "$CLEAN_SHA" "$MARK_SHA"
assert_eq "GL_NO_OVERLAY: operator marker (fixed-path only) does NOT fire" "0" "$RC"
# repo [allowlist] honored under base-rules (gl_resolve loads the repo's config unmodified)
git -C "$REPO" checkout -q -b allowlisted "$CLEAN_SHA"
echo "leak $CANARY in an allowlisted path" > "$REPO/allowed.txt"; git -C "$REPO" add allowed.txt; git -C "$REPO" commit -q -m allow --no-verify
ALLOW_SHA="$(git -C "$REPO" rev-parse HEAD)"
git -C "$REPO" checkout -q main
cat > "$REPO/.gitleaks.toml" <<'EOF'
title = "fixture with allowlist"
[extend]
path = ".gitleaks-operator-rules.toml"
[allowlist]
paths = ['''allowed\.txt$''']
EOF
run_range_mode "GL_NO_OVERLAY=1" "$CLEAN_SHA" "$ALLOW_SHA"
assert_eq "GL_NO_OVERLAY: an allowlisted path passes (repo allowlist honored)" "0" "$RC"
write_config_chain "$REPO"
run_range_mode "GL_NO_OVERLAY=1" "$CLEAN_SHA" "$ALLOW_SHA"
assert_eq "control: without the allowlist the same range blocks" "1" "$RC"

section "GL_OVERLAY_ONLY: operator overlay standalone fires the marker and IGNORES the repo [allowlist]"
run_range_mode "GL_OVERLAY_ONLY=1" "$CLEAN_SHA" "$MARK_SHA"
assert_eq "GL_OVERLAY_ONLY: overlay marker fires (blocks)" "1" "$RC"
grep -q "fixture-fixedpath-marker" "$ERRFILE" && pass "GL_OVERLAY_ONLY: reports the overlay rule id" || fail "GL_OVERLAY_ONLY: overlay rule id" "$(cat "$ERRFILE")"
# an [allowlist] in the repo config must NOT suppress the overlay-only pass
git -C "$REPO" checkout -q -b allow-marker "$CLEAN_SHA"
echo "token FIXEDPATHMARKER in an allowlisted path" > "$REPO/allowed.txt"; git -C "$REPO" add allowed.txt; git -C "$REPO" commit -q -m allowmark --no-verify
ALLOWMARK_SHA="$(git -C "$REPO" rev-parse HEAD)"
git -C "$REPO" checkout -q main
cat > "$REPO/.gitleaks.toml" <<'EOF'
title = "fixture with allowlist"
[extend]
path = ".gitleaks-operator-rules.toml"
[allowlist]
paths = ['''allowed\.txt$''']
EOF
run_range_mode "GL_OVERLAY_ONLY=1" "$CLEAN_SHA" "$ALLOWMARK_SHA"
assert_eq "GL_OVERLAY_ONLY: a repo [allowlist] does NOT suppress the overlay (blocks)" "1" "$RC"
write_config_chain "$REPO"

section "useDefault-only config (no operator extend) passes through unchanged (base rules only)"
cat > "$REPO/.gitleaks.toml" <<'EOF'
title = "base rules only"
[extend]
useDefault = true
EOF
run_range_mode "" "$CLEAN_SHA" "$BAD_SHA"
assert_eq "useDefault-only: base rules fire (canary blocked)" "1" "$RC"
run_range_mode "" "$CLEAN_SHA" "$MARK_SHA"
assert_eq "useDefault-only: no operator overlay injected (marker does NOT fire)" "0" "$RC"
write_config_chain "$REPO"

section "parse guard: an [extend] path this parser cannot read blocks (never pass-through)"
cat > "$REPO/.gitleaks.toml" <<'EOF'
title = "unquoted extend"
[extend]
path = .gitleaks-operator-rules.toml
EOF
run_range_mode "" "$CLEAN_SHA" "$CLEAN2_SHA"
assert_eq "unreadable extend value exits 1 (blocked)" "1" "$RC"
grep -qi "cannot parse" "$ERRFILE" && pass "names the parse failure" || fail "names the parse failure" "$(cat "$ERRFILE")"
write_config_chain "$REPO"

section "GL_CONFIG_PATH: a pinned config is used instead of the repo's own (widened) config"
WIDENED="$TMP/widened.toml"
cat > "$WIDENED" <<EOF
title = "widened (simulates a PR's own .gitleaks.toml)"
[extend]
useDefault = true
[allowlist]
regexes = ['''$CANARY''']
EOF
PINNED="$TMP/pinned.toml"
printf 'title="pinned"\n[extend]\nuseDefault = true\n' > "$PINNED"
cp "$WIDENED" "$REPO/.gitleaks.toml"
run_range_mode "GL_NO_OVERLAY=1" "$CLEAN_SHA" "$BAD_SHA"
assert_eq "no GL_CONFIG_PATH: the repo's own widened config is used, canary passes" "0" "$RC"
run_range_mode "GL_NO_OVERLAY=1 GL_CONFIG_PATH=$PINNED" "$CLEAN_SHA" "$BAD_SHA"
assert_eq "GL_CONFIG_PATH set: the pinned config is used, canary blocks" "1" "$RC"
run_range_mode "GL_NO_OVERLAY=1 GL_CONFIG_PATH=$PINNED" "$CLEAN_SHA" "$CLEAN2_SHA"
assert_eq "GL_CONFIG_PATH set: a clean range still passes" "0" "$RC"
write_config_chain "$REPO"

# ---- fail-open guards, exercised via a stub gitleaks (the slice's signature) -
# The two receipted guards catch gitleaks' documented fail-open shapes, which a
# REAL gitleaks won't reproduce on demand — so a stub `gitleaks` on PATH (the
# same technique house-code.test.sh uses for `gh`) fabricates each shape. The
# stub writes an EMPTY report and exits 0, so WITHOUT the guard the scan would
# PASS (exit 0); asserting it BLOCKS (exit 1) proves the guard actually fired —
# a removed or inverted guard makes these tests fail (non-vacuous by construction).
STUBBIN="$TMP/stubbin"; mkdir -p "$STUBBIN"
cat > "$STUBBIN/gitleaks" <<'STUBEOF'
#!/usr/bin/env bash
# Controlled fail-open stub. STUB_STDERR: a line emitted to stderr (e.g. a
# git 'fatal:' the #2129 guard must catch). STUB_SCANNED: the "<N> commits
# scanned." count the #1729 over-scan guard parses. STUB_RC: exit code
# (default 0 -- the fail-open: gitleaks exits 0 despite the problem).
report=""; prev=""
for a in "$@"; do [[ "$prev" == "--report-path" ]] && report="$a"; prev="$a"; done
[[ -n "$report" ]] && printf '[]' > "$report"
[[ -n "${STUB_SCANNED:-}" ]] && echo "${STUB_SCANNED} commits scanned." >&2
[[ -n "${STUB_STDERR:-}" ]] && echo "${STUB_STDERR}" >&2
exit "${STUB_RC:-0}"
STUBEOF
chmod +x "$STUBBIN/gitleaks"
# run_range_stub <stub-env-assignments> <from> <to> — like run_range but with the
# stub gitleaks first on PATH. GL_NO_OVERLAY=1 so gl_resolve needs no overlay.
run_range_stub() {
    local stub="$1" from="$2" to="$3"
    # shellcheck disable=SC2086  # $stub is deliberately word-split into STUB_* env args
    ( cd "$REPO" && env PATH="$STUBBIN:$PATH" XDG_CONFIG_HOME="$XDG_CONFIG_HOME" \
        GL_NO_OVERLAY=1 $stub GL_RANGE_BASE="$from" GL_RANGE_HEAD="$to" \
        bash "$RANGE" ) >/dev/null 2>"$ERRFILE"
    RC=$?
}
# The range CLEAN_SHA..CLEAN2_SHA is real (expected=1), so rev-list --count
# resolves and the identity guard passes; only the stub's gitleaks output varies.
EXP_CTRL="$(git -C "$REPO" rev-list --count "$CLEAN_SHA..$CLEAN2_SHA")"

section "#2129 guard: gitleaks emits a git 'fatal:' but exits 0 -> BLOCK (never trust the clean exit)"
run_range_stub "STUB_STDERR=fatal:_bad_revision STUB_SCANNED=$EXP_CTRL STUB_RC=0" "$CLEAN_SHA" "$CLEAN2_SHA"
assert_eq "#2129: fatal-on-stderr with exit 0 is BLOCKED" "1" "$RC"
grep -qi "could not resolve the range\|scanner could not" "$ERRFILE" && pass "#2129: names the range-resolve fail-open" || fail "#2129: names the fail-open" "$(cat "$ERRFILE")"

section "#1729 guard: gitleaks scans MORE commits than the range holds (silent widen) -> BLOCK"
run_range_stub "STUB_SCANNED=999 STUB_RC=0" "$CLEAN_SHA" "$CLEAN2_SHA"
assert_eq "#1729: N(999) > expected($EXP_CTRL) is BLOCKED (over-scan)" "1" "$RC"
grep -qi "more than the\|silently widened\|over-scan" "$ERRFILE" && pass "#1729: names the over-scan" || fail "#1729: names the over-scan" "$(cat "$ERRFILE")"

section "guard control: a stub reporting the correct count, no fatal, clean report -> PASSES (guards fire only on the bad shapes)"
run_range_stub "STUB_SCANNED=$EXP_CTRL STUB_RC=0" "$CLEAN_SHA" "$CLEAN2_SHA"
assert_eq "control: correct count + no fatal + empty report exits 0" "0" "$RC"

finish
