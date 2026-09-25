#!/usr/bin/env bash
# Test suite for the merge step of .github/workflows/estate-ollie-merge.yml —
# the one decision the estate's merger makes: which outcomes of PUT /merge are
# GitHub's gate (logged, run ends green) and which are genuine errors (run
# fails loudly). The step's `run:` block is extracted from the workflow file
# and executed verbatim against a stub `gh`, so the YAML and the test cannot
# drift apart: a change to the step is what this suite runs.
#
# Why this exists: the first cut swallowed every non-zero exit as "the gate"
# (a broken pipeline would have shown green), and before that a refusal under
# the runner's `bash -e` aborted the step before its own logging branch.
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
#   fork.txt   — what `gh pr view … --jq .isCrossRepository` prints (or "FAIL"
#                to exit non-zero with nothing on stdout: an unreadable PR)
#   merge.rc   — exit code of `gh api --method PUT …/merge`
#   merge.out  — what that call writes (stdout+stderr are captured together
#                by the step, the way gh really prints its errors)
STUB_DIR="$TMP/bin"
mkdir -p "$STUB_DIR"
cat >"$STUB_DIR/gh" <<STUBEOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >>"$TMP/calls.log"
case "\$1 \$2" in
  "pr view")
    v="\$(cat "$TMP/fork.txt")"
    [[ "\$v" == FAIL ]] && exit 1
    printf '%s\n' "\$v"; exit 0 ;;
  "api --method")
    cat "$TMP/merge.out"
    exit "\$(cat "$TMP/merge.rc")" ;;
esac
echo "stub gh: unexpected call: \$*" >&2; exit 99
STUBEOF
chmod +x "$STUB_DIR/gh"

# run_step <fork> <merge-rc> <merge-out> — executes the step the way the
# runner does: `bash -e` with the step's own `set -uo pipefail` inside.
run_step() {
	printf '%s' "$1" >"$TMP/fork.txt"
	printf '%s' "$2" >"$TMP/merge.rc"
	printf '%s' "$3" >"$TMP/merge.out"
	: >"$TMP/calls.log"
	OUT="$(PATH="$STUB_DIR:$PATH" GITHUB_REPOSITORY=acme/widgets PR=7 bash -e "$STEP" 2>&1)"
	RC=$?
}
puts() { grep -c '^api --method PUT ' "$TMP/calls.log" || true; }

section "merged: PUT succeeds -> logs the sha, exit 0"
run_step false 0 '{"sha":"abc1234","merged":true}'
assert_eq "exit 0" "0" "$RC"
grep -q 'merged #7: abc1234' <<<"$OUT" && pass "logs the merge sha" || fail "logs the merge sha" "$OUT"
assert_eq "exactly one PUT" "1" "$(puts)"

for code in 405 409 422; do
	section "GitHub's gate: HTTP $code -> logged as not merged, exit 0"
	run_step false 1 "gh: refused for this test (HTTP $code)"
	assert_eq "HTTP $code exits 0" "0" "$RC"
	grep -q "not merged #7 — GitHub's gate" <<<"$OUT" && pass "HTTP $code is logged as the gate" || fail "HTTP $code logged as the gate" "$OUT"
	grep -q '::error::' <<<"$OUT" && fail "HTTP $code carries no error annotation" "$OUT" || pass "HTTP $code carries no error annotation"
done

for err in "gh: Resource not accessible by integration (HTTP 403)" "gh: Not Found (HTTP 404)" "connect: network is unreachable"; do
	section "genuine error: '$err' -> ::error::, exit 1"
	run_step false 1 "$err"
	assert_eq "exit 1" "1" "$RC"
	grep -q '::error::merge call failed for #7 (not a gate refusal)' <<<"$OUT" && pass "annotated as a real failure" || fail "annotated as a real failure" "$OUT"
	grep -q "GitHub's gate" <<<"$OUT" && fail "never mislabelled as the gate" "$OUT" || pass "never mislabelled as the gate"
done

section "fork PR: refused by estate policy before any merge call, exit 0"
run_step true 0 '{"sha":"never"}'
assert_eq "exit 0" "0" "$RC"
grep -q 'refused #7: cross-repository (fork)' <<<"$OUT" && pass "refusal is logged" || fail "refusal is logged" "$OUT"
assert_eq "no PUT issued" "0" "$(puts)"

section "unreadable PR: treated as a fork (fails closed), no merge call"
run_step FAIL 0 '{"sha":"never"}'
assert_eq "exit 0" "0" "$RC"
grep -q 'refused #7: cross-repository (fork)' <<<"$OUT" && pass "unreadable PR refused" || fail "unreadable PR refused" "$OUT"
assert_eq "no PUT issued" "0" "$(puts)"

finish
