#!/usr/bin/env bash
# Test suite for new-repo.sh (repo root) — the estate's new-repository front door.
#
# Runs in CI, which has NO gh, NO op, NO network. The script routes every gh
# call through $OPERATOR_GH / $APP_GH and every op call through $OP; this suite
# substitutes stubs for all three. The gh stub is semi-real: `repo create`
# makes a local BARE repository, `repo clone` clones it, and the contents /
# ref / pulls endpoints answer FROM that bare repo — so the seed push, the
# declaration branch push and the provisioner's --callers reads are real git
# against real bare remotes, not canned fixtures. Writes (POST/PUT/PATCH, and
# every `secret set`) are RECORDED per role (operator / app) so a case can
# assert who wrote what; a secret's VALUE is never recorded, only its length.
#
# HARD-FAILS, never skips, on a missing dependency (jq, git, python3).
#
# Fixtures use the fictional owner `acme`. No operator PII appears.
#
# Run: bash .claude/eval/new-repo.test.sh

set -uo pipefail

# Hermetic git: no global/system config (no estate template hooks, no
# credential helpers), and a fixed noreply identity for every fixture commit.
export GIT_CONFIG_GLOBAL=/dev/null
export GIT_CONFIG_SYSTEM=/dev/null
export GIT_AUTHOR_NAME="Test Runner"
export GIT_AUTHOR_EMAIL="test@users.noreply.github.com"
export GIT_COMMITTER_NAME="Test Runner"
export GIT_COMMITTER_EMAIL="test@users.noreply.github.com"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/assert.sh"
ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

for dep in jq git python3; do
	command -v "$dep" >/dev/null 2>&1 || {
		echo "FATAL: $dep not on PATH — suite cannot run."
		exit 2
	}
done
for f in new-repo.sh provision-public-repo.sh rulesets/default-branch.json \
	.github/scripts/pre-commit-suite-merge.py .github/workflows/margot.yml \
	.github/pull_request_template.md .github/scripts/pr-body-check.py \
	repo-claude-template.md .claude/eval/gate-resolve-profile.test.sh \
	new-repo/templates/common/README.md new-repo/templates/public/LICENSE \
	new-repo/templates/private/.house-code.json; do
	[[ -e "$ROOT/$f" ]] || {
		echo "FATAL: $ROOT/$f missing — suite cannot run."
		exit 2
	}
done

TMP="$(mktemp -d -t new-repo-test.XXXXXX)"
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT INT TERM

SLUG="acme/widgets"
OWNER="acme"

# --- The dotty fixture ---------------------------------------------------------
# A checkout of "dotty" carrying exactly the files new-repo.sh reads, with a
# bare origin. Every scenario gets its OWN copy of both (the script pushes an
# enroll-* branch to origin), re-pointed at each other.
DOTTY_SRC="$TMP/dotty-src"
mkdir -p "$DOTTY_SRC"
(
	cd "$ROOT" && tar -cf - new-repo.sh provision-public-repo.sh rulesets/default-branch.json \
		.github/scripts/pre-commit-suite-merge.py .github/scripts/codeowners-drift.py \
		.github/workflows/margot.yml .github/pull_request_template.md \
		repo-claude-template.md .yamllint.yaml .markdownlint.yaml ruff.toml \
		.claude/eval/gate-resolve-profile.test.sh new-repo/templates
) | (cd "$DOTTY_SRC" && tar -xf -)
git init -q -b "main" "$DOTTY_SRC" 2>/dev/null || {
	git init -q "$DOTTY_SRC"
	git -C "$DOTTY_SRC" symbolic-ref HEAD refs/heads/main
}
assert_repo_identity "$DOTTY_SRC"
git -C "$DOTTY_SRC" add -A
git -C "$DOTTY_SRC" commit -q -m "dotty fixture"
DOTTY_BASE="$TMP/dotty-base.git"
git clone -q --bare "$DOTTY_SRC" "$DOTTY_BASE"
assert_repo_identity "$DOTTY_BASE"

# --- The stubs -----------------------------------------------------------------
BIN="$TMP/bin"
mkdir -p "$BIN"

# gh stub: NR_ROLE (operator|app), NR_STATE (scenario dir: remotes/, cap/, fix/),
# NR_OPERATOR_LOGIN, NR_APP_LOGIN.
cat >"$BIN/gh-stub" <<'STUBEOF'
#!/usr/bin/env bash
set -uo pipefail
role="${NR_ROLE:?}"
REM="$NR_STATE/remotes"; CAP="$NR_STATE/cap"; FIX="$NR_STATE/fix"
mkdir -p "$REM" "$CAP" "$FIX"
log() { printf '[%s] %s\n' "$role" "$*" >> "$CAP/requests.log"; }
bare_of() { printf '%s/%s.git' "$REM" "${1//\//__}"; }
err() { # <status> <message> — gh's real shape: JSON on stdout, non-zero exit
    printf '{"message":"%s","documentation_url":"https://docs.github.com/rest","status":"%s"}' "$2" "$1"
    exit 1
}
b64() { base64 | tr -d '\n'; }

cmd="${1:-}"; shift || true
case "$cmd" in
    auth)
        case "${1:-}" in
            status)
                if [[ "$role" == app ]]; then
                    printf 'github.com\n  ✓ Logged in to github.com account %s (GH_TOKEN)\n  - Token: ghs_stub_********************\n' "$NR_APP_LOGIN"
                else
                    printf 'github.com\n  ✓ Logged in to github.com account %s (keyring)\n  - Token: gho_stub_********************\n' "$NR_OPERATOR_LOGIN"
                fi
                exit 0 ;;
            token) echo "stub-token-$role"; exit 0 ;;
        esac
        echo "STUB: unhandled gh auth $*" >&2; exit 90 ;;
    repo)
        sub="${1:-}"; shift || true
        case "$sub" in
            create)
                slug="${1:-}"; shift || true
                [[ "$role" == operator ]] || { echo "STUB: only the operator creates repos" >&2; exit 93; }
                log "REPO_CREATE $slug $*"
                bare="$(bare_of "$slug")"
                [[ -e "$bare" ]] && err 422 "Repository already exists"
                git init -q --bare "$bare"
                git -C "$bare" symbolic-ref HEAD refs/heads/main
                vis=public
                for a in "$@"; do [[ "$a" == --private ]] && vis=private; done
                printf '%s' "$vis" > "$bare.visibility"
                echo "https://example.invalid/$slug"
                exit 0 ;;
            clone)
                slug="${1:-}"; dir="${2:-}"
                bare="$(bare_of "$slug")"
                [[ -d "$bare" ]] || err 404 "Not Found"
                git clone -q "$bare" "$dir" 2>/dev/null
                exit $? ;;
        esac
        echo "STUB: unhandled gh repo $sub" >&2; exit 90 ;;
    secret)
        [[ "${1:-}" == set ]] || { echo "STUB: unhandled gh secret $*" >&2; exit 90; }
        shift; name="${1:-}"; shift || true
        env=""; repo=""
        while [[ $# -gt 0 ]]; do
            case "$1" in
                --env|-e) env="${2:-}"; shift 2 ;;
                -R|--repo) repo="${2:-}"; shift 2 ;;
                *) shift ;;
            esac
        done
        # The value is never recorded — only that SOMETHING non-empty arrived.
        bytes="$(wc -c | tr -d ' ')"
        log "SECRET_SET $name env=${env:-<repo-level>} repo=$repo bytes=$bytes"
        exit 0 ;;
    api) ;;
    *) echo "STUB: unhandled gh $cmd" >&2; exit 90 ;;
esac

# --- gh api ---
method=GET; read_stdin=0; pos=(); fields=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        -X|--method) method="${2:-}"; shift 2 ;;
        --input) [[ "${2:-}" == "-" ]] && read_stdin=1; shift 2 ;;
        -f|--field|-F|--raw-field) fields+=("${2:-}"); shift 2 ;;
        -H|--header|--jq|-q|--template|-t) shift 2 ;;
        --paginate|--slurp|--silent) shift ;;
        -*) shift ;;
        *) pos+=("$1"); shift ;;
    esac
done
endpoint="${pos[0]:-}"
[[ -n "$endpoint" ]] || { echo "STUB: no endpoint" >&2; exit 91; }
path="${endpoint%%\?*}"
query=""
[[ "$endpoint" == *\?* ]] && query="${endpoint#*\?}"
IFS='/' read -r -a seg <<< "$path"

if [[ "$method" != GET ]]; then
    body=""
    [[ $read_stdin -eq 1 ]] && body="$(cat)"
    log "$method $path"
    printf '%s' "$body" > "$CAP/${role}_${method}_${path//\//_}.body"
    if [[ ${#fields[@]} -gt 0 ]]; then
        printf '%s\n' "${fields[@]}" > "$CAP/${role}_${method}_${path//\//_}.fields"
    fi
    case "$path" in
        repos/*/*/pulls)
            printf '{"html_url":"https://example.invalid/%s/%s/pull/1","number":1}' "${seg[1]}" "${seg[2]}"
            exit 0 ;;
        *) echo '{}'; exit 0 ;;
    esac
fi

# --- GET ---
case "$path" in
    user)
        [[ "$role" == app ]] && err 403 "Resource not accessible by integration"
        printf '{"login":"%s","id":1001,"type":"User"}' "$NR_OPERATOR_LOGIN"; exit 0 ;;
    users/*)
        login="${path#users/}"; login="${login//%5B/[}"; login="${login//%5D/]}"
        printf '{"login":"%s","id":325510841,"type":"Bot"}' "$login"; exit 0 ;;
    user/installations)
        [[ -f "$FIX/installations.json" ]] && { cat "$FIX/installations.json"; exit 0; }
        echo '{"total_count":0,"installations":[]}'; exit 0 ;;
    user/installations/*/repositories)
        id="${seg[2]}"
        [[ -f "$FIX/installation-$id-repositories.json" ]] && { cat "$FIX/installation-$id-repositories.json"; exit 0; }
        echo '{"total_count":0,"repositories":[]}'; exit 0 ;;
    repos/*/*)
        slug="${seg[1]}/${seg[2]}"
        bare="$(bare_of "$slug")"
        rest="$(IFS=/; echo "${seg[*]:3}")"
        case "$rest" in
            "")
                [[ -d "$bare" ]] || err 404 "Not Found"
                vis="$(cat "$bare.visibility" 2>/dev/null || echo public)"
                priv=false; [[ "$vis" == private ]] && priv=true
                id="$(printf '%s' "$slug" | cksum | cut -d' ' -f1)"
                printf '{"id":%s,"full_name":"%s","default_branch":"main","private":%s}' "$id" "$slug" "$priv"
                exit 0 ;;
            releases/latest) echo '{"tag_name":"v2026.09.25-6"}'; exit 0 ;;
            git/ref/heads/*)
                b="${rest#git/ref/heads/}"
                # NR_REF_MODE: 500 (server error body), net (no body, exit 1),
                # 404 (an empty repo answered 404 instead of 409), default real.
                case "${NR_REF_MODE:-}" in
                    500) err 500 "Server Error" ;;
                    net) exit 1 ;;
                esac
                if ! sha="$(git -C "$bare" rev-parse --verify -q "refs/heads/$b" 2>/dev/null)"; then
                    [[ "${NR_REF_MODE:-}" == 404 ]] && err 404 "Not Found"
                    err 409 "Git Repository is empty."
                fi
                printf '{"ref":"refs/heads/%s","object":{"sha":"%s","type":"commit"}}' "$b" "$sha"; exit 0 ;;
            contents/*)
                cpath="${rest#contents/}"
                ref=HEAD
                case "$query" in *ref=*) ref="${query#*ref=}"; ref="${ref%%&*}" ;; esac
                content="$(git -C "$bare" show "$ref:$cpath" 2>/dev/null)" || err 404 "Not Found"
                sha="$(git -C "$bare" rev-parse -q --verify "$ref:$cpath" 2>/dev/null)"
                printf '{"content":"%s","encoding":"base64","sha":"%s"}' "$(printf '%s\n' "$content" | b64)" "$sha"
                exit 0 ;;
            pulls)
                # "branch on the remote" stands in for "PR open on that branch".
                head_branch=""
                case "$query" in *head=*) head_branch="${query#*head=}"; head_branch="${head_branch%%&*}"; head_branch="${head_branch#*:}" ;; esac
                if [[ -n "$head_branch" ]] && git -C "$bare" rev-parse --verify -q "refs/heads/$head_branch" >/dev/null 2>&1; then
                    printf '[{"number":7,"html_url":"https://example.invalid/%s/pull/7"}]' "$slug"
                else
                    echo '[]'
                fi
                exit 0 ;;
            environments/default-branch)
                [[ -f "$FIX/environment.json" ]] && { cat "$FIX/environment.json"; exit 0; }
                err 404 "Not Found" ;;
            environments/default-branch/deployment-branch-policies)
                [[ -f "$FIX/branch-policies.json" ]] && { cat "$FIX/branch-policies.json"; exit 0; }
                echo '{"total_count":0,"branch_policies":[]}'; exit 0 ;;
        esac ;;
esac
echo "STUB: no canned GET response for '$endpoint'" >&2
exit 92
STUBEOF
chmod +x "$BIN/gh-stub"
printf '#!/usr/bin/env bash\nNR_ROLE=operator exec bash "%s" "$@"\n' "$BIN/gh-stub" >"$BIN/gh-operator"
printf '#!/usr/bin/env bash\nNR_ROLE=app exec bash "%s" "$@"\n' "$BIN/gh-stub" >"$BIN/gh-app"
chmod +x "$BIN/gh-operator" "$BIN/gh-app"

# op stub: `op read <ref>` prints a fixture value derived from the ref, or
# NOTHING when NR_OP_EMPTY=1 (the receipted empty-read defect).
cat >"$BIN/op" <<'OPEOF'
#!/usr/bin/env bash
[[ "${1:-}" == read ]] || { echo "STUB: only op read" >&2; exit 90; }
[[ "${NR_OP_EMPTY:-0}" == 1 ]] && exit 0
printf 'fixture-secret-for-%s' "${2##*/}"
OPEOF
chmod +x "$BIN/op"

# --- Scenario builders ---------------------------------------------------------
write_installations() { # <scenario> <claude-selection> <margot-selection|absent> <ollie-selection>
	local s="$1" c="$2" m="$3" o="$4" arr='[]'
	arr="$(jq -n --arg c "$c" '[{id: 42, app_slug: "claude-the-enduring", repository_selection: $c}]')"
	if [[ "$m" != absent ]]; then
		arr="$(printf '%s' "$arr" | jq --arg m "$m" '. + [{id: 43, app_slug: "margot-the-meticulous", repository_selection: $m}]')"
	fi
	arr="$(printf '%s' "$arr" | jq --arg o "$o" '. + [{id: 44, app_slug: "ollie-the-intern", repository_selection: $o}]')"
	printf '%s' "$arr" | jq '{total_count: length, installations: .}' >"$s/fix/installations.json"
}

write_secrets_env() { # <path> [omit-name]
	local p="$1" omit="${2:-}"
	{
		echo "# fixture secrets env"
		[[ "$omit" == OPERATOR_RULES_REF ]] || echo 'OPERATOR_RULES_REF="op://fixture-vault/operator-rules/toml"'
		[[ "$omit" == MARGOT_APP_KEY_REF ]] || echo 'MARGOT_APP_KEY_REF="op://fixture-vault/margot-app/private-key"'
		[[ "$omit" == OLLIE_APP_KEY_REF ]] || echo 'OLLIE_APP_KEY_REF="op://fixture-vault/ollie-app/private-key"'
	} >"$p"
}

# mk_scenario <name> -> prints the scenario dir. A fresh dotty checkout + bare
# origin, an empty remotes store, default fixtures (all three Apps installed
# for all repositories), a complete secrets env.
mk_scenario() {
	local s="$TMP/scen/$1"
	mkdir -p "$s/remotes" "$s/cap" "$s/fix"
	cp -R "$DOTTY_BASE" "$s/remotes/lexijamesesq__dotty.git"
	git clone -q "$s/remotes/lexijamesesq__dotty.git" "$s/checkout"
	assert_repo_identity "$s/checkout"
	write_installations "$s" all all all
	write_secrets_env "$s/new-repo.env"
	printf '%s' "$s"
}

# run_new_repo <scenario-dir> <args...> -> sets RC, OUT. Overrides via env:
# NR_OPERATOR_LOGIN, NR_APP_LOGIN, NR_OP_EMPTY, APP_GH_OVERRIDE (set to "" to
# unset), SECRETS_ENV_OVERRIDE.
run_new_repo() {
	local s="$1"
	shift
	OUT="$(cd "$s/checkout" && env NR_STATE="$s" \
		NR_OPERATOR_LOGIN="${NR_OPERATOR_LOGIN:-$OWNER}" \
		NR_APP_LOGIN="${NR_APP_LOGIN:-claude-the-enduring[bot]}" \
		NR_OP_EMPTY="${NR_OP_EMPTY:-0}" \
		NR_REF_MODE="${NR_REF_MODE:-}" \
		OPERATOR_GH="$BIN/gh-operator" \
		APP_GH="${APP_GH_OVERRIDE-$BIN/gh-app}" \
		OP="$BIN/op" \
		NEW_REPO_SECRETS_ENV="${SECRETS_ENV_OVERRIDE-$s/new-repo.env}" \
		bash ./new-repo.sh "$@" 2>&1)"
	RC=$?
}

requests() { cat "$1/cap/requests.log" 2>/dev/null || true; }
bare_show() { git -C "$1/remotes/${2//\//__}.git" show "$3" 2>/dev/null; }
bare_files() { git -C "$1/remotes/${2//\//__}.git" ls-tree -r --name-only "$3" 2>/dev/null; }

# ============================================================================
section "guards: OPERATOR_GH logged in as someone other than <owner> -> exit 2, nothing written"
S="$(mk_scenario guard-login)"
NR_OPERATOR_LOGIN="someone-else" run_new_repo "$S" "$SLUG"
assert_eq "wrong operator login exits 2" "2" "$RC"
grep -q "REFUSED: OPERATOR_GH" <<<"$OUT" && pass "refusal names OPERATOR_GH" || fail "refusal names OPERATOR_GH" "$OUT"
grep -q "someone-else" <<<"$OUT" && pass "refusal names the login it found" || fail "refusal names the login" "$OUT"
[[ ! -s "$S/cap/requests.log" ]] && pass "no write, secret or repo call was made" || fail "no calls made" "$(requests "$S")"

section "guards: APP_GH unset, or not a bot -> exit 2, nothing written"
S="$(mk_scenario guard-app)"
APP_GH_OVERRIDE="" run_new_repo "$S" "$SLUG"
assert_eq "APP_GH unset exits 2" "2" "$RC"
grep -q "REFUSED: APP_GH is not set" <<<"$OUT" && pass "refusal names the missing APP_GH" || fail "refusal names APP_GH" "$OUT"
NR_APP_LOGIN="lexi-human" run_new_repo "$S" "$SLUG"
assert_eq "APP_GH identifying as a human login exits 2" "2" "$RC"
grep -q "does not identify as a bot" <<<"$OUT" && pass "refusal says the App identity is not a bot" || fail "refusal names non-bot" "$OUT"
[[ ! -s "$S/cap/requests.log" ]] && pass "no write, secret or repo call was made" || fail "no calls made" "$(requests "$S")"

section "guards: secrets env missing / incomplete / not op:// -> exit 2 before any write"
S="$(mk_scenario guard-secrets)"
SECRETS_ENV_OVERRIDE="$S/does-not-exist.env" run_new_repo "$S" "$SLUG"
assert_eq "missing secrets env exits 2" "2" "$RC"
grep -q "secrets env .* is missing" <<<"$OUT" && pass "refusal names the missing env file" || fail "refusal names the env file" "$OUT"
write_secrets_env "$S/partial.env" OLLIE_APP_KEY_REF
SECRETS_ENV_OVERRIDE="$S/partial.env" run_new_repo "$S" "$SLUG"
assert_eq "secrets env without OLLIE_APP_KEY_REF exits 2" "2" "$RC"
grep -q "does not define OLLIE_APP_KEY_REF" <<<"$OUT" && pass "refusal names the missing reference" || fail "refusal names the reference" "$OUT"
printf 'OPERATOR_RULES_REF="not-a-reference"\nMARGOT_APP_KEY_REF="op://v/i/f"\nOLLIE_APP_KEY_REF="op://v/i/f"\n' >"$S/bad.env"
SECRETS_ENV_OVERRIDE="$S/bad.env" run_new_repo "$S" "$SLUG"
assert_eq "a non-op:// reference exits 2" "2" "$RC"
grep -q "OPERATOR_RULES_REF .* is not an op:// reference" <<<"$OUT" && pass "refusal names the malformed reference" || fail "refusal names the malformed reference" "$OUT"
[[ ! -s "$S/cap/requests.log" ]] && pass "no write, secret or repo call was made" || fail "no calls made" "$(requests "$S")"

section "guards: the dotty checkout must be on main, clean, at origin/main"
S="$(mk_scenario guard-checkout)"
git -C "$S/checkout" checkout -q -b elsewhere
run_new_repo "$S" "$SLUG"
assert_eq "checkout on another branch exits 2" "2" "$RC"
grep -q "is on 'elsewhere', not 'main'" <<<"$OUT" && pass "refusal names the branch" || fail "refusal names the branch" "$OUT"
git -C "$S/checkout" checkout -q main
echo "dirty" >>"$S/checkout/README.fixture"
run_new_repo "$S" "$SLUG"
assert_eq "a dirty checkout exits 2" "2" "$RC"
grep -q "is not clean" <<<"$OUT" && pass "refusal names the dirty tree" || fail "refusal names the dirty tree" "$OUT"
rm -f "$S/checkout/README.fixture"
git -C "$S/checkout" commit -q --allow-empty -m "ahead of origin"
run_new_repo "$S" "$SLUG"
assert_eq "a checkout ahead of origin/main exits 2" "2" "$RC"
grep -q "is not at origin/main" <<<"$OUT" && pass "refusal names the divergence from origin" || fail "refusal names divergence" "$OUT"

# ============================================================================
section "fresh PUBLIC repo: created, seeded, declared, callers PR, environment + secrets, exit 0"
S="$(mk_scenario fresh-public)"
run_new_repo "$S" --description "Widgets for the estate" "$SLUG"
assert_eq "fresh public run exits 0" "0" "$RC"
grep -q "identities = operator=acme (does the work) app=claude-the-enduring\[bot\] (authors the two PRs)" <<<"$OUT" &&
	pass "both identities printed once" || fail "identities printed" "$OUT"
grep -q "^\[operator\] REPO_CREATE acme/widgets --public --disable-wiki --description Widgets for the estate$" <(requests "$S") &&
	pass "repo created by the operator: --public --disable-wiki --description" || fail "repo create recorded" "$(requests "$S")"
grep -q "FIXED repository -> created acme/widgets (public, wiki disabled)" <<<"$OUT" && pass "reports the creation as FIXED" || fail "creation FIXED" "$OUT"
grep -q "OK    app.claude-the-enduring = installation 42 covers all repositories" <<<"$OUT" && pass "an all-repositories installation is OK" || fail "all-repos installation OK" "$OUT"

# The seed: one commit on main, by the operator's push, with the seed set.
SEED_FILES="$(bare_files "$S" "$SLUG" main)"
assert_eq "exactly one commit on the new repo's main" "1" "$(git -C "$S/remotes/acme__widgets.git" rev-list --count main)"
assert_eq "the seed commit message" "chore: estate seed" "$(git -C "$S/remotes/acme__widgets.git" log -1 --format=%s main)"
for f in .github/workflows/ci.yml .github/workflows/gate.yml .github/workflows/margot.yml .pre-commit-config.yaml \
	.yamllint.yaml .markdownlint.yaml ruff.toml \
	.gitleaks.toml .house-code.json .github/CODEOWNERS README.md CLAUDE.md LICENSE; do
	grep -qx "$f" <<<"$SEED_FILES" && pass "seed carries $f" || fail "seed carries $f" "$SEED_FILES"
done
for f in .github/workflows/ollie-merge.yml renovate.json .github/pull_request_template.md; do
	grep -qx "$f" <<<"$SEED_FILES" && fail "seed must NOT carry $f (that is --callers' surface)" "$SEED_FILES" || pass "seed leaves $f to --callers"
done
# The three lint configs are dotty's own bytes (the provisioner's sources), so
# --callers finds them at shape; seeded because the seed commit runs the
# seeded suite and the no-config 80-column defaults refuse the callers.
for f in .yamllint.yaml .markdownlint.yaml ruff.toml; do
	diff <(bare_show "$S" "$SLUG" "main:$f") "$ROOT/$f" >/dev/null && pass "seed's $f is byte-identical to dotty's (the --callers source)" || fail "seed's $f identical to dotty's" "differs"
done
grep -q "estate-ci.yml@v1" <<<"$(bare_show "$S" "$SLUG" main:.github/workflows/ci.yml)" && pass "ci.yml is a thin @v1 caller" || fail "ci.yml @v1" "$(bare_show "$S" "$SLUG" main:.github/workflows/ci.yml)"
grep -q "needs: \[universal-ci\]" <<<"$(bare_show "$S" "$SLUG" main:.github/workflows/ci.yml)" && pass "all-checks-passed needs only universal-ci" || fail "all-checks-passed needs" "$(bare_show "$S" "$SLUG" main:.github/workflows/ci.yml)"
grep -q "estate-gate.yml@v1" <<<"$(bare_show "$S" "$SLUG" main:.github/workflows/gate.yml)" && pass "gate.yml is a thin @v1 caller" || fail "gate.yml @v1" "$(bare_show "$S" "$SLUG" main:.github/workflows/gate.yml)"
diff <(bare_show "$S" "$SLUG" main:.github/workflows/margot.yml) "$ROOT/.github/workflows/margot.yml" >/dev/null &&
	pass "margot.yml is byte-identical to dotty's own (the converged canonical)" || fail "margot.yml identical" "differs"
assert_eq "README from the template" "# widgets

Widgets for the estate" "$(bare_show "$S" "$SLUG" main:README.md)"
grep -q "Copyright (c) $(date +%Y) acme" <<<"$(bare_show "$S" "$SLUG" main:LICENSE)" && pass "LICENSE is MIT with the owner and the current year" || fail "LICENSE owner/year" "$(bare_show "$S" "$SLUG" main:LICENSE | head -3)"
assert_eq ".house-code.json has no private flag" "false" "$(bare_show "$S" "$SLUG" main:.house-code.json | jq 'has("private_repo")')"
grep -q '^title = "widgets gitleaks config"$' <<<"$(bare_show "$S" "$SLUG" main:.gitleaks.toml)" && pass ".gitleaks.toml titled from the name" || fail ".gitleaks.toml title" "$(bare_show "$S" "$SLUG" main:.gitleaks.toml)"
grep -q '^path = ".gitleaks-operator-rules.toml"$' <<<"$(bare_show "$S" "$SLUG" main:.gitleaks.toml)" && pass ".gitleaks.toml carries the relative [extend] token" || fail ".gitleaks.toml token" "$(bare_show "$S" "$SLUG" main:.gitleaks.toml)"
CO="$(bare_show "$S" "$SLUG" main:.github/CODEOWNERS)"
for p in /.github/workflows/ /.pre-commit-config.yaml /.gitleaks.toml /.gitleaks.ci.toml /.house-code.json /.github/CODEOWNERS; do
	grep -qE "^$(printf '%s' "$p" | sed 's/\./\\./g')[[:space:]]+@acme$" <<<"$CO" && pass "CODEOWNERS owns $p for @acme" || fail "CODEOWNERS owns $p" "$CO"
done
grep -q '^\* ' <<<"$CO" && fail "CODEOWNERS has no catch-all" "$CO" || pass "CODEOWNERS has no catch-all"
grep -qE '^/\.claude/settings\.json' <<<"$CO" && fail "CODEOWNERS must not own an untracked settings.json (sample-shape refuses the seed commit)" "$CO" || pass "CODEOWNERS does not reference an untracked settings.json"
# The five template placeholders specifically — `${{ ... }}` in a workflow is
# GitHub's own expression syntax and legitimately survives.
grep -qE '\{\{(SLUG|NAME|OWNER|DESCRIPTION|YEAR)\}\}' <<<"$(for f in $SEED_FILES; do bare_show "$S" "$SLUG" "main:$f"; done)" &&
	fail "no unrendered {{placeholder}} survives in the seed" "$(for f in $SEED_FILES; do bare_show "$S" "$SLUG" "main:$f" | grep -nE '\{\{(SLUG|NAME|OWNER|DESCRIPTION|YEAR)\}\}' && echo "in $f"; done)" ||
	pass "no unrendered {{placeholder}} survives in the seed"
# CLAUDE.md is the template block's body, placeholders left as {…}.
CLAUDE_WANT="$(awk '/^````markdown$/ { f = 1; next } /^````$/ { f = 0 } f' "$ROOT/repo-claude-template.md")"
assert_eq "CLAUDE.md is exactly repo-claude-template.md's template block" "$CLAUDE_WANT" "$(bare_show "$S" "$SLUG" main:CLAUDE.md)"
# The pre-commit suite, built from the skeleton by pre-commit-suite-merge.py.
PCC="$(bare_show "$S" "$SLUG" main:.pre-commit-config.yaml)"
grep -q '^default_install_hook_types: \[pre-commit, pre-push, commit-msg\]$' <<<"$PCC" && pass "pre-commit: all three hook types installed" || fail "hook types" "$PCC"
grep -A1 'repo: https://github.com/lexijamesesq/dotty$' <<<"$PCC" | grep -q 'rev: v2026.09.25-6' && pass "pre-commit: dotty block pinned at dotty's latest release" || fail "dotty block rev" "$PCC"
for h in gitleaks-staged gitleaks-pre-push gitleaks-commit-msg house-code house-scaffold-no-tracked-scratch house-scaffold-sample-shape house-scaffold-sample-placeholder vale-self-narration check-yaml check-json end-of-file-fixer trailing-whitespace shellcheck ruff ruff-format shfmt yamllint markdownlint; do
	grep -qE "^      - id: $h$" <<<"$PCC" || {
		fail "pre-commit: hook $h present" "$PCC"
		continue
	}
done
pass "pre-commit: the standard suite's hook ids are all present (checked individually above)"
[[ "$(grep -A1 '^repos:$' <<<"$PCC" | sed -n 2p)" == "  - repo: "* ]] && pass "pre-commit: the first block follows repos: directly (no blank line)" || fail "blank under repos:" "$(grep -nA1 '^repos:$' <<<"$PCC")"
[[ "$(bare_show "$S" "$SLUG" main:.pre-commit-config.yaml | tail -c1 | od -An -c | tr -d ' ')" == '\n' ]] && pass "pre-commit: file ends with a newline" || fail "trailing newline" "od"

# The declaration PR: App-authored, on enroll-widgets, public shape, eval untouched.
DOTTY_BARE="$S/remotes/lexijamesesq__dotty.git"
git -C "$DOTTY_BARE" rev-parse --verify -q refs/heads/enroll-widgets >/dev/null && pass "enroll-widgets pushed to dotty" || fail "enroll-widgets pushed" "$(git -C "$DOTTY_BARE" branch)"
assert_eq "declaration commit author is the App's noreply identity" "claude-the-enduring[bot] <325510841+claude-the-enduring[bot]@users.noreply.github.com>" \
	"$(git -C "$DOTTY_BARE" log -1 --format='%an <%ae>' enroll-widgets)"
DECL="$(git -C "$DOTTY_BARE" show enroll-widgets:rulesets/default-branch.json)"
assert_eq "declaration entry: public shape, key order as existing entries" '["required_contexts","margot_enrolled","codeowners_owned"]' "$(printf '%s' "$DECL" | jq -c '.repos["acme/widgets"] | keys_unsorted')"
assert_eq "declaration entry: the public required contexts" '["all-checks-passed","trusted-scan / trusted-scan"]' "$(printf '%s' "$DECL" | jq -c '.repos["acme/widgets"].required_contexts')"
assert_eq "declaration entry: codeowners_owned is the seed's CODEOWNERS set" \
	'["/.github/workflows/","/.pre-commit-config.yaml","/.gitleaks.toml","/.gitleaks.ci.toml","/.house-code.json","/.github/CODEOWNERS"]' \
	"$(printf '%s' "$DECL" | jq -c '.repos["acme/widgets"].codeowners_owned')"
assert_eq "declaration: every other entry byte-identical (jq round trip)" "$(jq -c 'del(.repos["acme/widgets"])' <<<"$DECL")" "$(jq -c . "$ROOT/rulesets/default-branch.json")"
assert_eq "declaration: the file is formatted exactly as the shipped one (2-space indent)" "" "$(diff <(jq --indent 2 . "$ROOT/rulesets/default-branch.json") "$ROOT/rulesets/default-branch.json")"
diff <(git -C "$DOTTY_BARE" show enroll-widgets:.claude/eval/gate-resolve-profile.test.sh) "$ROOT/.claude/eval/gate-resolve-profile.test.sh" >/dev/null &&
	pass "public repo: the gate eval's private list is untouched" || fail "gate eval untouched for public" "differs"
grep -q "^\[app\] POST repos/lexijamesesq/dotty/pulls$" <(requests "$S") && pass "declaration PR opened by the APP" || fail "declaration PR by app" "$(requests "$S")"
grep -q "^\[operator\] POST .*/pulls$" <(requests "$S") && fail "the operator never opens a PR" "$(requests "$S")" || pass "the operator never opens a PR"
# The declaration PR body passes the estate's own pr-body check.
DECL_BODY="$(awk '/^body=/ { f = 1; sub(/^body=/, "") } f' "$S/cap/app_POST_repos_lexijamesesq_dotty_pulls.fields")"
jq -n --arg b "$DECL_BODY" '{pull_request: {body: $b}}' >"$S/decl-event.json"
GITHUB_EVENT_PATH="$S/decl-event.json" python3 "$ROOT/.github/scripts/pr-body-check.py" --template "$ROOT/.github/pull_request_template.md" >"$S/pr-body-check.out" 2>&1 &&
	pass "declaration PR body passes pr-body-check.py (pr-body:v1)" || fail "declaration PR body passes pr-body-check" "$(cat "$S/pr-body-check.out")"
grep -q "FIXED declaration -> opened https://example.invalid/lexijamesesq/dotty/pull/1" <<<"$OUT" && pass "declaration reported FIXED with its URL" || fail "declaration FIXED" "$OUT"

# The callers PR: the provisioner ran as the App against the seeded repo.
grep -q "^\[app\] POST repos/acme/widgets/git/refs$" <(requests "$S") && pass "callers: the provisioner cut its branch as the APP" || fail "callers branch by app" "$(requests "$S")"
for f in .github/workflows/ollie-merge.yml renovate.json .github/pull_request_template.md; do
	grep -q "^\[app\] PUT repos/acme/widgets/contents/$f$" <(requests "$S") && pass "callers: $f written by the App" || fail "callers writes $f" "$(requests "$S")"
done
for f in .github/workflows/ci.yml .github/workflows/gate.yml .github/workflows/margot.yml .pre-commit-config.yaml .yamllint.yaml .markdownlint.yaml ruff.toml; do
	grep -q "^\[app\] PUT repos/acme/widgets/contents/$f$" <(requests "$S") && fail "callers: seeded $f already at shape, must not be rewritten" "$(requests "$S")" || pass "callers: seeded $f already at shape (not rewritten)"
done
grep -q "^\[app\] POST repos/acme/widgets/pulls$" <(requests "$S") && pass "callers PR opened by the APP" || fail "callers PR by app" "$(requests "$S")"
grep -q "FIXED callers -> https://example.invalid/acme/widgets/pull/1" <<<"$OUT" && pass "callers reported FIXED with its URL" || fail "callers FIXED" "$OUT"

# Environment + secrets, by the operator.
grep -q "^\[operator\] PUT repos/acme/widgets/environments/default-branch$" <(requests "$S") && pass "environment default-branch PUT by the operator" || fail "environment PUT" "$(requests "$S")"
assert_eq "environment PUT body: custom branch policies" '{"deployment_branch_policy":{"protected_branches":false,"custom_branch_policies":true}}' \
	"$(jq -c . "$S/cap/operator_PUT_repos_acme_widgets_environments_default-branch.body")"
grep -q "^\[operator\] POST repos/acme/widgets/environments/default-branch/deployment-branch-policies$" <(requests "$S") && pass "deployment branch policy POSTed" || fail "branch policy POST" "$(requests "$S")"
assert_eq "branch policy names the default branch" '{"name":"main","type":"branch"}' "$(jq -c . "$S/cap/operator_POST_repos_acme_widgets_environments_default-branch_deployment-branch-policies.body")"
assert_eq "four secret sets recorded" "4" "$(grep -c "^\[operator\] SECRET_SET " <(requests "$S"))"
for n in OPERATOR_RULES MARGOT_APP_KEY OLLIE_APP_KEY; do
	grep -qE "^\[operator\] SECRET_SET $n env=default-branch repo=acme/widgets bytes=[1-9][0-9]*$" <(requests "$S") && pass "env secret $n set non-empty by the operator" || fail "env secret $n" "$(requests "$S")"
done
grep -qE "^\[operator\] SECRET_SET MARGOT_APP_KEY env=<repo-level> repo=acme/widgets bytes=[1-9][0-9]*$" <(requests "$S") && pass "repo-level MARGOT_APP_KEY set non-empty" || fail "repo-level MARGOT_APP_KEY" "$(requests "$S")"
grep -q "fixture-secret-for" <<<"$OUT" && fail "a secret value must never appear in the output" "leaked" || pass "no secret value appears in the output"
grep -q "set (cannot verify value)" <<<"$OUT" && pass "secret sets are reported as unverifiable, not assumed" || fail "unverifiable wording" "$OUT"
grep -qi "secret.scanning\|security_and_analysis\|security-and-analysis" <(requests "$S") && fail "secret-scanning is never touched" "$(requests "$S")" || pass "secret-scanning is never touched"
grep -q "done when CI + trusted-scan are green" <<<"$OUT" && pass "the done-condition is printed" || fail "done-condition printed" "$OUT"
grep -q "merged by ollie-the-intern\[bot\]" <<<"$OUT" && pass "the done-condition names the merger" || fail "done-condition names ollie" "$OUT"

section "the seed survives its own hooks: the estate's house hooks pass inside a clone of the seeded repo"
# On the estate machine the git template installs pre-commit's hooks into the
# seed clone, so the seed commit runs the seeded suite against itself. The
# in-repo house hooks (no network needed) run here from THIS worktree's
# git-hooks/ inside a clone of the seeded bare — receipted: the first seed
# shape was refused by sample-shape (CODEOWNERS naming an untracked
# settings.json), and the callers by yamllint/markdownlint's no-config
# defaults (hence the seeded .yamllint.yaml / .markdownlint.yaml).
SEEDCLONE="$S/seed-clone"
git clone -q "$S/remotes/acme__widgets.git" "$SEEDCLONE"
assert_repo_identity "$SEEDCLONE"
for hook in house-scaffold-sample-shape house-scaffold-sample-placeholder house-scaffold-no-tracked-scratch; do
	(cd "$SEEDCLONE" && bash "$ROOT/git-hooks/$hook.sh") >"$S/$hook.out" 2>&1 &&
		pass "seeded repo passes $hook" || fail "seeded repo passes $hook" "$(cat "$S/$hook.out")"
done
# shellcheck disable=SC2046
(cd "$SEEDCLONE" && python3 "$ROOT/git-hooks/house-code.py" $(git -C "$SEEDCLONE" ls-files)) >"$S/house-code.out" 2>&1 &&
	pass "seeded repo passes house-code" || fail "seeded repo passes house-code" "$(cat "$S/house-code.out")"
[[ -f "$SEEDCLONE/.yamllint.yaml" && -f "$SEEDCLONE/.markdownlint.yaml" ]] &&
	pass "seeded repo carries the lint configs its own yamllint/markdownlint hooks read" ||
	fail "lint configs present" "$(ls -a "$SEEDCLONE")"

section "re-run on the same state: repo OK, seed SKIP, declaration SKIP with its URL, secrets re-set, exit 0"
run_new_repo "$S" --description "Widgets for the estate" "$SLUG"
assert_eq "re-run exits 0" "0" "$RC"
grep -q "OK    repository = exists (public)" <<<"$OUT" && pass "re-run: repository OK" || fail "re-run repo OK" "$OUT"
grep -q "SKIP  seed (not a fresh repo" <<<"$OUT" && pass "re-run: seed SKIPped" || fail "re-run seed SKIP" "$OUT"
assert_eq "re-run: still exactly one commit on main" "1" "$(git -C "$S/remotes/acme__widgets.git" rev-list --count main)"
grep -q "SKIP  declaration (PR already open on enroll-widgets: https://example.invalid/lexijamesesq/dotty/pull/7)" <<<"$OUT" && pass "re-run: declaration SKIPped with the open PR's URL" || fail "re-run declaration SKIP" "$OUT"
assert_eq "re-run: only ONE declaration PR was ever opened" "1" "$(grep -c "^\[app\] POST repos/lexijamesesq/dotty/pulls$" <(requests "$S"))"
assert_eq "re-run: the repo was created once" "1" "$(grep -c "REPO_CREATE" <(requests "$S"))"
assert_eq "re-run: secrets are (re)set every run — eight sets across two runs" "8" "$(grep -c "SECRET_SET" <(requests "$S"))"

# ============================================================================
section "fresh PRIVATE repo: no LICENSE, private .house-code.json, private declaration, eval list gains the slug"
S="$(mk_scenario fresh-private)"
run_new_repo "$S" --private "$SLUG"
assert_eq "fresh private run exits 0" "0" "$RC"
grep -q "^\[operator\] REPO_CREATE acme/widgets --private --disable-wiki$" <(requests "$S") && pass "repo created --private (no description flag when none given)" || fail "repo create --private" "$(requests "$S")"
SEED_FILES="$(bare_files "$S" "$SLUG" main)"
grep -qx "LICENSE" <<<"$SEED_FILES" && fail "private seed carries no LICENSE" "$SEED_FILES" || pass "private seed carries no LICENSE"
assert_eq "private .house-code.json declares private_repo: true" "true" "$(bare_show "$S" "$SLUG" main:.house-code.json | jq '.private_repo')"
assert_eq "private .house-code.json has an empty exemptions list" "[]" "$(bare_show "$S" "$SLUG" main:.house-code.json | jq -c '.exemptions')"
assert_eq "README with no description is the heading alone" "# widgets" "$(bare_show "$S" "$SLUG" main:README.md)"
DOTTY_BARE="$S/remotes/lexijamesesq__dotty.git"
DECL="$(git -C "$DOTTY_BARE" show enroll-widgets:rulesets/default-branch.json)"
assert_eq "declaration entry: private shape, private_repo first" '["private_repo","required_contexts","margot_enrolled","codeowners_owned"]' "$(printf '%s' "$DECL" | jq -c '.repos["acme/widgets"] | keys_unsorted')"
assert_eq "declaration entry: private_repo is true" "true" "$(printf '%s' "$DECL" | jq '.repos["acme/widgets"].private_repo')"
GATE_EVAL="$(git -C "$DOTTY_BARE" show enroll-widgets:.claude/eval/gate-resolve-profile.test.sh)"
BLOCK="$(printf '%s\n' "$GATE_EVAL" | awk "/<<'PRIVATE_SLUGS'/ { f = 1; next } /^PRIVATE_SLUGS\$/ { f = 0 } f")"
grep -qx "acme/widgets" <<<"$BLOCK" && pass "the gate eval's PRIVATE_SLUGS block gained the slug" || fail "eval list gained the slug" "$BLOCK"
assert_eq "the PRIVATE_SLUGS block is sorted and unique" "$(printf '%s\n' "$BLOCK" | sort -u)" "$BLOCK"
assert_eq "the block carries the five shipped slugs plus the new one" "6" "$(printf '%s\n' "$BLOCK" | grep -c .)"
# The edited eval still runs green against the edited declaration.
EV="$S/eval-check"
mkdir -p "$EV/.claude/eval" "$EV/rulesets" "$EV/git-hooks"
cp -R "$ROOT/.claude/eval/lib" "$EV/.claude/eval/lib"
cp "$ROOT/git-hooks/gate-resolve-profile.sh" "$EV/git-hooks/"
printf '%s\n' "$GATE_EVAL" >"$EV/.claude/eval/gate-resolve-profile.test.sh"
printf '%s\n' "$DECL" >"$EV/rulesets/default-branch.json"
bash "$EV/.claude/eval/gate-resolve-profile.test.sh" >"$EV/out.txt" 2>&1 &&
	pass "the edited gate eval passes against the edited declaration" || fail "edited gate eval passes" "$(tail -15 "$EV/out.txt")"
grep -q "PASS: acme/widgets is declared private" "$EV/out.txt" && pass "the edited gate eval asserts the new slug by name" || fail "edited eval names the slug" "$(cat "$EV/out.txt")"
grep -qi "secret.scanning\|security_and_analysis\|security-and-analysis" <(requests "$S") && fail "private: secret-scanning is never touched" "$(requests "$S")" || pass "private: secret-scanning is never touched"
assert_eq "private: four secret sets recorded" "4" "$(grep -c "SECRET_SET" <(requests "$S"))"

section "PRIVATE requested but the repo exists PUBLIC: FAIL, visibility never flipped"
S="$(mk_scenario visibility-mismatch)"
run_new_repo "$S" "$SLUG"
assert_eq "precondition: public repo created" "0" "$RC"
run_new_repo "$S" --private "$SLUG"
assert_eq "asking for private on an existing public repo exits 1" "1" "$RC"
grep -q "FAIL  repository: acme/widgets exists with private=false but this run asked for private — visibility is never flipped here" <<<"$OUT" && pass "names the mismatch and refuses to flip" || fail "visibility mismatch FAIL" "$OUT"
grep -q "PATCH repos/acme/widgets$" <(requests "$S") && fail "no visibility PATCH is ever issued" "$(requests "$S")" || pass "no visibility PATCH is ever issued"

# ============================================================================
section "existing NON-EMPTY repo: seed SKIPped, nothing overwritten, the rest still ensured"
S="$(mk_scenario existing)"
# The repo exists with history the operator wrote by hand.
PRE="$TMP/pre-existing"
git init -q -b main "$PRE" 2>/dev/null || {
	git init -q "$PRE"
	git -C "$PRE" symbolic-ref HEAD refs/heads/main
}
assert_repo_identity "$PRE"
printf '# keep me\n\nhand-written before enrollment\n' >"$PRE/README.md"
printf 'name: CI\non: [push]\njobs: {}\n' >"$PRE/ci-of-my-own.yml"
git -C "$PRE" add -A
git -C "$PRE" commit -q -m "hand-written history"
git init -q --bare "$S/remotes/acme__widgets.git"
git -C "$PRE" push -q "$S/remotes/acme__widgets.git" main
run_new_repo "$S" "$SLUG"
assert_eq "existing non-empty repo: exit 0 (the seed is a SKIP, not a failure)" "0" "$RC"
grep -q "OK    repository = exists (public)" <<<"$OUT" && pass "existing repo reported OK, not created" || fail "existing repo OK" "$OUT"
grep -q "REPO_CREATE" <(requests "$S") && fail "no repo create for an existing repo" "$(requests "$S")" || pass "no repo create for an existing repo"
grep -q "SKIP  seed (not a fresh repo — main has history; the seed never overwrites)" <<<"$OUT" && pass "seed SKIPped with the reason" || fail "seed SKIP" "$OUT"
assert_eq "the hand-written history is untouched (still one commit)" "1" "$(git -C "$S/remotes/acme__widgets.git" rev-list --count main)"
assert_eq "the hand-written README is byte-identical" "$(printf '# keep me\n\nhand-written before enrollment')" "$(bare_show "$S" "$SLUG" main:README.md)"
bare_files "$S" "$SLUG" main | grep -q "^.github/workflows/ci.yml$" && fail "no seed file landed on main" "$(bare_files "$S" "$SLUG" main)" || pass "no seed file landed on main"
grep -q "^\[app\] POST repos/lexijamesesq/dotty/pulls$" <(requests "$S") && pass "the declaration PR is still opened" || fail "declaration PR still opened" "$(requests "$S")"
grep -q "SKIP  callers (no caller workflows in this repo — outside the caller lane" <<<"$OUT" && pass "callers: an un-seeded repo with no callers is left alone by the provisioner (its own rule)" || fail "callers SKIP for no-caller repo" "$OUT"
grep -q "OK    callers = already at the intended shape — no PR needed" <<<"$OUT" && pass "callers reported OK (nothing to open)" || fail "callers OK" "$OUT"
assert_eq "environment + secrets still ensured: four secret sets" "4" "$(grep -c "SECRET_SET" <(requests "$S"))"

# ============================================================================
section "the empty-branch guard decides on the HTTP status: doubt never seeds"
# Receipted: an earlier guard treated ANY non-success from the ref endpoint as
# "empty" and pushed the seed on top of real history behind a 500.
mk_history_repo() { # <scenario> — a bare acme/widgets with one real commit
	local pre="$TMP/history-$1"
	git init -q -b main "$pre" 2>/dev/null || {
		git init -q "$pre"
		git -C "$pre" symbolic-ref HEAD refs/heads/main
	}
	assert_repo_identity "$pre"
	printf '# keep me\n' >"$pre/README.md"
	git -C "$pre" add -A
	git -C "$pre" commit -q -m "real history"
	git init -q --bare "$TMP/scen/$1/remotes/acme__widgets.git"
	git -C "$pre" push -q "$TMP/scen/$1/remotes/acme__widgets.git" main
}
S="$(mk_scenario ref-500)"
mk_history_repo ref-500
NR_REF_MODE=500 run_new_repo "$S" "$SLUG"
assert_eq "HTTP 500 from the ref endpoint: the run exits 1" "1" "$RC"
grep -q "FAIL  seed: cannot determine whether main is empty (gh exit 1, HTTP status '500') — never seeded on doubt" <<<"$OUT" && pass "500: FAIL names the doubt and the status" || fail "500: FAIL wording" "$OUT"
grep -q "FIXED seed" <<<"$OUT" && fail "500: nothing was seeded" "$OUT" || pass "500: nothing was seeded"
assert_eq "500: the real history is untouched (still one commit)" "1" "$(git -C "$S/remotes/acme__widgets.git" rev-list --count main)"
assert_eq "500: the real README is byte-identical" "# keep me" "$(bare_show "$S" "$SLUG" main:README.md)"
[[ -d "$S/remotes/acme__widgets.git" ]] && ! bare_files "$S" "$SLUG" main | grep -q "ci.yml" && pass "500: no seed file on main" || fail "500: no seed file on main" "$(bare_files "$S" "$SLUG" main)"
S="$(mk_scenario ref-net)"
mk_history_repo ref-net
NR_REF_MODE=net run_new_repo "$S" "$SLUG"
assert_eq "network-style failure (no body, non-zero exit): the run exits 1" "1" "$RC"
grep -q "FAIL  seed: cannot determine whether main is empty (gh exit 1, HTTP status 'none') — never seeded on doubt" <<<"$OUT" && pass "net: FAIL names the doubt with no status" || fail "net: FAIL wording" "$OUT"
assert_eq "net: the real history is untouched (still one commit)" "1" "$(git -C "$S/remotes/acme__widgets.git" rev-list --count main)"
grep -q "FIXED seed" <<<"$OUT" && fail "net: nothing was seeded" "$OUT" || pass "net: nothing was seeded"
S="$(mk_scenario ref-404)"
NR_REF_MODE=404 run_new_repo "$S" "$SLUG"
assert_eq "a confirmed 404 on a fresh repo: seeds, exit 0" "0" "$RC"
grep -q "FIXED seed -> pushed 'chore: estate seed'" <<<"$OUT" && pass "404: the seed was pushed" || fail "404: seed pushed" "$OUT"
assert_eq "404: one seed commit on main" "1" "$(git -C "$S/remotes/acme__widgets.git" rev-list --count main)"
# The 409 ("Git Repository is empty") path is the stub's default and is what
# every fresh-repo case above exercised; the 200 path is the existing-repo case.

# ============================================================================
section "EMPTY op read: exit 1, NO gh secret set recorded (the receipted defect)"
S="$(mk_scenario op-empty)"
NR_OP_EMPTY=1 run_new_repo "$S" "$SLUG"
assert_eq "an empty op read exits 1" "1" "$RC"
grep -q "SECRET_SET" <(requests "$S") && fail "NO secret was set after an empty read" "$(requests "$S")" || pass "NO secret was set after an empty read"
grep -q "FAIL  secret.OPERATOR_RULES: op read returned EMPTY for OPERATOR_RULES_REF" <<<"$OUT" && pass "FAIL names the empty reference" || fail "FAIL names the reference" "$OUT"
grep -q "SKIP  secrets (nothing set — every reference must read non-empty before any secret is written)" <<<"$OUT" && pass "states that nothing was set" || fail "nothing-set wording" "$OUT"
grep -q "^\[operator\] PUT repos/acme/widgets/environments/default-branch$" <(requests "$S") && pass "the environment itself was still ensured" || fail "environment ensured" "$(requests "$S")"
grep -q "1 step(s) FAILed\|[0-9] step(s) FAILed" <<<"$OUT" && pass "summary counts the failure" || fail "summary counts failure" "$OUT"

# ============================================================================
section "App coverage: a 'selected' installation without the repo gets it added; an App with NO installation FAILs"
S="$(mk_scenario app-coverage)"
write_installations "$S" selected absent all
jq -n '{total_count: 1, repositories: [{id: 1, full_name: "acme/other"}]}' >"$S/fix/installation-42-repositories.json"
run_new_repo "$S" "$SLUG"
assert_eq "an App with no installation makes the run exit 1" "1" "$RC"
REPO_ID="$(printf '%s' "$SLUG" | cksum | cut -d' ' -f1)"
grep -q "^\[operator\] PUT user/installations/42/repositories/$REPO_ID$" <(requests "$S") && pass "claude-the-enduring (selected): the repo was ADDED to installation 42" || fail "PUT add to installation" "$(requests "$S")"
grep -q "FIXED app.claude-the-enduring -> added acme/widgets to installation 42 (selected repositories)" <<<"$OUT" && pass "reported as FIXED" || fail "app FIXED" "$OUT"
grep -q "FAIL  app.margot-the-meticulous: no installation of this App for acme — install it from the App's page in the GitHub UI" <<<"$OUT" && pass "margot-the-meticulous (no installation): FAIL naming the App and the UI act" || fail "app FAIL" "$OUT"
grep -q "OK    app.ollie-the-intern = installation 44 covers all repositories" <<<"$OUT" && pass "ollie-the-intern (all): OK" || fail "ollie OK" "$OUT"
grep -q "PUT user/installations/44/" <(requests "$S") && fail "an all-repositories installation is never written to" "$(requests "$S")" || pass "an all-repositories installation is never written to"
# A second run: the fixture now lists the repo as covered -> OK, no PUT.
jq -n '{total_count: 2, repositories: [{id: 1, full_name: "acme/other"}, {id: 2, full_name: "acme/widgets"}]}' >"$S/fix/installation-42-repositories.json"
run_new_repo "$S" "$SLUG"
grep -q "OK    app.claude-the-enduring = installation 42 (selected repositories) already includes acme/widgets" <<<"$OUT" && pass "once covered, the selected installation is OK" || fail "selected covered OK" "$OUT"
assert_eq "no second PUT once covered" "1" "$(grep -c "PUT user/installations/42/repositories/" <(requests "$S"))"

finish
