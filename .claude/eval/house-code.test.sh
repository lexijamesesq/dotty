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

run_house_code_declared() {
    # $1 = rosters path, $2 = declaration path, remaining args = files/flags
    local rosters="$1" decl="$2"; shift 2
    python3 "$HOUSE_CODE" --rosters-path "$rosters" --declaration-path "$decl" "$@"
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

section "HC_NO_OVERLAY: roster-name-leak skipped, base only by design -- the other three rules unaffected"
F="$TMP/roster-no-overlay.yaml"
printf 'owner: Fixture Fictus\n' > "$F"
OUT="$(HC_NO_OVERLAY=1 run_house_code "$TMP/does-not-exist.md" "$F" 2>&1)"; RC=$?
assert_eq "HC_NO_OVERLAY: roster name no longer blocks (exit 0)" "0" "$RC"
if [[ "$OUT" == *"base only by design"* ]]; then pass "HC_NO_OVERLAY: logs the skip"; else fail "HC_NO_OVERLAY: logs the skip" "$OUT"; fi
if [[ "$OUT" == *"does-not-exist.md"* ]]; then fail "HC_NO_OVERLAY: never attempts the rosters path at all" "$OUT"; else pass "HC_NO_OVERLAY: never attempts the rosters path at all"; fi
FT="$TMP/ticket-no-overlay.py"
printf 'ticket = "LEX-9999"\n' > "$FT"
OUT="$(HC_NO_OVERLAY=1 run_house_code "$TMP/does-not-exist.md" "$FT" 2>&1)"; RC=$?
assert_eq "HC_NO_OVERLAY: the other three rules (ticket-id-leak here) still fire" "1" "$RC"
if [[ "$OUT" == *"[ticket-id-leak]"* ]]; then pass "HC_NO_OVERLAY: ticket-id-leak rule id present"; else fail "HC_NO_OVERLAY: ticket-id-leak rule id present" "$OUT"; fi
unset HC_NO_OVERLAY
OUT="$(run_house_code "$TMP/does-not-exist.md" "$F" 2>&1)"; RC=$?
assert_eq "control: HC_NO_OVERLAY unset behaves as before (missing rosters file blocks)" "2" "$RC"

section "Fail-closed: an unreadable tracked file blocks, never a silent skip"
F="$TMP/unreadable.py"
printf 'ticket = "LEX-9999"\n' > "$F"
chmod 000 "$F"
OUT="$(run_house_code "$ROSTERS_OK" "$F" 2>&1)"; RC=$?
chmod 644 "$F"   # restore so cleanup's rm -rf can remove it
assert_eq "unreadable file: exit 2 (fail-closed), not a silent pass" "2" "$RC"
if [[ "$OUT" == *"$F"* ]]; then pass "unreadable file: names the file it could not read"; else fail "unreadable file: names the file it could not read" "$OUT"; fi

section "Applicability: no blanket test/fixture class exemption (withdrawn on purpose)"
mkdir -p "$TMP/tests" "$TMP/fixtures"
F="$TMP/tests/test_something.py"
printf 'ticket = "LEX-8888"\n' > "$F"
OUT="$(run_house_code "$ROSTERS_OK" "$F" 2>&1)"; RC=$?
assert_eq "a tests/ dir path still blocks on ticket-id-leak (no class exemption)" "1" "$RC"
F2="$TMP/fixtures/roster.yaml"
printf 'owner: Fixture Fictus\n' > "$F2"
OUT="$(run_house_code "$ROSTERS_OK" "$F2" 2>&1)"; RC=$?
assert_eq "a fixtures/ dir path still blocks on roster-name-leak (no class exemption)" "1" "$RC"

# Stub gh once, reused by every "is this actually dotty / is this actually
# private" live-verification test below — answers exactly the two calls
# house-code.py makes (repo visibility, repo full_name), fails loud on
# anything else so an unexpected call is never silently accepted.
STUBBIN="$TMP/stubbin"; mkdir -p "$STUBBIN"
cat > "$STUBBIN/gh" <<'STUBEOF'
#!/usr/bin/env bash
if [[ "$1" == "api" && "$2" == "repos/fixtureorg/fixture-private-repo" && "$4" == ".visibility" ]]; then
    echo "private"; exit 0
fi
if [[ "$1" == "api" && "$2" == "repos/lexijamesesq/dotty" && "$4" == ".full_name" ]]; then
    echo "lexijamesesq/dotty"; exit 0
fi
if [[ "$1" == "api" && "$4" == ".full_name" ]]; then
    # Any other repo genuinely answers its own name -- proves the gate
    # checks the ANSWER, not just that gh ran.
    echo "${2#repos/}"; exit 0
fi
echo "STUB: unexpected gh invocation: $*" >&2
exit 90
STUBEOF
chmod +x "$STUBBIN/gh"

git_repo_sim() { # <dir> <remote-url>
    mkdir -p "$1"
    git -C "$1" init -q -b main 2>/dev/null || { git -C "$1" init -q; git -C "$1" symbolic-ref HEAD refs/heads/main; }
    git -C "$1" remote add origin "$2"
}

section "This hook's own fixtures are exempt ONLY when the repo is verified-live as dotty itself"
DOTTYSIM="$TMP/dotty-sim"
git_repo_sim "$DOTTYSIM" "git@github.com:lexijamesesq/dotty.git"
mkdir -p "$DOTTYSIM/.claude/eval" "$DOTTYSIM/git-hooks"
printf 'ticket = "LEX-7777"\n' > "$DOTTYSIM/git-hooks/house-code.py"
OUT="$(cd "$DOTTYSIM" && PATH="$STUBBIN:$PATH" python3 "$HOUSE_CODE" --rosters-path "$ROSTERS_OK" --report "git-hooks/house-code.py" 2>&1)"; RC=$?
assert_eq "verified-dotty: this hook's own path (git-hooks/house-code.py) is exempt, exit 0" "0" "$RC"
if [[ "$OUT" == *"this hook's own fixtures"* ]]; then pass "own-fixture exemption is named in --report"; else fail "own-fixture exemption is named in --report" "$OUT"; fi

# A pressure-test finding: the SAME path, in a repo that is NOT dotty (no
# git remote at all here — the common case for an arbitrary consumer repo)
# must NOT be exempt. This is the defect that was live-proven exploitable.
NOTDOTTY="$TMP/not-dotty-sim"
mkdir -p "$NOTDOTTY/.claude/eval" "$NOTDOTTY/git-hooks"
printf 'ticket = "LEX-7778"\n' > "$NOTDOTTY/git-hooks/house-code.py"
OUT="$(cd "$NOTDOTTY" && python3 "$HOUSE_CODE" --rosters-path "$ROSTERS_OK" "git-hooks/house-code.py" 2>&1)"; RC=$?
assert_eq "NOT dotty (no verifiable remote): the same own-fixture path is NOT exempt, blocks" "1" "$RC"
if [[ "$OUT" == *"[ticket-id-leak]"* ]]; then pass "not-dotty: ticket-id-leak reported on the own-fixture path"; else fail "not-dotty: ticket-id-leak reported on the own-fixture path" "$OUT"; fi

# Same path, a remote that resolves live but to a DIFFERENT repo — proves
# the gate checks the verified answer, not just "a remote exists".
OTHERREPO="$TMP/other-repo-sim"
git_repo_sim "$OTHERREPO" "git@github.com:someoneelse/not-dotty.git"
mkdir -p "$OTHERREPO/.claude/eval" "$OTHERREPO/git-hooks"
printf 'ticket = "LEX-7779"\n' > "$OTHERREPO/git-hooks/house-code.py"
OUT="$(cd "$OTHERREPO" && PATH="$STUBBIN:$PATH" python3 "$HOUSE_CODE" --rosters-path "$ROSTERS_OK" "git-hooks/house-code.py" 2>&1)"; RC=$?
assert_eq "verified-live as a DIFFERENT repo: the own-fixture path is NOT exempt, blocks" "1" "$RC"

section "Declared one-off exemption: scoped to exactly the declared (rule, path), nothing else"
DECL_ONEOFF="$TMP/house-code-oneoff.json"
cat > "$DECL_ONEOFF" <<'EOF'
{"exemptions": [{"path": "deprecated/stub\\.sample\\.md", "rule": "ticket-id-leak", "reason": "test fixture: a declared one-off"}]}
EOF
mkdir -p "$TMP/deprecated"
DECLF="$TMP/deprecated/stub.sample.md"
printf 'ticket = "LEX-6666"\n' > "$DECLF"
OUT="$(cd "$TMP" && run_house_code_declared "$ROSTERS_OK" "$DECL_ONEOFF" --report "deprecated/stub.sample.md" 2>&1)"; RC=$?
assert_eq "declared exemption suppresses the named (rule, path): exit 0" "0" "$RC"
if [[ "$OUT" == *"deprecated/stub"*"1 file(s), 1 finding(s)"* ]]; then pass "declared exemption named in --report with counts"; else fail "declared exemption named in --report with counts" "$OUT"; fi

# The SAME path, a DIFFERENT rule (roster-name-leak) — the declared entry
# names ticket-id-leak only, so this must still block. Proves an exemption
# is scoped per-rule, not per-file.
DECLF2="$TMP/deprecated/stub2.sample.md"
printf 'owner: Fixture Fictus\n' > "$DECLF2"
cat > "$TMP/deprecated/stub2decl.json" <<'EOF'
{"exemptions": [{"path": "deprecated/stub2\\.sample\\.md", "rule": "ticket-id-leak", "reason": "test fixture: wrong rule on purpose"}]}
EOF
OUT="$(cd "$TMP" && run_house_code_declared "$ROSTERS_OK" "$TMP/deprecated/stub2decl.json" "deprecated/stub2.sample.md")"; RC=$?
assert_eq "a declared exemption for a DIFFERENT rule does not suppress roster-name-leak" "1" "$RC"

section "Declared exemption that matched nothing is named, not silently accepted"
DECL_STALE="$TMP/house-code-stale.json"
cat > "$DECL_STALE" <<'EOF'
{"exemptions": [{"path": "nowhere/nothing\\.md", "rule": "ticket-id-leak", "reason": "test fixture: a stale entry"}]}
EOF
F="$TMP/clean3.py"
printf 'x = 1\n' > "$F"
OUT="$(run_house_code_declared "$ROSTERS_OK" "$DECL_STALE" --report "$F" 2>&1)"
if [[ "$OUT" == *"declared but matched NOTHING"* ]]; then pass "a stale declared exemption is flagged in --report"; else fail "a stale declared exemption is flagged in --report" "$OUT"; fi

section "Fail-closed: a malformed .house-code.json blocks, never silently 'no exemptions'"
DECL_BAD="$TMP/house-code-bad.json"
printf 'not valid json{' > "$DECL_BAD"
F="$TMP/clean4.py"
printf 'x = 1\n' > "$F"
OUT="$(run_house_code_declared "$ROSTERS_OK" "$DECL_BAD" "$F" 2>&1)"; RC=$?
assert_eq "malformed declaration file: exit 2 (fail-closed)" "2" "$RC"

section "private_repo: declared but NOT verified (no git remote here) never suppresses vault-path-leak"
DECL_PRIVATE_UNVERIFIED="$TMP/house-code-private-unverified.json"
cat > "$DECL_PRIVATE_UNVERIFIED" <<'EOF'
{"private_repo": true}
EOF
F="$TMP/vaultpath2.py"
printf 'p = "/Users/fixtureuser/Vaults/Notes/System/foo.md"\n' > "$F"
OUT="$(run_house_code_declared "$ROSTERS_OK" "$DECL_PRIVATE_UNVERIFIED" "$F" 2>&1)"; RC=$?
assert_eq "declared private_repo with no verifiable git remote still blocks vault-path-leak (fail toward public)" "1" "$RC"

section "private_repo: verified live via a stubbed gh, suppresses vault-path-leak only"
PRIVREPO="$TMP/private-repo-sim"
git_repo_sim "$PRIVREPO" "git@github.com:fixtureorg/fixture-private-repo.git"
cat > "$PRIVREPO/.house-code.json" <<'EOF'
{"private_repo": true}
EOF

F="vaultpath3.py"
printf 'p = "/Users/fixtureuser/Vaults/Notes/System/foo.md"\np2 = "%s"\n' "LEX-5555" > "$PRIVREPO/$F"
(cd "$PRIVREPO" && PATH="$STUBBIN:$PATH" python3 "$HOUSE_CODE" --rosters-path "$ROSTERS_OK" --report "$F" 2>&1)
OUT="$(cd "$PRIVREPO" && PATH="$STUBBIN:$PATH" python3 "$HOUSE_CODE" --rosters-path "$ROSTERS_OK" --report "$F" 2>&1)"; RC=$?
assert_eq "verified-private repo: still blocks (ticket-id-leak stays active regardless of visibility)" "1" "$RC"
if [[ "$OUT" == *"[ticket-id-leak]"* ]]; then pass "verified-private repo: ticket-id-leak still reported"; else fail "verified-private repo: ticket-id-leak still reported" "$OUT"; fi
if [[ "$OUT" == *"[vault-path-leak]"* ]]; then fail "verified-private repo: vault-path-leak must NOT be reported" "$OUT"; else pass "verified-private repo: vault-path-leak is suppressed"; fi
if [[ "$OUT" == *"private_repo profile, verified live"* ]]; then pass "verified-private suppression is named in --report"; else fail "verified-private suppression is named in --report" "$OUT"; fi

section "Fail-closed: missing rosters file"
OUT="$(run_house_code "$TMP/does-not-exist.md" "$TMP/clean1.py" 2>&1)"; RC=$?
assert_eq "missing rosters file: exit 2" "2" "$RC"
if [[ "$OUT" == *"does-not-exist.md"* ]]; then pass "missing rosters file: names the missing path"; else fail "missing rosters file: names the missing path" "$OUT"; fi

section "Fail-closed: malformed (truncated) rosters file"
OUT="$(run_house_code "$ROSTERS_TRUNCATED" "$TMP/clean1.py" 2>&1)"; RC=$?
assert_eq "truncated rosters file: exit 2" "2" "$RC"

# ============================================================================
# Two pressure-test findings, fixed: a PR-controlled FILENAME reaching this
# parser as a bare argv token (a file literally named -h silenced the whole
# scan; --rosters-path=<decoy> silently redirected the roster source), and a
# tracked file with one invalid UTF-8 byte silently skipped rather than
# blocked. Both closed here at the parser level; the trusted lane that
# originally exposed the argv class is gone (house-code no longer runs
# there), but Lane A still runs this hook via pre-commit's positional
# filenames, so the fix stays real regardless of caller.
# ============================================================================
section "--files-from: the safe path for an untrusted file list -- a dash-prefixed name is never argv"
DASH_H="$TMP/dashh-dir/-h"
mkdir -p "$TMP/dashh-dir"
printf 'x = 1\n' > "$DASH_H"
printf '%s\0' "-h" > "$TMP/filelist.nul"
OUT="$(cd "$TMP/dashh-dir" && printf '%s\0' "-h" | python3 "$HOUSE_CODE" --rosters-path "$ROSTERS_OK" --files-from - 2>&1)"; RC=$?
assert_eq "--files-from -: a file named -h is read as a real file, not parsed as help" "0" "$RC"
if [[ "$OUT" == *"usage:"* ]]; then fail "--files-from -: must not trigger argparse's own -h handling" "$OUT"; else pass "--files-from -: no usage banner (never option-parsed)"; fi

section "--files-from: a genuine finding in a dash-named file is still caught"
DASH_LEAK="$TMP/dashh-dir/-leak.py"
printf 'ticket = "LEX-8888"\n' > "$DASH_LEAK"
OUT="$(cd "$TMP/dashh-dir" && printf '%s\0' "-leak.py" | python3 "$HOUSE_CODE" --rosters-path "$ROSTERS_OK" --files-from - 2>&1)"; RC=$?
assert_eq "--files-from -: a dash-named file's real finding still blocks" "1" "$RC"

section "--files-from and positional FILE are mutually exclusive"
OUT="$(printf '%s\0' "$TMP/clean1.py" | python3 "$HOUSE_CODE" --rosters-path "$ROSTERS_OK" --files-from - "$TMP/clean1.py" 2>&1)"; RC=$?
assert_eq "--files-from with positional args too: exit 2 (fail-closed, ambiguous)" "2" "$RC"

section "Positional dash-guard: a file that still looks like an option is refused, not silently scanned"
OUT="$(cd "$TMP" && python3 "$HOUSE_CODE" --rosters-path "$ROSTERS_OK" -- "-h" 2>&1)"; RC=$?
assert_eq "positional -h after --: refused by the dash-guard (exit 2), not silently treated as a filename" "2" "$RC"
if [[ "$OUT" == *"BLOCKED"* ]]; then pass "dash-guard names the refusal"; else fail "dash-guard names the refusal" "$OUT"; fi

section "Fail-closed: an undecodable byte blocks, never a silent skip (the fix for a live-found bypass)"
UNDECODABLE="$TMP/undecodable.py"
printf 'ticket = "LEX-9999"' > "$UNDECODABLE"
printf '\xff' >> "$UNDECODABLE"
OUT="$(run_house_code "$ROSTERS_OK" "$UNDECODABLE" 2>&1)"; RC=$?
assert_eq "undecodable byte: exit 2 (fail-closed), never a silent skip past a real finding" "2" "$RC"
if [[ "$OUT" == *"$UNDECODABLE"* || "$OUT" == *"undecodable.py"* ]]; then pass "undecodable byte: names the file"; else fail "undecodable byte: names the file" "$OUT"; fi

section "control: a genuinely clean file with no undecodable bytes still passes"
CLEAN_UTF8="$TMP/clean-utf8.py"
printf 'x = 1\n' > "$CLEAN_UTF8"
OUT="$(run_house_code "$ROSTERS_OK" "$CLEAN_UTF8" 2>&1)"; RC=$?
assert_eq "control: clean UTF-8 file passes (exit 0)" "0" "$RC"

finish
