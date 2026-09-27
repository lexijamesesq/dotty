#!/usr/bin/env bash
# The dead-man backstop's live sweep against a fake `gh`: one assignment POST
# fails with the 403 the real App token returned, the others succeed. The
# sweep must still reach every PR after the failure, log the API's own
# response, count the failure, and exit 1 once the whole sweep is done — a
# backstop that cannot assign must not end green. Also runs the committed
# demo fixture (fixture mode never writes, so it exits 0).
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=lib/assert.sh
source "$SCRIPT_DIR/lib/assert.sh"
DEADMAN="$REPO/.github/scripts/margot-deadman.py"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin"

# Two repos: o/a has two stale PRs (#14's POST fails), o/b has one stale PR
# and one fresh one. No PR has a margot check-run.
cat >"$TMP/bin/gh" <<'EOF'
#!/usr/bin/env python3
import json, sys
path = next(a for a in sys.argv[1:] if a.startswith("repos/"))
old, new = "2026-01-01T00:00:00Z", "2099-01-01T00:00:00Z"
prs = {
    "o/a": [{"number": 14, "created_at": old, "assignees": [], "head": {"sha": "a1"}},
            {"number": 15, "created_at": old, "assignees": [], "head": {"sha": "a2"}}],
    "o/b": [{"number": 1, "created_at": old, "assignees": [], "head": {"sha": "b1"}},
            {"number": 2, "created_at": new, "assignees": [], "head": {"sha": "b2"}}],
}
if path.endswith("/pulls"):
    print(json.dumps(prs[path[len("repos/"):-len("/pulls")]]))
elif "/check-runs" in path:
    print(json.dumps({"check_runs": []}))
elif path == "repos/o/a/issues/14/assignees":
    sys.stderr.write("gh: Resource not accessible by integration (HTTP 403)\n")
    print('{"message":"Resource not accessible by integration","status":"403"}')
    sys.exit(1)
elif path.endswith("/assignees"):
    print("{}")
else:
    sys.exit(9)
EOF
chmod +x "$TMP/bin/gh"

section "live sweep: one failed POST never ends the sweep, and the run ends red"
OUT="$(PATH="$TMP/bin:$PATH" python3 "$DEADMAN" --repos o/a,o/b 2>&1)"
RC=$?
assert_eq "exit 1 when an assignment failed" "1" "$RC"
for line in "ASSIGN       o/a#14" "ASSIGN       o/a#15" "ASSIGN       o/b#1" "skip         o/b#2"; do
	[[ "$OUT" == *"$line"* ]] && pass "decision line: $line" || fail "decision line: $line"
done
[[ "$OUT" == *"::error::o/a#14: could not assign lexijamesesq (gh exit 1): gh: Resource not accessible by integration (HTTP 403)"* ]] &&
	pass "::error:: names the PR and carries the API's response" ||
	fail "::error:: names the PR and carries the API's response"
[[ "$OUT" == *"[live] 2 PR(s) were assigned"* ]] && pass "summary counts 2 assigned" || fail "summary counts 2 assigned"
[[ "$OUT" == *"[live] 1 PR(s) could not be assigned"* ]] && pass "summary counts 1 failed" || fail "summary counts 1 failed"
ERR_LINE="$(printf '%s\n' "$OUT" | grep -n '::error::o/a#14' | cut -d: -f1)"
NEXT_LINE="$(printf '%s\n' "$OUT" | grep -n 'ASSIGN       o/a#15' | cut -d: -f1)"
[[ -n "$ERR_LINE" && -n "$NEXT_LINE" && "$ERR_LINE" -lt "$NEXT_LINE" ]] &&
	pass "the failure is logged before the sweep moves on" ||
	fail "the failure is logged before the sweep moves on"

section "live sweep with every POST succeeding exits 0"
OUT="$(PATH="$TMP/bin:$PATH" python3 "$DEADMAN" --repos o/b 2>&1)"
assert_eq "exit 0 when nothing failed" "0" "$?"

section "demo fixture (never writes) exits 0"
section "the verdict is review / margot (check-name rename, 2026-09-27)"
verdict() { python3 -c "import importlib.util,json,sys; sp=importlib.util.spec_from_file_location('d','$DEADMAN'); m=importlib.util.module_from_spec(sp); sp.loader.exec_module(m); print(m.has_margot_verdict(json.loads(sys.argv[1])))" "$1"; }
assert_eq "new name completed -> verdict" "True" "$(verdict '[{"name":"review / margot","status":"completed","started_at":"2026-09-27T01:00:00Z"}]')"
assert_eq "new name still running -> no verdict" "False" "$(verdict '[{"name":"review / margot","status":"in_progress","started_at":"2026-09-27T01:00:00Z"}]')"
assert_eq "an unrelated check -> no verdict" "False" "$(verdict '[{"name":"ci / checks","status":"completed","started_at":"2026-09-27T01:00:00Z"}]')"

python3 "$DEADMAN" --fixture-file "$REPO/.github/scripts/margot-deadman.demo-fixture.json" >/dev/null 2>&1
assert_eq "fixture mode exit 0" "0" "$?"

finish
