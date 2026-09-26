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

section "the rewritten aggregator's step, EXECUTED (not grepped) against the four result shapes"
# Pull the `run:` body out of the tool's AGGREGATOR_RUN template and run it as
# the workflow would, with RESULTS (toJSON(needs)) and MECHANICAL in the
# environment. Margot's finding on dotty #361: the step was tested only by its
# name; an inverted jq would have passed.
AGG_RUN="$TMP/agg-run.sh"
python3 - "$TOOL" "$AGG_RUN" <<'PY'
import importlib.util, sys, textwrap
spec = importlib.util.spec_from_file_location("ccm", sys.argv[1]); m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
lines = m.AGGREGATOR_RUN.split("\n")
i = next(k for k, l in enumerate(lines) if l.strip() == "run: |")
open(sys.argv[2], "w").write(textwrap.dedent("\n".join(lines[i + 1:])))
PY
agg() {
	RESULTS="$1" MECHANICAL="$2" bash "$AGG_RUN" >/dev/null 2>&1
	echo $?
}
assert_eq "all success, functional -> pass" "0" "$(agg '{"floor":{"result":"success"},"tests":{"result":"success"}}' false)"
assert_eq "one failure -> fail" "1" "$(agg '{"floor":{"result":"success"},"tests":{"result":"failure"}}' false)"
assert_eq "one cancelled -> fail" "1" "$(agg '{"floor":{"result":"success"},"tests":{"result":"cancelled"}}' false)"
assert_eq "own job skipped on a MECHANICAL PR -> pass" "0" "$(agg '{"floor":{"result":"success"},"tests":{"result":"skipped"}}' true)"
assert_eq "own job skipped on a FUNCTIONAL PR -> fail" "1" "$(agg '{"floor":{"result":"success"},"tests":{"result":"skipped"}}' false)"
assert_eq "own job skipped, MECHANICAL unset (no triage) -> fail" "1" "$(agg '{"floor":{"result":"success"},"tests":{"result":"skipped"}}' '')"
assert_eq "the floor itself failed on a mechanical PR -> fail" "1" "$(agg '{"floor":{"result":"failure"},"tests":{"result":"skipped"}}' true)"

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

section "an empty needs: value becomes [floor], never [floor, ] (the two paths share one helper)"
cat >"$TMP/empty-needs.yml" <<'EOF'
jobs:
  universal-ci:
    uses: x
  all-checks-passed:
    needs:
    if: always()
    runs-on: ubuntu-latest
    steps:
      - run: echo
  tests:
    needs:
    runs-on: ubuntu-latest
EOF
# `needs:` with nothing after it is a multi-line shape for the gate path (refused);
# make the aggregator case explicit with an inline empty list instead.
sed -i.bak 's/^    needs:$/    needs: []/' "$TMP/empty-needs.yml"
out="$(merge "$TMP/empty-needs.yml")"
grep -q 'needs: \[floor, \]' <<<"$out" && fail "no dangling comma in needs" "$out" || pass "no dangling comma in needs"
grep -c 'needs: \[floor\]' <<<"$out" | grep -q '^2$' && pass "both empty needs became [floor]" || fail "both empty needs became [floor]" "$out"
grep -q 'import yaml' "$TOOL" && fail "stdlib only: no PyYAML import" || pass "stdlib only: no PyYAML import"

finish
