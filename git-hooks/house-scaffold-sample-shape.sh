#!/usr/bin/env bash
# house-scaffold-sample-shape.sh — every operator-config reference found in a
# tracked file (CLAUDE.md, settings*.json, or a name ending in "config"
# followed by a .json/.yaml/.yml extension) must have a tracked counterpart
# or a *.sample.*/*.example.* shape. Ported from
# gate-mechanical.sh's Step 1 (gate.md § Scaffold, A6); the verb's own copy
# retires once this hook covers every consumer.
#
# pass_filenames: false — this hook always reads the whole tracked tree
# itself (`git ls-files`), so pre-commit's own `exclude:` config has no file
# list to filter here. --exclude <extended-regex> (repeatable) is this
# hook's own exemption path: a repo passes it via the hook's `args:` in its
# .pre-commit-config.yaml to keep a file's CONTENT out of the reference scan
# — the shape for a test suite whose fixtures deliberately contain
# config-name-like strings that are not real references (never for hiding a
# genuine missing sample; the file still counts toward tracked_stripped and
# sample_basenames either way).
set -uo pipefail

EXCLUDES=()
while [[ "${1:-}" == "--exclude" ]]; do
    EXCLUDES+=("$2"); shift 2
done

TRACKED="$(git ls-files)"

tracked_stripped=$(printf '%s\n' "${TRACKED}" | while read -r p; do b=$(basename "$p"); echo "${b#.}"; done | sort -u)
# Sample shapes come in two conventions: *.sample.* and *.example.* — strip
# either marker to get the basename the sample stands in for.
sample_basenames=$(printf '%s\n' "${TRACKED}" | { grep -E '\.(sample|example)\.' || true; } | while read -r p; do basename "$p"; done | sed -E 's/\.(sample|example)(\.[^.]+)$/\2/' | sort -u)

CONTENT_SOURCES="${TRACKED}"
for pat in "${EXCLUDES[@]+"${EXCLUDES[@]}"}"; do
    CONTENT_SOURCES="$(printf '%s\n' "${CONTENT_SOURCES}" | grep -Ev "${pat}" || true)"
done

# Filtered to regular files (a tracked directory-symlink target aborts `cat`
# under pipefail — a bug class the publish verb's own equivalent step
# documents and works around the same way).
refs=$(printf '%s\n' "${CONTENT_SOURCES}" \
  | { while IFS= read -r f; do [[ -f "$f" ]] && cat "$f"; done; true; } \
  | { grep -ohE '\bCLAUDE\.md\b|\bsettings(\.[A-Za-z]+)*\.json\b|\b[A-Za-z0-9_-]*config\.(json|ya?ml)\b' || true; } \
  | sed -E 's/^\.//' | sort -u)

missing=""
while IFS= read -r ref; do
    [[ -z "${ref}" ]] && continue
    case "${ref}" in *.sample.*|*.example.*) continue ;; esac
    printf '%s\n' "${tracked_stripped}" | grep -qx "${ref}" && continue
    printf '%s\n' "${sample_basenames}" | grep -qx "${ref}" && continue
    # Suffix tolerance: prose often refers to a longer sampled name by its
    # tail (a tool's generic conf filename standing for the repo's longer
    # example counterpart).
    printf '%s\n' "${sample_basenames}" | grep -qE "(^|[-.])$(printf '%s' "${ref}" | sed 's/\./\\./g')$" && continue
    missing="${missing} ${ref}"
done <<< "${refs}"

if [[ -n "${missing}" ]]; then
    echo "BLOCKED: operator-config referenced without sample shape:${missing}" >&2
    exit 1
fi
exit 0
