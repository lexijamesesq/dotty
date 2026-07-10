#!/usr/bin/env bash
#
# provision-public-repo.sh — idempotently wire a public GitHub repo to this
# estate's publishing conventions, or (with --check) report drift and mutate
# nothing.
#
#     provision-public-repo.sh [--check] [--rules <path>] <owner/repo> [local-path]
#
# WHY THIS EXISTS
# ---------------
# Wiring a public repo used to be a remembered checklist. A skipped step is a
# SILENT TIER DOWNGRADE — the repo looks protected and isn't. This makes the
# wiring *run* rather than be *remembered*, and --check makes a downgrade
# visible instead of assumed-away.
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
#       2. GitHub secret-scanning push protection (server-side). This script
#          only VERIFIES it is enabled; enabling it is done out of band.
#
# RULE OWNERSHIP — CONVERGED vs PRESERVED
# ---------------------------------------
# The ruleset step distinguishes rules this tool OWNS from rules it does not:
#
#   * OWNED (converged to intent): non_fast_forward, deletion, pull_request.
#     These three are the reason this script touches rulesets at all, so their
#     presence AND parameters are driven to intent. In particular pull_request
#     is forced to required_approving_review_count = 0 — a solo operator cannot
#     approve their own PR, so any nonzero count makes merging impossible, a
#     silent and total downgrade of the publishing workflow. The other owned
#     pull_request flags are set false. Any EXTRA parameters GitHub attaches to
#     the pull_request rule (e.g. allowed_merge_methods) are left intact — this
#     tool owns its five parameters, not the whole object.
#   * PRESERVED (byte-for-byte): every other rule a repo declares for itself —
#     required_status_checks (a CI gate) and anything else — is passed through
#     untouched, as are the ruleset's conditions and bypass_actors.
#
# RULESET PATH — RESOLVED, NOT CONFIGURED
# ---------------------------------------
# The operator gitleaks ruleset lives in a private location that this PUBLIC
# file must never name. Success must not depend on the operator remembering to
# export an environment variable in two places. Resolution order, first hit wins:
#   1. --rules <path>                              (explicit per-run override)
#   2. <this script's dir>/.gitleaks-operator-rules.toml  — the gitignored
#      symlink setup-claude-profiles.sh creates in this repo. The normal path;
#      nothing to configure. The symlink is followed to its real target.
#   3. $GITLEAKS_OPERATOR_RULES                    (override for an unprovisioned
#      machine that lacks the symlink; never a requirement)
#   4. else fail closed, naming all three and that setup-claude-profiles.sh
#      creates the symlink.
# The private path appears only inside the gitignored symlink, never here.
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
while [[ $# -gt 0 ]]; do
    case "$1" in
        --check)     MODE=check; shift ;;
        --rules)     RULES_FLAG="${2:-}"; [[ -n "$RULES_FLAG" ]] || { echo "FATAL: --rules requires a path" >&2; exit 2; }; shift 2 ;;
        --rules=*)   RULES_FLAG="${1#--rules=}"; shift ;;
        --)          shift; break ;;
        -*)          echo "FATAL: unknown option '$1'" >&2; exit 2 ;;
        *)           break ;;
    esac
done

REPO_SLUG="${1:-}"
LOCAL_PATH="${2:-}"

if [[ -z "$REPO_SLUG" ]]; then
    echo "usage: provision-public-repo.sh [--check] [--rules <path>] <owner/repo> [local-path]" >&2
    exit 2
fi
if [[ "$REPO_SLUG" != */* || "$REPO_SLUG" == */*/* ]]; then
    echo "FATAL: '<owner/repo>' must be exactly owner/repo (got '$REPO_SLUG')" >&2
    exit 2
fi

GH="${GH:-gh}"
DRIFT_COUNT=0

# This script's own directory, and the gitignored operator-rules symlink beside
# it (resolution path 2). Derived from BASH_SOURCE — no configuration needed.
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
REPO_RULES_SYMLINK="$SELF_DIR/.gitleaks-operator-rules.toml"

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
# Helpers
# ----------------------------------------------------------------------------
hdr()       { printf '\n== %s ==\n' "$1"; }
note_ok()   { printf '  OK    %s = %s\n' "$1" "$2"; }
note_drift(){ printf '  DRIFT %s = %s (intended %s)\n' "$1" "$2" "$3"; DRIFT_COUNT=$((DRIFT_COUNT + 1)); }
note_conv() { printf '  DRIFT %s = %s (intended %s) — converging\n' "$1" "$2" "$3"; }
note_fixed(){ printf '  FIXED %s -> %s\n' "$1" "$2"; }

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

# resolve_real <path> — print the absolute real path, following symlinks.
# Portable across GNU + BSD: realpath, then readlink -f, then a single-hop
# fallback that absolutizes a relative link target.
resolve_real() {
    local p="$1" t
    if command -v realpath >/dev/null 2>&1 && t="$(realpath "$p" 2>/dev/null)"; then
        printf '%s' "$t"; return 0
    fi
    if t="$(readlink -f "$p" 2>/dev/null)" && [[ -n "$t" ]]; then
        printf '%s' "$t"; return 0
    fi
    if t="$(readlink "$p" 2>/dev/null)" && [[ -n "$t" ]]; then
        case "$t" in
            /*) printf '%s' "$t" ;;
            *)  printf '%s' "$(cd "$(dirname "$p")" >/dev/null 2>&1 && pwd)/$t" ;;
        esac
        return 0
    fi
    printf '%s' "$p"
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

    # --- Step 1: operator-rules symlink -----------------------------------
    # Resolve the ruleset path (see header § RULESET PATH). rules_target is NEVER
    # printed — it may be the private ruleset's real path; only rules_src is.
    local rules_target="" rules_src="" candidate=""
    if [[ -n "$RULES_FLAG" ]]; then
        candidate="$(expand_tilde "$RULES_FLAG")"
        if [[ ! -r "$candidate" ]]; then
            echo "FATAL [operator-rules]: --rules path is not readable: $candidate" >&2
            exit 1
        fi
        rules_target="$(resolve_real "$candidate")"
        rules_src="--rules"
    elif [[ -r "$REPO_RULES_SYMLINK" ]]; then
        rules_target="$(resolve_real "$REPO_RULES_SYMLINK")"
        rules_src="repo symlink"
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
        rules_target="$(resolve_real "$candidate")"
        rules_src="\$GITLEAKS_OPERATOR_RULES"
    else
        echo "FATAL [operator-rules]: cannot locate the operator gitleaks ruleset. Satisfy one:" >&2
        echo "  1. pass --rules <path>" >&2
        echo "  2. provision this repo so $REPO_RULES_SYMLINK exists and resolves" >&2
        echo "     (setup-claude-profiles.sh creates that gitignored symlink)" >&2
        echo "  3. set GITLEAKS_OPERATOR_RULES to a readable ruleset path" >&2
        exit 1
    fi

    local link="$path/.gitleaks-operator-rules.toml"
    if [[ -L "$link" || -e "$link" ]]; then
        note_ok "operator-rules-symlink" "present"
    elif [[ "$MODE" == converge ]]; then
        ln -sf "$rules_target" "$link"
        note_fixed "operator-rules-symlink" "created (source: $rules_src)"
    else
        note_drift "operator-rules-symlink" "absent" "symlink -> operator ruleset (source: $rules_src)"
    fi

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

    # --- Step 4b: stale-clone check (LEX-321 class) -------------------------
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
    # --- Repo object (one fetch: default branch + merge + security fields) --
    local repo_json default_branch
    repo_json="$(gh_call "repo-get" api "repos/$REPO_SLUG")"
    default_branch="$(printf '%s' "$repo_json" | jq -r '.default_branch // empty')"
    if [[ -z "$default_branch" ]]; then
        echo "FATAL [repo-get]: could not read .default_branch for $REPO_SLUG" >&2
        exit 1
    fi

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

    # --- Step 6: branch ruleset (own three rules; preserve the rest) ------
    hdr "Branch ruleset (target: $default_branch)"
    local rulesets_json matched_id="" matched_detail="" rid detail

    # The OWNED pull_request parameters. required_approving_review_count MUST be
    # 0 — a solo operator cannot approve their own PR, so any higher value makes
    # merging impossible for a one-person estate.
    local pr_params='{
        "required_approving_review_count": 0,
        "dismiss_stale_reviews_on_push": false,
        "require_code_owner_review": false,
        "require_last_push_approval": false,
        "required_review_thread_resolution": false
    }'

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
            jq -n --argjson pp "$pr_params" '{
                name: "Protect default branch",
                target: "branch",
                enforcement: "active",
                bypass_actors: [],
                conditions: { ref_name: { include: ["~DEFAULT_BRANCH"], exclude: [] } },
                rules: [ {type:"non_fast_forward"}, {type:"deletion"}, {type:"pull_request", parameters:$pp} ]
            }' | gh_call "ruleset-create" api "repos/$REPO_SLUG/rulesets" --method POST --input - >/dev/null
            note_fixed "ruleset" "created 'Protect default branch' (active, targets ~DEFAULT_BRANCH)"
        else
            note_drift "ruleset" "none targets refs/heads/$default_branch" \
                "active ruleset w/ non_fast_forward, deletion, pull_request"
        fi
    else
        local ruleset_needs_put=0 rt enf cur_count

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

        # pull_request: presence AND owned-parameter convergence. The owned
        # params are a SUBSET of the rule's parameters — extra keys GitHub
        # attaches are ignored for drift (so a fully-wired repo stays a no-op)
        # but preserved on write.
        if ! printf '%s' "$matched_detail" | jq -e '(.rules // []) | any(.type == "pull_request")' >/dev/null; then
            if [[ "$MODE" == converge ]]; then
                note_conv "rule.pull_request" "absent" "present, review_count=0"
                ruleset_needs_put=1
            else
                note_drift "rule.pull_request" "absent" "present, review_count=0"
            fi
        else
            cur_count="$(printf '%s' "$matched_detail" | jq -r \
                '(.rules // []) | map(select(.type=="pull_request"))[0].parameters.required_approving_review_count // "unset"')"
            if printf '%s' "$matched_detail" | jq -e --argjson want "$pr_params" '
                    ((.rules // []) | map(select(.type=="pull_request"))) as $prs
                    | ($prs[0].parameters // {}) as $p
                    | ($want | to_entries | all(.value == ($p[.key])))
                ' >/dev/null; then
                note_ok "rule.pull_request" "present, review_count=$cur_count"
            elif [[ "$MODE" == converge ]]; then
                note_conv "rule.pull_request" "review_count=$cur_count" "review_count=0 (+owned flags false)"
                ruleset_needs_put=1
            else
                note_drift "rule.pull_request" "review_count=$cur_count" "review_count=0 (+owned flags false)"
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
            # Converge the three owned rules to intent; preserve everything else
            # byte-for-byte. An existing pull_request rule keeps its extra params
            # and gets the owned five forced; required_status_checks and any
            # other rule pass through verbatim; conditions + bypass_actors are
            # preserved exactly; enforcement is forced active.
            printf '%s' "$matched_detail" | jq --argjson pp "$pr_params" '
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
                            else .
                            end
                        ))
                        + (if ($t | index("non_fast_forward")) then [] else [{type:"non_fast_forward"}] end)
                        + (if ($t | index("deletion"))        then [] else [{type:"deletion"}]        end)
                        + (if ($t | index("pull_request"))    then [] else [{type:"pull_request", parameters:$pp}] end)
                    )
                }
            ' | gh_call "ruleset-update" api "repos/$REPO_SLUG/rulesets/$matched_id" --method PUT --input - >/dev/null
            note_fixed "ruleset" "patched id $matched_id (owned rules converged; other rules, conditions, bypass_actors preserved)"
        fi
    fi

    # --- Step 7: secret scanning + push protection (verify; enable if off) -
    hdr "Secret scanning"
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
