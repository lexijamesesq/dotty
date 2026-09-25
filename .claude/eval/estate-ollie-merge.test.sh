#!/usr/bin/env bash
# Test suite for the merge step of .github/workflows/estate-ollie-merge.yml —
# the one decision the estate's merger makes: which outcomes of PUT /merge are
# GitHub's gate (logged, run ends green) and which are genuine errors (run
# fails loudly) — and the one thing it says on the pull request: a refusal
# note, only on an already-approved PR, upserted, resolved on merge.
# The step's `run:` block is extracted from the workflow file and executed
# verbatim against a stub `gh`, so the YAML and the test cannot drift: a change
# to the step is what this suite runs.
#
# Why this exists: the first cut swallowed every non-zero exit as "the gate"
# (a broken pipeline would have shown green); before that a refusal under the
# runner's `bash -e` aborted the step before its own logging branch; and a
# refusal that lived only in the run log led the operator to bypass-merge a PR
# whose required check was failing.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/assert.sh"

WORKFLOW="${WORKFLOW:-${SCRIPT_DIR}/../../.github/workflows/estate-ollie-merge.yml}"
[[ -f "$WORKFLOW" ]] || {
	echo "FATAL: missing $WORKFLOW"
	exit 2
}
command -v python3 >/dev/null || {
	echo "FATAL: python3 required to read the workflow"
	exit 2
}

TMP="$(mktemp -d -t estate-ollie-merge-test.XXXXXX)"
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT INT TERM

# The step's shell, byte for byte, selected by its name.
STEP="$TMP/step.sh"
python3 - "$WORKFLOW" >"$STEP" <<'PY'
import sys, yaml
wf = yaml.safe_load(open(sys.argv[1]))
for job in wf["jobs"].values():
    for step in job.get("steps", []):
        if step.get("name", "").startswith("Ollie merges the pull request"):
            sys.stdout.write(step["run"])
            sys.exit(0)
sys.exit("merge step not found")
PY
[[ -s "$STEP" ]] || {
	echo "FATAL: could not extract the merge step from $WORKFLOW"
	exit 2
}

# Stub gh. Scripted per case through files in $TMP:
#   pr.json     — what `gh pr view … --json isCrossRepository,reviewDecision`
#                 prints, or the word FAIL to exit non-zero with nothing on
#                 stdout (an unreadable PR)
#   merge.rc    — exit code of `gh api --method PUT …/merge`
#   merge.out   — what that call writes (stdout+stderr are captured together
#                 by the step, the way gh really prints its errors)
#   reviews.json — what `gh api …/pulls/N/reviews` returns (the existing
#                 reviews; the step looks for its own marker there)
#   note.rc     — exit code for the POST/PUT of the note (0 unless a case
#                 wants the post to fail)
# Every call is appended to calls.log; a note's body is written to note.body.
STUB_DIR="$TMP/bin"
mkdir -p "$STUB_DIR"
cat >"$STUB_DIR/gh" <<STUBEOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >>"$TMP/calls.log"
case "\$1 \$2" in
  "pr view")
    v="\$(cat "$TMP/pr.json")"
    [[ "\$v" == FAIL ]] && exit 1
    printf '%s\n' "\$v"; exit 0 ;;
  "api --method")
    case "\$*" in
      *"/merge"*) cat "$TMP/merge.out"; exit "\$(cat "$TMP/merge.rc")" ;;
      *"/reviews"*)
        # record the note body: the -f body=… argument
        while [[ \$# -gt 0 ]]; do
          if [[ "\$1" == "-f" && "\$2" == body=* ]]; then printf '%s' "\${2#body=}" >"$TMP/note.body"; fi
          shift
        done
        exit "\$(cat "$TMP/note.rc")" ;;
    esac ;;
  "api --paginate")
    # The reviews read: every page, streamed as objects (the step slurps).
    printf '%s\n' "\$*" >>"$TMP/reads.log"
    case "\$3" in
      *"/reviews?"*) [[ -f "$TMP/reviews.fail" ]] && exit 1; jq -c '.[]' "$TMP/reviews.json"; exit 0 ;;
    esac ;;
esac
echo "stub gh: unexpected call: \$*" >&2; exit 99
STUBEOF
chmod +x "$STUB_DIR/gh"

# run_step <pr.json> <merge-rc> <merge-out> [reviews.json] [note-rc] [readfail]
# A sixth argument of "readfail" makes the reviews GET exit non-zero.
run_step() {
	printf '%s' "$1" >"$TMP/pr.json"
	printf '%s' "$2" >"$TMP/merge.rc"
	printf '%s' "$3" >"$TMP/merge.out"
	printf '%s' "${4:-[]}" >"$TMP/reviews.json"
	printf '%s' "${5:-0}" >"$TMP/note.rc"
	: >"$TMP/calls.log"
	: >"$TMP/reads.log"
	rm -f "$TMP/note.body" "$TMP/reviews.fail"
	[[ "${6:-}" == readfail ]] && touch "$TMP/reviews.fail"
	OUT="$(PATH="$STUB_DIR:$PATH" GITHUB_REPOSITORY=acme/widgets PR=7 OLLIE_LOGIN="ollie-the-intern[bot]" bash -e "$STEP" 2>&1)"
	RC=$?
}
puts() { grep -c '^api --method PUT .*/merge' "$TMP/calls.log" || true; }
note_posts() { grep -c '^api --method POST .*/reviews' "$TMP/calls.log" || true; }
note_updates() { grep -c '^api --method PUT .*/reviews/' "$TMP/calls.log" || true; }

SAME_REPO_APPROVED='{"isCrossRepository":false,"reviewDecision":"APPROVED","state":"OPEN"}'
SAME_REPO_PENDING='{"isCrossRepository":false,"reviewDecision":"REVIEW_REQUIRED","state":"OPEN"}'
ALREADY_MERGED='{"isCrossRepository":false,"reviewDecision":"APPROVED","state":"MERGED"}'
FORK='{"isCrossRepository":true,"reviewDecision":"APPROVED","state":"OPEN"}'
GATE_405='{"message":"Repository rule violations found\n\nRequired status check \"all-checks-passed\" is failing.\n\n","documentation_url":"https://docs.github.com/rest/pulls/pulls#merge-a-pull-request","status":"405"}gh: Repository rule violations found (HTTP 405)'
EXISTING_NOTE='[{"id":99,"user":{"login":"ollie-the-intern[bot]"},"body":"<!-- ollie-merge:refusal -->\nold"},{"id":5,"user":{"login":"margot-the-meticulous[bot]"},"body":"### APPROVED"}]'
# A human review that happens to begin with Ollie's marker: not Ollie's note.
HUMAN_MARKER_NOTE='[{"id":42,"user":{"login":"lexijamesesq"},"body":"<!-- ollie-merge:refusal -->\nquoting the bot"}]'

section "merged: PUT succeeds -> logs the sha, exit 0, no note without a prior refusal"
run_step "$SAME_REPO_PENDING" 0 '{"sha":"abc1234","merged":true}'
assert_eq "exit 0" "0" "$RC"
grep -q 'merged #7: abc1234' <<<"$OUT" && pass "logs the merge sha" || fail "logs the merge sha" "$OUT"
assert_eq "exactly one PUT /merge" "1" "$(puts)"
assert_eq "no note posted" "0" "$(note_posts)"
assert_eq "no note updated" "0" "$(note_updates)"

section "merged after an earlier refusal note -> the note is resolved in place"
run_step "$SAME_REPO_APPROVED" 0 '{"sha":"abc1234","merged":true}' "$EXISTING_NOTE"
assert_eq "exit 0" "0" "$RC"
assert_eq "existing note updated, not duplicated" "1" "$(note_updates)"
assert_eq "no new note" "0" "$(note_posts)"
grep -q 'Resolved — Ollie merged this pull request' "$TMP/note.body" && pass "note says resolved" || fail "note says resolved" "$(cat "$TMP/note.body" 2>/dev/null)"

for code in 405 409 422; do
	section "GitHub's gate: HTTP $code before approval -> logged as not merged, exit 0, silent on the PR"
	run_step "$SAME_REPO_PENDING" 1 "gh: refused for this test (HTTP $code)"
	assert_eq "HTTP $code exits 0" "0" "$RC"
	grep -q "not merged #7 — GitHub's gate" <<<"$OUT" && pass "HTTP $code is logged as the gate" || fail "HTTP $code logged as the gate" "$OUT"
	grep -q '::error::' <<<"$OUT" && fail "HTTP $code carries no error annotation" "$OUT" || pass "HTTP $code carries no error annotation"
	assert_eq "no note before approval" "0" "$(($(note_posts) + $(note_updates)))"
done

section "GitHub's gate on an APPROVED PR -> one note with GitHub's reason and the re-init path"
run_step "$SAME_REPO_APPROVED" 1 "$GATE_405"
assert_eq "exit 0" "0" "$RC"
assert_eq "one note posted" "1" "$(note_posts)"
assert_eq "none updated" "0" "$(note_updates)"
grep -q '^<!-- ollie-merge:refusal -->' "$TMP/note.body" && pass "note starts with the marker" || fail "note starts with the marker" "$(cat "$TMP/note.body")"
grep -q 'Required status check "all-checks-passed" is failing' "$TMP/note.body" && pass "note carries GitHub's own reason" || fail "note carries GitHub's own reason" "$(cat "$TMP/note.body")"
grep -q 'pr=7' "$TMP/note.body" && pass "note names the manual retry with the PR number" || fail "note names the manual retry" "$(cat "$TMP/note.body")"
grep -q 'next completed check suite' "$TMP/note.body" && pass "note names the automatic retry" || fail "note names the automatic retry" "$(cat "$TMP/note.body")"
grep -q '::warning::' <<<"$OUT" && fail "no warning on a successful post" "$OUT" || pass "no warning on a successful post"

section "GitHub's gate on an APPROVED PR with a body jq cannot parse -> the note still lands, with gh's one-line reason"
run_step "$SAME_REPO_APPROVED" 1 "gh: Pull Request is not mergeable (HTTP 405)"
assert_eq "exit 0 — the unparsable body never aborts the run" "0" "$RC"
assert_eq "one note posted" "1" "$(note_posts)"
grep -q 'Pull Request is not mergeable (HTTP 405)' "$TMP/note.body" && pass "note falls back to gh's own line" || fail "note falls back to gh's own line" "$(cat "$TMP/note.body" 2>/dev/null)"

section "a late run on an ALREADY-MERGED PR (GitHub answers 405) -> no note, the resolved note is never overwritten"
run_step "$ALREADY_MERGED" 1 "$GATE_405" "$EXISTING_NOTE"
assert_eq "exit 0" "0" "$RC"
assert_eq "no note posted" "0" "$(note_posts)"
assert_eq "no note updated" "0" "$(note_updates)"
grep -q '#7 is MERGED — no note' <<<"$OUT" && pass "logs why no note was written" || fail "logs why no note was written" "$OUT"

section "a human review starting with Ollie's marker is NOT Ollie's note -> a new note is posted, the human's is never edited"
run_step "$SAME_REPO_APPROVED" 1 "$GATE_405" "$HUMAN_MARKER_NOTE"
assert_eq "exit 0" "0" "$RC"
assert_eq "one new note posted" "1" "$(note_posts)"
assert_eq "the human's review untouched" "0" "$(note_updates)"

section "the reviews cannot be READ -> no note at all (never a duplicate on doubt), a warning, exit 0"
run_step "$SAME_REPO_APPROVED" 1 "$GATE_405" "$EXISTING_NOTE" 0 readfail
assert_eq "exit 0" "0" "$RC"
assert_eq "no note posted on a read failure" "0" "$(note_posts)"
assert_eq "no note updated on a read failure" "0" "$(note_updates)"
grep -q "::warning::could not read the reviews on #7" <<<"$OUT" && pass "warns that the note was not written" || fail "warns that the note was not written" "$OUT"

section "merged, but the reviews cannot be read -> merge logged, nothing written, exit 0"
run_step "$SAME_REPO_APPROVED" 0 '{"sha":"abc1234","merged":true}' "$EXISTING_NOTE" 0 readfail
assert_eq "exit 0" "0" "$RC"
grep -q 'merged #7: abc1234' <<<"$OUT" && pass "the merge is still logged" || fail "the merge is still logged" "$OUT"
assert_eq "nothing written" "0" "$(($(note_posts) + $(note_updates)))"

section "the note lookup reads EVERY page of reviews (a note beyond the first hundred is still found)"
BIG="$(jq -c '[range(0;150) | {id: (1000 + .), user: {login: "someone"}, body: ("review " + tostring)}] + [{id: 99, user: {login: "ollie-the-intern[bot]"}, body: "<!-- ollie-merge:refusal -->\nold"}]' <<<'null')"
run_step "$SAME_REPO_APPROVED" 1 "$GATE_405" "$BIG"
assert_eq "exit 0" "0" "$RC"
grep -q -- '--paginate' "$TMP/reads.log" && pass "the reviews read is paginated" || fail "the reviews read is paginated" "$(cat "$TMP/reads.log")"
assert_eq "the 151st review (Ollie's note) is found and updated" "1" "$(note_updates)"
assert_eq "no duplicate posted" "0" "$(note_posts)"

section "a second refusal on the same approved PR -> the existing note is updated, never a second one"
run_step "$SAME_REPO_APPROVED" 1 "$GATE_405" "$EXISTING_NOTE"
assert_eq "exit 0" "0" "$RC"
assert_eq "no new note" "0" "$(note_posts)"
assert_eq "existing note updated" "1" "$(note_updates)"

section "the note cannot be posted -> a warning, the run still ends green"
run_step "$SAME_REPO_APPROVED" 1 "$GATE_405" "[]" 1
assert_eq "exit 0 despite the failed post" "0" "$RC"
grep -q "::warning::could not post Ollie's refusal note" <<<"$OUT" && pass "warns about the failed post" || fail "warns about the failed post" "$OUT"

for err in "gh: Resource not accessible by integration (HTTP 403)" "gh: Not Found (HTTP 404)" "connect: network is unreachable"; do
	section "genuine error: '$err' -> ::error::, exit 1, no note"
	run_step "$SAME_REPO_APPROVED" 1 "$err"
	assert_eq "exit 1" "1" "$RC"
	grep -q '::error::merge call failed for #7 (not a gate refusal)' <<<"$OUT" && pass "annotated as a real failure" || fail "annotated as a real failure" "$OUT"
	grep -q "GitHub's gate" <<<"$OUT" && fail "never mislabelled as the gate" "$OUT" || pass "never mislabelled as the gate"
	assert_eq "no note on a genuine error" "0" "$(($(note_posts) + $(note_updates)))"
done

section "fork PR: refused by estate policy before any merge call, exit 0"
run_step "$FORK" 0 '{"sha":"never"}'
assert_eq "exit 0" "0" "$RC"
grep -q 'refused #7: cross-repository (fork)' <<<"$OUT" && pass "refusal is logged" || fail "refusal is logged" "$OUT"
assert_eq "no PUT issued" "0" "$(puts)"

section "unreadable PR: treated as a fork (fails closed), no merge call"
run_step FAIL 0 '{"sha":"never"}'
assert_eq "exit 0" "0" "$RC"
grep -q 'refused #7: cross-repository (fork)' <<<"$OUT" && pass "unreadable PR refused" || fail "unreadable PR refused" "$OUT"
assert_eq "no PUT issued" "0" "$(puts)"

finish
