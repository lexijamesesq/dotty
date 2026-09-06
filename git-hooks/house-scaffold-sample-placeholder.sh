#!/usr/bin/env bash
# house-scaffold-sample-placeholder.sh — every tracked *.sample.* file must
# carry a placeholder marker. Ported from gate-mechanical.sh's Step 2
# (gate.md § Scaffold, A7); the verb's own copy retires once this hook
# covers every consumer.
#
# The marker set widened once already (rollout receipt): the original four
# literals (TODO:, path/to/your, YOUR_VALUE_HERE, <CAPS>) missed two
# conventions real sample files across three separate consumer repos
# actually use — an inline `YOUR_SOMETHING` token with no surrounding angle
# brackets, and a `[Bracketed Description]` placeholder. Both are common,
# unambiguous marker shapes; recognizing them is a precision fix, not a
# loosening of what counts as "has a placeholder."
#
# Applicability: this rule applies to every tracked *.sample.* file, no
# exceptions by path shape. A one-off — a sample that carries the suffix
# but is no longer a fill-in-the-blank template (a deprecated stub still
# referenced elsewhere, so it can't simply be deleted) — goes through this
# repo's .house-code.json `exemptions[]` (rule: "sample-placeholder"),
# named and reasoned, never a --exclude flag.
#
# Known gap, inherited unchanged from the verb (documented, not fixed
# speculatively): *.example.* files count as sample shapes for the
# sibling sample-shape hook but are not swept here — their marker
# conventions differ (env-style values).
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=house-code-common.sh
source "$HERE/house-code-common.sh"
hc_load_declaration || exit 2

TRACKED="$(git ls-files)"
declared_exempt="$(hc_declared_exempt_paths sample-placeholder)"

is_declared_exempt() {
    local f="$1"
    [[ -z "${declared_exempt}" ]] && return 1
    while IFS= read -r pat; do
        [[ -z "${pat}" ]] && continue
        [[ "${f}" =~ ^(${pat})$ ]] && return 0
    done <<< "${declared_exempt}"
    return 1
}

BAD=""
while IFS= read -r f; do
    [[ -z "${f}" ]] && continue
    is_declared_exempt "${f}" && continue
    grep -qE 'TODO:|path/to/your|YOUR_VALUE_HERE|YOUR_[A-Z_]+|<[A-Z_]+>|\[[A-Z][^]]*\]' "${f}" || BAD="${BAD} ${f}"
done < <(printf '%s\n' "${TRACKED}" | { grep -E '\.sample\.' || true; })

if [[ -n "${BAD}" ]]; then
    echo "BLOCKED: sample file(s) with zero placeholder markers:${BAD}" >&2
    exit 1
fi
exit 0
