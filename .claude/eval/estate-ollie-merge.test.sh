#!/usr/bin/env bash
# Test suite for .github/workflows/estate-ollie-merge.yml, retired: the agent
# Ollie lands pull requests now, and this reusable is a no-op kept only because
# every enrolled repository's ollie-merge.yml still calls it at @v1. The
# step's `run:` block is extracted from the workflow file and executed verbatim
# against a `gh` that fails on any call, so the YAML and the test cannot drift.
#
# What it guards: the lane merges nothing and calls nothing, it ends green, and
# its interface still accepts what every caller passes (a secret passed to a
# reusable workflow that doesn't declare it fails the caller's run). The merge
# authority it leaves behind, Ollie's App on the update wall, is unchanged.
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
# shellcheck disable=SC2317,SC2329 # Invoked by the EXIT/INT/TERM trap below.
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT INT TERM

# The workflow's facts, read once: its jobs, steps and workflow_call interface.
read_workflow() {
	python3 - "$WORKFLOW" "$1" <<'PY'
import json, sys, yaml
wf = yaml.safe_load(open(sys.argv[1]))
on = wf.get("on", wf.get(True, {}))  # PyYAML reads a bare `on:` key as True
call = on.get("workflow_call", {})
jobs = wf["jobs"]
steps = [s for j in jobs.values() for s in j.get("steps", [])]
facts = {
    "jobs": sorted(jobs),
    "environment": [j.get("environment") for j in jobs.values() if j.get("environment")],
    "steps": len(steps),
    "uses": [s["uses"] for s in steps if "uses" in s],
    "input_pr_required": call.get("inputs", {}).get("pr", {}).get("required"),
    "secret_required": call.get("secrets", {}).get("OLLIE_APP_KEY", {}).get("required"),
    "step_names": [s.get("name", "") for s in steps],
}
if sys.argv[2] == "run":
    sys.stdout.write(steps[0]["run"])
else:
    print(json.dumps(facts[sys.argv[2]]))
PY
}

STEP="$TMP/step.sh"
read_workflow run >"$STEP"
[[ -s "$STEP" ]] || {
	echo "FATAL: could not extract the step from $WORKFLOW"
	exit 2
}

# A gh that records any call and fails it: the retired lane must make none.
STUB_DIR="$TMP/bin"
mkdir -p "$STUB_DIR"
cat >"$STUB_DIR/gh" <<STUBEOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >>"$TMP/calls.log"
echo "stub gh: the retired lane called gh: \$*" >&2
exit 99
STUBEOF
chmod +x "$STUB_DIR/gh"

section "the retired step merges nothing, calls nothing, and ends green"
: >"$TMP/calls.log"
out=$(PATH="$STUB_DIR:$PATH" PR=7 GITHUB_REPOSITORY=lexijamesesq/ollie-sandbox bash -e "$STEP" 2>&1)
rc=$?
assert_eq "exit 0" "0" "$rc"
assert_eq "no gh call at all" "" "$(cat "$TMP/calls.log")"
case "$out" in
*"::notice::"*"retired"*"agent Ollie lands pull requests"*) pass "says the lane is retired and the agent Ollie lands PRs" ;;
*) fail "says the lane is retired and the agent Ollie lands PRs" "got: $out" ;;
esac
case "$out" in
*"#7"*) pass "names the pull request it was asked about" ;;
*) fail "names the pull request it was asked about" "got: $out" ;;
esac

section "nothing left that could merge: one step, no token, no merge-key environment"
assert_eq "one job, still called merge" '["merge"]' "$(read_workflow jobs)"
assert_eq "one step" "1" "$(read_workflow steps)"
assert_eq "no action used (no token mint, no checkout)" "[]" "$(read_workflow uses)"
assert_eq "no default-branch environment" "[]" "$(read_workflow environment)"
grep -qE 'PUT|/merge|ollie-state' "$STEP" && fail "the step's shell mentions no merge or state call" "$(cat "$STEP")" ||
	pass "the step's shell mentions no merge or state call"

section "the interface every caller still uses"
assert_eq "the pr input stays required" "true" "$(read_workflow input_pr_required)"
assert_eq "OLLIE_APP_KEY is still declared, and optional" "false" "$(read_workflow secret_required)"
CALLER="$SCRIPT_DIR/../../.github/workflows/ollie-merge.yml"
# shellcheck disable=SC2016 # the caller's GitHub expression, matched literally, not a shell one
grep -q 'estate-ollie-merge.yml@v1' "$CALLER" && grep -qF 'OLLIE_APP_KEY: ${{ secrets.OLLIE_APP_KEY }}' "$CALLER" &&
	pass "dotty's own caller passes pr and OLLIE_APP_KEY to @v1, which this interface accepts" ||
	fail "dotty's own caller passes pr and OLLIE_APP_KEY to @v1, which this interface accepts" "$(cat "$CALLER")"

section "canonical merge authority and caller"
SHIPPED="$SCRIPT_DIR/../../rulesets/default-branch.json"
assert_eq "Ollie bypasses only the update wall through a PR" "true" "$(jq '[.branch_rulesets[] | select(.rules | index("update")) | .bypass_actors[] | select(.actor_type == "Integration")] == [{"actor_id":4984137,"actor_type":"Integration","bypass_mode":"pull_request"}]' "$SHIPPED")"
assert_eq "no App bypasses review or checks" "true" "$(jq '[.branch_rulesets[] | select(.rules | any(. == "pull_request" or . == "required_status_checks")) | .bypass_actors[] | select(.actor_type == "Integration")] == []' "$SHIPPED")"
assert_eq "all declared branch bypasses remain PR-only" "true" "$(jq 'all(.branch_rulesets[].bypass_actors[]; .bypass_mode == "pull_request")' "$SHIPPED")"
assert_eq "each wall retains the admin anti-lockout actor" "true" "$(jq 'all(.branch_rulesets[]; any(.bypass_actors[]; .actor_type == "RepositoryRole" and .actor_id == 5))' "$SHIPPED")"
assert_eq "dependency actors retain current and previous engines" "true" "$(jq '(["dependabot[bot]","ollie-the-intern[bot]","renovate[bot]"] - .dependency_bot_authors) == []' "$SHIPPED")"
assert_eq "author Apps cannot use dependency routing" "true" "$(jq 'all(.dependency_bot_authors[]; . != "claude-the-enduring[bot]" and . != "cody-the-alchemist[bot]")' "$SHIPPED")"
assert_eq "retired Renovate has no bypass" "true" "$(jq 'all(.branch_rulesets[].bypass_actors[]; .actor_id != 2740)' "$SHIPPED")"
assert_eq "Dotty floating major remains mutable" '["refs/tags/v1"]' "$(jq -c '.repos["lexijamesesq/dotty"].tag_ruleset_exclude' "$SHIPPED")"
assert_eq "no other repo un-protects a tag" "1" \
	"$(jq '[.repos | to_entries[] | select(.value.tag_ruleset_exclude != null)] | length' "$SHIPPED")"
assert_eq "public reviewer package retains independent hosted product coverage" "true" "$(jq '.repos["lexijamesesq/margot-pr-reviewer"].required_contexts | index("Package Validation") != null' "$SHIPPED")"
finish
