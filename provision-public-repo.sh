#!/usr/bin/env bash
#
# provision-public-repo.sh — idempotently wire a GitHub repo to this estate's
# publishing conventions, or (with --check) report drift and mutate nothing.
#
#     provision-public-repo.sh [--check] [--rules <path>] [--declared-json <path>] <owner/repo> [local-path]
#
# WHY THIS EXISTS
# ---------------
# Wiring a repo used to be a remembered checklist. A skipped step is a
# SILENT TIER DOWNGRADE — the repo looks protected and isn't. This makes the
# wiring *run* rather than be *remembered*, and --check makes a downgrade
# visible instead of assumed-away.
#
# NAME, SCOPE
# ----------------------
# Despite the name, this is now the one provisioner for every repo the
# "Local to merged" map governs, public or private — the visibility check in
# Step 7 is what used to be the whole reason for the name. Renaming the file
# is a consumer-inventory job of its own, not done here.
#
# HONEST LABELLING — WHAT IS AND IS NOT A LEAK CONTROL
# ----------------------------------------------------
# Two things this script converges are NOT leak controls. This header says so
# plainly so no future reader — or comment — mistakes them for one:
#
#   * The branch ruleset (non_fast_forward, deletion, pull_request) and the
#     squash-only merge settings are HISTORY HYGIENE and MERGE DISCIPLINE.
#     They keep the default branch linear and route change through a PR. They
#     do NOT prevent leaks: commits pushed to a PR branch persist at
#     refs/pull/<n>/* regardless of merge strategy, and this estate has already
#     established that PR refs are effectively unrewritable. A secret is exposed
#     the moment its branch is pushed — PR or no PR, squash or no squash.
#
#   * The ACTUAL leak controls are two, and this script CONFIGURES NEITHER of
#     their rules:
#       1. the local pre-commit / pre-push hook line (gitleaks). This script
#          installs the hook *plumbing* (local steps below), but the scanning
#          rules live in the repo's own tracked .gitleaks.toml + operator ruleset.
#       2. GitHub secret-scanning push protection (server-side, public repos
#          only — see § VISIBILITY below). This script only VERIFIES it is
#          enabled; enabling it is done out of band.
#
# RULE OWNERSHIP — CONVERGED vs PRESERVED
# ---------------------------------------
# The ruleset step distinguishes rules this tool OWNS from rules it does not:
#
#   * OWNED (converged to intent): non_fast_forward, deletion, pull_request,
#     required_status_checks' strict flag and per-context integration_id
#     binding, and a separate tag-immutability ruleset. The
#     pull_request rule's five owned parameters are READ FROM THE DECLARED
#     JSON (§ DECLARED JSON below), never hardcoded — a solo operator cannot
#     approve their own PR, so any nonzero required_approving_review_count in
#     that JSON makes merging impossible until a second reviewer identity
#     exists; a later identity change changes only the JSON's values (e.g.
#     require_code_owner_review: true) and re-runs the same converge — no
#     script edit, no hardcoded trigger condition to get wrong. Any EXTRA
#     parameters GitHub attaches to the pull_request rule (e.g.
#     allowed_merge_methods) are left intact — this tool owns its five
#     declared parameters, not the whole object.
#   * PRESERVED (byte-for-byte, except the two owned sub-fields above): the
#     required_status_checks rule's context LIST (which checks are required
#     at all) is a CI gate — a repo's own business — and is never added to or
#     removed by this script. Conditions and bypass_actors on the branch
#     ruleset are likewise preserved exactly.
#
# CONTEXT BINDING — VERIFIED, NEVER ASSUMED
# ------------------------------------------
# A required context missing `integration_id` can be satisfied by a spoofed
# classic Status from any write-access token — the estate's own probe
# proved this. Converging binds each unbound context to the app id
# that ACTUALLY reported it on a recent merged PR's head commit
# (resolve_context_reporter), never an assumed constant. A context with no
# live reporter is DROPPED from required rather than bound — a wrong bind
# makes that check permanently unsatisfiable and blocks every future PR.
#
# WRITE MODEL — FULL OBJECT, VERIFIED READ-BACK
# -----------------------------------------------
# GitHub's ruleset PUT/POST is not documented as a partial patch, and every
# field this tool owns lives inside the `rules` array — a partial body would
# silently drop untouched rules. Every write GETs first, projects to the
# complete writable object (never echoing id/source/timestamps/links back),
# and PUTs/POSTs whole. After every ruleset write this tool re-GETs and
# compares a normalized projection (unordered collections sorted; volatile
# metadata stripped) against what was intended — a mismatch is FATAL, never
# assumed-correct from a 200 response.
#
# VISIBILITY — PUBLIC-ONLY SETTINGS ARE SKIPPED ON PRIVATE REPOS
# --------------------------------------------------------------------------
# Secret-scanning + push-protection (Step 7) are GitHub features that do not
# exist on a private repo under a personal account. This script reads
# `.private` from the repo object and skips Step 7 entirely (report OK,
# never DRIFT) when true, instead of failing the call or reporting a false
# downgrade.
#
# DECLARED JSON — THE PULL_REQUEST FLOOR AND THE TAG-RULESET SHAPE
# --------------------------------------------------------------------
# Resolution order, first hit wins:
#   1. --declared-json <path>                       (explicit per-run override)
#   2. rulesets/default-branch.json next to this script (the normal path)
# The file is not private (no PII, no operator content) and is tracked in
# this repo. See its own comments for the shape.
#
# RULESET PATH (GITLEAKS OPERATOR RULES) — RESOLVED, NOT CONFIGURED
# ---------------------------------------------------------------------
# The operator gitleaks ruleset lives in a private location that this PUBLIC
# file must never name. Success must not depend on the operator remembering to
# export an environment variable in two places. Resolution order, first hit wins:
#   1. --rules <path>                              (explicit per-run override)
#   2. the FIXED install path (gl_fixed_rules_path in git-hooks/gitleaks-
#      common.sh: ${XDG_CONFIG_HOME:-$HOME/.config}/gitleaks/operator-rules.toml)
#      — installed by the blueprint's gitleaks-rules slice (`apply`). The
#      normal path; nothing to configure per repo. There is no per-repo symlink
#      to create — every repo's tracked .gitleaks.toml carries a relative
#      [extend] token that gl_preflight resolves against this fixed path at
#      hook-run time.
#   3. $GITLEAKS_OPERATOR_RULES                    (override for an unprovisioned
#      machine that lacks the fixed-path install; never a requirement)
#   4. else fail closed, naming all three.
# The private path appears only at the fixed install location, never here.
#
# FAIL-CLOSED
# -----------
# `set -euo pipefail`. Any gh call that fails aborts non-zero, naming the repo
# and the step. --check exits non-zero if any drift remains. converge exits
# non-zero if any drift it CANNOT resolve remains (e.g. a repo missing its own
# tracked .gitleaks.toml — that is the repo's responsibility, not synthesized
# here). Every gh call goes through $GH (defaults to `gh`) so a test can stub it.

set -euo pipefail

# ----------------------------------------------------------------------------
# Arg parsing
# ----------------------------------------------------------------------------
MODE=converge
RULES_FLAG=""
DECLARED_JSON_FLAG=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --check)          MODE=check; shift ;;
        --rules)          RULES_FLAG="${2:-}"; [[ -n "$RULES_FLAG" ]] || { echo "FATAL: --rules requires a path" >&2; exit 2; }; shift 2 ;;
        --rules=*)        RULES_FLAG="${1#--rules=}"; shift ;;
        --declared-json)  DECLARED_JSON_FLAG="${2:-}"; [[ -n "$DECLARED_JSON_FLAG" ]] || { echo "FATAL: --declared-json requires a path" >&2; exit 2; }; shift 2 ;;
        --declared-json=*) DECLARED_JSON_FLAG="${1#--declared-json=}"; shift ;;
        --)               shift; break ;;
        -*)               echo "FATAL: unknown option '$1'" >&2; exit 2 ;;
        *)                break ;;
    esac
done

REPO_SLUG="${1:-}"
LOCAL_PATH="${2:-}"

if [[ -z "$REPO_SLUG" ]]; then
    echo "usage: provision-public-repo.sh [--check] [--rules <path>] [--declared-json <path>] <owner/repo> [local-path]" >&2
    exit 2
fi
if [[ "$REPO_SLUG" != */* || "$REPO_SLUG" == */*/* ]]; then
    echo "FATAL: '<owner/repo>' must be exactly owner/repo (got '$REPO_SLUG')" >&2
    exit 2
fi

GH="${GH:-gh}"
DRIFT_COUNT=0
SCRIPT_SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# The fixed install path (resolution path 2) — see header § RULESET PATH.
GL_FIXED_RULES_PATH="${XDG_CONFIG_HOME:-$HOME/.config}/gitleaks/operator-rules.toml"

# ----------------------------------------------------------------------------
# Dependency floor. A missing tool is a hard, named failure — never a skip.
# ----------------------------------------------------------------------------
command -v jq >/dev/null 2>&1 || {
    echo "FATAL: jq is not installed — required to read/build GitHub API JSON. brew install jq" >&2
    exit 1
}
command -v git >/dev/null 2>&1 || {
    echo "FATAL: git is not installed." >&2
    exit 1
}

# ----------------------------------------------------------------------------
# Declared JSON (§ DECLARED JSON) — resolved once, fail-closed.
# ----------------------------------------------------------------------------
DECLARED_JSON_PATH=""
if [[ -n "$DECLARED_JSON_FLAG" ]]; then
    DECLARED_JSON_PATH="$DECLARED_JSON_FLAG"
else
    DECLARED_JSON_PATH="$SCRIPT_SELF_DIR/rulesets/default-branch.json"
fi
[[ -r "$DECLARED_JSON_PATH" ]] || {
    echo "FATAL [declared-json]: cannot read declared ruleset JSON at '$DECLARED_JSON_PATH'. Pass --declared-json <path> or restore rulesets/default-branch.json." >&2
    exit 1
}
DECLARED_JSON="$(cat "$DECLARED_JSON_PATH")"
PR_PARAMS="$(printf '%s' "$DECLARED_JSON" | jq -c '.pull_request')"
[[ "$PR_PARAMS" != "null" ]] || { echo "FATAL [declared-json]: '.pull_request' missing from $DECLARED_JSON_PATH" >&2; exit 1; }
STRICT_WANT="$(printf '%s' "$DECLARED_JSON" | jq -r '.required_status_checks.strict_required_status_checks_policy')"
[[ "$STRICT_WANT" == "true" || "$STRICT_WANT" == "false" ]] || { echo "FATAL [declared-json]: '.required_status_checks.strict_required_status_checks_policy' missing/invalid in $DECLARED_JSON_PATH" >&2; exit 1; }
TAG_RULESET_NAME="$(printf '%s' "$DECLARED_JSON" | jq -r '.tag_ruleset.name')"
TAG_RULESET_RULES="$(printf '%s' "$DECLARED_JSON" | jq -c '.tag_ruleset.rules')"
[[ "$TAG_RULESET_NAME" != "null" && "$TAG_RULESET_RULES" != "null" ]] || { echo "FATAL [declared-json]: '.tag_ruleset' missing/invalid in $DECLARED_JSON_PATH" >&2; exit 1; }

# ----------------------------------------------------------------------------
# Helpers
# ----------------------------------------------------------------------------
hdr()       { printf '\n== %s ==\n' "$1"; }
note_ok()   { printf '  OK    %s = %s\n' "$1" "$2"; }
note_drift(){ printf '  DRIFT %s = %s (intended %s)\n' "$1" "$2" "$3"; DRIFT_COUNT=$((DRIFT_COUNT + 1)); }
note_conv() { printf '  DRIFT %s = %s (intended %s) — converging\n' "$1" "$2" "$3"; }
note_fixed(){ printf '  FIXED %s -> %s\n' "$1" "$2"; }
note_skip() { printf '  SKIP  %s (%s)\n' "$1" "$2"; }

# gh_call <step-label> <gh-args...> — echoes stdout; aborts fail-closed on error.
gh_call() {
    local label="$1"; shift
    local out
    if ! out="$("$GH" "$@")"; then
        echo "FATAL [$label]: 'gh $*' failed for $REPO_SLUG — aborting (fail-closed)." >&2
        exit 1
    fi
    printf '%s' "$out"
}

# expand_tilde <path> — expand a leading ~ (env vars/flags are not tilde-expanded
# by the shell). The literal ~ is held in a variable so it never sits in a
# quoted-path position (which would misfire shellcheck SC2088).
expand_tilde() {
    local p="$1" t='~'
    if [[ "$p" == "$t" ]]; then printf '%s' "$HOME"
    elif [[ "$p" == "$t"/* ]]; then printf '%s' "$HOME/${p#"$t"/}"
    else printf '%s' "$p"; fi
}

# normalize_ruleset — projects a ruleset GET body to writable keys only, with
# unordered collections sorted, for read-back comparison. Reads JSON on stdin.
normalize_ruleset() {
    jq -S '{
        name, target, enforcement,
        bypass_actors: ((.bypass_actors // []) | sort_by([.actor_type, (.actor_id // -1)])),
        conditions,
        rules: ((.rules // []) | map(
            if .type == "required_status_checks" then
                .parameters.required_status_checks |= ((. // []) | sort_by(.context))
            else . end
        ) | sort_by(.type))
    }'
}

# ruleset_write_verify <label> <method> <url> — reads the intended full
# object on stdin, writes it, re-GETs the ruleset, and FATALs if the
# normalized projection does not match. Never assumes a 200 means the write
# landed as intended. Echoes the (re-fetched) ruleset id on success.
ruleset_write_verify() {
    local label="$1" method="$2" url="$3" intended write_result new_id verify_url got
    intended="$(cat)"
    write_result="$(printf '%s' "$intended" | gh_call "$label" api "$url" --method "$method" --input -)"
    if [[ "$method" == POST ]]; then
        new_id="$(printf '%s' "$write_result" | jq -r '.id')"
        verify_url="repos/$REPO_SLUG/rulesets/$new_id"
    else
        verify_url="$url"
    fi
    got="$(gh_call "$label-verify" api "$verify_url")"
    if [[ "$(printf '%s' "$got" | normalize_ruleset)" != "$(printf '%s' "$intended" | normalize_ruleset)" ]]; then
        echo "FATAL [$label]: read-back after write does not match intent for $REPO_SLUG." >&2
        echo "  intended: $(printf '%s' "$intended" | normalize_ruleset)" >&2
        echo "  observed: $(printf '%s' "$got" | normalize_ruleset)" >&2
        exit 1
    fi
    printf '%s' "$got" | jq -r '.id'
}

# resolve_context_reporter <default_branch> <context_name> — the app id that
# ACTUALLY reported this context on a recent merged PR's head commit. Empty
# output (not a FATAL) means no live reporter was found; the caller decides
# to drop the context rather than bind a guess.
resolve_context_reporter() {
    local branch="$1" ctx="$2" sha
    sha="$(gh_call "recent-pr" api "repos/$REPO_SLUG/pulls?state=closed&base=$branch&sort=updated&direction=desc&per_page=10" | \
        jq -r '[.[] | select(.merged_at != null)][0].head.sha // empty')"
    [[ -n "$sha" ]] || return 0
    gh_call "check-runs" api "repos/$REPO_SLUG/commits/$sha/check-runs" | \
        jq -r --arg ctx "$ctx" '[.check_runs[] | select(.name == $ctx) | .app.id][0] // empty'
}

# ----------------------------------------------------------------------------
# LOCAL STEPS — only when a local-path is supplied AND is a git work tree.
# ----------------------------------------------------------------------------
process_local() {
    local path="$1"

    if ! git -C "$path" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
        printf '  SKIP  local steps: %s is not a git work tree\n' "$path" >&2
        return 0
    fi

    local gitdir
    gitdir="$(git -C "$path" rev-parse --absolute-git-dir)"

    hdr "Local: $path"

    # --- Step 1: operator-rules resolution (verify only; nothing to write) -
    # Resolve the ruleset path (see header § RULESET PATH). There is no
    # per-repo symlink to create — rules load from the fixed install path at
    # hook-run time (gl_preflight, git-hooks/gitleaks-common.sh). This step
    # only verifies a ruleset resolves SOMEWHERE, so provisioning fails closed
    # with a clear message rather than silently wiring hooks that FTL on every
    # commit/push. The resolved path is NEVER printed — it may be the private
    # ruleset's real path; only rules_src (which source resolved it) is.
    local rules_src="" candidate=""
    if [[ -n "$RULES_FLAG" ]]; then
        candidate="$(expand_tilde "$RULES_FLAG")"
        if [[ ! -r "$candidate" ]]; then
            echo "FATAL [operator-rules]: --rules path is not readable: $candidate" >&2
            exit 1
        fi
        rules_src="--rules"
    elif [[ -r "$GL_FIXED_RULES_PATH" ]]; then
        rules_src="fixed install path"
    elif [[ -n "${GITLEAKS_OPERATOR_RULES:-}" ]]; then
        # The env var was set deliberately — a broken value is a PINPOINTED
        # error ("you set one and it's broken"), never the generic "cannot
        # locate" ("you set nothing"). State only the fact; never echo the
        # resolved path (it is the private target). Matches the sibling consumer
        # gh-pr-body-guard.sh, which blocks the same env var the same way.
        candidate="$(expand_tilde "$GITLEAKS_OPERATOR_RULES")"
        if [[ ! -r "$candidate" ]]; then
            echo "FATAL [operator-rules]: GITLEAKS_OPERATOR_RULES is set but its target is unreadable. Fix or unset it, then re-run. (Fail-closed; path withheld.)" >&2
            exit 1
        fi
        rules_src="\$GITLEAKS_OPERATOR_RULES"
    else
        echo "FATAL [operator-rules]: cannot locate the operator gitleaks ruleset. Satisfy one:" >&2
        echo "  1. pass --rules <path>" >&2
        echo "  2. install it via the blueprint (gitleaks-rules apply) at the fixed path" >&2
        echo "  3. set GITLEAKS_OPERATOR_RULES to a readable ruleset path" >&2
        exit 1
    fi
    note_ok "operator-rules" "resolved (source: $rules_src)"

    # --- Step 2: tracked .gitleaks.toml (report-only; never synthesized) ---
    if git -C "$path" ls-files --error-unmatch .gitleaks.toml >/dev/null 2>&1; then
        note_ok "gitleaks.toml-tracked" "present"
    else
        note_drift "gitleaks.toml-tracked" "absent" \
            "repo must add & commit its own .gitleaks.toml (not synthesized here)"
    fi

    # --- Step 3: pre-commit hooks (pre-commit, pre-push, commit-msg) -------
    # default_install_hook_types in the tracked .pre-commit-config.yaml means a
    # bare install wires all three. A declared-but-uninstalled hook is fail-OPEN.
    if [[ "$MODE" == converge ]]; then
        command -v pre-commit >/dev/null 2>&1 || {
            echo "FATAL [pre-commit]: pre-commit is not installed — cannot wire hooks. brew install pre-commit" >&2
            exit 1
        }
        if ! ( cd "$path" && pre-commit install --install-hooks ) >/dev/null; then
            echo "FATAL [pre-commit]: 'pre-commit install --install-hooks' failed in $path" >&2
            exit 1
        fi
    fi
    local missing_hooks=()
    local h
    for h in pre-commit pre-push commit-msg; do
        if [[ -f "$gitdir/hooks/$h" ]] && grep -q "pre-commit" "$gitdir/hooks/$h" 2>/dev/null; then
            continue
        fi
        missing_hooks+=("$h")
    done
    if [[ ${#missing_hooks[@]} -eq 0 ]]; then
        note_ok "pre-commit-hooks" "pre-commit,pre-push,commit-msg"
    else
        note_drift "pre-commit-hooks" "missing: ${missing_hooks[*]}" \
            "all three installed (run without --check, or 'pre-commit install')"
    fi

    # --- Step 3b: stage coverage — an installed hook TYPE that executes zero
    # hooks is fail-open with a green audit. The tracked config must BIND scan
    # logic to pre-push and commit-msg: either an explicit `stages:` entry
    # naming the stage, or dotty's consumer hook ids (gitleaks-pre-push /
    # gitleaks-commit-msg — their stages are pinned in dotty's
    # .pre-commit-hooks.yaml). Grep-level: flow-style `stages: [...]` only.
    local pcc="$path/.pre-commit-config.yaml" unbound=() st
    for st in pre-push commit-msg; do
        grep -qE "^[[:space:]]*stages:[^#]*$st" "$pcc" 2>/dev/null && continue
        grep -qE "^[[:space:]]*-[[:space:]]*id:[[:space:]]*gitleaks-$st([[:space:]]|\$)" "$pcc" 2>/dev/null && continue
        unbound+=("$st")
    done
    if [[ ${#unbound[@]} -eq 0 ]]; then
        note_ok "scan-stage-coverage" "pre-push,commit-msg bound"
    elif [[ "$MODE" == converge ]]; then
        echo "FATAL [scan-stage-coverage]: no scan hook bound to stage(s): ${unbound[*]} in $pcc — add dotty's consumer recipe (ids gitleaks-staged, gitleaks-pre-push, gitleaks-commit-msg; shape in dotty's .pre-commit-hooks.yaml). The provisioner converges plumbing, never config content." >&2
        exit 1
    else
        note_drift "scan-stage-coverage" "unbound: ${unbound[*]}" \
            "a scan hook bound per stage (dotty consumer recipe, or explicit stages: entry)"
    fi

    # --- Step 4: origin/HEAD (security-review's base ref) ------------------
    if git -C "$path" symbolic-ref --quiet refs/remotes/origin/HEAD >/dev/null 2>&1; then
        note_ok "origin/HEAD" "set"
    elif [[ "$MODE" == converge ]]; then
        if ! git -C "$path" remote set-head origin --auto >/dev/null 2>&1; then
            echo "FATAL [origin-head]: 'git remote set-head origin --auto' failed in $path (is 'origin' set?)" >&2
            exit 1
        fi
        note_fixed "origin/HEAD" "git remote set-head origin --auto"
    else
        note_drift "origin/HEAD" "unset" "git remote set-head origin --auto"
    fi

    # --- Step 4b: stale-clone check (scrubbed-content/identity resurfacing class) ---
    # A clone whose origin/main is not an ancestor of local main predates a
    # history rewrite; pushing from it resurrects scrubbed content/identity.
    # No fetch here — --check never touches the network — so an absent
    # origin/main ref is itself drift (fail-closed: ancestry unverifiable).
    if ! git -C "$path" rev-parse --verify -q refs/remotes/origin/main >/dev/null; then
        note_drift "stale-clone" "refs/remotes/origin/main absent" \
            "fetch origin so ancestry is verifiable (fail-closed without it)"
    elif git -C "$path" merge-base --is-ancestor refs/remotes/origin/main main 2>/dev/null; then
        note_ok "stale-clone" "origin/main is an ancestor of local main"
    elif git -C "$path" merge-base --is-ancestor main refs/remotes/origin/main 2>/dev/null; then
        note_ok "stale-clone" "local main behind origin/main, not diverged (pull to refresh)"
    else
        note_drift "stale-clone" "local main has diverged from origin/main" \
            "likely a pre-rewrite clone; re-point before any push"
    fi
}

# ----------------------------------------------------------------------------
# REMOTE STEPS — always run.
# ----------------------------------------------------------------------------
process_remote() {
    # --- Repo object (one fetch: default branch + merge + security + visibility) --
    local repo_json default_branch is_private
    repo_json="$(gh_call "repo-get" api "repos/$REPO_SLUG")"
    default_branch="$(printf '%s' "$repo_json" | jq -r '.default_branch // empty')"
    if [[ -z "$default_branch" ]]; then
        echo "FATAL [repo-get]: could not read .default_branch for $REPO_SLUG" >&2
        exit 1
    fi
    is_private="$(printf '%s' "$repo_json" | jq -r '.private')"

    # --- Step 5: merge settings ------------------------------------------
    # (No associative array: this must run on bash 3.2 too.)
    hdr "Merge settings"
    local merge_drift=0 merge_key cur want
    for merge_key in allow_squash_merge allow_merge_commit allow_rebase_merge \
                     delete_branch_on_merge squash_merge_commit_title squash_merge_commit_message; do
        cur="$(printf '%s' "$repo_json" | jq -r --arg k "$merge_key" '.[$k]')"
        case "$merge_key" in
            allow_squash_merge)          want=true ;;
            allow_merge_commit)          want=false ;;
            allow_rebase_merge)          want=false ;;
            delete_branch_on_merge)      want=true ;;
            squash_merge_commit_title)   want=PR_TITLE ;;
            squash_merge_commit_message) want=PR_BODY ;;
            *)                           want="" ;;
        esac
        if [[ "$cur" == "$want" ]]; then
            note_ok "$merge_key" "$cur"
        elif [[ "$MODE" == converge ]]; then
            note_conv "$merge_key" "$cur" "$want"
            merge_drift=1
        else
            note_drift "$merge_key" "$cur" "$want"
        fi
    done
    if [[ "$MODE" == converge && $merge_drift -eq 1 ]]; then
        jq -n '{
            allow_squash_merge: true,
            allow_merge_commit: false,
            allow_rebase_merge: false,
            delete_branch_on_merge: true,
            squash_merge_commit_title: "PR_TITLE",
            squash_merge_commit_message: "PR_BODY"
        }' | gh_call "merge-settings" api "repos/$REPO_SLUG" --method PATCH --input - >/dev/null
        note_fixed "merge-settings" "squash-only + delete_branch_on_merge"
    fi

    # --- Step 6: branch ruleset (own several rules; preserve the rest) ----
    hdr "Branch ruleset (target: $default_branch)"
    local rulesets_json matched_id="" matched_detail="" rid detail

    rulesets_json="$(gh_call "rulesets-list" api "repos/$REPO_SLUG/rulesets")"
    while IFS= read -r rid; do
        [[ -n "$rid" ]] || continue
        detail="$(gh_call "ruleset-get" api "repos/$REPO_SLUG/rulesets/$rid")"
        if printf '%s' "$detail" | jq -e --arg b "refs/heads/$default_branch" '
                (.conditions.ref_name.include // []) as $inc
                | (($inc | index($b)) != null) or (($inc | index("~DEFAULT_BRANCH")) != null)
            ' >/dev/null; then
            matched_id="$rid"
            matched_detail="$detail"
            break
        fi
    done < <(printf '%s' "$rulesets_json" | jq -r '.[] | select(.target=="branch") | .id')

    if [[ -z "$matched_id" ]]; then
        if [[ "$MODE" == converge ]]; then
            note_conv "ruleset" "none targets refs/heads/$default_branch" \
                "active ruleset (non_fast_forward, deletion, pull_request)"
            matched_id="$(jq -n --argjson pp "$PR_PARAMS" '{
                name: "Protect default branch",
                target: "branch",
                enforcement: "active",
                bypass_actors: [],
                conditions: { ref_name: { include: ["~DEFAULT_BRANCH"], exclude: [] } },
                rules: [ {type:"non_fast_forward"}, {type:"deletion"}, {type:"pull_request", parameters:$pp} ]
            }' | ruleset_write_verify "ruleset-create" POST "repos/$REPO_SLUG/rulesets")"
            note_fixed "ruleset" "created 'Protect default branch' (active, targets ~DEFAULT_BRANCH), id $matched_id"
        else
            note_drift "ruleset" "none targets refs/heads/$default_branch" \
                "active ruleset w/ non_fast_forward, deletion, pull_request"
        fi
    else
        local ruleset_needs_put=0 rt enf cur_count has_rsc

        # non_fast_forward + deletion: presence-only owned rules.
        for rt in non_fast_forward deletion; do
            if printf '%s' "$matched_detail" | jq -e --arg t "$rt" '(.rules // []) | any(.type == $t)' >/dev/null; then
                note_ok "rule.$rt" "present"
            elif [[ "$MODE" == converge ]]; then
                note_conv "rule.$rt" "absent" "present"
                ruleset_needs_put=1
            else
                note_drift "rule.$rt" "absent" "present"
            fi
        done

        # pull_request: presence AND owned-parameter convergence, from the
        # declared JSON (§ DECLARED JSON) — never hardcoded here.
        if ! printf '%s' "$matched_detail" | jq -e '(.rules // []) | any(.type == "pull_request")' >/dev/null; then
            if [[ "$MODE" == converge ]]; then
                note_conv "rule.pull_request" "absent" "present, per declared JSON"
                ruleset_needs_put=1
            else
                note_drift "rule.pull_request" "absent" "present, per declared JSON"
            fi
        else
            cur_count="$(printf '%s' "$matched_detail" | jq -r \
                '(.rules // []) | map(select(.type=="pull_request"))[0].parameters.required_approving_review_count // "unset"')"
            if printf '%s' "$matched_detail" | jq -e --argjson want "$PR_PARAMS" '
                    ((.rules // []) | map(select(.type=="pull_request"))) as $prs
                    | ($prs[0].parameters // {}) as $p
                    | ($want | to_entries | all(.value == ($p[.key])))
                ' >/dev/null; then
                note_ok "rule.pull_request" "present, review_count=$cur_count"
            elif [[ "$MODE" == converge ]]; then
                note_conv "rule.pull_request" "review_count=$cur_count" "per declared JSON"
                ruleset_needs_put=1
            else
                note_drift "rule.pull_request" "review_count=$cur_count" "per declared JSON"
            fi
        fi

        # required_status_checks: OWNED sub-fields only (strict flag, each
        # context's integration_id). The context LIST ITSELF is PRESERVED —
        # never added to or removed here (§ RULE OWNERSHIP).
        has_rsc="$(printf '%s' "$matched_detail" | jq -e '(.rules // []) | any(.type == "required_status_checks")' >/dev/null && echo yes || echo no)"
        if [[ "$has_rsc" == yes ]]; then
            local cur_strict
            cur_strict="$(printf '%s' "$matched_detail" | jq -r '(.rules // []) | map(select(.type=="required_status_checks"))[0].parameters.strict_required_status_checks_policy')"
            if [[ "$cur_strict" == "$STRICT_WANT" ]]; then
                note_ok "rule.required_status_checks.strict" "$cur_strict"
            elif [[ "$MODE" == converge ]]; then
                note_conv "rule.required_status_checks.strict" "$cur_strict" "$STRICT_WANT"
                ruleset_needs_put=1
            else
                note_drift "rule.required_status_checks.strict" "$cur_strict" "$STRICT_WANT"
            fi

            # Per-context integration_id binding — verified live, per context.
            local ctx_names ctx unbound_ctx=()
            ctx_names="$(printf '%s' "$matched_detail" | jq -r '(.rules // []) | map(select(.type=="required_status_checks"))[0].parameters.required_status_checks[]? | select(.integration_id == null) | .context')"
            if [[ -n "$ctx_names" ]]; then
                while IFS= read -r ctx; do
                    [[ -n "$ctx" ]] || continue
                    local app_id
                    app_id="$(resolve_context_reporter "$default_branch" "$ctx")"
                    if [[ -n "$app_id" ]]; then
                        note_conv "rule.required_status_checks.context[$ctx].integration_id" "unbound" "$app_id (live-verified)"
                        ruleset_needs_put=1
                    elif [[ "$MODE" == converge ]]; then
                        note_conv "rule.required_status_checks.context[$ctx]" "unbound, no live reporter found" \
                            "dropped from required (never bound blind)"
                        ruleset_needs_put=1
                        unbound_ctx+=("$ctx")
                    else
                        note_drift "rule.required_status_checks.context[$ctx]" "unbound, no live reporter found" \
                            "dropped from required (never bound blind)"
                        unbound_ctx+=("$ctx")
                    fi
                done <<< "$ctx_names"
            fi
        fi

        enf="$(printf '%s' "$matched_detail" | jq -r '.enforcement')"
        if [[ "$enf" == active ]]; then
            note_ok "ruleset.enforcement" "$enf"
        elif [[ "$MODE" == converge ]]; then
            note_conv "ruleset.enforcement" "$enf" "active"
            ruleset_needs_put=1
        else
            note_drift "ruleset.enforcement" "$enf" "active"
        fi

        if [[ "$MODE" == converge && $ruleset_needs_put -eq 1 ]]; then
            # Converge every owned field to intent; preserve everything else
            # byte-for-byte. An existing pull_request rule keeps its extra
            # params and gets the declared five forced; required_status_checks
            # keeps its context LIST verbatim but gets strict forced and each
            # unbound context's integration_id filled in from a live lookup
            # (never bound if no live reporter was found, per resolve_context_
            # reporter above — such a context is dropped from the array
            # entirely rather than shipped unbound or guessed); conditions +
            # bypass_actors are preserved exactly; enforcement is forced active.
            matched_id="$(printf '%s' "$matched_detail" | jq --argjson pp "$PR_PARAMS" --argjson strict "$STRICT_WANT" '
                (.rules // []) as $ex
                | ($ex | map(.type)) as $t
                | {
                    name: .name,
                    target: "branch",
                    enforcement: "active",
                    bypass_actors: (.bypass_actors // []),
                    conditions: .conditions,
                    rules: (
                        ($ex | map(
                            if .type == "pull_request"
                            then { type: "pull_request", parameters: ((.parameters // {}) + $pp) }
                            elif .type == "required_status_checks"
                            then .parameters.strict_required_status_checks_policy = $strict
                            else .
                            end
                        ))
                        + (if ($t | index("non_fast_forward")) then [] else [{type:"non_fast_forward"}] end)
                        + (if ($t | index("deletion"))        then [] else [{type:"deletion"}]        end)
                        + (if ($t | index("pull_request"))    then [] else [{type:"pull_request", parameters:$pp}] end)
                    )
                }
            ' | jq --argjson binds "$(
                    # Build {context: app_id} for every context this run resolved above.
                    printf '%s' "$matched_detail" | jq -c '(.rules // []) | map(select(.type=="required_status_checks"))[0].parameters.required_status_checks[]?.context' 2>/dev/null | \
                    while IFS= read -r cq; do
                        c="$(printf '%s' "$cq" | jq -r .)"
                        aid="$(resolve_context_reporter "$default_branch" "$c" 2>/dev/null || true)"
                        [[ -n "$aid" ]] && jq -n --arg c "$c" --argjson a "$aid" '{($c): $a}'
                    done | jq -s 'add // {}'
                )" '
                (.rules | map(.type) | index("required_status_checks")) as $i
                | if $i == null then .
                  else
                    .rules[$i].parameters.required_status_checks |=
                        ( map(
                            if .integration_id == null then
                                (.integration_id = ($binds[.context] // null))
                            else . end
                          )
                          | map(select(.integration_id != null))
                        )
                  end
            ' | ruleset_write_verify "ruleset-update" PUT "repos/$REPO_SLUG/rulesets/$matched_id")"
            note_fixed "ruleset" "patched id $matched_id (owned fields converged; context list, conditions, bypass_actors preserved)"
        fi
    fi

    # --- Step 6b: tag-immutability ruleset — OWNED, discovered by
    # exact declared name (never by "first ruleset targeting tags", so a
    # repo's own unrelated tag ruleset is never mistaken for this one).
    # Creation is deliberately absent from this rule set — that is a later,
    # separately-decided step, not this one's to touch.
    hdr "Tag ruleset ($TAG_RULESET_NAME)"
    local tag_matched_id="" tag_detail="" want_tag_rules
    want_tag_rules="$(printf '%s' "$TAG_RULESET_RULES" | jq -c 'map({type: .})')"
    while IFS= read -r rid; do
        [[ -n "$rid" ]] || continue
        detail="$(gh_call "tag-ruleset-get" api "repos/$REPO_SLUG/rulesets/$rid")"
        if printf '%s' "$detail" | jq -e --arg n "$TAG_RULESET_NAME" '.name == $n' >/dev/null; then
            tag_matched_id="$rid"
            tag_detail="$detail"
            break
        fi
    done < <(printf '%s' "$rulesets_json" | jq -r '.[] | select(.target=="tag") | .id')

    if [[ -z "$tag_matched_id" ]]; then
        if [[ "$MODE" == converge ]]; then
            note_conv "tag-ruleset" "absent" "active, update+deletion blocked, no bypass"
            tag_matched_id="$(jq -n --arg n "$TAG_RULESET_NAME" --argjson rules "$want_tag_rules" '{
                name: $n,
                target: "tag",
                enforcement: "active",
                bypass_actors: [],
                conditions: { ref_name: { include: ["refs/tags/*"], exclude: [] } },
                rules: $rules
            }' | ruleset_write_verify "tag-ruleset-create" POST "repos/$REPO_SLUG/rulesets")"
            note_fixed "tag-ruleset" "created '$TAG_RULESET_NAME', id $tag_matched_id"
        else
            note_drift "tag-ruleset" "absent" "active, update+deletion blocked, no bypass"
        fi
    else
        local tag_needs_put=0 tag_enf
        if printf '%s' "$tag_detail" | jq -e --argjson want "$want_tag_rules" '(.rules // []) == $want' >/dev/null; then
            note_ok "tag-ruleset.rules" "update,deletion"
        elif [[ "$MODE" == converge ]]; then
            note_conv "tag-ruleset.rules" "$(printf '%s' "$tag_detail" | jq -c '.rules // []')" "$want_tag_rules"
            tag_needs_put=1
        else
            note_drift "tag-ruleset.rules" "$(printf '%s' "$tag_detail" | jq -c '.rules // []')" "$want_tag_rules"
        fi
        if printf '%s' "$tag_detail" | jq -e '(.bypass_actors // []) == []' >/dev/null; then
            note_ok "tag-ruleset.bypass_actors" "[]"
        elif [[ "$MODE" == converge ]]; then
            note_conv "tag-ruleset.bypass_actors" "$(printf '%s' "$tag_detail" | jq -c '.bypass_actors')" "[]"
            tag_needs_put=1
        else
            note_drift "tag-ruleset.bypass_actors" "$(printf '%s' "$tag_detail" | jq -c '.bypass_actors')" "[]"
        fi
        tag_enf="$(printf '%s' "$tag_detail" | jq -r '.enforcement')"
        if [[ "$tag_enf" == active ]]; then
            note_ok "tag-ruleset.enforcement" "active"
        elif [[ "$MODE" == converge ]]; then
            note_conv "tag-ruleset.enforcement" "$tag_enf" "active"
            tag_needs_put=1
        else
            note_drift "tag-ruleset.enforcement" "$tag_enf" "active"
        fi
        if [[ "$MODE" == converge && $tag_needs_put -eq 1 ]]; then
            tag_matched_id="$(jq -n --arg n "$TAG_RULESET_NAME" --argjson rules "$want_tag_rules" --argjson cond "$(printf '%s' "$tag_detail" | jq -c '.conditions')" '{
                name: $n,
                target: "tag",
                enforcement: "active",
                bypass_actors: [],
                conditions: $cond,
                rules: $rules
            }' | ruleset_write_verify "tag-ruleset-update" PUT "repos/$REPO_SLUG/rulesets/$tag_matched_id")"
            note_fixed "tag-ruleset" "patched id $tag_matched_id (update+deletion blocked, no bypass)"
        fi
    fi

    # --- Step 7: secret scanning + push protection (public repos only) -----
    # Neither feature exists on a private repo under a personal account
    # (§ VISIBILITY) — skip cleanly rather than fail or report a false
    # downgrade.
    hdr "Secret scanning"
    if [[ "$is_private" == "true" ]]; then
        note_skip "secret_scanning" "private repo — feature does not apply"
        note_skip "secret_scanning_push_protection" "private repo — feature does not apply"
    else
        local ss_status pp_status secret_drift=0
        ss_status="$(printf '%s' "$repo_json" | jq -r '.security_and_analysis.secret_scanning.status // "unknown"')"
        pp_status="$(printf '%s' "$repo_json" | jq -r '.security_and_analysis.secret_scanning_push_protection.status // "unknown"')"
        if [[ "$ss_status" == enabled ]]; then
            note_ok "secret_scanning" "$ss_status"
        elif [[ "$MODE" == converge ]]; then
            note_conv "secret_scanning" "$ss_status" "enabled"
            secret_drift=1
        else
            note_drift "secret_scanning" "$ss_status" "enabled"
        fi
        if [[ "$pp_status" == enabled ]]; then
            note_ok "secret_scanning_push_protection" "$pp_status"
        elif [[ "$MODE" == converge ]]; then
            note_conv "secret_scanning_push_protection" "$pp_status" "enabled"
            secret_drift=1
        else
            note_drift "secret_scanning_push_protection" "$pp_status" "enabled"
        fi
        if [[ "$MODE" == converge && $secret_drift -eq 1 ]]; then
            jq -n '{
                security_and_analysis: {
                    secret_scanning: { status: "enabled" },
                    secret_scanning_push_protection: { status: "enabled" }
                }
            }' | gh_call "secret-scanning" api "repos/$REPO_SLUG" --method PATCH --input - >/dev/null
            note_fixed "secret-scanning" "secret_scanning + push_protection enabled"
        fi
    fi
}

# ----------------------------------------------------------------------------
# Dispatch — local steps first (per spec order + fail-closed before any remote
# work), then remote.
# ----------------------------------------------------------------------------
if [[ -n "$LOCAL_PATH" ]]; then
    process_local "$LOCAL_PATH"
fi
process_remote

# ----------------------------------------------------------------------------
# Summary + exit
# ----------------------------------------------------------------------------
hdr "Summary"
if [[ "$MODE" == check ]]; then
    if [[ $DRIFT_COUNT -eq 0 ]]; then
        echo "  $REPO_SLUG: no drift — fully wired."
        exit 0
    fi
    echo "  $REPO_SLUG: $DRIFT_COUNT drift item(s). Run without --check to converge."
    exit 1
fi

# converge
if [[ $DRIFT_COUNT -eq 0 ]]; then
    echo "  $REPO_SLUG: converged (or already wired)."
    exit 0
fi
echo "  $REPO_SLUG: $DRIFT_COUNT drift item(s) could not be auto-resolved (see above)."
exit 1
