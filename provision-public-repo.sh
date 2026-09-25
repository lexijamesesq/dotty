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
#   2. the FIXED install path (gl_overlay_path in git-hooks/gitleaks-
#      common.sh: ${XDG_CONFIG_HOME:-$HOME/.config}/gitleaks/operator-rules.toml)
#      — installed by the blueprint's gitleaks-rules slice (`apply`). The
#      normal path; nothing to configure per repo. There is no per-repo symlink
#      to create — every repo's tracked .gitleaks.toml carries a relative
#      [extend] token that gl_resolve resolves against this fixed path at
#      hook-run time, by running gitleaks from a resolution directory holding
#      that name — never by rewriting the repo's config.
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
# here; the one place the estate writes one is new-repo.sh's seed, and only
# on a brand-new repository whose default branch is still empty — a repo with
# history keeps this stance unchanged). Every gh call goes through $GH
# (defaults to `gh`) so a test can stub it.

set -euo pipefail

# ----------------------------------------------------------------------------
# Arg parsing
# ----------------------------------------------------------------------------
MODE=converge
RULES_FLAG=""
DECLARED_JSON_FLAG=""
while [[ $# -gt 0 ]]; do
	case "$1" in
	--check)
		MODE=check
		shift
		;;
	# A THIRD mode, deliberately not a converge sub-step. Converge writes
	# rulesets; this writes repo CONTENT (caller workflows, renovate.json,
	# the PR template) and nothing else, and the two must never be one
	# keystroke.
	--callers)
		MODE=callers
		shift
		;;
	--rules)
		RULES_FLAG="${2:-}"
		[[ -n "$RULES_FLAG" ]] || {
			echo "FATAL: --rules requires a path" >&2
			exit 2
		}
		shift 2
		;;
	--rules=*)
		RULES_FLAG="${1#--rules=}"
		shift
		;;
	--declared-json)
		DECLARED_JSON_FLAG="${2:-}"
		[[ -n "$DECLARED_JSON_FLAG" ]] || {
			echo "FATAL: --declared-json requires a path" >&2
			exit 2
		}
		shift 2
		;;
	--declared-json=*)
		DECLARED_JSON_FLAG="${1#--declared-json=}"
		shift
		;;
	--)
		shift
		break
		;;
	-*)
		echo "FATAL: unknown option '$1'" >&2
		exit 2
		;;
	*) break ;;
	esac
done

REPO_SLUG="${1:-}"
LOCAL_PATH="${2:-}"

if [[ -z "$REPO_SLUG" ]]; then
	echo "usage: provision-public-repo.sh [--check|--callers] [--rules <path>] [--declared-json <path>] <owner/repo> [local-path]" >&2
	exit 2
fi
if [[ "$REPO_SLUG" != */* || "$REPO_SLUG" == */*/* ]]; then
	echo "FATAL: '<owner/repo>' must be exactly owner/repo (got '$REPO_SLUG')" >&2
	exit 2
fi

GH="${GH:-gh}"
DRIFT_COUNT=0
SCRIPT_SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# The CODEOWNERS coverage matcher (§ codeowners-policy in drift_check_extras).
CODEOWNERS_DRIFT_PY="$SCRIPT_SELF_DIR/.github/scripts/codeowners-drift.py"
# The by-line/additive .pre-commit-config.yaml merger (§ CALLER OWNERSHIP).
PCC_MERGE_PY="$SCRIPT_SELF_DIR/.github/scripts/pre-commit-suite-merge.py"

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
[[ "$PR_PARAMS" != "null" ]] || {
	echo "FATAL [declared-json]: '.pull_request' missing from $DECLARED_JSON_PATH" >&2
	exit 1
}
STRICT_WANT="$(printf '%s' "$DECLARED_JSON" | jq -r '.required_status_checks.strict_required_status_checks_policy')"
[[ "$STRICT_WANT" == "true" || "$STRICT_WANT" == "false" ]] || {
	echo "FATAL [declared-json]: '.required_status_checks.strict_required_status_checks_policy' missing/invalid in $DECLARED_JSON_PATH" >&2
	exit 1
}
TAG_RULESET_NAME="$(printf '%s' "$DECLARED_JSON" | jq -r '.tag_ruleset.name')"
TAG_RULESET_RULES="$(printf '%s' "$DECLARED_JSON" | jq -c '.tag_ruleset.rules')"
[[ "$TAG_RULESET_NAME" != "null" && "$TAG_RULESET_RULES" != "null" ]] || {
	echo "FATAL [declared-json]: '.tag_ruleset' missing/invalid in $DECLARED_JSON_PATH" >&2
	exit 1
}

# § DRIFT-CHECK DECLARATIONS (--check only; the drift check holds every repo to
# the core — LEX rollout Step 9). Optional top-level keys, read once here:
#   .release_tag_authors : array of the login/name strings a tag from the
#     release path may carry as its annotated-tag tagger (dotty's
#     release-on-merge job, a plugin release-tag job). Tag origin has no ruleset enforcement
#     (tag creation is unrestricted, immutability-only) — so the drift check is
#     the enforcement surface: a lightweight tag, or an annotated tag whose
#     tagger is not in this set, is reported DRIFT. Absent -> the class reports
#     "not declared" (never false-clean), never silently passes.
RELEASE_TAG_AUTHORS="$(printf '%s' "$DECLARED_JSON" | jq -c '.release_tag_authors // null')"
if [[ "$RELEASE_TAG_AUTHORS" != "null" ]] && ! printf '%s' "$RELEASE_TAG_AUTHORS" | jq -e 'type == "array" and all(.[]; type == "string")' >/dev/null 2>&1; then
	echo "FATAL [declared-json]: '.release_tag_authors' must be an array of strings in $DECLARED_JSON_PATH" >&2
	exit 1
fi

#   .codeowners_owner : the single owner token every REQUIRED-OWNED path must
#     effectively resolve to in a repo's CODEOWNERS (§ codeowners-policy in
#     drift_check_extras below). The estate un-inverted CODEOWNERS: the model is
#     now default-UNOWNED + an owned allow-list (no `* <owner>` catch-all,
#     except a deliberately full-owned repo), so this key is the "owner of the
#     safety paths" half of that model. Absent -> the class reports "not
#     declared" (never false-clean). Explicit null-check (not `//`) so a
#     malformed non-string declaration FATALs rather than collapsing to "absent".
CODEOWNERS_OWNER="$(printf '%s' "$DECLARED_JSON" | jq -r '.codeowners_owner as $v | if $v == null then "null" else ($v | tostring) end')"
if [[ "$CODEOWNERS_OWNER" != "null" ]] && ! printf '%s' "$DECLARED_JSON" | jq -e '.codeowners_owner | type == "string"' >/dev/null 2>&1; then
	echo "FATAL [declared-json]: '.codeowners_owner' must be a string in $DECLARED_JSON_PATH" >&2
	exit 1
fi

#   .codeowners_required_owned : the SHARED owned pattern set every repo owns
#     where present (the intersection of the per-repo owned-sets — the CI/gate/
#     scan/policy floor: `/.github/workflows/`, `/.github/CODEOWNERS`,
#     `/.pre-commit-config.yaml`, `/.gitleaks.toml`). The check unions this with
#     the per-repo `.codeowners_owned` and resolves each against the repo's real
#     tree, so this global floor still holds even if a per-repo list drops one.
#     Absent -> "not declared" (never false-clean).
CODEOWNERS_REQUIRED_OWNED="$(printf '%s' "$DECLARED_JSON" | jq -c '.codeowners_required_owned // null')"
if [[ "$CODEOWNERS_REQUIRED_OWNED" != "null" ]] && ! printf '%s' "$CODEOWNERS_REQUIRED_OWNED" | jq -e 'type == "array" and all(.[]; type == "string")' >/dev/null 2>&1; then
	echo "FATAL [declared-json]: '.codeowners_required_owned' must be an array of strings in $DECLARED_JSON_PATH" >&2
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

# `.repos["<owner>/<repo>"].margot_enrolled` — whether Margot runs on this repo,
# the enrollment signal for the margot-caller and margot-app-key audits below.
# It used to be inferred from `margot` being in required_contexts, but the v3
# merge flip removed `margot` as a required check (it is no longer deadlock-
# forming), so enrollment needs its own explicit declaration or those two audits
# would silently skip every repo. Optional boolean, absent → false (not enrolled).
REPO_MARGOT_ENROLLED="$(printf '%s' "$DECLARED_JSON" | jq -r --arg repo "$REPO_SLUG" '.repos[$repo].margot_enrolled // false')"
if [[ "$REPO_MARGOT_ENROLLED" != "true" && "$REPO_MARGOT_ENROLLED" != "false" ]]; then
	echo "FATAL [declared-json]: '.repos[\"$REPO_SLUG\"].margot_enrolled' must be a boolean in $DECLARED_JSON_PATH" >&2
	exit 1
fi

# `.repos["<owner>/<repo>"].enforcement` — declared branch-ruleset enforcement,
# "active" | "evaluate". Absent → "active" (this tool's prior forced default, so
# existing repos are unchanged). "evaluate" lets a newly enrolled repo run its
# required checks visibly-but-non-blocking (rule insights, nothing blocked) until
# an acceptance run flips one field to "active". Anti-lockout layer 2 (the review dead-man slice).
REPO_DECLARED_ENFORCEMENT="$(printf '%s' "$DECLARED_JSON" | jq -r --arg repo "$REPO_SLUG" '.repos[$repo].enforcement // "active"')"
if [[ "$REPO_DECLARED_ENFORCEMENT" != "active" && "$REPO_DECLARED_ENFORCEMENT" != "evaluate" ]]; then
	echo "FATAL [declared-json]: '.repos[\"$REPO_SLUG\"].enforcement' must be \"active\" or \"evaluate\" in $DECLARED_JSON_PATH" >&2
	exit 1
fi

# Branch-ruleset bypass actors — declared in TWO places whose UNION is what this
# tool writes:
#   • `.branch_rulesets[].bypass_actors`         — PER DECLARED RULESET, and the
#     reason the top-level `.bypass_actors` key that used to sit here is gone: a
#     bypass actor waives every rule in the ruleset carrying it, so one estate-wide
#     list could not give the dependency bot a review bypass without also waiving
#     the up-to-date requirement. The actor set is now a property of each half of
#     the split, not of the estate.
#   • `.repos["<owner>/<repo>"].bypass_actors`   — this repo gets these as well,
#     unioned onto EVERY declared ruleset.
# Neither declared → PRESERVE whatever the live ruleset carries (unchanged
# behavior; a repo that never declares them keeps any operator-set actors).
# Either declared → this tool OWNS the field: the union is written and --check
# drifts on it.
#
# UNION, not override, and the failure that picked it: the estate's two actors
# serve two different lanes, and an override would let a per-repo line silently
# drop one of them. Every live branch ruleset already carries the admin actor
# (read across all thirteen on 2026-09-17), so a per-repo list written for the
# bot lane alone would have converged the anti-lockout actor away on that repo.
# The union is deduplicated on the whole object, so declaring an actor in both
# places is a no-op rather than a doubled entry.
#
# The two actors and the failure each answers:
#   • RepositoryRole 5 (repo Admin), pull_request — anti-lockout layer 1: rulesets
#     do not exempt admins, so a structurally dead required check would otherwise
#     block every PR including its own fix. Declared on BOTH halves of the split;
#     the admin is the only actor the checks half admits at all.
#   • Integration 4984137 (Ollie — The Intern, the App the self-hosted Renovate
#     engine runs as), pull_request — declared on the REVIEW half only. Every
#     default-branch ruleset sets require_code_owner_review, and CODEOWNERS names
#     only a human, so a dependency-bump PR can never collect that review and
#     would sit forever. Bypassing review is all it needs: on the checks half it
#     holds no bypass, so its own PRs stay fully subject to the required contexts
#     and to strict_required_status_checks_policy. Renovate rebases its branches
#     (rebaseWhen: "behind-base-branch") rather than merging behind base.
#     This replaced Integration 2740, the hosted Mend Renovate app, which was
#     uninstalled when the engine moved in-house. Ollie therefore authors a
#     dependency bump and merges it — the safeguard is not a separate merging
#     identity but that its Renovate token holds Checks READ and no
#     Administration, and that every required context is bound to its reporting
#     App by integration_id, so Ollie cannot satisfy one it did not earn.
#
# An earlier version of this comment claimed GitHub rejects App/Integration
# bypass actors on personal-account repos and that RepositoryRole was the only
# accepted type here. That claim shipped with no receipt and is FALSE. Receipt,
# 2026-09-17: POST /repos/lexijamesesq/probe-local-to-merged/rulesets with
# `bypass_actors: [{actor_type: "Integration", actor_id: 4984137, bypass_mode:
# "pull_request"}]` was accepted (ruleset 23630828, created with enforcement
# "disabled" over a nonexistent ref so it gated nothing), read back byte-identical,
# and deleted (204). GitHub's REST reference names `Integration` in the actor_type
# enum and marks only `OrganizationAdmin` as inapplicable to personal repositories;
# for `Integration` the actor_id is the App's own id (`GET /apps/ollie-the-intern`
# → `id: 4984137`), the same id space the required-status-checks rule already uses
# for `integration_id`.
#
# `actor_id` is the App id, NOT an installation id: the App must still be installed
# on the repo for the bypass to do anything, but the id written here is
# installation-independent, so the same declaration is correct for all of them.
# `.branch_rulesets` — the declared default-branch rulesets, one object per
# ruleset: {name, rules[], bypass_actors[]}. TWO of them by design.
#
# The receipt, and why this is not one ruleset with one bypass list: a bypass
# actor on a ruleset bypasses EVERY rule in it, `strict_required_status_checks_policy`
# included. While review and checks lived in one object, granting the dependency
# bot a review bypass also let it merge a branch behind its base — the retired
# merge script hand-rolled a `behind_by == 0` check for exactly that, and
# Renovate has no merge-time equivalent. GitHub applies every ruleset targeting a
# branch and scopes bypass per ruleset, so splitting them is the fix, in config
# rather than in code.
DECLARED_BRANCH_RULESETS="$(printf '%s' "$DECLARED_JSON" | jq -c '.branch_rulesets // null')"
if [[ "$DECLARED_BRANCH_RULESETS" == "null" ]] || ! printf '%s' "$DECLARED_BRANCH_RULESETS" | jq -e '
        type == "array" and length > 0
        and all(.[]; type == "object" and has("name") and has("rules")
                     and (.rules | type == "array" and length > 0)
                     and ((.bypass_actors // []) | type == "array"
                          and all(.[]; type == "object" and has("actor_type") and has("bypass_mode"))))
    ' >/dev/null 2>&1; then
	echo "FATAL [declared-json]: '.branch_rulesets' must be a non-empty array of {name, rules[], bypass_actors[]} objects in $DECLARED_JSON_PATH" >&2
	exit 1
fi
# Names are how each ruleset is DISCOVERED, so a duplicate name is a declaration
# that cannot be converged.
if [[ "$(printf '%s' "$DECLARED_BRANCH_RULESETS" | jq -r '[.[].name] | length')" != "$(printf '%s' "$DECLARED_BRANCH_RULESETS" | jq -r '[.[].name] | unique | length')" ]]; then
	echo "FATAL [declared-json]: '.branch_rulesets' names must be unique in $DECLARED_JSON_PATH" >&2
	exit 1
fi

REPO_ONLY_DECLARED_BYPASS="$(printf '%s' "$DECLARED_JSON" | jq -c --arg repo "$REPO_SLUG" '.repos[$repo].bypass_actors // null')"
if [[ "$REPO_ONLY_DECLARED_BYPASS" != "null" ]] && ! printf '%s' "$REPO_ONLY_DECLARED_BYPASS" | jq -e 'type == "array" and all(.[]; type == "object" and has("actor_type") and has("bypass_mode"))' >/dev/null 2>&1; then
	echo "FATAL [declared-json]: '.repos[\"$REPO_SLUG\"].bypass_actors' must be an array of {actor_type, actor_id, bypass_mode} objects in $DECLARED_JSON_PATH" >&2
	exit 1
fi

# `.dependency_bot_authors` — the estate's declared dependency-bot logins, the ONE
# place the list lives. Read by estate-margot.yml's bot path (both the `margot`
# skip check and the autonomous merge preconditions), so the check that is posted
# and the merge that follows can never disagree about who a dependency bot is. A
# LIST, not a literal: the pre-commit `rev:` channel is expected to add a second
# bot author, and a literal would have to be edited in several workflow steps.
# Validated here so a malformed list fails the provisioner rather than silently
# widening or emptying the bot path at runtime.
DECLARED_BOT_AUTHORS="$(printf '%s' "$DECLARED_JSON" | jq -c '.dependency_bot_authors // null')"
if [[ "$DECLARED_BOT_AUTHORS" != "null" ]] && ! printf '%s' "$DECLARED_BOT_AUTHORS" | jq -e 'type == "array" and length > 0 and all(.[]; type == "string" and length > 0)' >/dev/null 2>&1; then
	echo "FATAL [declared-json]: top-level '.dependency_bot_authors' must be a non-empty array of non-empty strings in $DECLARED_JSON_PATH" >&2
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

# `.repos["<owner>/<repo>"].tag_ruleset_exclude` — ref patterns this repo's tag
# immutability ruleset does NOT cover. PER-REPO, never estate-wide: it
# un-protects a tag, so it is granted to the one repo with a receipted need
# rather than to all fifteen.
#
# The receipted need is dotty's alone. release-on-merge cuts an immutable
# calendar tag AND moves a floating first-party major tag (`refs/tags/v1`) onto
# the same commit. Consumers pin their `uses:` at `@v1` — GitHub's own
# convention for same-owner actions — so one dotty release reaches all thirteen
# callers instead of fanning out into thirteen pin-bump PRs and thirteen CI
# runs. Moving a tag is an `update`, which this ruleset blocks with no bypass
# actor, so without this exclusion the v1 step fails on every release after the
# first.
#
# Exactly `refs/tags/v1`, not a `refs/tags/v[0-9]*` pattern: one tag moves, and
# a pattern would silently un-protect a v2 line nobody has decided on yet.
# Absent/[] keeps immutability over every tag — the default for every repo.
REPO_TAG_RULESET_EXCLUDE="$(printf '%s' "$DECLARED_JSON" | jq -c --arg repo "$REPO_SLUG" '.repos[$repo].tag_ruleset_exclude // []')"
if ! printf '%s' "$REPO_TAG_RULESET_EXCLUDE" | jq -e 'type == "array" and all(.[]; type == "string")' >/dev/null 2>&1; then
	echo "FATAL [declared-json]: '.repos[\"$REPO_SLUG\"].tag_ruleset_exclude' must be an array of strings in $DECLARED_JSON_PATH" >&2
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

# `.repos["<owner>/<repo>"].codeowners_owned` — this repo's OWNED allow-list:
# the patterns whose real files must effectively resolve to .codeowners_owner
# (§ codeowners-policy below). Unioned with the global .codeowners_required_owned
# and resolved against the repo's real tree by last-match-wins. `null` (not
# declared for this repo) means the class skips rather than guessing — UNLESS
# .codeowners_full_owned is true (a full-owned repo needs no per-repo list).
REPO_CODEOWNERS_OWNED="$(printf '%s' "$DECLARED_JSON" | jq -c --arg repo "$REPO_SLUG" '.repos[$repo].codeowners_owned // null')"
if [[ "$REPO_CODEOWNERS_OWNED" != "null" ]] && ! printf '%s' "$REPO_CODEOWNERS_OWNED" | jq -e 'type == "array" and all(.[]; type == "string")' >/dev/null 2>&1; then
	echo "FATAL [declared-json]: '.repos[\"$REPO_SLUG\"].codeowners_owned' must be an array of strings in $DECLARED_JSON_PATH" >&2
	exit 1
fi

# `.repos["<owner>/<repo>"].codeowners_full_owned` — true only for a repo kept
# deliberately FULLY OWNED (dotty-private, the crown-jewels repo): the check then
# REQUIRES the `* <owner>` catch-all present and every real path owned (its
# absence -> DRIFT). Absent/false -> the default-unowned model. Over-coverage (a
# catch-all in an ordinary repo) is always SAFE, so a repo NOT flagged full_owned
# that carries a catch-all still passes — it just isn't REQUIRED to.
REPO_CODEOWNERS_FULL_OWNED="$(printf '%s' "$DECLARED_JSON" | jq -r --arg repo "$REPO_SLUG" '.repos[$repo].codeowners_full_owned // false')"
if [[ "$REPO_CODEOWNERS_FULL_OWNED" != "true" && "$REPO_CODEOWNERS_FULL_OWNED" != "false" ]]; then
	echo "FATAL [declared-json]: '.repos[\"$REPO_SLUG\"].codeowners_full_owned' must be a boolean in $DECLARED_JSON_PATH" >&2
	exit 1
fi

# ----------------------------------------------------------------------------
# Helpers
# ----------------------------------------------------------------------------
hdr() { printf '\n== %s ==\n' "$1"; }
note_ok() { printf '  OK    %s = %s\n' "$1" "$2"; }
note_drift() {
	printf '  DRIFT %s = %s (intended %s)\n' "$1" "$2" "$3"
	DRIFT_COUNT=$((DRIFT_COUNT + 1))
}
note_conv() { printf '  DRIFT %s = %s (intended %s) — converging\n' "$1" "$2" "$3"; }
# note_warn — a standing condition this tool REPORTS and will never act on, in
# either mode. Deliberately NOT counted in DRIFT_COUNT.
#
# The failure that picked it: `ruleset.superseded` fires on every migrated repo
# from the moment the split converges until the operator deletes the old
# rulesets by hand. Counted as drift, the daily scheduled check would be red on
# all thirteen repos indefinitely, and a signal that is always red reports
# nothing — the next real drift would arrive into noise nobody reads. The
# cleanup list reaches the operator once, from the lead; it does not need a
# permanently failing schedule to keep asking.
#
# `::warning::` is GitHub's own workflow command, so the line is an annotation
# on the run rather than a failure, and stays legible when run by hand.
note_warn() { printf '::warning::%s = %s (%s)\n' "$1" "$2" "$3"; }
note_fixed() { printf '  FIXED %s -> %s\n' "$1" "$2"; }
note_skip() { printf '  SKIP  %s (%s)\n' "$1" "$2"; }

# gh_call <step-label> <gh-args...> — echoes stdout; aborts fail-closed on error.
gh_call() {
	local label="$1"
	shift
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
	if [[ "$p" == "$t" ]]; then
		printf '%s' "$HOME"
	elif [[ "$p" == "$t"/* ]]; then
		printf '%s' "$HOME/${p#"$t"/}"
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
	sha="$(gh_call "recent-pr" api "repos/$REPO_SLUG/pulls?state=closed&base=$branch&sort=updated&direction=desc&per_page=10" |
		jq -r '[.[] | select(.merged_at != null)][0].head.sha // empty')"
	[[ -n "$sha" ]] || return 0
	gh_call "check-runs" api "repos/$REPO_SLUG/commits/$sha/check-runs" |
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
	sha="$(gh_call "open-pr" api "repos/$REPO_SLUG/pulls?state=open&base=$branch&sort=updated&direction=desc&per_page=10" |
		jq -r '.[0].head.sha // empty')"
	[[ -n "$sha" ]] || return 0
	gh_call "check-runs-open" api "repos/$REPO_SLUG/commits/$sha/check-runs" |
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
	# hook-run time (gl_resolve, git-hooks/gitleaks-common.sh). This step
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
		if ! (cd "$path" && pre-commit install --install-hooks) >/dev/null; then
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
		allow_squash_merge) want=true ;;
		allow_merge_commit) want=false ;;
		allow_rebase_merge) want=false ;;
		delete_branch_on_merge) want=true ;;
		# allow_auto_merge: the repo-level enable for "merge when checks
		# pass" -- the map's "unowned PRs merge on green" needs it ON, and
		# arming stays a NON-AUTHOR act (until Margot: the operator, never
		# the authoring session). allow_update_branch: exposes GitHub's
		# own "update branch" so a PR stranded behind an advanced base
		# under strict checks can be brought current (the named
		# branch-updater path) without a force-rebase.
		allow_auto_merge) want=true ;;
		allow_update_branch) want=true ;;
		squash_merge_commit_title) want=PR_TITLE ;;
		squash_merge_commit_message) want=PR_BODY ;;
		*) want="" ;;
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
	# --- Step 6: branch rulesets — one per declared entry -----------------
	# Two by design (review / checks): bypass is per-ruleset, so a single object
	# would let a review bypass also waive the up-to-date rule. See
	# converge_branch_ruleset's header for the receipt.
	#
	# rulesets_json is fetched HERE, in this scope, because the tag-ruleset step
	# below reuses it. It used to be a `local` of the inline branch block;
	# extracting that block took it out of scope and left the tag step reading an
	# unbound variable, which reported every tag ruleset as absent.
	local rulesets_json
	rulesets_json="$(gh_call "rulesets-list" api "repos/$REPO_SLUG/rulesets")"

	local _brs _brs_name _brs_rules _brs_bypass _brs_names_seen="" _other_id _other_name

	# Declared required contexts are resolved to their live reporting app ids
	# HERE, above the creation loop, so a ruleset POSTed from scratch carries
	# its finished required_status_checks rule in the create body.
	#
	# The failure this closes: the create POSTed an empty required_status_checks
	# list and bound the contexts in a follow-up PUT. Anything failing between
	# the two — a 403 on check-runs, a dropped connection — left a checks
	# ruleset that was present, correctly named, and required nothing: a gate
	# that reads as enforced and enforces nothing.
	#
	# Resolution sits above the LOOP, not inside converge_branch_ruleset, for
	# the same reason one level up. The loop creates the review ruleset first,
	# so resolving per-ruleset would POST review, then fail on checks, and leave
	# the repo with a review gate (bot bypass and all) and no checks gate at
	# all. Both declared rulesets are created from one resolved plan, or neither
	# is. gh_call is fail-closed, so an unreadable check-runs endpoint aborts
	# the run right here — before any ruleset exists.
	local _create_ctx_json="[]" _create_blocked=0 _need_ctx_resolve=0
	local _absent_name _absent_rules _cdc _capp
	while IFS= read -r _brs; do
		[[ -n "$_brs" ]] || continue
		_absent_name="$(printf '%s' "$_brs" | jq -r '.name')"
		_absent_rules="$(printf '%s' "$_brs" | jq -c '.rules')"
		printf '%s' "$_absent_rules" | jq -e 'index("required_status_checks") != null' >/dev/null || continue
		printf '%s' "$rulesets_json" | jq -e --arg n "$_absent_name" \
			'any(.[]; .target == "branch" and .name == $n)' >/dev/null && continue
		_need_ctx_resolve=1
	done < <(printf '%s' "$DECLARED_BRANCH_RULESETS" | jq -c '.[]')

	if [[ "$MODE" == converge && $_need_ctx_resolve -eq 1 && "$REPO_DECLARED_CONTEXTS" != "null" ]]; then
		# The bindings a LIVE branch ruleset already enforces on this branch,
		# collected once and preferred over a check-run scan below.
		local _live_bindings="[]" _lb_id _lb_detail
		while IFS= read -r _lb_id; do
			[[ -n "$_lb_id" ]] || continue
			_lb_detail="$(gh_call "ruleset-get-bindings" api "repos/$REPO_SLUG/rulesets/$_lb_id")"
			printf '%s' "$_lb_detail" | jq -e --arg b "refs/heads/$default_branch" '
                    (.conditions.ref_name.include // []) as $inc
                    | (($inc | index($b)) != null) or (($inc | index("~DEFAULT_BRANCH")) != null)
                ' >/dev/null || continue
			_live_bindings="$(printf '%s' "$_lb_detail" | jq -c --argjson acc "$_live_bindings" '
                $acc + ((.rules // [])
                        | map(select(.type == "required_status_checks"))
                        | map(.parameters.required_status_checks // [])
                        | add // []
                        | map(select(.integration_id != null)))')"
		done < <(printf '%s' "$rulesets_json" | jq -r '.[] | select(.target=="branch") | .id')

		while IFS= read -r _cdc; do
			[[ -n "$_cdc" ]] || continue
			# PREFERRED SOURCE: a binding the branch is already enforcing.
			#
			# The receipt, read across the estate on 2026-09-18: five repos
			# declare `margot` and their live ruleset binds it to App 4862659,
			# but `margot` appears on NEITHER their newest merged PR head nor
			# their newest open one — Margot skips bot-authored pull requests,
			# and a dependency bump is often the most recent merge. A check-run
			# scan alone therefore cannot re-derive a context the branch is
			# enforcing right now, and the split would create nothing on 5 of 13
			# repos.
			#
			# This is not a weaker source than the scan, it is a stronger one:
			# the live ruleset is the enforced state rather than an inference
			# from one commit's history, and carrying a binding forward from the
			# ruleset being replaced can never bind a context blind.
			_capp="$(printf '%s' "$_live_bindings" | jq -r --arg c "$_cdc" \
				'[.[] | select(.context == $c) | .integration_id][0] // empty')"
			[[ -n "$_capp" ]] || _capp="$(resolve_context_reporter_any_pr "$default_branch" "$_cdc")"
			if [[ -z "$_capp" ]]; then
				# Same key and wording as the convergence path's refusal, so the
				# daily run's drift_class() sees one known class either way.
				_create_blocked=1
				note_drift "rule.required_status_checks.context-list[+$_cdc]" "declared but never reported" \
					"refusing to require -- never reported on $default_branch or an open PR (a typo must never lock the repo)"
				continue
			fi
			_create_ctx_json="$(printf '%s' "$_create_ctx_json" |
				jq -c --arg c "$_cdc" --argjson a "$_capp" '. + [{context:$c, integration_id:$a}]')"
		done < <(printf '%s' "$REPO_DECLARED_CONTEXTS" | jq -r '.[]')
	fi

	while IFS= read -r _brs; do
		[[ -n "$_brs" ]] || continue
		_brs_name="$(printf '%s' "$_brs" | jq -r '.name')"
		_brs_rules="$(printf '%s' "$_brs" | jq -c '.rules')"
		# A repo's own declared bypass actors are a UNION onto every declared
		# ruleset, which is what `.repos[x].bypass_actors` has always meant.
		# `null` when NOTHING declares a bypass for this ruleset — neither the
		# entry nor the repo. That is not the same as an empty list: null means
		# PRESERVE what is live, [] means own it and write an empty set. The
		# distinction predates this change and is load-bearing, because a
		# declaration that quietly cleared every repo's live bypass actors would
		# lock the operator out of their own default branches.
		_brs_bypass="$(printf '%s' "$_brs" | jq -c --argjson ro "$REPO_ONLY_DECLARED_BYPASS" '
            if (has("bypass_actors") | not) and ($ro == null) then null
            else ((.bypass_actors // []) + (if $ro == null then [] else $ro end)
                  | unique_by([.actor_type, (.actor_id // -1), .bypass_mode]))
            end')"
		converge_branch_ruleset "$_brs_name" "$_brs_rules" "$_brs_bypass" \
			"$_create_ctx_json" "$_create_blocked"
		_brs_names_seen="$_brs_names_seen|$_brs_name"
	done < <(printf '%s' "$DECLARED_BRANCH_RULESETS" | jq -c '.[]')

	# Any OTHER ruleset targeting this branch is REPORTED, never removed. The
	# single pre-split "Protect main" is exactly this case during migration, and
	# while it survives it enforces MORE than the two declared ones, not less —
	# so leaving it is the safe direction. Deleting branch protection is an
	# operator act; this tool has never done it and does not start here.
	#
	# A WARNING, not drift, in BOTH modes — see note_warn. This condition lasts
	# from the split's converge until a human deletes thirteen rulesets, so
	# counting it would leave the daily check red on every repo indefinitely and
	# bury the next real drift in noise. Nothing here is unconverged: the
	# declared rulesets are correct and this one is extra.
	hdr "Superseded branch rulesets"
	local _found_other=0
	while IFS= read -r _other_id; do
		[[ -n "$_other_id" ]] || continue
		detail="$(gh_call "ruleset-get-superseded" api "repos/$REPO_SLUG/rulesets/$_other_id")"
		_other_name="$(printf '%s' "$detail" | jq -r '.name')"
		case "|$_brs_names_seen|" in *"|$_other_name|"*) continue ;; esac
		printf '%s' "$detail" | jq -e --arg b "refs/heads/$default_branch" '
                (.conditions.ref_name.include // []) as $inc
                | (($inc | index($b)) != null) or (($inc | index("~DEFAULT_BRANCH")) != null)
            ' >/dev/null || continue
		_found_other=1
		note_warn "ruleset.superseded[$_other_name]" "also targets $default_branch" \
			"remove BY HAND once the declared rulesets are verified — this tool never deletes branch protection"
	done < <(printf '%s' "$rulesets_json" | jq -r '.[] | select(.target=="branch") | .id')
	[[ "$_found_other" -eq 1 ]] || note_ok "ruleset.superseded" "none — only the declared rulesets target $default_branch"

	# --- Step 6b: tag-immutability ruleset — OWNED, discovered by
	# exact declared name (never by "first ruleset targeting tags", so a
	# repo's own unrelated tag ruleset is never mistaken for this one).
	# What the ruleset restricts: UPDATE and DELETION of a tag. What it does
	# NOT restrict is CREATION — anyone who can push may cut a new tag, and the
	# drift check's tag-origin class is the enforcement surface for that, since
	# no ruleset covers it. The `creation` rule stays out on purpose.
	# "Restricts" is about tags; this step itself both creates the ruleset when
	# it is absent and converges an existing one.
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
			tag_matched_id="$(jq -n --arg n "$TAG_RULESET_NAME" --argjson rules "$want_tag_rules" --argjson exclude "$REPO_TAG_RULESET_EXCLUDE" '{
                name: $n,
                target: "tag",
                enforcement: "active",
                bypass_actors: [],
                conditions: { ref_name: { include: ["refs/tags/*"], exclude: $exclude } },
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
		# conditions.ref_name.exclude is OWNED and CONVERGED, not preserved.
		# The failure that change answers is receipted: dotty's live ruleset
		# (id 22361714) carries `exclude: []`, and this step used to hand the
		# live `.conditions` straight back into the PUT — so a declared
		# exclusion could be committed to rulesets/default-branch.json and
		# never reach GitHub, while --check reported clean. `include` stays
		# preserved-from-live: this rule set has never owned it.
		local live_tag_exclude
		live_tag_exclude="$(printf '%s' "$tag_detail" | jq -c '.conditions.ref_name.exclude // []')"
		if printf '%s' "$live_tag_exclude" | jq -e --argjson want "$REPO_TAG_RULESET_EXCLUDE" '. == $want' >/dev/null; then
			note_ok "tag-ruleset.exclude" "$REPO_TAG_RULESET_EXCLUDE"
		elif [[ "$MODE" == converge ]]; then
			note_conv "tag-ruleset.exclude" "$live_tag_exclude" "$REPO_TAG_RULESET_EXCLUDE"
			tag_needs_put=1
		else
			note_drift "tag-ruleset.exclude" "$live_tag_exclude" "$REPO_TAG_RULESET_EXCLUDE"
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
			tag_matched_id="$(jq -n --arg n "$TAG_RULESET_NAME" --argjson rules "$want_tag_rules" \
				--argjson cond "$(printf '%s' "$tag_detail" | jq -c '.conditions')" \
				--argjson exclude "$REPO_TAG_RULESET_EXCLUDE" '{
                name: $n,
                target: "tag",
                enforcement: "active",
                bypass_actors: [],
                # include preserved from live; exclude is the declared value.
                conditions: ($cond | .ref_name.exclude = $exclude),
                rules: $rules
            }' | ruleset_write_verify "tag-ruleset-update" PUT "repos/$REPO_SLUG/rulesets/$tag_matched_id")"
			note_fixed "tag-ruleset" "patched id $tag_matched_id (update+deletion blocked, no bypass, exclude $REPO_TAG_RULESET_EXCLUDE)"
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

	# --- Step 8: Actions approve-PR permission --------------------------
	# Lives here, on the converge path, not in drift_check_extras (check-only):
	# the daily check reported this drift on the probe repo while converge
	# only audited it — a setting this tool judges, it must also set.
	# Readable and writable under Ollie's token (Administration); the Claude
	# App's session token still 403s and SKIPs, never false-DRIFTs.
	hdr "Actions approve-PR permission (S2)"
	local actions_perm_json
	# Clean fallback + shape gate (a 403 body lands on stdout): readable iff
	# the response carries .can_approve_pull_request_reviews.
	actions_perm_json="$("$GH" api "repos/$REPO_SLUG/actions/permissions/workflow" 2>/dev/null)" || actions_perm_json='{}'
	if ! printf '%s' "$actions_perm_json" | jq -e 'has("can_approve_pull_request_reviews")' >/dev/null 2>&1; then
		note_skip "actions-approve-off" "not readable under current scope (Administration:read grant pending)"
	else
		local can_approve
		can_approve="$(printf '%s' "$actions_perm_json" | jq -r '.can_approve_pull_request_reviews // false')"
		if [[ "$can_approve" == "false" ]]; then
			note_ok "actions-approve-off" "can_approve_pull_request_reviews=false"
		elif [[ "$MODE" == converge ]]; then
			note_conv "actions-approve-off" "can_approve_pull_request_reviews=true" "off"
			# Whole object, as GitHub documents the PUT: the read-back
			# default_workflow_permissions is carried over unchanged.
			printf '%s' "$actions_perm_json" |
				jq '{default_workflow_permissions: (.default_workflow_permissions // "read"), can_approve_pull_request_reviews: false}' |
				gh_call "actions-approve-off" api "repos/$REPO_SLUG/actions/permissions/workflow" --method PUT --input - >/dev/null
			note_fixed "actions-approve-off" "can_approve_pull_request_reviews=false (Actions must never approve its own PRs)"
		else
			note_drift "actions-approve-off" "can_approve_pull_request_reviews=true" \
				"off (Actions must never approve its own PRs)"
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
	printf '%s' "$content" | tr -d '\n' | base64 --decode 2>/dev/null ||
		printf '%s' "$content" | tr -d '\n' | base64 -D 2>/dev/null
}

# dotty_latest_tag — the current dotty release. The authoritative source is
# what dotty's release-on-merge job publishes as repos/$DOTTY_UPSTREAM_SLUG/releases/latest,
# NOT repos/.../tags[0]: GitHub lists tags in reverse LEXICAL order, so a bare
# CalVer date tag "v2026.09.07" sorts ABOVE its own suffixed releases
# "v2026.09.07-10" — .[0] would name the wrong "latest" and false-flag a
# consumer that is correctly at -10. Falls back to a CalVer-numeric sort of the
# tag list (date, then the -N suffix) when no published release is readable.
# Empty output (never FATAL) means "unreadable" to every caller — they treat
# that as "cannot classify", never as "current" or "drift" (never bound blind).
dotty_latest_tag() {
	local rel
	# `|| true` keeps a 404/empty from aborting under set -e (pipefail).
	rel="$("$GH" api "repos/$DOTTY_UPSTREAM_SLUG/releases/latest" 2>/dev/null | jq -r '.tag_name // empty' 2>/dev/null || true)"
	if [[ -n "$rel" ]]; then
		printf '%s\n' "$rel"
		return 0
	fi
	# Fallback: no readable published release — pick the highest tag by a
	# CalVer-aware sort (date components, then the numeric -N suffix), never the
	# lexical order the API returns. Non-CalVer or unparseable tags sort low.
	"$GH" api "repos/$DOTTY_UPSTREAM_SLUG/tags" 2>/dev/null | jq -r '
        def ver($t): ($t | ltrimstr("v") | split("-")) as $p
            | [ ($p[0] | split(".") | map(try tonumber catch 0)),
                (($p[1] // "0") | try tonumber catch 0) ];
        [ .[]?.name | select(type == "string" and test("^v[0-9]")) ]
        | sort_by(ver(.)) | last // empty
    ' 2>/dev/null || true
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
	behind | diverged)
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
	identical | ahead)
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
	# ANNOTATED tag whose tagger is a declared release author (dotty's
	# release-on-merge job; a plugin release-tag job). A LIGHTWEIGHT tag (ref -> commit, no
	# tag object) or an annotated tag with any other tagger is DRIFT. Reads
	# git/matching-refs/tags + git/tags/<sha> only — App-safe.
	hdr "Tag origin"
	if [[ "$RELEASE_TAG_AUTHORS" == "null" ]]; then
		# Estate policy not configured (a top-level, all-repos input) — visible
		# skip, never a silent clean and never per-repo drift. Once
		# .release_tag_authors is declared the class audits every tag.
		note_skip "tag-origin" "no .release_tag_authors declared — tag origin not audited"
	else
		local tag_refs n
		# matching-refs has the shape this audit needs: every successful page is
		# an array, including [] when no tag matches. Keep API failures fatal;
		# treating an unreadable tag inventory as "no tags" would be false-clean.
		tag_refs="$(gh_call "tag-refs" api "repos/$REPO_SLUG/git/matching-refs/tags" --paginate |
			jq -sc 'if all(.[]; type == "array") then add else error("tag refs response is not an array") end')"
		n="$(printf '%s' "$tag_refs" | jq 'length')"
		if [[ "$n" -eq 0 ]]; then
			note_ok "tag-origin" "no tags"
		else
			local i ref name obj_sha obj_type tagger
			for ((i = 0; i < n; i++)); do
				ref="$(printf '%s' "$tag_refs" | jq -c ".[$i]")"
				name="$(printf '%s' "$ref" | jq -r '.ref | sub("^refs/tags/";"")')"
				obj_sha="$(printf '%s' "$ref" | jq -r '.object.sha')"
				obj_type="$(printf '%s' "$ref" | jq -r '.object.type')"
				# A ref this repo DECLARES mutable is exempt from the origin
				# audit, read from the same `tag_ruleset_exclude` list that
				# exempts it from tag immutability — one declaration, two
				# readers, so the two can never disagree about which ref is the
				# floating one.
				#
				# It has to be exempt because the floating major tag is
				# deliberately LIGHTWEIGHT: `git describe` prefers an annotated
				# tag over a lightweight one on the same commit, and that
				# preference is what keeps `pre-commit autoupdate` resolving the
				# calendar tag instead of the moving one. Auditing it as drift
				# would report the fix as the fault.
				if printf '%s' "$REPO_TAG_RULESET_EXCLUDE" |
					jq -e --arg r "refs/tags/$name" 'index($r) != null' >/dev/null 2>&1; then
					note_ok "tag-origin[$name]" "declared mutable (tag_ruleset_exclude) — origin not audited"
					continue
				fi
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
		printf '%s' "$CI_YML_CONTENT" | grep -q "estate-ci\.yml@" || core_missing+=("ci.yml")
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
		[[ -n "$ci_ref" ]] && classify_dotty_pin "caller-pin[ci.yml]" "$ci_ref"
		[[ -n "$gate_ref" ]] && classify_dotty_pin "caller-pin[gate.yml]" "$gate_ref"
	fi

	# --- Margot caller coverage ---------------------------------------------
	# A margot-enrolled repo (.repos[<slug>].margot_enrolled: true) MUST carry a
	# margot.yml caller that hands off to the estate reusable (estate-margot.yml)
	# — otherwise Margot never runs on its PRs and the reviewer that gates
	# auto-merge is silently absent. A repo NOT enrolled is SKIPPED, never failed.
	# Enrollment is its own declared flag now, NOT `margot` in required_contexts:
	# the v3 flip removed `margot` as a required check, so the old proxy is gone.
	# Verify only the trigger is present; the secret VALUES are set at cutover.
	hdr "Margot caller coverage"
	if [[ "$REPO_MARGOT_ENROLLED" != "true" ]]; then
		note_skip "margot-caller" "not margot-enrolled (.repos[\"$REPO_SLUG\"].margot_enrolled is not true)"
	else
		local MARGOT_YML_CONTENT
		MARGOT_YML_CONTENT="$(fetch_repo_file "$REPO_SLUG" ".github/workflows/margot.yml" || true)"
		if printf '%s' "$MARGOT_YML_CONTENT" | grep -q "estate-margot\.yml@"; then
			note_ok "margot-caller" "margot.yml present and calls the estate reusable (estate-margot.yml@)"
		else
			note_drift "margot-caller" "margot.yml missing or does not call estate-margot.yml@" \
				"margot.yml present, calling estate-margot.yml@<pin>"
		fi
	fi

	# --- Ollie caller coverage ----------------------------------------------
	# The same enrolled repo MUST carry an ollie-merge.yml caller that hands off
	# to estate-ollie-merge.yml — that is the only path by which the
	# ollie-the-intern App merges an approved PR. Without it, Margot approves and
	# nothing lands. Same gate and same skip as margot-caller.
	hdr "Ollie caller coverage"
	if [[ "$REPO_MARGOT_ENROLLED" != "true" ]]; then
		note_skip "ollie-caller" "not margot-enrolled (.repos[\"$REPO_SLUG\"].margot_enrolled is not true)"
	else
		local OLLIE_YML_CONTENT OLLIE_BOUNCE_CONTENT
		OLLIE_YML_CONTENT="$(fetch_repo_file "$REPO_SLUG" ".github/workflows/ollie-merge.yml" || true)"
		OLLIE_BOUNCE_CONTENT="$(fetch_repo_file "$REPO_SLUG" ".github/workflows/ollie-bounce.yml" || true)"
		if ! printf '%s' "$OLLIE_YML_CONTENT" | grep -q "estate-ollie-merge\.yml@"; then
			note_drift "ollie-caller" "ollie-merge.yml missing or does not call estate-ollie-merge.yml@" \
				"ollie-merge.yml present, calling estate-ollie-merge.yml@<pin>"
		elif ! printf '%s' "$OLLIE_BOUNCE_CONTENT" | grep -q "workflows/ollie-merge\.yml/dispatches"; then
			# The merger alone is not enough: an approval that lands after the
			# checks reaches it only through the relay.
			note_drift "ollie-caller" "ollie-bounce.yml missing or does not dispatch ollie-merge.yml" \
				"ollie-bounce.yml present, relaying approvals to ollie-merge.yml"
		else
			note_ok "ollie-caller" "ollie-merge.yml present and calls the estate reusable (estate-ollie-merge.yml@); ollie-bounce.yml relays approvals"
		fi
	fi

	# --- Self-instrument alert caller coverage --------------------------------
	# The same enrolled repo MUST carry a self-instrument-alert.yml caller that
	# hands off to estate-self-instrument-alert.yml — the detection that makes
	# the accepted gate-config residual recoverable. Without it a merge that
	# touches Margot's own instrument surface lands with nobody told. Same gate
	# and same skip as margot-caller and ollie-caller.
	hdr "Self-instrument alert caller coverage"
	if [[ "$REPO_MARGOT_ENROLLED" != "true" ]]; then
		note_skip "self-instrument-alert-caller" "not margot-enrolled (.repos[\"$REPO_SLUG\"].margot_enrolled is not true)"
	else
		local SI_ALERT_YML_CONTENT
		SI_ALERT_YML_CONTENT="$(fetch_repo_file "$REPO_SLUG" ".github/workflows/self-instrument-alert.yml" || true)"
		if printf '%s' "$SI_ALERT_YML_CONTENT" | grep -q "estate-self-instrument-alert\.yml@"; then
			note_ok "self-instrument-alert-caller" "self-instrument-alert.yml present and calls the estate reusable (estate-self-instrument-alert.yml@)"
		else
			note_drift "self-instrument-alert-caller" "self-instrument-alert.yml missing or does not call estate-self-instrument-alert.yml@" \
				"self-instrument-alert.yml present, calling estate-self-instrument-alert.yml@<pin>"
		fi
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

	# --- License presence ----------------------------------------------------
	# Public repos carry a license (the estate default is MIT); private repos
	# carry none. Visibility's source of truth is the declared .repos[slug].
	# private_repo (the map), falling back to live visibility when undeclared;
	# license presence is GitHub's own detected .license field (null = none),
	# robust to LICENSE / LICENSE.md / COPYING naming. Check-mode only, App-safe
	# — reuses the repos/<repo> metadata already read above. SKIP when
	# visibility is unreadable — never guess an expectation.
	hdr "License presence"
	local lic_private lic_present
	if [[ "$REPO_DECLARED_PRIVATE" != "null" ]]; then
		lic_private="$REPO_DECLARED_PRIVATE"
	elif printf '%s' "$repo_json_dce" | jq -e 'has("private")' >/dev/null 2>&1; then
		lic_private="$(printf '%s' "$repo_json_dce" | jq -r '.private')"
	else
		lic_private="unknown"
	fi
	if [[ "$lic_private" == "unknown" ]]; then
		note_skip "license-presence" "repo visibility not readable — cannot judge the license expectation"
	else
		if printf '%s' "$repo_json_dce" | jq -e '.license != null' >/dev/null 2>&1; then
			lic_present=true
		else
			lic_present=false
		fi
		if [[ "$lic_private" == "true" ]]; then
			if [[ "$lic_present" == "true" ]]; then
				note_drift "license-presence" "private repo carries a license" "no license on a private repo"
			else
				note_ok "license-presence" "private repo, no license"
			fi
		elif [[ "$lic_present" == "true" ]]; then
			note_ok "license-presence" "public repo, license present"
		else
			note_drift "license-presence" "public repo has no license" "a license (estate default: MIT)"
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
			ahead) note_drift "setup-gitleaks-pin" "$sg_ref" "dotty's current ($sg_latest) — pin lags" ;;
			behind) note_ok "setup-gitleaks-pin" "$sg_ref (newer than $sg_latest)" ;;
			*) note_skip "setup-gitleaks-pin" "cannot verify $sg_ref against dotty's current ($sg_latest)" ;;
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
	# Un-inverted model: CODEOWNERS is default-UNOWNED + an owned allow-list (no
	# `* <owner>` catch-all, except a deliberately full-owned repo). The drift to
	# catch is UNDER-coverage: a REQUIRED-OWNED path (the global
	# .codeowners_required_owned floor unioned with this repo's .codeowners_owned)
	# left effectively unowned — something a human must review that would merge
	# without her. OVER-coverage (a `* <owner>` catch-all, extra owned lines) is
	# SAFE, never drift — which is why an OLD inverted file still passes during
	# the one-PR-at-a-time transition: its catch-all owns every required path.
	#
	# Correctness requires resolving each required-owned pattern against the
	# repo's REAL FILE TREE and running genuine LAST-MATCH-WINS resolution of the
	# actual CODEOWNERS lines (a later, broader, differently-worded ownerless line
	# can clear an owned path — string-comparing patterns would miss it). That
	# matcher lives in codeowners-drift.py (stdlib, no deps); this block fetches
	# the inputs (real tree + .github/CODEOWNERS, both App-token-safe reads) and
	# maps its verdict. Anything unreadable -> SKIP (never counted clean).
	hdr "CODEOWNERS policy"
	if [[ "$CODEOWNERS_OWNER" == "null" ]]; then
		note_skip "codeowners-policy" "no .codeowners_owner declared — CODEOWNERS not audited"
	elif [[ "$CODEOWNERS_REQUIRED_OWNED" == "null" ]]; then
		note_skip "codeowners-policy" "no .codeowners_required_owned declared — CODEOWNERS not audited"
	elif [[ "$REPO_CODEOWNERS_OWNED" == "null" && "$REPO_CODEOWNERS_FULL_OWNED" != "true" ]]; then
		note_skip "codeowners-policy" "no .repos[\"$REPO_SLUG\"].codeowners_owned declared — not audited for this repo"
	elif ! command -v python3 >/dev/null 2>&1; then
		note_skip "codeowners-policy" "python3 unavailable — cannot run the CODEOWNERS matcher"
	elif [[ ! -r "$CODEOWNERS_DRIFT_PY" ]]; then
		note_skip "codeowners-policy" "codeowners-drift.py not found at $CODEOWNERS_DRIFT_PY"
	else
		local co_repo_json co_branch co_tree_json co_content co_paths co_input
		local co_repo_owned co_verdict_json co_verdict co_message
		# The tree fetch is keyed on the repo's real default branch (the git/trees
		# endpoint resolves a branch name to its tree), read from the repo object.
		co_repo_json="$("$GH" api "repos/$REPO_SLUG" 2>/dev/null || echo '{}')"
		co_branch="$(printf '%s' "$co_repo_json" | jq -r '.default_branch // empty' 2>/dev/null)"
		if [[ -z "$co_branch" ]]; then
			note_skip "codeowners-policy" "repo default branch unreadable — cannot fetch the file tree"
		else
			co_tree_json="$("$GH" api "repos/$REPO_SLUG/git/trees/$co_branch?recursive=1" 2>/dev/null || echo '{}')"
			if ! printf '%s' "$co_tree_json" | jq -e '(.tree | type) == "array"' >/dev/null 2>&1; then
				note_skip "codeowners-policy" "repo file tree not readable under current token"
			elif [[ "$(printf '%s' "$co_tree_json" | jq -r '.truncated // false')" == "true" ]]; then
				# A truncated tree could hide a required path -> a false-clean risk.
				note_skip "codeowners-policy" "repo file tree truncated — cannot verify coverage completely"
			else
				co_paths="$(printf '%s' "$co_tree_json" | jq -c '[.tree[] | select(.type == "blob") | .path]')"
				co_content="$(fetch_repo_file "$REPO_SLUG" ".github/CODEOWNERS" || true)"
				co_repo_owned="$REPO_CODEOWNERS_OWNED"
				if [[ "$co_repo_owned" == "null" ]]; then co_repo_owned="[]"; fi
				# Build the matcher's stdin object. An empty CODEOWNERS (absent or
				# blank) is passed as JSON null so the matcher reports "no file".
				co_input="$(jq -n \
					--arg owner "$CODEOWNERS_OWNER" \
					--argjson required "$CODEOWNERS_REQUIRED_OWNED" \
					--argjson repo_owned "$co_repo_owned" \
					--argjson full "$REPO_CODEOWNERS_FULL_OWNED" \
					--argjson paths "$co_paths" \
					--arg content "$co_content" \
					'{owner:$owner, required_owned:$required, repo_owned:$repo_owned,
                      full_owned:$full, paths:$paths,
                      codeowners: (if ($content | length) > 0 then $content else null end)}')"
				co_verdict_json="$(printf '%s' "$co_input" | python3 "$CODEOWNERS_DRIFT_PY" 2>/dev/null || true)"
				co_verdict="$(printf '%s' "$co_verdict_json" | jq -r '.verdict // empty' 2>/dev/null || true)"
				co_message="$(printf '%s' "$co_verdict_json" | jq -r '.message // empty' 2>/dev/null || true)"
				case "$co_verdict" in
				OK) note_ok "codeowners-policy" "$co_message" ;;
				DRIFT) note_drift "codeowners-policy" "$co_message" \
					"every required-owned path effectively owned by $CODEOWNERS_OWNER" ;;
				SKIP) note_skip "codeowners-policy" "$co_message" ;;
				*) note_skip "codeowners-policy" "matcher produced no verdict (unreadable)" ;;
				esac
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
	# object has .name; the environment-secrets response has a .secrets array. Absent shape
	# (a 403 error object, or the fallback) -> SKIP "not readable", never a
	# false-DRIFT. Under a full-scope token both shapes are present and the real
	# OPERATOR_RULES state is reported below.
	env_json="$("$GH" api "repos/$REPO_SLUG/environments/default-branch" 2>/dev/null)" || env_json='{}'
	secrets_json="$("$GH" api "repos/$REPO_SLUG/environments/default-branch/secrets" 2>/dev/null)" || secrets_json='{}'
	if ! printf '%s' "$env_json" | jq -e 'has("name")' >/dev/null 2>&1 ||
		! printf '%s' "$secrets_json" | jq -e '(.secrets | type) == "array"' >/dev/null 2>&1; then
		note_skip "env-secret-freshness" "not readable under current scope (Environments/Secrets:read grant pending)"
	else
		if printf '%s' "$secrets_json" | jq -e '.secrets[]? | select(.name=="OPERATOR_RULES")' >/dev/null 2>&1; then
			note_ok "env-secret-freshness" "default-branch environment + OPERATOR_RULES secret present"
		else
			note_drift "env-secret-freshness" "OPERATOR_RULES secret absent from default-branch environment" \
				"present on the default-branch environment"
		fi

		# MARGOT_APP_KEY: required only for a margot-enrolled repo — its margot.yml
		# caller passes it to estate-margot.yml (the OPERATOR_RULES pass-through
		# shape). Set by the operator at cutover, from 1Password. A repo not
		# enrolled is skipped, never failed. Enrollment is the declared
		# margot_enrolled flag (the v3 flip removed the `margot` required-context proxy).
		# Same readability gate as OPERATOR_RULES above (already in readable branch).
		if [[ "$REPO_MARGOT_ENROLLED" != "true" ]]; then
			note_skip "margot-app-key" "not margot-enrolled — MARGOT_APP_KEY not required"
		elif printf '%s' "$secrets_json" | jq -e '.secrets[]? | select(.name=="MARGOT_APP_KEY")' >/dev/null 2>&1; then
			note_ok "margot-app-key" "MARGOT_APP_KEY secret present on the default-branch environment"
		else
			note_drift "margot-app-key" "MARGOT_APP_KEY secret absent from default-branch environment" \
				"present on the default-branch environment (margot-enrolled repo)"
		fi

		# OLLIE_APP_KEY: the merge key. Required for the same enrolled set — its
		# ollie-merge.yml caller passes it to estate-ollie-merge.yml. Same
		# delivery (default-branch environment, set by the operator from
		# 1Password) and the same skip.
		if [[ "$REPO_MARGOT_ENROLLED" != "true" ]]; then
			note_skip "ollie-app-key" "not margot-enrolled — OLLIE_APP_KEY not required"
		elif printf '%s' "$secrets_json" | jq -e '.secrets[]? | select(.name=="OLLIE_APP_KEY")' >/dev/null 2>&1; then
			note_ok "ollie-app-key" "OLLIE_APP_KEY secret present on the default-branch environment"
		else
			note_drift "ollie-app-key" "OLLIE_APP_KEY secret absent from default-branch environment" \
				"present on the default-branch environment (margot-enrolled repo)"
		fi
	fi

	# (Actions approve-PR permission moved to process_remote Step 8 — it is
	# converged, not audit-only, so it must run on the converge path.)

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

# converge_branch_ruleset <declared-name> <owned-rules-json> <bypass-json>
#
# ONE declared branch ruleset. Called once per entry in `.branch_rulesets`.
#
# WHY THERE IS MORE THAN ONE, and why this is a function rather than an inline
# block — the receipted reason. A bypass actor on a ruleset bypasses EVERY rule
# in it, `strict_required_status_checks_policy` included. While review and checks
# lived in one object, granting the dependency bot a review bypass also let it
# merge a branch that was behind its base; the retired merge script hand-rolled a
# `behind_by == 0` check for exactly that hole, and Renovate has no merge-time
# equivalent. GitHub applies EVERY ruleset targeting a branch and scopes bypass
# per ruleset, so two rulesets give the bot a review bypass while leaving it
# fully subject to the checks. Config, not code.
#
# Discovered by EXACT DECLARED NAME, never by "the first ruleset targeting this
# branch" — which is what the single-ruleset version did and which cannot tell
# two default-branch rulesets apart at all.
converge_branch_ruleset() {
	local declared_name="$1" owned_rules="$2" decl_bypass_in="$3"
	# Args 4/5 are the caller's pre-resolved create plan: the declared contexts
	# already bound to their live reporters, and whether any of them failed to
	# resolve. See the resolution block at the call site for why they are
	# computed there and not here.
	local create_ctx_json="${4:-[]}" create_blocked="${5:-0}"
	local REPO_DECLARED_BYPASS="$decl_bypass_in"

	# owns <rule-type> — is this rule this ruleset's to carry?
	owns() { printf '%s' "$owned_rules" | jq -e --arg t "$1" 'index($t) != null' >/dev/null; }

	hdr "Branch ruleset: $declared_name (target: $default_branch)"
	local matched_id="" matched_detail="" rid detail

	while IFS= read -r rid; do
		[[ -n "$rid" ]] || continue
		detail="$(gh_call "ruleset-get" api "repos/$REPO_SLUG/rulesets/$rid")"
		if printf '%s' "$detail" | jq -e --arg n "$declared_name" '.name == $n' >/dev/null; then
			matched_id="$rid"
			matched_detail="$detail"
			break
		fi
	done < <(printf '%s' "$rulesets_json" | jq -r '.[] | select(.target=="branch") | .id')

	if [[ -z "$matched_id" ]]; then
		if [[ "$MODE" == converge && "$create_blocked" == 1 ]]; then
			# A declared context could not be resolved to a live reporter, so
			# NOTHING is created for this repo — not this ruleset and not its
			# sibling. Creating the review half alone would give the bot its
			# review bypass with no checks gate behind it; creating the checks
			# half with the context dropped would give the operator a ruleset
			# that requires nothing. Both are worse than no ruleset, which at
			# least reads as unprotected.
			note_drift "ruleset" "no ruleset named '$declared_name'" \
				"NOT created — a declared required context has no live reporter (see the context-list line above); a half-formed gate is worse than none"
		elif [[ "$MODE" == converge ]]; then
			note_conv "ruleset" "no ruleset named '$declared_name'" \
				"active ruleset carrying $(printf '%s' "$owned_rules" | jq -r 'join(", ")')"
			matched_id="$(jq -n --argjson pp "$PR_PARAMS" --argjson strict "$STRICT_WANT" \
				--arg enf "$REPO_DECLARED_ENFORCEMENT" --argjson decl_bypass "$REPO_DECLARED_BYPASS" \
				--argjson ctxs "$create_ctx_json" \
				--arg name "$declared_name" --argjson owned "$owned_rules" '{
                name: $name,
                target: "branch",
                enforcement: $enf,
                bypass_actors: (if $decl_bypass == null then [] else $decl_bypass end),
                conditions: { ref_name: { include: ["~DEFAULT_BRANCH"], exclude: [] } },
                rules: [
                    $owned[] | if . == "pull_request" then {type:"pull_request", parameters:$pp}
                               elif . == "required_status_checks"
                               then {type:"required_status_checks",
                                     parameters:{strict_required_status_checks_policy:$strict,
                                                 required_status_checks:$ctxs}}
                               else {type:.} end
                ]
            }' | ruleset_write_verify "ruleset-create" POST "repos/$REPO_SLUG/rulesets")"
			note_fixed "ruleset" "created '$declared_name' (active, targets ~DEFAULT_BRANCH), id $matched_id"
			# Re-fetch the just-created ruleset so the convergence block below
			# runs against it too. The context list is already bound in the
			# create body above, so that block now finds it in agreement and
			# writes nothing -- but it still carries every other rule's
			# convergence, and an existing rsc-less ruleset reaches it by a
			# different route (FOLD: without this re-fetch, a repo created from
			# absolute scratch with a declared list would never get its
			# required checks -- the tier-downgrade class again).
			matched_detail="$(gh_call "ruleset-get-after-create" api "repos/$REPO_SLUG/rulesets/$matched_id")"
		else
			note_drift "ruleset" "no ruleset named '$declared_name'" \
				"active ruleset carrying $(printf '%s' "$owned_rules" | jq -r 'join(", ")')"
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

		# non_fast_forward, deletion, update: presence-only owned rules, and only
		# in the ruleset that DECLARES them. Checked everywhere, the review ruleset
		# would demand rules that belong to the checks ruleset. `update`
		# (restrict-updates) carries no parameters — GitHub stores it as bare
		# {type:"update"} (verified against the live tag-immutability ruleset) — so
		# it converges by presence exactly like the other two; the intended-rules
		# builder's `else {type:.}` emits it, and a ruleset's bypass_actors apply.
		for rt in non_fast_forward deletion update; do
			owns "$rt" || continue
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
		if ! owns pull_request; then
			:
		elif ! printf '%s' "$matched_detail" | jq -e '(.rules // []) | any(.type == "pull_request")' >/dev/null; then
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
		# `no` in a ruleset that does not declare the rule, which switches off
		# the strict-flag, context-binding and context-list work below in one
		# place — the review ruleset must neither require checks nor bind them.
		has_rsc=no
		# DIAGNOSTIC gate — decides only what `has_rsc` reports. The context
		# list's WRITE gate is the separate `owns required_status_checks &&
		# declared-list` test further down; the two are intentionally not one
		# test, and mutating this one does not exercise that one.
		if owns required_status_checks; then
			has_rsc="$(printf '%s' "$matched_detail" | jq -e '(.rules // []) | any(.type == "required_status_checks")' >/dev/null && echo yes || echo no)"
		fi

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
				done <<<"$ctx_names"
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
		# WRITE gate — decides whether the context list is converged at all, and
		# the one to mutate to test that. Separate from the diagnostic gate that
		# sets `has_rsc` above, because this one must also fire when no
		# required_status_checks rule exists yet (the from-scratch case).
		if owns required_status_checks && [[ "$REPO_DECLARED_CONTEXTS" != "null" ]]; then
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
		if [[ "$enf" == "$REPO_DECLARED_ENFORCEMENT" ]]; then
			note_ok "ruleset.enforcement" "$enf"
		elif [[ "$MODE" == converge ]]; then
			note_conv "ruleset.enforcement" "$enf" "$REPO_DECLARED_ENFORCEMENT"
			ruleset_needs_put=1
		else
			note_drift "ruleset.enforcement" "$enf" "$REPO_DECLARED_ENFORCEMENT"
		fi

		# bypass_actors: OWNED only when declared (else preserved, not compared).
		# Canonicalize BOTH sides before the string compare: sort_by orders the
		# array elements, and -S (--sort-keys) orders each object's keys, so a
		# live actor GitHub returns key-alphabetized ({actor_id, actor_type,
		# bypass_mode}) is not false-drift against a declared actor written in a
		# different key order ({actor_type, actor_id, bypass_mode}) — identical
		# content, identical canonical form.
		if [[ "$REPO_DECLARED_BYPASS" != "null" ]]; then
			live_bypass="$(printf '%s' "$matched_detail" | jq -cS '(.bypass_actors // []) | sort_by([.actor_type, (.actor_id // -1), .bypass_mode])')"
			want_bypass="$(printf '%s' "$REPO_DECLARED_BYPASS" | jq -cS 'sort_by([.actor_type, (.actor_id // -1), .bypass_mode])')"
			if [[ "$live_bypass" == "$want_bypass" ]]; then
				note_ok "ruleset.bypass_actors" "$live_bypass"
			elif [[ "$MODE" == converge ]]; then
				note_conv "ruleset.bypass_actors" "$live_bypass" "$want_bypass"
				ruleset_needs_put=1
			else
				note_drift "ruleset.bypass_actors" "$live_bypass" "$want_bypass"
			fi
		fi

		if [[ "$MODE" == converge && $ruleset_needs_put -eq 1 ]]; then
			# Converge every owned field to intent; preserve everything else
			# byte-for-byte. An existing pull_request rule keeps its extra
			# params and gets the declared five forced; required_status_checks
			# keeps its context LIST verbatim but gets strict forced and each
			# unbound context's integration_id filled in from a live lookup
			# (never bound if no live reporter was found, per resolve_context_
			# reporter above — such a context is dropped from the array
			# entirely rather than shipped unbound or guessed); conditions are
			# preserved exactly; enforcement + bypass_actors come from the declared
			# JSON when declared (enforcement default "active"; bypass_actors default
			# preserved), so an undeclared repo is unchanged.
			matched_id="$(printf '%s' "$matched_detail" | jq --argjson pp "$PR_PARAMS" --argjson strict "$STRICT_WANT" --arg enf "$REPO_DECLARED_ENFORCEMENT" --argjson decl_bypass "$REPO_DECLARED_BYPASS" --argjson owned "$owned_rules" '
                (.rules // []) as $ex
                | ($ex | map(.type)) as $t
                | {
                    name: .name,
                    target: "branch",
                    enforcement: $enf,
                    bypass_actors: (if $decl_bypass == null then (.bypass_actors // []) else $decl_bypass end),
                    conditions: .conditions,
                    # Existing rules preserved and converged; each add-if-absent
                    # arm gated on $owned, so a ruleset only ever grows the rules
                    # it DECLARES. Without that gate every ruleset would
                    # re-acquire the full set on its first converge and the split
                    # would quietly close itself.
                    rules: (
                        ($ex | map(
                            if .type == "pull_request"
                            then { type: "pull_request", parameters: ((.parameters // {}) + $pp) }
                            elif .type == "required_status_checks"
                            then .parameters.strict_required_status_checks_policy = $strict
                            else .
                            end
                        ))
                        + (if ($owned | index("non_fast_forward")) and (($t | index("non_fast_forward")) | not) then [{type:"non_fast_forward"}] else [] end)
                        + (if ($owned | index("deletion"))         and (($t | index("deletion"))         | not) then [{type:"deletion"}]         else [] end)
                        + (if ($owned | index("pull_request"))     and (($t | index("pull_request"))     | not) then [{type:"pull_request", parameters:$pp}] else [] end)
                        + (if ($owned | index("update"))           and (($t | index("update"))           | not) then [{type:"update"}]           else [] end)
                    )
                }
            ' | jq --argjson binds "$(
				# Build {context: app_id} for every context this run resolved above.
				printf '%s' "$matched_detail" | jq -c '(.rules // []) | map(select(.type=="required_status_checks"))[0].parameters.required_status_checks[]?.context' 2>/dev/null |
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
			note_fixed "ruleset" "patched id $matched_id (owned fields converged; context list + conditions preserved; enforcement + bypass_actors from declared JSON when declared, else preserved)"
		fi
	fi
}

# ----------------------------------------------------------------------------
# § CALLER OWNERSHIP (--callers to converge, --check to report)
#
# The surfaces every enrolled repo must carry so the estate's release reaches
# it without a pin-bump PR and its dependency bumps merge themselves:
#
#   (a) the three estate reusable `uses:` refs, and every `dotty_ref:` beside
#       them, at the floating major tag `v1`;
#   (b) margot.yml's push-to-main comment, which was wrong in every copy;
#   (c) a renovate.json extending the estate preset this repo publishes;
#   (d) the .github/pull_request_template.md CI already enforces the shape of;
#   (e) the standard pre-commit suite proved in dotty PR #310 — ENSURED
#       present in .pre-commit-config.yaml, not owned whole (see below);
#   (f) the .yamllint.yaml and .markdownlint.yaml those last two hooks read;
#   and it DELETES any .github/dependabot.yml, which Renovate replaces.
#
# WHY THIS IS OWNED HERE RATHER THAN HAND-EDITED THIRTEEN TIMES. The rollout
# that motivated it is thirteen repos wide, and a hand-edit leaves nothing
# behind that notices the next drift. Owning it means `--check` reports a repo
# that falls off the pipe instead of it failing silently at the next release,
# which is exactly how the estate got into the split-channel state this whole
# piece is fixing (hooks at v2026.09.07 while CI ran v2026.09.18).
#
# WHAT IS OWNED WHOLE, WHAT IS OWNED BY LINE, AND WHAT IS ENSURED/ADDITIVE —
# decided by surveying all fourteen enrolled repos, not by preference:
#   * margot.yml is owned WHOLE. All eleven unconverged copies are byte-
#     identical once the pin is normalized (one checksum across the lot), so a
#     single template is deterministic and `--check` is a content compare.
#     Rewriting a prose comment by pattern across eleven files would be the
#     fragile way to do the same thing.
#   * ci.yml and gate.yml are owned BY LINE — only the `uses:` ref and any
#     `dotty_ref:`. These genuinely differ (twelve distinct ci.yml shapes, four
#     gate.yml variants: release-check jobs, OPERATOR_ROSTERS, home-assistant's
#     own shape), and owning them whole would destroy real per-repo config.
#   * renovate.json, the PR template, .yamllint.yaml and .markdownlint.yaml are
#     owned WHOLE — pure estate policy with nothing per-repo in any of them
#     (no caller has ever carried its own yamllint/markdownlint config).
#   * .pre-commit-config.yaml is ENSURED/ADDITIVE — its own third mode,
#     neither whole nor by-line. An earlier version of this capability owned
#     it WHOLE, on the margot.yml theory; superseded on direction after an
#     audit found the eleven callers' copies are NOT byte-identical the way
#     margot.yml's are — seven of eleven carry a genuinely repo-specific
#     `repo: local` hook block in this same file (`check-file-presence`,
#     wiki's `track-list-guard`, home-assistant's `network-rule-fixtures`,
#     dotty-private's own gitleaks/operator-rules block), and whole-file
#     ownership had no way to preserve them. `pre-commit-suite-merge.py`
#     (`.github/scripts/`) is the fix: it ENSURES every standard hook id is
#     present, ADDING whatever a repo is missing, and otherwise touches
#     nothing — `repo: local` blocks are never inspected, and an existing
#     `rev:` is never rewritten (Renovate's lane: the repo's `default.json`
#     preset enrolls the `pre-commit` manager for exactly that, and fighting
#     it by re-pinning here would just make `--callers` and Renovate revert
#     each other's PRs). See that script's own module docstring for the full
#     mechanism and the one per-repo exclusion it carries today
#     (dotty-private declines dotty's remote gitleaks-* — it already runs its
#     own operator-rules gitleaks, and adding dotty's would not replace that
#     mechanism, only run two competing secret scanners beside it).
#   * dependabot.yml is DELETED rather than owned. Renovate covers both managers
#     this estate uses, and two bots opening two PRs for one bump is not
#     redundancy: under the strict up-to-date rulesets each one's merge makes the
#     other's branch stale.
#
# WHY A PULL REQUEST, NOT A PUSH. These are workflow files — real changes that
# belong under Margot's review and the operator's merge, unlike a ruleset field
# this tool converges directly. The author is deliberately NOT the dependency
# bot: that identity means "dependency bump, skip review, self-merge", and a
# workflow change must never wear it. For THIS pull request author, reviewer and
# merger stay three different identities — the Claude App, Margot, and the
# operator. A dependency bump is the one case where they collapse: Renovate runs
# as Ollie and both authors and merges its own bumps, which is exactly why the
# author of a workflow change must not be that identity.
#
# The content committed here is machine-generated from this file's own
# constants and the repo's existing bytes, so it never carries a secret and is
# not routed through the local pre-commit scan; the PR's own required
# `trusted-scan` is the covering scan, as it is for every other PR.
# ----------------------------------------------------------------------------

# The floating first-party major tag every caller pins. A constant, not a
# lookup: the whole point of `v1` is that it does not change per release.
INTENDED_USES_REF="v1"
CALLER_BRANCH="estate-caller-rollout"
CALLER_PR_COUNT=0
CALLER_RESOLVED=0

# The canonical margot.yml. Rendered from a constant here rather than fetched
# from dotty at run time, for two reasons: the tool must be testable offline,
# and dotty's own caller is converged BY this template rather than being its
# source, so there is exactly one definition and no chicken-and-egg.
intended_margot_yml() {
	cat <<'MARGOT_EOF'
name: Margot
# Thin per-repo caller: on THIS repo's CI completing, hand off to the estate's
# Margot-dispatch reusable, which fires Margot's review in dotty-private.
# Owned by provision-public-repo.sh --callers; edit it there, not here.
# Mirrors ci.yml / gate.yml: name + triggers + concurrency + the secret
# pass-through live HERE; the job lives in the reusable.
#
# Listens for "CI" ONLY (never "Gate") — this workflow is named "Margot", so it
# can never self-trigger. Margot's floor-gate poll covers the case where the
# Gate lane's trusted-scan is still finishing when CI completes.
on:
  workflow_run:
    workflows: ["CI"]
    types: [completed]

permissions:
  contents: read

# Cancel a superseded dispatch when a newer CI completion supersedes it —
# PR-scoped via the workflow_run's PR number.
#
# A push-to-main completion does NOT have an empty pull_requests[]. Every copy
# of this comment used to claim it did, and that claim was wrong: GitHub fills
# the array from the head sha, so after a merge the merged PR is still in it.
# Live proof in dotty on 2026-09-17 — CI run 35280943082 (event `push`, head_sha
# 746b655f) woke dispatch runs 35281445314 and 35282549847, both of which
# succeeded and paid for a review of an already-merged PR. The reusable now
# tests `workflow_run.event == 'pull_request'` directly, which is what actually
# skips it. Such a completion still collapses into a shared concurrency group
# here, which is harmless once the reusable's job refuses it.
concurrency:
  group: margot-dispatch-${{ github.event.workflow_run.pull_requests[0].number }}
  cancel-in-progress: true

jobs:
  dispatch:
    # `@v1`, the floating first-party major tag dotty's release-on-merge moves
    # onto every release, so one release reaches this caller with no pin-bump PR.
    uses: lexijamesesq/dotty/.github/workflows/estate-margot.yml@v1
    secrets:
      MARGOT_APP_KEY: ${{ secrets.MARGOT_APP_KEY }}
MARGOT_EOF
}

# The canonical ollie-merge.yml — the thin caller through which the
# ollie-the-intern App merges a repo's approved pull requests. Same rationale as
# intended_margot_yml: one definition, rendered from a constant, dotty's own copy
# converged BY it. The approval relay is a SEPARATE workflow (ollie-bounce.yml,
# below): when both jobs lived in this one file, every approval's run listed
# `merge` as skipped on the pull request while the run that actually merged (the
# dispatched one, on the default branch) never appeared there at all — the
# visible job always said skipped and the real one was invisible. One workflow
# per trigger context ends that: a review shows "Ollie bounce", a check suite
# shows "Ollie merge", and nothing is ever listed as skipped.
intended_ollie_merge_yml() {
	cat <<'OLLIE_EOF'
name: Ollie merge
# Thin per-repo caller: the ollie-the-intern App merges THIS repo's approved,
# green pull requests. Owned by provision-public-repo.sh --callers; edit it
# there, not here. Mirrors margot.yml: triggers + concurrency + the secret
# pass-through live HERE; the job lives in the reusable (estate-ollie-merge.yml).
#
# Two triggers, one merge, both from the default branch: `check_suite` and
# `workflow_dispatch` run there, so they can reach the `default-branch`
# environment that holds OLLIE_APP_KEY. The approval event cannot (its ref is
# the PR's merge ref, and the environment's branch policy is the default
# branch — the safeguard that keeps the merge key out of every PR-context run),
# so approvals arrive here as a workflow_dispatch raised by ollie-bounce.yml.
# Kept as its own workflow on purpose: a job that is skipped on every approval
# run used to sit in this file and read as "Ollie merge: skipped" on the pull
# request while the real merge ran elsewhere, unseen.
#
# Fork pull requests are never merged: the reusable refuses a cross-repository PR
# before it calls merge, identically for both triggers. A refusal by GitHub's
# gate ends this run green and, on an approved PR, leaves a note on it.
on:
  check_suite:
    types: [completed]
  workflow_dispatch:
    inputs:
      pr:
        description: "Pull request number to merge"
        required: true
        type: string

permissions:
  contents: read

concurrency:
  group: ollie-merge-${{ github.event.inputs.pr || github.event.check_suite.pull_requests[0].number || github.run_id }}
  cancel-in-progress: false

jobs:
  merge:
    # A completed, successful check suite that belongs to a PR, or an explicit
    # dispatch. GitHub's own `check_suite.pull_requests` lists same-repo PRs only.
    if: >-
      ${{ github.event_name == 'workflow_dispatch'
          || (github.event_name == 'check_suite'
              && github.event.check_suite.conclusion == 'success'
              && github.event.check_suite.pull_requests[0]) }}
    # `@v1`, the floating first-party major tag dotty's release-on-merge moves
    # onto every release, so one release reaches this caller with no pin-bump PR.
    uses: lexijamesesq/dotty/.github/workflows/estate-ollie-merge.yml@v1
    with:
      pr: ${{ format('{0}', github.event.inputs.pr || github.event.check_suite.pull_requests[0].number) }}
    secrets:
      OLLIE_APP_KEY: ${{ secrets.OLLIE_APP_KEY }}
OLLIE_EOF
}

# The canonical ollie-bounce.yml — the approval relay. Holds no secret and no
# environment: it re-raises an approval as a workflow_dispatch of ollie-merge.yml
# on the default branch, the one kind of run a GITHUB_TOKEN-raised event may
# start. Its own workflow so the pull request's checks show it as what it is.
intended_ollie_bounce_yml() {
	cat <<'BOUNCE_EOF'
name: Ollie bounce
# Thin per-repo relay, owned by provision-public-repo.sh --callers; edit it
# there, not here. An approval (the operator's or Margot's) usually lands AFTER
# the checks already finished, so no default-branch-context event follows it and
# ollie-merge.yml would never run. This workflow re-raises the approval as a
# workflow_dispatch of ollie-merge.yml on the default branch, where the merge
# key is reachable. It holds NO secret and no environment, so its PR-ref context
# is harmless; `actions: write` is the only grant. Fork PRs are skipped here only
# to save a pointless dispatch — the reusable refuses them regardless.
on:
  pull_request_review:
    types: [submitted]

permissions:
  contents: read

concurrency:
  group: ollie-bounce-${{ github.event.pull_request.number }}
  cancel-in-progress: false

jobs:
  bounce:
    if: >-
      ${{ github.event.review.state == 'approved'
          && github.event.pull_request.head.repo.full_name == github.repository }}
    runs-on: ubuntu-latest
    timeout-minutes: 2
    permissions:
      actions: write
    env:
      GH_TOKEN: ${{ github.token }}
      PR: ${{ github.event.pull_request.number }}
      REF: ${{ github.event.repository.default_branch }}
    steps:
      - name: Re-raise the approval as a default-branch dispatch of ollie-merge.yml
        run: |
          set -euo pipefail
          jq -n --arg ref "$REF" --arg pr "$PR" '{ref:$ref,inputs:{pr:$pr}}' \
          | gh api -X POST "repos/${GITHUB_REPOSITORY}/actions/workflows/ollie-merge.yml/dispatches" --input -
          echo "dispatched ollie-merge for #${PR} on ${REF}"
BOUNCE_EOF
}

# The canonical self-instrument-alert.yml — the detection half of the accepted
# gate-config residual. Holds no secret and no environment: on every push to
# main it hands the push's before/after to the estate reusable, which
# classifies the merge against the BASE self_instrument set and surfaces a
# hit. Out-of-band by construction: nothing here is shared with Margot's or
# Ollie's pipeline, so one merge cannot both disarm Margot and suppress this.
# The file is in the ruleset's self_instrument.global so that any OTHER surface
# classifying the estate treats it as instrument; a push that removes the
# caller runs the pushed (absent) file, so its removal is surfaced by the
# self-instrument-alert-caller audit below, not by the alert itself.
intended_self_instrument_alert_yml() {
	cat <<'SIALERT_EOF'
name: Self-instrument merge alert
# Thin per-repo caller, owned by provision-public-repo.sh --callers; edit it
# there, not here. On every push to main the estate reusable classifies the
# merge against the self_instrument set AS IT STOOD BEFORE THE MERGE and, on a
# hit, comments on the merged pull request, assigns the operator and warns on
# the run. Detection, never a hold: it blocks, reverts and re-decides nothing.
# GITHUB_TOKEN only — no App, no secret, no environment — so it runs
# independently of Margot's and Ollie's pipelines. A push runs the caller AS
# PUSHED, so a merge that removes or edits this file is not caught here; it is
# caught by the provisioner's self-instrument-alert-caller audit (DRIFT on the
# scheduled check). The reusable and the ruleset ARE self-covered: dotty's own
# caller classifies a merge editing them against the pre-merge set.
on:
  push:
    branches: [main]

permissions:
  contents: read

jobs:
  alert:
    permissions:
      contents: read
      pull-requests: write
      issues: write
    # `@v1`, the floating first-party major tag dotty's release-on-merge moves
    # onto every release, so one release reaches this caller with no pin-bump PR.
    uses: lexijamesesq/dotty/.github/workflows/estate-self-instrument-alert.yml@v1
    with:
      before: ${{ github.event.before }}
      after: ${{ github.event.after }}
      repo: ${{ github.repository }}
SIALERT_EOF
}

# The canonical per-consumer renovate.json — two lines of intent and nothing
# else. Every policy decision lives in dotty's own `default.json`, which this
# extends, so changing the estate's dependency policy changes one file here and
# reaches every repo without touching any of them.
intended_renovate_json() {
	cat <<'RENOVATE_EOF'
{
  "$schema": "https://docs.renovatebot.com/renovate-schema.json",
  "extends": [
    "github>lexijamesesq/dotty"
  ]
}
RENOVATE_EOF
}

# The canonical .github/pull_request_template.md, copied from dotty's own. This
# is the half of PR creation that was built and never rolled out: CI enforces a
# body shape (`pr-body-check.py` against `pr-body:v1`) in every enrolled repo,
# and until now only dotty carried the template that prompts it. One shape, two
# enforcement points, and they have to agree — verified by diffing this against
# dotty's live template, not by assertion.
intended_pr_template() {
	cat "$PR_TEMPLATE_SOURCE"
}

# The canonical .yamllint.yaml / .markdownlint.yaml — read straight from
# dotty's OWN root, not re-declared here. Unlike margot.yml (dotty's own
# caller is converged BY the template, so the template can't also be sourced
# FROM dotty without a chicken-and-egg), these two carry nothing dotty-only:
# dotty consumes the identical file itself (see dotty's own
# .pre-commit-config.yaml yamllint/markdownlint entries), so pointing every
# consumer at the one file dotty already maintains means there is exactly one
# copy to keep current — same non-duplication reasoning as PR_TEMPLATE_SOURCE.
YAMLLINT_SOURCE="${YAMLLINT_SOURCE:-$SCRIPT_SELF_DIR/.yamllint.yaml}"
MARKDOWNLINT_SOURCE="${MARKDOWNLINT_SOURCE:-$SCRIPT_SELF_DIR/.markdownlint.yaml}"
RUFF_SOURCE="${RUFF_SOURCE:-$SCRIPT_SELF_DIR/ruff.toml}"
intended_yamllint_yaml() {
	cat "$YAMLLINT_SOURCE"
}
intended_markdownlint_yaml() {
	cat "$MARKDOWNLINT_SOURCE"
}
intended_ruff_toml() {
	cat "$RUFF_SOURCE"
}

# pcc_merge <content> — ENSURE the standard pre-commit suite is present in a
# caller's .pre-commit-config.yaml, adding whatever is missing and touching
# nothing else. Delegates to pre-commit-suite-merge.py (see that script's own
# docstring for the full mechanism); this is a thin JSON-in/JSON-out wrapper,
# the same shape drift_check_extras already uses for codeowners-drift.py.
#
# Sets PCC_MERGE_CHANGED (0/1), PCC_MERGE_REASONS (newline-separated), and
# PCC_MERGE_CONTENT — all three as globals, none as a return value. This
# MUST be called directly (`pcc_merge "$pcc" "$rev"`), never wrapped in a
# command substitution (`x="$(pcc_merge ...)"`): a command substitution runs
# its command in a SUBSHELL, and a subshell's variable assignments never
# reach the caller — exactly the bug an earlier version of this call site
# had, found live: `--check` never reported drift on a real stale fixture
# because PCC_MERGE_CHANGED was being set one subshell away from the `if`
# that read it. Three globals, not one echoed value, because bash has no
# clean way to return three values and every call site needs at least two.
PCC_MERGE_CHANGED=0
PCC_MERGE_REASONS=""
PCC_MERGE_CONTENT=""
pcc_merge() {
	local content="$1" dotty_rev="$2" input result
	PCC_MERGE_CHANGED=0
	PCC_MERGE_REASONS=""
	PCC_MERGE_CONTENT="$content"
	if [[ -z "$PCC_MERGE_PY" || ! -r "$PCC_MERGE_PY" ]]; then
		return 0
	fi
	input="$(jq -n --arg slug "$REPO_SLUG" --arg content "$content" --arg rev "$dotty_rev" \
		'{repo_slug: $slug, content: $content, dotty_rev: $rev}')"
	result="$(printf '%s' "$input" | python3 "$PCC_MERGE_PY" 2>/dev/null || echo '{}')"
	if [[ "$(printf '%s' "$result" | jq -r '.changed // false' 2>/dev/null)" == "true" ]]; then
		PCC_MERGE_CHANGED=1
		PCC_MERGE_REASONS="$(printf '%s' "$result" | jq -r '.reasons[]?' 2>/dev/null)"
		PCC_MERGE_CONTENT="$(printf '%s' "$result" | jq -r '.content')"
	fi
}

# repin_content <content> — rewrite every estate reusable `uses:` ref and every
# `dotty_ref:` to $INTENDED_USES_REF. Emits the rewritten content.
#
# `dotty_ref:` is rewritten unconditionally because it has exactly one purpose
# in this estate: pinning the dotty checkout that estate-ci/estate-gate read
# their scripts from. It must never lag the ref the YAML itself came from, or
# new workflow code runs against an old checkout of the scripts it calls.
#
# Only the three REUSABLE WORKFLOW markers are touched. dotty's composite
# ACTIONS (.github/actions/*) stay SHA-pinned — zizmor's policy is `ref-pin`
# for the three workflows and `hash-pin` for everything else, and rewriting an
# action ref here would create the finding this estate's config exists to catch.
repin_content() {
	printf '%s\n' "$1" | sed -E \
		-e "s#(lexijamesesq/dotty/\.github/workflows/estate-(ci|gate|margot)\.yml)@[A-Za-z0-9._/-]+#\1@${INTENDED_USES_REF}#g" \
		-e "s#^([[:space:]]*)dotty_ref:[[:space:]]*[A-Za-z0-9._/-]+[[:space:]]*\$#\1dotty_ref: ${INTENDED_USES_REF}#"
}

# caller_pin_ok <content> <marker> — is every pin in this file already at the
# intended ref? Anchored so `@v1` never matches `@v10`: the ref must be
# followed by end-of-line, whitespace, or a comment.
caller_pin_ok() {
	local content="$1" marker="$2" ref
	ref="$(extract_uses_ref "$content" "$marker")"
	[[ -n "$ref" ]] || return 1
	[[ "$ref" == "$INTENDED_USES_REF" ]] || return 1
	# Any dotty_ref present must match too.
	if printf '%s\n' "$content" | grep -qE '^[[:space:]]*dotty_ref:'; then
		printf '%s\n' "$content" | grep -qE "^[[:space:]]*dotty_ref:[[:space:]]*${INTENDED_USES_REF}[[:space:]]*(#.*)?\$" || return 1
	fi
	return 0
}

# caller_plan — decide what this repo needs. Populates the CALLER_* arrays with
# repo-relative paths and their intended content. Pure decision: reads the
# repo's current files, writes nothing.
CALLER_PATHS=()
CALLER_BODIES=()
CALLER_REASONS=()
CALLER_DELETES=()

# dotty's own PR template is the source for every consumer's. Resolved from the
# local checkout when this script is run from one, which is how the rollout runs.
PR_TEMPLATE_SOURCE="${PR_TEMPLATE_SOURCE:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/.github/pull_request_template.md}"

caller_plan() {
	CALLER_PATHS=()
	CALLER_BODIES=()
	CALLER_REASONS=()
	CALLER_DELETES=()
	local ci gate margot ollie ollie_bounce si_alert depbot renovate prtpl pcc yamllint_cfg markdownlint_cfg ruff_cfg want

	# ENROLLMENT FIRST. A repo with no `.repos` entry in the declared JSON is
	# not part of this estate's lane, and this tool must treat it as not ours:
	# no pull request, no drift line, nothing. Un-enrolling is how a repo LEAVES
	# (hazel, 2026-09-18: receives no further commits, kept as a reference until
	# the project superseding it lands), and an un-enrolled repo that still
	# happens to carry caller workflows must not be converged back in by the
	# next run. Deleting the entry has to be sufficient, or un-enrollment is not
	# a real operation.
	if ! printf '%s' "$DECLARED_JSON" | jq -e --arg r "$REPO_SLUG" '.repos | has($r)' >/dev/null 2>&1; then
		note_skip "callers" "not an enrolled repo (no .repos[\"$REPO_SLUG\"] entry) — not ours to own"
		return 1
	fi

	ci="$(fetch_repo_file "$REPO_SLUG" ".github/workflows/ci.yml" || true)"
	gate="$(fetch_repo_file "$REPO_SLUG" ".github/workflows/gate.yml" || true)"
	margot="$(fetch_repo_file "$REPO_SLUG" ".github/workflows/margot.yml" || true)"
	ollie="$(fetch_repo_file "$REPO_SLUG" ".github/workflows/ollie-merge.yml" || true)"
	ollie_bounce="$(fetch_repo_file "$REPO_SLUG" ".github/workflows/ollie-bounce.yml" || true)"
	si_alert="$(fetch_repo_file "$REPO_SLUG" ".github/workflows/self-instrument-alert.yml" || true)"
	depbot="$(fetch_repo_file "$REPO_SLUG" ".github/dependabot.yml" || true)"
	renovate="$(fetch_repo_file "$REPO_SLUG" "renovate.json" || true)"
	prtpl="$(fetch_repo_file "$REPO_SLUG" ".github/pull_request_template.md" || true)"
	pcc="$(fetch_repo_file "$REPO_SLUG" ".pre-commit-config.yaml" || true)"
	yamllint_cfg="$(fetch_repo_file "$REPO_SLUG" ".yamllint.yaml" || true)"
	markdownlint_cfg="$(fetch_repo_file "$REPO_SLUG" ".markdownlint.yaml" || true)"
	ruff_cfg="$(fetch_repo_file "$REPO_SLUG" "ruff.toml" || true)"

	# A repo with NO caller workflows at all is not a half-converged repo, it is
	# a repo outside this lane — a .pre-commit-config.yaml and nothing else.
	# Converging it would mean inventing a CI lane it never had, which is a
	# decision for whoever owns that repo, not a drift item. (hazel was the
	# estate's example until it was un-enrolled on 2026-09-18; the enrollment
	# guard above is now what excludes it, and this arm still covers any enrolled
	# repo that genuinely has no callers.)
	if [[ -z "$ci" && -z "$gate" && -z "$margot" ]]; then
		note_skip "callers" "no caller workflows in this repo — outside the caller lane (nothing to own)"
		return 1
	fi

	if [[ -n "$ci" ]] && ! caller_pin_ok "$ci" 'estate-ci\.yml'; then
		want="$(repin_content "$ci")"
		CALLER_PATHS+=(".github/workflows/ci.yml")
		CALLER_BODIES+=("$want")
		CALLER_REASONS+=("ci.yml: estate-ci.yml pin -> @${INTENDED_USES_REF} (and dotty_ref beside it)")
	fi
	if [[ -n "$gate" ]] && ! caller_pin_ok "$gate" 'estate-gate\.yml'; then
		want="$(repin_content "$gate")"
		CALLER_PATHS+=(".github/workflows/gate.yml")
		CALLER_BODIES+=("$want")
		CALLER_REASONS+=("gate.yml: estate-gate.yml pin -> @${INTENDED_USES_REF} (and dotty_ref beside it)")
	fi
	if [[ -n "$margot" ]]; then
		want="$(intended_margot_yml)"
		if [[ "$margot" != "$want" ]]; then
			CALLER_PATHS+=(".github/workflows/margot.yml")
			CALLER_BODIES+=("$want")
			CALLER_REASONS+=("margot.yml: owned whole — @${INTENDED_USES_REF} pin, corrected push-to-main comment, no merge-key plumbing")
		fi
	fi
	# ollie-merge.yml is owned WHOLE and CREATED where absent: every repo in the
	# caller lane needs the App that merges, or its approved PRs sit forever.
	want="$(intended_ollie_merge_yml)"
	if [[ "$ollie" != "$want" ]]; then
		CALLER_PATHS+=(".github/workflows/ollie-merge.yml")
		CALLER_BODIES+=("$want")
		CALLER_REASONS+=("ollie-merge.yml: owned whole — the ollie-the-intern App merges this repo's approved PRs (created if absent)")
	fi
	# ollie-bounce.yml likewise: without the relay an approval that lands after
	# the checks never reaches the merger.
	want="$(intended_ollie_bounce_yml)"
	if [[ "$ollie_bounce" != "$want" ]]; then
		CALLER_PATHS+=(".github/workflows/ollie-bounce.yml")
		CALLER_BODIES+=("$want")
		CALLER_REASONS+=("ollie-bounce.yml: owned whole — relays an approval to ollie-merge.yml as a default-branch dispatch (created if absent)")
	fi
	# self-instrument-alert.yml likewise: the detection that makes the accepted
	# gate-config residual recoverable. Without it a mis-ranked merge that
	# touches Margot's own instrument surface lands unseen.
	want="$(intended_self_instrument_alert_yml)"
	if [[ "$si_alert" != "$want" ]]; then
		CALLER_PATHS+=(".github/workflows/self-instrument-alert.yml")
		CALLER_BODIES+=("$want")
		CALLER_REASONS+=("self-instrument-alert.yml: owned whole — surfaces a merge that touches the self_instrument set, classified against the base ruleset (created if absent)")
	fi
	want="$(intended_renovate_json)"
	if [[ "$renovate" != "$want" ]]; then
		CALLER_PATHS+=("renovate.json")
		CALLER_BODIES+=("$want")
		CALLER_REASONS+=("renovate.json: owned whole — extends the estate preset github>lexijamesesq/dotty")
	fi

	if [[ -n "$PR_TEMPLATE_SOURCE" && -r "$PR_TEMPLATE_SOURCE" ]]; then
		want="$(intended_pr_template)"
		if [[ "$prtpl" != "$want" ]]; then
			CALLER_PATHS+=(".github/pull_request_template.md")
			CALLER_BODIES+=("$want")
			CALLER_REASONS+=(".github/pull_request_template.md: owned whole from dotty's — the shape CI's pr-body-check already enforces")
		fi
	fi

	# .pre-commit-config.yaml (ensured/additive), .yamllint.yaml,
	# .markdownlint.yaml — gated on the repo already carrying a
	# .pre-commit-config.yaml, the same "outside the lane, not ours to
	# invent" reasoning as the ci/gate/margot arm above: a repo with none
	# today is an empty-appendix repo, and whether it adopts the suite at
	# all is not this tool's call.
	#
	# dotty ITSELF is exempted from the .pre-commit-config.yaml merge, not
	# gated by presence: dotty's own file dogfoods these hooks via
	# `repo: local` (see pre-commit-suite-merge.py's own docstring) and has
	# no `repo: https://github.com/lexijamesesq/dotty` block at all — run
	# unexempted, the merge would read that as "block missing" and inject a
	# dotty-pointing-at-itself remote block beside the local one it already
	# has. .yamllint.yaml/.markdownlint.yaml need no such exemption: dotty
	# IS their source (see YAMLLINT_SOURCE above), so the compare is against
	# itself and trivially matches.
	if [[ -n "$pcc" ]]; then
		if [[ "$REPO_SLUG" != "$DOTTY_UPSTREAM_SLUG" ]]; then
			# dotty_latest_tag captured FIRST, never inline in the pcc_merge
			# call: an empty result (dotty's tag list unreadable — rate limit,
			# network) is the one input this merge cannot safely guess. It is
			# only ever USED when a repo's dotty: block does not exist yet and
			# has to be created from nothing (home-assistant today) — every
			# other repo already has a dotty: block and this value is never
			# consulted. But an empty value reaching pcc_merge in that one case
			# would write `rev: ` with nothing after it, silently, and
			# `--callers` would COMMIT that malformed pin. classify_dotty_pin
			# and precommit-pin-lag both already refuse this exact input
			# ("unreadable -> SKIP, never guessed"); this mirrors them.
			local dotty_rev_for_pcc
			dotty_rev_for_pcc="$(dotty_latest_tag)"
			if [[ -z "$dotty_rev_for_pcc" ]]; then
				note_skip "callers[.pre-commit-config.yaml]" "dotty's tag list unreadable — cannot ensure the suite without a rev for a new dotty: block"
			else
				pcc_merge "$pcc" "$dotty_rev_for_pcc"
				if [[ "$PCC_MERGE_CHANGED" == "1" ]]; then
					CALLER_PATHS+=(".pre-commit-config.yaml")
					CALLER_BODIES+=("$PCC_MERGE_CONTENT")
					CALLER_REASONS+=(".pre-commit-config.yaml: ensured the standard suite proved in dotty PR #310 — $(printf '%s' "$PCC_MERGE_REASONS" | tr '\n' ';' | sed 's/;/; /g; s/; $//')")
				fi
			fi
		else
			note_skip "callers[.pre-commit-config.yaml]" "dotty's own — dogfoods these hooks via repo: local, never the consumer shape"
		fi
		if [[ -n "$YAMLLINT_SOURCE" && -r "$YAMLLINT_SOURCE" ]]; then
			want="$(intended_yamllint_yaml)"
			if [[ "$yamllint_cfg" != "$want" ]]; then
				CALLER_PATHS+=(".yamllint.yaml")
				CALLER_BODIES+=("$want")
				CALLER_REASONS+=(".yamllint.yaml: owned whole from dotty's — the config the shared yamllint hook reads")
			fi
		fi
		if [[ -n "$MARKDOWNLINT_SOURCE" && -r "$MARKDOWNLINT_SOURCE" ]]; then
			want="$(intended_markdownlint_yaml)"
			if [[ "$markdownlint_cfg" != "$want" ]]; then
				CALLER_PATHS+=(".markdownlint.yaml")
				CALLER_BODIES+=("$want")
				CALLER_REASONS+=(".markdownlint.yaml: owned whole from dotty's — the config the shared markdownlint hook reads")
			fi
		fi
		if [[ -n "$RUFF_SOURCE" && -r "$RUFF_SOURCE" ]]; then
			want="$(intended_ruff_toml)"
			if [[ "$ruff_cfg" != "$want" ]]; then
				CALLER_PATHS+=("ruff.toml")
				CALLER_BODIES+=("$want")
				CALLER_REASONS+=("ruff.toml: owned whole from dotty's — pins the Python lint select the shared ruff hook reads (classic E4/E7/E9/F), so ruff's aggressive floating default never applies")
			fi
		fi
	fi

	# dependabot.yml is DELETED, not owned. Renovate replaces it for both
	# managers this estate uses, and leaving a dependabot.yml beside a Renovate
	# config means two bots opening two PRs for the same bump — each one making
	# the other's branch stale under the strict up-to-date rulesets.
	if [[ -n "$depbot" ]]; then
		CALLER_DELETES+=(".github/dependabot.yml")
		CALLER_REASONS+=(".github/dependabot.yml: DELETED — Renovate replaces it; two bots on one bump is not redundancy")
	fi
	return 0
}

# callers_report — the --check face. Reports each planned change as DRIFT and
# writes nothing. Runs inside the ordinary check pass so the scheduled drift
# check catches a repo falling off the pipe.
callers_report() {
	[[ "$MODE" == check ]] || return 0
	hdr "Caller ownership (uses: pins, renovate.json, PR template, pre-commit suite, dependabot removal)"
	caller_plan || return 0
	if [[ ${#CALLER_PATHS[@]} -eq 0 && ${#CALLER_DELETES[@]} -eq 0 ]]; then
		note_ok "callers" "every owned/ensured surface at the intended shape (@${INTENDED_USES_REF}, renovate.json, PR template, standard pre-commit suite, no dependabot.yml)"
		return 0
	fi
	local i
	for i in "${!CALLER_PATHS[@]}"; do
		note_drift "callers[${CALLER_PATHS[$i]}]" "not at the intended shape" "${CALLER_REASONS[$i]}"
	done
}

# process_callers — the --callers face. Plans, then opens (or updates) ONE pull
# request carrying every change this repo needs.
#
# Idempotency, the same shape bump-consumers.sh uses and for the same receipted
# reason: a fixed branch, force-reset onto the current default-branch tip on
# every run. Thirteen of these sit open awaiting the operator, every ruleset
# sets strict_required_status_checks_policy, and a branch left where it was cut
# goes stale and stops being mergeable. An open PR is UPDATED, never stacked.
process_callers() {
	hdr "Caller ownership (opening a PR for this repo)"
	caller_plan || return 0
	if [[ ${#CALLER_PATHS[@]} -eq 0 && ${#CALLER_DELETES[@]} -eq 0 ]]; then
		note_ok "callers" "already at the intended shape — no PR needed"
		return 0
	fi

	# Iterates CALLER_REASONS, not CALLER_PATHS. There is one reason per planned
	# CHANGE, and a deletion is a change with no path to write — so keying the
	# loop on paths silently dropped the dependabot.yml removal from the plan and
	# from DRIFT_COUNT, while still performing it. Found when the deletion arm
	# finally got a fixture: the delete happened and was never announced.
	local i
	for i in "${!CALLER_REASONS[@]}"; do
		DRIFT_COUNT=$((DRIFT_COUNT + 1))
		printf '  PLAN  %s\n' "${CALLER_REASONS[$i]}"
	done

	local base base_sha
	# `|| true` on both: these go through "$GH" directly like every other read
	# in this file, and a 404/403 must REPORT rather than abort the run under
	# `set -e` with no explanation. Without it the function died silently after
	# printing its plan — no writes, no diagnosis, nothing in the summary.
	base="$("$GH" api "repos/$REPO_SLUG" 2>/dev/null | jq -r '.default_branch // empty' || true)"
	base_sha="$("$GH" api "repos/$REPO_SLUG/git/ref/heads/$base" 2>/dev/null | jq -r '.object.sha // empty' || true)"
	if [[ -z "$base" || -z "$base_sha" ]]; then
		echo "  FAIL  $REPO_SLUG: cannot read the default branch or its tip — no PR opened" >&2
		return 0
	fi

	# The open PR is looked up BEFORE the branch is touched, and that ordering
	# is the whole correctness of this block.
	#
	# The receipted failure: an earlier version force-reset the branch onto the
	# base tip on every run, including when a PR was already open on it. Resetting
	# leaves the branch with ZERO commits ahead of base, and GitHub CLOSES a pull
	# request whose head has nothing to merge. So the run that was meant to
	# UPDATE twelve held PRs silently closed all twelve and opened twelve more
	# (metrics #40 closed 03:20:12Z, replaced by #41; the same for the other
	# eleven). "Updates rather than stacks" was false in exactly the case it
	# claimed to handle.
	#
	# So: with a PR open, commit straight onto the branch and never reset it.
	# Without one, cut the branch fresh from the base tip.
	local existing_num existing del_path
	existing_num="$("$GH" api "repos/$REPO_SLUG/pulls?state=open&head=${REPO_SLUG%%/*}:$CALLER_BRANCH" 2>/dev/null | jq -r '.[0].number // empty' || true)"
	existing="$("$GH" api "repos/$REPO_SLUG/pulls?state=open&head=${REPO_SLUG%%/*}:$CALLER_BRANCH" 2>/dev/null | jq -r '.[0].html_url // empty' || true)"

	if [[ -n "$existing_num" ]]; then
		# Staleness is handled by GitHub's own update-branch, which MERGES the
		# base into the head. That keeps the PR open, where a reset would close
		# it. A failure here is not fatal: the PR is still open and reviewable,
		# it is merely behind, and the operator sees the ordinary "update branch"
		# button.
		"$GH" api -X PUT "repos/$REPO_SLUG/pulls/$existing_num/update-branch" >/dev/null 2>&1 || true
	elif "$GH" api "repos/$REPO_SLUG/git/ref/heads/$CALLER_BRANCH" >/dev/null 2>&1; then
		# A branch with no open PR: safe to reset, because there is no PR for the
		# momentarily-empty branch to close.
		"$GH" api -X PATCH "repos/$REPO_SLUG/git/refs/heads/$CALLER_BRANCH" \
			-f "sha=$base_sha" -F "force=true" >/dev/null 2>&1 ||
			{
				echo "  FAIL  $REPO_SLUG: cannot reset $CALLER_BRANCH onto $base_sha" >&2
				return 0
			}
	else
		"$GH" api -X POST "repos/$REPO_SLUG/git/refs" \
			-f "ref=refs/heads/$CALLER_BRANCH" -f "sha=$base_sha" >/dev/null 2>&1 ||
			{
				echo "  FAIL  $REPO_SLUG: cannot create $CALLER_BRANCH" >&2
				return 0
			}
	fi

	for i in "${!CALLER_PATHS[@]}"; do
		local path body blob args
		path="${CALLER_PATHS[$i]}"
		body="${CALLER_BODIES[$i]}"
		blob="$("$GH" api "repos/$REPO_SLUG/contents/$path?ref=$CALLER_BRANCH" 2>/dev/null | jq -r '.sha // empty' || true)"
		args=(-X PUT "repos/$REPO_SLUG/contents/$path"
			-f "message=Own $path from the estate caller template"
			# `printf '%s\n'`, NOT `%s`. Every body here arrives through a
			# command substitution, which strips trailing newlines, so
			# encoding it raw commits a file with no final newline — and the
			# estate's own end-of-file-fixer hook then fails CI on all four
			# files. Receipted: metrics run 35302085667, "fix end of files...
			# Failed" naming ci.yml, gate.yml, margot.yml and dependabot.yml.
			# One newline is exactly right: repin_content re-adds one that the
			# substitution strips again, so the file keeps the single trailing
			# newline it had.
			-f "content=$(printf '%s\n' "$body" | base64 | tr -d '\n')"
			-f "branch=$CALLER_BRANCH")
		# An ADD has no blob sha; an UPDATE must carry one or the API refuses.
		[[ -n "$blob" ]] && args+=(-f "sha=$blob")
		"$GH" api "${args[@]}" >/dev/null 2>&1 ||
			{
				echo "  FAIL  $REPO_SLUG: cannot commit $path" >&2
				return 0
			}
		printf '  WROTE %s\n' "$path"
	done

	# Deletions go through the same contents API, after the writes, so a repo
	# whose only change is the removal still gets a branch to carry it.
	for del_path in ${CALLER_DELETES[@]+"${CALLER_DELETES[@]}"}; do
		local del_sha
		del_sha="$("$GH" api "repos/$REPO_SLUG/contents/$del_path?ref=$CALLER_BRANCH" 2>/dev/null | jq -r '.sha // empty' || true)"
		if [[ -z "$del_sha" ]]; then
			printf '  SKIP  %s (already absent on the branch)\n' "$del_path"
			continue
		fi
		"$GH" api -X DELETE "repos/$REPO_SLUG/contents/$del_path" \
			-f "message=Remove $del_path — Renovate replaces it" \
			-f "sha=$del_sha" -f "branch=$CALLER_BRANCH" >/dev/null 2>&1 ||
			{
				echo "  FAIL  $REPO_SLUG: cannot delete $del_path" >&2
				return 0
			}
		printf '  DELETED %s\n' "$del_path"
	done

	local url
	if [[ -n "$existing" ]]; then
		printf '  PR    updated %s\n' "$existing"
		CALLER_PR_COUNT=$((CALLER_PR_COUNT + 1))
		CALLER_RESOLVED=$DRIFT_COUNT
		return 0
	fi

	url="$("$GH" api -X POST "repos/$REPO_SLUG/pulls" \
		-f "title=Put this repo on the estate's dependency-bot merge pipe" \
		-f "head=$CALLER_BRANCH" -f "base=$base" \
		-f "body=$(caller_pr_body)" 2>/dev/null | jq -r '.html_url // empty' || true)"
	if [[ -z "$url" ]]; then
		echo "  FAIL  $REPO_SLUG: branch and commits landed but the PR call returned no URL" >&2
		return 0
	fi
	printf '  PR    opened %s\n' "$url"
	CALLER_PR_COUNT=$((CALLER_PR_COUNT + 1))
	CALLER_RESOLVED=$DRIFT_COUNT
}

# caller_pr_body — the seven-heading estate body (pr-body:v1). The author is
# not a declared dependency bot, so the CI body check applies and Margot reviews
# this like any other workflow change. Carries no secret and reads none.
caller_pr_body() {
	local i reasons=""
	for i in "${!CALLER_REASONS[@]}"; do reasons+="- ${CALLER_REASONS[$i]}"$'\n'; done
	cat <<BODY_EOF
<!-- pr-body:v1 -->
## Intent
Put this repository on the estate's dependency pipe, so a dotty release reaches it without a pin-bump pull request and its dependency bumps open, go green and merge themselves.

Two things are wrong here today. The callers pin dotty's reusables at an immutable calendar tag, so every dotty release needs a pin-bump pull request in this repo — the per-patch fan-out across thirteen repos that the floating \`v1\` tag exists to end. And nothing keeps this repo's dependencies current on a policy the estate declares in one place.

## What changed
One concern: this repo's side of the dependency pipe. Generated by \`provision-public-repo.sh --callers\`, which owns these surfaces so a repo falling off the pipe is reported as drift instead of failing silently at the next release.

$reasons
\`margot.yml\` is owned whole because every unconverged copy in the estate was byte-identical once the pin is normalized. \`ci.yml\` and \`gate.yml\` are owned by line — only the \`uses:\` ref and any \`dotty_ref:\` — because those files carry real per-repo configuration that must survive.

\`renovate.json\` is two lines on purpose. Every policy decision lives in dotty's \`default.json\`, which it extends, so the estate's dependency rules change in one file and reach every repo without touching any of them.

Any \`.github/dependabot.yml\` is **deleted**, not migrated. Renovate covers both managers this estate uses, and two bots opening two pull requests for one bump is not redundancy: under this repo's strict up-to-date ruleset, each one merging makes the other's branch stale.

The corrected comment in \`margot.yml\` matters on its own. Every copy claimed a push-to-main CI completion is refused by an empty \`pull_requests\` array. It is not: GitHub fills that array from the head sha, so after a merge the merged pull request still matches. Receipted in dotty on 2026-09-17, where CI run 35280943082 woke two dispatch runs that both paid for a review of an already-merged pull request.

When this repo already carries a \`.pre-commit-config.yaml\`, this pull request also ENSURES the standard pre-commit suite dotty proved on itself in PR #310 — ADDING whatever hook this repo is missing, never rewriting what's already there. \`.yamllint.yaml\`/\`.markdownlint.yaml\` are owned whole (pure policy, nothing per-repo in either). The pre-commit surface is deliberately NOT owned whole: it never touches a \`rev:\` line (Renovate owns bumping those, via this repo's own \`default.json\`-derived preset) and never touches a \`repo: local\` block — this repo's own hooks, if it has any, survive untouched.

## Verification
Generated mechanically from one template plus this repo's existing bytes, so the same change is provable across every enrolled repo rather than hand-checked thirteen times. The generator is covered by evals in dotty's \`.claude/eval/provision-public-repo.test.sh\`, including that \`--check\` writes nothing, that an unenrolled repo is left alone, and that \`@v1\` is never matched by \`@v10\`.

This pull request's own required checks are the gate that applies to it: \`all-checks-passed\`, \`trusted-scan\`, and Margot's review.

## Risk and blast radius
This repository's CI wiring and dependency policy only.

Likely failure modes: \`v1\` resolving to something unexpected fails this repo's next CI run, visibly and here alone. Renovate opening more pull requests than expected is bounded by the preset's concurrency limit and by its enabled managers, which are only \`pre-commit\` and \`github-actions\`.

Moving \`uses:\` to a floating tag is a deliberate trade: one release reaches every caller, and the calendar tags stay immutable underneath. zizmor's \`unpinned-uses\` policy already permits \`ref-pin\` for exactly these first-party reusables and still requires a full SHA for every third-party action — which the preset explicitly refuses to let Renovate change for reusable workflows.

## Rollback
Revert this commit and merge the revert. The callers return to their previous pins, \`renovate.json\` disappears so Renovate stops acting on this repo, and any deleted \`dependabot.yml\` comes back.

## Ticket
None — a slice of the local-to-PR fix plan, tracked in that plan's execution log.

## Dependencies
dotty's preset pull request must merge first: \`renovate.json\` here extends \`github>lexijamesesq/dotty\`, which resolves to a \`default.json\` that does not exist on dotty \`main\` until then.

🤖 Generated with [Claude Code](https://claude.com/claude-code)

https://claude.ai/code/session_01SsneLEHEy8BU2PkkUMPLzK
BODY_EOF
}

# ----------------------------------------------------------------------------
# Dispatch — local steps first (per spec order + fail-closed before any remote
# work), then remote, then the drift-check-only classes.
# ----------------------------------------------------------------------------
if [[ "$MODE" == callers ]]; then
	# Caller ownership ONLY. Never process_local, never process_remote, never
	# the drift extras: this mode exists so converging caller content cannot
	# also rewrite a ruleset by accident.
	process_callers
else
	if [[ -n "$LOCAL_PATH" ]]; then
		process_local "$LOCAL_PATH"
	fi
	process_remote
	drift_check_extras
	callers_report
fi

# ----------------------------------------------------------------------------
# Summary + exit
# ----------------------------------------------------------------------------
hdr "Summary"
if [[ "$MODE" == callers ]]; then
	if [[ $DRIFT_COUNT -eq 0 ]]; then
		echo "  $REPO_SLUG: callers already own the intended shape — nothing to open."
		exit 0
	fi
	if [[ $DRIFT_COUNT -eq $CALLER_RESOLVED ]]; then
		echo "  $REPO_SLUG: $DRIFT_COUNT surface(s) carried by $CALLER_PR_COUNT caller PR, held for review."
		exit 0
	fi
	echo "  $REPO_SLUG: $DRIFT_COUNT surface(s) needed changes but no PR carries them (see the FAIL line above)."
	exit 1
fi
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
