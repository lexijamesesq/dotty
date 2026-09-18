#!/usr/bin/env bash
# Test suite for .github/scripts/bump-consumers.sh — the consumer half of
# release-on-merge. Every assertion runs the REAL functions from that script
# against real files on disk; only the single api() seam is replaced, by a stub
# that serves fixture repositories out of a directory and records the write calls
# it was asked to make.
#
# Proves NON-VACUOUS as well as happy-path. The three skip reasons (no config,
# no dotty pin, already current) and the readiness gate each get a case that
# asserts NOTHING was written, because the failure this gate exists to prevent —
# opening thirteen unmergeable paid-review pull requests on the first run — looks
# exactly like success from a test that only checks the happy path.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/assert.sh"

SCRIPT="${SCRIPT:-${SCRIPT_DIR}/../../.github/scripts/bump-consumers.sh}"
[[ -f "$SCRIPT" ]] || { echo "FATAL: missing $SCRIPT"; exit 2; }

TMP="$(mktemp -d -t bump-consumers-test.XXXXXX)"
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT INT TERM

TAG="v2026.09.19"

# ---------------------------------------------------------------------------
# The stub. Serves repos/<owner>/<repo>/contents/<path> from $FIXTURES/<repo>/,
# and appends every write (PUT/POST/PATCH) to $CALLS. Reads that miss return 1,
# exactly as gh api does for a 404, which is what the script's read_file relies
# on to tell "no such file" from "empty file".
# ---------------------------------------------------------------------------
STUB="$TMP/stub.sh"
cat > "$STUB" <<'STUBEOF'
api() {
  local method="GET" path="" arg
  local -a rest=()
  while (( $# )); do
    case "$1" in
      -X) method="$2"; shift 2 ;;
      -q) rest+=("JQ:$2"); shift 2 ;;
      -f|-F) rest+=("F:$2"); shift 2 ;;
      *) path="$1"; shift ;;
    esac
  done

  if [[ "$method" != "GET" ]]; then
    # FAIL_ON lets a case make one write method fail, which is the only way to
    # exercise the error path — the happy-path stub can never fail.
    if [[ -n "${FAIL_ON:-}" && "$method" == "${FAIL_ON}" ]]; then
      printf 'FAILED %s %s\n' "$method" "$path" >> "$CALLS"
      return 1
    fi
    printf '%s %s\n' "$method" "$path" >> "$CALLS"
    for arg in "${rest[@]}"; do
      case "$arg" in
        F:content=*) printf '  content=%s\n' "${arg#F:content=}" >> "$CALLS" ;;
        F:*) printf '  %s\n' "${arg#F:}" >> "$CALLS" ;;
      esac
    done
    # html_url, for the create-PR call whose output the script captures.
    echo "https://example.invalid/pr/1"
    return 0
  fi

  # --- reads ---
  case "$path" in
    repos/*/contents/*)
      local repo file
      repo="${path#repos/}"; repo="${repo%%/contents/*}"
      file="${path#*/contents/}"; file="${file%%\?*}"
      if [[ "${rest[*]}" == *"JQ:.sha"* ]]; then
        echo "blobsha-${repo//\//-}"; return 0
      fi
      [[ -f "$FIXTURES/$repo/$file" ]] || return 1
      base64 < "$FIXTURES/$repo/$file" | tr -d '\n'
      return 0 ;;
    repos/*/git/ref/heads/*)
      case "$path" in
        */dotty-bump) [[ -n "${BRANCH_EXISTS:-}" ]] || return 1; echo "existingsha" ;;
        *) echo "basesha" ;;
      esac
      return 0 ;;
    repos/*/pulls*)
      [[ -n "${OPEN_PR:-}" ]] && { echo "https://example.invalid/pr/existing"; return 0; }
      echo ""; return 0 ;;
    repos/*)
      echo "main"; return 0 ;;
  esac
  return 1
}
STUBEOF

# ---------------------------------------------------------------------------
# Fixture builders
# ---------------------------------------------------------------------------
# shellcheck disable=SC2016  # the ${{ }} is literal GitHub Actions YAML,
# not shell — these fixtures must reach the script exactly as a real
# caller's file would.
READY_MARGOT='jobs:
  dispatch:
    uses: lexijamesesq/dotty/.github/workflows/estate-margot.yml@v1
    secrets:
      MARGOT_APP_KEY: ${{ secrets.MARGOT_APP_KEY }}
      OLLIE_APP_KEY: ${{ secrets.OLLIE_APP_KEY }}'

# shellcheck disable=SC2016  # the ${{ }} is literal GitHub Actions YAML,
# not shell — these fixtures must reach the script exactly as a real
# caller's file would.
OLD_MARGOT='jobs:
  dispatch:
    uses: lexijamesesq/dotty/.github/workflows/estate-margot.yml@v2026.09.18
    secrets:
      MARGOT_APP_KEY: ${{ secrets.MARGOT_APP_KEY }}'

# A caller on @v1 that never got the key line — the half-converged case.
# shellcheck disable=SC2016  # the ${{ }} is literal GitHub Actions YAML,
# not shell — these fixtures must reach the script exactly as a real
# caller's file would.
NOKEY_MARGOT='jobs:
  dispatch:
    uses: lexijamesesq/dotty/.github/workflows/estate-margot.yml@v1
    secrets:
      MARGOT_APP_KEY: ${{ secrets.MARGOT_APP_KEY }}'

config_pinned() {
  printf 'repos:\n  - repo: https://github.com/lexijamesesq/dotty\n    rev: %s\n    hooks:\n      - id: gitleaks-staged\n' "$1"
}

# <name> <rev|-> <margot-yaml|->
make_consumer() {
    local name="$1" rev="$2" margot="$3"
    mkdir -p "$FIXTURES/lexijamesesq/$name/.github/workflows"
    [[ "$rev" == "-" ]] || config_pinned "$rev" > "$FIXTURES/lexijamesesq/$name/.pre-commit-config.yaml"
    [[ "$margot" == "-" ]] || printf '%s\n' "$margot" > "$FIXTURES/lexijamesesq/$name/.github/workflows/margot.yml"
}

# <names...> -> a rulesets JSON declaring them plus dotty itself
make_rulesets() {
    local dir="$1"; shift
    mkdir -p "$dir/rulesets"
    {
        printf '{"repos":{"lexijamesesq/dotty":{}'
        for n in "$@"; do printf ',"lexijamesesq/%s":{}' "$n"; done
        printf '}}'
    } > "$dir/rulesets/default-branch.json"
}

# Runs the real script end to end with the stub in place.
# Sets: RC, OUT (stderr+stdout), CALLS file contents in $CALLS.
run_bump() {
    CALLS="$TMP/calls.$RANDOM"; export CALLS; : > "$CALLS"
    OUT="$(BUMP_CONSUMERS_LIB="$STUB" FIXTURES="$FIXTURES" CALLS="$CALLS" \
           BRANCH_EXISTS="${BRANCH_EXISTS:-}" OPEN_PR="${OPEN_PR:-}" FAIL_ON="${FAIL_ON:-}" \
           bash "$SCRIPT" "$TAG" "$DOTTY" 2>&1)"
    RC=$?
}

new_case() {
    CASE_N=$((${CASE_N:-0} + 1))
    FIXTURES="$TMP/fx$CASE_N"; DOTTY="$TMP/dotty$CASE_N"
    mkdir -p "$FIXTURES" "$DOTTY"
    unset BRANCH_EXISTS OPEN_PR FAIL_ON
}

# ---------------------------------------------------------------------------
section "Pure: pin_rev reads the right block"
# ---------------------------------------------------------------------------
# shellcheck disable=SC1090
source "$SCRIPT" "$TAG" "/nonexistent"
# The script under test opens with `set -euo pipefail`, and sourcing it applies
# that to THIS shell. Left alone, the first case that deliberately makes the
# script exit non-zero would kill the suite at the assignment capturing its
# output, before the assertion about that failure ever ran — a test for the
# error path that cannot report on the error path. Restore the header's own
# `set -uo pipefail`.
set +e

f="$TMP/c1.yaml"
config_pinned "v2026.09.07-9" > "$f"
assert_eq "pin_rev reads a simple pin" "v2026.09.07-9" "$(pin_rev "$f")"

# The failure a bare `grep rev:` would cause: another project's pin rewritten to
# this repository's tag.
cat > "$f" <<'EOF'
repos:
  - repo: https://github.com/pre-commit/pre-commit-hooks
    rev: v4.5.0
    hooks:
      - id: end-of-file-fixer
  - repo: https://github.com/lexijamesesq/dotty
    rev: v2026.09.07-9
    hooks:
      - id: gitleaks-staged
EOF
assert_eq "pin_rev skips a foreign repo's rev" "v2026.09.07-9" "$(pin_rev "$f")"

rewrite_rev "$f" "$TAG"
assert_eq "rewrite_rev moves only the dotty pin" "$TAG" "$(pin_rev "$f")"
assert_eq "rewrite_rev leaves the foreign pin alone" "v4.5.0" \
    "$(awk '/pre-commit-hooks/{getline; print $2}' "$f")"

cat > "$f" <<'EOF'
repos:
  - repo: https://github.com/lexijamesesq/dotty
    rev: v2026.09.07-9  # bumped by the release job
    hooks:
      - id: gitleaks-staged
EOF
rewrite_rev "$f" "$TAG"
assert_eq "rewrite_rev preserves a trailing comment" \
    "    rev: ${TAG}  # bumped by the release job" "$(grep 'rev:' "$f")"

config_pinned "v1" > "$f"
assert_eq "pin_rev reads a (broken) floating pin too" "v1" "$(pin_rev "$f")"

printf 'repos:\n  - repo: https://github.com/someone/else\n    rev: v1\n' > "$f"
assert_eq "pin_rev is empty when dotty is not pinned" "" "$(pin_rev "$f")"

# ---------------------------------------------------------------------------
section "Pure: pipe_ready needs BOTH halves"
# ---------------------------------------------------------------------------
m="$TMP/m.yml"
printf '%s\n' "$READY_MARGOT" > "$m"
if pipe_ready "$m"; then pass "pipe_ready accepts @v1 + OLLIE_APP_KEY"
else fail "pipe_ready accepts @v1 + OLLIE_APP_KEY"; fi

printf '%s\n' "$OLD_MARGOT" > "$m"
if pipe_ready "$m"; then fail "pipe_ready rejects an old pin" "accepted @v2026.09.18"
else pass "pipe_ready rejects a caller still pinned at a calendar tag"; fi

printf '%s\n' "$NOKEY_MARGOT" > "$m"
if pipe_ready "$m"; then fail "pipe_ready rejects a missing key" "accepted a caller with no OLLIE_APP_KEY"
else pass "pipe_ready rejects @v1 with no OLLIE_APP_KEY pass-through"; fi

# A trailing comment on the uses: line must NOT take a repo off the pipe.
printf '%s\n' "${READY_MARGOT/@v1/@v1  # floating major tag}" > "$m"
if pipe_ready "$m"; then pass "pipe_ready tolerates a trailing comment on the uses: line"
else fail "pipe_ready tolerates a trailing comment on the uses: line"; fi

# But the ref itself must be exactly v1.
printf '%s\n' "${READY_MARGOT/@v1/@v10}" > "$m"
if pipe_ready "$m"; then fail "pipe_ready requires the whole ref" "accepted @v10"
else pass "pipe_ready does not match @v10 as if it were @v1"; fi

# ---------------------------------------------------------------------------
section "Pure: consumer_list excludes dotty itself"
# ---------------------------------------------------------------------------
new_case
make_rulesets "$DOTTY" alpha beta
got="$(consumer_list "$DOTTY/rulesets/default-branch.json" | sort | tr '\n' ' ')"
assert_eq "consumer_list drops lexijamesesq/dotty" \
    "lexijamesesq/alpha lexijamesesq/beta " "$got"

# ---------------------------------------------------------------------------
section "Which consumers are due"
# ---------------------------------------------------------------------------
new_case
make_rulesets "$DOTTY" ready stale nokey nopin noconfig current
make_consumer ready    "v2026.09.07-9" "$READY_MARGOT"
make_consumer stale    "v2026.09.07-9" "$OLD_MARGOT"
make_consumer nokey    "v2026.09.07-9" "$NOKEY_MARGOT"
make_consumer nopin    "-"             "$READY_MARGOT"
make_consumer noconfig "-"             "-"
make_consumer current  "$TAG"          "$READY_MARGOT"
# nopin needs a config that pins something else entirely
printf 'repos:\n  - repo: https://github.com/someone/else\n    rev: v9\n' \
    > "$FIXTURES/lexijamesesq/nopin/.pre-commit-config.yaml"

run_bump
assert_eq "the run succeeds" "0" "$RC"
assert_eq "exactly one consumer is bumped" "1" "$(grep -c '^POST repos/.*/pulls$' "$CALLS")"
if grep -q 'repos/lexijamesesq/ready/pulls' "$CALLS"; then
    pass "the ready consumer gets the PR"
else fail "the ready consumer gets the PR" "$(cat "$CALLS")"; fi

# The gate's whole purpose, asserted as an absence.
for r in stale nokey nopin noconfig current; do
    if grep -q "repos/lexijamesesq/$r/" "$CALLS"; then
        fail "no write reaches '$r'" "$(grep "$r" "$CALLS")"
    else pass "no write reaches '$r'"; fi
done

for pat in "not on the bot pipe yet" "already at ${TAG}" "no .pre-commit-config.yaml" "does not pin"; do
    if grep -qF "$pat" <<< "$OUT"; then pass "logs the reason: '$pat'"
    else fail "logs the reason: '$pat'" "$OUT"; fi
done

# ---------------------------------------------------------------------------
section "What gets written for a due consumer"
# ---------------------------------------------------------------------------
if grep -q '^POST repos/lexijamesesq/ready/git/refs$' "$CALLS"; then
    pass "creates the bump branch when absent"
else fail "creates the bump branch when absent" "$(cat "$CALLS")"; fi

written="$(grep '^  content=' "$CALLS" | head -1 | sed 's/^  content=//' | base64 --decode)"
assert_eq "the committed config carries the cut tag" "$TAG" \
    "$(printf '%s' "$written" > "$TMP/w.yaml"; pin_rev "$TMP/w.yaml")"

if grep -qF "head=${BUMP_BRANCH:-dotty-bump}" "$CALLS"; then
    pass "the PR is opened from the fixed bump branch"
else fail "the PR is opened from the fixed bump branch" "$(cat "$CALLS")"; fi

# No secret, no key material, ever, in a body this job writes.
if grep -Eqi 'APP_KEY|BEGIN [A-Z ]*PRIVATE KEY|ghs_|github_pat_' "$CALLS"; then
    fail "the PR body carries no key material" "$(cat "$CALLS")"
else pass "the PR body carries no key material"; fi

# ---------------------------------------------------------------------------
section "Idempotency: one branch, one PR, never a stack"
# ---------------------------------------------------------------------------
new_case
make_rulesets "$DOTTY" ready
make_consumer ready "v2026.09.07-9" "$READY_MARGOT"
BRANCH_EXISTS=1
run_bump
assert_eq "a second release succeeds" "0" "$RC"
if grep -q '^PATCH repos/lexijamesesq/ready/git/refs/heads/dotty-bump$' "$CALLS"; then
    pass "an existing bump branch is force-reset onto the base tip"
else fail "an existing bump branch is force-reset onto the base tip" "$(cat "$CALLS")"; fi
if grep -q '^POST repos/lexijamesesq/ready/git/refs$' "$CALLS"; then
    fail "an existing branch is not re-created" "$(cat "$CALLS")"
else pass "an existing branch is not re-created"; fi

new_case
make_rulesets "$DOTTY" ready
make_consumer ready "v2026.09.07-9" "$READY_MARGOT"
BRANCH_EXISTS=1; OPEN_PR=1
run_bump
assert_eq "a release with a PR already open succeeds" "0" "$RC"
if grep -q '^POST repos/.*/pulls$' "$CALLS"; then
    fail "an open bump PR is updated, never stacked" "$(cat "$CALLS")"
else pass "an open bump PR is updated, never stacked"; fi
if grep -q '^PUT repos/lexijamesesq/ready/contents/' "$CALLS"; then
    pass "the open PR's branch still receives the new pin"
else fail "the open PR's branch still receives the new pin" "$(cat "$CALLS")"; fi

# ---------------------------------------------------------------------------
section "A failing write FAILS — errexit is suppressed inside publish_bump"
# ---------------------------------------------------------------------------
# `set -e` does not apply inside a function invoked as an `if` condition, which
# is how main() calls publish_bump. Without an explicit `|| return 1` on every
# call, a failing write would be swallowed, the function would return 0, and the
# consumer would be counted as successfully bumped. This case is the guard on
# that: it makes the commit fail and requires the run to say so.
new_case
make_rulesets "$DOTTY" ready
make_consumer ready "v2026.09.07-9" "$READY_MARGOT"
FAIL_ON="PUT"
run_bump
assert_eq "a failed commit fails the run" "1" "$RC"
if grep -q 'failed: 1' <<< "$OUT"; then pass "the failure is counted, not swallowed"
else fail "the failure is counted, not swallowed" "$OUT"; fi
if grep -q '^POST repos/.*/pulls$' "$CALLS"; then
    fail "no PR is opened after a failed commit" "$(cat "$CALLS")"
else pass "no PR is opened after a failed commit"; fi

# ---------------------------------------------------------------------------
section "Non-vacuous: nothing enrolled, nothing written"
# ---------------------------------------------------------------------------
new_case
make_rulesets "$DOTTY"
run_bump
assert_eq "a release with no consumers succeeds" "0" "$RC"
assert_eq "and writes nothing at all" "0" "$(wc -l < "$CALLS" | tr -d ' ')"

finish
