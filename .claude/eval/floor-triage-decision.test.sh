#!/usr/bin/env bash
# The floor's "mechanical" decision -- the jq that reads Jev's `margot-triage`
# check and decides whether a PR skips lint, tests and the council. It lives in
# two workflows (estate-gate.yml, the trusted lane; estate-ci.yml, the untrusted
# lane) and floats to every enrolled repo via @v1, so a regression would pass
# every check and land everywhere. Margot's finding on dotty #361: it had no
# eval and none of the PR's own checks ran it. This suite extracts the two jq
# programs FROM THE WORKFLOW FILES (never a copy) and executes them.
# (JSON literals are single-quoted throughout: bash 3.2 on macOS mis-parses
# backslash-escaped quotes inside a double-quoted $(...) and splits the word.)
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=lib/assert.sh
source "$SCRIPT_DIR/lib/assert.sh"
GATE="$REPO/.github/workflows/estate-gate.yml"
CI="$REPO/.github/workflows/estate-ci.yml"

# The decision program: the single-quoted jq argument on the line that carries
# `if (type=="object"`. The selection program: the --jq argument on the line
# that picks the newest completed check.
decision_prog() { grep -oE "'if \(type==\"object\".*\"false\" end'" "$1" | head -1 | sed "s/^'//; s/'$//"; }
select_prog() { grep -oE -- "--jq '\[\.check_runs\[\].*// empty'" "$1" | head -1 | sed "s/^--jq '//; s/'$//"; }

section "one program, two lanes"
D_GATE="$(decision_prog "$GATE")"
D_CI="$(decision_prog "$CI")"
S_GATE="$(select_prog "$GATE")"
S_CI="$(select_prog "$CI")"
[[ -n "$D_GATE" ]] && pass "decision program found in estate-gate.yml" || fail "decision program found in estate-gate.yml"
[[ -n "$S_GATE" ]] && pass "selection program found in estate-gate.yml" || fail "selection program found in estate-gate.yml"
assert_eq "decision program identical in both lanes" "$D_GATE" "$D_CI"
assert_eq "selection program identical in both lanes" "$S_GATE" "$S_CI"

SHA=deadbeefcafe0000000000000000000000000001
decide() { printf '%s' "$1" | jq -r --arg sha "$SHA" "$D_GATE" 2>/dev/null || echo false; }

section "the decision: mechanical only on Jev's literal answer for this head"
assert_eq "jev + mechanical + this head -> true" "true" \
	"$(decide '{"mechanical":true,"p":0.97,"decision_source":"jev","reason":"version bump","head_sha":"'"$SHA"'"}')"
assert_eq "another head's answer -> false" "false" \
	"$(decide '{"mechanical":true,"decision_source":"jev","head_sha":"0000000000000000000000000000000000000000"}')"
assert_eq "not from jev (heuristic) -> false" "false" \
	"$(decide '{"mechanical":true,"decision_source":"heuristic","head_sha":"'"$SHA"'"}')"
assert_eq "jev says functional -> false" "false" \
	"$(decide '{"mechanical":false,"decision_source":"jev","head_sha":"'"$SHA"'"}')"
assert_eq "mechanical as a string, not a boolean -> false" "false" \
	"$(decide '{"mechanical":"true","decision_source":"jev","head_sha":"'"$SHA"'"}')"
assert_eq "a bare string (a title leaked into text) -> false" "false" "$(decide '"mechanical"')"
assert_eq "an array -> false" "false" "$(decide '[true]')"
assert_eq "missing head_sha -> false" "false" "$(decide '{"mechanical":true,"decision_source":"jev"}')"
assert_eq "unparseable text -> false (jq fails, the workflow's || echo false)" "false" "$(decide 'not json at all')"
assert_eq "empty object -> false" "false" "$(decide '{}')"

section "the selection: newest COMPLETED margot-triage run wins; nothing completed -> empty"
pick() { printf '%s' "$1" | jq -r "$S_GATE"; }
assert_eq "one completed run -> its text" 'A' \
	"$(pick '{"check_runs":[{"status":"completed","started_at":"2026-09-26T10:00:00Z","id":1,"output":{"text":"A"}}]}')"
assert_eq "in_progress newer than a completed one -> the completed one" 'A' \
	"$(pick '{"check_runs":[{"status":"in_progress","started_at":"2026-09-26T10:05:00Z","id":2,"output":{"text":null}},{"status":"completed","started_at":"2026-09-26T10:00:00Z","id":1,"output":{"text":"A"}}]}')"
assert_eq "two completed -> the later started_at" 'B' \
	"$(pick '{"check_runs":[{"status":"completed","started_at":"2026-09-26T10:00:00Z","id":1,"output":{"text":"A"}},{"status":"completed","started_at":"2026-09-26T10:05:00Z","id":2,"output":{"text":"B"}}]}')"
assert_eq "same started_at -> the higher id" 'B' \
	"$(pick '{"check_runs":[{"status":"completed","started_at":"2026-09-26T10:00:00Z","id":2,"output":{"text":"B"}},{"status":"completed","started_at":"2026-09-26T10:00:00Z","id":1,"output":{"text":"A"}}]}')"
assert_eq "no completed run -> empty (the wait loop keeps waiting)" '' \
	"$(pick '{"check_runs":[{"status":"queued","started_at":null,"id":1,"output":{"text":null}}]}')"
assert_eq "no runs at all -> empty" '' "$(pick '{"check_runs":[]}')"
assert_eq "completed with null text -> empty" '' \
	"$(pick '{"check_runs":[{"status":"completed","started_at":"2026-09-26T10:00:00Z","id":1,"output":{"text":null}}]}')"

finish
