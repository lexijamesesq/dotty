#!/usr/bin/env bash
# Test suite for the "Post the initial `margot` check" step of
# .github/workflows/estate-gate.yml (the trusted lane's last step) — the promise that a pull
# request shows what Margot is doing from the moment her review is dispatched,
# not from the moment a runner picks it up. The step's `run:` block is
# extracted from the workflow file by step name and executed against a stub
# `gh`, so the YAML and the test cannot drift.
#
# Why this exists: one release opened thirteen dependency bumps at once and
# fourteen reviews queued behind two runners; until margot-review's own job
# started, each PR showed NO `margot` check — a queued review looked exactly
# like one that would never happen.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/assert.sh"

WORKFLOW="${WORKFLOW:-${SCRIPT_DIR}/../../.github/workflows/estate-gate.yml}"
[[ -f "$WORKFLOW" ]] || {
	echo "FATAL: missing $WORKFLOW"
	exit 2
}
command -v python3 >/dev/null || {
	echo "FATAL: python3 required to read the workflow"
	exit 2
}

TMP="$(mktemp -d -t estate-margot-queued-test.XXXXXX)"
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT INT TERM

STEP="$TMP/step.sh"
python3 - "$WORKFLOW" >"$STEP" <<'PY'
import sys, yaml
wf = yaml.safe_load(open(sys.argv[1]))
for job in wf["jobs"].values():
    for step in job.get("steps", []):
        if step.get("name", "").startswith("Post the initial `margot` check"):
            sys.stdout.write(step["run"])
            sys.exit(0)
sys.exit("queued-check step not found")
PY
[[ -s "$STEP" ]] || {
	echo "FATAL: could not extract the queued-check step from $WORKFLOW"
	exit 2
}

STUB_DIR="$TMP/bin"
mkdir -p "$STUB_DIR"
cat >"$STUB_DIR/gh" <<STUBEOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >>"$TMP/calls.log"
if [[ "\$1 \$2 \$3" == "api -X POST" ]]; then
  cat >"$TMP/body.json"
  [[ -f "$TMP/post.fail" ]] && exit 1
  echo '{"id": 4242}'; exit 0
fi
case "\$2" in
  repos/*/commits/*/check-runs?check_name=margot*)
    # the existence lookup: honour --jq against the fixture
    shift 2; [[ "\$1" == "--jq" ]] && jq -r "\$2" "$TMP/existing.json"; exit 0 ;;
esac
echo "stub gh: unexpected call: \$*" >&2; exit 99
STUBEOF
chmod +x "$STUB_DIR/gh"

# run_step [existing-check-runs-json]
run_step() {
	: >"$TMP/calls.log"
	rm -f "$TMP/body.json"
	printf '%s' "${1:-{\"check_runs\":[]\}}" >"$TMP/existing.json"
	OUT="$(PATH="$STUB_DIR:$PATH" TARGET_REPO=acme/widgets HEAD_SHA=abc123def PR_NUMBER=7 MARGOT_APP_ID=4862659 \
		DISPATCH_RUN_URL=https://example.invalid/runs/1 bash -e "$STEP" 2>&1)"
	RC=$?
}

section "the trusted lane posts ONE initial margot check-run on the target head"
run_step
assert_eq "exit 0" "0" "$RC"
assert_eq "exactly one POST" "1" "$(grep -c '^api -X POST repos/acme/widgets/check-runs' "$TMP/calls.log" || true)"
assert_eq "name is margot" "margot" "$(jq -r .name "$TMP/body.json")"
assert_eq "head_sha is the dispatched head" "abc123def" "$(jq -r .head_sha "$TMP/body.json")"
assert_eq "status is in_progress (not completed)" "in_progress" "$(jq -r .status "$TMP/body.json")"
[[ "$(jq -r '.conclusion // "none"' "$TMP/body.json")" == "none" ]] && pass "no conclusion on an in-progress check" || fail "no conclusion on an in-progress check" "$(cat "$TMP/body.json")"
grep -q 'dispatched' <<<"$(jq -r .output.title "$TMP/body.json")" && pass "title says dispatched" || fail "title says dispatched" "$(jq -r .output.title "$TMP/body.json")"
grep -q 'https://example.invalid/runs/1' <<<"$(jq -r .output.summary "$TMP/body.json")" && pass "summary carries the dispatch run link" || fail "summary carries the dispatch run link" "$(jq -r .output.summary "$TMP/body.json")"
grep -q '#7' <<<"$(jq -r .output.summary "$TMP/body.json")" && pass "summary names the PR" || fail "summary names the PR" "$(jq -r .output.summary "$TMP/body.json")"
grep -q 'posted the initial margot check for acme/widgets PR #7' <<<"$OUT" && pass "logs what it posted" || fail "logs what it posted" "$OUT"

section "the lookup is by name AND App id on the head, the same query margot-review uses"
grep -q 'check-runs?check_name=margot&app_id=' "$TMP/calls.log" && pass "existence lookup by name + app id" || fail "existence lookup by name + app id" "$(cat "$TMP/calls.log")"

section "a margot check already on the head (a re-dispatch) -> no second check-run"
run_step '{"check_runs":[{"id":99,"name":"margot","status":"completed"}]}'
assert_eq "exit 0" "0" "$RC"
assert_eq "no POST" "0" "$(grep -c '^api -X POST' "$TMP/calls.log" || true)"
grep -q 'already exists' <<<"$OUT" && pass "says why it did not post" || fail "says why it did not post" "$OUT"

section "the check body is built with jq --arg (no shell interpolation into JSON)"
grep -q 'jq -n --arg sha' "$STEP" && pass "jq --arg body" || fail "jq --arg body" "$(cat "$STEP")"

section "a failed post fails the step (a silent miss would recreate the blank page)"
touch "$TMP/post.fail"
run_step
rm -f "$TMP/post.fail"
assert_eq "exit non-zero when the POST fails" "1" "$RC"

finish
