#!/usr/bin/env bash
# house-scaffold-sample-placeholder.sh — every tracked *.sample.* file must
# carry a placeholder marker. Ported from gate-mechanical.sh's Step 2
# (gate.md § Scaffold, A7); the verb's own copy retires once this hook
# covers every consumer.
#
# Known gap, inherited unchanged from the verb (documented, not fixed
# speculatively): *.example.* files count as sample shapes for the
# sibling sample-shape hook but are not swept here — their marker
# conventions differ (env-style values).
set -uo pipefail

TRACKED="$(git ls-files)"
BAD=""
while IFS= read -r f; do
    [[ -z "${f}" ]] && continue
    grep -qE 'TODO:|path/to/your|YOUR_VALUE_HERE|<[A-Z_]+>' "${f}" || BAD="${BAD} ${f}"
done < <(printf '%s\n' "${TRACKED}" | { grep -E '\.sample\.' || true; })

if [[ -n "${BAD}" ]]; then
    echo "BLOCKED: sample file(s) with zero placeholder markers:${BAD}" >&2
    exit 1
fi
exit 0
