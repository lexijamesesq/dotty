#!/usr/bin/env bash
# Execute the trusted handoff against both workflow schemas. No network writes.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/assert.sh"
REPO="$(cd "$SCRIPT_DIR/../.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
python3 - "$REPO/.github/workflows/estate-gate.yml" >"$TMP/dispatch.sh" <<'PY'
import sys, yaml
wf = yaml.safe_load(open(sys.argv[1]))
assert any(step.get('id') == 'dispatch_token' and step['with'].get('permission-contents') == 'read' for job in wf['jobs'].values() for step in job.get('steps', []))
for job in wf['jobs'].values():
    for step in job.get('steps', []):
        if step.get('name', '').startswith('Dispatch margot-review'):
            print(step['run'])
PY
python3 - "$REPO/.github/workflows/estate-gate.yml" >"$TMP/project.sh" <<'PY'
import sys, yaml
wf = yaml.safe_load(open(sys.argv[1]))
for job in wf['jobs'].values():
    for step in job.get('steps', []):
        if step.get('id') == 'triage':
            for line in step['run'].splitlines():
                if line.strip().startswith('mechanical=false;'):
                    print(line.strip())
                    print('printf "%s\\n" "$mechanical"')
                    sys.exit(0)
sys.exit('gate classification projection not found')
PY
cat >"$TMP/gh" <<'STUB'
#!/usr/bin/env bash
if [[ "$*" == *contents/.github/workflows/margot-review.yml* ]]; then
  if [[ "$SCHEMA" == new ]]; then echo '      classification:'; fi
elif [[ "$*" == *dispatches* ]]; then
  cat >"$PAYLOAD"
else
  exit 99
fi
STUB
chmod +x "$TMP/gh"
section "all classes preserve the gate's projection for old and new reviewers"
for cls in mechanical documentation functional; do
	for reviewer in old new; do
		mechanical="$(classification="$cls" bash "$TMP/project.sh")"
		SCHEMA="$reviewer" PAYLOAD="$TMP/payload" CLASSIFICATION="$cls" MECHANICAL="$mechanical" \
			TARGET_REPO=example/widgets PR_NUMBER=1 HEAD_SHA=head OWNED_TIER=none \
			PATH="$TMP:$PATH" bash "$TMP/dispatch.sh" >/dev/null
		expected_triage=not-mechanical
		[[ "$cls" == mechanical ]] && expected_triage=mechanical
		assert_eq "$cls/$reviewer reviewer uses the gate projection" "$expected_triage" "$(jq -r '.inputs.triage' "$TMP/payload")"
		if [[ "$reviewer" == new ]]; then
			assert_eq "$cls/new reviewer receives the class" "$cls" "$(jq -r '.inputs.classification' "$TMP/payload")"
		else
			assert_eq "$cls/old reviewer has exact old input keys" 'owned_tier,pr,repo,sha,triage' "$(jq -r '.inputs | keys | join(",")' "$TMP/payload")"
		fi
	done
done

CI="$REPO/.github/workflows/estate-ci.yml"
decision_prog() { grep -oE "'if \(type==\"object\".*\"functional\" end'" "$CI" | head -1 | sed "s/^'//; s/'$//"; }
D_CI="$(decision_prog)"
[[ -n "$D_CI" ]] && pass "floor classification program found" || fail "floor classification program found"
# shellcheck disable=SC2016  # the pattern is literal workflow text, not an expansion
grep -qF 'mechanical=false; [[ "$classification" == mechanical || "$classification" == documentation ]] && mechanical=true' "$CI" &&
	pass "floor light-route projection found" || fail "floor light-route projection found"
SHA=deadbeefcafe0000000000000000000000000001
floor_output() {
	local classification
	classification="$(printf '%s' "$1" | jq -r --arg sha "$SHA" "$D_CI" 2>/dev/null || echo functional)"
	[[ "$classification" == mechanical || "$classification" == documentation ]] && echo true || echo false
}
section "floor mechanical output means either light route"
for cls in mechanical documentation; do
	assert_eq "$cls -> true" true "$(floor_output '{"classification":"'"$cls"'","mechanical":false,"decision_source":"jev","head_sha":"'"$SHA"'"}')"
done
assert_eq "functional -> false" false "$(floor_output '{"classification":"functional","mechanical":true,"decision_source":"jev","head_sha":"'"$SHA"'"}')"
assert_eq "missing check -> false" false "$(floor_output '')"
assert_eq "malformed class -> false" false "$(floor_output '{"classification":"bogus","mechanical":true,"decision_source":"jev","head_sha":"'"$SHA"'"}')"
assert_eq "unreadable check -> false" false "$(floor_output 'not json')"
finish
