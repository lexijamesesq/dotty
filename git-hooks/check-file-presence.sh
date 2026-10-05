#!/usr/bin/env bash
# check-file-presence.sh <required-file>... — every named file must exist
# at the repo root. Parameterized via the hook's own `args:` so a consumer
# repo writes `args: [README.md, LICENSE]` or `args: [README.md]` -- the
# two variants seven repos carried as byte-identical inline `bash -c`
# one-liners in their own .pre-commit-config.yaml before this.
#
# Message and exit-code convention matches the other whole-repo hooks
# shipped beside it (house-scaffold-*.sh): "BLOCKED: <what>" on stderr,
# exit 1 for a real violation, exit 2 fail-closed for a misconfiguration
# this hook cannot run meaningfully (no required files declared).
set -uo pipefail

if [[ $# -eq 0 ]]; then
	echo "BLOCKED: check-file-presence.sh: no required files given (empty hook args: [] in .pre-commit-config.yaml?)" >&2
	exit 2
fi

missing=""
for f in "$@"; do
	[[ -f "$f" ]] || missing="$missing $f"
done

if [[ -n "$missing" ]]; then
	echo "BLOCKED: missing required file(s):${missing}" >&2
	exit 1
fi
exit 0
