#!/usr/bin/env bash
# Execute the trusted handoff against both workflow schemas. No network writes.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/assert.sh"
REPO="$(cd "$SCRIPT_DIR/../.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
MARGOT_LEGACY_REF="$(
	python3 - "$REPO/.github/workflows/estate-gate.yml" <<'PYREF'
import sys, yaml
print(yaml.safe_load(open(sys.argv[1]))['env']['MARGOT_LEGACY_REF'])
PYREF
)"
python3 - "$REPO/.github/workflows/estate-gate.yml" >"$TMP/dispatch.sh" <<'PY'
import sys, yaml
wf = yaml.safe_load(open(sys.argv[1]))
assert any(step.get('id') == 'dispatch_token' and step['with'].get('permission-contents') == 'read' for job in wf['jobs'].values() for step in job.get('steps', []))
for job in wf['jobs'].values():
    for step in job.get('steps', []):
        if step.get('name', '').startswith('Dispatch margot-review'):
            print(step['run'])
PY
python3 - "$REPO/.github/workflows/estate-gate.yml" >"$TMP/triage.sh" <<'PYTRIAGE'
import sys, yaml
wf = yaml.safe_load(open(sys.argv[1]))
for job in wf['jobs'].values():
    for step in job.get('steps', []):
        if step.get('name', '').startswith('Dispatch margot-triage'):
            print(step['run'])
            sys.exit(0)
sys.exit('gate triage dispatch not found')
PYTRIAGE
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
  printf '%s\n' "$*" >"$LOOKUP"
  if [[ "$SCHEMA" == new ]]; then echo '      classification:'; fi
elif [[ "$*" == *dispatches* ]]; then
  printf '%s\n' "$*" >"$PAYLOAD.endpoint"
  cat >"$PAYLOAD"
else
  exit 99
fi
STUB
chmod +x "$TMP/gh"
section "triage dispatch uses the pinned release and its unchanged input contract"
PAYLOAD="$TMP/triage-payload" MARGOT_LEGACY_REF="$MARGOT_LEGACY_REF" \
	TARGET_REPO=example/widgets PR_NUMBER=1 HEAD_SHA=head \
	PATH="$TMP:$PATH" bash "$TMP/triage.sh" >/dev/null
assert_eq "triage dispatch uses the workflow release ref" "$MARGOT_LEGACY_REF" "$(jq -r .ref "$TMP/triage-payload")"
assert_eq "triage dispatch preserves exact inputs" '{"pr":"1","repo":"example/widgets","sha":"head"}' "$(jq -cS .inputs "$TMP/triage-payload")"
assert_eq "triage dispatch targets the triage workflow" 'api -X POST repos/lexijamesesq/margot/actions/workflows/margot-triage.yml/dispatches --input -' "$(cat "$TMP/triage-payload.endpoint")"
section "all classes preserve the gate's projection for old and new reviewers"
for cls in mechanical documentation functional; do
	for reviewer in old new; do
		mechanical="$(classification="$cls" bash "$TMP/project.sh")"
		SCHEMA="$reviewer" PAYLOAD="$TMP/payload" LOOKUP="$TMP/lookup" MARGOT_LEGACY_REF="$MARGOT_LEGACY_REF" \
			CLASSIFICATION="$cls" MECHANICAL="$mechanical" \
			TARGET_REPO=example/widgets PR_NUMBER=1 HEAD_SHA=head OWNED_TIER=none \
			PATH="$TMP:$PATH" bash "$TMP/dispatch.sh" >/dev/null
		assert_eq "$cls/$reviewer dispatch uses the workflow release ref" "$MARGOT_LEGACY_REF" "$(jq -r .ref "$TMP/payload")"
		grep -qF "?ref=$MARGOT_LEGACY_REF" "$TMP/lookup" && pass "$cls/$reviewer schema uses the workflow release ref" || fail "$cls/$reviewer schema uses the workflow release ref"
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
# The floor's `mechanical` output ("skip the repo's jobs") is decided by two
# workflow steps, executed here as written: `files` (the manifest/lockfile
# match, run against a throwaway git repo) and `repo_jobs` (the class x manifest
# decision).
step_run() {
	python3 - "$CI" "$1" <<'PY'
import sys, yaml
wf = yaml.safe_load(open(sys.argv[1]))
for step in wf['jobs']['floor']['steps']:
    if step.get('id') == sys.argv[2]:
        print(step['run'])
        sys.exit(0)
sys.exit('step ' + sys.argv[2] + ' not found')
PY
}
step_run files >"$TMP/files.sh" && step_run repo_jobs >"$TMP/repo_jobs.sh" && pass "floor files and repo_jobs steps found" || fail "floor files and repo_jobs steps found"
# manifest_for <path>... : the files step's `manifest` output for a PR changing exactly those paths.
manifest_for() {
	local ws="$TMP/ws.$RANDOM" f base
	mkdir -p "$ws/repo" "$ws/tmp"
	git -C "$ws/repo" init -q && git -C "$ws/repo" -c user.name=t -c user.email=t@t commit -q --allow-empty -m base >/dev/null 2>&1
	base="$(git -C "$ws/repo" rev-parse HEAD)"
	for f in "$@"; do
		mkdir -p "$ws/repo/$(dirname "$f")"
		echo x >"$ws/repo/$f"
	done
	git -C "$ws/repo" add -A && git -C "$ws/repo" -c user.name=t -c user.email=t@t commit -q -m head >/dev/null 2>&1
	GITHUB_WORKSPACE="$ws" RUNNER_TEMP="$ws/tmp" GITHUB_OUTPUT="$ws/out" \
		BASE_SHA="$base" HEAD_SHA="$(git -C "$ws/repo" rev-parse HEAD)" bash "$TMP/files.sh" >/dev/null 2>&1
	sed -n 's/^manifest=//p' "$ws/out"
}
# floor_output <class> <manifest>: the repo_jobs step's `mechanical` output.
floor_output() {
	local out="$TMP/out.$RANDOM"
	: >"$out"
	CLASSIFICATION="$1" MANIFEST="$2" GITHUB_OUTPUT="$out" bash "$TMP/repo_jobs.sh" >/dev/null 2>&1
	sed -n 's/^mechanical=//p' "$out"
}
section "floor mechanical output: skip repo jobs only for a light class with no runtime manifest change"
assert_eq "functional, no manifest -> false" false "$(floor_output functional false)"
assert_eq "functional, manifest -> false" false "$(floor_output functional true)"
assert_eq "documentation, no manifest -> true" true "$(floor_output documentation false)"
assert_eq "documentation, manifest -> false" false "$(floor_output documentation true)"
assert_eq "mechanical, no manifest (hook revs, action pins) -> true" true "$(floor_output mechanical false)"
assert_eq "mechanical, manifest -> false" false "$(floor_output mechanical true)"
section "floor mechanical output fails safe: unknown runs the repo's jobs"
assert_eq "file list not computed (empty manifest) -> false" false "$(floor_output mechanical '')"
assert_eq "documentation, file list not computed -> false" false "$(floor_output documentation '')"
assert_eq "triage not computed (empty class) -> false" false "$(floor_output '' false)"
assert_eq "unrecognised class -> false" false "$(floor_output bogus false)"
section "the manifest match: basename, anywhere in the tree"
for m in package.json package-lock.json pnpm-lock.yaml yarn.lock pyproject.toml uv.lock poetry.lock requirements.txt requirements-dev.txt Pipfile Pipfile.lock go.mod go.sum Cargo.toml Cargo.lock Gemfile Gemfile.lock studio/package.json a/b/uv.lock; do
	assert_eq "$m -> manifest" true "$(manifest_for "$m")"
done
assert_eq "a manifest under a non-ASCII directory -> manifest" true "$(manifest_for "é/package.json")"
assert_eq "a manifest among other changes -> manifest" true "$(manifest_for README.md docs/x.md web/package-lock.json)"
for n in .pre-commit-config.yaml .github/workflows/ci.yml README.md package.json.md docs/package.json.bak mypackage.json requirements.md requirements/base.in src/uv.lock.txt; do
	assert_eq "$n -> not a manifest" false "$(manifest_for "$n")"
done
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
jq -n --slurpfile request "$MARGOT_ROOT/request.json" \
	'{result:{kind:"classified",request:$request[0],classification:"documentation",decision_source:"fallback",triage_check_id:101},actions:[],responses:[]}' >"$MARGOT_ROOT/result.json"
bash "$TMP/classification.sh" || exit 1
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
