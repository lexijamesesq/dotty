#!/usr/bin/env bash
# Native workflow tools with cheap staged selection, including deleted configs.
set -euo pipefail
tool=${1:?usage: workflow-check.sh actionlint|zizmor [changed files...]}
shift
case "$tool" in actionlint | zizmor) ;; *)
	echo "Unknown workflow checker: $tool" >&2
	exit 2
	;;
esac
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
paths=$(mktemp)
trap 'rm -f "$paths"' EXIT
# pre-commit filters deleted files out of argv. Name-only without rename folding
# preserves both sides and requires no whole-tree scan on unrelated commits.
git diff --cached --name-only --no-renames -z >"$paths"
files=()
if [[ $# -gt 0 ]]; then files=("$@"); fi
while IFS= read -r -d '' path; do files+=("$path"); done <"$paths"
all=false
selected=()
if [[ ${#files[@]} -gt 0 ]]; then
	for path in "${files[@]}"; do
		case "$path" in
		.github/workflows/*.yml | .github/workflows/*.yaml | .github/actions/*/action.yml | .github/actions/*/action.yaml)
			# A reusable workflow or action can change its callers' contract.
			# Let actionlint validate the small native workflow component.
			if [[ "$tool" == actionlint ]]; then
				all=true
			elif [[ -f "$path" ]]; then selected+=("$path"); fi
			;;
		.github/actionlint.y*ml) [[ "$tool" != actionlint ]] || all=true ;;
		.github/zizmor.y*ml) [[ "$tool" != zizmor ]] || all=true ;;
		git-hooks/workflow-check.sh) all=true ;;
		esac
	done
fi
if [[ "$all" == true ]]; then
	selected=()
	git ls-files -z .github/workflows .github/actions >"$paths"
	while IFS= read -r -d '' path; do
		[[ -f "$path" ]] || continue
		case "$path" in
		.github/workflows/*.yml | .github/workflows/*.yaml) selected+=("$path") ;;
		.github/actions/*/action.yml | .github/actions/*/action.yaml) [[ "$tool" != zizmor ]] || selected+=("$path") ;;
		esac
	done <"$paths"
fi
# argv and the index can name the same file; invoke each input only once.
unique=()
if [[ ${#selected[@]} -gt 0 ]]; then
	for path in "${selected[@]}"; do
		seen=false
		if [[ ${#unique[@]} -gt 0 ]]; then
			for prior in "${unique[@]}"; do [[ "$prior" != "$path" ]] || seen=true; done
		fi
		[[ "$seen" == true ]] || unique+=("$path")
	done
	selected=("${unique[@]}")
fi
rm -f "$paths"
trap - EXIT
[[ ${#selected[@]} -gt 0 ]] || exit 0
command -v "$tool" >/dev/null || {
	echo "BLOCKED: $tool is unavailable; run checkout preparation" >&2
	exit 2
}
if [[ "$tool" == actionlint ]]; then
	command -v shellcheck >/dev/null || {
		echo "BLOCKED: ShellCheck is unavailable for actionlint inline-shell checks" >&2
		exit 2
	}
	exec actionlint -shellcheck "$(command -v shellcheck)" "${selected[@]}"
else
	unset GH_TOKEN GITHUB_TOKEN
	exec zizmor --offline --min-confidence high --config "$here/../.github/zizmor.yml" "${selected[@]}"
fi
