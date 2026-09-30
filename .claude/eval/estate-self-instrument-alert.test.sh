#!/usr/bin/env bash
# Test suite for .github/workflows/estate-self-instrument-alert.yml — the
# detection half of the accepted gate-config residual: a merge that touches a
# `self_instrument` path is surfaced (comment, assignee, warning), never held.
# Both steps' `run:` blocks are extracted from the workflow file and executed
# verbatim against a stub `gh`, so the YAML and the test cannot drift.
#
# The cases below prove that path matching uses the base ruleset and both names
# of a rename, while suppression follows only a Jev light class recorded for
# every exact merged head by the reviewer App. Missing, stale, malformed,
# unreadable, differently posted and functional results produce an alert.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/assert.sh"

WORKFLOW="${WORKFLOW:-${SCRIPT_DIR}/../../.github/workflows/estate-self-instrument-alert.yml}"
SHIPPED_RULESET="${SCRIPT_DIR}/../../rulesets/default-branch.json"
[[ -f "$WORKFLOW" ]] || {
	echo "FATAL: missing $WORKFLOW"
	exit 2
}
command -v python3 >/dev/null || {
	echo "FATAL: python3 required to read the workflow"
	exit 2
}

section "permissions: the reusable inherits exactly what its caller grants"
if python3 - "$WORKFLOW" <<'PY'
import sys, yaml
wf = yaml.safe_load(open(sys.argv[1]))
if "permissions" in wf or any("permissions" in job for job in wf["jobs"].values()):
    sys.exit(1)
PY
then
	pass "reusable has no workflow-level or job-level permissions key"
else
	fail "reusable has no workflow-level or job-level permissions key" "a permissions key reappeared"
fi

TMP="$(mktemp -d -t estate-self-instrument-alert-test.XXXXXX)"
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT INT TERM

# extract_step <name-prefix> <out-file> — a step's shell, byte for byte.
extract_step() {
	python3 - "$WORKFLOW" "$1" >"$2" <<'PY'
import sys, yaml
wf = yaml.safe_load(open(sys.argv[1]))
for job in wf["jobs"].values():
    for step in job.get("steps", []):
        if step.get("name", "").startswith(sys.argv[2]):
            sys.stdout.write(step["run"])
            sys.exit(0)
sys.exit("step not found: " + sys.argv[2])
PY
	[[ -s "$2" ]] || {
		echo "FATAL: could not extract the '$1' step from $WORKFLOW"
		exit 2
	}
}
CLASSIFY="$TMP/classify.sh"
SURFACE="$TMP/surface.sh"
extract_step "Classify the merge" "$CLASSIFY"
extract_step "Surface it" "$SURFACE"

# Stub gh. Scripted per case through files in $TMP:
#   files.txt        — the compare's changed files, one per line; the word FAIL
#                      makes the compare exit non-zero
#   ruleset.<ref>.json — the ruleset served for `contents/...?ref=<ref>`; a ref
#                      with no file exits non-zero (unreadable)
#   heads.txt        — merged PR head shas for the classify step
#   triage.<sha>.json — triage output text for one head; absent means no check
#   checks-refused   — when present, check-run reads exit non-zero
#   prs.txt          — PR numbers for `commits/<sha>/pulls`, one per line
#   comments.json    — the existing comments on the PR (an array)
#   assignees.txt    — the PR's current assignee logins, one per line
#   issues.json      — the repo's existing issues (an array)
# Every call is appended to calls.log; every ruleset read's ref to refs.log; a
# comment/issue body to comment.body / issue.body.
STUB_DIR="$TMP/bin"
mkdir -p "$STUB_DIR"
cat >"$STUB_DIR/gh" <<STUBEOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >>"$TMP/calls.log"
body_of() {
  while [[ \$# -gt 0 ]]; do
    if [[ "\$1" == "-f" && "\$2" == body=* ]]; then printf '%s' "\${2#body=}"; return; fi
    shift
  done
}
case "\$*" in
  *"/compare/"*)
    [[ "\$(cat "$TMP/files.txt")" == FAIL ]] && { echo "gh: Not Found (HTTP 404)" >&2; exit 1; }
    # The step reads --jq '.files[]': one object per file. files.json, when a
    # case writes it, is served as is (status and patch); otherwise each name in
    # files.txt becomes {filename, status: modified}, with no patch.
    if [[ -f "$TMP/files.json" ]]; then jq -c '.[]' "$TMP/files.json"; else
      while IFS= read -r f; do [[ -n "\$f" ]] && jq -cn --arg f "\$f" '{filename: \$f, status: "modified"}'; done <"$TMP/files.txt"; fi
    exit 0 ;;
  *"/check-runs?app_id=4862659"*)
    [[ -f "$TMP/checks-refused" ]] && { echo "gh: Resource not accessible by integration (HTTP 403)" >&2; exit 1; }
    all="\$*"; head="\${all#*repos/*/commits/}"; head="\${head%%/check-runs*}"
    [[ -f "$TMP/triage.\$head.json" ]] && cat "$TMP/triage.\$head.json"
    exit 0 ;;
  *"/pulls --jq ["*)
    cat "$TMP/heads.txt"; exit 0 ;;
  *"contents/rulesets/default-branch.json?ref="*)
    all="\$*"; ref="\${all##*ref=}"; ref="\${ref%% *}"
    printf '%s\n' "\$ref" >>"$TMP/refs.log"
    [[ -f "$TMP/ruleset.\$ref.json" ]] || { echo "gh: Not Found (HTTP 404)" >&2; exit 1; }
    cat "$TMP/ruleset.\$ref.json"; exit 0 ;;
  *"/pulls --jq .[].number")
    cat "$TMP/prs.txt"; exit 0 ;;
  *"/reviews?per_page=100 --jq .[]")
    [[ -f "$TMP/reviews.json" ]] && jq -c '.[]' "$TMP/reviews.json"; exit 0 ;;
  *"/comments?per_page=100 --jq .[]")
    jq -c '.[]' "$TMP/comments.json"; exit 0 ;;
  "api --method PATCH "*"/issues/comments/"*)
    body_of "\$@" >"$TMP/comment.body"; exit 0 ;;
  "api --method POST "*"/comments -f body="*)
    body_of "\$@" >"$TMP/comment.body"; echo '{"id":1}'; exit 0 ;;
  *"/issues/"*" --jq .assignees[].login")
    cat "$TMP/assignees.txt"; exit 0 ;;
  "api --method POST "*"/assignees -f assignees[]="*)
    echo '{}'; exit 0 ;;
  *"/issues?state=all&per_page=100 --jq .[]")
    jq -c '.[]' "$TMP/issues.json"; exit 0 ;;
  "api --method POST repos/"*"/issues -f title="*)
    body_of "\$@" >"$TMP/issue.body"; echo 123; exit 0 ;;
esac
echo "stub gh: unexpected call: \$*" >&2; exit 99
STUBEOF
chmod +x "$STUB_DIR/gh"

# A fixture ruleset: a directory prefix, a glob, an exact path in global; one
# per-repo entry for acme/widgets; the operator declared.
FIXTURE_RULESET='{
  "codeowners_owner": "@the-operator",
  "self_instrument": {
    "global": ["/.github/CODEOWNERS", "/tools/", "/hooks/*-guard.sh"],
    "repos": {"acme/widgets": ["/.github/workflows/widgets-margot.yml", "/.pre-commit-config.yaml"]}
  }
}'
BEFORE_SHA=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
AFTER_SHA=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
ZERO_SHA=0000000000000000000000000000000000000000

reset_fixtures() {
	rm -f "$TMP"/ruleset.*.json "$TMP"/triage.*.json "$TMP/checks-refused" "$TMP/comment.body" "$TMP/issue.body" "$TMP/self-instrument-matched.txt"
	: >"$TMP/calls.log"
	: >"$TMP/refs.log"
	: >"$TMP/out"
	printf '%s\n' "$FIXTURE_RULESET" >"$TMP/ruleset.v1.json"
	printf '%s\n' "$FIXTURE_RULESET" >"$TMP/ruleset.$BEFORE_SHA.json"
	: >"$TMP/prs.txt"
	: >"$TMP/heads.txt"
	echo '[]' >"$TMP/comments.json"
	: >"$TMP/assignees.txt"
	echo '[]' >"$TMP/issues.json"
	echo '[]' >"$TMP/reviews.json"
}

# run_classify <repo> <before> <files...>
run_classify() {
	local repo="$1" before="$2"
	shift 2
	printf '%s\n' "$@" >"$TMP/files.txt"
	[[ -n "${FILES_JSON:-}" ]] && printf '%s' "$FILES_JSON" >"$TMP/files.json" || rm -f "$TMP/files.json"
	OUT="$(PATH="$STUB_DIR:$PATH" RUNNER_TEMP="$TMP" GITHUB_OUTPUT="$TMP/out" \
		MARGOT_APP_ID=4862659 TARGET_REPO="$repo" BEFORE="$before" AFTER="$AFTER_SHA" bash -e "$CLASSIFY" 2>&1)"
	RC=$?
}
# run_surface <repo> — after a classify; the matched file is already in $TMP.
run_surface() {
	OUT="$(PATH="$STUB_DIR:$PATH" RUNNER_TEMP="$TMP" GITHUB_OUTPUT="$TMP/out" \
		TARGET_REPO="$1" BEFORE="$BEFORE_SHA" AFTER="$AFTER_SHA" bash -e "$SURFACE" 2>&1)"
	RC=$?
}
hit_output() { grep -o '^hit=.*' "$TMP/out" | tail -1; }
matched() { cat "$TMP/self-instrument-matched.txt" 2>/dev/null; }
count_calls() { grep -c "$1" "$TMP/calls.log" || true; }

# ---------------------------------------------------------------------------

section "classify: only an App-bound, same-head Jev light class for every merged head suppresses the alert"
HEAD_SHA=cccccccccccccccccccccccccccccccccccccccc
EARLIER_SHA=dddddddddddddddddddddddddddddddddddddddd
class_case() { # <name> <expected hit> <answer>
	reset_fixtures
	printf '%s\n' "$HEAD_SHA" >"$TMP/heads.txt"
	printf '%s\n' "$3" >"$TMP/triage.$HEAD_SHA.json"
	run_classify acme/widgets "$BEFORE_SHA" .github/CODEOWNERS
	assert_eq "$1" "hit=$2" "$(hit_output)"
}
class_case "mechanical class, App-bound, current head -> silent" false \
	"$(jq -cn --arg sha "$HEAD_SHA" '{head_sha:$sha,classification:"mechanical",decision_source:"jev"}')"
grep -q "commits/$HEAD_SHA/check-runs?app_id=4862659" "$TMP/calls.log" && pass "mechanical lookup is bound to the reviewer App integration" || fail "App integration binding" "$(cat "$TMP/calls.log")"
class_case "documentation class, App-bound, current head -> silent" false \
	"$(jq -cn --arg sha "$HEAD_SHA" '{head_sha:$sha,classification:"documentation",decision_source:"jev"}')"
class_case "legacy mechanical true with no classification, App-bound, current head -> silent" false \
	"$(jq -cn --arg sha "$HEAD_SHA" '{head_sha:$sha,mechanical:true,decision_source:"jev"}')"
class_case "functional class -> alert" true \
	"$(jq -cn --arg sha "$HEAD_SHA" '{head_sha:$sha,classification:"functional",decision_source:"jev"}')"

reset_fixtures
echo "$HEAD_SHA" >"$TMP/heads.txt"
run_classify acme/widgets "$BEFORE_SHA" .github/CODEOWNERS
assert_eq "no triage check -> alert" "hit=true" "$(hit_output)"

class_case "check for an earlier head -> alert" true \
	"$(jq -cn --arg sha "$EARLIER_SHA" '{head_sha:$sha,classification:"mechanical",decision_source:"jev"}')"

reset_fixtures
echo "$HEAD_SHA" >"$TMP/heads.txt"
jq -cn --arg sha "$HEAD_SHA" '{head_sha:$sha,classification:"mechanical",decision_source:"jev"}' >"$TMP/triage.different-app.json"
run_classify acme/widgets "$BEFORE_SHA" .github/CODEOWNERS
assert_eq "check posted by a different App -> alert" "hit=true" "$(hit_output)"
grep -q "app_id=4862659" "$TMP/calls.log" && pass "different-App case queries only the reviewer integration" || fail "different-App filter" "$(cat "$TMP/calls.log")"

class_case "malformed answer -> alert" true 'not-json'

reset_fixtures
echo "$HEAD_SHA" >"$TMP/heads.txt"
touch "$TMP/checks-refused"
run_classify acme/widgets "$BEFORE_SHA" .github/CODEOWNERS
assert_eq "check-runs read refused (caller lacks permission) -> alert" "hit=true" "$(hit_output)"

reset_fixtures
run_classify acme/widgets "$BEFORE_SHA" .github/CODEOWNERS
assert_eq "direct push with no pull request -> alert" "hit=true" "$(hit_output)"

reset_fixtures
printf '%s\n%s\n' "$HEAD_SHA" "$EARLIER_SHA" >"$TMP/heads.txt"
jq -cn --arg sha "$HEAD_SHA" '{head_sha:$sha,classification:"documentation",decision_source:"jev"}' >"$TMP/triage.$HEAD_SHA.json"
jq -cn --arg sha "$EARLIER_SHA" '{head_sha:$sha,classification:"functional",decision_source:"jev"}' >"$TMP/triage.$EARLIER_SHA.json"
run_classify acme/widgets "$BEFORE_SHA" .github/CODEOWNERS
assert_eq "two merged heads, one light and one functional -> alert" "hit=true" "$(hit_output)"

section "classify: both names of a renamed file are considered"
reset_fixtures
echo "$HEAD_SHA" >"$TMP/heads.txt"
jq -cn --arg sha "$HEAD_SHA" '{head_sha:$sha,classification:"functional",decision_source:"jev"}' >"$TMP/triage.$HEAD_SHA.json"
FILES_JSON='[{"filename":"ordinary.txt","previous_filename":".github/CODEOWNERS","status":"renamed"}]' \
	run_classify acme/widgets "$BEFORE_SHA" ordinary.txt
assert_eq "rename away from a protected name with a functional class alerts" "hit=true" "$(hit_output)"
assert_eq "the protected previous name is matched" ".github/CODEOWNERS" "$(matched)"

reset_fixtures
FILES_JSON='[{"filename":".github/CODEOWNERS","previous_filename":"ordinary.txt","status":"renamed"}]' \
	run_classify acme/widgets "$BEFORE_SHA" .github/CODEOWNERS
assert_eq "rename into a protected path alerts" "hit=true" "$(hit_output)"
assert_eq "the protected new name is matched" ".github/CODEOWNERS" "$(matched)"

reset_fixtures
FILES_JSON='[{"filename":"new-name.txt","previous_filename":"old-name.txt","status":"renamed"}]' \
	run_classify acme/widgets "$BEFORE_SHA" new-name.txt
assert_eq "rename with neither name protected does not alert" "hit=false" "$(hit_output)"

section "global hit: an exact global path -> hit=true, the path listed, a ::warning::"
reset_fixtures
run_classify acme/widgets "$BEFORE_SHA" README.md .github/CODEOWNERS
assert_eq "exit 0 (detection succeeded; the run ends green)" "0" "$RC"
assert_eq "hit=true" "hit=true" "$(hit_output)"
assert_eq "exactly the matched path" ".github/CODEOWNERS" "$(matched)"
grep -q "::warning::self-instrument merge $AFTER_SHA: .github/CODEOWNERS" <<<"$OUT" && pass "the run carries a ::warning:: naming the path" || fail "::warning::" "$OUT"

section "per-repo hit: the repo's own entry -> hit=true"
reset_fixtures
run_classify acme/widgets "$BEFORE_SHA" .github/workflows/widgets-margot.yml
assert_eq "exit 0" "0" "$RC"
assert_eq "hit=true" "hit=true" "$(hit_output)"
assert_eq "the per-repo path is matched" ".github/workflows/widgets-margot.yml" "$(matched)"

section "no hit: an unrelated change -> hit=false, logged, exit 0"
reset_fixtures
run_classify acme/widgets "$BEFORE_SHA" src/main.py docs/README.md
assert_eq "exit 0" "0" "$RC"
assert_eq "hit=false" "hit=false" "$(hit_output)"
grep -q "no self-instrument path in this merge" <<<"$OUT" && pass "logs that nothing matched" || fail "no-hit log" "$OUT"
grep -q '::warning::' <<<"$OUT" && fail "no warning without a hit" "$OUT" || pass "no warning without a hit"

section "hit() semantics: a directory prefix, a glob that does not cross '/', an exact path"
reset_fixtures
run_classify acme/widgets "$BEFORE_SHA" tools/deep/nested.sh hooks/pre-guard.sh hooks/sub/pre-guard.sh tools hooks/guard.sh CODEOWNERS
assert_eq "exit 0" "0" "$RC"
assert_eq "prefix matches a nested file; the glob matches one segment only; the exact path needs the directory" \
	"$(printf '%s\n' tools/deep/nested.sh hooks/pre-guard.sh)" "$(matched)"

section "absent repo: a repo with no .repos entry is classified by the global set alone"
reset_fixtures
run_classify acme/other "$BEFORE_SHA" .github/workflows/widgets-margot.yml
assert_eq "exit 0" "0" "$RC"
assert_eq "another repo's per-repo entry does not apply" "hit=false" "$(hit_output)"
run_classify acme/other "$BEFORE_SHA" .github/CODEOWNERS
assert_eq "the global set still applies" "hit=true" "$(hit_output)"

section "BASE-NOT-HEAD (dotty): a merge that REMOVES its own path from the set is still classified by the base ruleset"
reset_fixtures
# At `before` the set names the exact file this merge edits; at `after` the
# merge has emptied the set. Only the base read can catch it — `/rulesets/` is
# deliberately NOT in this fixture, so nothing else rescues the case.
printf '%s\n' '{"codeowners_owner":"@the-operator","self_instrument":{"global":["/rulesets/default-branch.json"],"repos":{}}}' >"$TMP/ruleset.$BEFORE_SHA.json"
printf '%s\n' '{"codeowners_owner":"@the-operator","self_instrument":{"global":[],"repos":{}}}' >"$TMP/ruleset.$AFTER_SHA.json"
run_classify lexijamesesq/dotty "$BEFORE_SHA" rulesets/default-branch.json
assert_eq "exit 0" "0" "$RC"
assert_eq "the self-removing merge is still a hit" "hit=true" "$(hit_output)"
assert_eq "the ruleset was read at the BEFORE sha" "$BEFORE_SHA" "$(cat "$TMP/refs.log")"
grep -q "$AFTER_SHA" "$TMP/refs.log" && fail "the post-merge ruleset is never consulted" "$(cat "$TMP/refs.log")" || pass "the post-merge ruleset is never consulted"
grep -q "base ruleset: dotty rulesets/default-branch.json at $BEFORE_SHA" <<<"$OUT" && pass "the run names the base it classified against" || fail "base named" "$OUT"

section "BASE-NOT-HEAD (another repo): dotty's ruleset is read at v1, never at the push's shas"
reset_fixtures
run_classify acme/widgets "$BEFORE_SHA" .github/CODEOWNERS
assert_eq "read at v1" "v1" "$(cat "$TMP/refs.log")"

section "SELF-COVERAGE: the SHIPPED ruleset lists the alert's own caller (global) and reusable (dotty)"
reset_fixtures
cp "$SHIPPED_RULESET" "$TMP/ruleset.v1.json"
cp "$SHIPPED_RULESET" "$TMP/ruleset.$BEFORE_SHA.json"
run_classify acme/widgets "$BEFORE_SHA" .github/workflows/self-instrument-alert.yml
assert_eq "a merge disabling any repo's caller is a hit (global)" "hit=true" "$(hit_output)"
run_classify lexijamesesq/dotty "$BEFORE_SHA" .github/workflows/estate-self-instrument-alert.yml
assert_eq "a merge editing the reusable itself is a hit (dotty)" "hit=true" "$(hit_output)"
run_classify lexijamesesq/dotty "$BEFORE_SHA" rulesets/default-branch.json
assert_eq "a merge editing the ruleset itself is a hit (dotty)" "hit=true" "$(hit_output)"

section "credentials: the reusable reads checks with GITHUB_TOKEN, never an App secret"
for forbidden in create-github-app-token 'secrets\.' APP_KEY 'environment:' 'workflow_call:.*secrets'; do
	grep -Eq "$forbidden" "$WORKFLOW" && fail "no '$forbidden' in the reusable" "$(grep -En "$forbidden" "$WORKFLOW")" || pass "no '$forbidden' in the reusable"
done
grep -qF "GH_TOKEN: \${{ github.token }}" "$WORKFLOW" && pass "GH_TOKEN is github.token" || fail "GH_TOKEN is github.token"

section "unreadable base ruleset -> the step FAILS (red), never 'nothing to report'"
reset_fixtures
rm -f "$TMP/ruleset.v1.json"
run_classify acme/widgets "$BEFORE_SHA" .github/CODEOWNERS
assert_eq "exit 1" "1" "$RC"
grep -q '::error::cannot read the base self_instrument set' <<<"$OUT" && pass "annotated as an error" || fail "::error::" "$OUT"
grep -q '^hit=' "$TMP/out" && fail "no hit output on a failed classification" "$(cat "$TMP/out")" || pass "no hit output on a failed classification"

section "a base ruleset with no self_instrument object -> the step FAILS"
reset_fixtures
echo '{"repos":{}}' >"$TMP/ruleset.v1.json"
run_classify acme/widgets "$BEFORE_SHA" .github/CODEOWNERS
assert_eq "exit 1" "1" "$RC"
grep -q '::error::' <<<"$OUT" && pass "annotated as an error" || fail "::error::" "$OUT"

section "unreadable changed-file list -> the step FAILS"
reset_fixtures
run_classify acme/widgets "$BEFORE_SHA" FAIL
assert_eq "exit 1" "1" "$RC"
grep -q '::error::cannot read the changed files' <<<"$OUT" && pass "annotated as an error" || fail "::error::" "$OUT"

section "zero before (branch creation) -> exit 0, nothing classified, no API call"
reset_fixtures
run_classify acme/widgets "$ZERO_SHA" .github/CODEOWNERS
assert_eq "exit 0" "0" "$RC"
assert_eq "hit=false" "hit=false" "$(hit_output)"
assert_eq "no API call at all" "0" "$(wc -l <"$TMP/calls.log" | tr -d ' ')"

# ---------------------------------------------------------------------------
section "surface (PR): first run -> ONE comment POSTed with the marker, the sha and the paths; the operator assigned"
reset_fixtures
run_classify acme/widgets "$BEFORE_SHA" .github/CODEOWNERS tools/x.sh
echo 7 >"$TMP/prs.txt"
run_surface acme/widgets
assert_eq "exit 0" "0" "$RC"
assert_eq "one comment posted" "1" "$(count_calls '^api --method POST repos/acme/widgets/issues/7/comments')"
assert_eq "none updated" "0" "$(count_calls '^api --method PATCH')"
grep -q '^<!-- self-instrument-merge -->' "$TMP/comment.body" && pass "the comment starts with the marker" || fail "marker" "$(cat "$TMP/comment.body")"
grep -q "Detection, not a hold: verify the change was intended; if not, revert." "$TMP/comment.body" && pass "the one sentence" || fail "sentence" "$(cat "$TMP/comment.body")"
grep -q "$AFTER_SHA" "$TMP/comment.body" && pass "names the merge sha" || fail "sha" "$(cat "$TMP/comment.body")"
grep -qF -e "- \`.github/CODEOWNERS\`" "$TMP/comment.body" && grep -qF -e "- \`tools/x.sh\`" "$TMP/comment.body" && pass "lists every matched path" || fail "paths" "$(cat "$TMP/comment.body")"
assert_eq "the operator (codeowners_owner, '@' stripped) is assigned once" "1" "$(count_calls '^api --method POST repos/acme/widgets/issues/7/assignees -f assignees\[\]=the-operator$')"
assert_eq "no issue opened when a PR exists" "0" "$(count_calls '^api --method POST repos/acme/widgets/issues -f')"

section "surface (PR): the operator APPROVED the merged PR -> no alert, no assignment (notification audit N5)"
reset_fixtures
run_classify acme/widgets "$BEFORE_SHA" .github/CODEOWNERS
echo 7 >"$TMP/prs.txt"
printf '%s\n' '[{"user":{"login":"margot-the-meticulous[bot]"},"state":"COMMENTED"},{"user":{"login":"the-operator"},"state":"APPROVED"}]' >"$TMP/reviews.json"
run_surface acme/widgets
assert_eq "exit 0" "0" "$RC"
assert_eq "no comment posted" "0" "$(count_calls '^api --method POST repos/acme/widgets/issues/7/comments')"
assert_eq "no assignment" "0" "$(count_calls '/assignees')"
grep -q "the-operator approved this merge — no alert" <<<"$OUT" && pass "says why it stayed quiet" || fail "skip message" "$OUT"

section "surface (PR): someone else approved (or nobody did) -> the alert still fires"
reset_fixtures
run_classify acme/widgets "$BEFORE_SHA" .github/CODEOWNERS
echo 7 >"$TMP/prs.txt"
printf '%s\n' '[{"user":{"login":"margot-the-meticulous[bot]"},"state":"APPROVED"}]' >"$TMP/reviews.json"
run_surface acme/widgets
assert_eq "one comment posted" "1" "$(count_calls '^api --method POST repos/acme/widgets/issues/7/comments')"

section "surface (PR): rerun with our comment present -> PATCHed in place, never a second one; already assigned -> no second POST"
reset_fixtures
run_classify acme/widgets "$BEFORE_SHA" .github/CODEOWNERS
echo 7 >"$TMP/prs.txt"
printf '%s\n' '[{"id":55,"user":{"login":"github-actions[bot]"},"body":"<!-- self-instrument-merge -->\nold"}]' >"$TMP/comments.json"
echo the-operator >"$TMP/assignees.txt"
run_surface acme/widgets
assert_eq "exit 0" "0" "$RC"
assert_eq "existing comment updated" "1" "$(count_calls '^api --method PATCH repos/acme/widgets/issues/comments/55')"
assert_eq "no new comment" "0" "$(count_calls '^api --method POST repos/acme/widgets/issues/7/comments')"
assert_eq "no second assignment" "0" "$(count_calls '/assignees')"
grep -q 'already assigned to the-operator' <<<"$OUT" && pass "logs the idempotent skip" || fail "skip log" "$OUT"

section "surface (PR): a human comment that quotes the marker is NOT ours -> a new comment, the human's untouched"
reset_fixtures
run_classify acme/widgets "$BEFORE_SHA" .github/CODEOWNERS
echo 7 >"$TMP/prs.txt"
printf '%s\n' '[{"id":42,"user":{"login":"someone"},"body":"<!-- self-instrument-merge -->\nquoting the bot"}]' >"$TMP/comments.json"
run_surface acme/widgets
assert_eq "one new comment" "1" "$(count_calls '^api --method POST repos/acme/widgets/issues/7/comments')"
assert_eq "the human's comment untouched" "0" "$(count_calls '^api --method PATCH')"

section "surface (PR): the comment lookup reads EVERY page (ours beyond the first hundred is still found)"
reset_fixtures
run_classify acme/widgets "$BEFORE_SHA" .github/CODEOWNERS
echo 7 >"$TMP/prs.txt"
jq -c '[range(0;150) | {id: (1000 + .), user: {login: "someone"}, body: ("c " + tostring)}] + [{id: 55, user: {login: "github-actions[bot]"}, body: "<!-- self-instrument-merge -->\nold"}]' <<<null >"$TMP/comments.json"
run_surface acme/widgets
grep -q -- '--paginate repos/acme/widgets/issues/7/comments' "$TMP/calls.log" && pass "paginated read" || fail "paginated" "$(cat "$TMP/calls.log")"
assert_eq "the 151st comment (ours) is updated" "1" "$(count_calls '^api --method PATCH repos/acme/widgets/issues/comments/55')"

section "surface (direct push, no PR): ONE issue opened with the same body, titled by sha, the operator assigned"
reset_fixtures
run_classify acme/widgets "$BEFORE_SHA" .github/CODEOWNERS
run_surface acme/widgets
assert_eq "exit 0" "0" "$RC"
assert_eq "one issue opened" "1" "$(count_calls "^api --method POST repos/acme/widgets/issues -f title=self-instrument merge $AFTER_SHA -f body=")"
grep -q "assignees\[\]=the-operator" "$TMP/calls.log" && pass "the issue carries the assignee" || fail "assignee on issue" "$(cat "$TMP/calls.log")"
grep -q '^<!-- self-instrument-merge -->' "$TMP/issue.body" && pass "the issue body carries the marker" || fail "issue marker" "$(cat "$TMP/issue.body")"
assert_eq "no PR comment" "0" "$(count_calls '/comments')"

section "surface (direct push): rerun with the issue already open -> not duplicated"
reset_fixtures
run_classify acme/widgets "$BEFORE_SHA" .github/CODEOWNERS
printf '[{"number":9,"title":"self-instrument merge %s","pull_request":null},{"number":10,"title":"self-instrument merge %s","pull_request":{"url":"x"}}]\n' "$AFTER_SHA" "$AFTER_SHA" >"$TMP/issues.json"
run_surface acme/widgets
assert_eq "exit 0" "0" "$RC"
assert_eq "no second issue" "0" "$(count_calls '^api --method POST repos/acme/widgets/issues -f')"
grep -q 'issue #9 already exists' <<<"$OUT" && pass "the existing issue (not the PR with the same title) is the dedupe hit" || fail "dedupe" "$OUT"

section "surface (direct push): the issue lookup reads EVERY page (the alert issue beyond the first hundred is still found)"
reset_fixtures
run_classify acme/widgets "$BEFORE_SHA" .github/CODEOWNERS
jq -c --arg t "self-instrument merge $AFTER_SHA" '[range(0;150) | {number: (1000 + .), title: ("issue " + tostring), pull_request: null}] + [{number: 9, title: $t, pull_request: null}]' <<<null >"$TMP/issues.json"
run_surface acme/widgets
assert_eq "exit 0" "0" "$RC"
grep -q -- '--paginate repos/acme/widgets/issues?state=all' "$TMP/calls.log" && pass "paginated read" || fail "paginated" "$(cat "$TMP/calls.log")"
assert_eq "no duplicate issue" "0" "$(count_calls '^api --method POST repos/acme/widgets/issues -f')"
grep -q 'issue #9 already exists' <<<"$OUT" && pass "the 151st issue (ours) is the dedupe hit" || fail "dedupe past page one" "$OUT"

section "surface: no codeowners_owner in the base ruleset -> FAILS (nobody to assign is no alert)"
reset_fixtures
run_classify acme/widgets "$BEFORE_SHA" .github/CODEOWNERS
echo '{"self_instrument":{"global":["/.github/CODEOWNERS"],"repos":{}}}' >"$TMP/ruleset.v1.json"
echo 7 >"$TMP/prs.txt"
run_surface acme/widgets
assert_eq "exit 1" "1" "$RC"
grep -q '::error::no codeowners_owner' <<<"$OUT" && pass "annotated as an error" || fail "::error::" "$OUT"
assert_eq "nothing written" "0" "$(count_calls '^api --method')"

section "surface (dotty): the assignee is read from the ruleset at BEFORE, never HEAD"
reset_fixtures
run_classify lexijamesesq/dotty "$BEFORE_SHA" rulesets/default-branch.json
: >"$TMP/refs.log"
echo 7 >"$TMP/prs.txt"
run_surface lexijamesesq/dotty
assert_eq "exit 0" "0" "$RC"
assert_eq "read at the before sha" "$BEFORE_SHA" "$(sort -u "$TMP/refs.log")"

finish
