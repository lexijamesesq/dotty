#!/usr/bin/env bash
# Trusted producer tools scan PR data; no hook/config/script from that tree runs.
set -euo pipefail
kind=${1:?history or text required}
repo=${2:?PR data checkout required}
slug=${3:?repository required}
producer=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
[[ "$kind" == history || "$kind" == text ]] || exit 2
repo=$(cd "$repo" && pwd)
[[ -r "$producer/.gitleaks.toml" ]] || {
	echo 'trusted scan: producer config missing' >&2
	exit 1
}
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
export XDG_CONFIG_HOME="$scratch/config"
export GL_CONFIG_PATH="$producer/.gitleaks.toml"
export GL_IGNORE_PATH="$scratch/ignore"
# Ignore rules come only from reviewed producer source, never the PR checkout.
if [[ -f "$producer/.gitleaksignore" ]]; then cp "$producer/.gitleaksignore" "$GL_IGNORE_PATH"; else : >"$GL_IGNORE_PATH"; fi
unset GL_NO_OVERLAY GL_OVERLAY_ONLY GL_TEXT_FILE
profile=$(bash "$producer/git-hooks/gate-resolve-profile.sh" "$slug" "$producer/rulesets/default-branch.json")
case "$profile" in
GATE_SKIP_OVERLAY=0) overlay=true ;;
GATE_SKIP_OVERLAY=1) overlay=false ;;
*)
	echo 'trusted scan: invalid profile' >&2
	exit 1
	;;
esac
if [[ "$overlay" == true ]]; then
	[[ -n "${OPERATOR_RULES:-}" ]] || {
		echo 'trusted scan: required overlay unavailable' >&2
		exit 1
	}
	mkdir -p "$XDG_CONFIG_HOME/gitleaks"
	(
		umask 077
		printf '%s' "$OPERATOR_RULES" >"$XDG_CONFIG_HOME/gitleaks/operator-rules.toml"
	)
fi
unset OPERATOR_RULES
cd "$repo"
failed=0
scan() {
	local script=$1
	if ! GL_NO_OVERLAY=1 bash "$producer/git-hooks/$script" >"$scratch/capture" 2>&1; then
		echo "::error::trusted $kind scan failed (base rules; content withheld)" >&2
		failed=1
	fi
	if [[ "$overlay" == true ]] && ! GL_OVERLAY_ONLY=1 bash "$producer/git-hooks/$script" >"$scratch/capture" 2>&1; then
		echo "::error::trusted $kind scan failed (operator rules; content withheld)" >&2
		failed=1
	fi
}
if [[ "$kind" == history ]]; then
	export GL_RANGE_BASE=${4:?base SHA required} GL_RANGE_HEAD=${5:?head SHA required}
	[[ "$GL_RANGE_BASE" =~ ^[0-9a-f]{40}$ && "$GL_RANGE_HEAD" =~ ^[0-9a-f]{40}$ ]] || exit 2
	scan gitleaks-range-scan.sh
	# Fail visibly on unreadable history; do not turn a failed command into empty text.
	git log --format=%B "$GL_RANGE_BASE..$GL_RANGE_HEAD" >"$scratch/messages"
	export GL_TEXT_FILE="$scratch/messages"
else
	export GL_TEXT_FILE=${4:?package-produced current text file required}
	[[ "$GL_TEXT_FILE" == /* && -f "$GL_TEXT_FILE" ]] || exit 2
fi
scan gitleaks-commit-msg.sh
exit "$failed"
