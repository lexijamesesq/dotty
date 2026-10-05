#!/usr/bin/env bash
# check-file-presence.sh <required-file>... — every named file must exist
# at the repo root. Parameterized via the hook's own `args:` so a consumer
# repo writes `args: [README.md, LICENSE]` or `args: [README.md]` -- the
# two variants seven repos carried as byte-identical inline `bash -c`
# one-liners in their own .pre-commit-config.yaml before this.
#
# Preserves the original message format ("Missing required files:<list>")
# verbatim, so a repo migrating to this hook sees the same failure text
# it already had.
set -uo pipefail

if [[ $# -eq 0 ]]; then
	echo "FATAL: check-file-presence.sh: no required files given (empty hook args: [] in .pre-commit-config.yaml?)" >&2
	exit 2
fi

missing=""
for f in "$@"; do
	[[ -f "$f" ]] || missing="$missing $f"
done

if [[ -n "$missing" ]]; then
	echo "Missing required files:$missing"
	exit 1
fi
exit 0
