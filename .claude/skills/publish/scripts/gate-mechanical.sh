#!/usr/bin/env bash
# gate-mechanical.sh — the publish gate's one-script mechanical front.
# Runs the gate trace's steps 1–3 + 8 in a single invocation:
#   1. Scaffold verification        (gate.md § Scaffold)
#   2. Sample-file placeholder audit (same criterion, placeholder-integrity half)
#   3. Universe/fiction scan of the changed *.md files (qa.py, delta-scoped)
#   8. PII sweep of ADDED diff lines against the gitleaks operator patterns
#
# Gitleaks (criterion 5) and the two judgment passes (house-qa review,
# security review) are deliberately NOT here — see playbooks/gate.md.
#
# Usage: gate-mechanical.sh <target_repo> [--base <ref>] [--visibility public|private]
#   --base        diff base for delta-scoped steps (default: origin/HEAD)
#   --visibility  file-presence expectations; private repos carry no LICENSE
#                 (default: public)
#
# Exit: 0 all steps PASS; 1 any step FAIL; 2 usage/config error.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
QA_PY="${SCRIPT_DIR}/../../house-qa/qa.py"

TARGET="${1:-}"; shift || true
BASE="origin/HEAD"
VISIBILITY="public"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --base)       BASE="${2:?}"; shift ;;
    --visibility) VISIBILITY="${2:?}"; shift ;;
    *) echo "Unknown argument: $1" >&2; exit 2 ;;
  esac
  shift
done
[[ -n "${TARGET}" && -d "${TARGET}" ]] || { echo "Usage: $0 <target_repo> [--base <ref>] [--visibility public|private]" >&2; exit 2; }
[[ -n "${VAULT_ROOT:-}" ]] || { echo "VAULT_ROOT must be set (qa.py resolves the tag rosters through it)" >&2; exit 2; }
TARGET="$(cd "${TARGET}" && pwd)"
git -C "${TARGET}" rev-parse --git-dir >/dev/null 2>&1 || { echo "Not a git repo: ${TARGET}" >&2; exit 2; }
git -C "${TARGET}" rev-parse --verify --quiet "${BASE}" >/dev/null || { echo "Base ref not found: ${BASE} (set once: git -C ${TARGET} remote set-head origin --auto)" >&2; exit 2; }

FAIL=0
step() { printf '\n== %s ==\n' "$1"; }
verdict() { # verdict <PASS|FAIL> <detail>
  if [[ "$1" == PASS ]]; then printf 'PASS %s\n' "${2:-}"; else printf 'FAIL %s\n' "${2:-}"; FAIL=1; fi
}

TRACKED="$(git -C "${TARGET}" ls-files)"

# ---- Step 1: Scaffold --------------------------------------------------
step "1. Scaffold"

if echo "${TRACKED}" | grep -qEi '(^|/)(evals|scratch)(/|$)'; then
  verdict FAIL "non-shipping dir tracked: $(echo "${TRACKED}" | grep -Ei '(^|/)(evals|scratch)(/|$)' | head -3 | tr '\n' ' ')"
else
  verdict PASS "no evals/scratch tracked"
fi

if echo "${TRACKED}" | grep -qE 'fixtures?/|samples?/|golden|Evals?/'; then
  if grep -qs '^\[allowlist\]' "${TARGET}/.gitleaks.toml"; then
    verdict PASS "content-bearing, gitleaks allowlist present"
  else
    verdict FAIL "content-bearing repo without a gitleaks [allowlist]"
  fi
else
  verdict PASS "not content-bearing"
fi

if [[ "${VISIBILITY}" == "public" ]]; then
  if [[ -f "${TARGET}/LICENSE" && -f "${TARGET}/README.md" ]]; then
    verdict PASS "LICENSE + README present"
  else
    verdict FAIL "missing $( [[ -f "${TARGET}/LICENSE" ]] || echo LICENSE ) $( [[ -f "${TARGET}/README.md" ]] || echo README.md )"
  fi
else
  if [[ -f "${TARGET}/README.md" ]]; then
    verdict PASS "README present (private repo: LICENSE not expected)"
  else
    verdict FAIL "missing README.md"
  fi
fi

# Operator-config references need a tracked or *.sample.* counterpart
tracked_stripped=$(printf '%s\n' "${TRACKED}" | while read -r p; do b=$(basename "$p"); echo "${b#.}"; done | sort -u)
# Sample shapes come in two conventions: *.sample.* and *.example.* — strip
# either marker to get the basename the sample stands in for.
sample_basenames=$(printf '%s\n' "${TRACKED}" | { grep -E '\.(sample|example)\.' || true; } | while read -r p; do basename "$p"; done | sed -E 's/\.(sample|example)(\.[^.]+)$/\2/' | sort -u)
refs=$(printf '%s\n' "${TRACKED}" | sed "s|^|${TARGET}/|" | xargs -I{} cat {} 2>/dev/null \
  | { grep -ohE '\bCLAUDE\.md\b|\bsettings(\.[A-Za-z]+)*\.json\b|\b[A-Za-z0-9_-]*config\.(json|ya?ml)\b' || true; } \
  | sed -E 's/^\.//' | sort -u)
missing=""
while IFS= read -r ref; do
  [[ -z "$ref" ]] && continue
  case "$ref" in *.sample.*|*.example.*) continue ;; esac
  printf '%s\n' "$tracked_stripped" | grep -qx "$ref" && continue
  printf '%s\n' "$sample_basenames" | grep -qx "$ref" && continue
  # Suffix tolerance: prose often refers to a longer sampled name by its
  # tail (a tool's generic conf filename standing for the repo's longer
  # example counterpart). Covered if any sample/example basename ends
  # with the referenced name.
  printf '%s\n' "$sample_basenames" | grep -qE "(^|[-.])$(printf '%s' "$ref" | sed 's/\./\\./g')$" && continue
  missing="$missing $ref"
done <<< "$refs"
if [[ -n "${missing}" ]]; then verdict FAIL "operator-config referenced without sample shape:${missing}"; else verdict PASS "operator-config sample shapes complete"; fi

# ---- Step 2: Sample placeholder audit ----------------------------------
step "2. Sample placeholder audit"
BAD=""
while IFS= read -r f; do
  [[ -z "$f" ]] && continue
  grep -qE 'TODO:|path/to/your|YOUR_VALUE_HERE|<[A-Z_]+>' "${TARGET}/$f" || BAD="$BAD $f"
done < <(printf '%s\n' "${TRACKED}" | { grep -E '\.sample\.' || true; })
if [[ -n "${BAD}" ]]; then verdict FAIL "sample file(s) with zero placeholder markers:${BAD}"; else verdict PASS "all tracked samples carry placeholders"; fi

# ---- Step 3: Universe/fiction scan of changed *.md ---------------------
step "3. Universe conformance (changed *.md, mechanical)"
CHANGED_MD=()
while IFS= read -r f; do
  [[ -n "$f" ]] && CHANGED_MD+=("${TARGET}/$f")
done < <(git -C "${TARGET}" diff --name-only --diff-filter=d "${BASE}...HEAD" -- '*.md' || true)
if [[ ${#CHANGED_MD[@]} -eq 0 ]]; then
  verdict PASS "no changed markdown in range"
else
  QA_OUT="$(mktemp)"
  if python3 "${QA_PY}" "${CHANGED_MD[@]}" --json --vault-root "${VAULT_ROOT}" > "${QA_OUT}" 2>"${QA_OUT}.err"; then
    FICTION=$(python3 - "${QA_OUT}" <<'PYEOF'
import json, sys
r = json.load(open(sys.argv[1]))
f = [x for x in r["findings"]
     if x["check"] in ("unlisted-fiction-entity", "fiction-continuity-mismatch")
     and "/tests/fixtures/" not in x["file"]]
print("\n".join(f"{x['severity']} {x['file']}: {x['detail'][:120]}" for x in f))
PYEOF
)
    if [[ -n "${FICTION}" ]]; then verdict FAIL $'unlisted/inconsistent fiction in changed files:\n'"${FICTION}"; else verdict PASS "changed files draw only from the sample universe"; fi
  else
    verdict FAIL "qa.py errored: $(head -2 "${QA_OUT}.err" | tr '\n' ' ')"
  fi
  rm -f "${QA_OUT}" "${QA_OUT}.err"
fi

# ---- Step 8: PII sweep of added diff lines -----------------------------
step "8. PII sweep (gitleaks operator patterns, HEAD content)"
# Same engine as gate criterion 5 — never a session-improvised list, and no
# pattern drift: a hand-rolled regex loop over the same TOML proved stricter
# than gitleaks itself (it ignored per-rule case flags and allowlists).
# Semantics differ from criterion 5 deliberately: this sweeps TRACKED content
# at HEAD (git archive → scratch tree), i.e. exactly what a push publishes. A
# raw --no-git working-tree scan is wrong in both directions — it sweeps
# gitignored files whose whole job is to hold secrets (.env), and untracked
# scratch that a push never ships. A pattern introduced then scrubbed within
# the branch lives only in history, which is criterion 5's range scan — and
# on public repos that correctly forces a history cleanup before publish.
# With a repo .gitleaks.toml the full extend-chain + allowlists apply;
# without one, the operator-rules file runs alone.
RULES="${TARGET}/.gitleaks.toml"
[[ -f "${RULES}" ]] || RULES="${TARGET}/.gitleaks-operator-rules.toml"
[[ -f "${RULES}" ]] || RULES="${HOME}/bin/dotty-private/gitleaks-operator-rules.toml"
if [[ ! -f "${RULES}" ]]; then
  verdict FAIL "no gitleaks config found (repo config, repo symlink, or dotty-private canonical)"
elif ! command -v gitleaks >/dev/null; then
  verdict FAIL "gitleaks not installed"
else
  HEAD_TREE="$(mktemp -d)"
  git -C "${TARGET}" archive HEAD | tar -x -C "${HEAD_TREE}"
  # The config may live in the working tree only (gitignored symlink target
  # resolution) — resolve RULES to an absolute path before scanning the
  # scratch tree, and run from the scratch tree so relative extends break
  # loudly rather than silently reading the wrong file.
  RULES_ABS="$(cd "$(dirname "${RULES}")" && pwd)/$(basename "${RULES}")"
  if [[ -f "${HEAD_TREE}/.gitleaks.toml" && -f "${TARGET}/.gitleaks-operator-rules.toml" ]]; then
    cp "${TARGET}/.gitleaks-operator-rules.toml" "${HEAD_TREE}/.gitleaks-operator-rules.toml" 2>/dev/null || true
    RULES_ABS="${HEAD_TREE}/.gitleaks.toml"
  fi
  GL_REPORT="$(mktemp)"
  (cd "${HEAD_TREE}" && gitleaks detect --source . --no-git --config "${RULES_ABS}" --no-banner --redact --report-format json --report-path "${GL_REPORT}" >/dev/null 2>&1) || true
  # The gitleaks configs themselves carry the literal patterns by nature —
  # exclude them from the sweep verdict.
  SWEEP=$(python3 - "${GL_REPORT}" <<'PYEOF'
import json, sys
try:
    findings = json.load(open(sys.argv[1]))
except (OSError, json.JSONDecodeError):
    findings = []
cfgs = {".gitleaks.toml", ".gitleaks-operator-rules.toml"}
real = [f for f in findings if f.get("File", "").split("/")[-1] not in cfgs]
for f in real:
    print(f"{f.get('RuleID','?')}  {f.get('File','?')}")
PYEOF
)
  if [[ -z "${SWEEP}" ]]; then
    verdict PASS "no operator-pattern findings in tracked HEAD content"
  else
    verdict FAIL $'operator-pattern findings in tracked HEAD content (rule + file):\n'"${SWEEP}"
  fi
  rm -rf "${HEAD_TREE}" "${GL_REPORT}"
fi

printf '\n== gate-mechanical: %s ==\n' "$( [[ ${FAIL} -eq 0 ]] && echo ALL PASS || echo FAILURES PRESENT )"
exit "${FAIL}"
