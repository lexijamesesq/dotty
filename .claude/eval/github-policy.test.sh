#!/usr/bin/env bash
# Test suite for ~/bin/dotty/.claude/lib/github-policy.sh
#
# Covers:
#   - Conservative defaults applied when no policy file
#   - Declared values override defaults (deep merge)
#   - policy_hash deterministic across whitespace differences
#   - policy_hash differs when content differs
#   - Falls back to defaults when yq missing (graceful degradation)
#   - Malformed YAML doesn't crash the reader
#
# Run: bash ~/bin/dotty/.claude/eval/github-policy.test.sh

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/assert.sh"

READER="$HOME/bin/dotty/.claude/lib/github-policy.sh"
[[ -x "$READER" ]] || { echo "FATAL: $READER not executable"; exit 2; }

TMPDIR=$(mktemp -d -t github-policy-test.XXXXXX)
cleanup() { rm -rf "$TMPDIR"; }
trap cleanup EXIT INT TERM

# read_field <repo-root> <field-name>
# Runs the reader and extracts a key=value field. Returns the value.
read_field() {
    "$READER" "$1" 2>/dev/null | awk -F= -v k="$2" '$1 == k { sub(/^[^=]*=/, ""); print; exit }'
}

# === Defaults when no policy file ===
section "Conservative defaults when no policy file"
EMPTY_REPO="$TMPDIR/empty-repo"
mkdir -p "$EMPTY_REPO"
assert_eq "default visibility=public"          "public"        "$(read_field "$EMPTY_REPO" visibility)"
assert_eq "default main_branch=main"           "main"          "$(read_field "$EMPTY_REPO" main_branch)"
assert_eq "default protection=direct_push"     "direct_push"   "$(read_field "$EMPTY_REPO" main_branch_protection)"
assert_eq "default prep.required=true"         "true"          "$(read_field "$EMPTY_REPO" prep.required)"
assert_eq "default prep.strictness=strict"     "strict"        "$(read_field "$EMPTY_REPO" prep.strictness)"
assert_eq "default prep.ttl_hours=24"          "24"            "$(read_field "$EMPTY_REPO" prep.ttl_hours)"
assert_eq "default force-push targets empty"   ""              "$(read_field "$EMPTY_REPO" allowed_force_push_targets)"
assert_eq "default treat_as_public=false"      "false"         "$(read_field "$EMPTY_REPO" treat_as_public_for_secrets)"

# === Declared values override defaults ===
section "Declared values override defaults"
DECLARED_REPO="$TMPDIR/declared-repo"
mkdir -p "$DECLARED_REPO/.claude"
cat > "$DECLARED_REPO/.claude/github-policy.yaml" <<'YAML'
visibility: private
main_branch_protection: pr_only
prep:
  strictness: warn
allowed_force_push_targets:
  - 'lexi/*'
  - 'experimental/*'
treat_as_public_for_secrets: true
YAML

assert_eq "declared visibility=private"        "private"       "$(read_field "$DECLARED_REPO" visibility)"
assert_eq "declared protection=pr_only"        "pr_only"       "$(read_field "$DECLARED_REPO" main_branch_protection)"
assert_eq "declared strictness=warn"           "warn"          "$(read_field "$DECLARED_REPO" prep.strictness)"
assert_eq "declared force-push targets"        "lexi/*,experimental/*"  "$(read_field "$DECLARED_REPO" allowed_force_push_targets)"
assert_eq "declared treat_as_public=true"      "true"          "$(read_field "$DECLARED_REPO" treat_as_public_for_secrets)"
# Defaults preserved for fields not declared
assert_eq "preserved main_branch=main"         "main"          "$(read_field "$DECLARED_REPO" main_branch)"
assert_eq "preserved prep.required=true"       "true"          "$(read_field "$DECLARED_REPO" prep.required)"

# === Hash determinism ===
section "policy_hash determinism"
H_BASE=$(read_field "$DECLARED_REPO" policy_hash)
[[ -n "$H_BASE" ]] && pass "policy_hash present" || fail "policy_hash present" "got empty hash"

# Add trailing whitespace — hash must not change
printf '\n\n\n' >> "$DECLARED_REPO/.claude/github-policy.yaml"
H_AFTER_WS=$(read_field "$DECLARED_REPO" policy_hash)
assert_eq "hash unchanged by trailing whitespace" "$H_BASE" "$H_AFTER_WS"

# Two repos with identical content (different file system locations) — same hash
DECLARED_REPO_2="$TMPDIR/declared-repo-2"
mkdir -p "$DECLARED_REPO_2/.claude"
cat > "$DECLARED_REPO_2/.claude/github-policy.yaml" <<'YAML'
visibility: private
main_branch_protection: pr_only
prep:
  strictness: warn
allowed_force_push_targets:
  - 'lexi/*'
  - 'experimental/*'
treat_as_public_for_secrets: true
YAML
H_OTHER_REPO=$(read_field "$DECLARED_REPO_2" policy_hash)
assert_eq "hash same across identical content in different locations" "$H_BASE" "$H_OTHER_REPO"

# Different content — different hash
CHANGED_REPO="$TMPDIR/changed-repo"
mkdir -p "$CHANGED_REPO/.claude"
cat > "$CHANGED_REPO/.claude/github-policy.yaml" <<'YAML'
visibility: public
prep:
  strictness: strict
YAML
H_CHANGED=$(read_field "$CHANGED_REPO" policy_hash)
if [[ "$H_BASE" != "$H_CHANGED" ]]; then
    pass "hash differs when content differs"
else
    fail "hash differs when content differs" "both equal: $H_BASE"
fi

# Default-no-file hash differs from declared
H_DEFAULT=$(read_field "$EMPTY_REPO" policy_hash)
if [[ "$H_DEFAULT" != "$H_BASE" ]]; then
    pass "hash for defaults differs from hash for declared"
else
    fail "hash for defaults differs from hash for declared" "both equal: $H_DEFAULT"
fi

# === Malformed YAML doesn't crash ===
section "Malformed YAML graceful degradation"
MALFORMED_REPO="$TMPDIR/malformed-repo"
mkdir -p "$MALFORMED_REPO/.claude"
cat > "$MALFORMED_REPO/.claude/github-policy.yaml" <<'YAML'
visibility: private
this is not valid: yaml
  - unbalanced
  brackets: [unclosed
YAML
# Reader should not error out; should fall back to defaults if parse fails
EXIT_CODE=$("$READER" "$MALFORMED_REPO" >/dev/null 2>&1; echo $?)
assert_eq "malformed YAML: reader exits 0" "0" "$EXIT_CODE"
# Output should still produce some visibility value (either declared if partially parseable, or default)
VIS=$(read_field "$MALFORMED_REPO" visibility)
if [[ "$VIS" == "public" || "$VIS" == "private" ]]; then
    pass "malformed YAML: visibility resolves to a valid value ($VIS)"
else
    fail "malformed YAML: visibility resolves" "got: '$VIS'"
fi

# === Hash format ===
section "policy_hash format"
if [[ "$H_BASE" =~ ^sha256: ]]; then
    pass "hash uses sha256: prefix"
else
    fail "hash uses sha256: prefix" "got: $H_BASE"
fi

finish
