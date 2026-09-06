#!/usr/bin/env bash
# house-scaffold-sample-shape.sh — every operator-config reference found in a
# tracked file (CLAUDE.md, settings*.json, *config.json/yaml) must have a
# tracked counterpart or a *.sample.*/*.example.* shape. Ported from
# gate-mechanical.sh's Step 1 (gate.md § Scaffold, A6); the verb's own copy
# retires once this hook covers every consumer (LEX-753).
set -uo pipefail

TRACKED="$(git ls-files)"

tracked_stripped=$(printf '%s\n' "${TRACKED}" | while read -r p; do b=$(basename "$p"); echo "${b#.}"; done | sort -u)
# Sample shapes come in two conventions: *.sample.* and *.example.* — strip
# either marker to get the basename the sample stands in for.
sample_basenames=$(printf '%s\n' "${TRACKED}" | { grep -E '\.(sample|example)\.' || true; } | while read -r p; do basename "$p"; done | sed -E 's/\.(sample|example)(\.[^.]+)$/\2/' | sort -u)

# Filtered to regular files (a tracked directory-symlink target aborts `cat`
# under pipefail — see gate-mechanical.sh's own comment on this, receipted
# LEX-702).
refs=$(printf '%s\n' "${TRACKED}" \
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
