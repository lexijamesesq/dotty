#!/usr/bin/env bash
# ollie-state.py's rules: when Ollie assigns the operator, and when he does not.
# Design: the Ollie-as-teammate design (2026-09-27). Receipts
# for each rule are the notification audit's cases
# (the notification audit of 2026-09-27).
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=lib/assert.sh
source "$SCRIPT_DIR/lib/assert.sh"
TOOL="$REPO/.github/scripts/ollie-state.py"

# state <facts-json> -> the decided state (or "none")
state() {
	python3 - "$TOOL" "$1" <<'PY'
import importlib.util, json, sys
from datetime import datetime, timezone
spec = importlib.util.spec_from_file_location("o", sys.argv[1]); o = importlib.util.module_from_spec(spec); spec.loader.exec_module(o)
f = {"pr_state": "OPEN", "draft": False, "created_at": "2026-09-27T10:00:00Z", "author": "claude-the-enduring[bot]",
     "author_is_bot": True, "verdict": None, "self_instrument": None, "operator_approved": False,
     "merge_state": "blocked", "refusal": "", "assignees": [], "labels": []}
f.update(json.loads(sys.argv[2]))
now = datetime(2026, 9, 27, 12, 0, tzinfo=timezone.utc)
print(o.decide(f, now)["state"] or "none")
PY
}
V() { # <outcome> <band> <source> <completed_at>
	printf '{"status":"completed","completed_at":"%s","text":"outcome: %s | band: %s\\ndecision_source: %s"}' "$4" "$1" "$2" "$3"
}

section "no verdict: nothing before 6h; the operator after (the dead-man's rule, now Ollie's)"
assert_eq "no verdict, 2h old -> none" "none" "$(state '{"created_at":"2026-09-27T10:00:00Z"}')"
assert_eq "no verdict, 7h old -> operator" "waiting-on-operator" "$(state '{"created_at":"2026-09-27T05:00:00Z"}')"
assert_eq "verdict still running, 7h old -> operator" "waiting-on-operator" "$(state '{"created_at":"2026-09-27T05:00:00Z","verdict":{"status":"in_progress"}}')"

section "APPROVED LOW: Ollie's to merge; the operator only if it is still open an hour later"
assert_eq "LOW, just approved -> none" "none" "$(state "$(printf '{"verdict":%s}' "$(V APPROVED LOW jev 2026-09-27T11:50:00Z)")")"
assert_eq "LOW, approved 2h ago, still open -> operator (approved but not merged)" "waiting-on-operator" "$(state "$(printf '{"verdict":%s}' "$(V APPROVED LOW jev 2026-09-27T10:00:00Z)")")"

section "the merge is blocked on her: assign at verdict (audit N0; dotty #376 was the missed case)"
assert_eq "self-instrument blocked, LOW -> operator" "waiting-on-operator" "$(state "$(printf '{"verdict":%s,"self_instrument":"action_required"}' "$(V APPROVED LOW jev 2026-09-27T11:50:00Z)")")"
assert_eq "MEDIUM, not approved by her -> operator" "waiting-on-operator" "$(state "$(printf '{"verdict":%s}' "$(V APPROVED MEDIUM jev 2026-09-27T11:50:00Z)")")"
assert_eq "HIGH, approved by her, just now -> none (Ollie merges)" "none" "$(state "$(printf '{"verdict":%s,"operator_approved":true}' "$(V APPROVED HIGH jev 2026-09-27T11:50:00Z)")")"

section "the author's turn: label only; the operator after 1h if a bot author stalls"
assert_eq "changes requested, bot author, 20 min -> author" "waiting-on-author" "$(state "$(printf '{"verdict":%s}' "$(V CHANGES_REQUESTED MEDIUM jev 2026-09-27T11:40:00Z)")")"
assert_eq "changes requested, bot author, 2h -> operator (stalled agent)" "waiting-on-operator" "$(state "$(printf '{"verdict":%s}' "$(V CHANGES_REQUESTED MEDIUM jev 2026-09-27T10:00:00Z)")")"
assert_eq "changes requested, human author, 2h -> author (never escalated)" "waiting-on-author" "$(state "$(printf '{"author_is_bot":false,"author":"lexijamesesq","verdict":%s}' "$(V CHANGES_REQUESTED MEDIUM jev 2026-09-27T10:00:00Z)")")"
assert_eq "clarification requested, bot, 2h -> operator" "waiting-on-operator" "$(state "$(printf '{"verdict":%s}' "$(V CLARIFICATION_REQUESTED LOW jev 2026-09-27T10:00:00Z)")")"

section "outage: a label, never an individual assignment (audit N2: one outage was 16 assignments)"
assert_eq "fallback-scored hold -> outage" "outage" "$(state "$(printf '{"verdict":%s}' "$(V APPROVED MEDIUM fallback 2026-09-27T10:00:00Z)")")"
assert_eq "ERROR -> outage" "outage" "$(state "$(printf '{"verdict":%s}' "$(V ERROR MEDIUM jev 2026-09-27T10:00:00Z)")")"

section "closed, merged and draft PRs need nobody (audit N1: stale assignments re-notified on merge)"
assert_eq "closed -> none" "none" "$(state "$(printf '{"pr_state":"CLOSED","verdict":%s}' "$(V APPROVED HIGH jev 2026-09-27T10:00:00Z)")")"
assert_eq "draft -> none" "none" "$(state '{"draft":true,"created_at":"2026-09-27T01:00:00Z"}')"

section "the verdict text parser reads Margot's real format"
parsed="$(
	python3 - "$TOOL" <<'PY'
import importlib.util, sys
spec = importlib.util.spec_from_file_location("o", sys.argv[1]); o = importlib.util.module_from_spec(spec); spec.loader.exec_module(o)
p = o.parse_verdict("verdict_source: verdict_voice\npipeline_ok: True\noutcome: APPROVED | band: LOW\nvector: {}\ndecision_source: jev\n")
print(p["outcome"], p["band"], p["source"])
PY
)"
assert_eq "outcome, band and source parsed" "APPROVED LOW jev" "$parsed"

finish
