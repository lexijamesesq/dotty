#!/usr/bin/env bash
# gate-mechanical.sh — the publish gate's one-script mechanical front.
# Four steps in a single invocation:
#   1. Scaffold verification        (gate.md § Scaffold)
#   2. Sample-file placeholder audit (same criterion, placeholder-integrity half)
#   3. Universe/fiction scan of the changed *.md files (qa.py, delta-scoped)
#   4. PII sweep of tracked HEAD content against the gitleaks operator patterns
#      (HEAD-content complement to gate.md criterion 5's range scan)
#
# The Step 4 sweep is computed once, ahead of Step 1, because Step 1's
# conditional-allowlist rule (content-bearing + no [allowlist] + a clean
# sweep → PASS) needs the same result — see gate.md § Criteria 1.
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

# gl_preflight / gl_effective_config resolution — the same operator-rules
# resolver the actual pre-commit/pre-push hooks use (fixed path first, no
# checkout-relative fallback). Without this, a bare `--config .gitleaks.toml`
# load FTLs on any repo whose checkout-relative symlink is gone.
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/../../../../git-hooks/gitleaks-common.sh"

# Resolve references.tag_taxonomy_rosters from dotty-private's global
# CLAUDE.md — the single source of truth for where tag-taxonomy-rosters.md
# actually lives, never hardcoded here. Unlike a project CLAUDE.md (real
# YAML frontmatter, the shape statusline.sh's parse_declared_repos() reads),
# the global CLAUDE.md's Configuration block is a fenced ```yaml section in
# the body — extract that fence, not frontmatter. Empty output (missing yq,
# missing file, missing key) is a legitimate "unresolved" signal, not an
# error — the caller falls back to qa.py's own pre-key vault-relative
# default.
resolve_rosters_path() {
  local claude_md="${HOME}/bin/dotty-private/.claude/CLAUDE.md"
  [[ -f "$claude_md" ]] || return
  command -v yq >/dev/null 2>&1 || return
  local yaml_block value workspace_root
  yaml_block="$(awk '/^```yaml/{c=1; next} /^```$/{c=0} c' "$claude_md")"
  value="$(printf '%s\n' "$yaml_block" | yq -r '."references.tag_taxonomy_rosters"' - 2>/dev/null | grep -v '^null$')" || true
  [[ -z "$value" ]] && return
  case "$value" in
    "~"*|/*)
      # Repo-absolute or already-expanded — expand a leading ~ (no eval).
      printf '%s\n' "${value/#\~/$HOME}"
      ;;
    *)
      # workspace_root-relative, same convention every other references.*
      # key uses (see the Configuration block's own header comment).
      workspace_root="$(printf '%s\n' "$yaml_block" | yq -r '.workspace_root' - 2>/dev/null | grep -v '^null$')"
      [[ -z "$workspace_root" ]] && workspace_root="${HOME}/Vaults/Notes"
      workspace_root="${workspace_root/#\~/$HOME}"
      printf '%s\n' "${workspace_root%/}/$value"
      ;;
  esac
}
ROSTERS_PATH="$(resolve_rosters_path)"

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

# ---- Shared: PII sweep of tracked HEAD content --------------------------
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
# With a repo .gitleaks.toml the full extend-chain + allowlists apply
# (gl_preflight resolves the relative [extend] token against the fixed
# install path — see git-hooks/gitleaks-common.sh).
#
# Computed once, here, because Step 1's conditional-allowlist rule (2026-07-10
# ruling — gate.md § Criteria 1) and Step 4 both need the same result.
#
# FAIL CLOSED on scan errors. The estate standard for this class (pre-push)
# is fail-closed; a swallowed gitleaks error (e.g. an unresolvable [extend]
# when the operator ruleset is not installed at the fixed path) must never
# read as a clean sweep — that fail-open would flow into BOTH consuming
# steps. gitleaks exit codes: 0 = clean scan, 1 = leaks found, >1 = error.
# An unparseable/missing report on rc<=1 is also a scan anomaly → closed.
PII_SWEEP_STATUS=""
PII_SWEEP=""
PII_SWEEP_ERR=""
RULES="${TARGET}/.gitleaks.toml"
if [[ ! -f "${RULES}" ]]; then
  PII_SWEEP_STATUS="no_config"
elif ! command -v gitleaks >/dev/null; then
  PII_SWEEP_STATUS="no_gitleaks"
else
  HEAD_TREE="$(mktemp -d)"
  git -C "${TARGET}" archive HEAD | tar -x -C "${HEAD_TREE}"
  GL_REPORT="$(mktemp)"
  GL_RC=0
  if gl_preflight "${RULES}"; then
    (cd "${HEAD_TREE}" && gitleaks detect --source . --no-git --config "${GL_EFFECTIVE_CONFIG}" --no-banner --redact --ignore-gitleaks-allow --report-format json --report-path "${GL_REPORT}" >/dev/null 2>&1) || GL_RC=$?
  else
    # gl_preflight already printed a cause-specific gl_block to stderr.
    GL_RC=2
  fi
  rm -f "${GL_TMP_CONFIG}" 2>/dev/null || true
  if [[ ${GL_RC} -gt 1 ]]; then
    PII_SWEEP_STATUS="scan_error"
    PII_SWEEP_ERR="gitleaks exit ${GL_RC}"
  else
    # rc 0/1: parse the report. The parser prints TOTAL:<n> (finding count
    # BEFORE the config-file exclusion) as its first line and exits nonzero
    # on an unparseable/missing report — so "rc=1 but every finding was in
    # the excluded gitleaks configs" (legitimate empty sweep) stays
    # distinguishable from "the scan never produced a report" (anomaly,
    # fail closed). The gitleaks configs themselves carry the literal
    # patterns by nature — excluded from the sweep verdict.
    PARSE_RC=0
    RAW_SWEEP=$(python3 - "${GL_REPORT}" <<'PYEOF'
import json, sys
try:
    findings = json.load(open(sys.argv[1]))
except (OSError, json.JSONDecodeError):
    sys.exit(3)
print(f"TOTAL:{len(findings)}")
cfgs = {".gitleaks.toml"}
real = [f for f in findings if f.get("File", "").split("/")[-1] not in cfgs]
for f in real:
    print(f"{f.get('RuleID','?')}  {f.get('File','?')}")
PYEOF
) || PARSE_RC=$?
    if [[ ${PARSE_RC} -ne 0 || "${RAW_SWEEP}" != TOTAL:* ]]; then
      PII_SWEEP_STATUS="scan_error"
      PII_SWEEP_ERR="gitleaks exit ${GL_RC}, report unparseable"
    else
      PII_SWEEP="$(printf '%s\n' "${RAW_SWEEP}" | tail -n +2)"
      PII_SWEEP_STATUS="ok"
    fi
  fi
  rm -rf "${HEAD_TREE}" "${GL_REPORT}"
fi

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
    # Conditional allowlist rule (2026-07-10 ruling — gate.md § Criteria 1):
    # an allowlist exists to keep intentional test literals distinguishable
    # from real leaks; when the operator-pattern sweep over tracked HEAD
    # content trips nothing, there is nothing to distinguish, and forcing an
    # allowlist re-adds the suppression surface the operator removed on
    # 2026-07-09. Reuses the sweep computed above (shared with Step 4).
    case "${PII_SWEEP_STATUS}" in
      ok)
        if [[ -z "${PII_SWEEP}" ]]; then
          verdict PASS "content-bearing, no allowlist needed — tracked content trips no patterns"
        else
          verdict FAIL $'content-bearing, no allowlist, and tracked HEAD content trips operator patterns:\n'"${PII_SWEEP}"
        fi
        ;;
      no_config)
        verdict FAIL "content-bearing, no allowlist, and no gitleaks config found to run the fallback sweep"
        ;;
      no_gitleaks)
        verdict FAIL "content-bearing, no allowlist, and gitleaks not installed to run the fallback sweep"
        ;;
      scan_error)
        verdict FAIL "content-bearing, no allowlist, and the PII sweep failed to run (${PII_SWEEP_ERR}) — failing closed"
        ;;
    esac
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
# Known gap (documented, not fixed speculatively): .example. files count as
# sample shapes in Step 1 but are not swept here — their marker conventions
# differ (env-style values). Extend when a real failure motivates it.
if [[ -n "${BAD}" ]]; then verdict FAIL "sample file(s) with zero placeholder markers:${BAD}"; else verdict PASS "all tracked samples carry placeholders"; fi

# ---- Step 3: Universe/fiction scan of changed *.md ---------------------
step "3. Universe conformance (changed *.md, mechanical)"
CHANGED_MD=()
# -M100%: the git-diff(1) rename-detection threshold, expressed as an
# explicit percentage — the number alone (-M100) is NOT "100%", it's git's
# internal fractional scale and behaves close to a 10% threshold; only the
# %-suffixed form asks for exact-similarity-only detection, and under it
# R100 means the two blobs are byte-identical (mode changes excepted) — a
# reordered-lines-only rename does NOT report R100 here, it reports as a
# separate add+delete pair instead (unlike the bare -M100 form, which
# scores by line-multiset similarity and could call that "identical" too).
# A whole-directory rename (e.g. claude/ -> .claude/) makes every file's
# path change with zero content change — without rename awareness,
# `--name-only` lists every one of those files as "changed," so a PR that
# renames a directory gates on its entire pre-existing content, not what
# the PR actually touched. R100 is excluded from the blocking set below;
# genuine adds, edits, and below-100%-similarity renames still gate
# normally.
#
# Exception: a file moving OUT of an exempt directory (tests/fixtures/ or
# reference/, both per qa.py's own exemption logic) must still be scanned
# even if R100 — the exemption depends on PATH, not content, so a pure
# rename crossing that boundary needs re-evaluating under its new path,
# not skipped as if nothing relevant could have changed.
while IFS=$'\t' read -r status path newpath; do
  [[ -z "$status" ]] && continue
  # Absolute-path check: $path alone (e.g. "tests/fixtures/x.md", no
  # leading component) wouldn't contain the "/tests/fixtures/" substring —
  # match the same absolute-path form the downstream Python filter below
  # checks, so a top-level fixtures/reference dir is caught the same as a
  # nested one.
  old_abs="${TARGET}/${path}"
  if [[ "$status" == R100* && "$old_abs" != *"/tests/fixtures/"* && "$old_abs" != *"/reference/"* ]]; then
    continue
  fi
  f="${newpath:-$path}"
  [[ -n "$f" ]] && CHANGED_MD+=("${TARGET}/$f")
done < <(git -C "${TARGET}" diff --name-status -M100% --diff-filter=d "${BASE}...HEAD" -- '*.md' || true)
if [[ ${#CHANGED_MD[@]} -eq 0 ]]; then
  verdict PASS "no changed markdown in range"
else
  QA_OUT="$(mktemp)"
  QA_ROSTERS_ARGS=()
  [[ -n "${ROSTERS_PATH}" ]] && QA_ROSTERS_ARGS=(--rosters-path "${ROSTERS_PATH}")
  if python3 "${QA_PY}" "${CHANGED_MD[@]}" --json --vault-root "${VAULT_ROOT}" "${QA_ROSTERS_ARGS[@]}" > "${QA_OUT}" 2>"${QA_OUT}.err"; then
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

# ---- Step 4: PII sweep of tracked HEAD content --------------------------
step "4. PII sweep (gitleaks operator patterns, HEAD content)"
# Sweep computed once, above (shared with Step 1's conditional-allowlist
# check) — semantics documented there.
case "${PII_SWEEP_STATUS}" in
  no_config)
    verdict FAIL "no gitleaks config found (expected ${TARGET}/.gitleaks.toml)"
    ;;
  no_gitleaks)
    verdict FAIL "gitleaks not installed"
    ;;
  scan_error)
    verdict FAIL "PII sweep failed to run (${PII_SWEEP_ERR}) — failing closed"
    ;;
  ok)
    if [[ -z "${PII_SWEEP}" ]]; then
      verdict PASS "no operator-pattern findings in tracked HEAD content"
    else
      verdict FAIL $'operator-pattern findings in tracked HEAD content (rule + file):\n'"${PII_SWEEP}"
    fi
    ;;
esac

printf '\n== gate-mechanical: %s ==\n' "$( [[ ${FAIL} -eq 0 ]] && echo ALL PASS || echo FAILURES PRESENT )"
exit "${FAIL}"
