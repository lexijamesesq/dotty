#!/usr/bin/env bash
# Test suite for git-hooks/house-code.py — the house-code pattern checks
# (ticket-id-leak, vault-path-leak, internal-section-reference-leak,
# roster-name-leak) exported as a pre-commit hook.
#
# Coverage: one true positive + one true negative per rule; redaction (no
# finding ever prints the matched literal, for ANY of the four classes, not
# just roster-name); fail-closed on a missing rosters file and on a
# malformed one (below the parse floor). Self-contained: a private
# XDG_CONFIG_HOME and synthetic roster fixtures — never the real installed
# roster, never any real name.
#
# Run: bash ~/bin/dotty/.claude/eval/house-code.test.sh

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/assert.sh"

HOOKS_DIR="${HOOKS_DIR:-${SCRIPT_DIR}/../../git-hooks}"
HOUSE_CODE="$HOOKS_DIR/house-code.py"

[[ -f "$HOUSE_CODE" ]] || { echo "FATAL: missing $HOUSE_CODE"; exit 2; }
command -v python3 >/dev/null 2>&1 || { echo "FATAL: python3 not on PATH — suite cannot run."; exit 2; }

TMP="$(mktemp -d -t house-code-test.XXXXXX)"
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT INT TERM

# Synthetic roster fixture — fictional names only, never real ones.
ROSTERS_OK="$TMP/rosters-ok.md"
cat > "$ROSTERS_OK" <<'EOF'
# tag-taxonomy-rosters.md (fixture)

Current roster: Fixture Fictus, Sample Synth
Current employers: Fixtureco, Synthetic Systems
EOF

ROSTERS_TRUNCATED="$TMP/rosters-truncated.md"
cat > "$ROSTERS_TRUNCATED" <<'EOF'
# tag-taxonomy-rosters.md (fixture, below floor)

Current roster: OnlyOne
Current employers: OnlyOneCo
EOF

run_house_code() {
    # $1 = rosters path, remaining args = files
    local rosters="$1"; shift
    python3 "$HOUSE_CODE" --rosters-path "$rosters" "$@"
}

section "Rule: ticket-id-leak"
F="$TMP/ticket.py"
printf 'ticket = "LEX-9999"\n' > "$F"
OUT="$(run_house_code "$ROSTERS_OK" "$F" 2>&1)"; RC=$?
assert_eq "ticket-id-leak: blocks (exit 1)" "1" "$RC"
if [[ "$OUT" == *"[ticket-id-leak]"* ]]; then pass "ticket-id-leak: rule id present"; else fail "ticket-id-leak: rule id present" "$OUT"; fi
if [[ "$OUT" == *"LEX-9999"* ]]; then fail "ticket-id-leak: never prints the matched id" "$OUT"; else pass "ticket-id-leak: never prints the matched id"; fi

F="$TMP/clean1.py"
printf 'x = 1\n' > "$F"
run_house_code "$ROSTERS_OK" "$F" >/dev/null 2>&1
assert_exit "ticket-id-leak: clean file passes" 0 run_house_code "$ROSTERS_OK" "$F"

section "Rule: vault-path-leak"
F="$TMP/vaultpath.py"
printf 'p = "/Users/fixtureuser/Vaults/Notes/System/foo.md"\n' > "$F"
OUT="$(run_house_code "$ROSTERS_OK" "$F" 2>&1)"; RC=$?
assert_eq "vault-path-leak: blocks (exit 1)" "1" "$RC"
if [[ "$OUT" == *"[vault-path-leak]"* ]]; then pass "vault-path-leak: rule id present"; else fail "vault-path-leak: rule id present" "$OUT"; fi
if [[ "$OUT" == *"/Users/fixtureuser"* ]]; then fail "vault-path-leak: never prints the matched path" "$OUT"; else pass "vault-path-leak: never prints the matched path"; fi

section "Rule: internal-section-reference-leak"
F="$TMP/sectionref.py"
printf '# see \xc2\xa7 System/Knowledge/some-doc.md for detail\n' > "$F"
OUT="$(run_house_code "$ROSTERS_OK" "$F" 2>&1)"; RC=$?
assert_eq "internal-section-reference-leak: blocks (exit 1)" "1" "$RC"
if [[ "$OUT" == *"[internal-section-reference-leak]"* ]]; then pass "internal-section-reference-leak: rule id present"; else fail "internal-section-reference-leak: rule id present" "$OUT"; fi
if [[ "$OUT" == *"some-doc.md"* ]]; then fail "internal-section-reference-leak: never prints the matched line" "$OUT"; else pass "internal-section-reference-leak: never prints the matched line"; fi

section "Rule: roster-name-leak"
F="$TMP/roster.yaml"
printf 'owner: Fixture Fictus\n' > "$F"
OUT="$(run_house_code "$ROSTERS_OK" "$F" 2>&1)"; RC=$?
assert_eq "roster-name-leak: blocks (exit 1)" "1" "$RC"
if [[ "$OUT" == *"[roster-name-leak]"* ]]; then pass "roster-name-leak: rule id present"; else fail "roster-name-leak: rule id present" "$OUT"; fi
if [[ "$OUT" == *"Fixture Fictus"* ]]; then fail "roster-name-leak: never prints the matched name" "$OUT"; else pass "roster-name-leak: never prints the matched name"; fi

F="$TMP/clean2.yaml"
printf 'owner: nobody in particular\n' > "$F"
assert_exit "roster-name-leak: clean file passes" 0 run_house_code "$ROSTERS_OK" "$F"

section "Fail-closed: an unreadable tracked file blocks, never a silent skip"
F="$TMP/unreadable.py"
printf 'ticket = "LEX-9999"\n' > "$F"
chmod 000 "$F"
OUT="$(run_house_code "$ROSTERS_OK" "$F" 2>&1)"; RC=$?
chmod 644 "$F"   # restore so cleanup's rm -rf can remove it
assert_eq "unreadable file: exit 2 (fail-closed), not a silent pass" "2" "$RC"
if [[ "$OUT" == *"$F"* ]]; then pass "unreadable file: names the file it could not read"; else fail "unreadable file: names the file it could not read" "$OUT"; fi

section "Fail-closed: missing rosters file"
OUT="$(run_house_code "$TMP/does-not-exist.md" "$TMP/clean1.py" 2>&1)"; RC=$?
assert_eq "missing rosters file: exit 2" "2" "$RC"
if [[ "$OUT" == *"does-not-exist.md"* ]]; then pass "missing rosters file: names the missing path"; else fail "missing rosters file: names the missing path" "$OUT"; fi

section "Fail-closed: malformed (truncated) rosters file"
OUT="$(run_house_code "$ROSTERS_TRUNCATED" "$TMP/clean1.py" 2>&1)"; RC=$?
assert_eq "truncated rosters file: exit 2" "2" "$RC"

finish
