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
    # Answers only the fields the step must ask for, so a step that stops
    # requesting baseRefName fails here, not in production.
    [[ "\$*" == *"--json isCrossRepository,baseRefName"* ]] || { echo "stub gh: pr view without the fork and base fields: \$*" >&2; exit 98; }
    v="\$(cat "$TMP/pr.json")"
    [[ "\$v" == FAIL ]] && exit 1
    printf '%s\n' "\$v"; exit 0 ;;
  "repo view")
    [[ "\$*" == *"--json defaultBranchRef"*"--jq .defaultBranchRef.name"* ]] || { echo "stub gh: repo view without defaultBranchRef: \$*" >&2; exit 98; }
    d="\$(cat "$TMP/default_branch" 2>/dev/null || echo main)"
    [[ "\$d" == FAIL ]] && { echo "HTTP 502: outage" >&2; exit 1; }
    printf '%s\n' "\$d"; exit 0 ;;
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

# run_step <pr.json> <merge-rc> <merge-out> [reviews.json] [note-rc] [readfail] [default-branch]
# A sixth argument of "readfail" makes the reviews GET exit non-zero; a seventh
# sets what `gh repo view` reports as the default branch (FAIL: unreadable).
run_step() {
	printf '%s' "$1" >"$TMP/pr.json"
	printf '%s' "$2" >"$TMP/merge.rc"
	printf '%s' "$3" >"$TMP/merge.out"
	printf '%s' "${4:-[]}" >"$TMP/reviews.json"
	printf '%s' "${5:-0}" >"$TMP/note.rc"
	: >"$TMP/calls.log"
	: >"$TMP/reads.log"
	rm -f "$TMP/note.body" "$TMP/reviews.fail" "$TMP/default_branch"
	[[ "${6:-}" == readfail ]] && touch "$TMP/reviews.fail"
	[[ -n "${7:-}" ]] && printf '%s' "$7" >"$TMP/default_branch"
	: >"$TMP/gh_output"
	OUT="$(PATH="$STUB_DIR:$PATH" GITHUB_REPOSITORY=acme/widgets PR=7 GITHUB_OUTPUT="$TMP/gh_output" bash -e "$STEP" 2>&1)"
	RC=$?
}
puts() { grep -c '^api --method PUT .*/merge' "$TMP/calls.log" || true; }
note_posts() { grep -c '^api --method POST .*/reviews' "$TMP/calls.log" || true; }
note_updates() { grep -c '^api --method PUT .*/reviews/' "$TMP/calls.log" || true; }

SAME_REPO_APPROVED='{"isCrossRepository":false,"baseRefName":"main","reviewDecision":"APPROVED","state":"OPEN"}'
SAME_REPO_PENDING='{"isCrossRepository":false,"baseRefName":"main","reviewDecision":"REVIEW_REQUIRED","state":"OPEN"}'
FORK='{"isCrossRepository":true,"baseRefName":"main","reviewDecision":"APPROVED","state":"OPEN"}'
STACKED='{"isCrossRepository":false,"baseRefName":"voice-parse-fix","reviewDecision":"APPROVED","state":"OPEN"}'
GATE_405='{"message":"Repository rule violations found\n\nRequired status check \"all-checks-passed\" is failing.\n\n","documentation_url":"https://docs.github.com/rest/pulls/pulls#merge-a-pull-request","status":"405"}gh: Repository rule violations found (HTTP 405)'

section "merged: PUT succeeds -> logs the sha, exit 0, no note without a prior refusal"
run_step "$SAME_REPO_PENDING" 0 '{"sha":"abc1234","merged":true}'
assert_eq "exit 0" "0" "$RC"
grep -q 'merged #7: abc1234' <<<"$OUT" && pass "logs the merge sha" || fail "logs the merge sha" "$OUT"
assert_eq "exactly one PUT /merge" "1" "$(puts)"
assert_eq "no note posted" "0" "$(note_posts)"
assert_eq "no note updated" "0" "$(note_updates)"

for code in 405 409 422; do
	section "GitHub's gate: HTTP $code before approval -> logged as not merged, exit 0, silent on the PR"
	run_step "$SAME_REPO_PENDING" 1 "gh: refused for this test (HTTP $code)"
	assert_eq "HTTP $code exits 0" "0" "$RC"
	grep -q "not merged #7 — GitHub's gate" <<<"$OUT" && pass "HTTP $code is logged as the gate" || fail "HTTP $code logged as the gate" "$OUT"
	grep -q '::error::' <<<"$OUT" && fail "HTTP $code carries no error annotation" "$OUT" || pass "HTTP $code carries no error annotation"
	assert_eq "this step posts no review" "0" "$(($(note_posts) + $(note_updates)))"
done

section "GitHub's gate: its own reason is handed to ollie-state.py (the step output), never posted by this step"
run_step "$SAME_REPO_APPROVED" 1 "$GATE_405"
assert_eq "exit 0" "0" "$RC"
grep -q 'Required status check "all-checks-passed" is failing.' "$TMP/gh_output" && pass "GitHub's reason is in the refusal output" || fail "refusal output" "$(cat "$TMP/gh_output")"
assert_eq "this step posts no review" "0" "$(($(note_posts) + $(note_updates)))"

section "GitHub's gate with a body jq cannot parse -> gh's one-line reason is handed on instead"
run_step "$SAME_REPO_APPROVED" 1 "gh: Pull Request is not mergeable (HTTP 405)"
assert_eq "exit 0 — the unparsable body never aborts the run" "0" "$RC"
grep -q 'Pull Request is not mergeable' "$TMP/gh_output" && pass "falls back to gh's own line" || fail "fallback reason" "$(cat "$TMP/gh_output")"

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

section "stacked PR (base is not the default branch): refused, no merge call (margot #75)"
run_step "$STACKED" 0 '{"sha":"never"}'
assert_eq "exit 0" "0" "$RC"
grep -q "refused #7: base 'voice-parse-fix' is not the default branch 'main'" <<<"$OUT" && pass "refusal names the base and the default branch" || fail "refusal names the base and the default branch" "$OUT"
assert_eq "no PUT issued" "0" "$(puts)"

section "stacked PR: the refusal reaches ollie-state as the refusal output"
run_step "$STACKED" 0 '{"sha":"never"}'
grep -q "stacked on 'voice-parse-fix', not the default branch 'main'" "$TMP/gh_output" && pass "refusal written to GITHUB_OUTPUT" || fail "refusal written to GITHUB_OUTPUT" "$(cat "$TMP/gh_output")"

section "default branch unreadable: a genuine error (exit 1, annotated), never a policy refusal, no merge call"
run_step "$SAME_REPO_APPROVED" 0 '{"sha":"never"}' '[]' 0 '' FAIL
assert_eq "exit 1" "1" "$RC"
grep -q '::error::could not read the default branch of acme/widgets' <<<"$OUT" && pass "annotated as unreadable" || fail "annotated as unreadable" "$OUT"
grep -q 'is not the default branch' <<<"$OUT" && fail "never reported as a policy refusal" "$OUT" || pass "never reported as a policy refusal"
assert_eq "no PUT issued" "0" "$(puts)"

section "base branch missing from a readable PR: a genuine error, no merge call"
run_step '{"isCrossRepository":false,"reviewDecision":"APPROVED","state":"OPEN"}' 0 '{"sha":"never"}'
assert_eq "exit 1" "1" "$RC"
grep -q '::error::could not read the base branch of #7' <<<"$OUT" && pass "annotated as unreadable" || fail "annotated as unreadable" "$OUT"
assert_eq "no PUT issued" "0" "$(puts)"

finish
