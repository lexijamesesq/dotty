#!/usr/bin/env bash
# Test suite for .github/scripts/margot-floor-gate.py — the sequencing gate that
# lets Margot run ONLY after the mechanical floor is green. Empirical: runs the
# real script against the real committed rulesets + synthesized check-run payloads
# (test mode, no network). Proves the peer's bar:
#   (i)   floor resolved from committed rulesets required_contexts
#   (ii)  the literal `margot` check is EXCLUDED (no self-deadlock even where a
#         repo requires `margot` for merge — probe-local-to-merged does)
#   (iii) refuse-until-green (pending or failing floor check) AND admit-when-green
#   (iv)  no repo entry / empty required_contexts -> FAIL-CLOSED (Margot doesn't run)
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/assert.sh"

S="${S:-${SCRIPT_DIR}/../../.github/scripts/margot-floor-gate.py}"
RS="${RS:-${SCRIPT_DIR}/../../rulesets/default-branch.json}"
[[ -f "$S" ]] || { echo "FATAL: missing $S"; exit 2; }
[[ -f "$RS" ]] || { echo "FATAL: missing $RS"; exit 2; }

TMP="$(mktemp -d -t margot-floor-gate-test.XXXXXX)"
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT INT TERM

# gate <repo> <check-runs-json-file> <rulesets> : sets GREEN to true/false
gate() {
    : > "$TMP/gho"
    GITHUB_OUTPUT="$TMP/gho" python3 "$S" --rulesets "${3:-$RS}" --repo "$1" --check-runs-file "$2" >/dev/null 2>"$TMP/err"
    GREEN="$(grep -oE 'floor_green=(true|false)' "$TMP/gho" | tail -1 | cut -d= -f2)"
}

PROBE="lexijamesesq/probe-local-to-merged"

# All floor checks green; note margot itself present as FAILURE — must NOT block.
cat > "$TMP/green.json" <<'EOF'
[{"name":"all-checks-passed","status":"completed","conclusion":"success"},
 {"name":"trusted-scan / trusted-scan","status":"completed","conclusion":"success"},
 {"name":"margot","status":"completed","conclusion":"failure"}]
EOF
cat > "$TMP/pending.json" <<'EOF'
[{"name":"all-checks-passed","status":"completed","conclusion":"success"}]
EOF
cat > "$TMP/failing.json" <<'EOF'
[{"name":"all-checks-passed","status":"completed","conclusion":"failure"},
 {"name":"trusted-scan / trusted-scan","status":"completed","conclusion":"success"}]
EOF
cat > "$TMP/inprogress.json" <<'EOF'
[{"name":"all-checks-passed","status":"completed","conclusion":"success"},
 {"name":"trusted-scan / trusted-scan","status":"in_progress","conclusion":null}]
EOF
echo '[]' > "$TMP/empty.json"

section "(ii)+(iii) admit-when-green: all floor checks success -> floor_green=true (margot's OWN failing check excluded, no self-deadlock)"
gate "$PROBE" "$TMP/green.json"
assert_eq "green floor admits" "true" "$GREEN"
grep -q "margot excluded" "$TMP/err" && pass "margot explicitly excluded from the floor" || fail "margot exclusion" "$(cat "$TMP/err")"

section "(iii) refuse-until-green: a floor check with no check-run yet -> false"
gate "$PROBE" "$TMP/pending.json"
assert_eq "pending floor refuses" "false" "$GREEN"

section "(iii) refuse: a floor check still in_progress -> false"
gate "$PROBE" "$TMP/inprogress.json"
assert_eq "in-progress floor refuses" "false" "$GREEN"

section "(iii) refuse: a floor check failing -> false"
gate "$PROBE" "$TMP/failing.json"
assert_eq "failing floor refuses" "false" "$GREEN"

section "(iv) FAIL-CLOSED: a repo not enrolled in the rulesets -> false (Margot does not run)"
gate "lexijamesesq/not-a-real-enrolled-repo" "$TMP/green.json"
assert_eq "unenrolled repo fail-closed" "false" "$GREEN"

section "(iv) FAIL-CLOSED: a repo with empty required_contexts -> false"
python3 -c "import json; d=json.load(open('$RS')); d.setdefault('repos',{})['lexijamesesq/emptyrepo']={'required_contexts':[]}; json.dump(d,open('$TMP/rs_empty.json','w'))"
gate "lexijamesesq/emptyrepo" "$TMP/green.json" "$TMP/rs_empty.json"
assert_eq "empty required_contexts fail-closed" "false" "$GREEN"

section "(i) floor is exactly required_contexts minus margot (a real enrolled repo)"
# dotty-private requires all-checks-passed + trusted-scan + eval-suite; with those
# three green (and margot absent), it admits.
cat > "$TMP/dp_green.json" <<'EOF'
[{"name":"all-checks-passed","status":"completed","conclusion":"success"},
 {"name":"trusted-scan / trusted-scan","status":"completed","conclusion":"success"},
 {"name":"eval-suite","status":"completed","conclusion":"success"}]
EOF
gate "lexijamesesq/dotty-private" "$TMP/dp_green.json"
assert_eq "dotty-private full floor green admits" "true" "$GREEN"
# ...but missing eval-suite (a real floor member) must refuse.
cat > "$TMP/dp_partial.json" <<'EOF'
[{"name":"all-checks-passed","status":"completed","conclusion":"success"},
 {"name":"trusted-scan / trusted-scan","status":"completed","conclusion":"success"}]
EOF
gate "lexijamesesq/dotty-private" "$TMP/dp_partial.json"
assert_eq "dotty-private missing eval-suite refuses (floor is not a hardcoded 2-name set)" "false" "$GREEN"

section "a concurrency-cancelled DUPLICATE must not override the later success"
# The receipted failure: dotty PR #281 head d6788ca carried two check-runs named
# `trusted-scan / trusted-scan` — cancelled, started 21:35:42, and success,
# started 21:36:01. The API lists newest first; the gate assigned unconditionally
# while iterating, so the OLDEST won, the floor read as failing, and Margot fell
# closed and posted nothing. Asserted in BOTH orderings, so the fix cannot be a
# silent dependency on the order the API happens to return.

cat > "$TMP/dup_newest_first.json" <<'EOF'
[{"name":"all-checks-passed","status":"completed","conclusion":"success","id":105391871457,"started_at":"2026-09-17T21:36:24Z"},
 {"name":"trusted-scan / trusted-scan","status":"completed","conclusion":"success","id":105391752806,"started_at":"2026-09-17T21:36:01Z"},
 {"name":"trusted-scan / trusted-scan","status":"completed","conclusion":"cancelled","id":105391652658,"started_at":"2026-09-17T21:35:42Z"}]
EOF
gate "$PROBE" "$TMP/dup_newest_first.json"
assert_eq "cancelled duplicate listed LAST (the live API order) does not block" "true" "$GREEN"

cat > "$TMP/dup_oldest_first.json" <<'EOF'
[{"name":"trusted-scan / trusted-scan","status":"completed","conclusion":"cancelled","id":105391652658,"started_at":"2026-09-17T21:35:42Z"},
 {"name":"trusted-scan / trusted-scan","status":"completed","conclusion":"success","id":105391752806,"started_at":"2026-09-17T21:36:01Z"},
 {"name":"all-checks-passed","status":"completed","conclusion":"success","id":105391871457,"started_at":"2026-09-17T21:36:24Z"}]
EOF
gate "$PROBE" "$TMP/dup_oldest_first.json"
assert_eq "cancelled duplicate listed FIRST does not block either" "true" "$GREEN"

section "NON-VACUOUS: when the NEWEST run of a repeated name is the bad one, it still blocks"
# The mirror image — proves the fix picks the most recent rather than simply
# preferring whichever outcome is convenient.

cat > "$TMP/dup_newest_failed.json" <<'EOF'
[{"name":"all-checks-passed","status":"completed","conclusion":"success","id":105391871457,"started_at":"2026-09-17T21:36:24Z"},
 {"name":"trusted-scan / trusted-scan","status":"completed","conclusion":"failure","id":105391752806,"started_at":"2026-09-17T21:36:01Z"},
 {"name":"trusted-scan / trusted-scan","status":"completed","conclusion":"success","id":105391652658,"started_at":"2026-09-17T21:35:42Z"}]
EOF
gate "$PROBE" "$TMP/dup_newest_failed.json"
assert_eq "a newer failure overrides an older success" "false" "$GREEN"

cat > "$TMP/dup_newest_rerun.json" <<'EOF'
[{"name":"all-checks-passed","status":"completed","conclusion":"success","id":105391871457,"started_at":"2026-09-17T21:36:24Z"},
 {"name":"trusted-scan / trusted-scan","status":"in_progress","conclusion":null,"id":105391752806,"started_at":"2026-09-17T21:36:01Z"},
 {"name":"trusted-scan / trusted-scan","status":"completed","conclusion":"success","id":105391652658,"started_at":"2026-09-17T21:35:42Z"}]
EOF
gate "$PROBE" "$TMP/dup_newest_rerun.json"
assert_eq "a re-run still in flight over an older success waits" "false" "$GREEN"

section "a payload with no id/started_at falls back to the API's newest-first order"
# Every pre-existing fixture in this suite omits those fields, so the fallback is
# load-bearing, not decorative: equal keys leave the FIRST occurrence winning.

cat > "$TMP/dup_no_keys.json" <<'EOF'
[{"name":"all-checks-passed","status":"completed","conclusion":"success"},
 {"name":"trusted-scan / trusted-scan","status":"completed","conclusion":"success"},
 {"name":"trusted-scan / trusted-scan","status":"completed","conclusion":"cancelled"}]
EOF
gate "$PROBE" "$TMP/dup_no_keys.json"
assert_eq "unkeyed duplicate: first (newest) wins" "true" "$GREEN"

finish
