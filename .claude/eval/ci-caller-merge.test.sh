#!/usr/bin/env bash
# ci-caller-merge.py: the text transform that brings a caller's ci.yml onto the
# floor-first shape. Asserts the shapes it must handle (plain; own jobs with and
# without needs/if; renamed needs; idempotence) and the shapes it must REFUSE
# rather than mangle (multi-line needs/if, a pre-existing floor beside
# universal-ci, no universal-ci at all) -- attack-kitty's finding on the first
# draft: a line-based edit that silently rewrote those would have quietly left
# a repo's own job running on mechanical PRs.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=lib/assert.sh
source "$SCRIPT_DIR/lib/assert.sh"
TOOL="$REPO/.github/scripts/ci-caller-merge.py"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

merge() { python3 "$TOOL" --ref v1 --in "$1"; }
required() { python3 "$TOOL" --ref v1 --in "$1" --plain-required; }

section "plain caller: universal-ci + aggregator -> one floor job, no secrets, no aggregator"
cat >"$TMP/plain.yml" <<'EOF'
name: CI
on:
  pull_request:
  push:
    branches: [main]
permissions:
  contents: read
jobs:
  # the shared floor
  universal-ci:
    uses: lexijamesesq/dotty/.github/workflows/estate-ci.yml@v2026.09.01
    with:
      dotty_ref: v2026.09.01
  all-checks-passed:
    needs: [universal-ci]
    if: always()
    runs-on: ubuntu-latest
    steps:
      - run: echo ok
EOF
out="$(merge "$TMP/plain.yml")"
rc=$?
assert_eq "exit 0" "0" "$rc"
grep -q '^  floor:$' <<<"$out" && pass "floor job present" || fail "floor job present" "$out"
grep -q 'estate-ci.yml@v1' <<<"$out" && grep -q 'dotty_ref: v1' <<<"$out" && pass "pinned to the requested ref" || fail "pin" "$out"
grep -q 'secrets' <<<"$out" && fail "no secrets in the untrusted lane" "$out" || pass "no secrets in the untrusted lane"
grep -q 'all-checks-passed' <<<"$out" && fail "aggregator deleted when the repo has no own jobs" "$out" || pass "aggregator deleted when the repo has no own jobs"
grep -q '# the shared floor' <<<"$out" && pass "comments outside the replaced block survive" || fail "comments survive" "$out"
assert_eq "required context for a plain repo" "floor / floor" "$(required "$TMP/plain.yml")"
printf '%s\n' "$out" >"$TMP/plain.merged.yml"
assert_eq "idempotent on its own output" "" "$(diff <(merge "$TMP/plain.merged.yml") "$TMP/plain.merged.yml")"

section "own jobs: gated on the floor; aggregator kept and rewritten; existing needs/if merged"
cat >"$TMP/own.yml" <<'EOF'
name: CI
on:
  pull_request:
jobs:
  universal-ci:
    uses: lexijamesesq/dotty/.github/workflows/estate-ci.yml@v1
  all-checks-passed:
    needs: [universal-ci, tests, release-tag]
    if: always()
    runs-on: ubuntu-latest
    steps:
      - run: old aggregator
  tests:
    runs-on: ubuntu-latest
    steps:
      - run: pytest
  release-tag:
    if: github.event_name == 'push'
    needs: [tests]
    runs-on: ubuntu-latest
    steps:
      - run: tag
EOF
out="$(merge "$TMP/own.yml")"
rc=$?
assert_eq "exit 0" "0" "$rc"
assert_eq "required context for a repo with own jobs" "all-checks-passed" "$(required "$TMP/own.yml")"
grep -q 'needs: \[floor, tests, release-tag\]' <<<"$out" && pass "aggregator needs renamed universal-ci -> floor" || fail "aggregator needs" "$out"
grep -q 'skipped on a mechanical PR is satisfied' <<<"$out" && pass "aggregator step rewritten (skipped-when-mechanical satisfied)" || fail "aggregator rewrite" "$out"
grep -q 'old aggregator' <<<"$out" && fail "old aggregator step replaced" "$out" || pass "old aggregator step replaced"
awk '/^  tests:/{f=1} f&&/^    needs:/{print; exit}' <<<"$out" | grep -q 'needs: \[floor\]' && pass "tests: needs [floor] inserted" || fail "tests needs" "$out"
awk '/^  tests:/{f=1} f&&/^    if:/{print; exit}' <<<"$out" | grep -q "needs.floor.outputs.mechanical != 'true'" && pass "tests: mechanical if inserted" || fail "tests if" "$out"
awk '/^  release-tag:/{f=1} f&&/^    if:/{print; exit}' <<<"$out" | grep -q "(github.event_name == 'push') && needs.floor.outputs.mechanical != 'true'" && pass "release-tag: existing if combined" || fail "release-tag if" "$out"
awk '/^  release-tag:/{f=1} f&&/^    needs:/{print; exit}' <<<"$out" | grep -q 'needs: \[floor, tests\]' && pass "release-tag: floor prepended to existing needs" || fail "release-tag needs" "$out"
printf '%s\n' "$out" >"$TMP/own.merged.yml"
assert_eq "idempotent on its own output" "" "$(diff <(merge "$TMP/own.merged.yml") "$TMP/own.merged.yml")"
python3 -c "import yaml,sys; yaml.safe_load(open(sys.argv[1]))" "$TMP/own.merged.yml" && pass "result is valid YAML" || fail "valid YAML"

section "refusals: shapes a line edit would mangle exit non-zero and write nothing"
cat >"$TMP/multiline-needs.yml" <<'EOF'
jobs:
  universal-ci:
    uses: x
  tests:
    needs:
      - universal-ci
    runs-on: ubuntu-latest
EOF
merge "$TMP/multiline-needs.yml" >/dev/null 2>"$TMP/err"
rc=$?
[[ $rc -ne 0 ]] && pass "multi-line needs refused" || fail "multi-line needs refused" "rc=$rc"
grep -q 'edit by hand' "$TMP/err" && pass "refusal says edit by hand" || fail "refusal wording" "$(cat "$TMP/err")"
cat >"$TMP/folded-if.yml" <<'EOF'
jobs:
  universal-ci:
    uses: x
  tests:
    if: >-
      github.event_name == 'push'
    runs-on: ubuntu-latest
EOF
merge "$TMP/folded-if.yml" >/dev/null 2>&1
rc=$?
[[ $rc -ne 0 ]] && pass "folded if refused" || fail "folded if refused" "rc=$rc"
cat >"$TMP/both.yml" <<'EOF'
jobs:
  universal-ci:
    uses: x
  floor:
    runs-on: ubuntu-latest
EOF
merge "$TMP/both.yml" >/dev/null 2>&1
rc=$?
[[ $rc -ne 0 ]] && pass "universal-ci beside a pre-existing floor refused" || fail "both refused" "rc=$rc"
cat >"$TMP/none.yml" <<'EOF'
jobs:
  tests:
    runs-on: ubuntu-latest
EOF
merge "$TMP/none.yml" >/dev/null 2>&1
rc=$?
[[ $rc -ne 0 ]] && pass "no universal-ci/floor refused (not a caller we own)" || fail "none refused" "rc=$rc"

finish
