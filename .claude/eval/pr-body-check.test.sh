#!/usr/bin/env bash
# Test suite for .github/scripts/pr-body-check.py — the mechanical PR-body:v1
# template gate. Empirical: every assertion runs the actual check against a
# synthesized GITHUB_EVENT_PATH payload and the repo's real committed template.
# Proves NON-VACUOUS (a malformed body BLOCKS) and ZERO-FP (a conforming body,
# an extra heading, a "Not applicable" section, CRLF/trailing-ws all PASS), and
# the fence-awareness + marker-line-1 + placeholder + duplicate edges.
#
# shellcheck disable=SC2016
# ^ fixtures use single-quoted printf with literal backticks (markdown code
# fences ``` inside PR-body text), never shell expansions.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/assert.sh"

CHK="${CHK:-${SCRIPT_DIR}/../../.github/scripts/pr-body-check.py}"
TPL="${TPL:-${SCRIPT_DIR}/../../.github/pull_request_template.md}"
[[ -f "$CHK" ]] || { echo "FATAL: missing $CHK"; exit 2; }
[[ -f "$TPL" ]] || { echo "FATAL: missing $TPL"; exit 2; }

TMP="$(mktemp -d -t pr-body-check-test.XXXXXX)"
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT INT TERM

# run_body <body-text> : writes it as pull_request.body into an event payload and
# runs the check; sets RC and OUT.
run_body() {
    python3 - "$TMP/ev.json" <<'PY' "$1"
import json, sys
open(sys.argv[1], "w").write(json.dumps({"pull_request": {"body": sys.argv[2]}}))
PY
    OUT="$(GITHUB_EVENT_PATH="$TMP/ev.json" python3 "$CHK" --template "$TPL" 2>&1)"; RC=$?
}

ALL7=$'## Intent\nreal\n## What changed\nreal\n## Verification\nran x\n## Risk and blast radius\nlow\n## Rollback\nrevert\n## Ticket\nhttps://x\n## Dependencies\nNone'

section "a conforming pr-body:v1 body PASSES"
run_body "$(printf '<!-- pr-body:v1 -->\n%s\n' "$ALL7")"
assert_eq "conforming body exits 0" "0" "$RC"

section "NON-VACUOUS: missing marker BLOCKS"
run_body "$ALL7"
assert_eq "missing marker exits 1" "1" "$RC"
printf '%s' "$OUT" | grep -q "missing the" && pass "names the missing marker" || fail "marker msg" "$OUT"

section "marker not on line 1 (blank line first) BLOCKS with a specific message"
run_body "$(printf '\n<!-- pr-body:v1 -->\n%s\n' "$ALL7")"
assert_eq "marker-after-blank exits 1" "1" "$RC"
printf '%s' "$OUT" | grep -q "must be the FIRST line" && pass "specific line-1 message" || fail "line-1 msg" "$OUT"

section "NON-VACUOUS: a missing required heading BLOCKS"
run_body "$(printf '<!-- pr-body:v1 -->\n## What changed\nx\n## Verification\nx\n## Risk and blast radius\nx\n## Rollback\nx\n## Ticket\nx\n## Dependencies\nNone\n')"
assert_eq "missing heading exits 1" "1" "$RC"
printf '%s' "$OUT" | grep -q "missing required section heading" && pass "names missing heading" || fail "heading msg" "$OUT"

section "NON-VACUOUS: an untouched template placeholder BLOCKS"
run_body "$(printf '<!-- pr-body:v1 -->\n## Intent\nThe problem and the intended outcome.\n%s\n' "$(printf '## What changed\nx\n## Verification\nx\n## Risk and blast radius\nx\n## Rollback\nx\n## Ticket\nx\n## Dependencies\nNone')")"
assert_eq "untouched placeholder exits 1" "1" "$RC"
printf '%s' "$OUT" | grep -q "untouched template placeholder" && pass "names the placeholder" || fail "placeholder msg" "$OUT"

section "NON-VACUOUS: a duplicate heading BLOCKS"
run_body "$(printf '<!-- pr-body:v1 -->\n## Intent\na\n%s\n' "$ALL7")"
assert_eq "duplicate heading exits 1" "1" "$RC"
printf '%s' "$OUT" | grep -q "duplicate section heading" && pass "names the duplicate" || fail "dup msg" "$OUT"

section "ZERO-FP: an EXTRA non-canonical heading PASSES (additions allowed)"
run_body "$(printf '<!-- pr-body:v1 -->\n%s\n## Additional context\nextra\n' "$ALL7")"
assert_eq "extra heading exits 0" "0" "$RC"

section "ZERO-FP: a fenced code block containing '## Intent' does NOT satisfy a missing heading"
run_body "$(printf '<!-- pr-body:v1 -->\n## What changed\nx\n```\n## Intent\n```\n## Verification\nx\n## Risk and blast radius\nx\n## Rollback\nx\n## Ticket\nx\n## Dependencies\nNone\n')"
assert_eq "fenced fake heading -> Intent still missing (exit 1)" "1" "$RC"
printf '%s' "$OUT" | grep -q "Intent" && pass "fenced heading ignored" || fail "fence-aware" "$OUT"

section "NON-VACUOUS: headings buried in an HTML comment do NOT count as present (comment-aware)"
# Regression for a real bypass: all required headings inside <!-- ... --> render as
# nothing on GitHub, so the visible body has no real sections — must FAIL.
run_body "$(printf '<!-- pr-body:v1 -->\n<!--\n## Intent\n## What changed\n## Verification\n## Risk and blast radius\n## Rollback\n## Ticket\n## Dependencies\n-->\nJust rambling adhoc text.\n')"
assert_eq "all-headings-in-a-comment exits 1" "1" "$RC"
printf '%s' "$OUT" | grep -q "missing required section heading" && pass "comment-buried headings not counted" || fail "comment-aware headings" "$OUT"

section "ZERO-FP: CRLF + trailing whitespace on headings PASSES (normalized)"
run_body "$(printf '<!-- pr-body:v1 -->\r\n## Intent   \r\na\r\n## What changed\r\nb\r\n## Verification\r\nc\r\n## Risk and blast radius\r\nd\r\n## Rollback\r\ne\r\n## Ticket\r\nx\r\n## Dependencies\r\nNone\r\n')"
assert_eq "CRLF/trailing-ws body exits 0" "0" "$RC"

section "ZERO-FP: a 'Not applicable — reason' section PASSES"
run_body "$(printf '<!-- pr-body:v1 -->\n## Intent\nreal\n## What changed\nreal\n## Verification\nNot applicable — docs only\n## Risk and blast radius\nlow\n## Rollback\nrevert\n## Ticket\nx\n## Dependencies\nNone\n')"
assert_eq "Not-applicable section exits 0" "0" "$RC"

section "empty body BLOCKS"
run_body ""
assert_eq "empty body exits 1" "1" "$RC"

section "a non-pull_request event is a no-op (PASS)"
printf '%s' '{"push":{}}' > "$TMP/ev2.json"
OUT="$(GITHUB_EVENT_PATH="$TMP/ev2.json" python3 "$CHK" --template "$TPL" 2>&1)"; RC=$?
assert_eq "non-PR event exits 0" "0" "$RC"

finish
