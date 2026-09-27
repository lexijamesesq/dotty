#!/usr/bin/env bash
# ollie-state.py's rules: when Ollie asks for the operator's review, and when he does not.
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
     "merge_state": "blocked", "refusal": "", "review_requested": False, "operator_reviewed_head": False,
     "assignees": [], "labels": []}
f.update(json.loads(sys.argv[2]))
now = datetime(2026, 9, 27, 12, 0, tzinfo=timezone.utc)
import os
d = o.decide(f, now)
print(d.get("via", "-") if os.environ.get("VIA") else (d["state"] or "none"))
PY
}
V() { # <outcome> <band> <source> <completed_at> [conclusion]
	local c="${5:-}"
	[[ -n "$c" ]] || { [[ "$1 $2" == "APPROVED LOW" ]] && c=success || c=neutral; }
	printf '{"status":"completed","conclusion":"%s","completed_at":"%s","title":"Margot: held for the operator: test","text":"outcome: %s | band: %s\\ndecision_source: %s"}' "$c" "$4" "$1" "$2" "$3"
}

section "no verdict: nothing before 6h; the operator after (the dead-man's rule, now Ollie's)"
assert_eq "no verdict, 2h old -> none" "none" "$(state '{"created_at":"2026-09-27T10:00:00Z"}')"
assert_eq "no verdict, 7h old -> operator" "waiting-on-operator" "$(state '{"created_at":"2026-09-27T05:00:00Z"}')"
assert_eq "verdict still running, 7h old -> operator" "waiting-on-operator" "$(state '{"created_at":"2026-09-27T05:00:00Z","verdict":{"status":"in_progress"}}')"

section "APPROVED LOW: Ollie's to merge; the operator only if it is still open an hour later"
assert_eq "LOW, just approved -> none" "none" "$(state "$(printf '{"verdict":%s}' "$(V APPROVED LOW jev 2026-09-27T11:50:00Z)")")"
assert_eq "LOW, approved 2h ago, still open -> operator (approved but not merged)" "waiting-on-operator" "$(state "$(printf '{"verdict":%s}' "$(V APPROVED LOW jev 2026-09-27T10:00:00Z)")")"

section "the merge is blocked on her: ask at verdict (audit N0; dotty #376 was the missed case)"
assert_eq "self-instrument blocked, LOW -> operator" "waiting-on-operator" "$(state "$(printf '{"verdict":%s,"self_instrument":"action_required"}' "$(V APPROVED LOW jev 2026-09-27T11:50:00Z)")")"
assert_eq "MEDIUM, not approved by her -> operator" "waiting-on-operator" "$(state "$(printf '{"verdict":%s}' "$(V APPROVED MEDIUM jev 2026-09-27T11:50:00Z)")")"
assert_eq "HIGH, approved by her, just now -> none (Ollie merges)" "none" "$(state "$(printf '{"verdict":%s,"operator_approved":true}' "$(V APPROVED HIGH jev 2026-09-27T11:50:00Z)")")"

section "APPROVED but held (conclusion not success) at any band -> the operator at once (margot-builder, #378)"
assert_eq "APPROVED LOW held (unresolved finding), neutral -> operator" "waiting-on-operator" "$(state "$(printf '{"verdict":%s}' "$(V APPROVED LOW jev 2026-09-27T11:50:00Z neutral)")")"
assert_eq "APPROVED LOW, success, just now -> none (Ollie merges)" "none" "$(state "$(printf '{"verdict":%s}' "$(V APPROVED LOW jev 2026-09-27T11:50:00Z success)")")"

section "the author's turn: label only; the operator after 1h if a bot author stalls"
assert_eq "changes requested, bot author, 20 min -> author" "waiting-on-author" "$(state "$(printf '{"verdict":%s}' "$(V CHANGES_REQUESTED MEDIUM jev 2026-09-27T11:40:00Z)")")"
assert_eq "changes requested, bot author, 2h -> operator (stalled agent)" "waiting-on-operator" "$(state "$(printf '{"verdict":%s}' "$(V CHANGES_REQUESTED MEDIUM jev 2026-09-27T10:00:00Z)")")"
assert_eq "changes requested, human author, 2h -> author (never escalated)" "waiting-on-author" "$(state "$(printf '{"author_is_bot":false,"author":"a-contributor","verdict":%s}' "$(V CHANGES_REQUESTED MEDIUM jev 2026-09-27T10:00:00Z)")")"
assert_eq "clarification requested, bot, 2h -> operator" "waiting-on-operator" "$(state "$(printf '{"verdict":%s}' "$(V CLARIFICATION_REQUESTED LOW jev 2026-09-27T10:00:00Z)")")"

section "outage: a label, never an individual review request (audit N2: one outage was 16 assignments)"
assert_eq "fallback-scored hold -> outage" "outage" "$(state "$(printf '{"verdict":%s}' "$(V APPROVED MEDIUM fallback 2026-09-27T10:00:00Z)")")"
assert_eq "ERROR -> outage" "outage" "$(state "$(printf '{"verdict":%s}' "$(V ERROR MEDIUM jev 2026-09-27T10:00:00Z)")")"

section "Margot held it without a verdict (no outcome line): the operator, never the outage issue"
assert_eq "action_required, no text (attribution or template hold) -> operator" "waiting-on-operator" "$(state '{"verdict":{"status":"completed","conclusion":"action_required","completed_at":"2026-09-27T11:50:00Z","title":"not reviewed: template compliance"}}')"
assert_eq "failure, no text (poster exception) -> operator" "waiting-on-operator" "$(state '{"verdict":{"status":"completed","conclusion":"failure","completed_at":"2026-09-27T11:50:00Z","title":"not reviewed: poster error"}}')"
assert_eq "neutral with a real verdict still follows the verdict" "waiting-on-author" "$(state "$(printf '{"verdict":%s}' "$(V CHANGES_REQUESTED MEDIUM jev 2026-09-27T11:50:00Z)")")"

section "draft PRs need nobody; a closed or merged PR is history (never rewritten)"
assert_eq "closed -> none" "none" "$(state "$(printf '{"pr_state":"CLOSED","verdict":%s}' "$(V APPROVED HIGH jev 2026-09-27T10:00:00Z)")")"
leave="$(
	python3 - "$TOOL" <<'PY2'
import importlib.util, sys
from datetime import datetime, timezone
spec = importlib.util.spec_from_file_location("o", sys.argv[1]); o = importlib.util.module_from_spec(spec); spec.loader.exec_module(o)
d = o.decide({"pr_state": "CLOSED"}, datetime.now(timezone.utc))
print(o.apply("acme/widgets", {"number": 7}, d, True))
PY2
)"
assert_eq "closed PR: apply writes nothing" "acme/widgets#7: closed -- history, left as it is" "$leave"
assert_eq "her own PR, no verdict after 6h -> none (Ollie stays out: no signal, label or comment)" "none" "$(state '{"author":"lexijamesesq","author_is_bot":false,"created_at":"2026-09-27T01:00:00Z"}')"
assert_eq "her own PR, Margot held it -> none" "none" "$(state "$(printf '{"author":"lexijamesesq","author_is_bot":false,"verdict":%s}' "$(V APPROVED HIGH jev 2026-09-27T10:00:00Z)")")"
assert_eq "draft -> none" "none" "$(state '{"draft":true,"created_at":"2026-09-27T01:00:00Z"}')"

section "one signal, by what she must do: review the change -> review request; unblock the pipeline -> assignment"
via() { VIA=1 state "$1"; }
assert_eq "no verdict after 6h -> assign" "assign" "$(via '{"created_at":"2026-09-27T05:00:00Z"}')"
assert_eq "held without a verdict -> assign" "assign" "$(via '{"verdict":{"status":"completed","conclusion":"action_required","completed_at":"2026-09-27T11:50:00Z","title":"not reviewed: template compliance"}}')"
assert_eq "stalled bot author -> assign" "assign" "$(via "$(printf '{"verdict":%s}' "$(V CHANGES_REQUESTED MEDIUM jev 2026-09-27T10:00:00Z)")")"
assert_eq "self-instrument (admin-merge) -> review" "review" "$(via "$(printf '{"verdict":%s,"self_instrument":"action_required"}' "$(V APPROVED LOW jev 2026-09-27T11:50:00Z)")")"
assert_eq "Margot held it for her (MEDIUM) -> review" "review" "$(via "$(printf '{"verdict":%s}' "$(V APPROVED MEDIUM jev 2026-09-27T11:50:00Z)")")"
assert_eq "approved but not merged -> assign" "assign" "$(via "$(printf '{"verdict":%s}' "$(V APPROVED LOW jev 2026-09-27T10:00:00Z)")")"

section "self-instrument: review first; after her approval, nothing for an hour, then an assignment to admin-merge"
SI="$(V APPROVED LOW jev 2026-09-27T11:50:00Z)"
assert_eq "not yet approved by her -> review" "review" "$(via "$(printf '{"verdict":%s,"self_instrument":"action_required"}' "$SI")")"
assert_eq "approved 10 min ago -> no new signal" "-" "$(VIA=1 state "$(printf '{"verdict":%s,"self_instrument":"action_required","operator_approved":true,"operator_approved_at":"2026-09-27T11:50:00Z"}' "$SI")" | sed 's/^None$/-/')"
assert_eq "approved 10 min ago -> still waiting on her (label kept)" "waiting-on-operator" "$(state "$(printf '{"verdict":%s,"self_instrument":"action_required","operator_approved":true,"operator_approved_at":"2026-09-27T11:50:00Z"}' "$SI")")"
assert_eq "approved 2h ago, not merged -> assign" "assign" "$(via "$(printf '{"verdict":%s,"self_instrument":"action_required","operator_approved":true,"operator_approved_at":"2026-09-27T10:00:00Z"}' "$SI")")"

section "apply(): exactly one signal, and the other one withdrawn"
# ap <facts-json> <decision-json> -> the writes apply() would make (dry run)
ap() {
	python3 - "$TOOL" "$1" "$2" <<'PY4'
import importlib.util, json, sys
spec = importlib.util.spec_from_file_location("o", sys.argv[1]); o = importlib.util.module_from_spec(spec); spec.loader.exec_module(o)
o.gh_list = lambda *a, **k: []
f = {"number": 7, "author": "claude-the-enduring[bot]", "labels": [], "assignees": [],
     "review_requested": False, "operator_reviewed_head": False}
f.update(json.loads(sys.argv[2]))
print(o.apply("acme/widgets", f, json.loads(sys.argv[3]), True).split("(would: ")[1].rstrip(")"))
PY4
}
OP='{"state":"waiting-on-operator","ask":"x","via":'
assert_eq "review case: comment first, then the request (the one notification)" "POST comments, POST labels, POST requested_reviewers" "$(ap '{}' "${OP}\"review\"}")"
assert_eq "assign case: comment first, then the assignment" "POST comments, POST labels, POST assignees" "$(ap '{}' "${OP}\"assign\"}")"
assert_eq "review case, already assigned: request, and the assignment withdrawn" "POST comments, POST labels, POST requested_reviewers, DELETE assignees" "$(ap '{"assignees":["lexijamesesq"]}' "${OP}\"review\"}")"
assert_eq "assign case, review pending: assign, and the request withdrawn" "POST comments, POST labels, DELETE requested_reviewers, POST assignees" "$(ap '{"review_requested":true}' "${OP}\"assign\"}")"
assert_eq "review case, she already reviewed this head: not asked again" "POST comments, POST labels" "$(ap '{"operator_reviewed_head":true}' "${OP}\"review\"}")"
assert_eq "nothing needed: both withdrawn" "DELETE requested_reviewers, DELETE assignees" "$(ap '{"review_requested":true,"assignees":["lexijamesesq"]}' '{"state":null,"ask":""}')"

section "the no-verdict clock starts at the last push, not the PR's opening (Margot, #378)"
assert_eq "no verdict, opened 7h ago, pushed 1h ago -> none" "none" "$(state '{"created_at":"2026-09-27T05:00:00Z","head_at":"2026-09-27T11:00:00Z"}')"
assert_eq "no verdict, opened and pushed 7h ago -> operator" "waiting-on-operator" "$(state '{"created_at":"2026-09-27T05:00:00Z","head_at":"2026-09-27T05:00:00Z"}')"

section "writes: what a sweep sends, and a failed write fails the run"
# io <scenario> -> one line per GitHub write, then the exit code. GitHub is stubbed.
io() {
	python3 - "$TOOL" "$1" <<'PY3'
import importlib.util, sys
spec = importlib.util.spec_from_file_location("o", sys.argv[1]); o = importlib.util.module_from_spec(spec); spec.loader.exec_module(o)
scenario = sys.argv[2]
writes = []
PR = {"number": 7, "state": "open", "draft": False, "created_at": "2026-09-20T00:00:00Z",
      "user": {"login": "claude-the-enduring[bot]", "type": "Bot"}, "head": {"sha": "abc"},
      "requested_reviewers": [], "labels": []}
if scenario == "own-pr":
    PR["user"] = {"login": o.OPERATOR, "type": "User"}
if scenario == "requested-cleared":  # a fresh PR (no verdict yet, so none) that still carries her request
    PR["created_at"] = "2099-01-01T00:00:00Z"
    PR["requested_reviewers"] = [{"login": o.OPERATOR}]
def gh(*args, data=None):
    if scenario == "fail-assign" and args[-1].endswith("/assignees"):
        raise RuntimeError("HTTP 403")
    writes.append(" ".join(a for a in args if a != "-X"))
    return ""
def gh_list(path, items=".[]"):
    if scenario == "fail-repo" and "acme/broken/pulls" in path:
        raise RuntimeError("HTTP 502")
    if "/pulls?" in path:
        return [PR]
    if "/check-runs" in path and scenario in ("reviewed-head", "own-pr", "own-pr-control"):  # Margot held it for her
        return [{"app": {"slug": o.MARGOT_APP}, "name": o.VERDICT_CHECK, "status": "completed",
                 "conclusion": "neutral", "completed_at": "2099-01-01T00:00:00Z", "started_at": "1",
                 "output": {"title": "Margot: held for the operator: risk is MEDIUM",
                            "text": "outcome: APPROVED | band: MEDIUM\ndecision_source: jev"}}]
    if "/reviews" in path and scenario == "reviewed-head":
        return [{"user": {"login": o.OPERATOR}, "state": "COMMENTED", "commit_id": "abc"}]
    if "/comments" in path:  # someone else's comment carrying Ollie's marker
        return [{"id": 99, "user": {"login": "lexijamesesq"}, "body": o.MARKER + " quoted"}]
    if "/issues?" in path:
        return [{"number": 1, "title": o.OUTAGE_TITLE}]
    return []
o.gh, o.gh_list = gh, gh_list
o.gh_json = lambda *a, **k: [{"number": 1, "title": o.OUTAGE_TITLE}] if "issues?" in a[0] else {}
if scenario == "fail-repo":
    import json, tempfile
    rf = tempfile.NamedTemporaryFile("w", suffix=".json", delete=False)
    json.dump({"repos": {"acme/broken": {}, "acme/widgets": {}}}, rf); rf.close()
    sys.argv = ["x", "--estate", "--rulesets-file", rf.name]
else:
    sys.argv = ["x", "--repo", "acme/widgets", "--pr", "7"]
import contextlib, io as sio
with contextlib.redirect_stdout(sio.StringIO()):
    rc = o.main()
for w in writes:
    if "/issues/" in w or "/pulls/" in w: print(w)
print(f"exit {rc}")
PY3
}
out="$(io assign)"
assert_eq "no verdict after 6h: comment first, then label and assignment; exit 0" "POST repos/acme/widgets/issues/7/comments
POST repos/acme/widgets/issues/7/labels
POST repos/acme/widgets/issues/7/assignees
exit 0" "$out"
assert_eq "a failed assignment fails the run (exit 1)" "exit 1" "$(io fail-assign | tail -1)"
assert_eq "held for her, first sweep: her review is requested (the derivation, end to end)" "1" "$(io own-pr-control | grep -c requested_reviewers)"
assert_eq "held for her, she already reviewed this head: not asked again" "0" "$(io reviewed-head | grep -c requested_reviewers)"
assert_eq "held for her, her own PR: no write at all" "exit 0" "$(io own-pr)"
assert_eq "no longer needed: her pending request is withdrawn" "DELETE repos/acme/widgets/pulls/7/requested_reviewers" "$(io requested-cleared | grep requested_reviewers)"
out="$(io fail-repo)"
assert_eq "one unreadable repo: the next repo is still swept" "POST repos/acme/widgets/issues/7/assignees" "$(grep assignees <<<"$out")"
assert_eq "one unreadable repo: the run fails" "exit 1" "$(tail -1 <<<"$out")"
assert_eq "one unreadable repo: no write to the outage issue" "0" "$(grep -c 'issues/1$' <<<"$out")"

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
