#!/usr/bin/env bash
# run-golden-fixtures.sh — exercise the pre-pass tier against each golden fixture
# and assert findings match expected.
#
# Each fixture directory has:
#   - input/         — files to scan
#   - expected.json  — { description, tier, expected_finding_count, expected_findings: [...] }
#
# This v1 runner covers the deterministic (pre-pass) tier. LLM-judgment-tier
# fixtures need full /github-prep invocation per fixture (~100s each); those are
# Stage 5 work.
#
# Usage:
#   run-golden-fixtures.sh [--filter <fixture-name-substring>]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
FIXTURES_DIR="${FIXTURES_DIR:-$SCRIPT_DIR/golden-fixtures}"
PREPASS="${PREPASS:-$SCRIPT_DIR/../lib/github-prep-prepass.sh}"

FILTER="${2:-}"
[ "${1:-}" = "--filter" ] && FILTER="$2"

pass=0
fail=0
total=0

run_fixture() {
  local fixture_dir="$1"
  local name
  name=$(basename "$fixture_dir")

  [ -n "$FILTER" ] && [[ "$name" != *"$FILTER"* ]] && return 0

  total=$((total + 1))

  if [ ! -d "$fixture_dir/input" ]; then
    echo "FAIL ($name): no input/ directory"
    fail=$((fail + 1))
    return 0
  fi

  if [ ! -f "$fixture_dir/expected.json" ]; then
    echo "FAIL ($name): no expected.json"
    fail=$((fail + 1))
    return 0
  fi

  local tier expected_count
  tier=$(python3 -c "import json; print(json.load(open('$fixture_dir/expected.json'))['tier'])")

  if [ "$tier" != "prepass" ]; then
    echo "SKIP ($name): tier=$tier (this runner covers prepass only)"
    return 0
  fi

  expected_count=$(python3 -c "import json; print(json.load(open('$fixture_dir/expected.json'))['expected_finding_count'])")

  # Build NUL-separated file list of input/
  local file_list
  file_list=$(mktemp)
  (cd "$fixture_dir/input" && find . -type f ! -name '.*' -print0 | sed 's|\./||g' > "$file_list" 2>/dev/null) \
    || (cd "$fixture_dir/input" && find . -type f ! -name '.*' -print0 > "$file_list")

  # Run prepass on the input/ as a pseudo-repo
  local actual_output
  actual_output=$("$PREPASS" "$fixture_dir/input" < "$file_list" 2>&1)
  local actual_count
  actual_count=$(echo "$actual_output" | grep -c '"category"' || true)

  rm -f "$file_list"

  if [ "$actual_count" -ne "$expected_count" ]; then
    echo "FAIL ($name): expected $expected_count finding(s), got $actual_count"
    if [ "$actual_count" -gt 0 ]; then
      echo "  Actual output:"
      echo "$actual_output" | sed 's/^/    /'
    fi
    fail=$((fail + 1))
    return 0
  fi

  # For each expected finding, assert a matching actual exists.
  local expected_findings_count
  expected_findings_count=$(python3 -c "import json; print(len(json.load(open('$fixture_dir/expected.json'))['expected_findings']))")

  local match_failures=0

  if [ "$expected_findings_count" -eq 0 ]; then
    # Clean fixture: expected_count was 0 (already verified above); no findings to match.
    echo "PASS ($name): clean (no findings expected, none produced)"
    pass=$((pass + 1))
    return 0
  fi

  for i in $(seq 0 $((expected_findings_count - 1))); do
    local cat verdict file line snippet_contains
    cat=$(python3 -c "import json; print(json.load(open('$fixture_dir/expected.json'))['expected_findings'][$i]['category'])")
    verdict=$(python3 -c "import json; print(json.load(open('$fixture_dir/expected.json'))['expected_findings'][$i]['verdict'])")
    file=$(python3 -c "import json; print(json.load(open('$fixture_dir/expected.json'))['expected_findings'][$i]['file'])")
    line=$(python3 -c "import json; print(json.load(open('$fixture_dir/expected.json'))['expected_findings'][$i]['line'])")
    snippet_contains=$(python3 -c "import json; print(json.load(open('$fixture_dir/expected.json'))['expected_findings'][$i].get('snippet_contains', ''))")

    if ! echo "$actual_output" | python3 -c "
import json, sys
expected = {'category': '$cat', 'verdict': '$verdict', 'file': '$file', 'line': $line, 'snippet_contains': '''$snippet_contains'''}
found = False
for raw in sys.stdin:
    raw = raw.strip()
    if not raw:
        continue
    try:
        f = json.loads(raw)
    except:
        continue
    if (f.get('category') == expected['category']
        and f.get('verdict') == expected['verdict']
        and f.get('file') == expected['file']
        and int(f.get('line', -1)) == expected['line']
        and expected['snippet_contains'] in f.get('snippet', '')):
        found = True
        break
sys.exit(0 if found else 1)
"; then
      echo "FAIL ($name): expected finding #$i not found (category=$cat verdict=$verdict file=$file line=$line snippet_contains=$snippet_contains)"
      match_failures=$((match_failures + 1))
    fi
  done

  if [ "$match_failures" -eq 0 ]; then
    echo "PASS ($name): $actual_count finding(s), all expected verdicts matched"
    pass=$((pass + 1))
  else
    fail=$((fail + 1))
  fi
}

for fixture_dir in "$FIXTURES_DIR"/*/; do
  [ -d "$fixture_dir" ] || continue
  run_fixture "$fixture_dir"
done

echo ""
echo "Total: $total | Passed: $pass | Failed: $fail"
[ "$fail" -eq 0 ]
