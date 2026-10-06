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
# Check names follow `<lane> / <what>` (check-name rename, 2026-09-27): the
# caller job is named `ci` and passes `check_name: checks` -> `ci / checks`.
awk '/^  floor:$/{f=1;next} f&&/^  [a-z]/{exit} f' <<<"$out" | grep -q '^    name: ci$' && pass "floor caller job named ci" || fail "floor named ci" "$out"
grep -q '^      check_name: checks$' <<<"$out" && pass "floor passes check_name: checks" || fail "check_name checks" "$out"
# The floor job grants exactly the three read scopes the lane uses (Margot on
# dotty #364: nothing pinned the grant; deleting it would bring back the 403 on
# a private repo's triage read with every suite green).
blk="$(awk '/^  floor:$/{f=1;next} f&&/^  [a-z]/{exit} f' <<<"$out")"
for sc in 'contents: read' 'pull-requests: read' 'checks: read'; do
	grep -q "^      ${sc}\$" <<<"$blk" && pass "floor job grants ${sc}" || fail "floor job grants ${sc}" "$blk"
done
grep -qE ': write$' <<<"$blk" && fail "floor job grants no write scope" "$blk" || pass "floor job grants no write scope"
grep -q 'all-checks-passed' <<<"$out" && fail "aggregator deleted" "$out" || pass "aggregator deleted"
grep -q '# the shared floor' <<<"$out" && pass "comments outside the replaced block survive" || fail "comments survive" "$out"
printf '%s\n' "$out" >"$TMP/plain.merged.yml"
assert_eq "idempotent on its own output" "" "$(diff <(merge "$TMP/plain.merged.yml") "$TMP/plain.merged.yml")"

section "own jobs: gated on the floor; the aggregator deleted there too (one CI shape everywhere); existing needs/if merged"
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
grep -q 'all-checks-passed\|all-passed' <<<"$out" && fail "aggregator deleted in a repo with own jobs" "$out" || pass "aggregator deleted in a repo with own jobs"
awk '/^  tests:$/{f=1;next} f&&/^    name:/{print;exit}' <<<"$out" | grep -q 'name: ci / tests$' && pass "own job named ci / <id>" || fail "own job name" "$out"
awk '/^  tests:/{f=1} f&&/^    needs:/{print; exit}' <<<"$out" | grep -q 'needs: \[floor\]' && pass "tests: needs [floor] inserted" || fail "tests needs" "$out"
awk '/^  tests:/{f=1} f&&/^    if:/{print; exit}' <<<"$out" | grep -q "needs.floor.outputs.mechanical != 'true'" && pass "tests: mechanical if inserted" || fail "tests if" "$out"
awk '/^  release-tag:/{f=1} f&&/^    if:/{print; exit}' <<<"$out" | grep -q "(github.event_name == 'push') && needs.floor.outputs.mechanical != 'true'" && pass "release-tag: existing if combined" || fail "release-tag if" "$out"
awk '/^  release-tag:/{f=1} f&&/^    needs:/{print; exit}' <<<"$out" | grep -q 'needs: \[floor, tests\]' && pass "release-tag: floor prepended to existing needs" || fail "release-tag needs" "$out"
printf '%s\n' "$out" >"$TMP/own.merged.yml"
assert_eq "idempotent on its own output" "" "$(diff <(merge "$TMP/own.merged.yml") "$TMP/own.merged.yml")"
python3 -c "import yaml,sys; yaml.safe_load(open(sys.argv[1]))" "$TMP/own.merged.yml" && pass "result is valid YAML" || fail "valid YAML"

section "refusals: shapes a line edit would mangle exit 1; not a caller exits 2; nothing written"
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
assert_eq "multi-line needs refused with exit 1" "1" "$rc"
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
assert_eq "folded if refused with exit 1" "1" "$rc"
cat >"$TMP/both.yml" <<'EOF'
jobs:
  universal-ci:
    uses: x
  floor:
    runs-on: ubuntu-latest
EOF
merge "$TMP/both.yml" >/dev/null 2>&1
rc=$?
assert_eq "universal-ci beside a pre-existing floor refused with exit 1" "1" "$rc"
cat >"$TMP/none.yml" <<'EOF'
jobs:
  tests:
    runs-on: ubuntu-latest
EOF
merge "$TMP/none.yml" >/dev/null 2>&1
rc=$?
assert_eq "no universal-ci/floor -> exit 2 (not a caller we own; the provisioner skips, not drifts)" "2" "$rc"

section "an aggregator with a block-list needs: is deleted whole, never left with dangling items (Margot's F5 on dotty #361)"
cat >"$TMP/agg-multiline.yml" <<'EOF'
jobs:
  universal-ci:
    uses: x
  all-checks-passed:
    needs:
      - universal-ci
      - tests
    if: always()
    runs-on: ubuntu-latest
    steps:
      - run: echo
  tests:
    runs-on: ubuntu-latest
EOF
out="$(merge "$TMP/agg-multiline.yml")"
rc=$?
assert_eq "aggregator with block-list needs: exit 0" "0" "$rc"
grep -q -- '- universal-ci\|- tests\|all-checks-passed' <<<"$out" && fail "no dangling needs items" "$out" || pass "no dangling needs items"

section "a comment above the job after a DELETED aggregator survives"
cat >"$TMP/agg-trailing.yml" <<'EOF'
jobs:
  universal-ci:
    uses: x
  all-checks-passed:
    needs: [universal-ci]
    if: always()
    runs-on: ubuntu-latest
    steps:
      - run: echo
  # keep me: about the next section
EOF
out="$(merge "$TMP/agg-trailing.yml")"
grep -q '# keep me: about the next section' <<<"$out" && pass "trailing comment kept on delete" || fail "trailing comment kept on delete" "$out"

section "the per-repo override: a job marked \`# floor: always-run\` is left exactly as written"
cat >"$TMP/always.yml" <<'EOF'
jobs:
  universal-ci:
    uses: x
  all-checks-passed:
    needs: [universal-ci, release-check, tests]
    if: always()
    runs-on: ubuntu-latest
    steps:
      - run: echo
  release-check:
    # floor: always-run
    needs: [universal-ci]
    if: github.event_name == 'pull_request'
    runs-on: ubuntu-latest
    steps:
      - run: check
  tests:
    runs-on: ubuntu-latest
EOF
out="$(merge "$TMP/always.yml")"
blk="$(awk '/^  release-check:$/{f=1;print;next} f&&/^  [a-z]/{exit} f' <<<"$out")"
grep -q 'needs: \[floor\]$' <<<"$blk" && pass "always-run job: needs universal-ci renamed to floor (no dangling job)" || fail "always-run needs renamed" "$blk"
grep -q 'universal-ci' <<<"$blk" && fail "always-run job names no retired job" "$blk" || pass "always-run job names no retired job"
grep -q "mechanical" <<<"$blk" && fail "always-run job is not gated" "$blk" || pass "always-run job is not gated"
grep -q "if: github.event_name == 'pull_request'\$" <<<"$blk" && pass "always-run job keeps its own if: untouched" || fail "always-run if untouched" "$blk"
awk '/^  tests:$/{f=1} f&&/^    if:/{print; exit}' <<<"$out" | grep -q "mechanical != 'true'" && pass "an unmarked job is still gated" || fail "unmarked job gated" "$out"
printf '%s\n' "$out" >"$TMP/always.merged.yml"
assert_eq "idempotent with an always-run job" "" "$(diff <(merge "$TMP/always.merged.yml") "$TMP/always.merged.yml")"

section "a job key with a trailing comment is named by its id, never the raw line (Margot on dotty #370)"
cat >"$TMP/commented-key.yml" <<'EOF'
jobs:
  universal-ci:
    uses: x
  tests:  # the repo's own tests
    runs-on: ubuntu-latest
EOF
out="$(merge "$TMP/commented-key.yml")"
grep -q '^    name: ci / tests$' <<<"$out" && pass "commented key named ci / tests" || fail "commented key name" "$out"
grep -q 'name: ci / tests:' <<<"$out" && fail "no raw key line in the name" "$out" || pass "no raw key line in the name"

section "an empty needs: value becomes [floor], never [floor, ] (the two paths share one helper)"
cat >"$TMP/empty-needs.yml" <<'EOF'
jobs:
  universal-ci:
    uses: x
  tests:
    needs:
    runs-on: ubuntu-latest
EOF
# `needs:` with nothing after it is a multi-line shape for the gate path (refused);
# make the case explicit with an inline empty list instead.
sed -i.bak 's/^    needs:$/    needs: []/' "$TMP/empty-needs.yml"
out="$(merge "$TMP/empty-needs.yml")"
grep -q 'needs: \[floor, \]' <<<"$out" && fail "no dangling comma in needs" "$out" || pass "no dangling comma in needs"
grep -q 'needs: \[floor\]' <<<"$out" && pass "empty needs became [floor]" || fail "empty needs became [floor]" "$out"
grep -q 'import yaml' "$TOOL" && fail "stdlib only: no PyYAML import" || pass "stdlib only: no PyYAML import"

section "the personal-skills shape: release-check/release-tag call a reusable workflow -- passed through byte-unchanged (not renamed, not gated)"
cat >"$TMP/personal-skills.yml" <<'EOF'
name: CI
jobs:
  floor:
    name: ci
    permissions:
      contents: read
      pull-requests: read
      checks: read
    uses: lexijamesesq/dotty/.github/workflows/estate-ci.yml@v1
    with:
      dotty_ref: v1
      check_name: checks

  validate-and-test:
    name: ci / validate-and-test
    needs: [floor]
    if: ${{ needs.floor.outputs.mechanical != 'true' }}
    runs-on: ubuntu-latest
    steps:
      - run: claude plugin validate --strict .

  release-check:
    name: ci
    # floor: always-run
    if: github.event_name == 'pull_request'
    permissions:
      contents: read
    uses: lexijamesesq/dotty/.github/workflows/estate-plugin-release.yml@v1
    with:
      dotty_ref: v1
      plugins: '[{"path":".","name":"personal"}]'

  release-tag:
    name: ci
    if: ${{ (github.event_name == 'push') && needs.floor.outputs.mechanical != 'true' }}
    needs: [floor, validate-and-test]
    permissions:
      contents: write
    uses: lexijamesesq/dotty/.github/workflows/estate-plugin-release.yml@v1
    with:
      dotty_ref: v1
      plugins: '[{"path":".","name":"personal"}]'
EOF
out="$(merge "$TMP/personal-skills.yml")"
rc=$?
assert_eq "exit 0" "0" "$rc"
rc_blk="$(awk '/^  release-check:$/{f=1;next} f&&/^  [a-z]/{exit} f' <<<"$out")"
rt_blk="$(awk '/^  release-tag:$/{f=1;next} f&&/^  [a-z]/{exit} f' <<<"$out")"
# Byte-unchanged, including the job key line itself: extract the SAME span
# (key line through the line before the next top-level job key) from both
# the original input and the merged output, and compare with plain string
# equality -- not grep, which treats an embedded-newline pattern as a
# (never-matching) single line and would silently pass a changed block.
in_rc="$(awk '/^  release-check:$/{f=1;print;next} f&&/^  [a-z]/{exit} f' "$TMP/personal-skills.yml")"
out_rc="$(awk '/^  release-check:$/{f=1;print;next} f&&/^  [a-z]/{exit} f' <<<"$out")"
in_rt="$(awk '/^  release-tag:$/{f=1;print;next} f&&/^  [a-z]/{exit} f' "$TMP/personal-skills.yml")"
out_rt="$(awk '/^  release-tag:$/{f=1;print;next} f&&/^  [a-z]/{exit} f' <<<"$out")"
[ "$in_rc" = "$out_rc" ] && pass "release-check byte-unchanged" || fail "release-check byte-unchanged" "$out_rc"
[ "$in_rt" = "$out_rt" ] && pass "release-tag byte-unchanged" || fail "release-tag byte-unchanged" "$out_rt"
grep -q '^    name: ci$' <<<"$rc_blk" && pass "release-check name: ci, not ci / release-check" || fail "release-check name untouched" "$rc_blk"
grep -q '^    name: ci$' <<<"$rt_blk" && pass "release-tag name: ci, not ci / release-tag" || fail "release-tag name untouched" "$rt_blk"
grep -q 'mechanical' <<<"$rc_blk" && fail "release-check gets no mechanical clause added" "$rc_blk" || pass "release-check gets no mechanical clause added"
grep -q 'needs: \[floor, validate-and-test\]$' <<<"$rt_blk" && pass "release-tag's own needs: untouched (not rewritten/reordered)" || fail "release-tag needs untouched" "$rt_blk"
printf '%s\n' "$out" >"$TMP/personal-skills.merged.yml"
assert_eq "idempotent on its own output" "" "$(diff <(merge "$TMP/personal-skills.merged.yml") "$TMP/personal-skills.merged.yml")"

section "the wiki shape: release-tag calling a reusable workflow with NO needs: at all -- none added"
cat >"$TMP/wiki.yml" <<'EOF'
name: CI
jobs:
  floor:
    name: ci
    uses: lexijamesesq/dotty/.github/workflows/estate-ci.yml@v1
    with:
      dotty_ref: v1
      check_name: checks

  gate:
    name: ci / gate
    needs: [floor]
    if: ${{ needs.floor.outputs.mechanical != 'true' }}
    runs-on: ubuntu-latest
    steps:
      - run: claude plugin validate --strict .

  release-check:
    name: ci
    # floor: always-run
    if: github.event_name == 'pull_request'
    permissions:
      contents: read
    uses: lexijamesesq/dotty/.github/workflows/estate-plugin-release.yml@v1
    with:
      dotty_ref: v1
      plugins: '[{"path":".","name":"wiki"}]'

  release-tag:
    name: ci
    if: github.event_name == 'push'
    permissions:
      contents: write
    uses: lexijamesesq/dotty/.github/workflows/estate-plugin-release.yml@v1
    with:
      dotty_ref: v1
      node_version: '24'
      plugins: '[{"path":".","name":"wiki"}]'
EOF
out="$(merge "$TMP/wiki.yml")"
rc=$?
assert_eq "exit 0" "0" "$rc"
rt_blk="$(awk '/^  release-tag:$/{f=1;next} f&&/^  [a-z]/{exit} f' <<<"$out")"
grep -q 'needs:' <<<"$rt_blk" && fail "release-tag gets no needs: added (wiki deliberately has none)" "$rt_blk" || pass "release-tag gets no needs: added (wiki deliberately has none)"
grep -q "if: github.event_name == 'push'\$" <<<"$rt_blk" && pass "release-tag's if: stays the bare push check, no mechanical clause folded in" || fail "release-tag if: untouched" "$rt_blk"
grep -q '^    name: ci$' <<<"$rt_blk" && pass "release-tag name: ci, not ci / release-tag" || fail "release-tag name untouched" "$rt_blk"
printf '%s\n' "$out" >"$TMP/wiki.merged.yml"
assert_eq "idempotent on its own output" "" "$(diff <(merge "$TMP/wiki.merged.yml") "$TMP/wiki.merged.yml")"

section "a reusable-calling job beside an ordinary job: only the ordinary one is renamed and gated"
cat >"$TMP/mixed.yml" <<'EOF'
name: CI
jobs:
  floor:
    name: ci
    uses: lexijamesesq/dotty/.github/workflows/estate-ci.yml@v1
    with:
      dotty_ref: v1
  release-check:
    name: ci
    # floor: always-run
    if: github.event_name == 'pull_request'
    uses: lexijamesesq/dotty/.github/workflows/estate-plugin-release.yml@v1
    with:
      dotty_ref: v1
      plugins: '[{"path":".","name":"x"}]'
  tests:
    runs-on: ubuntu-latest
    steps:
      - run: pytest
EOF
out="$(merge "$TMP/mixed.yml")"
awk '/^  release-check:$/{f=1;next} f&&/^  [a-z]/{exit} f' <<<"$out" | grep -q '^    name: ci$' &&
	pass "the reusable-calling job (release-check) keeps name: ci" || fail "release-check name" "$out"
awk '/^  tests:$/{f=1;next} f&&/^  [a-z]/{exit} f' <<<"$out" | grep -q '^    name: ci / tests$' &&
	pass "the ordinary job (tests) is still renamed ci / tests" || fail "tests name" "$out"
awk '/^  tests:$/{f=1;next} f&&/^  [a-z]/{exit} f' <<<"$out" | grep -q "mechanical != 'true'" &&
	pass "the ordinary job (tests) is still gated on the floor" || fail "tests gated" "$out"

section "a reusable-calling job's needs: still renames universal-ci -> floor (the one rewrite every job gets)"
cat >"$TMP/reusable-needs.yml" <<'EOF'
name: CI
jobs:
  universal-ci:
    uses: lexijamesesq/dotty/.github/workflows/estate-ci.yml@v1
    with:
      dotty_ref: v1
  validate-and-test:
    runs-on: ubuntu-latest
    steps:
      - run: test
  release-tag:
    name: ci
    if: github.event_name == 'push'
    needs: [universal-ci, validate-and-test]
    permissions:
      contents: write
    uses: lexijamesesq/dotty/.github/workflows/estate-plugin-release.yml@v1
    with:
      dotty_ref: v1
      plugins: '[{"path":".","name":"x"}]'
EOF
out="$(merge "$TMP/reusable-needs.yml")"
rc=$?
assert_eq "exit 0" "0" "$rc"
rt_blk="$(awk '/^  release-tag:$/{f=1;next} f&&/^  [a-z]/{exit} f' <<<"$out")"
grep -q '^    needs: \[floor, validate-and-test\]$' <<<"$rt_blk" &&
	pass "release-tag: universal-ci renamed to floor in needs:, order preserved (rewrite_needs' own rule)" ||
	fail "release-tag needs: renamed" "$rt_blk"
grep -q '^    name: ci$' <<<"$rt_blk" && pass "release-tag's name: still untouched (ci, not ci / release-tag)" || fail "release-tag name touched" "$rt_blk"
grep -q "^    if: github.event_name == 'push'\$" <<<"$rt_blk" && pass "release-tag's if: still untouched, no mechanical clause added" || fail "release-tag if: touched" "$rt_blk"
printf '%s\n' "$out" >"$TMP/reusable-needs.merged.yml"
assert_eq "idempotent on its own output" "" "$(diff <(merge "$TMP/reusable-needs.merged.yml") "$TMP/reusable-needs.merged.yml")"

finish
