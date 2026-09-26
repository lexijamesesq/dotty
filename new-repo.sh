#!/usr/bin/env bash
#
# new-repo.sh — the estate's front door for a NEW repository: create it (public
# or private), seed it, enroll it, and hand the operator exactly two pull
# requests to approve. Idempotent: every step is an "ensure" that reports
# OK / FIXED / SKIP / FAIL and mutates nothing that is already right.
#
#     new-repo.sh [--private] [--description "<text>"] <owner/repo>
#
# WHY THIS EXISTS
# ---------------
# provision-public-repo.sh is the estate's one provisioner, and its `--callers`
# mode REFUSES two things on purpose: a repo with no `.repos[<slug>]` entry in
# rulesets/default-branch.json ("not ours to own"), and an enrolled repo with
# no caller workflows at all ("outside the caller lane"). A brand-new, empty
# repository is both, so it gets nothing from `--callers` until it has (a) a
# declaration and (b) a seed. This script closes that gap and nothing else:
# it never touches a ruleset (converge-on-merge.yml converges the rulesets
# when the declaration PR merges to dotty main) and never rewrites a file in
# a repo that already has history.
#
# IDENTITIES — THE OPERATOR DOES THE WORK, THE APP AUTHORS THE PRS
# -----------------------------------------------------------------
# Runs as the OPERATOR: her own `gh` login (OPERATOR_GH), her own `op`,
# executed by a Claude session OUTSIDE the estate gh wrapper. Two things are
# done by the Claude App instead (APP_GH, the estate wrapper that mints the
# App's installation token): the two pull requests this script opens. An
# author cannot approve their own PR, and both PRs are held for HER approval,
# so they must not be hers. Both identities are verified before anything is
# written, and printed once.
#
#   OPERATOR_GH  (env; default `gh` on PATH) — must answer `api user` with a
#                login equal to <owner>, and its `auth status` must not name
#                a GitHub App / installation identity. Inside a Claude session
#                the `gh` on PATH is the estate wrapper and routes to the App,
#                so a session points OPERATOR_GH at her real gh binary with
#                her own config (the refusal names this).
#   APP_GH       (env; REQUIRED, no default) — must identify, via `auth
#                status`, as an account whose login ends in `[bot]`. (An
#                installation token cannot call `api user`; `auth status` is
#                how gh itself reports the App's identity.)
#
# SECRETS — REFERENCES ONLY, RESOLVED AT THE MOMENT OF USE
# --------------------------------------------------------
# NEW_REPO_SECRETS_ENV (env; default ${XDG_CONFIG_HOME:-$HOME/.config}/estate/
# new-repo.env, template: new-repo.env.sample) defines OPERATOR_RULES_REF,
# MARGOT_APP_KEY_REF and OLLIE_APP_KEY_REF, each an `op://` reference. Every
# value is read with `op read` right before it is set, held only in this
# process's memory, piped straight into `gh secret set`, and NEVER echoed,
# logged or written to disk. ALL reads happen BEFORE ANY `gh secret set`, and
# an EMPTY read is fatal: the receipted defect this guards against (2026-09-25)
# was an empty value being set silently, leaving a repo that looked enrolled
# and was not. GitHub gives no read-back of a secret's value, so a set is
# reported as "set (cannot verify value)" — honest, not assumed.
#
# THE STEPS
# ---------
#   1. Repository — exists, or `gh repo create` (visibility per --private,
#      wiki disabled, description). A repo that exists with the OTHER
#      visibility is a FAIL, never flipped.
#   2. App coverage — each of the three estate Apps (claude-the-enduring,
#      margot-the-meticulous, ollie-the-intern) must reach this repo: an
#      "all repositories" installation is OK; a "selected" one gets the repo
#      added (FIXED); an App with NO installation for this user is a FAIL —
#      installing an App is a UI act nobody can script.
#   3. Seed — ONLY when the default branch is EMPTY: the estate seed set
#      (thin ci/gate/margot callers at @v1, the standard pre-commit suite
#      with dotty pinned at its latest release plus dotty's own .yamllint.yaml
#      / .markdownlint.yaml / ruff.toml, .gitleaks.toml, .house-code.json,
#      README, CLAUDE.md from repo-claude-template.md, and for a public repo
#      the MIT LICENSE — no CODEOWNERS: code-owner review is retired and the
#      owned paths are declared in the ruleset map, never rendered to a
#      file), one commit `chore: estate seed` pushed to
#      the default branch by the operator. The seed commit runs the seeded
#      suite itself (the estate's git template installs pre-commit's hooks
#      into every clone), so the seed is shaped to pass its own hooks. A
#      repo with history is SKIPped: the seed never overwrites. This is the ONE place the estate
#      synthesizes a .gitleaks.toml — for a repo that has no history yet.
#      provision-public-repo.sh's stance for an EXISTING repo is unchanged:
#      its tracked .gitleaks.toml is the repo's own responsibility, never
#      synthesized there.
#   4. Declaration PR (dotty, App-authored) — a temp clone of dotty, branch
#      `enroll-<name>`, the `.repos[<slug>]` entry (public: the public
#      profile; private: `private_repo: true` first, then the same), and for
#      a private repo the slug appended to gate-resolve-profile.test.sh's
#      PRIVATE_SLUGS block. One PR, pr-body:v1 body. An open PR on that
#      branch is SKIPped with its URL. rulesets/ is self-instrument, so
#      Margot holds this PR HIGH for the operator.
#   5. Callers PR (new repo, App-authored) — `provision-public-repo.sh
#      --callers --declared-json <temp copy carrying the new entry> <slug>`
#      with GH=$APP_GH. The seed's ci.yml is what puts the repo inside the
#      caller lane so this can run before the declaration merges.
#   6. Environment + secrets (operator) — environment `default-branch` with a
#      custom deployment-branch policy naming the default branch; the three
#      environment secrets OPERATOR_RULES, MARGOT_APP_KEY, OLLIE_APP_KEY; and
#      MARGOT_APP_KEY once more at REPO level (the Margot dispatch caller
#      runs on workflow_run, outside any environment).
#   7. Print the done-condition — the two PR URLs to approve and the proof
#      to run by hand: a throwaway PR in the new repo that goes green, gets
#      Margot's verdict, and is merged by ollie-the-intern[bot]. Not run here.
#
# FAIL-CLOSED
# -----------
# `set -euo pipefail`. Identity, secrets-env and checkout guards exit 2 with
# a one-line reason before any write. Steps report FAIL and continue where
# a later step is still independently useful; the script exits 1 if any step
# FAILed and 0 only when every step is OK / FIXED / SKIP. Every gh call goes
# through $OPERATOR_GH or $APP_GH and every op call through $OP so the eval
# (.claude/eval/new-repo.test.sh) can stub all three — this script is never
# exercised against a real repository by its tests.

set -euo pipefail

# ----------------------------------------------------------------------------
# Arg parsing
# ----------------------------------------------------------------------------
VISIBILITY=public
DESCRIPTION=""
while [[ $# -gt 0 ]]; do
	case "$1" in
	--private)
		VISIBILITY=private
		shift
		;;
	--public)
		VISIBILITY=public
		shift
		;;
	--description)
		DESCRIPTION="${2:-}"
		[[ -n "$DESCRIPTION" ]] || {
			echo "FATAL: --description requires text" >&2
			exit 2
		}
		shift 2
		;;
	--description=*)
		DESCRIPTION="${1#--description=}"
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
if [[ -z "$REPO_SLUG" ]]; then
	echo "usage: new-repo.sh [--private] [--description \"<text>\"] <owner/repo>" >&2
	exit 2
fi
if [[ "$REPO_SLUG" != */* || "$REPO_SLUG" == */*/* ]]; then
	echo "FATAL: '<owner/repo>' must be exactly owner/repo (got '$REPO_SLUG')" >&2
	exit 2
fi
OWNER="${REPO_SLUG%%/*}"
NAME="${REPO_SLUG#*/}"
if [[ -z "$OWNER" || -z "$NAME" || ! "$NAME" =~ ^[A-Za-z0-9._-]+$ ]]; then
	echo "FATAL: '$REPO_SLUG' is not a valid GitHub owner/repo" >&2
	exit 2
fi

OPERATOR_GH="${OPERATOR_GH:-gh}"
APP_GH="${APP_GH:-}"
OP="${OP:-op}"
NEW_REPO_SECRETS_ENV="${NEW_REPO_SECRETS_ENV:-${XDG_CONFIG_HOME:-$HOME/.config}/estate/new-repo.env}"

SCRIPT_SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# This script lives in dotty; the checkout it lives in is the dotty it seeds
# from (templates, the provisioner, the pre-commit merger, the canonical
# margot.yml, the repo CLAUDE.md template, the declaration it extends).
DOTTY_CHECKOUT="$SCRIPT_SELF_DIR"
TEMPLATES_DIR="$DOTTY_CHECKOUT/new-repo/templates"
PROVISIONER="$DOTTY_CHECKOUT/provision-public-repo.sh"
PCC_MERGE_PY="$DOTTY_CHECKOUT/.github/scripts/pre-commit-suite-merge.py"
DECLARED_JSON_PATH="$DOTTY_CHECKOUT/rulesets/default-branch.json"
GATE_EVAL_REL=".claude/eval/gate-resolve-profile.test.sh"
CLAUDE_TEMPLATE="$DOTTY_CHECKOUT/repo-claude-template.md"
MARGOT_CALLER="$DOTTY_CHECKOUT/.github/workflows/margot.yml"

DOTTY_UPSTREAM_SLUG="lexijamesesq/dotty"
DOTTY_DEFAULT_BRANCH="main"
ENV_NAME="default-branch"
APP_SLUGS="claude-the-enduring margot-the-meticulous ollie-the-intern"
ENROLL_BRANCH="enroll-$NAME"
SEED_COMMIT_MESSAGE="chore: estate seed"

# The public profile every ordinary caller declares (wiki's shape), and the
# owned-path set the declaration writes as the new repo's `codeowners_owned`
# — the gate machinery only. Kept as JSON literals here because the
# declaration PR writes them with jq.
PUBLIC_REQUIRED_CONTEXTS='["all-checks-passed","trusted-scan / trusted-scan"]'
# Why this list exists with no CODEOWNERS file behind it: the ruleset's
# `codeowners_*` map is Margot's owned-tier INPUT (estate-margot.yml derives a
# PR's scrutiny tier from it), and the map is the only record — the seed
# renders no CODEOWNERS and the provisioner audits none, because
# require_code_owner_review is retired on every default-branch ruleset and a
# file's only remaining effect was auto-requesting the operator on every PR.
# The key keeps its "codeowners" name; renaming it is a consumer sweep.
# No /.claude/settings.json here: own it in the declaration when the repo
# gains a tracked one.
DECLARED_OWNED_PATHS='["/.github/workflows/","/.pre-commit-config.yaml","/.gitleaks.toml","/.gitleaks.ci.toml","/.house-code.json"]'
# The lint configs --callers owns whole from dotty's own root (the provisioner's
# YAMLLINT_SOURCE / MARKDOWNLINT_SOURCE / RUFF_SOURCE). Seeded too: the seed
# commit runs the seeded suite, and yamllint/markdownlint with NO config apply
# their 80-column defaults, which the thin callers and CLAUDE.md exceed —
# receipted against a rendered seed. Identical bytes, so --callers finds them
# at shape and writes nothing.
LINT_CONFIG_SOURCES=".yamllint.yaml .markdownlint.yaml ruff.toml"

FAIL_COUNT=0
DECL_PR_URL=""
CALLERS_PR_URL=""

# ----------------------------------------------------------------------------
# Reporting — the provisioner's own line shapes.
# ----------------------------------------------------------------------------
hdr() { printf '\n== %s ==\n' "$1"; }
note_ok() { printf '  OK    %s = %s\n' "$1" "$2"; }
note_fixed() { printf '  FIXED %s -> %s\n' "$1" "$2"; }
note_skip() { printf '  SKIP  %s (%s)\n' "$1" "$2"; }
note_fail() {
	printf '  FAIL  %s: %s\n' "$1" "$2" >&2
	FAIL_COUNT=$((FAIL_COUNT + 1))
}
refuse() { # <reason> — a guard: one line, exit 2, nothing written.
	echo "REFUSED: $1" >&2
	exit 2
}

# ----------------------------------------------------------------------------
# Dependency floor. A missing tool is a hard, named failure — never a skip.
# ----------------------------------------------------------------------------
command -v jq >/dev/null 2>&1 || {
	echo "FATAL: jq is not installed — required to read/build GitHub API JSON." >&2
	exit 1
}
command -v git >/dev/null 2>&1 || {
	echo "FATAL: git is not installed." >&2
	exit 1
}
command -v python3 >/dev/null 2>&1 || {
	echo "FATAL: python3 is not installed — required by pre-commit-suite-merge.py." >&2
	exit 1
}
for f in "$PROVISIONER" "$PCC_MERGE_PY" "$DECLARED_JSON_PATH" "$CLAUDE_TEMPLATE" "$MARGOT_CALLER" "$DOTTY_CHECKOUT/$GATE_EVAL_REL" \
	"$DOTTY_CHECKOUT/.yamllint.yaml" "$DOTTY_CHECKOUT/.markdownlint.yaml" "$DOTTY_CHECKOUT/ruff.toml"; do
	[[ -r "$f" ]] || {
		echo "FATAL: $f is missing — this script must run from a dotty checkout." >&2
		exit 1
	}
done
[[ -d "$TEMPLATES_DIR/common" && -d "$TEMPLATES_DIR/$VISIBILITY" ]] || {
	echo "FATAL: seed templates missing under $TEMPLATES_DIR (need common/ and $VISIBILITY/)." >&2
	exit 1
}

TMP="$(mktemp -d -t new-repo.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT INT TERM

# ----------------------------------------------------------------------------
# Guards — fail closed, exit 2, one line each, before any write.
# ----------------------------------------------------------------------------
hdr "Guards"

# The dotty checkout: on its default branch, clean, at origin's tip. The seed
# is built from this checkout's files, so a stale or dirty checkout seeds a
# repo from bytes that are not what dotty main ships.
checkout_branch="$(git -C "$DOTTY_CHECKOUT" rev-parse --abbrev-ref HEAD 2>/dev/null || true)"
[[ "$checkout_branch" == "$DOTTY_DEFAULT_BRANCH" ]] ||
	refuse "dotty checkout $DOTTY_CHECKOUT is on '$checkout_branch', not '$DOTTY_DEFAULT_BRANCH' — the seed is built from this checkout's files"
[[ -z "$(git -C "$DOTTY_CHECKOUT" status --porcelain 2>/dev/null)" ]] ||
	refuse "dotty checkout $DOTTY_CHECKOUT is not clean — commit or stash first"
git -C "$DOTTY_CHECKOUT" fetch -q origin "$DOTTY_DEFAULT_BRANCH" 2>/dev/null ||
	refuse "cannot fetch origin/$DOTTY_DEFAULT_BRANCH for $DOTTY_CHECKOUT — the checkout must be verifiably up to date"
[[ "$(git -C "$DOTTY_CHECKOUT" rev-parse HEAD)" == "$(git -C "$DOTTY_CHECKOUT" rev-parse "origin/$DOTTY_DEFAULT_BRANCH")" ]] ||
	refuse "dotty checkout $DOTTY_CHECKOUT is not at origin/$DOTTY_DEFAULT_BRANCH — pull first"
note_ok "dotty checkout" "$DOTTY_CHECKOUT at origin/$DOTTY_DEFAULT_BRANCH, clean"

# OPERATOR_GH is the operator's own login — the <owner> of the new repo — and
# not a GitHub App. Its `auth status` text is parsed and never printed: gh
# prints a token prefix there.
operator_login="$("$OPERATOR_GH" api user 2>/dev/null | jq -r '.login // empty' 2>/dev/null || true)"
[[ -n "$operator_login" ]] ||
	refuse "OPERATOR_GH ($OPERATOR_GH) cannot identify itself (\`api user\` gave no login). Inside a Claude session the gh on PATH is the estate wrapper; set OPERATOR_GH to your real gh binary with your own config"
# GitHub logins are case-insensitive; compare them that way.
[[ "$(printf '%s' "$operator_login" | tr '[:upper:]' '[:lower:]')" == "$(printf '%s' "$OWNER" | tr '[:upper:]' '[:lower:]')" ]] ||
	refuse "OPERATOR_GH ($OPERATOR_GH) is logged in as '$operator_login', not '$OWNER' — this script runs as the repo's owner; set OPERATOR_GH to your real gh with your own config"
operator_status="$("$OPERATOR_GH" auth status 2>&1 || true)"
if printf '%s\n' "$operator_status" | grep -qiE '\[bot\]|installation|github app'; then
	refuse "OPERATOR_GH ($OPERATOR_GH) reports a GitHub App / installation identity — it must be the operator's own login, not the estate wrapper"
fi

# APP_GH must be the App: an installation token cannot call `api user`, so the
# identity is the `account <login>` gh itself reports in `auth status`.
[[ -n "$APP_GH" ]] ||
	refuse "APP_GH is not set — it must name the estate gh wrapper that mints the Claude App's token (the two PRs are App-authored so the operator can approve them)"
app_status="$("$APP_GH" auth status 2>&1 || true)"
APP_LOGIN="$(printf '%s\n' "$app_status" | sed -nE 's/.*account ([^[:space:]]+).*/\1/p' | head -n1)"
[[ -n "$APP_LOGIN" && "$APP_LOGIN" == *"[bot]" ]] ||
	refuse "APP_GH ($APP_GH) does not identify as a bot account (auth status account: '${APP_LOGIN:-none}') — it must be the estate gh wrapper minting the Claude App's token"
# The App's numeric user id, for the noreply committer identity of the
# declaration commit (the estate's identity guard requires a noreply email).
app_login_enc="${APP_LOGIN//\[/%5B}"
app_login_enc="${app_login_enc//\]/%5D}"
APP_USER_ID="$("$APP_GH" api "users/$app_login_enc" 2>/dev/null | jq -r '.id // empty' 2>/dev/null || true)"
[[ -n "$APP_USER_ID" ]] ||
	refuse "cannot read the App's user id (\`api users/$APP_LOGIN\`) — needed for the App's noreply commit identity"
APP_COMMIT_EMAIL="${APP_USER_ID}+${APP_LOGIN}@users.noreply.github.com"
note_ok "identities" "operator=$operator_login (does the work) app=$APP_LOGIN (authors the two PRs)"

# The secrets env: three op:// references, present and well-formed. Parsed,
# not sourced — a config file is data, never code to execute.
[[ -r "$NEW_REPO_SECRETS_ENV" ]] ||
	refuse "secrets env $NEW_REPO_SECRETS_ENV is missing — copy new-repo.env.sample there and fill the three op:// references"
read_env_ref() { # <NAME> — the value of NAME="..." in the secrets env, or empty
	sed -nE "s/^[[:space:]]*(export[[:space:]]+)?$1=[\"']?([^\"'#]*)[\"']?[[:space:]]*$/\2/p" "$NEW_REPO_SECRETS_ENV" | tail -n1
}
OPERATOR_RULES_REF="$(read_env_ref OPERATOR_RULES_REF)"
MARGOT_APP_KEY_REF="$(read_env_ref MARGOT_APP_KEY_REF)"
OLLIE_APP_KEY_REF="$(read_env_ref OLLIE_APP_KEY_REF)"
for pair in "OPERATOR_RULES_REF=$OPERATOR_RULES_REF" "MARGOT_APP_KEY_REF=$MARGOT_APP_KEY_REF" "OLLIE_APP_KEY_REF=$OLLIE_APP_KEY_REF"; do
	ref_name="${pair%%=*}"
	ref_val="${pair#*=}"
	[[ -n "$ref_val" ]] || refuse "$NEW_REPO_SECRETS_ENV does not define $ref_name"
	[[ "$ref_val" == op://* ]] || refuse "$ref_name in $NEW_REPO_SECRETS_ENV is not an op:// reference"
done
note_ok "secrets env" "$NEW_REPO_SECRETS_ENV defines the three op:// references"

# ----------------------------------------------------------------------------
# Helpers
# ----------------------------------------------------------------------------

# git_as <gh-bin> <git args...> — run git authenticating to github.com with
# the token of the given gh identity. The machine's own credential helpers are
# URL-scoped to github.com and route through the estate wrapper, so a plain
# `git push` would carry the App's identity for the operator's seed push and
# vice versa; the URL-scoped reset (`helper=` empties the list) is what makes
# the identity explicit. The token travels in this one child's environment,
# never in an argument, never on disk. A remote that is a local path (the
# eval's bare repos) never consults a helper at all.
git_as() {
	local gh_bin="$1" token
	shift
	token="$("$gh_bin" auth token 2>/dev/null || true)"
	[[ -n "$token" ]] || return 1
	# shellcheck disable=SC2016 # the helper body is git's to expand, at credential time
	NEW_REPO_GIT_TOKEN="$token" git \
		-c credential.https://github.com.helper= \
		-c 'credential.https://github.com.helper=!f() { [ "$1" = get ] && printf "username=x-access-token\npassword=%s\n" "$NEW_REPO_GIT_TOKEN"; :; }; f' \
		"$@"
}

# https_origin <clone-dir> <slug> — if gh cloned over SSH (git_protocol ssh),
# re-point origin at HTTPS so git_as's helper governs every push. A local
# path remote (the eval's bare repos) is left alone.
https_origin() {
	case "$(git -C "$1" remote get-url origin 2>/dev/null)" in
	git@github.com:* | ssh://*) git -C "$1" remote set-url origin "https://github.com/$2.git" ;;
	*) : ;;
	esac
}

# render_template <src> <dst> — {{SLUG}} {{NAME}} {{OWNER}} {{DESCRIPTION}}
# {{YEAR}} substituted with bash pattern substitution (no sed escaping of the
# operator's description), nothing else. One trailing newline, always.
render_template() {
	local src="$1" dst="$2" content year
	year="$(date +%Y)"
	content="$(cat "$src")"
	content="${content//\{\{SLUG\}\}/$REPO_SLUG}"
	content="${content//\{\{NAME\}\}/$NAME}"
	content="${content//\{\{OWNER\}\}/$OWNER}"
	content="${content//\{\{DESCRIPTION\}\}/$DESCRIPTION}"
	content="${content//\{\{YEAR\}\}/$year}"
	mkdir -p "$(dirname "$dst")"
	printf '%s\n' "$content" >"$dst"
}

# render_tree <template-dir> <dest-dir> — every file under the template dir,
# rendered to the same relative path.
render_tree() {
	local tdir="$1" dest="$2" f rel
	while IFS= read -r f; do
		rel="${f#"$tdir"/}"
		render_template "$f" "$dest/$rel"
	done < <(find "$tdir" -type f | sort)
}

# dotty_latest_tag — dotty's current release, from what release-on-merge
# publishes as releases/latest (the provisioner's own rule: never tags[0],
# which sorts lexically). Empty output means unreadable; callers treat that
# as "cannot pin", never as a guess.
dotty_latest_tag() {
	"$OPERATOR_GH" api "repos/$DOTTY_UPSTREAM_SLUG/releases/latest" 2>/dev/null | jq -r '.tag_name // empty' 2>/dev/null || true
}

# claude_md_seed — the body of repo-claude-template.md's four-backtick
# template block, placeholders left as {…} for the operator to fill.
claude_md_seed() {
	awk '/^````markdown$/ { f = 1; next } /^````$/ { f = 0 } f' "$CLAUDE_TEMPLATE"
}

# ----------------------------------------------------------------------------
# Step 1 — the repository
# ----------------------------------------------------------------------------
hdr "Step 1 — repository $REPO_SLUG ($VISIBILITY)"
repo_json="$("$OPERATOR_GH" api "repos/$REPO_SLUG" 2>/dev/null || true)"
if printf '%s' "$repo_json" | jq -e '.id? // empty' >/dev/null 2>&1; then
	live_private="$(printf '%s' "$repo_json" | jq -r '.private')"
	want_private=false
	[[ "$VISIBILITY" == private ]] && want_private=true
	if [[ "$live_private" != "$want_private" ]]; then
		note_fail "repository" "$REPO_SLUG exists with private=$live_private but this run asked for $VISIBILITY — visibility is never flipped here"
	else
		note_ok "repository" "exists ($VISIBILITY)"
	fi
else
	create_args=("repo" "create" "$REPO_SLUG" "--$VISIBILITY" "--disable-wiki")
	[[ -n "$DESCRIPTION" ]] && create_args+=("--description" "$DESCRIPTION")
	if "$OPERATOR_GH" "${create_args[@]}" >/dev/null 2>&1; then
		repo_json="$("$OPERATOR_GH" api "repos/$REPO_SLUG" 2>/dev/null || true)"
		if printf '%s' "$repo_json" | jq -e '.id? // empty' >/dev/null 2>&1; then
			note_fixed "repository" "created $REPO_SLUG ($VISIBILITY, wiki disabled)"
		else
			note_fail "repository" "created $REPO_SLUG but cannot read it back"
		fi
	else
		note_fail "repository" "gh repo create $REPO_SLUG failed"
	fi
fi
REPO_ID="$(printf '%s' "$repo_json" | jq -r '.id // empty' 2>/dev/null || true)"
DEFAULT_BRANCH="$(printf '%s' "$repo_json" | jq -r '.default_branch // empty' 2>/dev/null || true)"
[[ -n "$DEFAULT_BRANCH" ]] || DEFAULT_BRANCH=main
if [[ -z "$REPO_ID" ]]; then
	echo "FATAL: no repository id for $REPO_SLUG — nothing further can be ensured." >&2
	exit 1
fi
note_ok "repository.id / default_branch" "$REPO_ID / $DEFAULT_BRANCH"

# ----------------------------------------------------------------------------
# Step 2 — App coverage
# ----------------------------------------------------------------------------
hdr "Step 2 — App coverage (claude-the-enduring, margot-the-meticulous, ollie-the-intern)"
installations="$("$OPERATOR_GH" api --paginate user/installations 2>/dev/null || true)"
for app in $APP_SLUGS; do
	inst="$(printf '%s' "$installations" | jq -c --arg s "$app" '[.installations[]? | select(.app_slug == $s)] | first // empty' 2>/dev/null || true)"
	if [[ -z "$inst" ]]; then
		note_fail "app.$app" "no installation of this App for $OWNER — install it from the App's page in the GitHub UI, then re-run"
		continue
	fi
	inst_id="$(printf '%s' "$inst" | jq -r '.id')"
	selection="$(printf '%s' "$inst" | jq -r '.repository_selection // empty')"
	if [[ "$selection" == "all" ]]; then
		note_ok "app.$app" "installation $inst_id covers all repositories"
		continue
	fi
	covered="$("$OPERATOR_GH" api --paginate "user/installations/$inst_id/repositories" 2>/dev/null | jq -r '.repositories[]?.full_name' 2>/dev/null || true)"
	if printf '%s\n' "$covered" | grep -qxF "$REPO_SLUG"; then
		note_ok "app.$app" "installation $inst_id (selected repositories) already includes $REPO_SLUG"
		continue
	fi
	if "$OPERATOR_GH" api -X PUT "user/installations/$inst_id/repositories/$REPO_ID" >/dev/null 2>&1; then
		note_fixed "app.$app" "added $REPO_SLUG to installation $inst_id (selected repositories)"
	else
		note_fail "app.$app" "cannot add $REPO_SLUG to installation $inst_id"
	fi
done

# ----------------------------------------------------------------------------
# Step 3 — seed (only an EMPTY default branch)
# ----------------------------------------------------------------------------
hdr "Step 3 — seed (only when $DEFAULT_BRANCH is empty)"
seed_repo() {
	local seed_dir="$TMP/seed" dotty_rev pcc_skeleton pcc_input pcc_result
	"$OPERATOR_GH" repo clone "$REPO_SLUG" "$seed_dir" -- -q >/dev/null 2>&1 || {
		note_fail "seed" "cannot clone $REPO_SLUG"
		return 0
	}
	https_origin "$seed_dir" "$REPO_SLUG"
	git -C "$seed_dir" symbolic-ref HEAD "refs/heads/$DEFAULT_BRANCH"
	render_tree "$TEMPLATES_DIR/common" "$seed_dir"
	render_tree "$TEMPLATES_DIR/$VISIBILITY" "$seed_dir"
	# margot.yml: dotty's own copy IS the canonical caller (the provisioner's
	# template converges it), so the seed carries the identical bytes.
	cp "$MARGOT_CALLER" "$seed_dir/.github/workflows/margot.yml"
	for f in $LINT_CONFIG_SOURCES; do
		cp "$DOTTY_CHECKOUT/$f" "$seed_dir/$f"
	done
	claude_md_seed >"$seed_dir/CLAUDE.md"
	[[ -s "$seed_dir/CLAUDE.md" ]] || {
		note_fail "seed" "repo-claude-template.md has no four-backtick template block to seed CLAUDE.md from"
		return 0
	}
	# An empty description leaves README as the heading alone, not a blank line.
	if [[ -z "$DESCRIPTION" ]]; then
		printf '# %s\n' "$NAME" >"$seed_dir/README.md"
	fi
	# The standard pre-commit suite, built by the same merger --callers uses to
	# ENSURE it on an existing repo, from the skeleton template: every block is
	# "missing", so every block is added, with dotty pinned at its latest
	# release. An unreadable release is a FAIL, never a guessed rev (the
	# provisioner refuses the same input for the same reason).
	dotty_rev="$(dotty_latest_tag)"
	[[ -n "$dotty_rev" ]] || {
		note_fail "seed" "dotty's latest release is unreadable — cannot pin the seed's dotty hooks (never guessed)"
		return 0
	}
	# The skeleton's trailing newline is kept (a command substitution strips
	# it, and the merger mirrors whether its input ended with one).
	pcc_skeleton="$(cat "$seed_dir/.pre-commit-config.yaml")"$'\n'
	pcc_input="$(jq -n --arg slug "$REPO_SLUG" --arg content "$pcc_skeleton" --arg rev "$dotty_rev" \
		'{repo_slug: $slug, content: $content, dotty_rev: $rev}')"
	pcc_result="$(printf '%s' "$pcc_input" | python3 "$PCC_MERGE_PY" 2>/dev/null || echo '{}')"
	[[ "$(printf '%s' "$pcc_result" | jq -r '.changed // false')" == "true" ]] || {
		note_fail "seed" "pre-commit-suite-merge.py did not build the suite from the skeleton"
		return 0
	}
	# The merger separates blocks with a blank line, which leaves one directly
	# under `repos:` — dropped so the file reads like every other caller's.
	# `jq -r` adds a newline after content that already ends with one; the
	# final sed drops that one empty last line so the file ends with exactly
	# one newline (end-of-file-fixer runs in the seeded repo too).
	printf '%s' "$pcc_result" | jq -r '.content' |
		awk 'prev_repos && $0 == "" { prev_repos = 0; next } { prev_repos = ($0 == "repos:"); print }' |
		sed '${/^$/d;}' >"$seed_dir/.pre-commit-config.yaml"
	git -C "$seed_dir" add -A
	git -C "$seed_dir" commit -q -m "$SEED_COMMIT_MESSAGE" >/dev/null 2>&1 || {
		note_fail "seed" "the seed commit failed (git identity? hook?) — nothing pushed"
		return 0
	}
	if git_as "$OPERATOR_GH" -C "$seed_dir" push -q origin "$DEFAULT_BRANCH" >/dev/null 2>&1; then
		note_fixed "seed" "pushed '$SEED_COMMIT_MESSAGE' to $DEFAULT_BRANCH ($(git -C "$seed_dir" ls-files | wc -l | tr -d ' ') files, dotty hooks at $dotty_rev)"
	else
		note_fail "seed" "push of the seed commit to $DEFAULT_BRANCH was refused (a pre-push hook, or the remote) — nothing landed"
	fi
}
# "Is the default branch empty?" is decided on the ACTUAL answer, never on
# the absence of one. A 200 carrying the ref's sha is history: SKIP. A
# confirmed 404 (no such ref) or 409 ("Git Repository is empty" — what GitHub
# returns for a repo with no commits) is a fresh repo: seed. Anything else —
# a 5xx, a rate limit, a network error with no body, a malformed body — is
# doubt, and doubt never seeds: an earlier revision treated every non-success
# as "empty" and, receipted against a repo with real history behind a 500,
# pushed the seed on top of it. gh writes an error body to stdout with a
# `status` field and exits non-zero; both are read.
ref_rc=0
ref_json="$("$OPERATOR_GH" api "repos/$REPO_SLUG/git/ref/heads/$DEFAULT_BRANCH" 2>/dev/null)" || ref_rc=$?
ref_sha="$(printf '%s' "$ref_json" | jq -r '.object.sha? // empty' 2>/dev/null || true)"
ref_status="$(printf '%s' "$ref_json" | jq -r 'if type == "object" then (.status? // empty | tostring) else empty end' 2>/dev/null || true)"
if [[ $ref_rc -eq 0 && -n "$ref_sha" ]]; then
	note_skip "seed" "not a fresh repo — $DEFAULT_BRANCH has history; the seed never overwrites"
elif [[ $ref_rc -ne 0 && ("$ref_status" == "404" || "$ref_status" == "409") ]]; then
	seed_repo
else
	note_fail "seed" "cannot determine whether $DEFAULT_BRANCH is empty (gh exit $ref_rc, HTTP status '${ref_status:-none}') — never seeded on doubt"
fi

# ----------------------------------------------------------------------------
# Step 4 — the declaration PR on dotty (App-authored)
# ----------------------------------------------------------------------------
hdr "Step 4 — declaration PR on $DOTTY_UPSTREAM_SLUG (branch $ENROLL_BRANCH, App-authored)"
DECLARED_TMP="$TMP/declared.json"
# The entry, key order as the existing entries: private_repo first (private
# only), then required_contexts, margot_enrolled, codeowners_owned.
if [[ "$VISIBILITY" == private ]]; then
	NEW_ENTRY="$(jq -n --argjson rc "$PUBLIC_REQUIRED_CONTEXTS" --argjson co "$DECLARED_OWNED_PATHS" \
		'{private_repo: true, required_contexts: $rc, margot_enrolled: true, codeowners_owned: $co}')"
else
	NEW_ENTRY="$(jq -n --argjson rc "$PUBLIC_REQUIRED_CONTEXTS" --argjson co "$DECLARED_OWNED_PATHS" \
		'{required_contexts: $rc, margot_enrolled: true, codeowners_owned: $co}')"
fi

# add_private_slug <file> — append the slug to the eval's PRIVATE_SLUGS block
# (between `cat <<'PRIVATE_SLUGS'` and the closing `PRIVATE_SLUGS`), keeping
# the block sorted and unique. Prints nothing; the file is rewritten in place.
add_private_slug() {
	local file="$1" start end
	start="$(grep -n "<<'PRIVATE_SLUGS'" "$file" | head -n1 | cut -d: -f1)"
	end="$(grep -n '^PRIVATE_SLUGS$' "$file" | head -n1 | cut -d: -f1)"
	[[ -n "$start" && -n "$end" && "$end" -gt "$start" ]] || return 1
	{
		head -n "$start" "$file"
		{
			sed -n "$((start + 1)),$((end - 1))p" "$file"
			printf '%s\n' "$REPO_SLUG"
		} | sort -u
		tail -n "+$end" "$file"
	} >"$file.new"
	mv "$file.new" "$file"
}

decl_pr_body() {
	local kind="$VISIBILITY" eval_line private_note="" license_note=", LICENSE"
	eval_line="Not applicable — a public repository adds nothing to the private set."
	if [[ "$kind" == private ]]; then
		eval_line="\`$GATE_EVAL_REL\`: the slug appended to the PRIVATE_SLUGS block, so the gate eval's explicit private-set assertion names it."
		private_note=" with \`private_repo: true\`"
		license_note=""
	fi
	cat <<BODY_EOF
<!-- pr-body:v1 -->
## Intent

Enroll \`$REPO_SLUG\` (a new $kind repository) in the estate's default-branch ruleset and lane, so converge-on-merge applies the three branch rulesets and the tag ruleset on merge, Margot reviews its pull requests, and ollie-the-intern merges the approved ones.

## What changed

One concern: this repository's declaration. \`rulesets/default-branch.json\` gains \`.repos["$REPO_SLUG"]\` — the standard profile (\`all-checks-passed\`, \`trusted-scan / trusted-scan\`; \`margot_enrolled\`; the gate machinery as \`codeowners_owned\`, Margot's owned-tier input — no CODEOWNERS file is rendered from it)$private_note. $eval_line

Generated by \`new-repo.sh\`, which also seeded the repository (thin \`@v1\` callers, the standard pre-commit suite, \`.gitleaks.toml\`, \`.house-code.json\`, README, CLAUDE.md$license_note) and opened the companion callers PR in the repository itself.

## Verification

Generated mechanically by \`new-repo.sh\`, covered by \`.claude/eval/new-repo.test.sh\` (declaration shape for a public and a private repository, key order, the eval list edit). This PR's own required checks apply: \`all-checks-passed\`, \`trusted-scan\`, \`eval-suite\` (which runs the edited gate eval against this declaration), and Margot's review.

## Risk and blast radius

\`rulesets/\` is self-instrument, so this PR is held HIGH for the operator. Blast radius on merge: converge-on-merge writes rulesets on \`$REPO_SLUG\` only; no other repository's declaration changes.

## Rollback

Revert this commit and merge the revert; converge-on-merge does not delete rulesets, so remove the repository's rulesets by hand if it is being un-enrolled.

## Ticket

None — new-repository enrollment, the front door new-repo.sh exists to open.

## Dependencies

None — the companion callers PR in \`$REPO_SLUG\` is independent and may merge in either order.
BODY_EOF
}

declaration_pr() {
	local dotty_dir="$TMP/dotty" existing_url remote_branch pr_url
	"$APP_GH" repo clone "$DOTTY_UPSTREAM_SLUG" "$dotty_dir" -- -q >/dev/null 2>&1 || {
		note_fail "declaration" "cannot clone $DOTTY_UPSTREAM_SLUG as the App"
		cp "$DECLARED_JSON_PATH" "$DECLARED_TMP"
		return 0
	}
	https_origin "$dotty_dir" "$DOTTY_UPSTREAM_SLUG"
	# Already declared on main (a re-run after the PR merged): nothing to open.
	if jq -e --arg r "$REPO_SLUG" '.repos | has($r)' "$dotty_dir/rulesets/default-branch.json" >/dev/null 2>&1; then
		note_skip "declaration" "$REPO_SLUG is already declared on $DOTTY_UPSTREAM_SLUG $DOTTY_DEFAULT_BRANCH — the declaration is the operator's; never rewritten here"
		cp "$dotty_dir/rulesets/default-branch.json" "$DECLARED_TMP"
		return 0
	fi
	# "Is an enrollment PR already open?" is decided on the ACTUAL answer, never
	# on the absence of one — the same rule the seed step applies to "is the
	# branch empty?". A 200 with a PR is SKIP; a 200 with an empty list is "open
	# one". Anything else — a 5xx, a rate limit, a network error, a malformed
	# body — is doubt, and doubt never opens a second PR or force-pushes the
	# enrollment branch over one that may exist. Receipt: the Opus 5.5
	# benchmark runs on dotty #346 both flagged the earlier `|| true` shape,
	# under which an API failure read as "no PR open".
	local pulls_rc=0 pulls_json pulls_status
	pulls_json="$("$APP_GH" api "repos/$DOTTY_UPSTREAM_SLUG/pulls?state=open&head=${DOTTY_UPSTREAM_SLUG%%/*}:$ENROLL_BRANCH" 2>/dev/null)" || pulls_rc=$?
	existing_url="$(printf '%s' "$pulls_json" | jq -r 'if type == "array" then (.[0].html_url // empty) else empty end' 2>/dev/null || true)"
	pulls_status="$(printf '%s' "$pulls_json" | jq -r 'if type == "object" then (.status? // empty | tostring) else empty end' 2>/dev/null || true)"
	if [[ $pulls_rc -ne 0 ]] || ! printf '%s' "$pulls_json" | jq -e 'type == "array"' >/dev/null 2>&1; then
		note_fail "declaration" "cannot determine whether an enrollment PR is already open on $ENROLL_BRANCH (gh exit $pulls_rc, HTTP status '${pulls_status:-none}') — never opened or pushed on doubt"
		# The callers step still needs the entry, exactly as on the SKIP path.
		jq --indent 2 --arg r "$REPO_SLUG" --argjson e "$NEW_ENTRY" '.repos[$r] = $e' "$dotty_dir/rulesets/default-branch.json" >"$DECLARED_TMP"
		return 0
	fi
	if [[ -n "$existing_url" ]]; then
		DECL_PR_URL="$existing_url"
		note_skip "declaration" "PR already open on $ENROLL_BRANCH: $existing_url"
		# The temp declaration for the callers step still needs the entry.
		jq --indent 2 --arg r "$REPO_SLUG" --argjson e "$NEW_ENTRY" '.repos[$r] = $e' "$dotty_dir/rulesets/default-branch.json" >"$DECLARED_TMP"
		return 0
	fi
	git -C "$dotty_dir" checkout -q -b "$ENROLL_BRANCH" "origin/$DOTTY_DEFAULT_BRANCH"
	jq --indent 2 --arg r "$REPO_SLUG" --argjson e "$NEW_ENTRY" '.repos[$r] = $e' "$dotty_dir/rulesets/default-branch.json" >"$dotty_dir/rulesets/default-branch.json.new"
	mv "$dotty_dir/rulesets/default-branch.json.new" "$dotty_dir/rulesets/default-branch.json"
	cp "$dotty_dir/rulesets/default-branch.json" "$DECLARED_TMP"
	if [[ "$VISIBILITY" == private ]]; then
		add_private_slug "$dotty_dir/$GATE_EVAL_REL" || {
			note_fail "declaration" "$GATE_EVAL_REL has no PRIVATE_SLUGS block to append $REPO_SLUG to"
			return 0
		}
	fi
	git -C "$dotty_dir" add rulesets/default-branch.json "$GATE_EVAL_REL"
	# The App's identity via the environment, which outranks any user.* config
	# or GIT_AUTHOR_* the caller's shell carries — this commit is the App's.
	GIT_AUTHOR_NAME="$APP_LOGIN" GIT_AUTHOR_EMAIL="$APP_COMMIT_EMAIL" \
		GIT_COMMITTER_NAME="$APP_LOGIN" GIT_COMMITTER_EMAIL="$APP_COMMIT_EMAIL" \
		git -C "$dotty_dir" commit -q -m "estate: enroll $REPO_SLUG in the default-branch ruleset ($VISIBILITY)" >/dev/null 2>&1 || {
		note_fail "declaration" "the declaration commit failed (a hook?) — no PR opened"
		return 0
	}
	# A stale branch with no open PR is safe to reset (the provisioner's rule):
	# there is no PR for a momentarily-empty branch to close.
	remote_branch="$(git -C "$dotty_dir" ls-remote --heads origin "$ENROLL_BRANCH" 2>/dev/null || true)"
	if [[ -n "$remote_branch" ]]; then
		git_as "$APP_GH" -C "$dotty_dir" push -q --force origin "$ENROLL_BRANCH" >/dev/null 2>&1 || {
			note_fail "declaration" "cannot reset and push $ENROLL_BRANCH as the App"
			return 0
		}
	else
		git_as "$APP_GH" -C "$dotty_dir" push -q origin "$ENROLL_BRANCH" >/dev/null 2>&1 || {
			note_fail "declaration" "cannot push $ENROLL_BRANCH as the App"
			return 0
		}
	fi
	pr_url="$("$APP_GH" api -X POST "repos/$DOTTY_UPSTREAM_SLUG/pulls" \
		-f "title=estate: enroll $REPO_SLUG in the default-branch ruleset ($VISIBILITY)" \
		-f "head=$ENROLL_BRANCH" -f "base=$DOTTY_DEFAULT_BRANCH" \
		-f "body=$(decl_pr_body)" 2>/dev/null | jq -r '.html_url // empty' 2>/dev/null || true)"
	if [[ -z "$pr_url" ]]; then
		note_fail "declaration" "branch $ENROLL_BRANCH pushed but the PR call returned no URL"
		return 0
	fi
	DECL_PR_URL="$pr_url"
	note_fixed "declaration" "opened $pr_url"
}
declaration_pr

# ----------------------------------------------------------------------------
# Step 5 — the callers PR in the new repo (App-authored, via the provisioner)
# ----------------------------------------------------------------------------
hdr "Step 5 — callers PR in $REPO_SLUG (provision-public-repo.sh --callers, App-authored)"
[[ -r "$DECLARED_TMP" ]] || cp "$DECLARED_JSON_PATH" "$DECLARED_TMP"
callers_out="$(GH="$APP_GH" bash "$PROVISIONER" --callers --declared-json "$DECLARED_TMP" "$REPO_SLUG" 2>&1)" && callers_rc=0 || callers_rc=$?
printf '%s\n' "$callers_out" | sed 's/^/      | /'
CALLERS_PR_URL="$(printf '%s\n' "$callers_out" | sed -nE 's/^  PR    (opened|updated) (.*)$/\2/p' | head -n1)"
if [[ $callers_rc -eq 0 && -n "$CALLERS_PR_URL" ]]; then
	note_fixed "callers" "$CALLERS_PR_URL"
elif [[ $callers_rc -eq 0 ]]; then
	note_ok "callers" "already at the intended shape — no PR needed"
else
	note_fail "callers" "provision-public-repo.sh --callers exited $callers_rc (its output is above)"
fi

# ----------------------------------------------------------------------------
# Step 6 — environment + secrets (operator)
# ----------------------------------------------------------------------------
hdr "Step 6 — environment '$ENV_NAME' and secrets (operator)"
env_json="$("$OPERATOR_GH" api "repos/$REPO_SLUG/environments/$ENV_NAME" 2>/dev/null || true)"
env_policy_ok="$(printf '%s' "$env_json" | jq -r '(.deployment_branch_policy.protected_branches == false and .deployment_branch_policy.custom_branch_policies == true) // false' 2>/dev/null || echo false)"
if [[ "$env_policy_ok" == "true" ]]; then
	note_ok "environment.$ENV_NAME" "exists with custom branch policies"
else
	if jq -n '{deployment_branch_policy: {protected_branches: false, custom_branch_policies: true}}' |
		"$OPERATOR_GH" api -X PUT "repos/$REPO_SLUG/environments/$ENV_NAME" --input - >/dev/null 2>&1; then
		note_fixed "environment.$ENV_NAME" "ensured with deployment_branch_policy {protected_branches: false, custom_branch_policies: true}"
	else
		note_fail "environment.$ENV_NAME" "PUT failed"
	fi
fi
policies="$("$OPERATOR_GH" api --paginate "repos/$REPO_SLUG/environments/$ENV_NAME/deployment-branch-policies" 2>/dev/null | jq -r '.branch_policies[]?.name' 2>/dev/null || true)"
if printf '%s\n' "$policies" | grep -qxF "$DEFAULT_BRANCH"; then
	note_ok "environment.$ENV_NAME.branch-policy" "$DEFAULT_BRANCH"
else
	if jq -n --arg n "$DEFAULT_BRANCH" '{name: $n, type: "branch"}' |
		"$OPERATOR_GH" api -X POST "repos/$REPO_SLUG/environments/$ENV_NAME/deployment-branch-policies" --input - >/dev/null 2>&1; then
		note_fixed "environment.$ENV_NAME.branch-policy" "added $DEFAULT_BRANCH"
	else
		note_fail "environment.$ENV_NAME.branch-policy" "POST failed"
	fi
fi

# Secrets: EVERY value is read first; an empty read is fatal BEFORE any set.
# The values live only in these three variables, are piped (never passed as
# an argument) into gh, and are never printed.
secrets_ok=1
OPERATOR_RULES_VAL="$("$OP" read "$OPERATOR_RULES_REF" 2>/dev/null || true)"
MARGOT_APP_KEY_VAL="$("$OP" read "$MARGOT_APP_KEY_REF" 2>/dev/null || true)"
OLLIE_APP_KEY_VAL="$("$OP" read "$OLLIE_APP_KEY_REF" 2>/dev/null || true)"
[[ -n "$OPERATOR_RULES_VAL" ]] || {
	note_fail "secret.OPERATOR_RULES" "op read returned EMPTY for OPERATOR_RULES_REF — no secret set (an empty value would enroll nothing and look enrolled)"
	secrets_ok=0
}
[[ -n "$MARGOT_APP_KEY_VAL" ]] || {
	note_fail "secret.MARGOT_APP_KEY" "op read returned EMPTY for MARGOT_APP_KEY_REF — no secret set"
	secrets_ok=0
}
[[ -n "$OLLIE_APP_KEY_VAL" ]] || {
	note_fail "secret.OLLIE_APP_KEY" "op read returned EMPTY for OLLIE_APP_KEY_REF — no secret set"
	secrets_ok=0
}
set_env_secret() { # <NAME> <value>
	if printf '%s' "$2" | "$OPERATOR_GH" secret set "$1" --env "$ENV_NAME" -R "$REPO_SLUG" >/dev/null 2>&1; then
		note_fixed "secret.$1 (env $ENV_NAME)" "set (cannot verify value)"
	else
		note_fail "secret.$1 (env $ENV_NAME)" "gh secret set failed"
	fi
}
if [[ $secrets_ok -eq 1 ]]; then
	set_env_secret OPERATOR_RULES "$OPERATOR_RULES_VAL"
	set_env_secret MARGOT_APP_KEY "$MARGOT_APP_KEY_VAL"
	set_env_secret OLLIE_APP_KEY "$OLLIE_APP_KEY_VAL"
	# Margot's dispatch caller runs on workflow_run, outside any environment,
	# so the key it passes through must also exist at repository level.
	if printf '%s' "$MARGOT_APP_KEY_VAL" | "$OPERATOR_GH" secret set MARGOT_APP_KEY -R "$REPO_SLUG" >/dev/null 2>&1; then
		note_fixed "secret.MARGOT_APP_KEY (repo)" "set (cannot verify value)"
	else
		note_fail "secret.MARGOT_APP_KEY (repo)" "gh secret set failed"
	fi
else
	note_skip "secrets" "nothing set — every reference must read non-empty before any secret is written"
fi
unset OPERATOR_RULES_VAL MARGOT_APP_KEY_VAL OLLIE_APP_KEY_VAL

# ----------------------------------------------------------------------------
# Step 7 — the done-condition (printed, not run)
# ----------------------------------------------------------------------------
hdr "Step 7 — done when"
echo "  Approve, in either order:"
echo "    1. declaration PR (held HIGH by Margot — rulesets/ is self-instrument): ${DECL_PR_URL:-<not opened — see the FAIL above>}"
echo "    2. callers PR in $REPO_SLUG: ${CALLERS_PR_URL:-<not opened — see the FAIL above, or already at shape>}"
echo "  Then open a throwaway PR in $REPO_SLUG; done when CI + trusted-scan are green,"
echo "  \`margot\` is posted by margot-the-meticulous, and it is merged by ollie-the-intern[bot]."

# ----------------------------------------------------------------------------
# Summary + exit
# ----------------------------------------------------------------------------
hdr "Summary"
if [[ $FAIL_COUNT -eq 0 ]]; then
	echo "  $REPO_SLUG: every step OK / FIXED / SKIP."
	exit 0
fi
echo "  $REPO_SLUG: $FAIL_COUNT step(s) FAILed (see above)."
exit 1
