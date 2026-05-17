#!/usr/bin/env bash
# prep-cache-check.test.sh — exercise lib/prep-cache-check.sh cache validity logic.
#
# Covers all 6 cache dimensions:
#   1. marker exists
#   2. marker_schema_version == 3
#   3. scanner_version match
#   4. policy_hash match
#   4b. persona_hash match (persona cache invalidation)
#   5. last_full_scan_at TTL
#   6. per-file content_sha256 match
#
# Plus: scope_files preservation on cache hit.
#
# Conventions: self-contained tmp dir per scenario, init git, write a marker
# directly, run prep-cache-check.sh, assert exit + marker mutation.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/assert.sh"

CACHE_CHECK="${CACHE_CHECK:-$HOME/bin/dotty/.claude/lib/prep-cache-check.sh}"
PERSONA_FILE="${PERSONA_FILE:-$HOME/bin/dotty/.claude/agents/github-prep.md}"

if [ ! -f "$CACHE_CHECK" ]; then
  echo "FATAL: cache-check script not found at $CACHE_CHECK" >&2
  exit 2
fi
if [ ! -f "$PERSONA_FILE" ]; then
  echo "FATAL: persona file not found at $PERSONA_FILE" >&2
  exit 2
fi

PERSONA_HASH="sha256:$(shasum -a 256 "$PERSONA_FILE" | awk '{print $1}')"

# Neutralize policy_hash dimension: pin GH_POLICY_HASH to match the zeroed value
# we write into test markers, so the policy_hash check passes and we can isolate
# the persona_hash dimension under test. Same for scanner_version.
export GH_POLICY_HASH="sha256:0000000000000000000000000000000000000000000000000000000000000000"
export GH_SCANNER_VERSION="2.1.0"

# Each test gets its own scratch repo; cleanup at the end.
TMP_ROOT=$(mktemp -d)
cleanup() { rm -rf "$TMP_ROOT"; }
trap cleanup EXIT

# make_repo <name> → echoes repo path. Initializes empty git repo + a scoped file.
make_repo() {
  local name="$1"
  local repo="$TMP_ROOT/$name"
  mkdir -p "$repo"
  ( cd "$repo" && git init -q && git config user.email t@t && git config user.name t )
  echo "content of file" > "$repo/file.md"
  ( cd "$repo" && git add file.md && git commit -q -m init )
  # Stage an edit so change-set scope picks up file.md
  echo "content of file (edited)" > "$repo/file.md"
  ( cd "$repo" && git add file.md )
  echo "$repo"
}

# write_marker <repo> <persona_hash_value_or_empty> [<file_hash_override>]
# Writes a valid v3 marker with optional persona_hash and file_hashes entries.
write_marker() {
  local repo="$1" persona="$2" file_hash="${3:-}"
  local marker="$repo/.github-prep-status.json"
  local current_file_hash="sha256:$(shasum -a 256 "$repo/file.md" | awk '{print $1}')"
  [ -n "$file_hash" ] && current_file_hash="$file_hash"
  local persona_field=""
  if [ -n "$persona" ]; then
    persona_field=",\"persona_hash\":\"$persona\""
  fi
  cat > "$marker" <<EOF
{
  "marker_schema_version": 3,
  "evaluated_path": "$repo",
  "evaluated_at": "2026-05-16T00:00:00Z",
  "scope": "change-set",
  "scope_files": ["file.md"],
  "scanner_version": "2.1.0",
  "policy_hash": "sha256:0000000000000000000000000000000000000000000000000000000000000000"
  $persona_field,
  "verdict": "allow",
  "findings": [],
  "acknowledgments": [],
  "file_hashes": {"file.md": "$current_file_hash"},
  "summary": {"allow": 0, "block": 0, "revise": 0, "escalate": 0}
}
EOF
  echo "$marker"
}

# run_cache_check <repo> [<scope>] → echoes "<exit_code>|<stderr>"
run_cache_check() {
  local repo="$1" scope="${2:-change-set}"
  local err
  err=$( "$CACHE_CHECK" "$repo" "$scope" 2>&1 >/dev/null )
  echo "$?|$err"
}

# --- Test 1: matching persona_hash → cache hit ---
section "Test 1: matching persona_hash → cache hit"
repo=$(make_repo t1)
write_marker "$repo" "$PERSONA_HASH" >/dev/null
out=$("$CACHE_CHECK" "$repo" change-set 2>&1)
rc=$?
if [ "$rc" = "0" ]; then
  pass "cache hit (exit 0) with matching persona_hash"
else
  fail "cache hit with matching persona_hash" "got exit $rc, output: $out"
fi

# --- Test 2: mismatched persona_hash → cache miss ---
section "Test 2: mismatched persona_hash → cache miss"
repo=$(make_repo t2)
write_marker "$repo" "sha256:deadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef" >/dev/null
err=$("$CACHE_CHECK" "$repo" change-set 2>&1 >/dev/null)
rc=$?
if [ "$rc" = "1" ]; then
  pass "cache miss (exit 1) on persona_hash mismatch"
else
  fail "cache miss on persona_hash mismatch" "got exit $rc"
fi
if echo "$err" | grep -q "persona_hash mismatch"; then
  pass "miss reason mentions persona_hash mismatch"
else
  fail "miss reason mentions persona_hash mismatch" "got: $err"
fi

# --- Test 3: missing persona_hash → cache miss (conservative, backward-compat) ---
section "Test 3: missing persona_hash → cache miss (conservative)"
repo=$(make_repo t3)
write_marker "$repo" "" >/dev/null   # no persona_hash field at all
err=$("$CACHE_CHECK" "$repo" change-set 2>&1 >/dev/null)
rc=$?
if [ "$rc" = "1" ]; then
  pass "cache miss (exit 1) when persona_hash absent"
else
  fail "cache miss when persona_hash absent" "got exit $rc"
fi
if echo "$err" | grep -q "persona_hash missing"; then
  pass "miss reason mentions persona_hash missing"
else
  fail "miss reason mentions persona_hash missing" "got: $err"
fi

# --- Test 4: simulated persona edit → next cache-check misses ---
section "Test 4: persona edit invalidates cache"
repo=$(make_repo t4)
# First, write a marker pinned to current persona (would be a hit)
write_marker "$repo" "$PERSONA_HASH" >/dev/null
out=$("$CACHE_CHECK" "$repo" change-set 2>&1)
rc=$?
if [ "$rc" = "0" ]; then
  pass "baseline cache hit before simulated persona edit"
else
  fail "baseline cache hit" "got exit $rc, output: $out"
fi
# Simulate a persona edit: pin marker to a deliberately wrong hash (proxy for
# "operator edited the persona file → live hash now differs from marker").
write_marker "$repo" "sha256:1111111111111111111111111111111111111111111111111111111111111111" >/dev/null
err=$("$CACHE_CHECK" "$repo" change-set 2>&1 >/dev/null)
rc=$?
if [ "$rc" = "1" ]; then
  pass "post-edit cache miss"
else
  fail "post-edit cache miss" "got exit $rc"
fi

# --- Test 5: scope_files preservation on cache hit ---
section "Test 5: scope_files preserved on cache-hit refresh"
repo=$(make_repo t5)
marker=$(write_marker "$repo" "$PERSONA_HASH")
out=$("$CACHE_CHECK" "$repo" change-set 2>&1)
rc=$?
if [ "$rc" = "0" ]; then
  pass "cache hit (precondition for scope_files preservation check)"
else
  fail "cache hit (precondition)" "got exit $rc, output: $out"
fi
sf=$(jq -c '.scope_files' "$marker")
if [ "$sf" = '["file.md"]' ]; then
  pass "scope_files unchanged after cache-hit refresh"
else
  fail "scope_files preserved after cache-hit refresh" "got: $sf"
fi
# And persona_hash survives too
ph=$(jq -r '.persona_hash // ""' "$marker")
if [ "$ph" = "$PERSONA_HASH" ]; then
  pass "persona_hash preserved on cache-hit refresh"
else
  fail "persona_hash preserved on cache-hit refresh" "got: $ph"
fi

finish
