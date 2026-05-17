#!/usr/bin/env bash
# filtered-verdict.test.sh — exercise the prep<->push verdict filtering logic.
#
# Validates: when prep produces a marker with findings on N files, push
# correctly scopes the verdict to ONLY findings on the files being committed.
# This is the load-bearing Stage 3-bis Fix 2 logic.
#
# Scenarios covered:
#   1. Empty staged list → allow
#   2. Marker is allow + staged subset → allow
#   3. Marker is revise + staged file is one of the revise findings → revise
#   4. Marker is revise + staged files are NONE of the revise findings → allow
#      (the verdict-poisoning regression test — Stage 3-bis Fix 2)
#   5. Marker has block + staged includes block file → block
#   6. Marker has escalate + staged includes escalate file → escalate
#   7. Marker has mix; staged matches highest-precedence → that precedence wins
#   8. Drift reporting: filtered != marker → drift=true
#   9. Malformed marker → exit 2
#  10. Missing marker → exit 3

set -uo pipefail

FILTER="${FILTER:-$HOME/bin/dotty/.claude/lib/filtered-verdict.sh}"
TMP=$(mktemp -d)
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

pass=0
fail=0

make_marker() {
  # $1 = output path, $2 = marker_verdict, $3..N = findings as "category|verdict|file|line"
  local out="$1" mv="$2"
  shift 2
  local findings_json="["
  local first=1
  for entry in "$@"; do
    IFS='|' read -r cat verdict file line <<<"$entry"
    [ "$first" -eq 1 ] && first=0 || findings_json+=","
    findings_json+="{\"category\":\"$cat\",\"verdict\":\"$verdict\",\"file\":\"$file\",\"line\":$line,\"snippet\":\"x\",\"reason\":\"y\"}"
  done
  findings_json+="]"
  cat > "$out" <<EOF
{
  "marker_schema_version": 2,
  "evaluated_path": "/x",
  "evaluated_at": "2026-05-16T00:00:00Z",
  "scope": "full-audit",
  "scanner_version": "2.1.0",
  "policy_hash": "sha256:0000000000000000000000000000000000000000000000000000000000000000",
  "verdict": "$mv",
  "findings": $findings_json,
  "acknowledgments": [],
  "summary": {"allow": 0, "block": 0, "revise": 0, "escalate": 0}
}
EOF
}

make_staged_list() {
  # $1 = output path, $2..N = file paths
  local out="$1"
  shift
  > "$out"
  for f in "$@"; do
    printf '%s\0' "$f" >> "$out"
  done
}

assert_verdict() {
  local name="$1" marker="$2" staged="$3" expected="$4"
  local result actual
  result=$("$FILTER" "$marker" "$staged" 2>&1) || {
    echo "FAIL: $name — filter exited non-zero: $result"
    fail=$((fail + 1))
    return
  }
  actual=$(echo "$result" | python3 -c 'import sys, json; print(json.load(sys.stdin)["filtered_verdict"])')
  if [ "$actual" = "$expected" ]; then
    echo "PASS: $name"
    pass=$((pass + 1))
  else
    echo "FAIL: $name — expected '$expected', got '$actual'"
    echo "  full output: $result"
    fail=$((fail + 1))
  fi
}

# --- Test 1: empty staged list → allow ---
make_marker "$TMP/m1.json" "revise" "Hardcoded path|Revise|a.sh|1"
make_staged_list "$TMP/s1.list"  # empty
assert_verdict "empty staged list → allow" "$TMP/m1.json" "$TMP/s1.list" "allow"

# --- Test 2: marker is allow + staged subset → allow ---
make_marker "$TMP/m2.json" "allow"  # no findings
make_staged_list "$TMP/s2.list" "a.sh" "b.md"
assert_verdict "marker allow + staged subset → allow" "$TMP/m2.json" "$TMP/s2.list" "allow"

# --- Test 3: marker revise, staged file is the revise file → revise ---
make_marker "$TMP/m3.json" "revise" "Hardcoded path|Revise|target.sh|10"
make_staged_list "$TMP/s3.list" "target.sh"
assert_verdict "staged includes the Revise file → revise" "$TMP/m3.json" "$TMP/s3.list" "revise"

# --- Test 4: VERDICT-POISONING REGRESSION (Stage 3-bis Fix 2) ---
# marker revise on other-session-file; staged is unrelated → allow
make_marker "$TMP/m4.json" "revise" "Hardcoded path|Revise|other-session.sh|5"
make_staged_list "$TMP/s4.list" "my-staged-file.md"
assert_verdict "verdict-poisoning regression: marker revise on out-of-scope → allow" \
  "$TMP/m4.json" "$TMP/s4.list" "allow"

# --- Test 5: block on staged file ---
make_marker "$TMP/m5.json" "block" "Secret|Block|sec.sh|3"
make_staged_list "$TMP/s5.list" "sec.sh"
assert_verdict "staged includes the Block file → block" "$TMP/m5.json" "$TMP/s5.list" "block"

# --- Test 6: escalate on staged file ---
make_marker "$TMP/m6.json" "escalate" "Internal reference|Escalate|name.md|1"
make_staged_list "$TMP/s6.list" "name.md"
assert_verdict "staged includes the Escalate file → escalate" "$TMP/m6.json" "$TMP/s6.list" "escalate"

# --- Test 7: mixed marker, precedence wins ---
make_marker "$TMP/m7.json" "escalate" \
  "Secret|Block|a.sh|1" \
  "Hardcoded path|Revise|b.sh|2" \
  "Internal reference|Escalate|c.md|3"
make_staged_list "$TMP/s7.list" "a.sh" "b.sh" "c.md"
assert_verdict "mixed marker, all staged → escalate (highest)" "$TMP/m7.json" "$TMP/s7.list" "escalate"
make_staged_list "$TMP/s7b.list" "a.sh" "b.sh"
assert_verdict "mixed marker, staged excludes escalate file → revise" "$TMP/m7.json" "$TMP/s7b.list" "revise"
make_staged_list "$TMP/s7c.list" "a.sh"
assert_verdict "mixed marker, staged only block file → block" "$TMP/m7.json" "$TMP/s7c.list" "block"

# --- Test 8: drift reporting ---
make_marker "$TMP/m8.json" "revise" "Hardcoded path|Revise|other.sh|1"
make_staged_list "$TMP/s8.list" "different.sh"
drift_out=$("$FILTER" "$TMP/m8.json" "$TMP/s8.list" | python3 -c 'import sys, json; print(json.load(sys.stdin)["drift"])')
if [ "$drift_out" = "True" ]; then
  echo "PASS: drift reported true when filtered differs from marker"
  pass=$((pass + 1))
else
  echo "FAIL: drift reporting (expected True, got '$drift_out')"
  fail=$((fail + 1))
fi

# --- Test 9: malformed marker → exit 2 ---
echo "not json" > "$TMP/m9.json"
set +e
"$FILTER" "$TMP/m9.json" "$TMP/s8.list" >/dev/null 2>&1
ec=$?
set -e
if [ "$ec" -eq 2 ]; then
  echo "PASS: malformed marker → exit 2"
  pass=$((pass + 1))
else
  echo "FAIL: malformed marker should exit 2, got $ec"
  fail=$((fail + 1))
fi

# --- Test 10: missing marker → exit 3 ---
set +e
"$FILTER" "$TMP/nonexistent.json" "$TMP/s8.list" >/dev/null 2>&1
ec=$?
set -e
if [ "$ec" -eq 3 ]; then
  echo "PASS: missing marker → exit 3"
  pass=$((pass + 1))
else
  echo "FAIL: missing marker should exit 3, got $ec"
  fail=$((fail + 1))
fi

echo ""
echo "Total: $((pass + fail)) | Passed: $pass | Failed: $fail"
[ "$fail" -eq 0 ]
