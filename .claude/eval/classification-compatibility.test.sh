#!/usr/bin/env bash
# Exercise the current native classification and handoff. No network writes.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/assert.sh"
REPO="$(cd "$SCRIPT_DIR/../.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
section "migrated native job validates classification and sends one current handoff"
python3 - "$REPO/.github/workflows/estate-pr-ci.yml" "$TMP" <<'PYCODE'
import pathlib, sys, yaml
steps = yaml.safe_load(open(sys.argv[1]))['jobs']['checks']['steps']
for step_id, path in [('classification', 'classification.sh'),
                      ('snapshot', 'snapshot.sh'),
                      ('handoff', 'handoff.sh')]:
    pathlib.Path(sys.argv[2], path).write_text(next(s['run'] for s in steps if s.get('id') == step_id))
PYCODE
mkdir -p "$TMP/instance"
export MARGOT_ROOT="$TMP/instance" GITHUB_OUTPUT="$TMP/output"
export TARGET_REPO=example/widgets PR_NUMBER=1
export GH_TOKEN=fixture-read MARGOT_DISPATCH_TOKEN=fixture-dispatch
export CURRENT_PULL="$TMP/current-pull.json" PAYLOAD="$TMP/payload"
export PATH="$TMP:$PATH"
cat >"$TMP/gh" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
if [[ "$*" == *dispatches* ]]; then
  [[ "$GH_TOKEN" == fixture-dispatch ]] || exit 99
  while [[ $# -gt 0 ]]; do
    if [[ "$1" == --input ]]; then cp "$2" "$PAYLOAD"; break; fi
    shift
  done
  exit "${DISPATCH_EXIT:-0}"
else
  [[ "$GH_TOKEN" == fixture-read ]] || exit 99
  cat "$CURRENT_PULL"
fi
STUB
chmod +x "$TMP/gh"
SHA=$(printf '%040d' 1)
BASE=$(printf '%040d' 2)
jq -n --arg head "$SHA" --arg base "$BASE" \
	'{repository:"example/widgets", pr:1, base:$base, head:$head, phase:"triage", workflowRef:"v0.10.4"}' >"$MARGOT_ROOT/request.json"
echo '{"handoff":{"repository":"example/reviewer","workflow":"margot-review.yml","ref":"v0.10.4"}}' >"$MARGOT_ROOT/config.json"
jq -n --arg head "$SHA" --arg base "$BASE" \
	'{number:1,state:"open",draft:false,title:"title",body:"body",head:{sha:$head,ref:"branch",repo:{full_name:"example/widgets"}},base:{sha:$base,ref:"main",repo:{full_name:"example/widgets"}}}' >"$CURRENT_PULL"
bash "$TMP/snapshot.sh" || exit 1
assert_eq "all PR metadata reaches scanning" $'title\nbody\nbranch\nmain' "$(cat "$MARGOT_ROOT/pr-text")"
for classification in mechanical functional documentation; do
	jq -n --slurpfile request "$MARGOT_ROOT/request.json" --arg classification "$classification" \
		'{result:{kind:"classified",request:$request[0],classification:$classification,decision_source:"fallback",triage_check_id:101},actions:[],responses:[]}' >"$MARGOT_ROOT/result.json"
	: >"$GITHUB_OUTPUT"
	bash "$TMP/classification.sh" || exit 1
	assert_eq "consumer receives the authenticated $classification class" "$classification" \
		"$(awk -F= '$1 == "classification" {print $2}' "$GITHUB_OUTPUT")"
done
export TRIAGE_CHECK_ID
TRIAGE_CHECK_ID=$(awk -F= '$1 == "triage_check_id" {print $2}' "$GITHUB_OUTPUT")
assert_exit "current classified PR dispatch succeeds" 0 bash "$TMP/handoff.sh"
assert_eq "handoff carries the published classification and revision" "$BASE/$SHA/101" "$(jq -r '.inputs | .base_sha + "/" + .sha + "/" + .triage_check_id' "$PAYLOAD")"
assert_eq "handoff matches the restored receiver inputs" 'base_sha,pr,repo,sha,triage_check_id,workflow_ref' "$(jq -r '.inputs | keys | join(",")' "$PAYLOAD")"

# The classifier CLI can exit successfully with a held result. Native CI must fail it.
cp "$MARGOT_ROOT/result.json" "$TMP/good-result"
jq '.result.kind = "held"' "$TMP/good-result" >"$MARGOT_ROOT/result.json"
if bash "$TMP/classification.sh" >/dev/null 2>&1; then
	fail "held classification blocks the hosted step"
else
	pass "held classification blocks the hosted step"
fi
cp "$TMP/good-result" "$MARGOT_ROOT/result.json"

# Text changes and revision changes need distinct handoff guards after classification.
cp "$CURRENT_PULL" "$TMP/good-pull"
for change in '.title = "new title"' '.head.sha = "new head"'; do
	rm -f "$PAYLOAD"
	jq "$change" "$TMP/good-pull" >"$CURRENT_PULL"
	if bash "$TMP/handoff.sh" >/dev/null 2>&1; then
		fail "changed PR blocks handoff: $change"
	elif [[ -e "$PAYLOAD" ]]; then
		fail "changed PR blocks handoff: $change" "review request was sent"
	else
		pass "changed PR blocks handoff: $change"
	fi
done
cp "$TMP/good-pull" "$CURRENT_PULL"
DISPATCH_EXIT=1 assert_exit "dispatch failure fails the hosted step" 1 bash "$TMP/handoff.sh"
finish
