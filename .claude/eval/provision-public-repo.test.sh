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
# see git-hooks/gitleaks-common.sh's gl_overlay_path). The suite pins
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
# python3 backs the codeowners-policy matcher (.github/scripts/codeowners-drift.py);
# a missing interpreter would silently SKIP the coverage cases, not fail — so it
# is a hard suite dependency, same posture as jq/git.
command -v python3 >/dev/null 2>&1 || { echo "FATAL: python3 not on PATH — suite cannot run."; exit 2; }

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
fields=()

while [[ $# -gt 0 ]]; do
    case "$1" in
        api) saw_api=1; shift ;;
        -X|--method) method="${2:-}"; shift 2 ;;
        --input) [[ "${2:-}" == "-" ]] && read_stdin=1; shift 2 ;;
        -f|--field|-F|--raw-field) fields+=("${2:-}"); shift 2 ;;
        -H|--header|--jq|-q|--template|-t) shift 2 ;;
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
        # The -f/-F fields, recorded so a test can assert on WHAT was written.
        if [[ ${#fields[@]} -gt 0 ]]; then
            printf '%s\n' "${fields[@]}" > "$GH_STUB_CAPTURE/${method}_${path//\//_}.fields"
        fi
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
        pulls)
            echo '{"html_url":"https://example.invalid/pr/1","number":1}'
            exit 0
            ;;
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
    "git/ref/heads/main") f="git-refs-heads-main.json" ;;
    git/ref/heads/*)     f="git-ref-${rest#git/ref/heads/}.json" ;;
    git/trees/*)         f="git-trees-${rest#git/trees/}.json" ;;
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
# write_ruleset <dir> <base-id> <branch> <comma-separated-rule-types>
#
# Writes ONE FIXTURE RULESET PER DECLARED ENTRY in `.branch_rulesets`, not one
# combined ruleset. The declaration is two (review / checks) because bypass is
# per-ruleset and a single object would let a review bypass also waive the
# up-to-date rule — so a fixture modelling one ruleset cannot represent the thing
# under test at all.
#
# <rule-types> is still "which rules exist LIVE", and each declared ruleset gets
# the intersection of that list with the rules it declares. A scenario omitting a
# rule therefore produces a live ruleset genuinely missing it, which is what the
# drift cases need.
#
# ids: the FIRST declared entry takes base-id and each later one base-id+10*i,
# deliberately NOT base-id+1 — scenarios call `write_ruleset <dir> 1 ...` then
# `add_tag_ruleset <dir> 2 ...`, so consecutive ids would collide the second
# branch ruleset with the tag ruleset. So `ruleset-1.json` is the first declared
# ruleset (review) and `ruleset-11.json` the second (checks).
write_ruleset() {
    local dir="$1" id="$2" branch="$3" types="$4"
    mkdir -p "$dir"
    local decl="$SCRIPT_DIR/../../rulesets/default-branch.json"
    local live_types_json n i rid dname drules dbypass rules listing="[]"
    live_types_json="$(printf '%s' "$types" | jq -Rc 'split(",") | map(select(length>0))')"
    n="$(jq -r '.branch_rulesets | length' "$decl")"
    for (( i=0; i<n; i++ )); do
        rid=$(( id + (i * 10) ))
        dname="$(jq -r --argjson i "$i" '.branch_rulesets[$i].name' "$decl")"
        drules="$(jq -c --argjson i "$i" '.branch_rulesets[$i].rules' "$decl")"
        # The declared bypass set for THIS ruleset, in GitHub's own key order.
        # Read from the real declaration rather than restated here, so adding an
        # actor there never leaves these fixtures describing a state that is gone.
        dbypass="$(jq -c --argjson i "$i" '[(.branch_rulesets[$i].bypass_actors // [])[] | {actor_id, actor_type, bypass_mode}]' "$decl")"
        rules="$(jq -nc --argjson live "$live_types_json" --argjson own "$drules" '
            [ $own[] | select(. as $t | $live | index($t))
              | if . == "required_status_checks"
                then {type:"required_status_checks", parameters:{required_status_checks:[{context:"eval-suite"}], strict_required_status_checks_policy:false}}
                elif . == "pull_request"
                then {type:"pull_request", parameters:{required_approving_review_count:0, dismiss_stale_reviews_on_push:true, require_code_owner_review:true, require_last_push_approval:false, required_review_thread_resolution:false, require_extra_approval_for_unattributed_changes:true}}
                else {type:.} end ]')"
        jq -n --argjson id "$rid" --arg branch "refs/heads/$branch" --arg name "$dname" \
              --argjson rules "$rules" --argjson bypass "$dbypass" '{
            id: $id,
            name: $name,
            target: "branch",
            enforcement: "active",
            bypass_actors: $bypass,
            conditions: { ref_name: { include: [$branch], exclude: [] } },
            rules: $rules
        }' > "$dir/ruleset-$rid.json"
        listing="$(jq -c --argjson l "$listing" --argjson id "$rid" --arg name "$dname" \
            '$l + [{id:$id, name:$name, target:"branch"}]' <<<'null')"
    done
    printf '%s\n' "$listing" > "$dir/rulesets.json"
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

# write_tree <dir> <paths-json-array> [truncated:true|false] — the git/trees
# recursive fixture the codeowners-policy class fetches (default branch "main").
# Every path is a blob; the class filters to blobs and resolves the declared
# owned patterns against these real paths. truncated defaults to false.
write_tree() {
    local dir="$1" paths="$2" truncated="${3:-false}"
    mkdir -p "$dir"
    jq -n --argjson paths "$paths" --argjson trunc "$truncated" \
        '{sha: "treesha", truncated: $trunc, tree: [$paths[] | {path: ., type: "blob", mode: "100644"}]}' \
        > "$dir/git-trees-main.json"
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
# (what dotty's release-on-merge job publishes; dotty_latest_tag's authoritative source).
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


# intended_template <function-name> — the exact body of one of the script's
# own caller templates, extracted from its heredoc. Single-sourced on purpose:
# a fixture that hard-coded a copy would drift from the thing it is meant to
# represent, and the suite would go on passing while the two diverged. If the
# heredoc marker ever changes, this extraction returns nothing and every
# caller-ownership case fails loudly rather than silently comparing "" to "".
intended_template() {
    # Bounded by the HEREDOC MARKER, not by a closing brace. An earlier version
    # scanned from the function header to the first line that was exactly `}`,
    # which works until a template's own content contains one — and the
    # renovate.json template is JSON, so its closing brace sits at column 0 and
    # truncated the extraction to nothing. The fixture then never matched and
    # every "fully wired" scenario reported false drift.
    awk -v fn="$1" '
        $0 ~ "^"fn"\\(\\) \\{" { inf = 1; next }
        inf && !marker && match($0, /<<.[A-Z_]+_EOF./) {
            marker = $0; sub(/^.*<</, "", marker); gsub(/[^A-Z_]/, "", marker); next
        }
        inf && marker && $0 == marker { exit }
        inf && marker { print }
    ' "$SCRIPT"
}

# write_callers_ok <dir> — the three caller surfaces this tool owns, at the
# intended shape, so a scenario meant to be "fully wired" genuinely is. Without
# this, every wired fixture reports caller drift and the suite's own definition
# of wired would disagree with the tool's.
write_callers_ok() {
    local dir="$1"
    write_contents "$dir" ".github/workflows/margot.yml" "$(intended_template intended_margot_yml)"
    write_contents "$dir" "renovate.json"                "$(intended_template intended_renovate_json)"
    write_contents "$dir" ".github/pull_request_template.md" "$(cat "$SCRIPT_DIR/../../.github/pull_request_template.md")"
}

# write_head_ref <dir> [sha] — the default branch's tip, which the caller
# rollout reads before cutting its branch from it.
write_head_ref() {
    jq -n --arg s "${2:-basesha0000000000000000000000000000000000}" \
        '{object: {sha: $s, type: "commit"}}' > "$1/git-refs-heads-main.json"
}

write_core_call_ok() {
    local dir="$1" ref="${2:-v1}"
    mkdir -p "$dir"
    write_callers_ok "$dir"
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
# Split into the two declared rulesets — a fixture modelling one
# combined ruleset cannot represent a per-ruleset bypass at all.
echo '[{"id":3,"name":"Protect main \u2014 review","target":"branch"},{"id":13,"name":"Protect main \u2014 checks","target":"branch"}]' > "$SC_PRCOUNT/rulesets.json"
cat > "$SC_PRCOUNT/ruleset-3.json" <<'EOF'
{
  "id": 3,
  "name": "Protect main \u2014 review",
  "target": "branch",
  "enforcement": "active",
  "bypass_actors": [
    {
      "actor_id": 5,
      "actor_type": "RepositoryRole",
      "bypass_mode": "pull_request"
    },
    {
      "actor_id": 2740,
      "actor_type": "Integration",
      "bypass_mode": "pull_request"
    }
  ],
  "conditions": {
    "ref_name": {
      "include": [
        "refs/heads/main"
      ],
      "exclude": []
    }
  },
  "rules": [
    {
      "type": "pull_request",
      "parameters": {
        "required_approving_review_count": 2,
        "dismiss_stale_reviews_on_push": false,
        "require_code_owner_review": false,
        "require_last_push_approval": false,
        "required_review_thread_resolution": false,
        "allowed_merge_methods": [
          "squash"
        ]
      }
    }
  ]
}
EOF
cat > "$SC_PRCOUNT/ruleset-13.json" <<'EOF'
{
  "id": 13,
  "name": "Protect main \u2014 checks",
  "target": "branch",
  "enforcement": "active",
  "bypass_actors": [
    {
      "actor_id": 5,
      "actor_type": "RepositoryRole",
      "bypass_mode": "pull_request"
    }
  ],
  "conditions": {
    "ref_name": {
      "include": [
        "refs/heads/main"
      ],
      "exclude": []
    }
  },
  "rules": [
    {
      "type": "non_fast_forward"
    },
    {
      "type": "deletion"
    },
    {
      "type": "required_status_checks",
      "parameters": {
        "required_status_checks": [
          {
            "context": "eval-suite"
          }
        ],
        "strict_required_status_checks_policy": true
      }
    }
  ]
}
EOF
write_reporter "$SC_PRCOUNT" "deadbeef03" "eval-suite" 15368
add_tag_ruleset "$SC_PRCOUNT" 6 ok

# 9. pr-extra — owned params AT intent, plus extra GitHub keys. Must be no-drift.
SC_PREXTRA="$SCEN/pr-extra"
write_repo "$SC_PREXTRA" main good on
# Split into the two declared rulesets — a fixture modelling one
# combined ruleset cannot represent a per-ruleset bypass at all.
echo '[{"id":4,"name":"Protect main \u2014 review","target":"branch"},{"id":14,"name":"Protect main \u2014 checks","target":"branch"}]' > "$SC_PREXTRA/rulesets.json"
cat > "$SC_PREXTRA/ruleset-4.json" <<'EOF'
{
  "id": 4,
  "name": "Protect main \u2014 review",
  "target": "branch",
  "enforcement": "active",
  "bypass_actors": [
    {
      "actor_id": 5,
      "actor_type": "RepositoryRole",
      "bypass_mode": "pull_request"
    },
    {
      "actor_id": 2740,
      "actor_type": "Integration",
      "bypass_mode": "pull_request"
    }
  ],
  "conditions": {
    "ref_name": {
      "include": [
        "refs/heads/main"
      ],
      "exclude": []
    }
  },
  "rules": [
    {
      "type": "pull_request",
      "parameters": {
        "required_approving_review_count": 0,
        "dismiss_stale_reviews_on_push": true,
        "require_code_owner_review": true,
        "require_last_push_approval": false,
        "required_review_thread_resolution": false,
        "require_extra_approval_for_unattributed_changes": true,
        "allowed_merge_methods": [
          "squash"
        ],
        "automatic_copilot_code_review_enabled": false
      }
    }
  ]
}
EOF
cat > "$SC_PREXTRA/ruleset-14.json" <<'EOF'
{
  "id": 14,
  "name": "Protect main \u2014 checks",
  "target": "branch",
  "enforcement": "active",
  "bypass_actors": [
    {
      "actor_id": 5,
      "actor_type": "RepositoryRole",
      "bypass_mode": "pull_request"
    }
  ],
  "conditions": {
    "ref_name": {
      "include": [
        "refs/heads/main"
      ],
      "exclude": []
    }
  },
  "rules": [
    {
      "type": "non_fast_forward"
    },
    {
      "type": "deletion"
    }
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
# Split into the two declared rulesets — a fixture modelling one
# combined ruleset cannot represent a per-ruleset bypass at all.
echo '[{"id":9,"name":"Protect main \u2014 review","target":"branch"},{"id":19,"name":"Protect main \u2014 checks","target":"branch"}]' > "$SC_STRICTUNBOUND/rulesets.json"
cat > "$SC_STRICTUNBOUND/ruleset-9.json" <<'EOF'
{
  "id": 9,
  "name": "Protect main \u2014 review",
  "target": "branch",
  "enforcement": "active",
  "bypass_actors": [
    {
      "actor_id": 5,
      "actor_type": "RepositoryRole",
      "bypass_mode": "pull_request"
    },
    {
      "actor_id": 2740,
      "actor_type": "Integration",
      "bypass_mode": "pull_request"
    }
  ],
  "conditions": {
    "ref_name": {
      "include": [
        "refs/heads/main"
      ],
      "exclude": []
    }
  },
  "rules": [
    {
      "type": "pull_request",
      "parameters": {
        "required_approving_review_count": 0,
        "dismiss_stale_reviews_on_push": false,
        "require_code_owner_review": false,
        "require_last_push_approval": false,
        "required_review_thread_resolution": false
      }
    }
  ]
}
EOF
cat > "$SC_STRICTUNBOUND/ruleset-19.json" <<'EOF'
{
  "id": 19,
  "name": "Protect main \u2014 checks",
  "target": "branch",
  "enforcement": "active",
  "bypass_actors": [
    {
      "actor_id": 5,
      "actor_type": "RepositoryRole",
      "bypass_mode": "pull_request"
    }
  ],
  "conditions": {
    "ref_name": {
      "include": [
        "refs/heads/main"
      ],
      "exclude": []
    }
  },
  "rules": [
    {
      "type": "non_fast_forward"
    },
    {
      "type": "deletion"
    },
    {
      "type": "required_status_checks",
      "parameters": {
        "strict_required_status_checks_policy": false,
        "required_status_checks": [
          {
            "context": "shellcheck"
          },
          {
            "context": "ghost-check"
          }
        ]
      }
    }
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
# The CHECKS ruleset's PUT body — required_status_checks, its strict flag and
# its context bindings all live there now.
PUTBODY="$CAP/PUT_repos_acme_widgets_rulesets_11.body"
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
# pull_request now belongs to the REVIEW ruleset, which this scenario's fixture
# carries at id 1. Asserting it against the checks body would be asserting the
# split had not happened.
PUTBODY_REVIEW="$CAP/PUT_repos_acme_widgets_rulesets_1.body"
if [[ -f "$PUTBODY_REVIEW" ]] && jq -e '.rules | map(.type) | index("pull_request") != null' "$PUTBODY_REVIEW" >/dev/null 2>&1; then
    pass "review PUT body ADDS pull_request"
else
    fail "review PUT body ADDS pull_request" "$(cat "$PUTBODY_REVIEW" 2>/dev/null)"
fi
# And the two bodies must NOT overlap: pull_request out of checks, rsc out of
# review. That is the property the split exists for, asserted on the wire.
if [[ -f "$PUTBODY" ]] && jq -e '.rules | map(.type) | index("pull_request") == null' "$PUTBODY" >/dev/null 2>&1; then
    pass "checks PUT body carries NO pull_request rule"
else
    fail "checks PUT body carries NO pull_request rule" "$(cat "$PUTBODY" 2>/dev/null)"
fi
if [[ -f "$PUTBODY_REVIEW" ]] && jq -e '.rules | map(.type) | index("required_status_checks") == null' "$PUTBODY_REVIEW" >/dev/null 2>&1; then
    pass "review PUT body carries NO required_status_checks rule"
else
    fail "review PUT body carries NO required_status_checks rule" "$(cat "$PUTBODY_REVIEW" 2>/dev/null)"
fi
if [[ -f "$PUTBODY" ]]; then
    assert_eq "PUT body enforcement active"            "active"          "$(jq -r '.enforcement' "$PUTBODY")"
    assert_eq "PUT body preserves conditions include"  "refs/heads/main" "$(jq -r '.conditions.ref_name.include[0]' "$PUTBODY")"
    assert_eq "pull_request review count is 0 (solo operator)" "0" \
        "$(jq -r '.rules[] | select(.type=="pull_request") | .parameters.required_approving_review_count' "$PUTBODY_REVIEW")"
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
    # required_status_checks is no longer in THIS body — it belongs to the
    # checks ruleset, which this scenario's fixture carries at id 13.
    PBCK="$CAP/PUT_repos_acme_widgets_rulesets_13.body"
    jq -e '.rules[] | select(.type=="required_status_checks") | .parameters.strict_required_status_checks_policy == true' "$PBCK" >/dev/null 2>&1 \
        && pass "required_status_checks preserved byte-for-byte" || fail "required_status_checks preserved" "$(cat "$PBCK" 2>/dev/null)"
    # THE OWNERSHIP BOUNDARY, stated as a test. This scenario's live ruleset
    # carries an undeclared Team actor (42). Before the estate declared a
    # top-level `.bypass_actors`, the field was preserved and 42 survived a
    # converge. It is now OWNED for every repo, and 42 is REPLACED by the
    # declared set — because the merge identity has to be present on every
    # enrolled repo for the autonomous bot path to work anywhere, and a field
    # that is owned on some repos and preserved on others is a field nobody can
    # reason about. The cost is real and is the point of this assertion: a
    # bypass actor added by hand and never written down is converged away. The
    # declared JSON is where a bypass actor lives.
    assert_eq "undeclared live bypass actor is OWNED away, not preserved" "" \
        "$(jq -r '.bypass_actors[] | select(.actor_id == 42) | .actor_id // empty' "$PB")"
    assert_eq "converge writes the declared bypass set (admin + the merge App)" \
        '[{"actor_id":5,"actor_type":"RepositoryRole","bypass_mode":"pull_request"},{"actor_id":2740,"actor_type":"Integration","bypass_mode":"pull_request"}]' \
        "$(jq -cS '.bypass_actors | sort_by(.actor_id)' "$PB")"
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
# The CHECKS ruleset's PUT body — required_status_checks, its strict flag and
# its context bindings all live there now.
SUPUT="$CAP/PUT_repos_acme_widgets_rulesets_19.body"
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
# The CHECKS ruleset's PUT body (id 11 — see write_ruleset's id note). The
# context list, the strict flag and the required_status_checks rule all live
# there; only pull_request is written to the review ruleset (id 1).
BRPUT="$CAP/PUT_repos_acme_widgets_rulesets_11.body"
if [[ -f "$BRPUT" ]]; then
    pass "ruleset PUT issued"
    # The three owned rules are now spread across the TWO rulesets, which is the
    # split working: the checks body carries non_fast_forward + deletion, the
    # review body carries pull_request. Asserting all three in one body would be
    # asserting the split had not happened.
    jq -e '.rules | map(.type) | index("non_fast_forward") != null and index("deletion") != null' "$BRPUT" >/dev/null 2>&1 \
        && pass "the checks ruleset gains non_fast_forward + deletion" \
        || fail "the checks ruleset gains non_fast_forward + deletion" "$(jq -c '.rules | map(.type)' "$BRPUT")"
    BRPUT_REVIEW="$CAP/PUT_repos_acme_widgets_rulesets_1.body"
    jq -e '.rules | map(.type) | index("pull_request") != null' "$BRPUT_REVIEW" >/dev/null 2>&1 \
        && pass "the review ruleset gains pull_request" \
        || fail "the review ruleset gains pull_request" "$(jq -c '.rules | map(.type)' "$BRPUT_REVIEW" 2>/dev/null)"
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
# _decl_brs — the two declared branch rulesets, read from the REAL declaration
# so these fixtures never describe a shape that no longer exists. Every builder
# below injects it: the loader FATALs without `.branch_rulesets`, and a fixture
# that omitted it would fail for a reason that has nothing to do with its case.
_decl_brs() { jq -c '.branch_rulesets' "$SCRIPT_DIR/../../rulesets/default-branch.json"; }

mk_declared_json() { # <path> <required_contexts-json-array>
    jq -n --argjson rc "$2" --arg slug "$SLUG" --argjson brs "$(_decl_brs)" '{
        pull_request: {required_approving_review_count:0, dismiss_stale_reviews_on_push:true, require_code_owner_review:true, require_last_push_approval:false, required_review_thread_resolution:false, require_extra_approval_for_unattributed_changes:true},
        required_status_checks: {strict_required_status_checks_policy: true},
        branch_rulesets: $brs,
        tag_ruleset: {name: "Tag immutability", rules: ["update","deletion"]},
        repos: {($slug): {required_contexts: $rc}}
    }' > "$1"
}

# mk_declared_repo_json <path> <repos-slug-object-json> — like mk_declared_json
# above, but the caller supplies the WHOLE `.repos[$SLUG]` object (the
# mechanical classes: core_call_exempt / private_repo / admin_exceptions /
# deploy_keys_allow — never all of them at once, so a fixed shape doesn't fit).
mk_declared_repo_json() {
    jq -n --argjson robj "$2" --arg slug "$SLUG" --argjson brs "$(_decl_brs)" '{
        pull_request: {required_approving_review_count:0, dismiss_stale_reviews_on_push:true, require_code_owner_review:true, require_last_push_approval:false, required_review_thread_resolution:false, require_extra_approval_for_unattributed_changes:true},
        required_status_checks: {strict_required_status_checks_policy: true},
        branch_rulesets: $brs,
        tag_ruleset: {name: "Tag immutability", rules: ["update","deletion"]},
        repos: {($slug): $robj}
    }' > "$1"
}

# mk_declared_codeowners <path> <owner|""> <required-json|"absent"> \
#                        <repo-owned-json|"absent"> [full_owned:true|false] —
# a declared JSON for the un-inverted codeowners-policy class, which reads two
# global keys (.codeowners_owner, .codeowners_required_owned) and two per-repo
# keys (.codeowners_owned, .codeowners_full_owned). Pass "" for the owner to
# OMIT .codeowners_owner (the no-policy skip); "absent" for required to OMIT
# .codeowners_required_owned (the no-floor skip); "absent" for repo-owned to
# OMIT .repos[$SLUG].codeowners_owned (the per-repo skip). full_owned defaults
# false; pass true to set .repos[$SLUG].codeowners_full_owned.
mk_declared_codeowners() {
    local path="$1" owner="$2" required="$3" repo_owned="$4" full="${5:-false}"
    local robj='{}' base
    if [[ "$repo_owned" != "absent" ]]; then
        robj="$(jq -c -n --argjson a "$repo_owned" '{codeowners_owned: $a}')"
    fi
    if [[ "$full" == "true" ]]; then
        robj="$(jq -c -n --argjson r "$robj" '$r + {codeowners_full_owned: true}')"
    fi
    base="$(jq -n --argjson robj "$robj" --arg slug "$SLUG" --argjson brs "$(_decl_brs)" '{
        pull_request: {required_approving_review_count:0, dismiss_stale_reviews_on_push:true, require_code_owner_review:true, require_last_push_approval:false, required_review_thread_resolution:false, require_extra_approval_for_unattributed_changes:true},
        required_status_checks: {strict_required_status_checks_policy: true},
        branch_rulesets: $brs,
        tag_ruleset: {name: "Tag immutability", rules: ["update","deletion"]},
        repos: {($slug): $robj}
    }')"
    if [[ -n "$owner" ]]; then
        base="$(jq -c --arg o "$owner" '.codeowners_owner = $o' <<<"$base")"
    fi
    if [[ "$required" != "absent" ]]; then
        base="$(jq -c --argjson r "$required" '.codeowners_required_owned = $r' <<<"$base")"
    fi
    printf '%s\n' "$base" > "$path"
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
# The CHECKS ruleset's PUT body (id 11 — see write_ruleset's id note). The
# context list, the strict flag and the required_status_checks rule all live
# there; only pull_request is written to the review ruleset (id 1).
CTXADDPUT="$CAP/PUT_repos_acme_widgets_rulesets_11.body"
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
# Split into the two declared rulesets — a fixture modelling one
# combined ruleset cannot represent a per-ruleset bypass at all.
echo '[{"id":1,"name":"Protect main \u2014 review","target":"branch"},{"id":11,"name":"Protect main \u2014 checks","target":"branch"}]' > "$SC_CTXRM/rulesets.json"
cat > "$SC_CTXRM/ruleset-1.json" <<'EOF'
{
  "id": 1,
  "name": "Protect main \u2014 review",
  "target": "branch",
  "enforcement": "active",
  "bypass_actors": [
    {
      "actor_id": 5,
      "actor_type": "RepositoryRole",
      "bypass_mode": "pull_request"
    },
    {
      "actor_id": 2740,
      "actor_type": "Integration",
      "bypass_mode": "pull_request"
    }
  ],
  "conditions": {
    "ref_name": {
      "include": [
        "refs/heads/main"
      ],
      "exclude": []
    }
  },
  "rules": [
    {
      "type": "pull_request",
      "parameters": {
        "required_approving_review_count": 0,
        "dismiss_stale_reviews_on_push": true,
        "require_code_owner_review": true,
        "require_last_push_approval": false,
        "required_review_thread_resolution": false,
        "require_extra_approval_for_unattributed_changes": true
      }
    }
  ]
}
EOF
cat > "$SC_CTXRM/ruleset-11.json" <<'EOF'
{
  "id": 11,
  "name": "Protect main \u2014 checks",
  "target": "branch",
  "enforcement": "active",
  "bypass_actors": [
    {
      "actor_id": 5,
      "actor_type": "RepositoryRole",
      "bypass_mode": "pull_request"
    }
  ],
  "conditions": {
    "ref_name": {
      "include": [
        "refs/heads/main"
      ],
      "exclude": []
    }
  },
  "rules": [
    {
      "type": "non_fast_forward"
    },
    {
      "type": "deletion"
    },
    {
      "type": "required_status_checks",
      "parameters": {
        "strict_required_status_checks_policy": true,
        "required_status_checks": [
          {
            "context": "eval-suite",
            "integration_id": 15368
          },
          {
            "context": "stale-check",
            "integration_id": 15368
          }
        ]
      }
    }
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
# The CHECKS ruleset's PUT body (id 11 — see write_ruleset's id note). The
# context list, the strict flag and the required_status_checks rule all live
# there; only pull_request is written to the review ruleset (id 1).
CTXRMPUT="$CAP/PUT_repos_acme_widgets_rulesets_11.body"
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
# The CHECKS ruleset's PUT body (id 11 — see write_ruleset's id note). The
# context list, the strict flag and the required_status_checks rule all live
# there; only pull_request is written to the review ruleset (id 1).
CTXREFPUT="$CAP/PUT_repos_acme_widgets_rulesets_11.body"
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
# A scenario that asserts "fully wired, no drift" has to be wired on EVERY class
# this tool owns, caller surfaces included — otherwise the suite's idea of wired
# and the tool's quietly diverge and the assertion stops meaning anything.
write_core_call_ok "$SC_CTXNOOP"
mkdir -p "$SC_CTXNOOP"
# Split into the two declared rulesets — a fixture modelling one
# combined ruleset cannot represent a per-ruleset bypass at all.
echo '[{"id":1,"name":"Protect main \u2014 review","target":"branch"},{"id":11,"name":"Protect main \u2014 checks","target":"branch"}]' > "$SC_CTXNOOP/rulesets.json"
cat > "$SC_CTXNOOP/ruleset-1.json" <<'EOF'
{
  "id": 1,
  "name": "Protect main \u2014 review",
  "target": "branch",
  "enforcement": "active",
  "bypass_actors": [
    {
      "actor_id": 5,
      "actor_type": "RepositoryRole",
      "bypass_mode": "pull_request"
    },
    {
      "actor_id": 2740,
      "actor_type": "Integration",
      "bypass_mode": "pull_request"
    }
  ],
  "conditions": {
    "ref_name": {
      "include": [
        "refs/heads/main"
      ],
      "exclude": []
    }
  },
  "rules": [
    {
      "type": "pull_request",
      "parameters": {
        "required_approving_review_count": 0,
        "dismiss_stale_reviews_on_push": true,
        "require_code_owner_review": true,
        "require_last_push_approval": false,
        "required_review_thread_resolution": false,
        "require_extra_approval_for_unattributed_changes": true
      }
    }
  ]
}
EOF
cat > "$SC_CTXNOOP/ruleset-11.json" <<'EOF'
{
  "id": 11,
  "name": "Protect main \u2014 checks",
  "target": "branch",
  "enforcement": "active",
  "bypass_actors": [
    {
      "actor_id": 5,
      "actor_type": "RepositoryRole",
      "bypass_mode": "pull_request"
    }
  ],
  "conditions": {
    "ref_name": {
      "include": [
        "refs/heads/main"
      ],
      "exclude": []
    }
  },
  "rules": [
    {
      "type": "non_fast_forward"
    },
    {
      "type": "deletion"
    },
    {
      "type": "required_status_checks",
      "parameters": {
        "strict_required_status_checks_policy": true,
        "required_status_checks": [
          {
            "context": "eval-suite",
            "integration_id": 15368
          }
        ]
      }
    }
  ]
}
EOF
add_tag_ruleset "$SC_CTXNOOP" 2 ok
write_core_call_ok "$SC_CTXNOOP"
DJ_NOOP="$TMP/declared-noop.json"
mk_declared_json "$DJ_NOOP" '["eval-suite"]'

run_provision "$TMP/cap/ctxnoop-check" "$SC_CTXNOOP" --check --declared-json "$DJ_NOOP" "$SLUG"
assert_eq "ctx-noop --check exits 0 (fully wired)" "0" "$RC"
printf '%s
' "$OUT" | grep -E 'DRIFT' >&2 || true
grep -q "OK    rule.required_status_checks.context-list" <<<"$OUT" && pass "reports the context-list as matching declared" || fail "reports context-list OK" "$OUT"
grep -q "context-list\[" <<<"$OUT" && fail "no add/remove lines when already matching" "$OUT" || pass "no add/remove lines when already matching"

# Undeclared repo (no .repos entry at all) keeps the ORIGINAL byte-for-byte
# preservation — this feature must never force every repo to declare a list.
DJ_UNDECLARED="$TMP/declared-undeclared.json"
jq -n --argjson brs "$(_decl_brs)" '{
    branch_rulesets: $brs,
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
# The CHECKS ruleset's PUT body (id 11 — see write_ruleset's id note). The
# context list, the strict flag and the required_status_checks rule all live
# there; only pull_request is written to the review ruleset (id 1).
NORSCPUT="$CAP/PUT_repos_acme_widgets_rulesets_11.body"
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
# The CHECKS ruleset's PUT body — required_status_checks, its strict flag and
# its context bindings all live there now.
NORSCREFPUT="$CAP/PUT_repos_acme_widgets_rulesets_11.body"
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
# BOTH declared rulesets are POSTed from scratch — review first (id 9001), then
# checks (id 9002). The CHECKS ruleset must arrive FINISHED: its
# required_status_checks rule, with every declared context already bound to its
# live reporter, is part of the create body itself. It is asserted on the
# stub's live-ruleset-<id>.json (the object as the "server" now holds it),
# because both POSTs share one request path and so one captured .body file.
#
# STRENGTHENED (was: assert the follow-up PUT carries the contexts). The old
# create POSTed an empty context list and bound it in a second call; this now
# asserts the opposite — the bindings are in the POST, and NO follow-up PUT is
# issued at all, because there is nothing left to converge. A PUT reappearing
# here means the create went out half-formed again.
FRESHNEW="$CAP/live-ruleset-9002.json"
if [[ -f "$FRESHNEW" ]]; then
    jq -e '.rules | map(.type) | index("required_status_checks") != null' "$FRESHNEW" >/dev/null 2>&1 \
        && pass "the created-from-scratch checks ruleset carries its required_status_checks rule" \
        || fail "fresh rsc rule created" "$(jq -c '.rules | map(.type)' "$FRESHNEW")"
    assert_eq "fresh: ci-check bound to its live reporter in the CREATE body" "15368" \
        "$(jq -r '.rules[] | select(.type=="required_status_checks") | .parameters.required_status_checks[] | select(.context=="ci-check") | .integration_id' "$FRESHNEW")"
    assert_eq "fresh: created rule has strict forced true" "true" \
        "$(jq -r '.rules[] | select(.type=="required_status_checks") | .parameters.strict_required_status_checks_policy' "$FRESHNEW")"
else
    fail "fresh: checks ruleset created" "requests.log=$(cat "$CAP/requests.log" 2>/dev/null)"
fi
[[ -f "$CAP/PUT_repos_acme_widgets_rulesets_9002.body" ]] \
    && fail "no follow-up PUT — the create body was already complete" \
            "$(jq -c '.rules' "$CAP/PUT_repos_acme_widgets_rulesets_9002.body")" \
    || pass "no follow-up PUT — the create body was already complete"
# The review ruleset never gains a required_status_checks rule, which is the
# split holding on a repo provisioned from nothing.
assert_eq "fresh: the REVIEW ruleset carries pull_request only" "[\"pull_request\"]" \
    "$(jq -c '.rules | map(.type)' "$CAP/live-ruleset-9001.json")"

# ============================================================================
# FOLD (#296 review): a 403 reading check-runs while resolving a declared
# context must leave ZERO rulesets created for the repo and the run red.
#
# The failure: context resolution used to happen AFTER the create POSTs, so a
# 403 here aborted with the review ruleset already live and the checks ruleset
# absent — a default branch requiring a review the bot may bypass and no
# mechanical checks behind it. Resolution now runs before the first POST, so a
# read failure costs nothing: the repo is left exactly as it was found.
section "from-scratch: a 403 on check-runs creates NO ruleset at all and the run is red"
SC_CTXFRESH403="$SCEN/ctx-fresh-403"
write_repo "$SC_CTXFRESH403" main good on
echo '[]' > "$SC_CTXFRESH403/rulesets.json"
# A merged PR exists, so resolution reaches check-runs — which is not readable
# under this token's scope. gh writes the error object to stdout and exits
# non-zero (the stub replicates that), so gh_call FATALs.
jq -n '[{merged_at: "2026-01-01T00:00:00Z", head: {sha: "fresh403sha"}}]' > "$SC_CTXFRESH403/recent-pr.json"
jq -n '{message: "Resource not accessible by integration", status: "403"}' \
    > "$SC_CTXFRESH403/check-runs-fresh403sha.json"
DJ_FRESH403="$TMP/declared-fresh-403.json"
mk_declared_json "$DJ_FRESH403" '["ci-check"]'

CAP="$TMP/cap/ctxfresh403-converge"
run_provision "$CAP" "$SC_CTXFRESH403" --declared-json "$DJ_FRESH403" "$SLUG"
[[ "$RC" != "0" ]] && pass "a 403 while resolving a declared context fails the run" \
    || fail "run must be red on an unreadable check-runs endpoint" "rc=$RC$OUT"
grep -q "FATAL \[check-runs\]" <<<"$OUT" && pass "fails loud, naming the call that could not be read" \
    || fail "FATAL names the check-runs call" "$OUT"
if [[ -f "$CAP/requests.log" ]] && grep -Eq '^POST .*rulesets' "$CAP/requests.log"; then
    fail "no ruleset POST may be issued" "$(cat "$CAP/requests.log")"
else
    pass "no ruleset POST was issued"
fi
if compgen -G "$CAP/live-ruleset-*.json" >/dev/null; then
    fail "zero rulesets exist for the repo afterwards" "$(printf '%s\n' "$CAP"/live-ruleset-*.json)"
else
    pass "zero rulesets exist for the repo afterwards"
fi

# The other half of the same guard: check-runs reads fine, but the declared
# context has simply never reported. Nothing is unreadable, so there is no
# FATAL — the run finishes, reports drift, and still creates NOTHING. Creating
# the review half alone would hand the bot its review bypass with no checks
# ruleset behind it; creating the checks half without the context would be a
# gate requiring nothing.
section "from-scratch: a declared context that never reported creates NO ruleset and drifts"
SC_FRESHREFUSE="$SCEN/ctx-fresh-refuse"
write_repo "$SC_FRESHREFUSE" main good on
echo '[]' > "$SC_FRESHREFUSE/rulesets.json"
DJ_FRESHREFUSE="$TMP/declared-fresh-refuse.json"
mk_declared_json "$DJ_FRESHREFUSE" '["never-ran-check"]'

CAP="$TMP/cap/ctxfreshrefuse-converge"
run_provision "$CAP" "$SC_FRESHREFUSE" --declared-json "$DJ_FRESHREFUSE" "$SLUG"
assert_eq "an unresolvable declared context leaves the converge run red" "1" "$RC"
grep -q "refusing to require" <<<"$OUT" && pass "names the refused context in the known drift class" \
    || fail "refusal line present" "$OUT"
grep -q "DRIFT ruleset = no ruleset named .* NOT created" <<<"$OUT" \
    && pass "says the ruleset was not created, and why" || fail "not-created line present" "$OUT"
grep -q "DRIFT ruleset = no ruleset named .* — converging" <<<"$OUT" \
    && fail "never announces converging a branch ruleset it then refuses to write" "$OUT" \
    || pass "never announces converging a branch ruleset it then refuses to write"
# Scoped to BRANCH rulesets: the tag ruleset is a separate declaration with no
# context bindings at all, and this guard has no business stopping it.
_fresh_branch_created="$(cat "$CAP"/live-ruleset-*.json 2>/dev/null | jq -s -r '[.[] | select(.target=="branch")] | length')"
assert_eq "neither declared BRANCH ruleset was created" "0" "${_fresh_branch_created:-0}"

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
jq -n --argjson brs "$(_decl_brs)" '{
    pull_request:{required_approving_review_count:0,dismiss_stale_reviews_on_push:true,require_code_owner_review:true,require_last_push_approval:false,required_review_thread_resolution:false,require_extra_approval_for_unattributed_changes:true},
    required_status_checks:{strict_required_status_checks_policy:true},
    branch_rulesets:$brs,
    tag_ruleset:{name:"Tag immutability", rules:["update","deletion"]},
    release_tag_authors:["claude-the-enduring[bot]"]
}' > "$DJ_TAGORIGIN"
run_provision "$TMP/cap/tagorigin-check" "$SC_TAGORIGIN" --check --declared-json "$DJ_TAGORIGIN" "$SLUG"
grep -q "OK    tag-origin\[v1.0.0\] = tagger claude-the-enduring\[bot\]" <<<"$OUT" && pass "release-authored annotated tag passes" || fail "release-authored tag OK" "$OUT"
grep -q "DRIFT tag-origin\[v1.0.1\] = tagger 'mallory' not a declared release author" <<<"$OUT" && pass "rogue-tagger annotated tag is DRIFT" || fail "rogue-tagger DRIFT" "$OUT"
grep -q "DRIFT tag-origin\[hand-cut\] = lightweight" <<<"$OUT" && pass "lightweight tag is DRIFT" || fail "lightweight DRIFT" "$OUT"

section "tag-origin: absent .release_tag_authors reports not-declared, never false-clean"
DJ_TAGNONE="$TMP/declared-tagnone.json"
jq -n --argjson brs "$(_decl_brs)" '{
    pull_request:{required_approving_review_count:0,dismiss_stale_reviews_on_push:true,require_code_owner_review:true,require_last_push_approval:false,required_review_thread_resolution:false,require_extra_approval_for_unattributed_changes:true},
    required_status_checks:{strict_required_status_checks_policy:true},
    branch_rulesets:$brs,
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
# codeowners-policy — the UN-INVERTED model: default-UNOWNED + an owned allow-list.
# The drift to catch is UNDER-coverage (a REQUIRED-OWNED real path left
# effectively unowned). OVER-coverage (a `* @owner` catch-all, extra owned lines)
# is SAFE — so an OLD inverted file still passes during the transition. Coverage
# is resolved against the repo's REAL FILE TREE by genuine last-match-wins, so a
# later broad ownerless line clearing an owned path is caught (patterns are never
# merely string-compared). The shared floor every scenario declares:
CO_REQ='["/.github/workflows/","/.github/CODEOWNERS","/.pre-commit-config.yaml","/.gitleaks.toml"]'

# (i) A new owned-only CODEOWNERS with every required path owned -> OK.
section "codeowners-policy: new owned-only file, all required paths owned -> OK"
SC_CO_OK="$SCEN/co-ok"
mk_minimal_repo "$SC_CO_OK"
write_tree "$SC_CO_OK" '[".github/workflows/ci.yml",".github/CODEOWNERS",".pre-commit-config.yaml",".gitleaks.toml",".github/scripts/gen.py","README.md","plugins/core/skills/x.md"]'
write_contents "$SC_CO_OK" ".github/CODEOWNERS" "# owned allow-list, no catch-all
/.github/workflows/ @lexijamesesq
/.github/scripts/ @lexijamesesq
/.pre-commit-config.yaml @lexijamesesq
/.gitleaks.toml @lexijamesesq
/.github/CODEOWNERS @lexijamesesq
"
DJ_CO_OK="$TMP/declared-co-ok.json"
mk_declared_codeowners "$DJ_CO_OK" "@lexijamesesq" "$CO_REQ" '["/.github/scripts/"]'
run_provision "$TMP/cap/co-ok" "$SC_CO_OK" --check --declared-json "$DJ_CO_OK" "$SLUG"
grep -q "OK    codeowners-policy = 5 required-owned path(s), all owned by @lexijamesesq" <<<"$OUT" \
    && pass "a new owned-only CODEOWNERS is OK" || fail "new owned-only OK" "$OUT"

# (i-b) REGRESSION: a middle `**/` matches the ZERO-directory case too — `/src/**/x.sh`
# must cover `src/x.sh`, not only `src/a/x.sh` — so the zero-dir path is counted AND
# owned (before the fix, src/x.sh was silently excluded from required-owned = under-coverage).
section "codeowners-policy: middle ** covers the zero-directory path (/src/**/x.sh -> src/x.sh) -> OK"
SC_CO_GG="$SCEN/co-globstar"
mk_minimal_repo "$SC_CO_GG"
write_tree "$SC_CO_GG" '[".github/workflows/ci.yml",".github/CODEOWNERS",".pre-commit-config.yaml",".gitleaks.toml","src/x.sh","src/a/x.sh"]'
write_contents "$SC_CO_GG" ".github/CODEOWNERS" "# owned allow-list
/.github/workflows/ @lexijamesesq
/.pre-commit-config.yaml @lexijamesesq
/.gitleaks.toml @lexijamesesq
/.github/CODEOWNERS @lexijamesesq
/src/**/x.sh @lexijamesesq
"
DJ_CO_GG="$TMP/declared-co-gg.json"
mk_declared_codeowners "$DJ_CO_GG" "@lexijamesesq" "$CO_REQ" '["/src/**/x.sh"]'
run_provision "$TMP/cap/co-gg" "$SC_CO_GG" --check --declared-json "$DJ_CO_GG" "$SLUG"
grep -q "OK    codeowners-policy = 6 required-owned path(s), all owned by @lexijamesesq" <<<"$OUT" \
    && pass "middle ** covers the zero-directory path (src/x.sh counted + owned)" || fail "globstar zero-dir" "$OUT"

# (ii) An OLD inverted file (catch-all + ownerless docs) -> OK (transition-compat).
section "codeowners-policy: OLD inverted file (catch-all + ownerless docs) -> OK (over-coverage)"
SC_CO_OLD="$SCEN/co-old"
mk_minimal_repo "$SC_CO_OLD"
write_tree "$SC_CO_OLD" '[".github/workflows/ci.yml",".github/CODEOWNERS",".pre-commit-config.yaml",".gitleaks.toml","README.md","LICENSE"]'
write_contents "$SC_CO_OLD" ".github/CODEOWNERS" "# Default: every path waits for the operator.
* @lexijamesesq
# Unattended paths: a pattern with no owner clears ownership.
/README.md
/LICENSE
"
DJ_CO_OLD="$TMP/declared-co-old.json"
mk_declared_codeowners "$DJ_CO_OLD" "@lexijamesesq" "$CO_REQ" '[]'
run_provision "$TMP/cap/co-old" "$SC_CO_OLD" --check --declared-json "$DJ_CO_OLD" "$SLUG"
grep -q "OK    codeowners-policy = 4 required-owned path(s), all owned by @lexijamesesq" <<<"$OUT" \
    && pass "an old inverted file passes via over-coverage (transition-compat)" || fail "old inverted OK" "$OUT"

# (iii) A required-owned path left unowned (its owning line removed) -> DRIFT.
section "codeowners-policy: a required-owned path left unowned -> DRIFT (under-coverage)"
SC_CO_UNDER="$SCEN/co-under"
mk_minimal_repo "$SC_CO_UNDER"
write_tree "$SC_CO_UNDER" '[".github/workflows/ci.yml",".gitleaks.toml",".github/CODEOWNERS",".pre-commit-config.yaml"]'
write_contents "$SC_CO_UNDER" ".github/CODEOWNERS" "# workflows line dropped -> that path is now unowned
/.gitleaks.toml @lexijamesesq
/.pre-commit-config.yaml @lexijamesesq
/.github/CODEOWNERS @lexijamesesq
"
DJ_CO_UNDER="$TMP/declared-co-under.json"
mk_declared_codeowners "$DJ_CO_UNDER" "@lexijamesesq" "$CO_REQ" '[]'
run_provision "$TMP/cap/co-under" "$SC_CO_UNDER" --check --declared-json "$DJ_CO_UNDER" "$SLUG"
assert_eq "co-under --check exits 1" "1" "$RC"
grep -q "DRIFT codeowners-policy = required-owned path(s) not owned by @lexijamesesq: .github/workflows/ci.yml" <<<"$OUT" \
    && pass "an unowned required path is DRIFT" || fail "unowned required path DRIFT" "$OUT"

# (iii-b) A later, broader ownerless line CLEARS an owned path -> DRIFT. This is
# the case string-comparison misses and real last-match-wins resolution catches.
section "codeowners-policy: a later broad ownerless line clears an owned path -> DRIFT"
SC_CO_CLEAR="$SCEN/co-clear"
mk_minimal_repo "$SC_CO_CLEAR"
write_tree "$SC_CO_CLEAR" '[".github/workflows/ci.yml",".github/CODEOWNERS",".pre-commit-config.yaml",".gitleaks.toml"]'
write_contents "$SC_CO_CLEAR" ".github/CODEOWNERS" "/.github/workflows/ @lexijamesesq
/.pre-commit-config.yaml @lexijamesesq
/.gitleaks.toml @lexijamesesq
/.github/CODEOWNERS @lexijamesesq
# a later, broader ownerless line frees everything under .github/ (incl workflows)
/.github/
"
DJ_CO_CLEAR="$TMP/declared-co-clear.json"
mk_declared_codeowners "$DJ_CO_CLEAR" "@lexijamesesq" "$CO_REQ" '[]'
run_provision "$TMP/cap/co-clear" "$SC_CO_CLEAR" --check --declared-json "$DJ_CO_CLEAR" "$SLUG"
assert_eq "co-clear --check exits 1" "1" "$RC"
grep -q "DRIFT codeowners-policy = required-owned path(s) not owned by @lexijamesesq" <<<"$OUT" \
    && pass "a later ownerless line clearing an owned path is DRIFT" || fail "cleared owned path DRIFT" "$OUT"

# (iv) A required-owned pattern that matches ZERO real files is N/A, never DRIFT.
section "codeowners-policy: a zero-match required pattern is NOT drift"
SC_CO_ZERO="$SCEN/co-zero"
mk_minimal_repo "$SC_CO_ZERO"
# Only .github/workflows/ exists; the other three required patterns match nothing.
write_tree "$SC_CO_ZERO" '[".github/workflows/ci.yml","README.md"]'
write_contents "$SC_CO_ZERO" ".github/CODEOWNERS" "/.github/workflows/ @lexijamesesq
"
DJ_CO_ZERO="$TMP/declared-co-zero.json"
mk_declared_codeowners "$DJ_CO_ZERO" "@lexijamesesq" "$CO_REQ" '[]'
run_provision "$TMP/cap/co-zero" "$SC_CO_ZERO" --check --declared-json "$DJ_CO_ZERO" "$SLUG"
grep -q "OK    codeowners-policy = 1 required-owned path(s), all owned by @lexijamesesq" <<<"$OUT" \
    && pass "a required pattern matching zero real files is not drift" || fail "zero-match not drift" "$OUT"
grep -q "DRIFT codeowners-policy" <<<"$OUT" && fail "zero-match emits no codeowners DRIFT" "$OUT" || pass "zero-match emits no codeowners DRIFT"

# (v) A full_owned repo (dotty-private class) MISSING the catch-all -> DRIFT.
section "codeowners-policy: full_owned repo missing the catch-all -> DRIFT"
SC_CO_FULLBAD="$SCEN/co-fullbad"
mk_minimal_repo "$SC_CO_FULLBAD"
write_tree "$SC_CO_FULLBAD" '["a.txt",".github/x.yml",".claude/blueprint/machine.md"]'
write_contents "$SC_CO_FULLBAD" ".github/CODEOWNERS" "/a.txt @lexijamesesq
"
DJ_CO_FULLBAD="$TMP/declared-co-fullbad.json"
mk_declared_codeowners "$DJ_CO_FULLBAD" "@lexijamesesq" "$CO_REQ" "absent" "true"
run_provision "$TMP/cap/co-fullbad" "$SC_CO_FULLBAD" --check --declared-json "$DJ_CO_FULLBAD" "$SLUG"
assert_eq "co-fullbad --check exits 1" "1" "$RC"
grep -q "DRIFT codeowners-policy = full-owned repo missing the '\* @lexijamesesq' catch-all" <<<"$OUT" \
    && pass "a full_owned repo without the catch-all is DRIFT" || fail "full_owned no catch-all DRIFT" "$OUT"

# (v-b) A full_owned repo WITH the catch-all -> OK.
section "codeowners-policy: full_owned repo with the catch-all -> OK"
SC_CO_FULLOK="$SCEN/co-fullok"
mk_minimal_repo "$SC_CO_FULLOK"
write_tree "$SC_CO_FULLOK" '["a.txt",".github/x.yml",".claude/blueprint/machine.md"]'
write_contents "$SC_CO_FULLOK" ".github/CODEOWNERS" "* @lexijamesesq
"
DJ_CO_FULLOK="$TMP/declared-co-fullok.json"
mk_declared_codeowners "$DJ_CO_FULLOK" "@lexijamesesq" "$CO_REQ" "absent" "true"
run_provision "$TMP/cap/co-fullok" "$SC_CO_FULLOK" --check --declared-json "$DJ_CO_FULLOK" "$SLUG"
grep -q "OK    codeowners-policy = full-owned: '\* @lexijamesesq' catch-all present" <<<"$OUT" \
    && pass "a full_owned repo with the catch-all is OK" || fail "full_owned with catch-all OK" "$OUT"

# No CODEOWNERS file at all -> DRIFT (a default-unowned repo needs the allow-list).
section "codeowners-policy: no CODEOWNERS file at all -> DRIFT"
SC_CO_NOFILE="$SCEN/co-nofile"
mk_minimal_repo "$SC_CO_NOFILE"
write_tree "$SC_CO_NOFILE" '[".github/workflows/ci.yml",".gitleaks.toml"]'
DJ_CO_NOFILE="$TMP/declared-co-nofile.json"
mk_declared_codeowners "$DJ_CO_NOFILE" "@lexijamesesq" "$CO_REQ" '[]'
run_provision "$TMP/cap/co-nofile" "$SC_CO_NOFILE" --check --declared-json "$DJ_CO_NOFILE" "$SLUG"
assert_eq "co-nofile --check exits 1" "1" "$RC"
grep -q "DRIFT codeowners-policy = no .github/CODEOWNERS file" <<<"$OUT" \
    && pass "an absent CODEOWNERS is DRIFT" || fail "absent CODEOWNERS DRIFT" "$OUT"

# A repo tree that cannot be read under the token -> SKIP (never counted clean).
section "codeowners-policy: unreadable repo tree -> SKIP (never false-clean)"
SC_CO_NOTREE="$SCEN/co-notree"
mk_minimal_repo "$SC_CO_NOTREE"   # no write_tree -> the stub has no tree fixture
write_contents "$SC_CO_NOTREE" ".github/CODEOWNERS" "/.github/workflows/ @lexijamesesq
"
DJ_CO_NOTREE="$TMP/declared-co-notree.json"
mk_declared_codeowners "$DJ_CO_NOTREE" "@lexijamesesq" "$CO_REQ" '[]'
run_provision "$TMP/cap/co-notree" "$SC_CO_NOTREE" --check --declared-json "$DJ_CO_NOTREE" "$SLUG"
grep -q "SKIP  codeowners-policy (repo file tree not readable" <<<"$OUT" \
    && pass "an unreadable tree skips, never assumed clean" || fail "unreadable tree skips" "$OUT"

# No per-repo codeowners_owned (and not full_owned) -> SKIP (never false-clean).
section "codeowners-policy: no per-repo codeowners_owned declared -> SKIP (never false-clean)"
DJ_CO_NOOWNED="$TMP/declared-co-noowned.json"
mk_declared_codeowners "$DJ_CO_NOOWNED" "@lexijamesesq" "$CO_REQ" "absent"
run_provision "$TMP/cap/co-noowned" "$SC_CO_OK" --check --declared-json "$DJ_CO_NOOWNED" "$SLUG"
grep -q "SKIP  codeowners-policy (no .repos" <<<"$OUT" \
    && pass "an undeclared per-repo owned-set skips, never assumed clean" || fail "undeclared owned-set skips" "$OUT"

# No global codeowners_owner -> SKIP (policy not configured).
section "codeowners-policy: no .codeowners_owner declared -> SKIP (policy not configured)"
DJ_CO_NOOWNER="$TMP/declared-co-noowner.json"
mk_declared_codeowners "$DJ_CO_NOOWNER" "" "$CO_REQ" '["/.github/workflows/"]'
run_provision "$TMP/cap/co-noowner" "$SC_CO_OK" --check --declared-json "$DJ_CO_NOOWNER" "$SLUG"
grep -q "SKIP  codeowners-policy (no .codeowners_owner declared" <<<"$OUT" \
    && pass "an unconfigured policy skips, never assumed clean" || fail "unconfigured policy skips" "$OUT"

# No global codeowners_required_owned floor -> SKIP.
section "codeowners-policy: no .codeowners_required_owned declared -> SKIP"
DJ_CO_NOREQ="$TMP/declared-co-noreq.json"
mk_declared_codeowners "$DJ_CO_NOREQ" "@lexijamesesq" "absent" '["/.github/workflows/"]'
run_provision "$TMP/cap/co-noreq" "$SC_CO_OK" --check --declared-json "$DJ_CO_NOREQ" "$SLUG"
grep -q "SKIP  codeowners-policy (no .codeowners_required_owned declared" <<<"$OUT" \
    && pass "a missing required-owned floor skips, never assumed clean" || fail "missing floor skips" "$OUT"

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
# UNION, not override: the per-repo list above declares only the admin actor, and
# what is written is that actor TOGETHER with the estate-wide ones. The failure
# this shape answers: every live branch ruleset in the estate already carries the
# admin actor, so if a per-repo list replaced the global one, a repo declaring
# only the merge App would have had its anti-lockout actor converged away — and a
# repo declaring only the admin actor would silently never get the merge App, so
# its dependency-bot PRs would go green and then sit unmerged forever with nothing
# reporting why. Duplicates across the two lists collapse, so declaring an actor
# in both places is a no-op rather than a doubled entry.
assert_eq "converge writes the UNION of the global and per-repo bypass actors" \
    '[{"actor_id":5,"actor_type":"RepositoryRole","bypass_mode":"pull_request"},{"actor_id":2740,"actor_type":"Integration","bypass_mode":"pull_request"}]' \
    "$(jq -cS '.bypass_actors | sort_by(.actor_id)' "$CONV_BODY" 2>/dev/null)"
assert_eq "an actor declared in BOTH places appears once" "2" \
    "$(jq -r '.bypass_actors | length' "$CONV_BODY" 2>/dev/null)"

section "declared enforcement + bypass_actors: --check drifts when live differs"
run_provision "$TMP/cap/widgets-check" "$SC_WIRED" --check --declared-json "$DECL_FIX" "$SLUG"
assert_eq "declared-fields --check exits 1 (drift)" "1" "$RC"
grep -q 'ruleset.enforcement' <<<"$OUT" && pass "--check reports enforcement drift" || fail "enforcement drift line" "$OUT"
grep -q 'ruleset.bypass_actors' <<<"$OUT" && pass "--check reports bypass_actors drift" || fail "bypass_actors drift line" "$OUT"

section "a repo with no per-repo entry still gets the estate-wide bypass actors"
# The real declared JSON has no acme/widgets entry, so enforcement defaults to
# active (== the wired live ruleset) and the bypass actors come from the
# top-level list alone — which the wired fixture carries, so this is clean.
run_provision "$TMP/cap/widgets-default" "$SC_WIRED" --check "$SLUG"
assert_eq "global-only --check exits 0 (live already carries the estate set)" "0" "$RC"

section "NEITHER declared: bypass_actors are preserved, never touched"
# The one remaining preserve path, and the only way to reach it — declared branch
# rulesets that OMIT `bypass_actors` entirely, and no per-repo list either. The
# live ruleset carries an actor nobody declared anywhere; with the field unowned
# it must be reported by neither OK nor DRIFT, because the tool has no opinion
# about it at all.
#
# `null` here is NOT the same as `[]`. Omitted means preserve what is live;
# an empty list means own the field and write an empty set — which would clear
# every repo's bypass actors and lock the operator out of their own default
# branch. This case is what keeps those two apart.
DECL_NOBYPASS="$TMP/decl-no-bypass.json"
mk_declared_json "$DECL_NOBYPASS" '["all-checks-passed"]'
jq '.branch_rulesets |= map(del(.bypass_actors))' "$DECL_NOBYPASS" > "$DECL_NOBYPASS.tmp" \
    && mv "$DECL_NOBYPASS.tmp" "$DECL_NOBYPASS"
SC_UNDECLARED_BYPASS="$SCEN/bypass-undeclared"
cp -r "$SC_WIRED" "$SC_UNDECLARED_BYPASS"
jq '.bypass_actors = [{"actor_id":77,"actor_type":"Team","bypass_mode":"always"}]' \
    "$SC_UNDECLARED_BYPASS/ruleset-1.json" > "$SC_UNDECLARED_BYPASS/ruleset-1.json.tmp" \
    && mv "$SC_UNDECLARED_BYPASS/ruleset-1.json.tmp" "$SC_UNDECLARED_BYPASS/ruleset-1.json"
run_provision "$TMP/cap/undeclared-bypass" "$SC_UNDECLARED_BYPASS" --check --declared-json "$DECL_NOBYPASS" "$SLUG"
grep -Eq '(OK|DRIFT) +ruleset\.bypass_actors' <<<"$OUT" \
    && fail "an undeclared bypass field must not be reported at all" "$OUT" \
    || pass "bypass_actors reported by neither OK nor DRIFT when undeclared anywhere"

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
write_core_call_ok "$SC_KEYORDER"
jq '.bypass_actors = [{"actor_id":2740,"actor_type":"Integration","bypass_mode":"pull_request"},{"actor_id":5,"actor_type":"RepositoryRole","bypass_mode":"pull_request"}]' \
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

# ----------------------------------------------------------------------------
# Margot enrollment checks — margot-caller + margot-app-key. Both are gated on
# the repo being margot-enrolled (its declared required_contexts includes
# "margot"); a non-enrolled repo (e.g. hazel, no ci.yml to dispatch from) SKIPs,
# never fails. Enrollment is set per-scenario via mk_declared_json.
DJ_MARGOT_ENROLLED="$TMP/declared-margot-enrolled.json"
mk_declared_json "$DJ_MARGOT_ENROLLED" '["all-checks-passed","trusted-scan / trusted-scan","margot"]'
DJ_MARGOT_NOTENROLLED="$TMP/declared-margot-notenrolled.json"
mk_declared_json "$DJ_MARGOT_NOTENROLLED" '["all-checks-passed","trusted-scan / trusted-scan"]'

section "margot-caller: enrolled + margot.yml calls the reusable -> OK"
SC_MARGOT_OK="$SCEN/margot-caller-ok"
mk_minimal_repo "$SC_MARGOT_OK"
write_contents "$SC_MARGOT_OK" ".github/workflows/margot.yml" \
    "uses: lexijamesesq/dotty/.github/workflows/estate-margot.yml@v2026.09.17"
run_provision "$TMP/cap/margot-caller-ok" "$SC_MARGOT_OK" --check --declared-json "$DJ_MARGOT_ENROLLED" "$SLUG"
grep -q "OK    margot-caller = margot.yml present and calls the estate reusable (estate-margot.yml@)" <<<"$OUT" \
    && pass "an enrolled repo with a valid margot.yml caller is OK" || fail "margot-caller OK" "$OUT"

section "margot-caller: enrolled + margot.yml absent -> DRIFT"
SC_MARGOT_DRIFT="$SCEN/margot-caller-drift"
mk_minimal_repo "$SC_MARGOT_DRIFT"
run_provision "$TMP/cap/margot-caller-drift" "$SC_MARGOT_DRIFT" --check --declared-json "$DJ_MARGOT_ENROLLED" "$SLUG"
assert_eq "margot-caller-drift --check exits 1" "1" "$RC"
grep -q "DRIFT margot-caller = margot.yml missing or does not call estate-margot.yml@" <<<"$OUT" \
    && pass "an enrolled repo with no margot.yml caller is DRIFT, never a silent pass" || fail "margot-caller DRIFT" "$OUT"

section "margot-caller: not margot-enrolled -> SKIP (never failed)"
run_provision "$TMP/cap/margot-caller-skip" "$SC_WIRED" --check --declared-json "$DJ_MARGOT_NOTENROLLED" "$SLUG"
grep -q "SKIP  margot-caller (not margot-enrolled" <<<"$OUT" \
    && pass "a non-enrolled repo skips the margot-caller check, never fails it" || fail "margot-caller SKIP" "$OUT"

section "margot-app-key: enrolled + MARGOT_APP_KEY present -> OK"
SC_MAK_OK="$SCEN/margot-appkey-ok"
mk_minimal_repo "$SC_MAK_OK"
jq -n '{name:"default-branch"}' > "$SC_MAK_OK/environments-default-branch.json"
jq -n '{secrets:[{name:"MARGOT_APP_KEY"}]}' > "$SC_MAK_OK/environment-secrets-default-branch.json"
run_provision "$TMP/cap/margot-appkey-ok" "$SC_MAK_OK" --check --declared-json "$DJ_MARGOT_ENROLLED" "$SLUG"
grep -q "OK    margot-app-key = MARGOT_APP_KEY secret present on the default-branch environment" <<<"$OUT" \
    && pass "an enrolled repo with MARGOT_APP_KEY present is OK" || fail "margot-app-key OK" "$OUT"

section "margot-app-key: enrolled + MARGOT_APP_KEY absent -> DRIFT"
SC_MAK_DRIFT="$SCEN/margot-appkey-drift"
mk_minimal_repo "$SC_MAK_DRIFT"
jq -n '{name:"default-branch"}' > "$SC_MAK_DRIFT/environments-default-branch.json"
jq -n '{secrets:[{name:"OPERATOR_RULES"}]}' > "$SC_MAK_DRIFT/environment-secrets-default-branch.json"
run_provision "$TMP/cap/margot-appkey-drift" "$SC_MAK_DRIFT" --check --declared-json "$DJ_MARGOT_ENROLLED" "$SLUG"
assert_eq "margot-appkey-drift --check exits 1" "1" "$RC"
grep -q "DRIFT margot-app-key = MARGOT_APP_KEY secret absent from default-branch environment" <<<"$OUT" \
    && pass "an enrolled repo missing MARGOT_APP_KEY is DRIFT" || fail "margot-app-key DRIFT" "$OUT"

section "margot-app-key: not margot-enrolled -> SKIP (never failed)"
SC_MAK_SKIP="$SCEN/margot-appkey-skip"
mk_minimal_repo "$SC_MAK_SKIP"
jq -n '{name:"default-branch"}' > "$SC_MAK_SKIP/environments-default-branch.json"
jq -n '{secrets:[{name:"OPERATOR_RULES"}]}' > "$SC_MAK_SKIP/environment-secrets-default-branch.json"
run_provision "$TMP/cap/margot-appkey-skip" "$SC_MAK_SKIP" --check --declared-json "$DJ_MARGOT_NOTENROLLED" "$SLUG"
grep -q "SKIP  margot-app-key (not margot-enrolled" <<<"$OUT" \
    && pass "a non-enrolled repo skips the margot-app-key check, never fails it" || fail "margot-app-key SKIP" "$OUT"

# ----------------------------------------------------------------------------
# The merge App as a declared bypass actor: absent from a live ruleset it must be
# REPORTED, and a converge must WRITE it. Without both halves the estate could
# believe the merge identity is in place on a repo where it is not, and a bot PR
# there would go green, get its skip check, and then fail the merge call with a
# 405 — the exact silent-stall this whole path exists to remove.
section "Integration bypass actor: missing on a live ruleset -> drift, then converged"
SC_NO_MERGE_APP="$SCEN/bypass-no-merge-app"
cp -r "$SC_WIRED" "$SC_NO_MERGE_APP"
jq '.bypass_actors = [{"actor_id":5,"actor_type":"RepositoryRole","bypass_mode":"pull_request"}]' \
    "$SC_NO_MERGE_APP/ruleset-1.json" > "$SC_NO_MERGE_APP/ruleset-1.json.tmp" \
    && mv "$SC_NO_MERGE_APP/ruleset-1.json.tmp" "$SC_NO_MERGE_APP/ruleset-1.json"
run_provision "$TMP/cap/no-merge-app-check" "$SC_NO_MERGE_APP" --check "$SLUG"
assert_eq "a ruleset without the merge App --check exits 1" "1" "$RC"
grep -Eq 'DRIFT +ruleset\.bypass_actors' <<<"$OUT" \
    && pass "the missing Integration bypass actor is reported as drift" \
    || fail "expected a DRIFT ruleset.bypass_actors line" "$OUT"
run_provision "$TMP/cap/no-ollie-conv" "$SC_NO_MERGE_APP" "$SLUG"
NO_OLLIE_PUT="$TMP/cap/no-ollie-conv/PUT_repos_acme_widgets_rulesets_1.body"
assert_eq "converge writes the merge App as an Integration bypass actor" "pull_request" \
    "$(jq -r '.bypass_actors[] | select(.actor_type=="Integration" and .actor_id==2740) | .bypass_mode' "$NO_OLLIE_PUT" 2>/dev/null)"
assert_eq "converge keeps the anti-lockout admin actor alongside it" "RepositoryRole" \
    "$(jq -r '.bypass_actors[] | select(.actor_id==5) | .actor_type' "$NO_OLLIE_PUT" 2>/dev/null)"

# ----------------------------------------------------------------------------
section "declared-JSON validation: the bot list and the global bypass list"
# Both are read at runtime by estate-margot.yml's bot path. A malformed list there
# would not fail loudly — it would quietly widen or empty the set of authors whose
# PRs merge themselves. Failing the provisioner is what keeps that from shipping.
DECL_BADBOTS="$TMP/decl-bad-bots.json"
jq '.dependency_bot_authors = []' "$SCRIPT_DIR/../../rulesets/default-branch.json" > "$DECL_BADBOTS"
run_provision "$TMP/cap/bad-bots" "$SC_WIRED" --check --declared-json "$DECL_BADBOTS" "$SLUG"
assert_eq "an empty dependency_bot_authors is FATAL" "1" "$RC"
grep -q "dependency_bot_authors" <<<"$OUT" && pass "the failure names the offending key" || fail "bot-list FATAL message" "$OUT"

DECL_BADBOTS2="$TMP/decl-bad-bots-2.json"
jq '.dependency_bot_authors = "dependabot[bot]"' "$SCRIPT_DIR/../../rulesets/default-branch.json" > "$DECL_BADBOTS2"
run_provision "$TMP/cap/bad-bots-2" "$SC_WIRED" --check --declared-json "$DECL_BADBOTS2" "$SLUG"
assert_eq "a bare string dependency_bot_authors is FATAL (it must be a list)" "1" "$RC"

# The bypass list now lives INSIDE each declared branch ruleset, so a malformed
# actor is caught by the `.branch_rulesets` validator rather than a top-level one.
DECL_BADBYPASS="$TMP/decl-bad-bypass.json"
jq '.branch_rulesets[0].bypass_actors = [{"actor_id": 1}]' "$SCRIPT_DIR/../../rulesets/default-branch.json" > "$DECL_BADBYPASS"
run_provision "$TMP/cap/bad-bypass" "$SC_WIRED" --check --declared-json "$DECL_BADBYPASS" "$SLUG"
assert_eq "a declared bypass actor missing actor_type/bypass_mode is FATAL" "1" "$RC"
grep -q "'.branch_rulesets'" <<<"$OUT" && pass "the failure names the branch_rulesets key" || fail "declared bypass FATAL message" "$OUT"

# ----------------------------------------------------------------------------
section "shipped default-branch.json: the estate-wide merge identity is declared"
SHIPPED="$SCRIPT_DIR/../../rulesets/default-branch.json"
# THE SPLIT ITSELF. These four assertions are the reason the ruleset was split,
# and they are written against the shipped declaration rather than a fixture so
# the property cannot quietly regress.
#
# A bypass actor on a ruleset bypasses EVERY rule in it, strict up-to-date
# included. So the merge App may appear on the REVIEW ruleset and must NOT appear
# on the CHECKS one — that asymmetry IS the fix.
REVIEW_BRS='.branch_rulesets[] | select(.rules | index("pull_request"))'
CHECKS_BRS='.branch_rulesets[] | select(.rules | index("required_status_checks"))'

assert_eq "the merge App bypasses the REVIEW ruleset" "pull_request" \
    "$(jq -r "$REVIEW_BRS"' | .bypass_actors[] | select(.actor_type=="Integration") | .bypass_mode' "$SHIPPED")"
assert_eq "its actor_id is the App id from GET /apps/renovate" "2740" \
    "$(jq -r "$REVIEW_BRS"' | .bypass_actors[] | select(.actor_type=="Integration") | .actor_id' "$SHIPPED")"
# The whole point: no Integration actor on the checks ruleset, so the bot stays
# subject to required status checks AND to strict up-to-date. If this ever
# returns an id, the split has been undone and the hole is back.
assert_eq "NO app bypasses the CHECKS ruleset" "" \
    "$(jq -r "$CHECKS_BRS"' | .bypass_actors[] | select(.actor_type=="Integration") | .actor_id // empty' "$SHIPPED")"
assert_eq "the anti-lockout admin actor is on BOTH rulesets" "5 5" \
    "$(jq -r '[.branch_rulesets[] | .bypass_actors[] | select(.actor_type=="RepositoryRole") | .actor_id] | join(" ")' "$SHIPPED")"
# `always` would let a bypass actor push straight to the default branch, outside
# a pull request entirely. `pull_request` is the whole scope any of them needs.
assert_eq "no declared bypass actor anywhere is granted 'always'" "" \
    "$(jq -r '[.branch_rulesets[] | .bypass_actors[] | select(.bypass_mode != "pull_request") | .actor_type] | join(" ")' "$SHIPPED")"
# And the two sets must actually DIFFER — identical sets would mean the split
# exists on paper and buys nothing.
if [[ "$(jq -c "$REVIEW_BRS"' | .bypass_actors' "$SHIPPED")" == "$(jq -c "$CHECKS_BRS"' | .bypass_actors' "$SHIPPED")" ]]; then
    fail "the two rulesets carry DIFFERENT bypass sets" "both carry the same set — the split buys nothing"
else pass "the two rulesets carry DIFFERENT bypass sets"; fi
# TWO declared dependency bots, and the pairing is deliberate.
#
# Renovate is the one that actually opens bumps now, for both managers this
# estate enables (pre-commit and github-actions). `dependabot[bot]` stays on the
# list as a harmless literal: every enrolled repo's dependabot.yml is deleted by
# the caller rollout, so it opens nothing, and keeping the name means a repo that
# somehow still has one does not get its PR sent down the paid-review path.
#
# `ollie-the-intern[bot]` is NOT here. It was, while a hand-rolled job authored
# the hook-channel bumps under its token. That job is gone: making the floating
# `v1` tag LIGHTWEIGHT lets `pre-commit autoupdate` resolve the calendar tag
# again, which is the whole thing the script existed to work around.
assert_eq "the two declared dependency bots" "dependabot[bot],renovate[bot]" \
    "$(jq -r '.dependency_bot_authors | join(",")' "$SHIPPED")"
# The merge App and the bump author are now ONE identity — Renovate opens its own
# bumps and merges them. That is safe only because it cannot post a check or
# approve a review, so the green it merges on is always someone else's.
assert_eq "the merge App is the declared Integration bypass actor" "2740" \
    "$(jq -r '[.branch_rulesets[] | .bypass_actors[]? | select(.actor_type=="Integration") | .actor_id] | unique | join(",")' "$SHIPPED")"
# The retired merge identity must be gone from BOTH surfaces, or an App nobody
# maintains keeps a standing bypass on every default branch.
assert_eq "the retired merge App is not a declared dependency-bot author" "" \
    "$(jq -r '.dependency_bot_authors[] | select(. == "ollie-the-intern[bot]")' "$SHIPPED")"
assert_eq "the retired merge App holds no bypass on any ruleset" "" \
    "$(jq -r '[.branch_rulesets[] | .bypass_actors[]? | select(.actor_id == 4984137) | .actor_type] | join(" ")' "$SHIPPED")"
# The one author this list must never contain: the App that opens every
# agent-authored PR in the estate. Adding it would make every agent PR merge
# itself with no review at all.
assert_eq "the agent-PR App is NOT a declared dependency bot" "" \
    "$(jq -r '.dependency_bot_authors[] | select(. == "claude-the-enduring[bot]")' "$SHIPPED")"

# ----------------------------------------------------------------------------
section "shipped default-branch.json: probe requires margot + the anti-lockout fields"
DECL_SHIPPED="$SCRIPT_DIR/../../rulesets/default-branch.json"
assert_eq "probe required_contexts includes margot" "true" \
    "$(jq -r '.repos["lexijamesesq/probe-local-to-merged"].required_contexts | any(. == "margot")' "$DECL_SHIPPED")"
assert_eq "probe enforcement is active" "active" \
    "$(jq -r '.repos["lexijamesesq/probe-local-to-merged"].enforcement' "$DECL_SHIPPED")"
assert_eq "probe declares a RepositoryRole admin pull_request bypass" "true" \
    "$(jq -r '.repos["lexijamesesq/probe-local-to-merged"].bypass_actors | any(.actor_type=="RepositoryRole" and .actor_id==5 and .bypass_mode=="pull_request")' "$DECL_SHIPPED")"

# ============================================================================
# § TAG-RULESET EXCLUDE — .repos["<slug>"].tag_ruleset_exclude, the ref patterns
# tag immutability does NOT cover. dotty's release-on-merge moves a floating
# `v1` tag, which is an `update` this ruleset otherwise blocks with no bypass
# actor.
#
# The failure these cases pin is receipted, not imagined: this step used to hand
# the LIVE `.conditions` straight back into its PUT, so a declared exclusion
# could sit in rulesets/default-branch.json forever while GitHub kept
# `exclude: []` and --check reported clean. `exclude` is OWNED and CONVERGED
# now; `include` stays preserved-from-live, which the update case asserts
# explicitly so a later change cannot quietly start owning it too.
section "tag-ruleset exclude: declared exclusion lands in the CREATE body"
DJ_TAGEXC="$TMP/declared-tag-exclude.json"
mk_declared_repo_json "$DJ_TAGEXC" '{"tag_ruleset_exclude":["refs/tags/v1"]}'
CAP="$TMP/cap/tagexc-create"
run_provision "$CAP" "$SC_TAGMISS" --declared-json "$DJ_TAGEXC" "$SLUG"
assert_eq "tag-exclude create converge exits 0" "0" "$RC"
TAGPOST="$CAP/POST_repos_acme_widgets_rulesets.body"
if [[ -f "$TAGPOST" ]]; then
    assert_eq "POST exclude is the declared list" '["refs/tags/v1"]' \
        "$(jq -c '.conditions.ref_name.exclude' "$TAGPOST")"
    assert_eq "POST include still covers every tag" '["refs/tags/*"]' \
        "$(jq -c '.conditions.ref_name.include' "$TAGPOST")"
else
    fail "tag-ruleset POST issued" "requests.log=$(cat "$CAP/requests.log" 2>/dev/null)"
fi

section "tag-ruleset exclude: an existing ruleset with the wrong exclude is DRIFT, then converged"
SC_TAGEXC="$SCEN/tag-exclude"
write_repo "$SC_TAGEXC" main good on
write_ruleset "$SC_TAGEXC" 1 main "non_fast_forward,deletion,pull_request"
# Otherwise-correct tag ruleset (update+deletion, no bypass, active) whose only
# difference from declared is `exclude: []` — exactly dotty's live shape.
add_tag_ruleset "$SC_TAGEXC" 2 ok
run_provision "$TMP/cap/tagexc-check" "$SC_TAGEXC" --check --declared-json "$DJ_TAGEXC" "$SLUG"
assert_eq "tag-exclude --check exits 1" "1" "$RC"
grep -q 'DRIFT tag-ruleset.exclude' <<<"$OUT" \
    && pass "a declared exclusion missing from the live ruleset is DRIFT, never a silent pass" \
    || fail "flags tag-ruleset.exclude drift" "$OUT"

CAP="$TMP/cap/tagexc-converge"
run_provision "$CAP" "$SC_TAGEXC" --declared-json "$DJ_TAGEXC" "$SLUG"
assert_eq "tag-exclude converge exits 0" "0" "$RC"
TAGPUT="$CAP/PUT_repos_acme_widgets_rulesets_2.body"
if [[ -f "$TAGPUT" ]]; then
    assert_eq "PUT exclude is the declared list" '["refs/tags/v1"]' \
        "$(jq -c '.conditions.ref_name.exclude' "$TAGPUT")"
    assert_eq "PUT include preserved from live, not re-declared" '["refs/tags/*"]' \
        "$(jq -c '.conditions.ref_name.include' "$TAGPUT")"
    jq -e '.rules == [{"type":"update"},{"type":"deletion"}]' "$TAGPUT" >/dev/null 2>&1 \
        && pass "the exclude-only PUT leaves update+deletion intact" \
        || fail "rules intact" "$(jq -c '.rules' "$TAGPUT")"
    assert_eq "the exclude-only PUT leaves bypass_actors empty" "[]" "$(jq -c '.bypass_actors' "$TAGPUT")"
else
    fail "tag-ruleset PUT issued" "requests.log=$(cat "$CAP/requests.log" 2>/dev/null)"
fi

section "tag-ruleset exclude: undeclared means EVERY tag stays immutable"
DJ_TAGNOEXC="$TMP/declared-tag-no-exclude.json"
mk_declared_repo_json "$DJ_TAGNOEXC" '{}'
run_provision "$TMP/cap/tagnoexc-check" "$SC_TAGEXC" --check --declared-json "$DJ_TAGNOEXC" "$SLUG"
# Assert the POSITIVE line, never "no DRIFT line appeared". A bad declared JSON
# makes the script FATAL before it ever reaches the tag step, and an
# absence-only test passes on that — which it did, once, while these cases were
# being written.
grep -q 'OK    tag-ruleset.exclude = \[\]' <<<"$OUT" \
    && pass "a repo declaring no exclusion reports the class OK with an empty exclude" \
    || fail "reports tag-ruleset.exclude OK = []" "$OUT"
grep -q 'DRIFT tag-ruleset.exclude' <<<"$OUT" \
    && fail "a repo declaring no exclusion is never churned" "$OUT" \
    || pass "a repo declaring no exclusion is never churned — the exclusion is dotty's alone"

section "shipped default-branch.json: dotty, and only dotty, excludes refs/tags/v1"
assert_eq "dotty declares refs/tags/v1 excluded" '["refs/tags/v1"]' \
    "$(jq -c '.repos["lexijamesesq/dotty"].tag_ruleset_exclude' "$DECL_SHIPPED")"
assert_eq "no other repo un-protects a tag" "1" \
    "$(jq '[.repos | to_entries[] | select(.value.tag_ruleset_exclude != null)] | length' "$DECL_SHIPPED")"

# ============================================================================
section "tag-origin: the declared mutable ref is exempt from the origin audit"
# ============================================================================
# The floating major tag is deliberately LIGHTWEIGHT — that is what keeps
# `pre-commit autoupdate` resolving the calendar tag rather than the moving one.
# The origin audit reports a lightweight tag as drift, so auditing v1 would
# report the fix as the fault. It is exempt via the same declared
# `tag_ruleset_exclude` list that exempts it from tag immutability.
SC_TAGORIGIN="$SCEN/tag-origin-mutable"
write_repo "$SC_TAGORIGIN" main good on
write_ruleset "$SC_TAGORIGIN" 1 main "non_fast_forward,deletion,pull_request"
add_tag_ruleset "$SC_TAGORIGIN" 2 ok
write_core_call_ok "$SC_TAGORIGIN"
write_head_ref "$SC_TAGORIGIN"
printf '%s\n' '[{"ref":"refs/tags/v1","object":{"sha":"c0ffee","type":"commit"}},{"ref":"refs/tags/v2026.09.19","object":{"sha":"deadbee","type":"tag"}}]' \
    > "$SC_TAGORIGIN/git-matching-refs-tags.json"
printf '%s\n' '{"tagger":{"name":"github-actions[bot]"}}' > "$SC_TAGORIGIN/git-tag-deadbee.json"

DECL_MUTABLE="$TMP/decl-mutable-v1.json"
jq '.repos["acme/widgets"] = {"required_contexts": ["all-checks-passed", "trusted-scan / trusted-scan"], "tag_ruleset_exclude": ["refs/tags/v1"]}' \
    "$SCRIPT_DIR/../../rulesets/default-branch.json" > "$DECL_MUTABLE"
run_provision "$TMP/cap/tag-origin-mutable" "$SC_TAGORIGIN" --check --declared-json "$DECL_MUTABLE" "$SLUG"
grep -q "OK    tag-origin\[v1\] = declared mutable" <<<"$OUT" \
    && pass "a declared-mutable lightweight tag is exempt, not drift" || fail "v1 exempt" "$OUT"
grep -q "DRIFT tag-origin\[v1\]" <<<"$OUT" \
    && fail "the exempt tag is never reported as drift" "$OUT" \
    || pass "the exempt tag is never reported as drift"
grep -q "OK    tag-origin\[v2026.09.19\]" <<<"$OUT" \
    && pass "an ordinary annotated tag is still audited normally" || fail "calendar tag audited" "$OUT"

# Non-vacuous: the SAME lightweight tag, NOT declared, is drift.
DECL_IMMUTABLE="$TMP/decl-no-mutable.json"
jq '.repos["acme/widgets"] = {"required_contexts": ["all-checks-passed", "trusted-scan / trusted-scan"]}' \
    "$SCRIPT_DIR/../../rulesets/default-branch.json" > "$DECL_IMMUTABLE"
run_provision "$TMP/cap/tag-origin-undeclared" "$SC_TAGORIGIN" --check --declared-json "$DECL_IMMUTABLE" "$SLUG"
grep -q "DRIFT tag-origin\[v1\]" <<<"$OUT" \
    && pass "an UNDECLARED lightweight tag is still drift" || fail "undeclared lightweight is drift" "$OUT"

finish
