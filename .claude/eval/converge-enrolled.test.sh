#!/usr/bin/env bash
# Test suite for .github/scripts/converge-enrolled.sh — which repos the estate
# converge touches, what it tolerates, and what it refuses.
#
# The provisioner itself is replaced by a stub, because this file decides WHICH
# repos and WHAT counts as failure and nothing else; the provisioner has its own
# 350-assertion suite. Every case asserts on the stub's recorded calls, so
# "touched nothing" is provable rather than assumed.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/assert.sh"

SCRIPT="${SCRIPT:-${SCRIPT_DIR}/../../.github/scripts/converge-enrolled.sh}"
[[ -f "$SCRIPT" ]] || { echo "FATAL: missing $SCRIPT"; exit 2; }

TMP="$(mktemp -d -t converge-enrolled-test.XXXXXX)"
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT INT TERM

# A fake provisioner. Records every repo it was called for and the mode, and
# emits whatever the case scripted for that repo.
mk_provisioner() { # <path-to-script> <calls-file>
    cat > "$1" <<STUBEOF
#!/usr/bin/env bash
mode=converge
[[ "\$1" == "--check" ]] && { mode=check; shift; }
repo="\$1"
printf '%s %s\n' "\$mode" "\$repo" >> "$2"
out_file="$TMP/out.\${repo//\//_}"
rc_file="$TMP/rc.\${repo//\//_}"
[[ -f "\$out_file" ]] && cat "\$out_file"
[[ -f "\$rc_file" ]] && exit "\$(cat "\$rc_file")"
exit 0
STUBEOF
    chmod +x "$1"
}

PROV="$TMP/fake-provision.sh"
CALLS="$TMP/calls.log"
mk_provisioner "$PROV" "$CALLS"

new_case() {
    : > "$CALLS"; rm -f "$TMP"/out.* "$TMP"/rc.*
    DOTTY="$TMP/dotty"; mkdir -p "$DOTTY/rulesets"
}
# declare_repos <slug...> — the enrolled list this run should see.
declare_repos() {
    { printf '{"repos":{'
      local first=1 r
      for r in "$@"; do [[ $first -eq 1 ]] || printf ','; printf '"%s":{}' "$r"; first=0; done
      printf '}}'; } > "$DOTTY/rulesets/default-branch.json"
}
run_converge() { # <mode>
    OUT="$(PROVISION_CMD="$PROV" bash "$SCRIPT" "$1" "$DOTTY" 2>&1)"; RC=$?
}

# ---------------------------------------------------------------------------
section "the enrolled list IS the definition of 'ours'"
# ---------------------------------------------------------------------------
new_case
declare_repos "lexijamesesq/alpha" "lexijamesesq/beta"
run_converge converge
assert_eq "a clean converge exits 0" "0" "$RC"
assert_eq "every enrolled repo is converged, and only those" \
    "converge lexijamesesq/alpha
converge lexijamesesq/beta" "$(sort "$CALLS")"

# A repo that leaves the estate by losing its entry must not be touched. This is
# the assertion whose absence let a previous un-enrollment silently revert.
new_case
declare_repos "lexijamesesq/alpha"
run_converge converge
if grep -q "beta" "$CALLS"; then
    fail "an un-enrolled repo is never touched" "$(cat "$CALLS")"
else pass "an un-enrolled repo is never touched"; fi

# ---------------------------------------------------------------------------
section "converge: any non-zero from the provisioner fails the run"
# ---------------------------------------------------------------------------
# There is no 'mostly converged'. A half-applied ruleset is the one state this
# job exists to prevent, so a repo that cannot finish is a red run.
new_case
declare_repos "lexijamesesq/alpha" "lexijamesesq/beta"
echo 1 > "$TMP/rc.lexijamesesq_beta"
run_converge converge
assert_eq "a failing converge fails the run" "1" "$RC"
grep -q "::error::lexijamesesq/beta: converge exited 1" <<<"$OUT" \
    && pass "the failure names the repo and the exit code" \
    || fail "failure names the repo" "$OUT"
# and it does not stop the others
grep -q "converge lexijamesesq/alpha" "$CALLS" \
    && pass "one repo failing does not skip the rest" || fail "others still run" "$(cat "$CALLS")"

# ---------------------------------------------------------------------------
section "schedule: check mode, and the tolerated-drift list"
# ---------------------------------------------------------------------------
new_case
declare_repos "lexijamesesq/alpha"
printf '  DRIFT tag-origin[v2026.09.18] = lightweight (no tag object)\n' > "$TMP/out.lexijamesesq_alpha"
echo 1 > "$TMP/rc.lexijamesesq_alpha"
run_converge check
assert_eq "check mode calls the provisioner with --check" "check lexijamesesq/alpha" "$(cat "$CALLS")"
assert_eq "tolerated drift alone does NOT fail the run" "0" "$RC"
grep -q "tolerated drift class 'tag-origin'" <<<"$OUT" \
    && pass "the tolerance is stated in the log, not silent" || fail "tolerance logged" "$OUT"

# The exemption is on the CLASS NAME, never a substring. A substring filter would
# swallow a future class nobody meant to exempt — this is the case that stops it.
new_case
declare_repos "lexijamesesq/alpha"
printf '  DRIFT tag-origin-policy = something new nobody exempted\n' > "$TMP/out.lexijamesesq_alpha"
echo 1 > "$TMP/rc.lexijamesesq_alpha"
run_converge check
assert_eq "a NEW class that merely starts with a tolerated name still fails" "1" "$RC"
grep -q "DRIFT tag-origin-policy" <<<"$OUT" \
    && pass "the un-exempted class is reported as an error" || fail "new class errors" "$OUT"

new_case
declare_repos "lexijamesesq/alpha"
printf '  DRIFT rule.pull_request = review_count=2 (intended 0)\n' > "$TMP/out.lexijamesesq_alpha"
echo 1 > "$TMP/rc.lexijamesesq_alpha"
run_converge check
assert_eq "an ordinary drift class fails the scheduled run" "1" "$RC"

new_case
declare_repos "lexijamesesq/alpha"
run_converge check
assert_eq "a clean check exits 0" "0" "$RC"

# A FATAL (exit > 1) is a failure in every mode — it means the declaration or an
# input could not be read, which is never 'just drift'.
new_case
declare_repos "lexijamesesq/alpha"
echo 2 > "$TMP/rc.lexijamesesq_alpha"
run_converge check
assert_eq "a provisioner FATAL fails a scheduled check too" "1" "$RC"

# ---------------------------------------------------------------------------
section "it never deletes a ruleset"
# ---------------------------------------------------------------------------
# The superseded 'Protect main' stays until the operator removes it. Nothing in
# this lane may delete branch protection, and the provisioner it drives issues no
# ruleset DELETE at all — asserted here against the real file so a future edit
# that added one would fail this suite rather than a live repo.
PROV_REAL="$SCRIPT_DIR/../../provision-public-repo.sh"
if grep -nE '\-X DELETE|--method DELETE' "$PROV_REAL" | grep -qi ruleset; then
    fail "the provisioner issues NO ruleset DELETE" "$(grep -nE '\-X DELETE|--method DELETE' "$PROV_REAL")"
else pass "the provisioner issues NO ruleset DELETE"; fi
if grep -qE '\-X DELETE|--method DELETE' "$SCRIPT"; then
    fail "the converge runner issues NO DELETE of its own" "$(grep -nE '\-X DELETE|--method DELETE' "$SCRIPT")"
else pass "the converge runner issues NO DELETE of its own"; fi

# ---------------------------------------------------------------------------
section "refusals"
# ---------------------------------------------------------------------------
new_case
declare_repos "lexijamesesq/alpha"
OUT="$(PROVISION_CMD="$PROV" bash "$SCRIPT" sideways "$DOTTY" 2>&1)"; RC=$?
assert_eq "an unknown mode refuses (exit 2), never guesses" "2" "$RC"
if [[ -s "$CALLS" ]]; then fail "an unknown mode touches nothing" "$(cat "$CALLS")"
else pass "an unknown mode touches nothing"; fi

new_case
rm -f "$DOTTY/rulesets/default-branch.json"
OUT="$(PROVISION_CMD="$PROV" bash "$SCRIPT" converge "$DOTTY" 2>&1)"; RC=$?
assert_eq "a missing declaration refuses (exit 2)" "2" "$RC"
if [[ -s "$CALLS" ]]; then fail "a missing declaration touches nothing" "$(cat "$CALLS")"
else pass "a missing declaration touches nothing"; fi

finish
