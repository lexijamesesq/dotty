#!/usr/bin/env bash
# Test suite for provision-public-repo.sh (repo root).
#
# Runs in CI, which has NO gh auth and NO network. The script routes every gh
# call through $GH; this suite substitutes a stub `gh` that serves canned GitHub
# API JSON for GETs (from $GH_STUB_DIR) and records write-method bodies (into
# $GH_STUB_CAPTURE). No real gh, no network, ever.
#
# HARD-FAILS, never skips, on a missing dependency (jq, git) — a silently-green
# suite that ran nothing is a "no-op tier" and is treated as a failure here.
#
# Ruleset-path resolution checks a FIXED install path (XDG_CONFIG_HOME-derived;
# see git-hooks/gitleaks-common.sh's gl_fixed_rules_path). The suite pins
# XDG_CONFIG_HOME to an empty scratch dir by default (see EMPTYXDG below) so it
# never depends on this machine's real provisioning state, which differs on CI
# and would otherwise leak through and mask the fail-closed/override assertions.
#
# Fixtures use the fictional slug `acme/widgets`. No operator PII appears.
#
# Run: bash ~/bin/dotty/.claude/eval/provision-public-repo.test.sh

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/assert.sh"

SCRIPT="${SCRIPT:-$SCRIPT_DIR/../../provision-public-repo.sh}"
[[ -f "$SCRIPT" ]] || { echo "FATAL: script under test not found: $SCRIPT"; exit 2; }

# Dependencies are REQUIRED. A missing binary is a hard suite failure, never a
# silent skip.
command -v jq  >/dev/null 2>&1 || { echo "FATAL: jq not on PATH — suite cannot run.";  exit 2; }
command -v git >/dev/null 2>&1 || { echo "FATAL: git not on PATH — suite cannot run."; exit 2; }

# --- Temp workspace ----------------------------------------------------------
TMP="$(mktemp -d -t provision-public-repo-test.XXXXXX)"
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT INT TERM

SLUG="acme/widgets"
RULES="$TMP/op-rules.toml"; printf 'title = "op"\n' > "$RULES"

# Fixed-install-path isolation (see header). EMPTYXDG is the suite-wide default
# — no gitleaks/operator-rules.toml under it, so Step 1 never resolves via the
# fixed path unless a test explicitly points XDG_CONFIG_HOME at FIXEDXDG
# instead. Every invocation below that can reach Step 1's resolution logic
# passes XDG_CONFIG_HOME explicitly for this reason.
EMPTYXDG="$TMP/empty-xdg"; mkdir -p "$EMPTYXDG"
FIXEDXDG="$TMP/fixed-xdg"; mkdir -p "$FIXEDXDG/gitleaks"; cp "$RULES" "$FIXEDXDG/gitleaks/operator-rules.toml"

# --- The gh stub -------------------------------------------------------------
STUB="$TMP/bin/gh"
mkdir -p "$TMP/bin"
cat > "$STUB" <<'STUBEOF'
#!/usr/bin/env bash
# Test stub for `gh`. Only `gh api ...` is supported.
#  - GET: prints canned JSON from $GH_STUB_DIR (endpoint -> file mapping below).
#  - write methods (-X/--method): record the request body to $GH_STUB_CAPTURE
#    and echo a trivial success object. No network.
set -uo pipefail

method=GET
read_stdin=0
saw_api=0
pos=()

while [[ $# -gt 0 ]]; do
    case "$1" in
        api) saw_api=1; shift ;;
        -X|--method) method="${2:-}"; shift 2 ;;
        --input) [[ "${2:-}" == "-" ]] && read_stdin=1; shift 2 ;;
        -f|--field|-F|--raw-field|-H|--header|--jq|-q|--template|-t) shift 2 ;;
        --paginate|--slurp|--silent) shift ;;
        -*) shift ;;
        *) pos+=("$1"); shift ;;
    esac
done

[[ $saw_api -eq 1 ]] || { echo "STUB: only 'gh api ...' is stubbed" >&2; exit 90; }
endpoint="${pos[0]:-}"
[[ -n "$endpoint" ]] || { echo "STUB: no endpoint given" >&2; exit 91; }

if [[ "$method" != GET ]]; then
    body=""
    [[ $read_stdin -eq 1 ]] && body="$(cat)"
    if [[ -n "${GH_STUB_CAPTURE:-}" ]]; then
        mkdir -p "$GH_STUB_CAPTURE"
        printf '%s %s\n' "$method" "$endpoint" >> "$GH_STUB_CAPTURE/requests.log"
        printf '%s' "$body" > "$GH_STUB_CAPTURE/${method}_${endpoint//\//_}.body"
    fi
    echo '{}'
    exit 0
fi

# GET: drop the repos/<owner>/<repo> prefix, map the remainder to a file.
IFS='/' read -r -a seg <<< "$endpoint"
rest="$(IFS=/; echo "${seg[*]:3}")"
case "$rest" in
    "")          f="repo.json" ;;
    "rulesets")  f="rulesets.json" ;;
    rulesets/*)  f="ruleset-${rest#rulesets/}.json" ;;
    *)           f="" ;;
esac
if [[ -n "$f" && -f "${GH_STUB_DIR:-}/$f" ]]; then
    cat "${GH_STUB_DIR}/$f"
    exit 0
fi
echo "STUB: no canned GET response for '$endpoint' (rest='$rest', file='$f')" >&2
exit 92
STUBEOF
chmod +x "$STUB"

# --- Scenario builders -------------------------------------------------------
SCEN="$TMP/scenarios"

# repo.json writer. $1=dir $2=default_branch $3=merge(good|bad) $4=secret(on|off)
write_repo() {
    local dir="$1" branch="$2" merge="$3" secret="$4"
    local amc dbm sct scm ss pp
    if [[ "$merge" == good ]]; then
        amc=false; dbm=true; sct="PR_TITLE"; scm="PR_BODY"
    else
        amc=true;  dbm=false; sct="COMMIT_OR_PR_TITLE"; scm="COMMIT_MESSAGES"
    fi
    if [[ "$secret" == on ]]; then ss=enabled; pp=enabled; else ss=disabled; pp=disabled; fi
    mkdir -p "$dir"
    jq -n \
        --arg branch "$branch" --argjson amc "$amc" --argjson dbm "$dbm" \
        --arg sct "$sct" --arg scm "$scm" --arg ss "$ss" --arg pp "$pp" '{
            default_branch: $branch,
            allow_squash_merge: true,
            allow_merge_commit: $amc,
            allow_rebase_merge: false,
            delete_branch_on_merge: $dbm,
            squash_merge_commit_title: $sct,
            squash_merge_commit_message: $scm,
            security_and_analysis: {
                secret_scanning: { status: $ss },
                secret_scanning_push_protection: { status: $pp }
            }
        }' > "$dir/repo.json"
}

# ruleset detail writer. $1=dir $2=id $3=branch $4=comma-separated rule types.
# A pull_request rule is written with owned params at intent (review_count 0).
write_ruleset() {
    local dir="$1" id="$2" branch="$3" types="$4"
    mkdir -p "$dir"
    local rules="[]" t
    IFS=',' read -r -a arr <<< "$types"
    for t in "${arr[@]}"; do
        case "$t" in
            required_status_checks)
                rules="$(jq -c --argjson r "$rules" '$r + [{type:"required_status_checks", parameters:{required_status_checks:[{context:"eval-suite"}], strict_required_status_checks_policy:false}}]' <<<'null')" ;;
            pull_request)
                rules="$(jq -c --argjson r "$rules" '$r + [{type:"pull_request", parameters:{required_approving_review_count:0, dismiss_stale_reviews_on_push:false, require_code_owner_review:false, require_last_push_approval:false, required_review_thread_resolution:false}}]' <<<'null')" ;;
            *)
                rules="$(jq -c --argjson r "$rules" --arg t "$t" '$r + [{type:$t}]' <<<'null')" ;;
        esac
    done
    jq -n --argjson id "$id" --arg branch "refs/heads/$branch" --argjson rules "$rules" '{
        id: $id,
        name: ("Protect " + ($branch | ltrimstr("refs/heads/"))),
        target: "branch",
        enforcement: "active",
        bypass_actors: [],
        conditions: { ref_name: { include: [$branch], exclude: [] } },
        rules: $rules
    }' > "$dir/ruleset-$id.json"
    jq -n --argjson id "$id" --arg branch "$branch" \
        '[{id:$id, name:("Protect " + $branch), target:"branch"}]' > "$dir/rulesets.json"
}

# 1. wired — everything correct.
SC_WIRED="$SCEN/wired"
write_repo "$SC_WIRED" main good on
write_ruleset "$SC_WIRED" 1 main "non_fast_forward,deletion,pull_request"

# 2. missing-pr — wired except the ruleset lacks pull_request.
SC_MPR="$SCEN/missing-pr"
write_repo "$SC_MPR" main good on
write_ruleset "$SC_MPR" 1 main "non_fast_forward,deletion"

# 3. dotty-shape — ruleset carries required_status_checks but no pull_request.
SC_DOTTY="$SCEN/dotty-shape"
write_repo "$SC_DOTTY" main good on
write_ruleset "$SC_DOTTY" 1 main "non_fast_forward,deletion,required_status_checks"

# 4. master — default branch is master; fully wired for master.
SC_MASTER="$SCEN/master"
write_repo "$SC_MASTER" master good on
write_ruleset "$SC_MASTER" 7 master "non_fast_forward,deletion,pull_request"

# 5. no-ruleset — no rulesets exist at all.
SC_NORULESET="$SCEN/no-ruleset"
write_repo "$SC_NORULESET" main good on
mkdir -p "$SC_NORULESET"
echo '[]' > "$SC_NORULESET/rulesets.json"

# 6. merge-drift — merge settings wrong; ruleset + secret fine.
SC_MERGE="$SCEN/merge-drift"
write_repo "$SC_MERGE" main bad on
write_ruleset "$SC_MERGE" 1 main "non_fast_forward,deletion,pull_request"

# 7. secret-drift — secret scanning off; merge + ruleset fine.
SC_SECRET="$SCEN/secret-drift"
write_repo "$SC_SECRET" main good off
write_ruleset "$SC_SECRET" 1 main "non_fast_forward,deletion,pull_request"

# 8. pr-count2 — a pull_request rule with required_approving_review_count: 2,
#    alongside a rich required_status_checks rule, a non-empty bypass_actors,
#    and an EXTRA GitHub pull_request param (allowed_merge_methods) to prove it
#    survives convergence.
SC_PRCOUNT="$SCEN/pr-count2"
write_repo "$SC_PRCOUNT" main good on
mkdir -p "$SC_PRCOUNT"
echo '[{"id":3,"name":"Protect main","target":"branch"}]' > "$SC_PRCOUNT/rulesets.json"
cat > "$SC_PRCOUNT/ruleset-3.json" <<'EOF'
{
  "id": 3, "name": "Protect main", "target": "branch", "enforcement": "active",
  "bypass_actors": [{"actor_id": 42, "actor_type": "Team", "bypass_mode": "pull_request"}],
  "conditions": {"ref_name": {"include": ["refs/heads/main"], "exclude": []}},
  "rules": [
    {"type": "non_fast_forward"},
    {"type": "deletion"},
    {"type": "required_status_checks", "parameters": {"required_status_checks": [{"context": "eval-suite"}], "strict_required_status_checks_policy": true}},
    {"type": "pull_request", "parameters": {"required_approving_review_count": 2, "dismiss_stale_reviews_on_push": false, "require_code_owner_review": false, "require_last_push_approval": false, "required_review_thread_resolution": false, "allowed_merge_methods": ["squash"]}}
  ]
}
EOF

# 9. pr-extra — owned params AT intent, plus extra GitHub keys. Must be no-drift.
SC_PREXTRA="$SCEN/pr-extra"
write_repo "$SC_PREXTRA" main good on
echo '[{"id":4,"name":"Protect main","target":"branch"}]' > "$SC_PREXTRA/rulesets.json"
cat > "$SC_PREXTRA/ruleset-4.json" <<'EOF'
{
  "id": 4, "name": "Protect main", "target": "branch", "enforcement": "active",
  "bypass_actors": [],
  "conditions": {"ref_name": {"include": ["refs/heads/main"], "exclude": []}},
  "rules": [
    {"type": "non_fast_forward"},
    {"type": "deletion"},
    {"type": "pull_request", "parameters": {"required_approving_review_count": 0, "dismiss_stale_reviews_on_push": false, "require_code_owner_review": false, "require_last_push_approval": false, "required_review_thread_resolution": false, "allowed_merge_methods": ["squash"], "automatic_copilot_code_review_enabled": false}}
  ]
}
EOF

# --- Local-repo + script-copy helpers ----------------------------------------
mklocalrepo() { # <dir>  — a git work tree with a tracked .gitleaks.toml
    git init -q "$1"
    git -C "$1" config user.email "test@example.com"
    git -C "$1" config user.name "Test Runner"
    git -C "$1" config commit.gpgsign false
    printf 'title = "fixture"\n' > "$1/.gitleaks.toml"
    git -C "$1" add .gitleaks.toml
    git -C "$1" commit -q -m "add gitleaks config"
}
mkbaregit() { # <dir> — a git work tree WITHOUT a tracked .gitleaks.toml
    git init -q "$1"
    git -C "$1" config user.email "test@example.com"
    git -C "$1" config user.name "Test Runner"
    git -C "$1" config commit.gpgsign false
}
mkcopy() { # <dir> -> path to a copy of the script placed there
    mkdir -p "$1"
    cp "$SCRIPT" "$1/provision-public-repo.sh"
    chmod +x "$1/provision-public-repo.sh"
    printf '%s' "$1/provision-public-repo.sh"
}

# --- Runner ------------------------------------------------------------------
# run_provision <capture-dir> <stub-dir> <args...>  -> sets RC, OUT
run_provision() {
    local cap="$1" dir="$2"; shift 2
    OUT="$(GH="$STUB" GH_STUB_DIR="$dir" GH_STUB_CAPTURE="$cap" \
        env -u GITLEAKS_OPERATOR_RULES bash "$SCRIPT" "$@" 2>&1)"
    RC=$?
}

# ============================================================================
section "--check against a fully-wired repo: no drift, exit 0"
run_provision "$TMP/cap/wired-check" "$SC_WIRED" --check "$SLUG"
assert_eq "wired --check exits 0" "0" "$RC"
grep -q "no drift" <<<"$OUT" && pass "reports no drift" || fail "reports no drift" "$OUT"
grep -q "DRIFT" <<<"$OUT" && fail "no DRIFT lines emitted" "$OUT" || pass "no DRIFT lines emitted"

# ============================================================================
section "--check against a repo missing the pull_request rule: drift, non-zero exit"
run_provision "$TMP/cap/mpr-check" "$SC_MPR" --check "$SLUG"
assert_eq "missing-pr --check exits 1" "1" "$RC"
grep -q "DRIFT rule.pull_request" <<<"$OUT" && pass "flags pull_request drift" || fail "flags pull_request drift" "$OUT"
grep -q "OK    rule.non_fast_forward" <<<"$OUT" && pass "non_fast_forward still OK" || fail "non_fast_forward still OK" "$OUT"

# ============================================================================
section "converge preserves an existing required_status_checks rule (PATCH body retains it)"
CAP="$TMP/cap/dotty-converge"
run_provision "$CAP" "$SC_DOTTY" "$SLUG"
assert_eq "dotty-shape converge exits 0" "0" "$RC"
PUTBODY="$CAP/PUT_repos_acme_widgets_rulesets_1.body"
if [[ -f "$PUTBODY" ]]; then
    pass "ruleset PUT issued"
else
    fail "ruleset PUT issued" "no PUT body; requests.log=$(cat "$CAP/requests.log" 2>/dev/null)"
fi
if [[ -f "$PUTBODY" ]] && jq -e '.rules | map(.type) | index("required_status_checks") != null' "$PUTBODY" >/dev/null 2>&1; then
    pass "PUT body RETAINS required_status_checks (CI gate not clobbered)"
else
    fail "PUT body RETAINS required_status_checks" "$(cat "$PUTBODY" 2>/dev/null)"
fi
if [[ -f "$PUTBODY" ]] && jq -e '.rules | map(.type) | index("pull_request") != null' "$PUTBODY" >/dev/null 2>&1; then
    pass "PUT body ADDS pull_request"
else
    fail "PUT body ADDS pull_request" "$(cat "$PUTBODY" 2>/dev/null)"
fi
if [[ -f "$PUTBODY" ]]; then
    assert_eq "PUT body enforcement active"            "active"          "$(jq -r '.enforcement' "$PUTBODY")"
    assert_eq "PUT body preserves conditions include"  "refs/heads/main" "$(jq -r '.conditions.ref_name.include[0]' "$PUTBODY")"
    assert_eq "pull_request review count is 0 (solo operator)" "0" \
        "$(jq -r '.rules[] | select(.type=="pull_request") | .parameters.required_approving_review_count' "$PUTBODY")"
fi

# ============================================================================
section "OWNED rule: --check flags pull_request review_count != 0 (solo-operator downgrade)"
run_provision "$TMP/cap/prcount-check" "$SC_PRCOUNT" --check "$SLUG"
assert_eq "pr-count2 --check exits 1" "1" "$RC"
grep -q "DRIFT rule.pull_request = review_count=2" <<<"$OUT" && pass "flags pull_request review_count=2 as drift" || fail "flags pull_request review_count=2" "$OUT"

# ============================================================================
section "OWNED rule: converge rewrites review_count to 0, preserving unowned rules verbatim"
CAP="$TMP/cap/prcount-converge"
run_provision "$CAP" "$SC_PRCOUNT" "$SLUG"
assert_eq "pr-count2 converge exits 0" "0" "$RC"
PB="$CAP/PUT_repos_acme_widgets_rulesets_3.body"
if [[ -f "$PB" ]]; then
    pass "ruleset PUT issued"
    assert_eq "review_count rewritten to 0" "0" \
        "$(jq -r '.rules[] | select(.type=="pull_request") | .parameters.required_approving_review_count' "$PB")"
    jq -e '.rules[] | select(.type=="required_status_checks") | .parameters.strict_required_status_checks_policy == true' "$PB" >/dev/null 2>&1 \
        && pass "required_status_checks preserved byte-for-byte" || fail "required_status_checks preserved" "$(cat "$PB")"
    assert_eq "non-empty bypass_actors preserved" "42" "$(jq -r '.bypass_actors[0].actor_id' "$PB")"
    jq -e '.rules[] | select(.type=="pull_request") | .parameters.allowed_merge_methods == ["squash"]' "$PB" >/dev/null 2>&1 \
        && pass "extra pull_request param (allowed_merge_methods) preserved" || fail "extra pull_request param preserved" "$(cat "$PB")"
else
    fail "ruleset PUT issued" "requests.log=$(cat "$CAP/requests.log" 2>/dev/null)"
fi

# ============================================================================
section "OWNED rule: owned params at intent + extra GitHub keys => NO drift (real-API no-op)"
run_provision "$TMP/cap/prextra-check" "$SC_PREXTRA" --check "$SLUG"
assert_eq "pr-extra --check exits 0 (extras ignored for drift)" "0" "$RC"
grep -q "DRIFT" <<<"$OUT" && fail "no drift when owned params match despite extras" "$OUT" || pass "no drift when owned params match despite extras"

# ============================================================================
section "default branch is READ from the API, not assumed (stub returns master)"
run_provision "$TMP/cap/master-check" "$SC_MASTER" --check "$SLUG"
assert_eq "master fully-wired --check exits 0 (matched the master ruleset)" "0" "$RC"
grep -q "target: master" <<<"$OUT" && pass "reports ruleset target = master (from API)" || fail "reports target master" "$OUT"
grep -q "DRIFT" <<<"$OUT" && fail "no drift when the master ruleset matches" "$OUT" || pass "no drift when the master ruleset matches"

# ============================================================================
section "ruleset path resolves from the fixed install path (no env var, no flag)"
COPYDIR="$TMP/withfixed"; COPY="$(mkcopy "$COPYDIR")"
LRA="$TMP/lr-withfixed"; mklocalrepo "$LRA"
OUT="$(GH="$STUB" GH_STUB_DIR="$SC_WIRED" GH_STUB_CAPTURE="$TMP/cap/withfixed" \
    env -u GITLEAKS_OPERATOR_RULES XDG_CONFIG_HOME="$FIXEDXDG" bash "$COPY" --check "$SLUG" "$LRA" 2>&1)"; RC=$?
grep -q "FATAL \[operator-rules\]" <<<"$OUT" && fail "resolves via the fixed install path (no fail-closed)" "$OUT" || pass "resolves via the fixed install path (no fail-closed)"
grep -q "source: fixed install path" <<<"$OUT" && pass "reports the fixed install path as the source" || fail "reports the fixed install path as the source" "$OUT"

# ============================================================================
section "ruleset path falls back to \$GITLEAKS_OPERATOR_RULES when the fixed install path is absent"
COPYDIR2="$TMP/nofixed"; COPY2="$(mkcopy "$COPYDIR2")"
LRB="$TMP/lr-nofixed"; mklocalrepo "$LRB"
OUT="$(GH="$STUB" GH_STUB_DIR="$SC_WIRED" GH_STUB_CAPTURE="$TMP/cap/nofixed" \
    XDG_CONFIG_HOME="$EMPTYXDG" GITLEAKS_OPERATOR_RULES="$RULES" bash "$COPY2" --check "$SLUG" "$LRB" 2>&1)"; RC=$?
grep -q "FATAL \[operator-rules\]" <<<"$OUT" && fail "resolves via env var override (no fail-closed)" "$OUT" || pass "resolves via env var override (no fail-closed)"
grep -q 'source: [$]GITLEAKS_OPERATOR_RULES' <<<"$OUT" && pass "reports env var as the source" || fail "reports env var as the source" "$OUT"

# ============================================================================
section "fail-closed: no --rules, no readable fixed install path, no env var"
LRC="$TMP/lr-failclosed"; mklocalrepo "$LRC"
OUT="$(GH="$STUB" GH_STUB_DIR="$SC_WIRED" GH_STUB_CAPTURE="$TMP/cap/failclosed" \
    XDG_CONFIG_HOME="$EMPTYXDG" env -u GITLEAKS_OPERATOR_RULES bash "$COPY2" --check "$SLUG" "$LRC" 2>&1)"; RC=$?
assert_eq "fail-closed exits non-zero" "1" "$RC"
grep -q "cannot locate the operator gitleaks ruleset" <<<"$OUT" && pass "names the failure (generic: nothing supplied)" || fail "names the failure (generic)" "$OUT"
grep -q "gitleaks-rules apply" <<<"$OUT" && pass "names the blueprint install (gitleaks-rules apply)" || fail "names the blueprint install" "$OUT"
grep -q "is set but its target is unreadable" <<<"$OUT" && fail "generic path does NOT pinpoint the env var" "$OUT" || pass "generic path does NOT pinpoint the env var"
[[ ! -f "$TMP/cap/failclosed/requests.log" ]] && pass "aborted before any remote call" || fail "aborted before any remote call" "issued writes"

# ============================================================================
section "set-but-unreadable \$GITLEAKS_OPERATOR_RULES gets a PINPOINTED message (not the generic)"
# no --rules, no readable fixed install path (EMPTYXDG has none), env var set to a broken path
LRH="$TMP/lr-envbad"; mklocalrepo "$LRH"
OUT="$(GH="$STUB" GH_STUB_DIR="$SC_WIRED" GH_STUB_CAPTURE="$TMP/cap/envbad" \
    XDG_CONFIG_HOME="$EMPTYXDG" GITLEAKS_OPERATOR_RULES="$TMP/does-not-exist.toml" bash "$COPY2" --check "$SLUG" "$LRH" 2>&1)"; RC=$?
assert_eq "set-but-unreadable env var exits non-zero" "1" "$RC"
grep -q "GITLEAKS_OPERATOR_RULES is set but its target is unreadable" <<<"$OUT" && pass "pinpoints the unreadable env var" || fail "pinpoints the unreadable env var" "$OUT"
grep -q "cannot locate" <<<"$OUT" && fail "does NOT fall back to the generic message" "$OUT" || pass "does NOT fall back to the generic message"
grep -q "does-not-exist.toml" <<<"$OUT" && fail "withholds the resolved path (private target)" "path leaked into output" || pass "withholds the resolved path (private target)"
[[ ! -f "$TMP/cap/envbad/requests.log" ]] && pass "aborted before any remote call" || fail "aborted before any remote call" "issued writes"

# ============================================================================
section "--rules flag has highest precedence and expands a leading ~"
LRD="$TMP/lr-flag"; mklocalrepo "$LRD"
FH="$TMP/flaghome"; mkdir -p "$FH"; printf 'title = "op"\n' > "$FH/op.toml"
tilde='~'; TFLAG="$tilde/op.toml"
OUT="$(GH="$STUB" GH_STUB_DIR="$SC_WIRED" GH_STUB_CAPTURE="$TMP/cap/flag" \
    HOME="$FH" XDG_CONFIG_HOME="$EMPTYXDG" env -u GITLEAKS_OPERATOR_RULES bash "$COPY2" --rules "$TFLAG" --check "$SLUG" "$LRD" 2>&1)"; RC=$?
grep -q "FATAL \[operator-rules\]" <<<"$OUT" && fail "--rules with ~ resolves (no fail-closed)" "$OUT" || pass "--rules with ~ resolves (no fail-closed)"
grep -q "source: --rules" <<<"$OUT" && pass "reports --rules as the source" || fail "reports --rules as the source" "$OUT"
# an unreadable --rules is a hard, named failure
OUT="$(GH="$STUB" GH_STUB_DIR="$SC_WIRED" GH_STUB_CAPTURE="$TMP/cap/flagbad" \
    XDG_CONFIG_HOME="$EMPTYXDG" env -u GITLEAKS_OPERATOR_RULES bash "$COPY2" --rules "$TMP/nope.toml" --check "$SLUG" "$LRD" 2>&1)"; RC=$?
assert_eq "--rules unreadable exits non-zero" "1" "$RC"
grep -q "not readable" <<<"$OUT" && pass "names the unreadable --rules path" || fail "names the unreadable --rules path" "$OUT"

# ============================================================================
section "local steps under --check: inspected read-only (no mutation)"
LRE="$TMP/lr-detect"; mklocalrepo "$LRE"
OUT="$(GH="$STUB" GH_STUB_DIR="$SC_WIRED" GH_STUB_CAPTURE="$TMP/cap/detect" \
    XDG_CONFIG_HOME="$EMPTYXDG" env -u GITLEAKS_OPERATOR_RULES bash "$SCRIPT" --rules "$RULES" --check "$SLUG" "$LRE" 2>&1)"; RC=$?
assert_eq "local --check exits 1 (local drift present)" "1" "$RC"
grep -q "OK    gitleaks.toml-tracked"  <<<"$OUT" && pass "detects the tracked .gitleaks.toml"      || fail "detects the tracked .gitleaks.toml" "$OUT"
grep -q "OK    operator-rules"         <<<"$OUT" && pass "resolves operator-rules via --rules"     || fail "resolves operator-rules via --rules" "$OUT"
grep -q "DRIFT pre-commit-hooks"       <<<"$OUT" && pass "flags missing pre-commit hooks"           || fail "flags missing pre-commit hooks" "$OUT"
grep -q "DRIFT origin/HEAD"            <<<"$OUT" && pass "flags unset origin/HEAD"                  || fail "flags unset origin/HEAD" "$OUT"
[[ ! -e "$LRE/.gitleaks-operator-rules.toml" ]] && pass "no per-repo symlink created (fixed path relied on instead)" || fail "no per-repo symlink created" "symlink exists"

# a missing tracked .gitleaks.toml is DRIFT and is NOT synthesized
LRF="$TMP/lr-nogl"; mkbaregit "$LRF"
OUT="$(GH="$STUB" GH_STUB_DIR="$SC_WIRED" GH_STUB_CAPTURE="$TMP/cap/nogl" \
    XDG_CONFIG_HOME="$EMPTYXDG" env -u GITLEAKS_OPERATOR_RULES bash "$SCRIPT" --rules "$RULES" --check "$SLUG" "$LRF" 2>&1)"
grep -q "DRIFT gitleaks.toml-tracked" <<<"$OUT" && pass "flags a missing tracked .gitleaks.toml" || fail "flags a missing tracked .gitleaks.toml" "$OUT"
[[ ! -e "$LRF/.gitleaks.toml" ]] && pass "does NOT synthesize a .gitleaks.toml" || fail "does NOT synthesize a .gitleaks.toml" "file was created"

# ============================================================================
section "step 3b: scan-stage-coverage — recipe ids OK; unbound DRIFT; commented-out stages DRIFT"
L3B="$TMP/lr-stages"; mklocalrepo "$L3B"
run_3b() { # <cap-name> — --check against $L3B, sets OUT
    OUT="$(GH="$STUB" GH_STUB_DIR="$SC_WIRED" GH_STUB_CAPTURE="$TMP/cap/$1" \
        env -u GITLEAKS_OPERATOR_RULES bash "$SCRIPT" --rules "$RULES" --check "$SLUG" "$L3B" 2>&1)"
}
cat > "$L3B/.pre-commit-config.yaml" <<'YAML'
repos:
  - repo: https://github.com/acme/dotty
    rev: v1
    hooks:
      - id: gitleaks-staged
      - id: gitleaks-pre-push
      - id: gitleaks-commit-msg
YAML
run_3b stages-ok
grep -q "OK    scan-stage-coverage" <<<"$OUT" && pass "recipe ids bind both stages (OK)" || fail "recipe ids bind both stages (OK)" "$OUT"
cat > "$L3B/.pre-commit-config.yaml" <<'YAML'
repos:
  - repo: local
    hooks:
      - id: some-linter
        name: linter
        entry: "true"
        language: system
YAML
run_3b stages-unbound
grep -q "DRIFT scan-stage-coverage = unbound: pre-push commit-msg" <<<"$OUT" && pass "unbound stages flagged as drift" || fail "unbound stages flagged as drift" "$OUT"
cat > "$L3B/.pre-commit-config.yaml" <<'YAML'
repos:
  - repo: local
    hooks:
      - id: some-linter
        name: linter
        entry: "true"
        language: system
        # stages: [pre-push, commit-msg]
YAML
run_3b stages-commented
grep -q "DRIFT scan-stage-coverage = unbound: pre-push commit-msg" <<<"$OUT" && pass "commented-out stages line does NOT count as bound" || fail "commented-out stages line does NOT count as bound" "$OUT"

# ============================================================================
section "step 4b: stale-clone — absent ref DRIFT; ahead-only OK; behind-only OK; diverged DRIFT"
L4B="$TMP/lr-ancestry"; mklocalrepo "$L4B"
# Step 4b tests ancestry of the literal branch name `main`, but mklocalrepo
# inherits init.defaultBranch (CI's differs from a workstation's). Pin it.
git -C "$L4B" branch -M main
run_4b() { # <cap-name> — --check against $L4B, sets OUT
    OUT="$(GH="$STUB" GH_STUB_DIR="$SC_WIRED" GH_STUB_CAPTURE="$TMP/cap/$1" \
        env -u GITLEAKS_OPERATOR_RULES bash "$SCRIPT" --rules "$RULES" --check "$SLUG" "$L4B" 2>&1)"
}
run_4b ancestry-absent
grep -q "DRIFT stale-clone = refs/remotes/origin/main absent" <<<"$OUT" && pass "absent origin/main ref is drift (fail-closed)" || fail "absent origin/main ref is drift" "$OUT"
git -C "$L4B" update-ref refs/remotes/origin/main HEAD
echo x > "$L4B/x.txt"; git -C "$L4B" add x.txt; git -C "$L4B" commit -q -m ahead
run_4b ancestry-ahead
grep -q "OK    stale-clone = origin/main is an ancestor of local main" <<<"$OUT" && pass "ahead-only local main is OK" || fail "ahead-only local main is OK" "$OUT"
git -C "$L4B" update-ref refs/remotes/origin/main HEAD
git -C "$L4B" reset -q --hard HEAD~1
run_4b ancestry-behind
grep -q "OK    stale-clone = local main behind origin/main" <<<"$OUT" && pass "behind-only local main is OK (not a push hazard)" || fail "behind-only local main is OK" "$OUT"
UNREL="$(git -C "$L4B" commit-tree "$(git -C "$L4B" mktree </dev/null)" -m "unrelated root")"
git -C "$L4B" update-ref refs/remotes/origin/main "$UNREL"
run_4b ancestry-diverged
grep -q "DRIFT stale-clone = local main has diverged from origin/main" <<<"$OUT" && pass "diverged history is drift" || fail "diverged history is drift" "$OUT"

# ============================================================================
section "converge is a no-op when already wired (no write calls)"
CAP="$TMP/cap/wired-converge"
run_provision "$CAP" "$SC_WIRED" "$SLUG"
assert_eq "wired converge exits 0" "0" "$RC"
[[ ! -f "$CAP/requests.log" ]] && pass "no write requests issued" || fail "no write requests issued" "$(cat "$CAP/requests.log")"

# ============================================================================
section "converge POSTs a new ruleset when none targets the default branch"
CAP="$TMP/cap/no-ruleset-converge"
run_provision "$CAP" "$SC_NORULESET" "$SLUG"
assert_eq "no-ruleset converge exits 0" "0" "$RC"
POSTBODY="$CAP/POST_repos_acme_widgets_rulesets.body"
if [[ -f "$POSTBODY" ]]; then
    pass "ruleset POST issued"
    assert_eq "POST targets ~DEFAULT_BRANCH (rename-robust)" "~DEFAULT_BRANCH" "$(jq -r '.conditions.ref_name.include[0]' "$POSTBODY")"
    assert_eq "POST enforcement active" "active" "$(jq -r '.enforcement' "$POSTBODY")"
    assert_eq "POST pull_request review_count is 0" "0" "$(jq -r '.rules[] | select(.type=="pull_request") | .parameters.required_approving_review_count' "$POSTBODY")"
else
    fail "ruleset POST issued" "requests.log=$(cat "$CAP/requests.log" 2>/dev/null)"
fi

# ============================================================================
section "converge fixes merge-settings drift (correct PATCH body), leaves ruleset alone"
CAP="$TMP/cap/merge-converge"
run_provision "$CAP" "$SC_MERGE" "$SLUG"
assert_eq "merge-drift converge exits 0" "0" "$RC"
MB="$CAP/PATCH_repos_acme_widgets.body"
if [[ -f "$MB" ]]; then
    pass "merge PATCH issued"
    assert_eq "allow_merge_commit -> false"   "false"    "$(jq -r '.allow_merge_commit' "$MB")"
    assert_eq "allow_rebase_merge -> false"   "false"    "$(jq -r '.allow_rebase_merge' "$MB")"
    assert_eq "delete_branch_on_merge -> true" "true"    "$(jq -r '.delete_branch_on_merge' "$MB")"
    assert_eq "squash_merge_commit_title -> PR_TITLE" "PR_TITLE" "$(jq -r '.squash_merge_commit_title' "$MB")"
else
    fail "merge PATCH issued" "requests.log=$(cat "$CAP/requests.log" 2>/dev/null)"
fi
if [[ -f "$CAP/requests.log" ]] && ! grep -Eq 'rulesets' "$CAP/requests.log"; then
    pass "wired ruleset left untouched"
else
    fail "wired ruleset left untouched" "$(cat "$CAP/requests.log" 2>/dev/null)"
fi

# ============================================================================
section "converge enables secret scanning when off (correct PATCH body)"
CAP="$TMP/cap/secret-converge"
run_provision "$CAP" "$SC_SECRET" "$SLUG"
assert_eq "secret-drift converge exits 0" "0" "$RC"
SB="$CAP/PATCH_repos_acme_widgets.body"
if [[ -f "$SB" ]]; then
    pass "secret-scanning PATCH issued"
    assert_eq "secret_scanning -> enabled" "enabled" "$(jq -r '.security_and_analysis.secret_scanning.status' "$SB")"
    assert_eq "push_protection -> enabled" "enabled" "$(jq -r '.security_and_analysis.secret_scanning_push_protection.status' "$SB")"
else
    fail "secret-scanning PATCH issued" "requests.log=$(cat "$CAP/requests.log" 2>/dev/null)"
fi

# ============================================================================
section "fail-closed: a failing gh call aborts with a named step"
EMPTY="$TMP/empty"; mkdir -p "$EMPTY"
run_provision "$TMP/cap/ghfail" "$EMPTY" --check "$SLUG"
assert_eq "gh failure aborts non-zero" "1" "$RC"
grep -q "FATAL \[repo-get\]" <<<"$OUT" && pass "names the failing step + fail-closed" || fail "names the failing step" "$OUT"

# ============================================================================
section "bad arguments are rejected"
OUT="$(GH="$STUB" bash "$SCRIPT" --check 2>&1)"; RC=$?
assert_eq "missing owner/repo exits 2" "2" "$RC"
OUT="$(GH="$STUB" bash "$SCRIPT" --check not-a-slug 2>&1)"; RC=$?
assert_eq "malformed slug exits 2" "2" "$RC"
OUT="$(GH="$STUB" bash "$SCRIPT" --rules 2>&1)"; RC=$?
assert_eq "--rules with no value exits 2" "2" "$RC"

finish
