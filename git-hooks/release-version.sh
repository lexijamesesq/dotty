#!/usr/bin/env bash
# Native pre-push adapter for existing version checks, using remote tags only.
set -euo pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
kind=${1:?usage: release-version.sh plugin|package directory name}
directory=${2:?missing directory}
name=${3:?missing name}
case "$kind" in plugin | package) ;; *)
	echo 'Unknown release kind' >&2
	exit 2
	;;
esac
[[ "$name" =~ ^[a-zA-Z0-9][a-zA-Z0-9_-]*$ ]] || {
	echo 'Invalid release name' >&2
	exit 2
}
case "$directory" in .. | /* | ../* | */../* | */..)
	echo 'Release directory must stay inside the checkout' >&2
	exit 2
	;;
esac
outgoing=${PRE_COMMIT_TO_REF:-${PRE_COMMIT_LOCAL_BRANCH:-}}
[[ -n "$outgoing" ]] || {
	echo 'Cannot check version: native outgoing ref is unavailable' >&2
	exit 2
}
[[ "$outgoing" != 0000000000000000000000000000000000000000 ]] || exit 0
# A promisor repository may fetch missing objects during a read. Refuse it
# before resolving commits; verification must not repair the author's store.
export GIT_NO_LAZY_FETCH=1
if git config --get extensions.partialClone >/dev/null || git config --bool --get-regexp '^remote\..*\.promisor$' | grep -q ' true$'; then
	echo 'Cannot check version from incomplete promisor history' >&2
	exit 2
fi
outgoing=$(git rev-parse --verify "$outgoing^{commit}")
[[ $(git rev-parse --is-shallow-repository) == false ]] || {
	echo 'Cannot check version from shallow history' >&2
	exit 2
}
git rev-list "$outgoing" >/dev/null
remote=${PRE_COMMIT_REMOTE_URL:-${PRE_COMMIT_REMOTE_NAME:-}}
[[ -n "$remote" ]] || {
	echo 'Cannot refresh tags: native push remote is unavailable' >&2
	exit 2
}
# Resolve a configured remote before leaving the author's routing/config context.
if [[ -z "${PRE_COMMIT_REMOTE_URL:-}" ]]; then remote=$(git remote get-url --push "$remote"); fi
source_root=$(git rev-parse --show-toplevel)
common=$(cd "$(git rev-parse --git-common-dir)" && pwd)
worktree_config="$(git rev-parse --absolute-git-dir)/config.worktree"
local_vars=$(git rev-parse --local-env-vars)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
(
	# Only temporary-repository routing is reset. Keep credential selectors,
	# config overlays, SSH agents and the invoking agent's authenticated context.
	for variable in $local_vars; do
		case "$variable" in GIT_CONFIG_PARAMETERS | GIT_CONFIG_COUNT) ;; *) unset "$variable" ;; esac
	done
	unset GIT_NAMESPACE GIT_TEMPLATE_DIR
	git -c core.hooksPath=/dev/null clone --quiet --shared --no-checkout --template= "$source_root" "$work/check"
	cd "$work/check"
	export GIT_DIR="$work/check/.git" GIT_WORK_TREE="$work/check"
	# A local-only or stale tag must never masquerade as a refreshed release.
	git for-each-ref --format='delete %(refname)' refs/tags | git -c core.hooksPath=/dev/null update-ref --stdin
	# Repository transport settings belong below the invoking agent's environment
	# overlays. A command-line include would wrongly outrank those credentials.
	git config --local --add include.path "$common/config"
	[[ ! -f "$worktree_config" ]] || git config --local --add include.path "$worktree_config"
	git -c core.bare=false -c "core.worktree=$work/check" -c core.hooksPath=/dev/null \
		fetch --quiet --no-tags "$remote" "+refs/tags/${name}--v*:refs/tags/${name}--v*"
	[[ $(git rev-parse --is-shallow-repository) == false ]] || {
		echo 'Refreshed release history is shallow' >&2
		exit 2
	}
	git -c core.bare=false -c core.hooksPath=/dev/null checkout --quiet --detach "$outgoing"
	case "$kind" in
	plugin) bash "$here/../.github/scripts/check-plugin-version.sh" "$directory" "$name" ;;
	package)
		# This checker belongs to the package consumer (currently Eve), and is
		# read from the exact outgoing checkout rather than the producer.
		[[ -f .github/scripts/check-package-version.sh ]] || {
			echo 'BLOCKED: package consumer must provide .github/scripts/check-package-version.sh at the pushed revision' >&2
			exit 2
		}
		bash .github/scripts/check-package-version.sh "$directory" "$name"
		;;
	esac
)
