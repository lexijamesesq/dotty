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

# Hermetic git config (enrollment hygiene): the scratch repos this suite
# `git init`s must NOT inherit this machine's global/system git config. On an
# ENROLLED estate machine the global config sets `init.templateDir`
# (~/.config/claude-estate/git-template), which injects the estate hooks into
# every new repo — so the "missing pre-commit hooks" fixture below would come
# up already carrying them and the drift assertion would spuriously fail. Pin
# both to /dev/null so `git init` sees an empty template, exactly as CI does.
# (Same class of isolation as EMPTYXDG below, for the git layer.)
export GIT_CONFIG_GLOBAL=/dev/null
export GIT_CONFIG_SYSTEM=/dev/null

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
# GET reads from $GH_STUB_DIR (canned, immutable fixtures) UNLESS a "live"
# override exists in $GH_STUB_CAPTURE — written by a prior POST/PUT in the
# SAME invocation, so ruleset_write_verify's own read-back-after-write is a
# real round trip rather than a fixed fixture. Fixtures are never mutated, so
# a scenario dir is reusable across multiple test invocations.
STUB="$TMP/bin/gh"
mkdir -p "$TMP/bin"
cat > "$STUB" <<'STUBEOF'
#!/usr/bin/env bash
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
path="${endpoint%%\?*}"

if [[ "$method" != GET ]]; then
    body=""
    [[ $read_stdin -eq 1 ]] && body="$(cat)"
    mkdir -p "${GH_STUB_CAPTURE:-/dev/null}" 2>/dev/null || true
    if [[ -n "${GH_STUB_CAPTURE:-}" ]]; then
        printf '%s %s\n' "$method" "$path" >> "$GH_STUB_CAPTURE/requests.log"
        printf '%s' "$body" > "$GH_STUB_CAPTURE/${method}_${path//\//_}.body"
    fi
    # Self-consistent echo for ruleset writes: a subsequent GET in this same
    # invocation (ruleset_write_verify's own read-back) sees exactly what was
    # written, with an id assigned/preserved — never a fixed fixture. GitHub
    # itself attaches extra pull_request defaults on a rule that didn't
    # already carry them (observed live on `hazel`'s first-ever pull_request
    # rule creation) — the stub reproduces that here so a regression is
    # caught in tests, not just in production.
    IFS='/' read -r -a wseg <<< "$path"
    wrest="$(IFS=/; echo "${wseg[*]:3}")"
    attach_gh_defaults() {
        jq '.rules |= map(
            if .type == "pull_request" then
                .parameters = ({
                    allowed_merge_methods: ["merge","squash","rebase"],
                    required_reviewers: [],
                    require_extra_approval_for_unattributed_changes: true
                } + .parameters)
            else . end
        )'
    }
    case "$wrest" in
        rulesets)
            ctr="$GH_STUB_CAPTURE/.next-id"
            id=9001; [[ -f "$ctr" ]] && id="$(cat "$ctr")"
            echo $((id + 1)) > "$ctr"
            echo "$body" | jq --argjson id "$id" '. + {id: $id}' | attach_gh_defaults > "$GH_STUB_CAPTURE/live-ruleset-$id.json"
            jq -n --argjson id "$id" '{id: $id}'
            exit 0
            ;;
        rulesets/*)
            id="${wrest#rulesets/}"
            echo "$body" | jq --argjson id "$id" '. + {id: $id}' | attach_gh_defaults > "$GH_STUB_CAPTURE/live-ruleset-$id.json"
            echo '{}'
            exit 0
            ;;
        *)
            echo '{}'
            exit 0
            ;;
    esac
fi

# GET: live override first (this invocation's own prior write), then the
# canned fixture, then a canned "not found" for the live-lookup endpoints
# (recent-pr / check-runs) so a scenario that doesn't stub one gets an empty
# result rather than a hard stub error.
IFS='/' read -r -a seg <<< "$path"
rest="$(IFS=/; echo "${seg[*]:3}")"
case "$rest" in
    "")                  f="repo.json" ;;
    "rulesets")          f="rulesets.json" ;;
    rulesets/*)          f="ruleset-${rest#rulesets/}.json" ;;
    "pulls")             f="recent-pr.json" ;;
    commits/*/check-runs) f="check-runs-${rest#commits/}"; f="${f%/check-runs}.json" ;;
    "git/matching-refs/tags") f="git-matching-refs-tags.json" ;;
    git/tags/*)          f="git-tag-${rest#git/tags/}.json" ;;
    "git/refs/heads/main") f="git-refs-heads-main.json" ;;
    "releases/latest")   f="releases-latest.json" ;;
    "tags")              f="tags.json" ;;
    contents/*)          cpath="${rest#contents/}"; f="contents-${cpath//\//_}.json" ;;
    compare/*)           cpath="${rest#compare/}"; f="compare-${cpath//\//_}.json" ;;
    "environments/default-branch") f="environments-default-branch.json" ;;
    "environments/default-branch/secrets") f="environment-secrets-default-branch.json" ;;
    "actions/permissions/workflow") f="actions-permissions-workflow.json" ;;
    "keys")              f="keys.json" ;;
    *)                   f="" ;;
esac
# The mechanical drift classes below read a SECOND repo in the same
# invocation (dotty upstream, or core-skills for the fork-check class) — the
# "rest" shape alone collides with the target repo's own identically-shaped
# endpoint (e.g. both call "tags" / "contents/..."), so any repo other than
# the suite's fixed target slug gets its fixtures prefixed by its own
# sanitized owner-repo, keeping the two fixture sets disjoint without
# touching any pre-existing (target-repo-only) fixture file name.
if [[ -n "$f" && "${seg[1]:-}/${seg[2]:-}" != "acme/widgets" ]]; then
    f="${seg[1]:-}-${seg[2]:-}-${f}"
fi
if [[ "$rest" == rulesets/* && -n "${GH_STUB_CAPTURE:-}" && -f "$GH_STUB_CAPTURE/live-${f}" ]]; then
    cat "$GH_STUB_CAPTURE/live-${f}"
    exit 0
fi
if [[ -n "$f" && -f "${GH_STUB_DIR:-}/$f" ]]; then
    body="$(cat "${GH_STUB_DIR}/$f")"
    printf '%s' "$body"
    # Replicate real `gh api`: an error response (a GitHub error object carrying
    # a 4xx/5xx .status) is written to STDOUT and gh exits NON-ZERO. Fixtures
    # for the "not readable under current scope" (403) paths carry such a body,
    # so the suite exercises the real 403-body-on-stdout shape rather than a
    # clean empty fallback — the exact shape that made the == null guard miss.
    if printf '%s' "$body" | jq -e '(.message? != null) and ((.status? // "") | test("^[45]"))' >/dev/null 2>&1; then
        exit 1
    fi
    exit 0
fi
if [[ "$rest" == "pulls" ]]; then echo '[]'; exit 0; fi
if [[ "$rest" == commits/*/check-runs ]]; then echo '{"check_runs":[]}'; exit 0; fi
if [[ "$rest" == "git/matching-refs/tags" ]]; then echo '[]'; exit 0; fi
echo "STUB: no canned GET response for '$endpoint' (rest='$rest', file='$f')" >&2
exit 92
STUBEOF
chmod +x "$STUB"

# --- Scenario builders -------------------------------------------------------
SCEN="$TMP/scenarios"

# repo.json writer. $1=dir $2=default_branch $3=merge(good|bad) $4=secret(on|off)
write_repo() {
    local dir="$1" branch="$2" merge="$3" secret="$4"
    local amc dbm sct scm ss pp aam aub
    if [[ "$merge" == good ]]; then
        amc=false; dbm=true; sct="PR_TITLE"; scm="PR_BODY"; aam=true;  aub=true
    else
        amc=true;  dbm=false; sct="COMMIT_OR_PR_TITLE"; scm="COMMIT_MESSAGES"; aam=false; aub=false
    fi
    if [[ "$secret" == on ]]; then ss=enabled; pp=enabled; else ss=disabled; pp=disabled; fi
    mkdir -p "$dir"
    jq -n \
        --arg branch "$branch" --argjson amc "$amc" --argjson dbm "$dbm" \
        --argjson aam "$aam" --argjson aub "$aub" \
        --arg sct "$sct" --arg scm "$scm" --arg ss "$ss" --arg pp "$pp" '{
            default_branch: $branch,
            allow_squash_merge: true,
            allow_merge_commit: $amc,
            allow_rebase_merge: false,
            delete_branch_on_merge: $dbm,
            allow_auto_merge: $aam,
            allow_update_branch: $aub,
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
                rules="$(jq -c --argjson r "$rules" '$r + [{type:"pull_request", parameters:{required_approving_review_count:0, dismiss_stale_reviews_on_push:true, require_code_owner_review:true, require_last_push_approval:false, required_review_thread_resolution:false, require_extra_approval_for_unattributed_changes:true}}]' <<<'null')" ;;
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

# add_tag_ruleset <dir> <id> <state> — appends a tag ruleset to the SAME
# scenario dir's rulesets.json (branch ruleset must already be written by
# write_ruleset first). state=ok writes the exact declared shape (name "Tag
# immutability", update+deletion, no bypass) so "fully wired" scenarios stay
# fully wired; state=drift writes a wrong shape (creation present, a bypass
# actor) for convergence tests.
add_tag_ruleset() {
    local dir="$1" id="$2" state="$3" rules bypass
    if [[ "$state" == ok ]]; then
        rules='[{"type":"update"},{"type":"deletion"}]'
        bypass='[]'
    else
        rules='[{"type":"creation"},{"type":"update"}]'
        bypass='[{"actor_id":1,"actor_type":"RepositoryRole","bypass_mode":"always"}]'
    fi
    jq --argjson id "$id" '. + [{id:$id, name:"Tag immutability", target:"tag"}]' \
        "$dir/rulesets.json" > "$dir/rulesets.json.tmp" && mv "$dir/rulesets.json.tmp" "$dir/rulesets.json"
    jq -n --argjson id "$id" --argjson rules "$rules" --argjson bypass "$bypass" '{
        id: $id, name: "Tag immutability", target: "tag", enforcement: "active",
        bypass_actors: $bypass,
        conditions: { ref_name: { include: ["refs/tags/*"], exclude: [] } },
        rules: $rules
    }' > "$dir/ruleset-$id.json"
}

# write_reporter <dir> <sha> <context> <app_id> — cans a merged-PR head sha
# and a check-run reporting <context> from <app_id>, for resolve_context_
# reporter to find live.
write_reporter() {
    local dir="$1" sha="$2" ctx="$3" app_id="$4"
    jq -n --arg sha "$sha" '[{merged_at: "2026-01-01T00:00:00Z", head: {sha: $sha}}]' > "$dir/recent-pr.json"
    jq -n --arg ctx "$ctx" --argjson app_id "$app_id" \
        '{check_runs: [{name: $ctx, app: {id: $app_id, slug: "github-actions"}}]}' > "$dir/check-runs-$sha.json"
}

# --- Mechanical-drift-class fixture helpers ----------------------------------
# write_contents <dir> <api-path> <text> — a contents-API GET fixture (base64
# content, matching the stub's "contents/<path>" -> "contents-<path_>.json"
# naming, slashes replaced with underscores same as the stub does).
write_contents() {
    local dir="$1" api_path="$2" text="$3" safe
    mkdir -p "$dir"
    safe="${api_path//\//_}"
    jq -n --arg c "$(printf '%s' "$text" | base64 | tr -d '\n')" '{content: $c, encoding: "base64"}' \
        > "$dir/contents-${safe}.json"
}

# write_403 <dir> <fixture-file> — a GitHub "Resource not accessible by
# integration" error object written to the named stub fixture. The stub emits
# it on STDOUT and exits non-zero, replicating how real `gh api` returns a 403
# (body on stdout, non-zero exit) — the exact shape a `== "null"` guard misses
# (it captures "{…403…}" + the fallback, never == "null", then parses the error
# object as data and false-DRIFTs). The readability guards must gate on the
# EXPECTED SHAPE and SKIP instead.
write_403() {
    mkdir -p "$1"
    jq -n '{message:"Resource not accessible by integration", documentation_url:"https://docs.github.com/rest", status:"403"}' \
        > "$1/$2"
}

# write_dotty_tags <dir> <tag-names-json-array> — the dotty upstream repo's
# own /tags fixture. Repo-prefixed per the stub's cross-repo disambiguation
# (dotty != acme/widgets). dotty_latest_tag no longer reads element 0 — it
# derives the latest from releases/latest (write_dotty_release) and only falls
# back to a CalVer-numeric sort of THIS list when no release is stubbed.
write_dotty_tags() {
    local dir="$1" names="$2"
    mkdir -p "$dir"
    jq -n --argjson names "$names" '[$names[] | {name: ., commit: {sha: ("sha-" + .)}}]' \
        > "$dir/lexijamesesq-dotty-tags.json"
}

# write_dotty_release <dir> <tag> — dotty's repos/dotty/releases/latest fixture
# (what release-dotty publishes; dotty_latest_tag's authoritative source).
write_dotty_release() {
    local dir="$1" tag="$2"
    mkdir -p "$dir"
    jq -n --arg t "$tag" '{tag_name: $t}' > "$dir/lexijamesesq-dotty-releases-latest.json"
}

# write_dotty_compare <dir> <base> <head> <status> — a dotty-upstream compare
# fixture for classify_dotty_pin / the setup-gitleaks and pre-commit-pin
# classes. status is one of identical/ahead/behind/diverged.
write_dotty_compare() {
    local dir="$1" base="$2" head="$3" status="$4"
    mkdir -p "$dir"
    jq -n --arg s "$status" '{status: $s}' \
        > "$dir/lexijamesesq-dotty-compare-${base}...${head}.json"
}

# write_core_call_ok <dir> [ref] — ci.yml + gate.yml content that calls the
# estate core (missing-core-call: OK) and carries no work-lifecycle reference
# (work-lifecycle-refs: OK). No dotty-tags/compare fixture is written here —
# caller-pin classification and the setup-gitleaks pin therefore SKIP
# ("dotty's tag list unreadable"), never DRIFT, for any scenario that uses
# this helper without ALSO calling write_dotty_tags (§ the four "must stay
# fully-wired" scenarios below never do).
write_core_call_ok() {
    local dir="$1" ref="${2:-v2026.01.01-1}"
    mkdir -p "$dir"
    write_contents "$dir" ".github/workflows/ci.yml" \
        "jobs:
  estate-ci:
    uses: lexijamesesq/dotty/.github/workflows/estate-ci.yml@${ref}
    with:
      dotty_ref: ${ref}
"
    write_contents "$dir" ".github/workflows/gate.yml" \
        "jobs:
  estate-gate:
    uses: lexijamesesq/dotty/.github/workflows/estate-gate.yml@${ref}
    with:
      dotty_ref: ${ref}
"
}

# 1. wired — everything correct.
SC_WIRED="$SCEN/wired"
write_repo "$SC_WIRED" main good on
write_ruleset "$SC_WIRED" 1 main "non_fast_forward,deletion,pull_request"
add_tag_ruleset "$SC_WIRED" 2 ok
write_core_call_ok "$SC_WIRED"

# 2. missing-pr — wired except the ruleset lacks pull_request.
SC_MPR="$SCEN/missing-pr"
write_repo "$SC_MPR" main good on
write_ruleset "$SC_MPR" 1 main "non_fast_forward,deletion"

# 3. dotty-shape — ruleset carries required_status_checks but no pull_request.
# Its "eval-suite" context has a live reporter fixture so convergence proves
# the strict flag AND the integration_id bind together.
SC_DOTTY="$SCEN/dotty-shape"
write_repo "$SC_DOTTY" main good on
write_ruleset "$SC_DOTTY" 1 main "non_fast_forward,deletion,required_status_checks"
write_reporter "$SC_DOTTY" "deadbeef01" "eval-suite" 15368

# 4. master — default branch is master; fully wired for master.
SC_MASTER="$SCEN/master"
write_repo "$SC_MASTER" master good on
write_ruleset "$SC_MASTER" 7 master "non_fast_forward,deletion,pull_request"
add_tag_ruleset "$SC_MASTER" 8 ok
write_core_call_ok "$SC_MASTER"

# 5. no-ruleset — no rulesets exist at all.
SC_NORULESET="$SCEN/no-ruleset"
write_repo "$SC_NORULESET" main good on
mkdir -p "$SC_NORULESET"
echo '[]' > "$SC_NORULESET/rulesets.json"

# 6. merge-drift — merge settings wrong; ruleset + secret fine.
SC_MERGE="$SCEN/merge-drift"
write_repo "$SC_MERGE" main bad on
write_ruleset "$SC_MERGE" 1 main "non_fast_forward,deletion,pull_request"
add_tag_ruleset "$SC_MERGE" 2 ok

# 7. secret-drift — secret scanning off; merge + ruleset fine.
SC_SECRET="$SCEN/secret-drift"
write_repo "$SC_SECRET" main good off
write_ruleset "$SC_SECRET" 1 main "non_fast_forward,deletion,pull_request"
add_tag_ruleset "$SC_SECRET" 2 ok

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
write_reporter "$SC_PRCOUNT" "deadbeef03" "eval-suite" 15368
add_tag_ruleset "$SC_PRCOUNT" 6 ok

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
    {"type": "pull_request", "parameters": {"required_approving_review_count": 0, "dismiss_stale_reviews_on_push": true, "require_code_owner_review": true, "require_last_push_approval": false, "required_review_thread_resolution": false, "require_extra_approval_for_unattributed_changes": true, "allowed_merge_methods": ["squash"], "automatic_copilot_code_review_enabled": false}}
  ]
}
EOF
add_tag_ruleset "$SC_PREXTRA" 5 ok
write_core_call_ok "$SC_PREXTRA"

# 14. bare-required-checks — a ruleset with ONLY required_status_checks (no
#     non_fast_forward, deletion, or pull_request at all) — the exact live
#     shape `hazel` carried before its first-ever provisioner run. Converging
#     must create all three owned rules AND survive GitHub attaching its own
#     defaults to the freshly-created pull_request rule (the stub's
#     attach_gh_defaults reproduces exactly the mismatch that FATAL'd in
#     production before ruleset_matches_intent replaced strict equality).
SC_BARERSC="$SCEN/bare-required-checks"
write_repo "$SC_BARERSC" main good on
write_ruleset "$SC_BARERSC" 1 main "required_status_checks"
write_reporter "$SC_BARERSC" "deadbeef14" "eval-suite" 15368
add_tag_ruleset "$SC_BARERSC" 2 ok

# 10. tag-missing — branch ruleset fully wired, no tag ruleset at all.
SC_TAGMISS="$SCEN/tag-missing"
write_repo "$SC_TAGMISS" main good on
write_ruleset "$SC_TAGMISS" 1 main "non_fast_forward,deletion,pull_request"

# 11. tag-drift — tag ruleset present but wrong shape (creation present,
#     a bypass actor) — must converge to update+deletion, no bypass.
SC_TAGDRIFT="$SCEN/tag-drift"
write_repo "$SC_TAGDRIFT" main good on
write_ruleset "$SC_TAGDRIFT" 1 main "non_fast_forward,deletion,pull_request"
add_tag_ruleset "$SC_TAGDRIFT" 2 drift

# 12. strict-unbound — required_status_checks present, strict false, two
#     contexts: one with a live reporter (binds), one with none (dropped).
SC_STRICTUNBOUND="$SCEN/strict-unbound"
write_repo "$SC_STRICTUNBOUND" main good on
mkdir -p "$SC_STRICTUNBOUND"
echo '[{"id":9,"name":"Protect main","target":"branch"}]' > "$SC_STRICTUNBOUND/rulesets.json"
cat > "$SC_STRICTUNBOUND/ruleset-9.json" <<'EOF'
{
  "id": 9, "name": "Protect main", "target": "branch", "enforcement": "active",
  "bypass_actors": [],
  "conditions": {"ref_name": {"include": ["refs/heads/main"], "exclude": []}},
  "rules": [
    {"type": "non_fast_forward"},
    {"type": "deletion"},
    {"type": "pull_request", "parameters": {"required_approving_review_count": 0, "dismiss_stale_reviews_on_push": false, "require_code_owner_review": false, "require_last_push_approval": false, "required_review_thread_resolution": false}},
    {"type": "required_status_checks", "parameters": {"strict_required_status_checks_policy": false, "required_status_checks": [{"context": "shellcheck"}, {"context": "ghost-check"}]}}
  ]
}
EOF
write_reporter "$SC_STRICTUNBOUND" "deadbeef09" "shellcheck" 15368
add_tag_ruleset "$SC_STRICTUNBOUND" 10 ok

# 13. private — a private repo. Secret scanning steps must be SKIPPED
#     (never DRIFT, never a PATCH), everything else applies normally.
SC_PRIVATE="$SCEN/private"
mkdir -p "$SC_PRIVATE"
jq -n '{
    default_branch: "main", allow_squash_merge: true, allow_merge_commit: false,
    allow_rebase_merge: false, delete_branch_on_merge: true,
    allow_auto_merge: true, allow_update_branch: true,
    squash_merge_commit_title: "PR_TITLE", squash_merge_commit_message: "PR_BODY",
    private: true
}' > "$SC_PRIVATE/repo.json"
write_ruleset "$SC_PRIVATE" 1 main "non_fast_forward,deletion,pull_request"
add_tag_ruleset "$SC_PRIVATE" 2 ok
write_core_call_ok "$SC_PRIVATE"

# --- Local-repo + script-copy helpers ----------------------------------------
mklocalrepo() { # <dir>  — a git work tree with a tracked .gitleaks.toml
    git init -q "$1"
    assert_repo_identity "$1"
    git -C "$1" config user.email "test@example.com"
    git -C "$1" config user.name "Test Runner"
    git -C "$1" config commit.gpgsign false
    printf 'title = "fixture"\n' > "$1/.gitleaks.toml"
    git -C "$1" add .gitleaks.toml
    git -C "$1" commit -q -m "add gitleaks config"
}
mkbaregit() { # <dir> — a git work tree WITHOUT a tracked .gitleaks.toml
    git init -q "$1"
    assert_repo_identity "$1"
    git -C "$1" config user.email "test@example.com"
    git -C "$1" config user.name "Test Runner"
    git -C "$1" config commit.gpgsign false
}
mkcopy() { # <dir> -> path to a copy of the script (+ its declared JSON) placed there
    mkdir -p "$1"
    cp "$SCRIPT" "$1/provision-public-repo.sh"
    chmod +x "$1/provision-public-repo.sh"
    mkdir -p "$1/rulesets"
    cp "$SCRIPT_DIR/../../rulesets/default-branch.json" "$1/rulesets/default-branch.json"
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
    assert_eq "strict_required_status_checks_policy forced true" "true" \
        "$(jq -r '.rules[] | select(.type=="required_status_checks") | .parameters.strict_required_status_checks_policy' "$PUTBODY")"
    assert_eq "eval-suite bound to its live-verified reporter (15368)" "15368" \
        "$(jq -r '.rules[] | select(.type=="required_status_checks") | .parameters.required_status_checks[] | select(.context=="eval-suite") | .integration_id' "$PUTBODY")"
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
# Two POSTs hit the identical endpoint this run (branch ruleset, then the
# tag ruleset) — the generic body-capture file only keeps the last one, so
# identify the branch write by content among the id-keyed live files instead.
POSTBODY=""
for f in "$CAP"/live-ruleset-*.json; do
    [[ -f "$f" ]] || continue
    [[ "$(jq -r '.target' "$f" 2>/dev/null)" == "branch" ]] && { POSTBODY="$f"; break; }
done
if [[ -n "$POSTBODY" && -f "$POSTBODY" ]]; then
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
    assert_eq "allow_auto_merge -> true"      "true"     "$(jq -r '.allow_auto_merge' "$MB")"
    assert_eq "allow_update_branch -> true"   "true"     "$(jq -r '.allow_update_branch' "$MB")"
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
section "tag ruleset: --check flags absence as drift; converge creates the declared shape"
run_provision "$TMP/cap/tagmiss-check" "$SC_TAGMISS" --check "$SLUG"
assert_eq "tag-missing --check exits 1" "1" "$RC"
grep -q "DRIFT tag-ruleset = absent" <<<"$OUT" && pass "flags tag-ruleset absence as drift" || fail "flags tag-ruleset absence" "$OUT"

CAP="$TMP/cap/tagmiss-converge"
run_provision "$CAP" "$SC_TAGMISS" "$SLUG"
assert_eq "tag-missing converge exits 0" "0" "$RC"
TAGPOST="$CAP/POST_repos_acme_widgets_rulesets.body"
if [[ -f "$TAGPOST" ]]; then
    pass "tag-ruleset POST issued"
    assert_eq "POST name is the declared name" "Tag immutability" "$(jq -r '.name' "$TAGPOST")"
    assert_eq "POST target is tag"             "tag"              "$(jq -r '.target' "$TAGPOST")"
    assert_eq "POST bypass_actors empty"       "[]"               "$(jq -c '.bypass_actors' "$TAGPOST")"
    jq -e '.rules == [{"type":"update"},{"type":"deletion"}]' "$TAGPOST" >/dev/null 2>&1 \
        && pass "POST rules are exactly update+deletion (no creation)" \
        || fail "POST rules are exactly update+deletion" "$(jq -c '.rules' "$TAGPOST")"
else
    fail "tag-ruleset POST issued" "requests.log=$(cat "$CAP/requests.log" 2>/dev/null)"
fi

# ============================================================================
section "tag ruleset: converge fixes a wrong shape (drops creation, clears bypass)"
CAP="$TMP/cap/tagdrift-converge"
run_provision "$CAP" "$SC_TAGDRIFT" "$SLUG"
assert_eq "tag-drift converge exits 0" "0" "$RC"
TAGPUT="$CAP/PUT_repos_acme_widgets_rulesets_2.body"
if [[ -f "$TAGPUT" ]]; then
    pass "tag-ruleset PUT issued"
    jq -e '.rules == [{"type":"update"},{"type":"deletion"}]' "$TAGPUT" >/dev/null 2>&1 \
        && pass "creation rule dropped, update+deletion only" \
        || fail "creation rule dropped" "$(jq -c '.rules' "$TAGPUT")"
    assert_eq "bypass_actors cleared" "[]" "$(jq -c '.bypass_actors' "$TAGPUT")"
else
    fail "tag-ruleset PUT issued" "requests.log=$(cat "$CAP/requests.log" 2>/dev/null)"
fi

# ============================================================================
section "required_status_checks: strict forced true; live-verified context bound, unreachable context dropped"
run_provision "$TMP/cap/strictunbound-check" "$SC_STRICTUNBOUND" --check "$SLUG"
assert_eq "strict-unbound --check exits 1" "1" "$RC"
grep -q "DRIFT rule.required_status_checks.strict = false" <<<"$OUT" && pass "flags strict=false as drift" || fail "flags strict=false" "$OUT"
grep -q "DRIFT rule.required_status_checks.context\[ghost-check\]" <<<"$OUT" && pass "flags the unreachable context, names it dropped-not-bound" || fail "flags the unreachable context" "$OUT"

CAP="$TMP/cap/strictunbound-converge"
run_provision "$CAP" "$SC_STRICTUNBOUND" "$SLUG"
assert_eq "strict-unbound converge exits 0" "0" "$RC"
SUPUT="$CAP/PUT_repos_acme_widgets_rulesets_9.body"
if [[ -f "$SUPUT" ]]; then
    pass "ruleset PUT issued"
    assert_eq "strict forced true" "true" "$(jq -r '.rules[] | select(.type=="required_status_checks") | .parameters.strict_required_status_checks_policy' "$SUPUT")"
    assert_eq "shellcheck bound to its live reporter" "15368" \
        "$(jq -r '.rules[] | select(.type=="required_status_checks") | .parameters.required_status_checks[] | select(.context=="shellcheck") | .integration_id' "$SUPUT")"
    jq -e '.rules[] | select(.type=="required_status_checks") | .parameters.required_status_checks | map(.context) | index("ghost-check") == null' "$SUPUT" >/dev/null 2>&1 \
        && pass "unreachable context dropped from the array entirely (never bound blind)" \
        || fail "unreachable context dropped" "$(jq -c '.rules[] | select(.type=="required_status_checks")' "$SUPUT")"
else
    fail "ruleset PUT issued" "requests.log=$(cat "$CAP/requests.log" 2>/dev/null)"
fi

# ============================================================================
section "visibility: a private repo skips secret-scanning entirely (never drift, never a write)"
run_provision "$TMP/cap/private-check" "$SC_PRIVATE" --check "$SLUG"
assert_eq "private --check exits 0 (nothing else drifts)" "0" "$RC"
grep -q "SKIP  secret_scanning" <<<"$OUT" && pass "reports secret_scanning as SKIP, not DRIFT" || fail "reports secret_scanning as SKIP" "$OUT"
grep -q "SKIP  secret_scanning_push_protection" <<<"$OUT" && pass "reports push_protection as SKIP, not DRIFT" || fail "reports push_protection as SKIP" "$OUT"
grep -qi "DRIFT secret" <<<"$OUT" && fail "no secret-scanning DRIFT line on a private repo" "$OUT" || pass "no secret-scanning DRIFT line on a private repo"

CAP="$TMP/cap/private-converge"
run_provision "$CAP" "$SC_PRIVATE" "$SLUG"
assert_eq "private converge exits 0" "0" "$RC"
if [[ -f "$CAP/requests.log" ]] && grep -q 'PATCH repos/acme/widgets$' "$CAP/requests.log"; then
    fail "no security_and_analysis PATCH issued on a private repo" "$(cat "$CAP/requests.log")"
else
    pass "no security_and_analysis PATCH issued on a private repo"
fi

# ============================================================================
section "bare-required-checks: converging a hazel-shaped ruleset survives GitHub's own defaults on the fresh pull_request rule"
run_provision "$TMP/cap/barersc-check" "$SC_BARERSC" --check "$SLUG"
assert_eq "bare-required-checks --check exits 1" "1" "$RC"
grep -q "DRIFT rule.non_fast_forward = absent" <<<"$OUT" && pass "flags missing non_fast_forward" || fail "flags missing non_fast_forward" "$OUT"
grep -q "DRIFT rule.deletion = absent" <<<"$OUT" && pass "flags missing deletion" || fail "flags missing deletion" "$OUT"
grep -q "DRIFT rule.pull_request = absent" <<<"$OUT" && pass "flags missing pull_request" || fail "flags missing pull_request" "$OUT"

CAP="$TMP/cap/barersc-converge"
run_provision "$CAP" "$SC_BARERSC" "$SLUG"
assert_eq "bare-required-checks converge exits 0 (does not FATAL on GitHub's attached defaults)" "0" "$RC"
grep -q "FATAL" <<<"$OUT" && fail "no FATAL from the read-back verification" "$OUT" || pass "no FATAL from the read-back verification"
BRPUT="$CAP/PUT_repos_acme_widgets_rulesets_1.body"
if [[ -f "$BRPUT" ]]; then
    pass "ruleset PUT issued"
    jq -e '.rules | map(.type) | index("non_fast_forward") != null and index("deletion") != null and index("pull_request") != null' "$BRPUT" >/dev/null 2>&1 \
        && pass "all three owned rules added" || fail "all three owned rules added" "$(jq -c '.rules | map(.type)' "$BRPUT")"
    assert_eq "eval-suite bound to its live reporter" "15368" \
        "$(jq -r '.rules[] | select(.type=="required_status_checks") | .parameters.required_status_checks[] | select(.context=="eval-suite") | .integration_id' "$BRPUT")"
else
    fail "ruleset PUT issued" "requests.log=$(cat "$CAP/requests.log" 2>/dev/null)"
fi
# Steady state — a pull_request rule already at intended values plus
# GitHub's own extra keys — is covered separately by the pr-extra scenario
# above ("no drift when owned params match despite extras").

# ============================================================================
# § REPO CONTEXT DECLARATIONS — .repos["<slug>"].required_contexts, additive
# per-repo migration (the estate CI/CD rollout). A custom --declared-json per
# scenario below; each carries the same .pull_request/.required_status_checks/
# .tag_ruleset the default file does (the loader FATALs without them) plus a
# .repos entry for $SLUG.
mk_declared_json() { # <path> <required_contexts-json-array>
    jq -n --argjson rc "$2" --arg slug "$SLUG" '{
        pull_request: {required_approving_review_count:0, dismiss_stale_reviews_on_push:true, require_code_owner_review:true, require_last_push_approval:false, required_review_thread_resolution:false, require_extra_approval_for_unattributed_changes:true},
        required_status_checks: {strict_required_status_checks_policy: true},
        tag_ruleset: {name: "Tag immutability", rules: ["update","deletion"]},
        repos: {($slug): {required_contexts: $rc}}
    }' > "$1"
}

# mk_declared_repo_json <path> <repos-slug-object-json> — like mk_declared_json
# above, but the caller supplies the WHOLE `.repos[$SLUG]` object (the
# mechanical classes: core_call_exempt / private_repo / admin_exceptions /
# deploy_keys_allow — never all of them at once, so a fixed shape doesn't fit).
mk_declared_repo_json() {
    jq -n --argjson robj "$2" --arg slug "$SLUG" '{
        pull_request: {required_approving_review_count:0, dismiss_stale_reviews_on_push:true, require_code_owner_review:true, require_last_push_approval:false, required_review_thread_resolution:false, require_extra_approval_for_unattributed_changes:true},
        required_status_checks: {strict_required_status_checks_policy: true},
        tag_ruleset: {name: "Tag immutability", rules: ["update","deletion"]},
        repos: {($slug): $robj}
    }' > "$1"
}

# mk_declared_codeowners <path> <default-owner|""> <appendix-json|"absent"> —
# a declared JSON for the codeowners-policy class, which reads BOTH a top-level
# key and a per-repo key. Pass "" for the owner to OMIT .codeowners_default_owner
# (the no-policy skip); pass "absent" for the appendix to OMIT
# .repos[$SLUG].codeowners_appendix (the per-repo skip). Otherwise the appendix
# is a JSON array of the allowed ownerless patterns.
mk_declared_codeowners() {
    local path="$1" owner="$2" appendix="$3" robj='{}'
    if [[ "$appendix" != "absent" ]]; then
        robj="$(jq -n --argjson a "$appendix" '{codeowners_appendix: $a}')"
    fi
    jq -n --argjson robj "$robj" --arg slug "$SLUG" --arg owner "$owner" '{
        pull_request: {required_approving_review_count:0, dismiss_stale_reviews_on_push:true, require_code_owner_review:true, require_last_push_approval:false, required_review_thread_resolution:false, require_extra_approval_for_unattributed_changes:true},
        required_status_checks: {strict_required_status_checks_policy: true},
        tag_ruleset: {name: "Tag immutability", rules: ["update","deletion"]},
        repos: {($slug): $robj}
    }
    | if $owner == "" then . else .codeowners_default_owner = $owner end' > "$path"
}

# mk_license_repo <dir> <private:true|false> <license:mit|none> — a minimal repo
# whose repos/<repo> metadata carries an explicit .private and GitHub's own
# .license field (the license-presence class reads both). write_repo's plain
# repo.json omits both, which is itself the "visibility unreadable -> SKIP" case.
mk_license_repo() {
    local dir="$1" priv="$2" lic="$3" licval='null'
    write_repo "$dir" main good on
    echo '[]' > "$dir/rulesets.json"
    [[ "$lic" == "mit" ]] && licval='{"spdx_id":"MIT","name":"MIT License"}'
    jq --argjson p "$priv" --argjson l "$licval" '.private=$p | .license=$l' \
        "$dir/repo.json" > "$dir/repo.json.tmp" && mv "$dir/repo.json.tmp" "$dir/repo.json"
}

# mk_minimal_repo <dir> — just enough for process_remote to complete without
# FATAL (repo.json + an empty rulesets.json) so drift_check_extras is
# reachable for a class-specific fixture test. The branch/tag ruleset will
# themselves report DRIFT (absent) in this shape — irrelevant noise for these
# sections, which assert only their own class's line.
mk_minimal_repo() {
    local dir="$1"
    write_repo "$dir" main good on
    echo '[]' > "$dir/rulesets.json"
}

# write_core_skills_content <dir> <api-path> <text> — core-skills' canonical
# copy of a shared script (check-plugin-version-fork), repo-prefixed like the
# write_dotty_* helpers above (core-skills != acme/widgets).
write_core_skills_content() {
    local dir="$1" api_path="$2" text="$3" safe
    mkdir -p "$dir"
    safe="${api_path//\//_}"
    jq -n --arg c "$(printf '%s' "$text" | base64 | tr -d '\n')" '{content: $c, encoding: "base64"}' \
        > "$dir/lexijamesesq-core-skills-contents-${safe}.json"
}

section "context-list: declared context with a live reporter is ADDED and bound"
SC_CTXADD="$SCEN/ctx-add"
write_repo "$SC_CTXADD" main good on
write_ruleset "$SC_CTXADD" 1 main "non_fast_forward,deletion,pull_request,required_status_checks"
# Both eval-suite (the pre-existing declared context, already in the
# ruleset but with no integration_id per write_ruleset's own fixture shape)
# and new-check (the one being added) must resolve via the SAME merged-PR
# head commit here -- write_reporter only models one recent-pr.json / one
# context per call, so both check runs are written directly onto the one
# sha it also uses, rather than calling it twice (which would overwrite
# recent-pr.json and leave only the second call's context resolvable).
write_reporter "$SC_CTXADD" "addsha01" "new-check" 15368
jq -n '{check_runs: [
    {name: "new-check", app: {id: 15368, slug: "github-actions"}},
    {name: "eval-suite", app: {id: 15368, slug: "github-actions"}}
]}' > "$SC_CTXADD/check-runs-addsha01.json"
add_tag_ruleset "$SC_CTXADD" 2 ok
DJ_ADD="$TMP/declared-add.json"
mk_declared_json "$DJ_ADD" '["eval-suite","new-check"]'

run_provision "$TMP/cap/ctxadd-check" "$SC_CTXADD" --check --declared-json "$DJ_ADD" "$SLUG"
assert_eq "ctx-add --check exits 1 (list drift)" "1" "$RC"
grep -q "DRIFT rule.required_status_checks.context-list\[+new-check\]" <<<"$OUT" && pass "flags the missing declared context as drift" || fail "flags missing declared context" "$OUT"
# --check must NOT print a contradictory "matches declared" line alongside the drifts.
grep -q "matches declared" <<<"$OUT" && fail "no false 'matches declared' when --check found drifts" "$OUT" || pass "no false 'matches declared' when --check found drifts"

CAP="$TMP/cap/ctxadd-converge"
run_provision "$CAP" "$SC_CTXADD" --declared-json "$DJ_ADD" "$SLUG"
assert_eq "ctx-add converge exits 0" "0" "$RC"
CTXADDPUT="$CAP/PUT_repos_acme_widgets_rulesets_1.body"
if [[ -f "$CTXADDPUT" ]]; then
    pass "ruleset PUT issued"
    assert_eq "new-check added and bound to its live reporter" "15368" \
        "$(jq -r '.rules[] | select(.type=="required_status_checks") | .parameters.required_status_checks[] | select(.context=="new-check") | .integration_id' "$CTXADDPUT")"
    jq -e '.rules[] | select(.type=="required_status_checks") | .parameters.required_status_checks | map(.context) | index("eval-suite") != null' "$CTXADDPUT" >/dev/null 2>&1 \
        && pass "the pre-existing declared context (eval-suite) is retained" \
        || fail "pre-existing declared context retained" "$(jq -c '.rules[] | select(.type=="required_status_checks")' "$CTXADDPUT")"
else
    fail "ruleset PUT issued" "requests.log=$(cat "$CAP/requests.log" 2>/dev/null)"
fi

section "context-list: live context absent from the declared list is REMOVED"
SC_CTXRM="$SCEN/ctx-rm"
write_repo "$SC_CTXRM" main good on
mkdir -p "$SC_CTXRM"
echo '[{"id":1,"name":"Protect main","target":"branch"}]' > "$SC_CTXRM/rulesets.json"
cat > "$SC_CTXRM/ruleset-1.json" <<'EOF'
{
  "id": 1, "name": "Protect main", "target": "branch", "enforcement": "active",
  "bypass_actors": [],
  "conditions": {"ref_name": {"include": ["refs/heads/main"], "exclude": []}},
  "rules": [
    {"type": "non_fast_forward"},
    {"type": "deletion"},
    {"type": "pull_request", "parameters": {"required_approving_review_count": 0, "dismiss_stale_reviews_on_push": true, "require_code_owner_review": true, "require_last_push_approval": false, "required_review_thread_resolution": false, "require_extra_approval_for_unattributed_changes": true}},
    {"type": "required_status_checks", "parameters": {"strict_required_status_checks_policy": true, "required_status_checks": [{"context": "eval-suite", "integration_id": 15368}, {"context": "stale-check", "integration_id": 15368}]}}
  ]
}
EOF
add_tag_ruleset "$SC_CTXRM" 2 ok
DJ_RM="$TMP/declared-rm.json"
mk_declared_json "$DJ_RM" '["eval-suite"]'

run_provision "$TMP/cap/ctxrm-check" "$SC_CTXRM" --check --declared-json "$DJ_RM" "$SLUG"
assert_eq "ctx-rm --check exits 1 (list drift)" "1" "$RC"
grep -q "DRIFT rule.required_status_checks.context-list\[-stale-check\]" <<<"$OUT" && pass "flags the undeclared live context as drift" || fail "flags undeclared live context" "$OUT"

CAP="$TMP/cap/ctxrm-converge"
run_provision "$CAP" "$SC_CTXRM" --declared-json "$DJ_RM" "$SLUG"
assert_eq "ctx-rm converge exits 0" "0" "$RC"
CTXRMPUT="$CAP/PUT_repos_acme_widgets_rulesets_1.body"
if [[ -f "$CTXRMPUT" ]]; then
    pass "ruleset PUT issued"
    jq -e '.rules[] | select(.type=="required_status_checks") | .parameters.required_status_checks | map(.context) | index("stale-check") == null' "$CTXRMPUT" >/dev/null 2>&1 \
        && pass "the undeclared context (stale-check) is removed" \
        || fail "undeclared context removed" "$(jq -c '.rules[] | select(.type=="required_status_checks")' "$CTXRMPUT")"
    jq -e '.rules[] | select(.type=="required_status_checks") | .parameters.required_status_checks | map(.context) | index("eval-suite") != null' "$CTXRMPUT" >/dev/null 2>&1 \
        && pass "the still-declared context (eval-suite) is retained" \
        || fail "still-declared context retained" "$(jq -c '.rules[] | select(.type=="required_status_checks")' "$CTXRMPUT")"
else
    fail "ruleset PUT issued" "requests.log=$(cat "$CAP/requests.log" 2>/dev/null)"
fi

section "context-list: a declared context with NO live reporter anywhere is refused, never bound blind"
SC_CTXREFUSE="$SCEN/ctx-refuse"
write_repo "$SC_CTXREFUSE" main good on
write_ruleset "$SC_CTXREFUSE" 1 main "non_fast_forward,deletion,pull_request,required_status_checks"
add_tag_ruleset "$SC_CTXREFUSE" 2 ok
DJ_REFUSE="$TMP/declared-refuse.json"
mk_declared_json "$DJ_REFUSE" '["eval-suite","typo-check"]'
# No write_reporter call for "typo-check" at all — neither a merged PR (the
# suite's stub answers "pulls" with an empty [] by default per its own
# fallback) nor an open PR (same fixture, same fallback) ever reports it.

run_provision "$TMP/cap/ctxrefuse-check" "$SC_CTXREFUSE" --check --declared-json "$DJ_REFUSE" "$SLUG"
assert_eq "ctx-refuse --check exits 1" "1" "$RC"
grep -q "DRIFT rule.required_status_checks.context-list\[+typo-check\]" <<<"$OUT" && pass "flags the unreported context as drift" || fail "flags unreported context" "$OUT"
grep -q "never reported on main or an open PR" <<<"$OUT" && pass "names why: never reported anywhere live" || fail "names why" "$OUT"

CAP="$TMP/cap/ctxrefuse-converge"
run_provision "$CAP" "$SC_CTXREFUSE" --declared-json "$DJ_REFUSE" "$SLUG"
assert_eq "ctx-refuse converge exits 1 (cannot fully resolve, but does not FATAL)" "1" "$RC"
grep -q "FATAL" <<<"$OUT" && fail "no FATAL — refusal is a reported drift, not a hard abort" "$OUT" || pass "no FATAL — refusal is a reported drift, not a hard abort"
CTXREFPUT="$CAP/PUT_repos_acme_widgets_rulesets_1.body"
if [[ -f "$CTXREFPUT" ]]; then
    jq -e '.rules[] | select(.type=="required_status_checks") | .parameters.required_status_checks | map(.context) | index("typo-check") == null' "$CTXREFPUT" >/dev/null 2>&1 \
        && pass "typo-check was never added to the PUT body (never bound blind)" \
        || fail "typo-check absent from PUT body" "$(jq -c '.rules[] | select(.type=="required_status_checks")' "$CTXREFPUT")"
else
    # Every other field already matched intent, so no PUT may have been
    # needed at all — that is fine; the assertion above about the drift
    # line and the non-FATAL exit already prove the refusal behavior.
    pass "no PUT issued (nothing else needed converging) — refusal alone doesn't force a write"
fi

section "context-list: live list already matches declared exactly — no-op, no PUT"
SC_CTXNOOP="$SCEN/ctx-noop"
write_repo "$SC_CTXNOOP" main good on
mkdir -p "$SC_CTXNOOP"
echo '[{"id":1,"name":"Protect main","target":"branch"}]' > "$SC_CTXNOOP/rulesets.json"
cat > "$SC_CTXNOOP/ruleset-1.json" <<'EOF'
{
  "id": 1, "name": "Protect main", "target": "branch", "enforcement": "active",
  "bypass_actors": [],
  "conditions": {"ref_name": {"include": ["refs/heads/main"], "exclude": []}},
  "rules": [
    {"type": "non_fast_forward"},
    {"type": "deletion"},
    {"type": "pull_request", "parameters": {"required_approving_review_count": 0, "dismiss_stale_reviews_on_push": true, "require_code_owner_review": true, "require_last_push_approval": false, "required_review_thread_resolution": false, "require_extra_approval_for_unattributed_changes": true}},
    {"type": "required_status_checks", "parameters": {"strict_required_status_checks_policy": true, "required_status_checks": [{"context": "eval-suite", "integration_id": 15368}]}}
  ]
}
EOF
add_tag_ruleset "$SC_CTXNOOP" 2 ok
write_core_call_ok "$SC_CTXNOOP"
DJ_NOOP="$TMP/declared-noop.json"
mk_declared_json "$DJ_NOOP" '["eval-suite"]'

run_provision "$TMP/cap/ctxnoop-check" "$SC_CTXNOOP" --check --declared-json "$DJ_NOOP" "$SLUG"
assert_eq "ctx-noop --check exits 0 (fully wired)" "0" "$RC"
grep -q "OK    rule.required_status_checks.context-list" <<<"$OUT" && pass "reports the context-list as matching declared" || fail "reports context-list OK" "$OUT"
grep -q "context-list\[" <<<"$OUT" && fail "no add/remove lines when already matching" "$OUT" || pass "no add/remove lines when already matching"

# Undeclared repo (no .repos entry at all) keeps the ORIGINAL byte-for-byte
# preservation — this feature must never force every repo to declare a list.
DJ_UNDECLARED="$TMP/declared-undeclared.json"
jq -n '{
    pull_request: {required_approving_review_count:0, dismiss_stale_reviews_on_push:true, require_code_owner_review:true, require_last_push_approval:false, required_review_thread_resolution:false, require_extra_approval_for_unattributed_changes:true},
    required_status_checks: {strict_required_status_checks_policy: true},
    tag_ruleset: {name: "Tag immutability", rules: ["update","deletion"]}
}' > "$DJ_UNDECLARED"
run_provision "$TMP/cap/ctxundeclared-check" "$SC_CTXNOOP" --check --declared-json "$DJ_UNDECLARED" "$SLUG"
assert_eq "a repo with no .repos entry --checks clean (list preserved, untouched by this feature)" "0" "$RC"
grep -q "context-list" <<<"$OUT" && fail "no context-list lines at all for an undeclared repo" "$OUT" || pass "no context-list lines at all for an undeclared repo"

# ============================================================================
# FOLD (attack-kitty pressure-test): a repo that DECLARES
# required_contexts but whose branch ruleset has NO required_status_checks
# rule must NOT be reported "fully wired" with the rule silently never
# created -- the tier-downgrade this tool exists to prevent. --check must
# flag it; converge must CREATE the rule, populated with the live-verified
# declared contexts (unresolvable ones refused, never bound blind).
section "context-list: declared contexts + a ruleset with NO required_status_checks rule -> rule CREATED"
SC_CTXNORSC="$SCEN/ctx-no-rsc"
write_repo "$SC_CTXNORSC" main good on
# non_fast_forward + deletion + pull_request, but deliberately NO
# required_status_checks rule.
write_ruleset "$SC_CTXNORSC" 1 main "non_fast_forward,deletion,pull_request"
write_reporter "$SC_CTXNORSC" "norscsha01" "ci-check" 15368
add_tag_ruleset "$SC_CTXNORSC" 2 ok
DJ_NORSC="$TMP/declared-no-rsc.json"
mk_declared_json "$DJ_NORSC" '["ci-check"]'

run_provision "$TMP/cap/ctxnorsc-check" "$SC_CTXNORSC" --check --declared-json "$DJ_NORSC" "$SLUG"
assert_eq "no-rsc-rule + declared --check exits 1 (NOT a false 'fully wired')" "1" "$RC"
grep -q "DRIFT rule.required_status_checks = absent" <<<"$OUT" && pass "flags the absent required_status_checks rule as drift" || fail "flags absent rsc rule" "$OUT"
grep -q "DRIFT rule.required_status_checks.context-list\[+ci-check\]" <<<"$OUT" && pass "flags the declared context as would-add" || fail "flags declared context" "$OUT"
grep -q "no drift" <<<"$OUT" && fail "must NOT report 'no drift — fully wired'" "$OUT" || pass "never reports the false green"

CAP="$TMP/cap/ctxnorsc-converge"
run_provision "$CAP" "$SC_CTXNORSC" --declared-json "$DJ_NORSC" "$SLUG"
assert_eq "no-rsc-rule + declared converge exits 0" "0" "$RC"
NORSCPUT="$CAP/PUT_repos_acme_widgets_rulesets_1.body"
if [[ -f "$NORSCPUT" ]]; then
    pass "ruleset PUT issued"
    jq -e '.rules | map(.type) | index("required_status_checks") != null' "$NORSCPUT" >/dev/null 2>&1 \
        && pass "the required_status_checks rule was CREATED (was absent)" \
        || fail "rsc rule created" "$(jq -c '.rules | map(.type)' "$NORSCPUT")"
    assert_eq "ci-check bound to its live reporter in the created rule" "15368" \
        "$(jq -r '.rules[] | select(.type=="required_status_checks") | .parameters.required_status_checks[] | select(.context=="ci-check") | .integration_id' "$NORSCPUT")"
    assert_eq "created rule has strict forced true" "true" \
        "$(jq -r '.rules[] | select(.type=="required_status_checks") | .parameters.strict_required_status_checks_policy' "$NORSCPUT")"
else
    fail "ruleset PUT issued" "requests.log=$(cat "$CAP/requests.log" 2>/dev/null)"
fi

section "context-list: declared contexts + a ruleset with no rsc rule, context UNREPORTED -> rule NOT created blind"
SC_CTXNORSCREFUSE="$SCEN/ctx-no-rsc-refuse"
write_repo "$SC_CTXNORSCREFUSE" main good on
write_ruleset "$SC_CTXNORSCREFUSE" 1 main "non_fast_forward,deletion,pull_request"
# No write_reporter: the declared context has never reported.
add_tag_ruleset "$SC_CTXNORSCREFUSE" 2 ok
DJ_NORSCREFUSE="$TMP/declared-no-rsc-refuse.json"
mk_declared_json "$DJ_NORSCREFUSE" '["never-ran-check"]'

CAP="$TMP/cap/ctxnorscrefuse-converge"
run_provision "$CAP" "$SC_CTXNORSCREFUSE" --declared-json "$DJ_NORSCREFUSE" "$SLUG"
grep -q "refusing to require" <<<"$OUT" && pass "refuses the never-reported context" || fail "refuses never-reported" "$OUT"
NORSCREFPUT="$CAP/PUT_repos_acme_widgets_rulesets_1.body"
if [[ -f "$NORSCREFPUT" ]]; then
    jq -e '(.rules | map(select(.type=="required_status_checks"))[0].parameters.required_status_checks // []) | length == 0 or (map(.context) | index("never-ran-check") == null)' "$NORSCREFPUT" >/dev/null 2>&1 \
        && pass "the unreported context was never added (no blind bind, even from scratch)" \
        || fail "never-ran-check must not appear" "$(jq -c '.rules[] | select(.type=="required_status_checks")' "$NORSCREFPUT")"
else
    # No RSC-affecting PUT at all is also acceptable: nothing resolvable to add.
    pass "no rsc rule created for an all-unreported declared list (never bound blind)"
fi

section "context-list: NO ruleset at all + declared contexts -> ruleset AND rsc rule created (converge)"
SC_CTXFRESH="$SCEN/ctx-fresh"
write_repo "$SC_CTXFRESH" main good on
# No branch ruleset at all: an empty rulesets list.
echo '[]' > "$SC_CTXFRESH/rulesets.json"
write_reporter "$SC_CTXFRESH" "freshsha01" "ci-check" 15368
DJ_FRESH="$TMP/declared-fresh.json"
mk_declared_json "$DJ_FRESH" '["ci-check"]'

CAP="$TMP/cap/ctxfresh-converge"
run_provision "$CAP" "$SC_CTXFRESH" --declared-json "$DJ_FRESH" "$SLUG"
assert_eq "fresh (no ruleset) + declared converge exits 0" "0" "$RC"
# The branch ruleset is POSTed (id 9001), then the rsc rule added via PUT.
FRESHPUT="$CAP/PUT_repos_acme_widgets_rulesets_9001.body"
if [[ -f "$FRESHPUT" ]]; then
    jq -e '.rules | map(.type) | index("required_status_checks") != null' "$FRESHPUT" >/dev/null 2>&1 \
        && pass "the created-from-scratch ruleset got its required_status_checks rule via convergence" \
        || fail "fresh rsc rule created" "$(jq -c '.rules | map(.type)' "$FRESHPUT")"
    assert_eq "fresh: ci-check bound to its live reporter" "15368" \
        "$(jq -r '.rules[] | select(.type=="required_status_checks") | .parameters.required_status_checks[] | select(.context=="ci-check") | .integration_id' "$FRESHPUT")"
else
    fail "fresh: convergence PUT issued after create" "requests.log=$(cat "$CAP/requests.log" 2>/dev/null)"
fi

# ============================================================================
# Drift-check-only classes (--check): the drift check holds every repo to the core.
# ============================================================================
section "tag-origin: release-authored tags pass; a wrong-tagger tag and a lightweight tag are DRIFT"
SC_TAGORIGIN="$SCEN/tag-origin"
write_repo "$SC_TAGORIGIN" main good on
write_ruleset "$SC_TAGORIGIN" 1 main "non_fast_forward,deletion,pull_request,required_status_checks"
add_tag_ruleset "$SC_TAGORIGIN" 2 ok
# v1.0.0 annotated + release tagger (OK); v1.0.1 annotated + rogue tagger (DRIFT);
# hand-cut lightweight, ref -> commit, no tag object (DRIFT).
jq -n '[
    {ref:"refs/tags/v1.0.0",   object:{sha:"tagobj_v1", type:"tag"}},
    {ref:"refs/tags/v1.0.1",   object:{sha:"tagobj_v2", type:"tag"}},
    {ref:"refs/tags/hand-cut", object:{sha:"commit_lw", type:"commit"}}
]' > "$SC_TAGORIGIN/git-matching-refs-tags.json"
jq -n '{tag:"v1.0.0", tagger:{name:"claude-the-enduring[bot]"}}' > "$SC_TAGORIGIN/git-tag-tagobj_v1.json"
jq -n '{tag:"v1.0.1", tagger:{name:"mallory"}}'                   > "$SC_TAGORIGIN/git-tag-tagobj_v2.json"
DJ_TAGORIGIN="$TMP/declared-tagorigin.json"
jq -n '{
    pull_request:{required_approving_review_count:0,dismiss_stale_reviews_on_push:true,require_code_owner_review:true,require_last_push_approval:false,required_review_thread_resolution:false,require_extra_approval_for_unattributed_changes:true},
    required_status_checks:{strict_required_status_checks_policy:true},
    tag_ruleset:{name:"Tag immutability", rules:["update","deletion"]},
    release_tag_authors:["claude-the-enduring[bot]"]
}' > "$DJ_TAGORIGIN"
run_provision "$TMP/cap/tagorigin-check" "$SC_TAGORIGIN" --check --declared-json "$DJ_TAGORIGIN" "$SLUG"
grep -q "OK    tag-origin\[v1.0.0\] = tagger claude-the-enduring\[bot\]" <<<"$OUT" && pass "release-authored annotated tag passes" || fail "release-authored tag OK" "$OUT"
grep -q "DRIFT tag-origin\[v1.0.1\] = tagger 'mallory' not a declared release author" <<<"$OUT" && pass "rogue-tagger annotated tag is DRIFT" || fail "rogue-tagger DRIFT" "$OUT"
grep -q "DRIFT tag-origin\[hand-cut\] = lightweight" <<<"$OUT" && pass "lightweight tag is DRIFT" || fail "lightweight DRIFT" "$OUT"

section "tag-origin: absent .release_tag_authors reports not-declared, never false-clean"
DJ_TAGNONE="$TMP/declared-tagnone.json"
jq -n '{
    pull_request:{required_approving_review_count:0,dismiss_stale_reviews_on_push:true,require_code_owner_review:true,require_last_push_approval:false,required_review_thread_resolution:false,require_extra_approval_for_unattributed_changes:true},
    required_status_checks:{strict_required_status_checks_policy:true},
    tag_ruleset:{name:"Tag immutability", rules:["update","deletion"]}
}' > "$DJ_TAGNONE"
run_provision "$TMP/cap/tagnone-check" "$SC_TAGORIGIN" --check --declared-json "$DJ_TAGNONE" "$SLUG"
grep -q "SKIP  tag-origin (no .release_tag_authors declared" <<<"$OUT" && pass "absent release_tag_authors -> visible skip (never false-clean, never spurious drift)" || fail "not-declared skip reported" "$OUT"

section "tag-origin: matching-refs returns [] for a repo with no tags"
SC_NOTAGS="$SCEN/tag-notags"
write_repo "$SC_NOTAGS" main good on
write_ruleset "$SC_NOTAGS" 1 main "non_fast_forward,deletion,pull_request,required_status_checks"
add_tag_ruleset "$SC_NOTAGS" 2 ok
printf '[]' > "$SC_NOTAGS/git-matching-refs-tags.json"
run_provision "$TMP/cap/notags-check" "$SC_NOTAGS" --check --declared-json "$DJ_TAGORIGIN" "$SLUG"
grep -q "OK    tag-origin = no tags" <<<"$OUT" && pass "no-tags repo is clean on tag-origin" || fail "no-tags clean" "$OUT"

section "tag-origin: unreadable tag inventory fails closed"
SC_TAGREAD_FAIL="$SCEN/tag-read-fail"
write_repo "$SC_TAGREAD_FAIL" main good on
write_ruleset "$SC_TAGREAD_FAIL" 1 main "non_fast_forward,deletion,pull_request,required_status_checks"
add_tag_ruleset "$SC_TAGREAD_FAIL" 2 ok
# A 403 fixture fails exactly as an unreadable API call; the stub's normal
# no-fixture behavior for matching-refs is the successful zero-tags shape.
write_403 "$SC_TAGREAD_FAIL" "git-matching-refs-tags.json"
run_provision "$TMP/cap/tag-read-fail" "$SC_TAGREAD_FAIL" --check --declared-json "$DJ_TAGORIGIN" "$SLUG"
assert_eq "unreadable tag inventory exits nonzero" "1" "$RC"
grep -q "OK    tag-origin = no tags" <<<"$OUT" \
    && fail "unreadable tag inventory must not be reported clean" "$OUT" \
    || pass "unreadable tag inventory is never false-clean"

# ============================================================================
# Mechanical drift classes — missing-core-call, caller-pin
# classification, work-lifecycle refs, consumer pre-commit-pin lag,
# private-repo-profile three-way, forked-scripts, admin-exception-reason,
# plus the S2 "not readable under current scope" stubs. SC_WIRED already
# carries write_core_call_ok (good ci.yml/gate.yml, no dotty-tags fixture) and
# no .pre-commit-config.yaml / .house-code.json / check-plugin-version.sh /
# environments / secrets / permissions / keys fixtures at all — so it is
# reused below as the free SKIP fixture for every class whose skip is
# triggered by "the needed input/scope is absent", exactly as it already
# proved to be a zero-DRIFT baseline for tag-origin.
# ============================================================================

section "missing-core-call: OK when ci.yml + gate.yml both call the core"
run_provision "$TMP/cap/cc-ok" "$SC_WIRED" --check "$SLUG"
grep -q "OK    missing-core-call = ci.yml + gate.yml both call the core" <<<"$OUT" \
    && pass "both files calling the core is OK" || fail "both files calling the core is OK" "$OUT"

section "missing-core-call: absent ci.yml/gate.yml -> DRIFT (every repo must call the core)"
run_provision "$TMP/cap/cc-drift" "$SC_MPR" --check "$SLUG"
grep -q "DRIFT missing-core-call = missing/absent: ci.yml gate.yml" <<<"$OUT" \
    && pass "absent core-call files flagged as drift, never a silent pass" || fail "absent core-call flagged" "$OUT"

section "missing-core-call: declared core_call_exempt -> SKIP (absent exempt flag would enforce)"
SC_CCEXEMPT="$SCEN/cc-exempt"
mk_minimal_repo "$SC_CCEXEMPT"
# No ci.yml/gate.yml at all -- would otherwise DRIFT; the declared exemption
# must skip it instead of enforcing.
DJ_CCEXEMPT="$TMP/declared-cc-exempt.json"
mk_declared_repo_json "$DJ_CCEXEMPT" '{"core_call_exempt": true}'
run_provision "$TMP/cap/cc-exempt" "$SC_CCEXEMPT" --check --declared-json "$DJ_CCEXEMPT" "$SLUG"
grep -q "SKIP  missing-core-call" <<<"$OUT" && grep -q "core_call_exempt: true" <<<"$OUT" \
    && pass "declared exemption skips, never silently absent" || fail "declared exemption skips" "$OUT"

# ----------------------------------------------------------------------------
section "caller-pin: ref at/after dotty's latest tag -> OK current"
SC_PIN_OK="$SCEN/pin-ok"
mk_minimal_repo "$SC_PIN_OK"
write_core_call_ok "$SC_PIN_OK" "v2.0.0"
write_dotty_tags "$SC_PIN_OK" '["v2.0.0","v1.0.0"]'
write_dotty_compare "$SC_PIN_OK" "v2.0.0" "main" "ahead"
run_provision "$TMP/cap/pin-ok" "$SC_PIN_OK" --check "$SLUG"
grep -q "OK    caller-pin\[ci.yml\] = v2.0.0 (current release)" <<<"$OUT" \
    && pass "pin at the latest release tag is OK current" || fail "pin at latest tag OK" "$OUT"

section "caller-pin: ref not reachable on dotty main -> DRIFT unauthorized"
SC_PIN_DRIFT="$SCEN/pin-drift"
mk_minimal_repo "$SC_PIN_DRIFT"
write_core_call_ok "$SC_PIN_DRIFT" "unauthorized-ref"
write_dotty_tags "$SC_PIN_DRIFT" '["v2.0.0"]'
write_dotty_compare "$SC_PIN_DRIFT" "unauthorized-ref" "main" "diverged"
run_provision "$TMP/cap/pin-drift" "$SC_PIN_DRIFT" --check "$SLUG"
assert_eq "pin-drift --check exits 1" "1" "$RC"
grep -q "DRIFT caller-pin\[ci.yml\] = unauthorized-ref" <<<"$OUT" && grep -q "not reachable on dotty main" <<<"$OUT" \
    && pass "a ref not reachable on dotty main is DRIFT unauthorized" || fail "unreachable ref DRIFT" "$OUT"

section "caller-pin: dotty's own tag/main data unreadable -> SKIP, never guessed"
run_provision "$TMP/cap/pin-skip" "$SC_WIRED" --check "$SLUG"
grep -q "SKIP  caller-pin\[ci.yml\]" <<<"$OUT" && grep -q "dotty's tag list unreadable" <<<"$OUT" \
    && pass "unreadable dotty tag data skips, never assumed clean or drift" || fail "unreadable dotty data skips" "$OUT"

# ----------------------------------------------------------------------------
section "work-lifecycle-refs: OK when the superseded name is absent"
run_provision "$TMP/cap/wlc-ok" "$SC_WIRED" --check "$SLUG"
grep -q "OK    work-lifecycle-refs = no superseded work-lifecycle references" <<<"$OUT" \
    && pass "no work-lifecycle mention is OK" || fail "no work-lifecycle mention OK" "$OUT"

section "work-lifecycle-refs: a reference to the superseded name is DRIFT"
SC_WLC_DRIFT="$SCEN/wlc-drift"
mk_minimal_repo "$SC_WLC_DRIFT"
write_contents "$SC_WLC_DRIFT" ".github/workflows/ci.yml" \
    "uses: lexijamesesq/work-lifecycle/.github/workflows/foo.yml@v1"
run_provision "$TMP/cap/wlc-drift" "$SC_WLC_DRIFT" --check "$SLUG"
grep -q "DRIFT work-lifecycle-refs = references lexijamesesq/work-lifecycle" <<<"$OUT" \
    && pass "a work-lifecycle reference is flagged (repoint to core-skills)" || fail "work-lifecycle reference flagged" "$OUT"

section "work-lifecycle-refs: a reference only in release.yml is DRIFT (the wiring sweep found them there)"
SC_WLC_RELEASE="$SCEN/wlc-release"
mk_minimal_repo "$SC_WLC_RELEASE"
# ci.yml/gate.yml carry no work-lifecycle ref; release.yml alone does.
write_contents "$SC_WLC_RELEASE" ".github/workflows/release.yml" \
    "uses: lexijamesesq/work-lifecycle/.github/actions/check-plugin-version@da3609c4"
run_provision "$TMP/cap/wlc-release" "$SC_WLC_RELEASE" --check "$SLUG"
grep -q "DRIFT work-lifecycle-refs = references lexijamesesq/work-lifecycle" <<<"$OUT" \
    && pass "a work-lifecycle reference in release.yml alone is flagged" || fail "release.yml work-lifecycle reference flagged" "$OUT"

section "work-lifecycle-refs: absent ci.yml/gate.yml/CI.md is OK, never drift-by-absence"
run_provision "$TMP/cap/wlc-absent" "$SC_MPR" --check "$SLUG"
grep -q "OK    work-lifecycle-refs = no superseded work-lifecycle references" <<<"$OUT" \
    && pass "nothing to grep is OK (unlike missing-core-call, absence here is not itself the violation)" || fail "absent files OK" "$OUT"

# ----------------------------------------------------------------------------
section "precommit-pin-lag: rev at the current dotty release -> OK"
SC_PCC_OK="$SCEN/pcc-ok"
mk_minimal_repo "$SC_PCC_OK"
write_contents "$SC_PCC_OK" ".pre-commit-config.yaml" \
    "repos:
  - repo: https://github.com/lexijamesesq/dotty
    rev: v2.0.0
    hooks:
      - id: gitleaks-staged
"
write_dotty_tags "$SC_PCC_OK" '["v2.0.0"]'
run_provision "$TMP/cap/pcc-ok" "$SC_PCC_OK" --check "$SLUG"
grep -q "OK    precommit-pin-lag = rev: v2.0.0 (current)" <<<"$OUT" \
    && pass "rev at the current release is OK" || fail "rev at current release OK" "$OUT"

section "precommit-pin-lag: rev lags the current dotty release -> DRIFT"
SC_PCC_DRIFT="$SCEN/pcc-drift"
mk_minimal_repo "$SC_PCC_DRIFT"
write_contents "$SC_PCC_DRIFT" ".pre-commit-config.yaml" \
    "repos:
  - repo: https://github.com/lexijamesesq/dotty
    rev: v1.0.0
    hooks:
      - id: gitleaks-staged
"
write_dotty_tags "$SC_PCC_DRIFT" '["v2.0.0","v1.0.0"]'
write_dotty_compare "$SC_PCC_DRIFT" "v2.0.0" "v1.0.0" "behind"
run_provision "$TMP/cap/pcc-drift" "$SC_PCC_DRIFT" --check "$SLUG"
assert_eq "pcc-drift --check exits 1" "1" "$RC"
grep -q "DRIFT precommit-pin-lag = rev: v1.0.0" <<<"$OUT" \
    && pass "a lagging rev is flagged as drift" || fail "lagging rev flagged" "$OUT"

section "precommit-pin-lag: no .pre-commit-config.yaml -> SKIP (not a dotty consumer)"
run_provision "$TMP/cap/pcc-skip" "$SC_WIRED" --check "$SLUG"
grep -q "SKIP  precommit-pin-lag (no .pre-commit-config.yaml" <<<"$OUT" \
    && pass "no config file skips, never assumed clean" || fail "no config file skips" "$OUT"

# --- dotty_latest_tag: the current release, not tags[0] ----------------------
# The class's reference for "current dotty release" must come from
# releases/latest, falling back to a CalVer-numeric sort — NOT the API's
# reverse-lexical tags[0], under which a bare date tag "v2026.09.07" outranks
# its own suffixed release "v2026.09.07-10" and false-flags a correct consumer.
PCC_YAML='repos:
  - repo: https://github.com/lexijamesesq/dotty
    rev: %s
    hooks:
      - id: gitleaks-staged
'
section "dotty_latest_tag: latest comes from releases/latest, not tags[0]"
SC_LT_REL="$SCEN/lt-rel"
mk_minimal_repo "$SC_LT_REL"
# shellcheck disable=SC2059
write_contents "$SC_LT_REL" ".pre-commit-config.yaml" "$(printf "$PCC_YAML" "v2026.09.07-10")"
write_dotty_release "$SC_LT_REL" "v2026.09.07-10"
write_dotty_tags "$SC_LT_REL" '["v2026.09.07"]'   # bare tag would be tags[0] — must be ignored
run_provision "$TMP/cap/lt-rel" "$SC_LT_REL" --check "$SLUG"
grep -q "OK    precommit-pin-lag = rev: v2026.09.07-10 (current)" <<<"$OUT" \
    && pass "releases/latest is the reference (a consumer at -10 is current, not drift)" || fail "releases/latest is the reference" "$OUT"

section "dotty_latest_tag: fallback CalVer sort — a bare date tag beside suffixed tags"
SC_LT_FALL="$SCEN/lt-fall"
mk_minimal_repo "$SC_LT_FALL"
# shellcheck disable=SC2059
write_contents "$SC_LT_FALL" ".pre-commit-config.yaml" "$(printf "$PCC_YAML" "v2026.09.07-10")"
# no releases/latest fixture -> fallback; the bare tag must NOT win the sort
write_dotty_tags "$SC_LT_FALL" '["v2026.09.07","v2026.09.07-10","v2026.09.07-6"]'
run_provision "$TMP/cap/lt-fall" "$SC_LT_FALL" --check "$SLUG"
grep -q "OK    precommit-pin-lag = rev: v2026.09.07-10 (current)" <<<"$OUT" \
    && pass "the fallback picks v2026.09.07-10 (CalVer), not the lexical bare date tag" || fail "fallback CalVer sort" "$OUT"

section "dotty_latest_tag: a genuinely lagging consumer is DRIFT with the correct target"
SC_LT_LAG="$SCEN/lt-lag"
mk_minimal_repo "$SC_LT_LAG"
# shellcheck disable=SC2059
write_contents "$SC_LT_LAG" ".pre-commit-config.yaml" "$(printf "$PCC_YAML" "v2026.09.07-6")"
write_dotty_release "$SC_LT_LAG" "v2026.09.07-10"
write_dotty_compare "$SC_LT_LAG" "v2026.09.07-10" "v2026.09.07-6" "behind"
run_provision "$TMP/cap/lt-lag" "$SC_LT_LAG" --check "$SLUG"
assert_eq "lt-lag --check exits 1" "1" "$RC"
grep -q "DRIFT precommit-pin-lag = rev: v2026.09.07-6 (intended current dotty release (v2026.09.07-10))" <<<"$OUT" \
    && pass "a lagging consumer is DRIFT and names the correct current release" || fail "lag names correct target" "$OUT"

# ----------------------------------------------------------------------------
section "private-repo-profile: nothing declared + public everywhere -> OK"
run_provision "$TMP/cap/priv-ok" "$SC_WIRED" --check "$SLUG"
grep -q "OK    private-repo-profile = plain public repo (nothing declared)" <<<"$OUT" \
    && pass "the trivial plain-public case is OK" || fail "plain public repo OK" "$OUT"

section "private-repo-profile: declared vs live mismatch -> DRIFT"
SC_PRIVATE_DRIFT="$SCEN/private-drift"
mkdir -p "$SC_PRIVATE_DRIFT"
jq -n '{
    default_branch: "main", allow_squash_merge: true, allow_merge_commit: false,
    allow_rebase_merge: false, delete_branch_on_merge: true,
    allow_auto_merge: true, allow_update_branch: true,
    squash_merge_commit_title: "PR_TITLE", squash_merge_commit_message: "PR_BODY",
    private: true
}' > "$SC_PRIVATE_DRIFT/repo.json"
echo '[]' > "$SC_PRIVATE_DRIFT/rulesets.json"
DJ_PRIVDRIFT="$TMP/declared-private-drift.json"
mk_declared_repo_json "$DJ_PRIVDRIFT" '{"private_repo": false}'
run_provision "$TMP/cap/priv-drift" "$SC_PRIVATE_DRIFT" --check --declared-json "$DJ_PRIVDRIFT" "$SLUG"
assert_eq "priv-drift --check exits 1" "1" "$RC"
grep -q "DRIFT private-repo-profile = declared=false, mismatch: live=true" <<<"$OUT" \
    && pass "a declared/live mismatch is flagged as drift" || fail "declared/live mismatch flagged" "$OUT"

section "private-repo-profile: no declared value + a non-default live state -> SKIP (cannot 3-way-verify)"
run_provision "$TMP/cap/priv-skip" "$SC_PRIVATE" --check "$SLUG"
grep -q "SKIP  private-repo-profile (no declared" <<<"$OUT" \
    && pass "an undeclared non-default state skips rather than guessing" || fail "undeclared non-default skips" "$OUT"

# ----------------------------------------------------------------------------
# license-presence — public repos carry a license (estate default MIT), private
# repos carry none. Visibility = declared private_repo (else live), license =
# GitHub's .license field. SKIP when visibility is unreadable.
section "license-presence: public repo with a license -> OK"
SC_LIC_PUB_OK="$SCEN/lic-pub-ok"
mk_license_repo "$SC_LIC_PUB_OK" false mit
run_provision "$TMP/cap/lic-pub-ok" "$SC_LIC_PUB_OK" --check "$SLUG"
grep -q "OK    license-presence = public repo, license present" <<<"$OUT" \
    && pass "a public repo with a license is OK" || fail "public + license OK" "$OUT"

section "license-presence: public repo with no license -> DRIFT"
SC_LIC_PUB_NO="$SCEN/lic-pub-no"
mk_license_repo "$SC_LIC_PUB_NO" false none
run_provision "$TMP/cap/lic-pub-no" "$SC_LIC_PUB_NO" --check "$SLUG"
assert_eq "lic-pub-no --check exits 1" "1" "$RC"
grep -q "DRIFT license-presence = public repo has no license" <<<"$OUT" \
    && pass "a public repo missing a license is DRIFT" || fail "public + no license DRIFT" "$OUT"

section "license-presence: private repo (declared) carrying a license -> DRIFT (the hazel shape)"
SC_LIC_PRIV_HAS="$SCEN/lic-priv-has"
mk_license_repo "$SC_LIC_PRIV_HAS" true mit
DJ_LIC_PRIV="$TMP/declared-lic-priv.json"
mk_declared_repo_json "$DJ_LIC_PRIV" '{"private_repo": true}'
run_provision "$TMP/cap/lic-priv-has" "$SC_LIC_PRIV_HAS" --check --declared-json "$DJ_LIC_PRIV" "$SLUG"
assert_eq "lic-priv-has --check exits 1" "1" "$RC"
grep -q "DRIFT license-presence = private repo carries a license" <<<"$OUT" \
    && pass "a private repo carrying a license is DRIFT (flagged, never touched)" || fail "private + license DRIFT" "$OUT"

section "license-presence: private repo (declared) with no license -> OK"
SC_LIC_PRIV_NO="$SCEN/lic-priv-no"
mk_license_repo "$SC_LIC_PRIV_NO" true none
run_provision "$TMP/cap/lic-priv-no" "$SC_LIC_PRIV_NO" --check --declared-json "$DJ_LIC_PRIV" "$SLUG"
grep -q "OK    license-presence = private repo, no license" <<<"$OUT" \
    && pass "a private repo with no license is OK" || fail "private + no license OK" "$OUT"

section "license-presence: visibility unreadable (undeclared + no live .private) -> SKIP"
run_provision "$TMP/cap/lic-skip" "$SC_WIRED" --check "$SLUG"
grep -q "SKIP  license-presence (repo visibility not readable" <<<"$OUT" \
    && pass "unreadable visibility skips, never guesses the expectation" || fail "unreadable visibility skips" "$OUT"

# ----------------------------------------------------------------------------
CPV_TEXT='#!/usr/bin/env bash
echo check-plugin-version
'
section "check-plugin-version-fork: byte-identical to core-skills' canonical copy -> OK"
SC_CPV_OK="$SCEN/cpv-ok"
mk_minimal_repo "$SC_CPV_OK"
write_contents "$SC_CPV_OK" ".github/check-plugin-version.sh" "$CPV_TEXT"
write_core_skills_content "$SC_CPV_OK" ".github/check-plugin-version.sh" "$CPV_TEXT"
run_provision "$TMP/cap/cpv-ok" "$SC_CPV_OK" --check "$SLUG"
grep -q "OK    check-plugin-version-fork = byte-identical to core-skills' canonical copy" <<<"$OUT" \
    && pass "a byte-identical local copy is OK" || fail "byte-identical copy OK" "$OUT"

section "check-plugin-version-fork: a diverged local copy -> DRIFT"
SC_CPV_DRIFT="$SCEN/cpv-drift"
mk_minimal_repo "$SC_CPV_DRIFT"
write_contents "$SC_CPV_DRIFT" ".github/check-plugin-version.sh" "#!/usr/bin/env bash
echo forked-local-copy
"
write_core_skills_content "$SC_CPV_DRIFT" ".github/check-plugin-version.sh" "$CPV_TEXT"
run_provision "$TMP/cap/cpv-drift" "$SC_CPV_DRIFT" --check "$SLUG"
assert_eq "cpv-drift --check exits 1" "1" "$RC"
grep -q "DRIFT check-plugin-version-fork = local copy diverges from core-skills' canonical copy" <<<"$OUT" \
    && pass "a diverged local copy is DRIFT (forked)" || fail "diverged local copy DRIFT" "$OUT"

section "check-plugin-version-fork: no local copy -> SKIP (not a consumer of the pattern)"
run_provision "$TMP/cap/cpv-skip" "$SC_WIRED" --check "$SLUG"
grep -q "SKIP  check-plugin-version-fork (no local copy" <<<"$OUT" \
    && pass "no local copy skips, never assumed clean" || fail "no local copy skips" "$OUT"

section "setup-gitleaks-pin + gitleaks-scan-present: current pin -> OK, and the shape is reported OK (shared composite)"
SC_SGPIN_OK="$SCEN/sgpin-ok"
mk_minimal_repo "$SC_SGPIN_OK"
write_contents "$SC_SGPIN_OK" ".github/workflows/ci.yml" \
    "jobs:
  scan:
    steps:
      - uses: lexijamesesq/dotty/.github/actions/setup-gitleaks@v2.0.0
"
write_dotty_tags "$SC_SGPIN_OK" '["v2.0.0"]'
run_provision "$TMP/cap/sgpin-ok" "$SC_SGPIN_OK" --check "$SLUG"
grep -q "OK    setup-gitleaks-pin = v2.0.0 (current)" <<<"$OUT" \
    && pass "a current setup-gitleaks pin is OK" || fail "current setup-gitleaks pin OK" "$OUT"
grep -q "OK    gitleaks-scan-present = shared composite in use" <<<"$OUT" \
    && pass "the shared composite shape is reported OK, never drift" || fail "shared composite shape reported OK" "$OUT"

section "setup-gitleaks-pin: a lagging pin -> DRIFT"
SC_SGPIN_DRIFT="$SCEN/sgpin-drift"
mk_minimal_repo "$SC_SGPIN_DRIFT"
write_contents "$SC_SGPIN_DRIFT" ".github/workflows/ci.yml" \
    "jobs:
  scan:
    steps:
      - uses: lexijamesesq/dotty/.github/actions/setup-gitleaks@v1.0.0
"
write_dotty_tags "$SC_SGPIN_DRIFT" '["v2.0.0","v1.0.0"]'
write_dotty_compare "$SC_SGPIN_DRIFT" "v1.0.0" "v2.0.0" "ahead"
run_provision "$TMP/cap/sgpin-drift" "$SC_SGPIN_DRIFT" --check "$SLUG"
assert_eq "sgpin-drift --check exits 1" "1" "$RC"
grep -q "DRIFT setup-gitleaks-pin = v1.0.0" <<<"$OUT" && grep -q "pin lags" <<<"$OUT" \
    && pass "a lagging setup-gitleaks pin is DRIFT" || fail "lagging setup-gitleaks pin DRIFT" "$OUT"

section "setup-gitleaks-pin: no pin at all -> SKIP; gitleaks-scan-present: nothing detected -> SKIP (never drift)"
run_provision "$TMP/cap/sgpin-skip" "$SC_WIRED" --check "$SLUG"
grep -q "SKIP  setup-gitleaks-pin (does not pin" <<<"$OUT" \
    && pass "no setup-gitleaks pin skips" || fail "no setup-gitleaks pin skips" "$OUT"
grep -q "SKIP  gitleaks-scan-present (no PR-range scan detected" <<<"$OUT" \
    && pass "no scan detected is reported as the shape, never ruled drift unilaterally" || fail "no scan detected reported as shape" "$OUT"

# ----------------------------------------------------------------------------
section "admin-exception-reason: nothing declared -> SKIP"
run_provision "$TMP/cap/adminexc-skip" "$SC_WIRED" --check "$SLUG"
grep -q "SKIP  admin-exception-reason (no admin exceptions declared for this repo)" <<<"$OUT" \
    && pass "no declared exceptions skips" || fail "no declared exceptions skips" "$OUT"

DJ_ADMINOK="$TMP/declared-admin-ok.json"
mk_declared_repo_json "$DJ_ADMINOK" '{"admin_exceptions":[{"flag":"pull_request_off","reason":"solo operator, reviewed manually"}]}'
section "admin-exception-reason: every declared exception carries a reason -> OK"
run_provision "$TMP/cap/adminexc-ok" "$SC_WIRED" --check --declared-json "$DJ_ADMINOK" "$SLUG"
grep -q "OK    admin-exception-reason = 1 exception(s), each carries a reason" <<<"$OUT" \
    && pass "a fully-reasoned exception list is OK" || fail "fully-reasoned exception list OK" "$OUT"

DJ_ADMINDRIFT="$TMP/declared-admin-drift.json"
mk_declared_repo_json "$DJ_ADMINDRIFT" '{"admin_exceptions":[{"flag":"pull_request_off","reason":""}]}'
section "admin-exception-reason: a declared exception without a reason -> DRIFT"
run_provision "$TMP/cap/adminexc-drift" "$SC_WIRED" --check --declared-json "$DJ_ADMINDRIFT" "$SLUG"
assert_eq "adminexc-drift --check exits 1" "1" "$RC"
grep -q "DRIFT admin-exception-reason = missing reason: pull_request_off" <<<"$OUT" \
    && pass "an unreasoned exception is DRIFT" || fail "unreasoned exception DRIFT" "$OUT"

# ----------------------------------------------------------------------------
# codeowners-policy — default owner present + every live ownerless pattern in
# the declared appendix; an undeclared ownerless pattern frees an owned path.
section "codeowners-policy: default owner present + all ownerless patterns declared -> OK"
SC_CO_OK="$SCEN/co-ok"
mk_minimal_repo "$SC_CO_OK"
write_contents "$SC_CO_OK" ".github/CODEOWNERS" "* @lexijamesesq
/README.md
/LICENSE
"
DJ_CO_OK="$TMP/declared-co-ok.json"
mk_declared_codeowners "$DJ_CO_OK" "@lexijamesesq" '["/README.md","/LICENSE"]'
run_provision "$TMP/cap/co-ok" "$SC_CO_OK" --check --declared-json "$DJ_CO_OK" "$SLUG"
grep -q "OK    codeowners-policy = default owner present; every ownerless pattern is in the declared appendix" <<<"$OUT" \
    && pass "a conformant CODEOWNERS is OK" || fail "conformant CODEOWNERS OK" "$OUT"

section "codeowners-policy: an escaped-space appendix pattern round-trips -> OK (real Metrics shape)"
SC_CO_ESC="$SCEN/co-esc"
mk_minimal_repo "$SC_CO_ESC"
write_contents "$SC_CO_ESC" ".github/CODEOWNERS" "* @lexijamesesq
/UX\\ Bugs/**/*.md
"
DJ_CO_ESC="$TMP/declared-co-esc.json"
mk_declared_codeowners "$DJ_CO_ESC" "@lexijamesesq" '["/UX\\ Bugs/**/*.md"]'
run_provision "$TMP/cap/co-esc" "$SC_CO_ESC" --check --declared-json "$DJ_CO_ESC" "$SLUG"
grep -q "OK    codeowners-policy = default owner present" <<<"$OUT" \
    && pass "an escaped-space ownerless pattern matches its declared entry" || fail "escaped-space pattern matches" "$OUT"

section "codeowners-policy: a declared pattern absent from live is NOT drift (that path is then owned — stricter)"
SC_CO_STRICT="$SCEN/co-strict"
mk_minimal_repo "$SC_CO_STRICT"
write_contents "$SC_CO_STRICT" ".github/CODEOWNERS" "* @lexijamesesq
/README.md
"
DJ_CO_STRICT="$TMP/declared-co-strict.json"
mk_declared_codeowners "$DJ_CO_STRICT" "@lexijamesesq" '["/README.md","/LICENSE"]'
run_provision "$TMP/cap/co-strict" "$SC_CO_STRICT" --check --declared-json "$DJ_CO_STRICT" "$SLUG"
# (this scenario's overall exit is 1 from the mk_minimal_repo ruleset-absent
# noise — the OK line alone proves no drift in THIS class, per the other
# codeowners OK cases above.)
grep -q "OK    codeowners-policy = default owner present" <<<"$OUT" \
    && pass "a declared-but-not-live appendix pattern is not drift" || fail "declared-not-live not drift" "$OUT"

section "codeowners-policy: an undeclared ownerless pattern frees an owned path -> DRIFT"
SC_CO_UNDECL="$SCEN/co-undecl"
mk_minimal_repo "$SC_CO_UNDECL"
write_contents "$SC_CO_UNDECL" ".github/CODEOWNERS" "* @lexijamesesq
/README.md
/.github/workflows/
"
DJ_CO_UNDECL="$TMP/declared-co-undecl.json"
mk_declared_codeowners "$DJ_CO_UNDECL" "@lexijamesesq" '["/README.md"]'
run_provision "$TMP/cap/co-undecl" "$SC_CO_UNDECL" --check --declared-json "$DJ_CO_UNDECL" "$SLUG"
assert_eq "co-undecl --check exits 1" "1" "$RC"
grep -q "DRIFT codeowners-policy = undeclared unowned pattern(s): /.github/workflows/" <<<"$OUT" \
    && pass "an undeclared ownerless pattern is DRIFT (frees an owned path)" || fail "undeclared ownerless DRIFT" "$OUT"

section "codeowners-policy: the default-owner line missing -> DRIFT (the whole gate is off)"
SC_CO_NODEF="$SCEN/co-nodef"
mk_minimal_repo "$SC_CO_NODEF"
write_contents "$SC_CO_NODEF" ".github/CODEOWNERS" "/README.md
/docs/**/*.md
"
DJ_CO_NODEF="$TMP/declared-co-nodef.json"
mk_declared_codeowners "$DJ_CO_NODEF" "@lexijamesesq" '["/README.md","/docs/**/*.md"]'
run_provision "$TMP/cap/co-nodef" "$SC_CO_NODEF" --check --declared-json "$DJ_CO_NODEF" "$SLUG"
assert_eq "co-nodef --check exits 1" "1" "$RC"
grep -q "DRIFT codeowners-policy = default-owner line '\* @lexijamesesq' missing" <<<"$OUT" \
    && pass "a missing default-owner line is DRIFT" || fail "missing default-owner DRIFT" "$OUT"

section "codeowners-policy: no CODEOWNERS file at all -> DRIFT"
SC_CO_NOFILE="$SCEN/co-nofile"
mk_minimal_repo "$SC_CO_NOFILE"
DJ_CO_NOFILE="$TMP/declared-co-nofile.json"
mk_declared_codeowners "$DJ_CO_NOFILE" "@lexijamesesq" '["/README.md"]'
run_provision "$TMP/cap/co-nofile" "$SC_CO_NOFILE" --check --declared-json "$DJ_CO_NOFILE" "$SLUG"
assert_eq "co-nofile --check exits 1" "1" "$RC"
grep -q "DRIFT codeowners-policy = no .github/CODEOWNERS file" <<<"$OUT" \
    && pass "an absent CODEOWNERS is DRIFT" || fail "absent CODEOWNERS DRIFT" "$OUT"

section "codeowners-policy: no per-repo codeowners_appendix declared -> SKIP (never false-clean)"
DJ_CO_NOAPX="$TMP/declared-co-noapx.json"
mk_declared_codeowners "$DJ_CO_NOAPX" "@lexijamesesq" "absent"
run_provision "$TMP/cap/co-noapx" "$SC_CO_OK" --check --declared-json "$DJ_CO_NOAPX" "$SLUG"
grep -q "SKIP  codeowners-policy (no .repos" <<<"$OUT" \
    && pass "an undeclared per-repo appendix skips, never assumed clean" || fail "undeclared appendix skips" "$OUT"

section "codeowners-policy: no .codeowners_default_owner declared -> SKIP (policy not configured)"
DJ_CO_NOOWNER="$TMP/declared-co-noowner.json"
mk_declared_codeowners "$DJ_CO_NOOWNER" "" '["/README.md"]'
run_provision "$TMP/cap/co-noowner" "$SC_CO_OK" --check --declared-json "$DJ_CO_NOOWNER" "$SLUG"
grep -q "SKIP  codeowners-policy (no .codeowners_default_owner declared" <<<"$OUT" \
    && pass "an unconfigured policy skips, never assumed clean" || fail "unconfigured policy skips" "$OUT"

# ----------------------------------------------------------------------------
# S2 stubs — the read is built on the App path so it activates once the
# Environments/Secrets:read + Administration:read grants land. Two unreadable
# shapes are both proven below: an endpoint with no fixture (SC_WIRED — the
# stub exits non-zero with nothing on stdout) AND a real 403 (write_403 — the
# stub emits the error BODY on stdout and exits non-zero, exactly as gh does).
# The full-read DRIFT cases (secret absent, approve-on, undeclared key) double
# as the proof that under a full-scope token the same classes still report real
# drift — the SKIP guard must never mask a finding when the endpoint IS
# readable.
section "S2 env-secret-freshness: environment + secret present -> OK"
SC_S2ENV_OK="$SCEN/s2env-ok"
mk_minimal_repo "$SC_S2ENV_OK"
jq -n '{name:"default-branch"}' > "$SC_S2ENV_OK/environments-default-branch.json"
jq -n '{secrets:[{name:"OPERATOR_RULES"}]}' > "$SC_S2ENV_OK/environment-secrets-default-branch.json"
run_provision "$TMP/cap/s2env-ok" "$SC_S2ENV_OK" --check "$SLUG"
grep -q "OK    env-secret-freshness = default-branch environment + OPERATOR_RULES secret present" <<<"$OUT" \
    && pass "environment + secret both present is OK" || fail "environment + secret present OK" "$OUT"

section "S2 env-secret-freshness: secret absent -> DRIFT"
SC_S2ENV_DRIFT="$SCEN/s2env-drift"
mk_minimal_repo "$SC_S2ENV_DRIFT"
jq -n '{name:"default-branch"}' > "$SC_S2ENV_DRIFT/environments-default-branch.json"
jq -n '{secrets:[]}' > "$SC_S2ENV_DRIFT/environment-secrets-default-branch.json"
run_provision "$TMP/cap/s2env-drift" "$SC_S2ENV_DRIFT" --check "$SLUG"
assert_eq "s2env-drift --check exits 1" "1" "$RC"
grep -q "DRIFT env-secret-freshness = OPERATOR_RULES secret absent from default-branch environment" <<<"$OUT" \
    && pass "an absent OPERATOR_RULES secret is DRIFT" || fail "absent secret DRIFT" "$OUT"

section "S2 env-secret-freshness: not readable under current scope -> SKIP, never false-clean"
run_provision "$TMP/cap/s2env-skip" "$SC_WIRED" --check "$SLUG"
grep -q "SKIP  env-secret-freshness (not readable under current scope" <<<"$OUT" \
    && pass "today's App 403 skips, never claims clean or drift" || fail "App 403 skips" "$OUT"

section "S2 actions-approve-off: off -> OK"
SC_S2ACT_OK="$SCEN/s2act-ok"
mk_minimal_repo "$SC_S2ACT_OK"
jq -n '{can_approve_pull_request_reviews:false}' > "$SC_S2ACT_OK/actions-permissions-workflow.json"
run_provision "$TMP/cap/s2act-ok" "$SC_S2ACT_OK" --check "$SLUG"
grep -q "OK    actions-approve-off = can_approve_pull_request_reviews=false" <<<"$OUT" \
    && pass "approve-off is OK" || fail "approve-off OK" "$OUT"

section "S2 actions-approve-off: on -> DRIFT"
SC_S2ACT_DRIFT="$SCEN/s2act-drift"
mk_minimal_repo "$SC_S2ACT_DRIFT"
jq -n '{can_approve_pull_request_reviews:true}' > "$SC_S2ACT_DRIFT/actions-permissions-workflow.json"
run_provision "$TMP/cap/s2act-drift" "$SC_S2ACT_DRIFT" --check "$SLUG"
assert_eq "s2act-drift --check exits 1" "1" "$RC"
grep -q "DRIFT actions-approve-off = can_approve_pull_request_reviews=true" <<<"$OUT" \
    && pass "approve-on is DRIFT (Actions must never approve its own PRs)" || fail "approve-on DRIFT" "$OUT"

section "S2 actions-approve-off: not readable under current scope -> SKIP"
run_provision "$TMP/cap/s2act-skip" "$SC_WIRED" --check "$SLUG"
grep -q "SKIP  actions-approve-off (not readable under current scope" <<<"$OUT" \
    && pass "today's App 403 skips" || fail "App 403 skips" "$OUT"

section "S2 deploy-key-inventory: not readable under current scope -> SKIP"
run_provision "$TMP/cap/s2keys-unreadable" "$SC_WIRED" --check "$SLUG"
grep -q "SKIP  deploy-key-inventory (not readable under current scope" <<<"$OUT" \
    && pass "today's App 403 skips" || fail "App 403 skips" "$OUT"

SC_S2KEYS="$SCEN/s2keys"
mk_minimal_repo "$SC_S2KEYS"
jq -n '[{id:1,title:"ci-deploy-key"}]' > "$SC_S2KEYS/keys.json"

section "S2 deploy-key-inventory: keys present, no declared allow-set -> SKIP (cannot verify a policy that isn't declared)"
run_provision "$TMP/cap/s2keys-noallow" "$SC_S2KEYS" --check "$SLUG"
grep -q "SKIP  deploy-key-inventory" <<<"$OUT" && grep -q "no declared allow-set to verify against" <<<"$OUT" \
    && pass "keys present but no declared policy skips, never guessed" || fail "no declared allow-set skips" "$OUT"

DJ_KEYSOK="$TMP/declared-keys-ok.json"
mk_declared_repo_json "$DJ_KEYSOK" '{"deploy_keys_allow": ["ci-deploy-key"]}'
section "S2 deploy-key-inventory: every key in the declared allow-set -> OK"
run_provision "$TMP/cap/s2keys-ok" "$SC_S2KEYS" --check --declared-json "$DJ_KEYSOK" "$SLUG"
grep -q "OK    deploy-key-inventory = 1 deploy key(s), all in the declared allow-set" <<<"$OUT" \
    && pass "an allow-listed key is OK" || fail "allow-listed key OK" "$OUT"

DJ_KEYSDRIFT="$TMP/declared-keys-drift.json"
mk_declared_repo_json "$DJ_KEYSDRIFT" '{"deploy_keys_allow": ["some-other-key"]}'
section "S2 deploy-key-inventory: an undeclared key -> DRIFT"
run_provision "$TMP/cap/s2keys-drift" "$SC_S2KEYS" --check --declared-json "$DJ_KEYSDRIFT" "$SLUG"
assert_eq "s2keys-drift --check exits 1" "1" "$RC"
grep -q "DRIFT deploy-key-inventory = undeclared key(s): ci-deploy-key" <<<"$OUT" \
    && pass "an undeclared key is DRIFT" || fail "undeclared key DRIFT" "$OUT"

# --- S2 readability guards: a REAL 403 body on stdout -> SKIP ----------------
# Regression proof for the guard bug: real `gh api` writes the 403 body to
# stdout and exits non-zero, so the old `== "null"` guard missed it and the
# class parsed the error object as data (env/secrets -> "OPERATOR_RULES absent",
# keys -> jq length of the error object = 2 -> "keys present"). The fixed guards
# gate on the expected shape and SKIP.
section "S2 env-secret-freshness: a real 403 on secrets -> SKIP (not false-DRIFT)"
SC_S2ENV_403="$SCEN/s2env-403"
mk_minimal_repo "$SC_S2ENV_403"
jq -n '{name:"default-branch"}' > "$SC_S2ENV_403/environments-default-branch.json"
write_403 "$SC_S2ENV_403" "environment-secrets-default-branch.json"
run_provision "$TMP/cap/s2env-403" "$SC_S2ENV_403" --check "$SLUG"
grep -q "SKIP  env-secret-freshness (not readable under current scope" <<<"$OUT" \
    && pass "a 403-body on secrets skips, never false-DRIFTs OPERATOR_RULES" || fail "403 secrets skips" "$OUT"

section "S2 actions-approve-off: a real 403 -> SKIP (not false-DRIFT)"
SC_S2ACT_403="$SCEN/s2act-403"
mk_minimal_repo "$SC_S2ACT_403"
write_403 "$SC_S2ACT_403" "actions-permissions-workflow.json"
run_provision "$TMP/cap/s2act-403" "$SC_S2ACT_403" --check "$SLUG"
grep -q "SKIP  actions-approve-off (not readable under current scope" <<<"$OUT" \
    && pass "a 403-body skips, never false-DRIFTs approve-on" || fail "403 approve skips" "$OUT"

section "S2 deploy-key-inventory: a real 403 -> SKIP (not counted as keys present)"
SC_S2KEYS_403="$SCEN/s2keys-403"
mk_minimal_repo "$SC_S2KEYS_403"
write_403 "$SC_S2KEYS_403" "keys.json"
DJ_KEYS403="$TMP/declared-keys-403.json"
mk_declared_repo_json "$DJ_KEYS403" '{"deploy_keys_allow": ["ci-deploy-key"]}'
run_provision "$TMP/cap/s2keys-403" "$SC_S2KEYS_403" --check --declared-json "$DJ_KEYS403" "$SLUG"
grep -q "SKIP  deploy-key-inventory (not readable under current scope" <<<"$OUT" \
    && pass "a 403-body skips, never counts the error object as keys" || fail "403 keys skips" "$OUT"

# --- secret_scanning readability (Bug A): absent security_and_analysis ------
# Under the App token repos/<repo> is readable but .security_and_analysis is
# null/absent. That is "not readable under current scope" — SKIP, never a false
# "unknown -> DRIFT". Under a full-scope token the field is present and a
# disabled status is reported as real DRIFT (the full-read case below).
section "secret_scanning: security_and_analysis absent -> SKIP (not false 'unknown' DRIFT)"
SC_SS_ABSENT="$SCEN/ss-absent"
mk_minimal_repo "$SC_SS_ABSENT"
jq 'del(.security_and_analysis)' "$SC_SS_ABSENT/repo.json" > "$SC_SS_ABSENT/repo.json.tmp" \
    && mv "$SC_SS_ABSENT/repo.json.tmp" "$SC_SS_ABSENT/repo.json"
run_provision "$TMP/cap/ss-absent" "$SC_SS_ABSENT" --check "$SLUG"
grep -q "SKIP  secret_scanning (not readable under current scope" <<<"$OUT" \
    && pass "an unreadable security_and_analysis skips, never false-DRIFTs unknown" || fail "unreadable secret_scanning skips" "$OUT"

section "secret_scanning: full read, status disabled -> DRIFT (no masking under full scope)"
SC_SS_DIS="$SCEN/ss-disabled"
write_repo "$SC_SS_DIS" main good off   # secret=off -> security_and_analysis present, status disabled
echo '[]' > "$SC_SS_DIS/rulesets.json"
run_provision "$TMP/cap/ss-disabled" "$SC_SS_DIS" --check "$SLUG"
grep -q "DRIFT secret_scanning = disabled" <<<"$OUT" \
    && pass "a readable disabled status is DRIFT, proving the SKIP fix does not mask" || fail "disabled secret_scanning DRIFT" "$OUT"

# ============================================================================
section "bad arguments are rejected"
OUT="$(GH="$STUB" bash "$SCRIPT" --check 2>&1)"; RC=$?
assert_eq "missing owner/repo exits 2" "2" "$RC"
OUT="$(GH="$STUB" bash "$SCRIPT" --check not-a-slug 2>&1)"; RC=$?
assert_eq "malformed slug exits 2" "2" "$RC"
OUT="$(GH="$STUB" bash "$SCRIPT" --rules 2>&1)"; RC=$?
assert_eq "--rules with no value exits 2" "2" "$RC"

# ============================================================================
# Declared enforcement + bypass_actors (the branch-ruleset anti-lockout fields):
# a repo that declares them has them OWNED (written on converge, drifted on
# --check); a repo that declares neither keeps the prior behavior (enforcement
# forced active, bypass preserved). Fixture = the real declared JSON + an
# acme/widgets entry so the top-level required fields stay valid.
DECL_FIX="$TMP/decl-with-widgets.json"
jq '.repos["acme/widgets"] = {enforcement:"evaluate", bypass_actors:[{actor_type:"RepositoryRole", actor_id:5, bypass_mode:"pull_request"}]}' \
    "$SCRIPT_DIR/../../rulesets/default-branch.json" > "$DECL_FIX"

section "declared enforcement + bypass_actors: converge writes them"
run_provision "$TMP/cap/widgets-conv" "$SC_WIRED" --declared-json "$DECL_FIX" "$SLUG"
CONV_BODY="$TMP/cap/widgets-conv/PUT_repos_acme_widgets_rulesets_1.body"
assert_eq "converge PUT the branch ruleset" "yes" "$([[ -f "$CONV_BODY" ]] && echo yes || echo no)"
assert_eq "converge writes the declared enforcement (evaluate)" "evaluate" "$(jq -r '.enforcement' "$CONV_BODY" 2>/dev/null)"
assert_eq "converge writes the declared bypass actor" \
    '[{"actor_type":"RepositoryRole","actor_id":5,"bypass_mode":"pull_request"}]' \
    "$(jq -c '.bypass_actors' "$CONV_BODY" 2>/dev/null)"

section "declared enforcement + bypass_actors: --check drifts when live differs"
run_provision "$TMP/cap/widgets-check" "$SC_WIRED" --check --declared-json "$DECL_FIX" "$SLUG"
assert_eq "declared-fields --check exits 1 (drift)" "1" "$RC"
grep -q 'ruleset.enforcement' <<<"$OUT" && pass "--check reports enforcement drift" || fail "enforcement drift line" "$OUT"
grep -q 'ruleset.bypass_actors' <<<"$OUT" && pass "--check reports bypass_actors drift" || fail "bypass_actors drift line" "$OUT"

section "an undeclared repo keeps the prior behavior (active, bypass preserved)"
# The real declared JSON has no acme/widgets entry, so enforcement defaults to
# active (== the wired live ruleset) and bypass_actors are not owned -> clean.
run_provision "$TMP/cap/widgets-default" "$SC_WIRED" --check "$SLUG"
assert_eq "undeclared --check exits 0 (no enforcement/bypass drift introduced)" "0" "$RC"

section "declared bypass_actors: identical content in a different key order is NOT drift"
# GitHub returns each bypass actor key-alphabetized ({actor_id, actor_type,
# bypass_mode}); the declared JSON writes them {actor_type, actor_id,
# bypass_mode}. sort_by orders the array but not the keys inside each element,
# so a byte compare would false-DRIFT on order alone — the --check must
# canonicalize BOTH sides (jq -S) before comparing. Live ruleset here carries
# the declared actor's exact content in GitHub's key order; declared carries it
# in the JSON's order; enforcement matches, so the ONLY thing under test is the
# bypass comparison.
SC_KEYORDER="$SCEN/bypass-key-order"
cp -r "$SC_WIRED" "$SC_KEYORDER"
jq '.bypass_actors = [{"actor_id":5,"actor_type":"RepositoryRole","bypass_mode":"pull_request"}]' \
    "$SC_KEYORDER/ruleset-1.json" > "$SC_KEYORDER/ruleset-1.json.tmp" \
    && mv "$SC_KEYORDER/ruleset-1.json.tmp" "$SC_KEYORDER/ruleset-1.json"
DECL_KEYORDER="$TMP/decl-key-order.json"
jq '.repos["acme/widgets"] = {enforcement:"active", bypass_actors:[{actor_type:"RepositoryRole", actor_id:5, bypass_mode:"pull_request"}]}' \
    "$SCRIPT_DIR/../../rulesets/default-branch.json" > "$DECL_KEYORDER"
run_provision "$TMP/cap/keyorder-check" "$SC_KEYORDER" --check --declared-json "$DECL_KEYORDER" "$SLUG"
assert_eq "key-order-only --check exits 0 (no drift introduced)" "0" "$RC"
grep -Eq 'OK +ruleset\.bypass_actors' <<<"$OUT" \
    && pass "bypass_actors reported OK when content matches (key order ignored)" \
    || fail "expected an OK ruleset.bypass_actors line" "$OUT"
grep -Eq 'DRIFT +ruleset\.bypass_actors' <<<"$OUT" \
    && fail "key-order-only difference must NOT be bypass_actors drift" "$OUT" \
    || pass "no false bypass_actors drift on a key-order-only difference"

section "shipped default-branch.json: probe requires margot + the anti-lockout fields"
DECL_SHIPPED="$SCRIPT_DIR/../../rulesets/default-branch.json"
assert_eq "probe required_contexts includes margot" "true" \
    "$(jq -r '.repos["lexijamesesq/probe-local-to-merged"].required_contexts | any(. == "margot")' "$DECL_SHIPPED")"
assert_eq "probe enforcement is active" "active" \
    "$(jq -r '.repos["lexijamesesq/probe-local-to-merged"].enforcement' "$DECL_SHIPPED")"
assert_eq "probe declares a RepositoryRole admin pull_request bypass" "true" \
    "$(jq -r '.repos["lexijamesesq/probe-local-to-merged"].bypass_actors | any(.actor_type=="RepositoryRole" and .actor_id==5 and .bypass_mode=="pull_request")' "$DECL_SHIPPED")"

finish
