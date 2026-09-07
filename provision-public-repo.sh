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

# § DRIFT-CHECK DECLARATIONS (--check only; the drift check holds every repo to
# the core — LEX rollout Step 9). Optional top-level keys, read once here:
#   .release_tag_authors : array of the login/name strings a tag from the
#     release path may carry as its annotated-tag tagger (release-dotty's App
#     push, a plugin release-tag job). Tag origin has no ruleset enforcement
#     (tag creation is unrestricted, immutability-only) — so the drift check is
#     the enforcement surface: a lightweight tag, or an annotated tag whose
#     tagger is not in this set, is reported DRIFT. Absent -> the class reports
#     "not declared" (never false-clean), never silently passes.
RELEASE_TAG_AUTHORS="$(printf '%s' "$DECLARED_JSON" | jq -c '.release_tag_authors // null')"
if [[ "$RELEASE_TAG_AUTHORS" != "null" ]] && ! printf '%s' "$RELEASE_TAG_AUTHORS" | jq -e 'type == "array" and all(.[]; type == "string")' >/dev/null 2>&1; then
    echo "FATAL [declared-json]: '.release_tag_authors' must be an array of strings in $DECLARED_JSON_PATH" >&2
    exit 1
fi

#   .codeowners_default_owner : the owner every repo's CODEOWNERS must name on
#     its `* <owner>` line (§ codeowners-policy in drift_check_extras below).
#     Everything is owned by that default MINUS an explicit per-repo ownerless
#     appendix — so this key is the "everything owned by default" half of the
#     Topic-5 decision. Absent -> the class reports "not declared" (never
#     false-clean), never silently passes. Read with the explicit null-check
#     (not `//`) so a malformed non-string declaration FATALs rather than
#     collapsing to the "absent" sentinel.
CODEOWNERS_DEFAULT_OWNER="$(printf '%s' "$DECLARED_JSON" | jq -r '.codeowners_default_owner as $v | if $v == null then "null" else ($v | tostring) end')"
if [[ "$CODEOWNERS_DEFAULT_OWNER" != "null" ]] && ! printf '%s' "$DECLARED_JSON" | jq -e '.codeowners_default_owner | type == "string"' >/dev/null 2>&1; then
    echo "FATAL [declared-json]: '.codeowners_default_owner' must be a string in $DECLARED_JSON_PATH" >&2
    exit 1
fi

# § REPO CONTEXT DECLARATIONS — optional, per-repo, additive migration.
# `.repos["<owner>/<repo>"].required_contexts` is a per-repo list of the
# EXACT required-context strings this repo's ruleset should carry (the
# reusable-workflow contexts plus any repo-specific appendix context that
# stays separately required rather than folding into an aggregate — see
# the estate CI/CD rollout + the drift-check work). A repo with NO entry here keeps the original
# byte-for-byte-preserved context-list behavior (§ RULE OWNERSHIP above)
# unchanged — this is deliberately additive so declaring one repo's list
# never touches a repo that hasn't been migrated yet. `null` (the entry, the
# repo, or the whole `.repos` key absent) means "not declared for this repo".
REPO_DECLARED_CONTEXTS="$(printf '%s' "$DECLARED_JSON" | jq -c --arg repo "$REPO_SLUG" '.repos[$repo].required_contexts // null')"
if [[ "$REPO_DECLARED_CONTEXTS" != "null" ]] && ! printf '%s' "$REPO_DECLARED_CONTEXTS" | jq -e 'type == "array" and all(.[]; type == "string")' >/dev/null 2>&1; then
    echo "FATAL [declared-json]: '.repos[\"$REPO_SLUG\"].required_contexts' must be an array of strings in $DECLARED_JSON_PATH" >&2
    exit 1
fi

# `.repos["<owner>/<repo>"].core_call_exempt` — per-repo escape hatch from
# missing-core-call (§ drift_check_extras below): every repo must call the
# estate's reusable core workflows; absent here means "not exempt" (enforce),
# never "not checked".
REPO_CORE_CALL_EXEMPT="$(printf '%s' "$DECLARED_JSON" | jq -r --arg repo "$REPO_SLUG" '.repos[$repo].core_call_exempt // false')"
if [[ "$REPO_CORE_CALL_EXEMPT" != "true" && "$REPO_CORE_CALL_EXEMPT" != "false" ]]; then
    echo "FATAL [declared-json]: '.repos[\"$REPO_SLUG\"].core_call_exempt' must be a boolean in $DECLARED_JSON_PATH" >&2
    exit 1
fi

# `.repos["<owner>/<repo>"].private_repo` — the declared SOURCE OF TRUTH for
# private-repo-profile's three-way compare (§ drift_check_extras below).
# `null` means "not declared" — the class then falls back to the
# plain-public-repo default rather than guessing at intent.
REPO_DECLARED_PRIVATE="$(printf '%s' "$DECLARED_JSON" | jq -r --arg repo "$REPO_SLUG" \
    '.repos[$repo].private_repo as $v | if $v == null then "null" else ($v | tostring) end')"
if [[ "$REPO_DECLARED_PRIVATE" != "null" && "$REPO_DECLARED_PRIVATE" != "true" && "$REPO_DECLARED_PRIVATE" != "false" ]]; then
    echo "FATAL [declared-json]: '.repos[\"$REPO_SLUG\"].private_repo' must be a boolean in $DECLARED_JSON_PATH" >&2
    exit 1
fi

# `.repos["<owner>/<repo>"].admin_exceptions` — declared admin exceptions for
# this repo, each `{flag, reason}`; every entry MUST carry a non-empty
# `reason` (§ admin-exception-reason below). `null` means "none declared".
REPO_ADMIN_EXCEPTIONS="$(printf '%s' "$DECLARED_JSON" | jq -c --arg repo "$REPO_SLUG" '.repos[$repo].admin_exceptions // null')"
if [[ "$REPO_ADMIN_EXCEPTIONS" != "null" ]] && ! printf '%s' "$REPO_ADMIN_EXCEPTIONS" | jq -e 'type == "array" and all(.[]; type == "object" and has("flag"))' >/dev/null 2>&1; then
    echo "FATAL [declared-json]: '.repos[\"$REPO_SLUG\"].admin_exceptions' must be an array of {flag, reason} objects in $DECLARED_JSON_PATH" >&2
    exit 1
fi

# `.repos["<owner>/<repo>"].deploy_keys_allow` — the declared allow-set of
# deploy-key titles for deploy-key-inventory (§ S2 below). `null` means "not
# declared" — the class skips rather than guessing at a policy.
REPO_DEPLOY_KEYS_ALLOW="$(printf '%s' "$DECLARED_JSON" | jq -c --arg repo "$REPO_SLUG" '.repos[$repo].deploy_keys_allow // null')"
if [[ "$REPO_DEPLOY_KEYS_ALLOW" != "null" ]] && ! printf '%s' "$REPO_DEPLOY_KEYS_ALLOW" | jq -e 'type == "array" and all(.[]; type == "string")' >/dev/null 2>&1; then
    echo "FATAL [declared-json]: '.repos[\"$REPO_SLUG\"].deploy_keys_allow' must be an array of strings in $DECLARED_JSON_PATH" >&2
    exit 1
fi

# `.repos["<owner>/<repo>"].codeowners_appendix` — the per-repo allow-list of
# ownerless (deliberately unowned) CODEOWNERS patterns (§ codeowners-policy
# below). Any live ownerless pattern NOT in this list frees a path the policy
# keeps owned -> DRIFT. `null` (not declared for this repo) means the class
# skips rather than guessing which paths may be freed.
REPO_CODEOWNERS_APPENDIX="$(printf '%s' "$DECLARED_JSON" | jq -c --arg repo "$REPO_SLUG" '.repos[$repo].codeowners_appendix // null')"
if [[ "$REPO_CODEOWNERS_APPENDIX" != "null" ]] && ! printf '%s' "$REPO_CODEOWNERS_APPENDIX" | jq -e 'type == "array" and all(.[]; type == "string")' >/dev/null 2>&1; then
    echo "FATAL [declared-json]: '.repos[\"$REPO_SLUG\"].codeowners_appendix' must be an array of strings in $DECLARED_JSON_PATH" >&2
    exit 1
fi

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
# unordered collections sorted, for read-back comparison/display. Reads JSON
# on stdin.
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

# ruleset_matches_intent <intended-json> <observed-json> — true if every rule
# TYPE intended declares is present in observed (and vice versa — no genuinely
# missing or extra rule), and every parameter KEY intended's rule declares
# matches observed's value for that key. Observed may carry EXTRA parameter
# keys GitHub itself attaches (e.g. allowed_merge_methods, required_reviewers
# on a freshly-created pull_request rule) without that counting as a mismatch
# — this tool owns the keys it declares, never the whole object (§ RULE
# OWNERSHIP). Top-level fields (name/target/enforcement/conditions/
# bypass_actors) are compared exactly — GitHub does not silently embellish
# those.
ruleset_matches_intent() {
    jq -n --argjson intended "$1" --argjson observed "$2" '
        def top_ok:
            $intended.name == $observed.name and
            $intended.target == $observed.target and
            $intended.enforcement == $observed.enforcement and
            ($intended.conditions == $observed.conditions) and
            (($intended.bypass_actors // []) | sort_by([.actor_type, (.actor_id // -1)]))
                == (($observed.bypass_actors // []) | sort_by([.actor_type, (.actor_id // -1)]));
        def rules_ok:
            ($intended.rules // []) as $ir
            | ($observed.rules // []) as $or
            | (($ir | map(.type)) | sort) == (($or | map(.type)) | sort)
              and
              ($ir | all(
                  . as $rule
                  | (($or[] | select(.type == $rule.type)) // {}) as $orule
                  | ($rule.parameters // {}) as $ip
                  | ($orule.parameters // {}) as $op
                  | ($ip | to_entries | all(
                        if .key == "required_status_checks" then
                            ((.value // []) | sort_by(.context)) == (($op.required_status_checks // []) | sort_by(.context))
                        else
                            .value == ($op[.key])
                        end
                    ))
              ));
        top_ok and rules_ok
    ' | grep -q true
}

# ruleset_write_verify <label> <method> <url> — reads the intended full
# object on stdin, writes it, re-GETs the ruleset, and FATALs if the observed
# state does not satisfy every field this tool declared (see
# ruleset_matches_intent — extra GitHub-attached keys are not a mismatch).
# Never assumes a 200 means the write landed as intended. Echoes the
# (re-fetched) ruleset id on success.
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
    if ! ruleset_matches_intent "$intended" "$got"; then
        echo "FATAL [$label]: read-back after write does not satisfy intent for $REPO_SLUG." >&2
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

# resolve_context_reporter_any_pr <default_branch> <context_name> — like
# resolve_context_reporter, but for a context name that is not yet in the
# ruleset at all (§ REPO CONTEXT DECLARATIONS): a brand-new context most
# often has no MERGED PR reporting it yet (the caller PR that introduces it
# may still be open), so this also checks the most recently updated OPEN
# PR's head commit before giving up. Same contract as
# resolve_context_reporter: empty output (not FATAL) means no live reporter
# anywhere — the caller refuses to add a context it cannot verify live,
# never binds one blind.
#
# RESIDUAL (attack-kitty pressure-test; no change for this rollout, flagged for
# later): the OPEN-PR fallback binds the context's integration_id from a
# check-run on the newest open PR's head commit — attacker-controllable on a
# repo that accepts outside PRs (an outside contributor could open a PR whose
# head reports a same-named check from an app id of their choosing, so a
# converge run that happens to pick that PR would bind the wrong app). The
# merged-only path (resolve_context_reporter) is reviewed and safe; this
# widening trades that for being able to establish a context from the very PR
# introducing it. Safe for the solo-operator estate (only the operator opens
# PRs). Revisit — restrict to merged-only, or require the open PR be
# author-trusted — before required_contexts is used on any repo that takes
# outside PRs.
resolve_context_reporter_any_pr() {
    local branch="$1" ctx="$2" app_id sha
    app_id="$(resolve_context_reporter "$branch" "$ctx")"
    if [[ -n "$app_id" ]]; then
        printf '%s' "$app_id"
        return 0
    fi
    sha="$(gh_call "open-pr" api "repos/$REPO_SLUG/pulls?state=open&base=$branch&sort=updated&direction=desc&per_page=10" | \
        jq -r '.[0].head.sha // empty')"
    [[ -n "$sha" ]] || return 0
    gh_call "check-runs-open" api "repos/$REPO_SLUG/commits/$sha/check-runs" | \
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
                     delete_branch_on_merge allow_auto_merge allow_update_branch \
                     squash_merge_commit_title squash_merge_commit_message; do
        cur="$(printf '%s' "$repo_json" | jq -r --arg k "$merge_key" '.[$k]')"
        case "$merge_key" in
            allow_squash_merge)          want=true ;;
            allow_merge_commit)          want=false ;;
            allow_rebase_merge)          want=false ;;
            delete_branch_on_merge)      want=true ;;
            # allow_auto_merge: the repo-level enable for "merge when checks
            # pass" -- the map's "unowned PRs merge on green" needs it ON, and
            # arming stays a NON-AUTHOR act (until Margot: the operator, never
            # the authoring session). allow_update_branch: exposes GitHub's
            # own "update branch" so a PR stranded behind an advanced base
            # under strict checks can be brought current (the named
            # branch-updater path) without a force-rebase.
            allow_auto_merge)            want=true ;;
            allow_update_branch)         want=true ;;
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
            allow_auto_merge: true,
            allow_update_branch: true,
            squash_merge_commit_title: "PR_TITLE",
            squash_merge_commit_message: "PR_BODY"
        }' | gh_call "merge-settings" api "repos/$REPO_SLUG" --method PATCH --input - >/dev/null
        note_fixed "merge-settings" "squash-only + delete_branch_on_merge + auto-merge + update-branch"
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
            # Re-fetch the just-created ruleset so the convergence block below
            # runs against it too -- in particular, a declared context list
            # (§ REPO CONTEXT DECLARATIONS) gets its required_status_checks
            # rule created here, the same from-scratch path as an existing
            # rsc-less ruleset (FOLD: without this, a repo created from
            # absolute scratch with a declared list would never get its
            # required checks -- the tier-downgrade class again).
            matched_detail="$(gh_call "ruleset-get-after-create" api "repos/$REPO_SLUG/rulesets/$matched_id")"
        else
            note_drift "ruleset" "none targets refs/heads/$default_branch" \
                "active ruleset w/ non_fast_forward, deletion, pull_request"
        fi
    fi

    # Convergence runs against any ruleset we have in hand: an existing one
    # (check or converge), or one just created above (converge). A genuinely
    # absent ruleset in --check mode (matched_detail empty) is already
    # reported as drift above; there is nothing to converge.
    if [[ -n "$matched_detail" ]]; then
        local ruleset_needs_put=0 rt enf cur_count has_rsc
        # Always defined (set -u): referenced unconditionally at the write
        # step below, but only populated when a declared list or an existing
        # rule needs it — the empty-array no-op otherwise, never an
        # unbound-variable FATAL.
        ADD_CONTEXTS_JSON="[]"
        REMOVE_CONTEXTS_JSON="[]"

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
        # context's integration_id) and -- when the repo DECLARES a context
        # list (§ REPO CONTEXT DECLARATIONS) -- the list itself. A repo with
        # NO declared list keeps its context list byte-for-byte-preserved,
        # never added to or removed (§ RULE OWNERSHIP), exactly as before this
        # feature existed.
        has_rsc="$(printf '%s' "$matched_detail" | jq -e '(.rules // []) | any(.type == "required_status_checks")' >/dev/null && echo yes || echo no)"

        # Strict flag + per-context integration binding operate on an EXISTING
        # required_status_checks rule; only meaningful when one is present.
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
                    local app_id_b
                    app_id_b="$(resolve_context_reporter "$default_branch" "$ctx")"
                    if [[ -n "$app_id_b" ]]; then
                        note_conv "rule.required_status_checks.context[$ctx].integration_id" "unbound" "$app_id_b (live-verified)"
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

        # Context-LIST convergence -- runs whenever a list is declared,
        # REGARDLESS of whether a required_status_checks rule exists yet. A
        # declared list on a ruleset with NO rsc rule is the from-scratch case
        # (a repo this tool just created, or one that never had required
        # checks): FOLD -- previously this whole block sat inside the
        # `has_rsc == yes` guard, so a declared-but-no-rsc-rule repo was
        # reported "fully wired" and the rule silently never created -- the
        # exact tier-downgrade this tool exists to prevent (attack-kitty
        # pressure-test). Now the rule is CREATED in the PUT below,
        # populated with the live-verified declared contexts (each refused if
        # it has never reported -- never bound blind). An absent rsc rule with
        # NO declared list is still left absent (a repo's own business).
        if [[ "$REPO_DECLARED_CONTEXTS" != "null" ]]; then
            # ctx_list_changed tracks whether the live list differs from
            # declared in ANY way (add, remove, refuse, or an absent rsc
            # rule) -- set in both --check and converge, unlike the
            # ADD/REMOVE arrays which populate only in converge. The
            # "matches declared" note below is gated on it so --check never
            # prints both the per-context drift lines AND a contradictory
            # "matches declared" summary.
            local live_ctx_list dc rc app_id ctx_list_changed=0
            live_ctx_list="$(printf '%s' "$matched_detail" | jq -c '(.rules // []) | map(select(.type=="required_status_checks"))[0].parameters.required_status_checks // []')"
            if [[ "$has_rsc" == no ]]; then
                ctx_list_changed=1
                if [[ "$MODE" == converge ]]; then
                    note_conv "rule.required_status_checks" "absent (no required_status_checks rule)" \
                        "created, populated from the declared context list (each context live-verified or refused)"
                else
                    note_drift "rule.required_status_checks" "absent (no required_status_checks rule)" \
                        "would create, populated from the declared context list"
                fi
            fi

            while IFS= read -r dc; do
                [[ -n "$dc" ]] || continue
                if printf '%s' "$live_ctx_list" | jq -e --arg c "$dc" 'any(.[]; .context == $c)' >/dev/null; then
                    continue
                fi
                ctx_list_changed=1
                app_id="$(resolve_context_reporter_any_pr "$default_branch" "$dc")"
                if [[ -n "$app_id" ]]; then
                    if [[ "$MODE" == converge ]]; then
                        note_conv "rule.required_status_checks.context-list[+$dc]" "absent" "added, bound to $app_id (live-verified)"
                        ruleset_needs_put=1
                        ADD_CONTEXTS_JSON="$(printf '%s' "$ADD_CONTEXTS_JSON" | jq -c --arg c "$dc" --argjson a "$app_id" '. + [{context:$c, integration_id:$a}]')"
                    else
                        note_drift "rule.required_status_checks.context-list[+$dc]" "absent" "would add, bound to $app_id (live-verified)"
                    fi
                else
                    # Neither converge nor --check can resolve this one (same
                    # category as Step 2's "gitleaks.toml-tracked absent" —
                    # a real difference from declared that this script will
                    # not synthesize its way past): note_drift regardless of
                    # mode, never note_conv, since nothing is written for it.
                    note_drift "rule.required_status_checks.context-list[+$dc]" "declared but never reported" \
                        "refusing to require -- never reported on $default_branch or an open PR (a typo must never lock the repo)"
                fi
            done < <(printf '%s' "$REPO_DECLARED_CONTEXTS" | jq -r '.[]')

            while IFS= read -r rc; do
                [[ -n "$rc" ]] || continue
                if printf '%s' "$REPO_DECLARED_CONTEXTS" | jq -e --arg c "$rc" 'any(.[]; . == $c)' >/dev/null; then
                    continue
                fi
                ctx_list_changed=1
                if [[ "$MODE" == converge ]]; then
                    note_conv "rule.required_status_checks.context-list[-$rc]" "present" "removed (not in declared list)"
                    ruleset_needs_put=1
                    REMOVE_CONTEXTS_JSON="$(printf '%s' "$REMOVE_CONTEXTS_JSON" | jq -c --arg c "$rc" '. + [$c]')"
                else
                    note_drift "rule.required_status_checks.context-list[-$rc]" "present" "would remove (not in declared list)"
                fi
            done < <(printf '%s' "$live_ctx_list" | jq -r '.[].context')

            if [[ "$has_rsc" == yes && "$ctx_list_changed" -eq 0 ]]; then
                note_ok "rule.required_status_checks.context-list" "matches declared ($REPO_DECLARED_CONTEXTS)"
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
            ' | jq --argjson add "$ADD_CONTEXTS_JSON" --argjson remove "$REMOVE_CONTEXTS_JSON" --argjson strict "$STRICT_WANT" '
                # Context-LIST convergence (§ REPO CONTEXT DECLARATIONS): a
                # no-op when neither array is populated (repo not declared,
                # or declared and already matching — ADD_CONTEXTS_JSON/
                # REMOVE_CONTEXTS_JSON are always "[]" in either case).
                # When a list is declared but the ruleset has NO
                # required_status_checks rule (the from-scratch case, FOLD),
                # the rule is CREATED here, strict-forced, populated with the
                # added (already live-bound) contexts. $add is empty when
                # every declared context was refused as never-reported, so a
                # rule is never created empty/blind.
                (.rules | map(.type) | index("required_status_checks")) as $i
                | if $i == null then
                    (if ($add | length) > 0
                     then .rules += [{
                            type: "required_status_checks",
                            parameters: {
                                strict_required_status_checks_policy: $strict,
                                required_status_checks: $add
                            }
                          }]
                     else . end)
                  else
                    .rules[$i].parameters.required_status_checks |=
                        ( map(select((.context as $c | $remove | index($c)) == null))
                          + $add
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
        # security_and_analysis is null/absent unless the token can read it (the
        # App token cannot; an admin/operator login can). Unreadable is "not
        # readable under current scope" — SKIP, never a false "unknown -> DRIFT".
        # Under a full-scope token the field is present and the real status is
        # read, reported, and converged exactly as before.
        if ! printf '%s' "$repo_json" | jq -e '.security_and_analysis != null' >/dev/null 2>&1; then
            note_skip "secret_scanning" "not readable under current scope (security_and_analysis not visible to this token)"
            note_skip "secret_scanning_push_protection" "not readable under current scope (security_and_analysis not visible to this token)"
        else
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
    fi
}

# ----------------------------------------------------------------------------
# Mechanical drift-check helpers (drift_check_extras, below) — App-token-safe
# reads only (contents API, git refs/tags, repo metadata, compare). Tolerant:
# a 404/403 must never abort under set -e, so every call here goes through
# "$GH" directly (never gh_call), and raw JSON is fetched then read with jq
# LOCALLY (the eval stub ignores gh --jq).
# ----------------------------------------------------------------------------

# The estate's own core repo — every repo's ci.yml/gate.yml calls its reusable
# workflows, every pre-commit consumer pins its rev, forked-scripts compares
# against it. A fixed estate constant, never a declared/per-repo value.
DOTTY_UPSTREAM_SLUG="lexijamesesq/dotty"
# Canonical home of check-plugin-version.sh post-substrate-regroup (dotty's
# own header context: "repo core-skills, the renamed work-lifecycle").
CORE_SKILLS_SLUG="lexijamesesq/core-skills"

# fetch_repo_file <repo> <path> — tolerant contents-API fetch + LOCAL base64
# decode. Echoes decoded text; returns non-zero with empty output when the
# file is absent/unreadable (a 404 is "no such file", never FATAL).
fetch_repo_file() {
    local repo="$1" path="$2" json content
    json="$("$GH" api "repos/$repo/contents/$path" 2>/dev/null || echo '{}')"
    content="$(printf '%s' "$json" | jq -r '.content // empty' 2>/dev/null)"
    [[ -n "$content" ]] || return 1
    printf '%s' "$content" | tr -d '\n' | base64 --decode 2>/dev/null \
        || printf '%s' "$content" | tr -d '\n' | base64 -D 2>/dev/null
}

# dotty_latest_tag — the first entry of repos/$DOTTY_UPSTREAM_SLUG/tags
# (GitHub returns newest-first). Empty output (never FATAL) means dotty's own
# tag list is unreadable/empty — callers treat that as "cannot classify",
# never as "current" or "drift" (never bound blind, same doctrine as
# resolve_context_reporter).
dotty_latest_tag() {
    # A pipeline's exit status (pipefail is on) is the rightmost non-zero
    # exit among its stages — an absent/unreadable tags list makes both "$GH"
    # AND jq (empty stdin) fail, and an unguarded failure here would abort
    # the whole script under set -e. `|| true` makes this tolerant like every
    # other read in this section; empty output already means "unreadable" to
    # every caller.
    "$GH" api "repos/$DOTTY_UPSTREAM_SLUG/tags" 2>/dev/null | jq -r '.[0].name // empty' 2>/dev/null || true
}

# extract_uses_ref <content> <marker> — the ref after "<marker>@" up to the
# next whitespace, from a `uses: .../<marker>@<ref>` line. Empty output (not
# an error) means the marker was not found in this content. <marker> is a
# fixed literal this file controls (e.g. "estate-ci\.yml"), not user input.
extract_uses_ref() {
    # grep exits non-zero on "no match" — the ordinary, expected outcome when
    # a repo simply doesn't reference this marker (pipefail would otherwise
    # propagate that as this pipeline's exit status and abort the script
    # under set -e). `|| true` makes "not found" a normal empty return.
    printf '%s\n' "$1" | grep -oE "${2}@[A-Za-z0-9._/-]+" | head -n1 | sed -E "s/^${2}@//" || true
}

# classify_dotty_pin <label> <ref> — a `uses: .../<workflow-or-action>@<ref>`
# pin extracted from a caller's own workflow file, classified against dotty
# main + dotty's latest release tag. Reports directly (note_ok/note_drift/
# note_skip); nothing is returned. Buckets:
#   * ref reachable on dotty main, at/after the latest tag -> OK current
#   * ref reachable on dotty main, before the latest tag    -> OK outdated
#     (advisory only — Dependabot's lane, never drift)
#   * ref NOT reachable on dotty main                       -> DRIFT unauthorized
#   * dotty's own tag/main data unreadable                  -> SKIP (never guessed)
classify_dotty_pin() {
    local label="$1" ref="$2" latest main_cmp main_status tag_cmp tag_status
    latest="$(dotty_latest_tag)"
    if [[ -z "$latest" ]]; then
        note_skip "$label" "dotty's tag list unreadable — cannot classify pin"
        return 0
    fi
    # base=ref, head=main: "identical"/"ahead" means main is at-or-ahead of
    # ref, i.e. ref IS an ancestor of main (reachable); "behind"/"diverged"
    # means ref carries commits main does not — not reachable, unauthorized.
    main_cmp="$("$GH" api "repos/$DOTTY_UPSTREAM_SLUG/compare/$ref...main" 2>/dev/null || echo '{}')"
    main_status="$(printf '%s' "$main_cmp" | jq -r '.status // empty' 2>/dev/null)"
    case "$main_status" in
        identical)
            note_ok "$label" "$ref (current, at dotty main HEAD)"
            return 0
            ;;
        ahead) : ;; # reachable on main, older than HEAD — fall through to the tag compare
        behind|diverged)
            note_drift "$label" "$ref" "not reachable on dotty main (unauthorized ref)"
            return 0
            ;;
        *)
            note_skip "$label" "cannot verify $ref against dotty main — comparison unreadable"
            return 0
            ;;
    esac
    if [[ "$ref" == "$latest" ]]; then
        note_ok "$label" "$ref (current release)"
        return 0
    fi
    # base=latest tag, head=ref: "identical"/"ahead" means ref is at-or-after
    # the latest release tag; "behind" means ref predates it (still reachable
    # on main — advisory outdated, never drift, per Dependabot's lane).
    tag_cmp="$("$GH" api "repos/$DOTTY_UPSTREAM_SLUG/compare/$latest...$ref" 2>/dev/null || echo '{}')"
    tag_status="$(printf '%s' "$tag_cmp" | jq -r '.status // empty' 2>/dev/null)"
    case "$tag_status" in
        identical|ahead)
            note_ok "$label" "$ref (current, at/after $latest)"
            ;;
        behind)
            note_ok "$label" "$ref (outdated — predates $latest; Dependabot's lane)"
            ;;
        *)
            note_ok "$label" "$ref (reachable on dotty main; cannot compare precisely against $latest)"
            ;;
    esac
}

# ----------------------------------------------------------------------------
# Drift-check-only classes (--check): the drift check holds every repo to the
# core. DETECTION reads, never converged — converge applies the declared owned
# config; the scheduled `--check` audits everything else against the core and
# reports DRIFT. Gated to check mode so a converge never fails on an advisory
# class it is not meant to fix. Reads are App-token-safe unless a class notes
# otherwise (those report "not readable under current scope", never false-clean).
# ----------------------------------------------------------------------------
drift_check_extras() {
    [[ "$MODE" == check ]] || return 0

    # --- Tag origin ------------------------------------------------------
    # No ruleset restricts who creates a tag (unrestricted-create, immutability
    # only) — so this check IS the enforcement surface. A release-path tag is an
    # ANNOTATED tag whose tagger is a declared release author (release-dotty's
    # App push; a plugin release-tag job). A LIGHTWEIGHT tag (ref -> commit, no
    # tag object) or an annotated tag with any other tagger is DRIFT. Reads
    # git/refs/tags + git/tags/<sha> only — App-safe.
    hdr "Tag origin"
    if [[ "$RELEASE_TAG_AUTHORS" == "null" ]]; then
        # Estate policy not configured (a top-level, all-repos input) — visible
        # skip, never a silent clean and never per-repo drift. Once
        # .release_tag_authors is declared the class audits every tag.
        note_skip "tag-origin" "no .release_tag_authors declared — tag origin not audited"
    else
        local tag_refs n
        # Tolerant: a repo with no tags returns 404 — "no tags", not an error.
        tag_refs="$("$GH" api "repos/$REPO_SLUG/git/refs/tags" --paginate 2>/dev/null || echo '[]')"
        # The refs API returns a bare object (not an array) when exactly one matches.
        tag_refs="$(printf '%s' "$tag_refs" | jq -c 'if type=="array" then . else [.] end')"
        n="$(printf '%s' "$tag_refs" | jq 'length')"
        if [[ "$n" -eq 0 ]]; then
            note_ok "tag-origin" "no tags"
        else
            local i ref name obj_sha obj_type tagger
            for ((i=0; i<n; i++)); do
                ref="$(printf '%s' "$tag_refs" | jq -c ".[$i]")"
                name="$(printf '%s' "$ref" | jq -r '.ref | sub("^refs/tags/";"")')"
                obj_sha="$(printf '%s' "$ref" | jq -r '.object.sha')"
                obj_type="$(printf '%s' "$ref" | jq -r '.object.type')"
                if [[ "$obj_type" != "tag" ]]; then
                    note_drift "tag-origin[$name]" "lightweight (no tag object)" \
                        "an annotated tag from the release path"
                    continue
                fi
                local tag_obj
                tag_obj="$("$GH" api "repos/$REPO_SLUG/git/tags/$obj_sha" 2>/dev/null || echo '{}')"
                tagger="$(printf '%s' "$tag_obj" | jq -r '.tagger.name // ""')"
                if printf '%s' "$RELEASE_TAG_AUTHORS" | jq -e --arg t "$tagger" 'index($t) != null' >/dev/null 2>&1; then
                    note_ok "tag-origin[$name]" "tagger $tagger"
                else
                    note_drift "tag-origin[$name]" "tagger '${tagger:-<unreadable>}' not a declared release author" \
                        "a tag created outside the release path"
                fi
            done
        fi
    fi

    # Shared reads for the workflow-content classes below (missing-core-call,
    # caller-pin classification, work-lifecycle refs, forked-scripts'
    # setup-gitleaks pin) — fetched once, decoded locally, reused by each.
    # An absent file decodes to an empty string, never FATAL; each class below
    # treats absence per its own spec instead of failing closed here.
    local CI_YML_CONTENT GATE_YML_CONTENT
    CI_YML_CONTENT="$(fetch_repo_file "$REPO_SLUG" ".github/workflows/ci.yml" || true)"
    GATE_YML_CONTENT="$(fetch_repo_file "$REPO_SLUG" ".github/workflows/gate.yml" || true)"

    # --- Missing core call -------------------------------------------------
    # Every repo's ci.yml/gate.yml MUST call the estate's reusable core
    # workflows (estate-ci.yml / estate-gate.yml) — the map's Step 9 floor,
    # not an opt-in. A declared per-repo exemption is the only way out;
    # absent exemption enforces (never a silent pass on "not declared").
    hdr "Core-call coverage"
    if [[ "$REPO_CORE_CALL_EXEMPT" == "true" ]]; then
        note_skip "missing-core-call" "declared .repos[\"$REPO_SLUG\"].core_call_exempt: true"
    else
        local core_missing=()
        printf '%s' "$CI_YML_CONTENT"   | grep -q "estate-ci\.yml@"   || core_missing+=("ci.yml")
        printf '%s' "$GATE_YML_CONTENT" | grep -q "estate-gate\.yml@" || core_missing+=("gate.yml")
        if [[ ${#core_missing[@]} -eq 0 ]]; then
            note_ok "missing-core-call" "ci.yml + gate.yml both call the core"
        else
            note_drift "missing-core-call" "missing/absent: ${core_missing[*]}" \
                "both files call the core (estate-ci.yml@/estate-gate.yml@)"
        fi
    fi

    # --- Caller-pin classification ------------------------------------------
    hdr "Caller-pin classification"
    local ci_ref gate_ref
    ci_ref="$(extract_uses_ref "$CI_YML_CONTENT" 'estate-ci\.yml')"
    gate_ref="$(extract_uses_ref "$GATE_YML_CONTENT" 'estate-gate\.yml')"
    if [[ -z "$ci_ref" && -z "$gate_ref" ]]; then
        note_skip "caller-pin" "no estate-ci.yml@/estate-gate.yml@ pin found (see missing-core-call)"
    else
        [[ -n "$ci_ref" ]]   && classify_dotty_pin "caller-pin[ci.yml]" "$ci_ref"
        [[ -n "$gate_ref" ]] && classify_dotty_pin "caller-pin[gate.yml]" "$gate_ref"
    fi

    # --- work-lifecycle refs (superseded name) ------------------------------
    # Scope: ci.yml, gate.yml, release.yml, and CI.md — not an exhaustive
    # `.github/workflows/*` directory walk (the contents API cannot glob), but
    # every file where this estate's own occurrences have been found: the two
    # reusable-workflow callers, the plugin repos' release.yml (which named
    # work-lifecycle across ci.yml/release.yml/CI.md in the wiring sweep),
    # and CI.md comments.
    hdr "work-lifecycle refs (superseded name)"
    local ci_md_content release_yml_content
    ci_md_content="$(fetch_repo_file "$REPO_SLUG" ".github/CI.md" || true)"
    release_yml_content="$(fetch_repo_file "$REPO_SLUG" ".github/workflows/release.yml" || true)"
    if printf '%s\n%s\n%s\n%s' "$CI_YML_CONTENT" "$GATE_YML_CONTENT" "$release_yml_content" "$ci_md_content" | grep -q "lexijamesesq/work-lifecycle"; then
        note_drift "work-lifecycle-refs" "references lexijamesesq/work-lifecycle" \
            "repoint to core-skills (superseded name)"
    else
        note_ok "work-lifecycle-refs" "no superseded work-lifecycle references"
    fi

    # --- Consumer pre-commit-pin lag ----------------------------------------
    hdr "Pre-commit dotty pin"
    local pcc_content dotty_rev latest_dotty_tag
    pcc_content="$(fetch_repo_file "$REPO_SLUG" ".pre-commit-config.yaml" || true)"
    if [[ -z "$pcc_content" ]]; then
        note_skip "precommit-pin-lag" "no .pre-commit-config.yaml — not a dotty pre-commit consumer"
    else
        # The dotty repo entry's rev:, read as the first `rev:` line following
        # a "repo: .../dotty" line (pre-commit's own YAML shape; a full YAML
        # parse is not worth the dependency for one field).
        dotty_rev="$(printf '%s\n' "$pcc_content" | awk '
            /repo:.*\/dotty([ #]|$)/ { found=1; next }
            found && /^[[:space:]]*rev:/ {
                sub(/^[[:space:]]*rev:[[:space:]]*/, "");
                sub(/[[:space:]]*#.*$/, "");
                print; exit
            }')"
        if [[ -z "$dotty_rev" ]]; then
            note_skip "precommit-pin-lag" "no lexijamesesq/dotty repo pin in .pre-commit-config.yaml — not a consumer"
        else
            latest_dotty_tag="$(dotty_latest_tag)"
            if [[ -z "$latest_dotty_tag" ]]; then
                note_skip "precommit-pin-lag" "dotty's tag list unreadable — cannot compare"
            elif [[ "$dotty_rev" == "$latest_dotty_tag" ]]; then
                note_ok "precommit-pin-lag" "rev: $dotty_rev (current)"
            else
                local pcc_cmp pcc_status
                pcc_cmp="$("$GH" api "repos/$DOTTY_UPSTREAM_SLUG/compare/$latest_dotty_tag...$dotty_rev" 2>/dev/null || echo '{}')"
                pcc_status="$(printf '%s' "$pcc_cmp" | jq -r '.status // empty' 2>/dev/null)"
                if [[ "$pcc_status" == "identical" ]]; then
                    note_ok "precommit-pin-lag" "rev: $dotty_rev (current, same commit as $latest_dotty_tag)"
                else
                    note_drift "precommit-pin-lag" "rev: $dotty_rev" "current dotty release ($latest_dotty_tag)"
                fi
            fi
        fi
    fi

    # --- Private-repo-profile three-way -------------------------------------
    hdr "Private-repo profile"
    local house_code_json house_code_private live_private_dce repo_json_dce
    repo_json_dce="$("$GH" api "repos/$REPO_SLUG" 2>/dev/null || echo '{}')"
    live_private_dce="$(printf '%s' "$repo_json_dce" | jq -r '.private // false' 2>/dev/null)"
    house_code_json="$(fetch_repo_file "$REPO_SLUG" ".house-code.json" || true)"
    house_code_private="null"
    if [[ -n "$house_code_json" ]]; then
        # `//` treats a JSON `false` as falsy too — a plain `.private_repo //
        # "null"` would wrongly collapse a DECLARED false to the "not
        # declared" sentinel, so the null-check is explicit here (same trap,
        # same fix, as REPO_DECLARED_PRIVATE above).
        house_code_private="$(printf '%s' "$house_code_json" | jq -r \
            '.private_repo as $v | if $v == null then "null" else ($v | tostring) end' 2>/dev/null || echo null)"
    fi
    if [[ "$REPO_DECLARED_PRIVATE" == "null" ]]; then
        if [[ "$house_code_private" != "true" && "$live_private_dce" == "false" ]]; then
            note_ok "private-repo-profile" "plain public repo (nothing declared)"
        else
            note_skip "private-repo-profile" "no declared .repos[\"$REPO_SLUG\"].private_repo — cannot 3-way-verify a non-default state"
        fi
    else
        local pr_mismatch=()
        [[ "$house_code_private" != "null" && "$house_code_private" != "$REPO_DECLARED_PRIVATE" ]] && pr_mismatch+=("house-code.json=$house_code_private")
        [[ "$live_private_dce" != "$REPO_DECLARED_PRIVATE" ]] && pr_mismatch+=("live=$live_private_dce")
        if [[ ${#pr_mismatch[@]} -eq 0 ]]; then
            note_ok "private-repo-profile" "declared=$REPO_DECLARED_PRIVATE, agrees with house-code.json and live"
        else
            note_drift "private-repo-profile" "declared=$REPO_DECLARED_PRIVATE, mismatch: ${pr_mismatch[*]}" "all three agree"
        fi
    fi

    # --- Forked scripts ------------------------------------------------------
    hdr "Forked scripts"
    # (a) check-plugin-version.sh — a repo carrying its own copy under
    # .github/ is compared byte-for-byte against core-skills' canonical copy.
    local cpv_local cpv_canonical
    cpv_local="$(fetch_repo_file "$REPO_SLUG" ".github/check-plugin-version.sh" || true)"
    if [[ -z "$cpv_local" ]]; then
        note_skip "check-plugin-version-fork" "no local copy under .github/ — not a consumer of this pattern"
    else
        cpv_canonical="$(fetch_repo_file "$CORE_SKILLS_SLUG" ".github/check-plugin-version.sh" || true)"
        if [[ -z "$cpv_canonical" ]]; then
            note_skip "check-plugin-version-fork" "core-skills' canonical copy unreadable — cannot compare"
        elif [[ "$cpv_local" == "$cpv_canonical" ]]; then
            note_ok "check-plugin-version-fork" "byte-identical to core-skills' canonical copy"
        else
            note_drift "check-plugin-version-fork" "local copy diverges from core-skills' canonical copy" \
                "byte-identical (or repoint to the shared copy)"
        fi
    fi
    # (b) setup-gitleaks composite pin — DRIFT if a consumer pins a ref older
    # than dotty's current release.
    local sg_ref
    sg_ref="$(extract_uses_ref "$CI_YML_CONTENT$GATE_YML_CONTENT" 'setup-gitleaks')"
    if [[ -z "$sg_ref" ]]; then
        note_skip "setup-gitleaks-pin" "does not pin dotty's setup-gitleaks composite"
    else
        local sg_latest sg_cmp sg_status
        sg_latest="$(dotty_latest_tag)"
        if [[ -z "$sg_latest" ]]; then
            note_skip "setup-gitleaks-pin" "dotty's tag list unreadable — cannot compare"
        elif [[ "$sg_ref" == "$sg_latest" ]]; then
            note_ok "setup-gitleaks-pin" "$sg_ref (current)"
        else
            sg_cmp="$("$GH" api "repos/$DOTTY_UPSTREAM_SLUG/compare/$sg_ref...$sg_latest" 2>/dev/null || echo '{}')"
            sg_status="$(printf '%s' "$sg_cmp" | jq -r '.status // empty' 2>/dev/null)"
            case "$sg_status" in
                identical) note_ok "setup-gitleaks-pin" "$sg_ref (current, same commit as $sg_latest)" ;;
                ahead)     note_drift "setup-gitleaks-pin" "$sg_ref" "dotty's current ($sg_latest) — pin lags" ;;
                behind)    note_ok "setup-gitleaks-pin" "$sg_ref (newer than $sg_latest)" ;;
                *)         note_skip "setup-gitleaks-pin" "cannot verify $sg_ref against dotty's current ($sg_latest)" ;;
            esac
        fi
    fi
    # (c) gitleaks-scan-present vs gitleaks-composite — REPORTS the shape;
    # a vendor action or a hand-rolled scan is the operator's own call, never
    # ruled DRIFT unilaterally here.
    local scan_blob
    scan_blob="$(printf '%s\n%s' "$CI_YML_CONTENT" "$GATE_YML_CONTENT")"
    if printf '%s' "$scan_blob" | grep -qiE "dotty/\.github/actions/(setup-gitleaks|gitleaks)"; then
        note_ok "gitleaks-scan-present" "shared composite in use"
    elif printf '%s' "$scan_blob" | grep -qi "gitleaks/gitleaks-action"; then
        note_skip "gitleaks-scan-present" "vendor action (gitleaks/gitleaks-action) in use — operator call, not unilateral drift"
    elif printf '%s' "$scan_blob" | grep -qiE "gitleaks (detect|dir)"; then
        note_skip "gitleaks-scan-present" "hand-rolled scan invocation — operator call, not unilateral drift"
    else
        note_skip "gitleaks-scan-present" "no PR-range scan detected in ci.yml/gate.yml (local-hook-only posture — operator call)"
    fi

    # --- Admin-exception-reason ("admin exceptions carry a reason") --------
    hdr "Admin exceptions"
    if [[ "$REPO_ADMIN_EXCEPTIONS" == "null" ]]; then
        note_skip "admin-exception-reason" "no admin exceptions declared for this repo"
    else
        local exc_count bad_count
        exc_count="$(printf '%s' "$REPO_ADMIN_EXCEPTIONS" | jq 'length')"
        if [[ "$exc_count" -eq 0 ]]; then
            note_ok "admin-exception-reason" "no exceptions declared"
        else
            bad_count="$(printf '%s' "$REPO_ADMIN_EXCEPTIONS" | jq '[.[] | select((.reason // "") | length == 0)] | length')"
            if [[ "$bad_count" -eq 0 ]]; then
                note_ok "admin-exception-reason" "$exc_count exception(s), each carries a reason"
            else
                local bad_names
                bad_names="$(printf '%s' "$REPO_ADMIN_EXCEPTIONS" | jq -r '[.[] | select((.reason // "") | length == 0) | .flag] | join(",")')"
                note_drift "admin-exception-reason" "missing reason: $bad_names" \
                    "every declared exception carries a non-empty reason"
            fi
        fi
    fi

    # --- CODEOWNERS policy ---------------------------------------------------
    # Topic-5 decision: every gate-weakening / behavior-changing file class is
    # OWNED per-repo. Each repo's CODEOWNERS already implements this as
    # `* <default owner>` (everything owned) MINUS an explicit ownerless
    # appendix of paths deliberately freed. So the drift check is NOT "does each
    # class have an owner" (they do, via `*`); it is: the default owner is
    # present on the `*` line, AND no ownerless (appendix) pattern frees a path
    # the policy keeps owned — every live ownerless pattern must be in the
    # repo's declared allow-list. One-directional: a declared appendix pattern
    # ABSENT from the live file is not drift (that path is then owned — stricter,
    # safe). Owned-ness is decided by the presence of an @-token (user, team, or
    # email) on the line, which sidesteps CODEOWNERS' backslash-escaped spaces
    # in paths (awk field-splitting would break on `/UX\ Bugs/...`). Reads
    # .github/CODEOWNERS via the contents API — App-safe.
    hdr "CODEOWNERS policy"
    if [[ "$CODEOWNERS_DEFAULT_OWNER" == "null" ]]; then
        note_skip "codeowners-policy" "no .codeowners_default_owner declared — CODEOWNERS not audited"
    elif [[ "$REPO_CODEOWNERS_APPENDIX" == "null" ]]; then
        note_skip "codeowners-policy" "no .repos[\"$REPO_SLUG\"].codeowners_appendix declared — not audited for this repo"
    else
        local codeowners_content co_has_default co_undeclared co_line co_trim
        codeowners_content="$(fetch_repo_file "$REPO_SLUG" ".github/CODEOWNERS" || true)"
        if [[ -z "$codeowners_content" ]]; then
            note_drift "codeowners-policy" "no .github/CODEOWNERS file" \
                "a CODEOWNERS with '* $CODEOWNERS_DEFAULT_OWNER' as the default owner"
        else
            # Default-owner line: a `*` pattern whose owner list includes the
            # declared owner. The `*` line carries no escaped spaces, so awk
            # field-splitting is safe here.
            co_has_default="$(printf '%s\n' "$codeowners_content" | awk -v o="$CODEOWNERS_DEFAULT_OWNER" '
                /^[[:space:]]*#/ { next }
                { if ($1 == "*") { for (i = 2; i <= NF; i++) if ($i == o) f = 1 } }
                END { if (f) print "yes" }')"
            if [[ "$co_has_default" != "yes" ]]; then
                note_drift "codeowners-policy" "default-owner line '* $CODEOWNERS_DEFAULT_OWNER' missing" \
                    "the default owner owns every path not in the appendix"
            else
                # Every live ownerless pattern (a non-comment line with no
                # @-token) must be in the declared appendix; an undeclared one
                # frees an owned path — the core drift this class guards.
                co_undeclared=""
                while IFS= read -r co_line; do
                    co_trim="$(printf '%s' "$co_line" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')"
                    [[ -n "$co_trim" ]] || continue
                    case "$co_trim" in \#*) continue ;; esac
                    if printf '%s' "$co_trim" | grep -q '@'; then continue; fi
                    if ! printf '%s' "$REPO_CODEOWNERS_APPENDIX" | jq -e --arg p "$co_trim" 'index($p) != null' >/dev/null 2>&1; then
                        co_undeclared="$co_undeclared $co_trim"
                    fi
                done < <(printf '%s\n' "$codeowners_content")
                co_undeclared="${co_undeclared# }"
                if [[ -z "$co_undeclared" ]]; then
                    note_ok "codeowners-policy" "default owner present; every ownerless pattern is in the declared appendix"
                else
                    note_drift "codeowners-policy" "undeclared unowned pattern(s): $co_undeclared" \
                        "every ownerless pattern in the declared appendix (an undeclared one frees an owned path)"
                fi
            fi
        fi
    fi

    # --- S2: env+secret freshness -------------------------------------------
    # Full three-way freshness (secret rotated after the last local rules
    # install) needs a local-machine timestamp that is meaningless run from an
    # arbitrary CI/App context — scoped down to presence-only; see the PR body
    # for this judgment call. Currently 403s under the App token (Environments/
    # Secrets:read pending) — reports the scope gap, never false-clean.
    hdr "Environment + secret presence (S2)"
    local env_json secrets_json
    # Clean fallback: on a 403 `gh api` writes the error BODY to stdout AND
    # exits non-zero, so `"$(cmd || echo null)"` would capture "{…403…}null" —
    # never == "null". Capture, then override on failure so the fallback is
    # clean, and gate readability on the EXPECTED SHAPE (not == null): the env
    # object has .name; the secrets response has a .secrets array. Absent shape
    # (a 403 error object, or the fallback) -> SKIP "not readable", never a
    # false-DRIFT. Under a full-scope token both shapes are present and the real
    # OPERATOR_RULES state is reported below.
    env_json="$("$GH" api "repos/$REPO_SLUG/environments/default-branch" 2>/dev/null)" || env_json='{}'
    secrets_json="$("$GH" api "repos/$REPO_SLUG/actions/secrets" 2>/dev/null)" || secrets_json='{}'
    if ! printf '%s' "$env_json" | jq -e 'has("name")' >/dev/null 2>&1 \
       || ! printf '%s' "$secrets_json" | jq -e '(.secrets | type) == "array"' >/dev/null 2>&1; then
        note_skip "env-secret-freshness" "not readable under current scope (Environments/Secrets:read grant pending)"
    else
        if printf '%s' "$secrets_json" | jq -e '.secrets[]? | select(.name=="OPERATOR_RULES")' >/dev/null 2>&1; then
            note_ok "env-secret-freshness" "default-branch environment + OPERATOR_RULES secret present"
        else
            note_drift "env-secret-freshness" "OPERATOR_RULES secret absent from repo secrets" \
                "present on the default-branch environment"
        fi
    fi

    # --- S2: Actions-approve-off ---------------------------------------------
    # Currently 403s under the App token (Administration:read pending).
    hdr "Actions approve-PR permission (S2)"
    local actions_perm_json
    # Clean fallback + shape gate (same 403-body-on-stdout reasoning as above):
    # readable iff the response carries .can_approve_pull_request_reviews.
    actions_perm_json="$("$GH" api "repos/$REPO_SLUG/actions/permissions/workflow" 2>/dev/null)" || actions_perm_json='{}'
    if ! printf '%s' "$actions_perm_json" | jq -e 'has("can_approve_pull_request_reviews")' >/dev/null 2>&1; then
        note_skip "actions-approve-off" "not readable under current scope (Administration:read grant pending)"
    else
        local can_approve
        can_approve="$(printf '%s' "$actions_perm_json" | jq -r '.can_approve_pull_request_reviews // false')"
        if [[ "$can_approve" == "false" ]]; then
            note_ok "actions-approve-off" "can_approve_pull_request_reviews=false"
        else
            note_drift "actions-approve-off" "can_approve_pull_request_reviews=true" \
                "off (Actions must never approve its own PRs)"
        fi
    fi

    # --- S2: deploy-key inventory --------------------------------------------
    # Currently 403s under the App token (Administration:read pending).
    hdr "Deploy-key inventory (S2)"
    local keys_json
    # Clean fallback + shape gate: the keys endpoint returns a JSON ARRAY when
    # readable. A 403 error object is NOT an array — `jq 'length'` on it would
    # (falsely) count its keys (message/documentation_url/status = 2+), so the
    # == null guard alone let a 403 masquerade as "keys present". Gate on the
    # array shape -> SKIP "not readable", never a false key count.
    keys_json="$("$GH" api "repos/$REPO_SLUG/keys" 2>/dev/null)" || keys_json='{}'
    if ! printf '%s' "$keys_json" | jq -e 'type == "array"' >/dev/null 2>&1; then
        note_skip "deploy-key-inventory" "not readable under current scope (Administration:read grant pending)"
    else
        local key_count
        key_count="$(printf '%s' "$keys_json" | jq 'length' 2>/dev/null || echo 0)"
        if [[ "$key_count" -eq 0 ]]; then
            note_ok "deploy-key-inventory" "no deploy keys"
        elif [[ "$REPO_DEPLOY_KEYS_ALLOW" == "null" ]]; then
            note_skip "deploy-key-inventory" "$key_count deploy key(s) present but no declared allow-set to verify against"
        else
            local undeclared
            undeclared="$(printf '%s' "$keys_json" | jq -r --argjson allow "$REPO_DEPLOY_KEYS_ALLOW" \
                '[.[] | select((.title // "") as $t | ($allow | index($t)) == null) | .title] | join(",")')"
            if [[ -z "$undeclared" ]]; then
                note_ok "deploy-key-inventory" "$key_count deploy key(s), all in the declared allow-set"
            else
                note_drift "deploy-key-inventory" "undeclared key(s): $undeclared" \
                    "every deploy key in the declared allow-set"
            fi
        fi
    fi
}

# ----------------------------------------------------------------------------
# Dispatch — local steps first (per spec order + fail-closed before any remote
# work), then remote, then the drift-check-only classes.
# ----------------------------------------------------------------------------
if [[ -n "$LOCAL_PATH" ]]; then
    process_local "$LOCAL_PATH"
fi
process_remote
drift_check_extras

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
