#!/usr/bin/env bash
# Test suite for git-hooks/gate-resolve-profile.sh — the trusted lane's
# per-repo private-repo profile resolver (the estate CI/CD rollout).
#
# Covers, offline (GATE_VISIBILITY_OVERRIDE injects the live-visibility answer
# so no network / no real gh is ever touched):
#   * class split: not-declared / declared-false -> GATE_SKIP_OVERLAY=0
#     (standard two-pass); declared-true + verified private -> =1 (identity/
#     overlay pass dropped, credential/base-rules pass kept);
#   * visibility check, fail-closed: declared-private but found public, or
#     visibility unreadable, blocks (exit 1) rather than relaxing the scan;
#   * fail-closed on unreadable / malformed declared JSON, and on bad args;
#   * the SHIPPED rulesets/default-branch.json declares exactly the three
#     content-bearing repos private (hazel, dotty-private, susuwatari-config)
#     and no other repo -- so a regression in the real declaration is caught
#     here, not in production.
#
# No operator PII anywhere; fixtures use the real public slugs (which are not
# secret) only to bind the shipped-declaration assertions.
#
# Run: bash ~/bin/dotty/.claude/eval/gate-resolve-profile.test.sh

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/assert.sh"

HOOKS_DIR="${HOOKS_DIR:-${SCRIPT_DIR}/../../git-hooks}"
RESOLVE="$HOOKS_DIR/gate-resolve-profile.sh"
DECLARED_REAL="${SCRIPT_DIR}/../../rulesets/default-branch.json"

[[ -f "$RESOLVE" ]] || { echo "FATAL: $RESOLVE not found"; exit 2; }
command -v jq >/dev/null 2>&1 || { echo "FATAL: jq required"; exit 2; }

TMP="$(mktemp -d -t gate-resolve-profile-test.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT INT TERM

# A fake `gh` that always fails, on PATH ahead of the real one — lets the
# "visibility unreadable" test drive the live lookup's failure branch offline,
# with no real gh call and no network, while `bash` and everything else stay
# resolvable.
FAILGH_BIN="$TMP/failgh-bin"; mkdir -p "$FAILGH_BIN"
cat > "$FAILGH_BIN/gh" <<'EOF'
#!/usr/bin/env bash
echo "fake gh: forced failure (offline visibility test)" >&2
exit 1
EOF
chmod +x "$FAILGH_BIN/gh"

# run <declared-json> <repo> [visibility-override] -> sets RC, OUT
# With a 3rd arg: inject that as the live-visibility answer (offline).
# Without: no override — the script takes the live-`gh` path. Not-declared
# repos return before ever calling gh, so this is safe for them; the one
# "visibility unreadable" case uses run_failgh below to force gh to fail.
run() {
    local dj="$1" repo="$2"
    if [[ $# -ge 3 ]]; then
        OUT="$(GATE_VISIBILITY_OVERRIDE="$3" bash "$RESOLVE" "$repo" "$dj" 2>&1)"; RC=$?
    else
        OUT="$(bash "$RESOLVE" "$repo" "$dj" 2>&1)"; RC=$?
    fi
}

# run_failgh <declared-json> <repo> -> live path with gh forced to fail.
run_failgh() {
    OUT="$(PATH="$FAILGH_BIN:$PATH" bash "$RESOLVE" "$2" "$1" 2>&1)"; RC=$?
}

# A synthetic declared file with the shapes under test.
DJ="$TMP/declared.json"
cat > "$DJ" <<'EOF'
{
  "pull_request": {"required_approving_review_count": 0},
  "required_status_checks": {"strict_required_status_checks_policy": true},
  "tag_ruleset": {"name": "Tag immutability", "rules": ["update", "deletion"]},
  "repos": {
    "acme/private-thing": {"private_repo": true},
    "acme/explicit-false": {"private_repo": false},
    "acme/has-contexts-only": {"required_contexts": ["ci"]}
  }
}
EOF

# ============================================================================
section "class split: standard (two-pass) when not declared private"
run "$DJ" "acme/not-in-map"
assert_eq "a repo absent from .repos -> exit 0" "0" "$RC"
assert_eq "a repo absent from .repos -> GATE_SKIP_OVERLAY=0" "GATE_SKIP_OVERLAY=0" "$OUT"

run "$DJ" "acme/explicit-false"
assert_eq "private_repo:false -> exit 0" "0" "$RC"
assert_eq "private_repo:false -> GATE_SKIP_OVERLAY=0" "GATE_SKIP_OVERLAY=0" "$OUT"

run "$DJ" "acme/has-contexts-only"
assert_eq "a .repos entry with only required_contexts (no private_repo) -> exit 0" "0" "$RC"
assert_eq "required_contexts-only entry -> GATE_SKIP_OVERLAY=0" "GATE_SKIP_OVERLAY=0" "$OUT"

# ============================================================================
section "class split: private-repo profile when declared private AND verified private"
run "$DJ" "acme/private-thing" "true"
assert_eq "declared private + visibility true -> exit 0" "0" "$RC"
assert_eq "declared private + visibility true -> GATE_SKIP_OVERLAY=1" "GATE_SKIP_OVERLAY=1" "$OUT"

# ============================================================================
section "visibility check: fail-closed on declared-private-but-not-verified"
run "$DJ" "acme/private-thing" "false"
assert_eq "declared private + found PUBLIC -> exit 1 (fail-closed)" "1" "$RC"
grep -q "not verified private" <<<"$OUT" && pass "names the fail-closed reason (public)" || fail "names the reason" "$OUT"
grep -q "GATE_SKIP_OVERLAY=1" <<<"$OUT" && fail "must NOT emit skip=1 when public" "$OUT" || pass "never emits skip=1 when public"

run "$DJ" "acme/private-thing" "unknown"
assert_eq "declared private + visibility 'unknown' -> exit 1 (fail-closed)" "1" "$RC"

run "$DJ" "acme/private-thing" "null"
assert_eq "declared private + visibility 'null' (API gave nothing) -> exit 1" "1" "$RC"

# Live lookup fails (gh forced to exit 1): a declared-private repo whose
# visibility can't be read must block, never relax.
run_failgh "$DJ" "acme/private-thing"
assert_eq "declared private + visibility UNREADABLE (gh fails) -> exit 1 (fail-closed)" "1" "$RC"

# ============================================================================
section "fail-closed on bad declared JSON and bad args"
run "$TMP/does-not-exist.json" "acme/private-thing" "true"
assert_eq "unreadable declared JSON -> exit 1" "1" "$RC"
grep -q "not readable" <<<"$OUT" && pass "names unreadable JSON" || fail "names unreadable JSON" "$OUT"

BADJSON="$TMP/malformed.json"; printf '{ this is not json' > "$BADJSON"
run "$BADJSON" "acme/private-thing" "true"
assert_eq "malformed declared JSON -> exit 1 (never silently 'not private')" "1" "$RC"
grep -q "not valid JSON" <<<"$OUT" && pass "names malformed JSON" || fail "names malformed JSON" "$OUT"

OUT="$(bash "$RESOLVE" 2>&1)"; RC=$?
assert_eq "no args -> exit 2 (usage)" "2" "$RC"
OUT="$(bash "$RESOLVE" "acme/only-one-arg" 2>&1)"; RC=$?
assert_eq "one arg -> exit 2 (usage)" "2" "$RC"

# ============================================================================
section "the SHIPPED declaration: exactly the three content-bearing repos are private"
if [[ -r "$DECLARED_REAL" ]]; then
    for repo in lexijamesesq/hazel lexijamesesq/dotty-private lexijamesesq/susuwatari-config; do
        run "$DECLARED_REAL" "$repo" "true"
        assert_eq "$repo is declared private in the shipped default-branch.json" "GATE_SKIP_OVERLAY=1" "$OUT"
    done
    # A caller that is NOT content-bearing must stay standard two-pass.
    run "$DECLARED_REAL" "lexijamesesq/core-skills"
    assert_eq "core-skills (a normal caller) is NOT private in the shipped declaration" "GATE_SKIP_OVERLAY=0" "$OUT"
    # Guard against the private set silently growing: exactly three declared.
    declared_private_count="$(jq '[.repos // {} | to_entries[] | select(.value.private_repo == true)] | length' "$DECLARED_REAL")"
    assert_eq "exactly three repos are declared private_repo:true" "3" "$declared_private_count"
else
    fail "shipped default-branch.json is readable at $DECLARED_REAL" "not found"
fi

finish
