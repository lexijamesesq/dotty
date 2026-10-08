#!/usr/bin/env bash
# Meta-runner for ~/bin/dotty/.claude/eval/
# Runs every *.test.sh in this directory; exits non-zero if any suite fails.
#
# Usage: bash ~/bin/dotty/.claude/eval/run-all.sh

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Native push entries name one component. Manual no-argument use retains the
# existing full runner, but no pre-push hook attaches that blanket mode.
component=${2:-}
suites=()
case "${1:-manual}" in
manual) for suite in "$SCRIPT_DIR"/*.test.sh; do suites+=("$suite"); done ;;
--push)
	case "$component" in
	hooks) names="check-file-presence fixture-isolation gitleaks-hooks gitleaks-range-scan house-code local-check-config pr-body-check prepare-checkout project-push vale-self-narration web-lint-configs workflow-check" ;;
	workflows) names="classification-compatibility estate-margot-queued-check estate-ollie-merge estate-self-instrument-alert floor-triage-decision gate-resolve-profile margot-floor-gate ollie-state" ;;
	release) names="next-calendar-tag release-version" ;;
	settings) names="ci-caller-merge converge-enrolled new-repo provision-public-repo" ;;
	*)
		echo "Unknown dotty component: $component" >&2
		exit 2
		;;
	esac
	paths=$(mktemp)
	trap 'rm -f "$paths"' EXIT
	# Keep the parent's Git routing until selection is complete. Native ranges
	# include deleted/renamed paths even though pre-commit omits them from argv.
	if [[ -n "${PRE_COMMIT_FROM_REF:-}" && -n "${PRE_COMMIT_TO_REF:-}" ]]; then
		git diff --name-only --no-renames -z "$PRE_COMMIT_FROM_REF" "$PRE_COMMIT_TO_REF" >"$paths" || exit 2
	elif [[ -n "${PRE_COMMIT_REMOTE_NAME:-}" && -n "${PRE_COMMIT_LOCAL_BRANCH:-}" ]]; then
		# Native pre-commit's first/root push has no from/to pair. Use the
		# same outgoing ancestry boundary and include historical deletions.
		git rev-parse --verify "$PRE_COMMIT_LOCAL_BRANCH^{commit}" >/dev/null || exit 2
		git log --format= --name-only --no-renames -z "$PRE_COMMIT_LOCAL_BRANCH" --not "--remotes=$PRE_COMMIT_REMOTE_NAME" >"$paths" || exit 2
	else
		echo 'Cannot select push checks: native outgoing range is unavailable.' >&2
		exit 2
	fi
	relevant=false
	while IFS= read -r -d '' path; do
		# git log inserts a line separator before each name list.
		path=${path#$'\n'}
		case "$path" in
		.pre-commit-config.yaml | .claude/eval/run-all.sh | .claude/eval/lib/*) relevant=true ;;
		esac
		for name in $names; do [[ "$path" != ".claude/eval/$name.test.sh" ]] || relevant=true; done
		case "$component:$path" in
		hooks:git-hooks/* | hooks:scripts/prepare-checkout.sh | hooks:.pre-commit-hooks.yaml | hooks:.github/scripts/pr-body-check.py | hooks:.github/pull_request_template.md | hooks:.github/actions/* | hooks:.github/actionlint.y*ml | hooks:.github/zizmor.y*ml | hooks:.vale* | hooks:styles/* | hooks:ruff.toml | hooks:.shellcheckrc | hooks:.claude/eval/.shellcheckrc | hooks:.yamllint.yaml | hooks:.markdownlint.yaml | hooks:biome.json | hooks:.prettierrc*) relevant=true ;;
		workflows:.github/workflows/* | workflows:.github/actions/* | workflows:.github/scripts/margot-floor-gate.py | workflows:.github/scripts/ollie-state.py | workflows:git-hooks/gate-resolve-profile.sh | workflows:rulesets/*) relevant=true ;;
		release:git-hooks/release-version.sh | release:.github/scripts/next-calendar-tag.sh | release:.github/scripts/tag-plugin-release.sh | release:.github/scripts/check-plugin-version.sh | release:.github/workflows/*release* | release:scripts/prepare-checkout.sh | release:ruff.toml | release:.shellcheckrc | release:.yamllint.yaml | release:.markdownlint.yaml | release:biome.json | release:.prettierrc | release:AGENTS.md | release:repo-claude-template.md | release:.vale.ini | release:styles/*) relevant=true ;;
		settings:provision-public-repo.sh | settings:new-repo.sh | settings:rulesets/* | settings:.github/scripts/* | settings:.github/workflows/* | settings:git-hooks/* | settings:repo-*-template* | settings:.gitleaks.toml | settings:.pre-commit-hooks.yaml | settings:biome.json | settings:.prettierrc* | settings:.markdownlint.yaml | settings:.yamllint.yaml | settings:ruff.toml | settings:.shellcheckrc | settings:AGENTS.md | settings:new-repo/* | settings:.claude/eval/gate-resolve-profile.test.sh | settings:.github/pull_request_template.md) relevant=true ;;
		esac
	done <"$paths"
	rm -f "$paths"
	trap - EXIT
	[[ "$relevant" == true ]] || {
		echo "dotty $component: no affected inputs"
		exit 0
	}
	for name in $names; do suites+=("$SCRIPT_DIR/$name.test.sh"); done
	;;
*)
	echo 'usage: run-all.sh [--push hooks|workflows|release|settings]' >&2
	exit 2
	;;
esac

if [[ -t 1 ]]; then
	GREEN=$'\033[0;32m'
	RED=$'\033[0;31m'
	BOLD=$'\033[1m'
	RESET=$'\033[0m'
else
	GREEN=""
	RED=""
	BOLD=""
	RESET=""
fi

TOTAL_SUITES=0
PASSED_SUITES=0
FAILED_SUITES=()
START_TIME=$(date +%s)

for suite in "${suites[@]}"; do
	[[ -f "$suite" ]] || {
		echo "Missing retained suite: $suite" >&2
		exit 2
	}
	TOTAL_SUITES=$((TOTAL_SUITES + 1))
	name=$(basename "$suite" .test.sh)
	echo "${BOLD}>>> $name${RESET}"
	if bash "$SCRIPT_DIR/lib/fixture-env.sh" bash "$suite"; then
		PASSED_SUITES=$((PASSED_SUITES + 1))
	else
		FAILED_SUITES+=("$name")
	fi
	echo ""
done

ELAPSED=$(($(date +%s) - START_TIME))

echo "${BOLD}=== Summary ===${RESET}"
echo "Suites: $PASSED_SUITES/$TOTAL_SUITES passed (${ELAPSED}s)"
if [[ ${#FAILED_SUITES[@]} -eq 0 ]]; then
	echo "${GREEN}All suites passed.${RESET}"
	exit 0
else
	echo "${RED}Failed suites:${RESET}"
	for s in "${FAILED_SUITES[@]}"; do echo "  - $s"; done
	exit 1
fi
