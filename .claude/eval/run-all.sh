#!/usr/bin/env bash
# Meta-runner for ~/bin/dotty/.claude/eval/
# Runs every *.test.sh in this directory; exits non-zero if any suite fails.
#
# Usage: bash ~/bin/dotty/.claude/eval/run-all.sh

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ $# -ne 0 ]]; then
	echo 'usage: run-all.sh' >&2
	exit 2
fi
suites=("$SCRIPT_DIR"/*.test.sh)

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
