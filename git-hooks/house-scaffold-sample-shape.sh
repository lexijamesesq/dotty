#!/usr/bin/env bash
# house-scaffold-sample-shape.sh — every operator-config reference found in a
# tracked file (CLAUDE.md, settings*.json, or a name ending in "config"
# followed by a .json/.yaml/.yml extension) must have a tracked counterpart
# or a *.sample.*/*.example.* shape. Ported from
# gate-mechanical.sh's Step 1 (gate.md § Scaffold, A6); the verb's own copy
# retires once this hook covers every consumer.
#
# Applicability, narrow and hardcoded (never a per-repo --exclude flag —
# withdrawn after it grew unbounded): Claude Code's own documented,
# always-gitignored, per-user local-override file is recognized by exact
# name and never flagged, in every repo, with no declaration required.
# Second recognized case (same rollout-receipt shape): a reference confined
# entirely to files under a skills/ directory (at any depth — `skills/**`
# or `plugins/*/skills/**`) is skill/playbook documentation explaining
# Claude Code mechanics generically across any project — it never claims
# to be THIS repo's own shipped config, so it isn't evaluated for a sample
# counterpart at all. The same reference at repo root or in a top-level
# README/setup doc still blocks exactly as before; only a reference with
# NO occurrence outside a skills/ path is recognized. Any other one-off
# goes through this repo's .house-code.json `exemptions[]` (rule:
# "sample-shape") — see house-code-common.sh / house-code.py's module
# docstring for the shared shape and the fail-closed discipline.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=house-code-common.sh
source "$HERE/house-code-common.sh"
hc_load_declaration || exit 2

TRACKED="$(git ls-files)"

tracked_stripped=$(printf '%s\n' "${TRACKED}" | while read -r p; do b=$(basename "$p"); echo "${b#.}"; done | sort -u)
# Sample shapes come in two conventions: *.sample.* and *.example.* — strip
# either marker to get the basename the sample stands in for.
sample_basenames=$(printf '%s\n' "${TRACKED}" | { grep -E '\.(sample|example)\.' || true; } | while read -r p; do basename "$p"; done | sed -E 's/\.(sample|example)(\.[^.]+)$/\2/' | sort -u)

# Only references found OUTSIDE a skills/ path can block (see the recognized
# case above) — build the ref set per-file, restricted to non-skills-path
# files, rather than one combined cat|grep over every tracked file (which
# would lose the file association a skills-path exemption needs). Filtered
# to regular files (a tracked directory-symlink target aborts `cat` under
# pipefail — a bug class the publish verb's own equivalent step documents
# and works around the same way).
REF_PATTERN='\bCLAUDE\.md\b|\bsettings(\.[A-Za-z]+)*\.json\b|\b[A-Za-z0-9_-]*config\.(json|ya?ml)\b'
refs=$(printf '%s\n' "${TRACKED}" \
  | { while IFS= read -r f; do
        [[ -f "$f" ]] || continue
        # `case` inside a $(...) command substitution does not parse under
        # this machine's real /bin/bash 3.2 (confirmed: a bare case/esac
        # here is a syntax error, not just missing declare -A) -- a
        # bash-3.2-safe [[ ]] glob test replaces it.
        [[ "$f" == skills/* || "$f" == */skills/* ]] && continue
        cat "$f"
      done; true; } \
  | { grep -ohE "${REF_PATTERN}" || true; } \
  | sed -E 's/^\.//' | sort -u)

declared_exempt="$(hc_declared_exempt_paths sample-shape)"

missing=""
while IFS= read -r ref; do
    [[ -z "${ref}" ]] && continue
    case "${ref}" in *.sample.*|*.example.*) continue ;; esac
    # settings.local.json is Claude Code's own standard per-user local
    # override file — always gitignored, never repo-committed, so it never
    # has or needs a sample counterpart. Fixed here, not per-repo: this
    # exemption showed up independently in four consumer repos before the
    # fix — the same cause recurring across repos is a check defect, not
    # repo variance.
    [[ "${ref}" == "settings.local.json" ]] && continue
    printf '%s\n' "${tracked_stripped}" | grep -qx "${ref}" && continue
    printf '%s\n' "${sample_basenames}" | grep -qx "${ref}" && continue
    # Suffix tolerance: prose often refers to a longer sampled name by its
    # tail (a tool's generic conf filename standing for the repo's longer
    # example counterpart).
    printf '%s\n' "${sample_basenames}" | grep -qE "(^|[-.])$(printf '%s' "${ref}" | sed 's/\./\\./g')$" && continue
    # declared_exempt holds regex PATTERNS (one per line); ref is the
    # candidate — test ref against each pattern, not the reverse.
    if [[ -n "${declared_exempt}" ]]; then
        exempt_hit=0
        while IFS= read -r pat; do
            [[ -z "${pat}" ]] && continue
            [[ "${ref}" =~ ^(${pat})$ ]] && { exempt_hit=1; break; }
        done <<< "${declared_exempt}"
        [[ "${exempt_hit}" -eq 1 ]] && continue
    fi
    missing="${missing} ${ref}"
done <<< "${refs}"

if [[ -n "${missing}" ]]; then
    echo "BLOCKED: operator-config referenced without sample shape:${missing}" >&2
    exit 1
fi
exit 0
