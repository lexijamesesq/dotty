#!/usr/bin/env bash
# github-prep-prepass.sh — deterministic HIGH-confidence pattern detection.
#
# Reads a NUL-separated list of file paths on stdin (relative to repo root).
# For each file, scans for HIGH-confidence patterns and emits NDJSON findings
# to stdout (one JSON object per line). Findings carry source:"prepass" so the
# orchestrator can distinguish them from LLM-judgment findings.
#
# Patterns detected (Block verdict — operator may ack with overriding context):
#   - Anthropic API keys:  sk-ant-[A-Za-z0-9_-]{20,}
#   - OpenAI API keys:     sk-(?:proj-)?[A-Za-z0-9]{20,}     (excludes sk-ant-)
#   - GitHub tokens:       gh[psour]_[A-Za-z0-9]{20,}
#   - Slack tokens:        xox[abprs]-[A-Za-z0-9-]{10,}
#   - AWS access keys:     AKIA[0-9A-Z]{16}
#   - AWS secret env-var:  AWS_SECRET_ACCESS_KEY=<non-empty value>
#
# Patterns detected (Revise verdict — operator must fix in code):
#   - Hardcoded user paths: /Users/<name>/... or /home/<name>/... in shipped files
#
# Usage: changed-files.sh ... | github-prep-prepass.sh <repo_root>
#
# Output: NDJSON (one finding per line):
#   {"category":"Secret","verdict":"Block","file":"...","line":N,"snippet":"...","reason":"...","source":"prepass"}
#
# Exits 0 on completion (even with findings).
# Exits non-zero on error (missing repo_root, unreadable file list).

set -euo pipefail

REPO_ROOT="${1:-}"

if [ -z "$REPO_ROOT" ]; then
  echo "Usage: $0 <repo_root> (reads NUL-separated file list from stdin)" >&2
  exit 1
fi

if [ ! -d "$REPO_ROOT" ]; then
  echo "Not a directory: $REPO_ROOT" >&2
  exit 1
fi

cd "$REPO_ROOT"

# JSON-escape a string: backslashes, quotes, newlines, tabs, control chars.
json_escape() {
  python3 -c 'import json, sys; sys.stdout.write(json.dumps(sys.stdin.read()))' \
    < <(printf '%s' "$1")
}

emit_finding() {
  local category="$1" verdict="$2" file="$3" line="$4" snippet="$5" reason="$6"
  printf '{"category":%s,"verdict":%s,"file":%s,"line":%d,"snippet":%s,"reason":%s,"source":"prepass"}\n' \
    "$(json_escape "$category")" \
    "$(json_escape "$verdict")" \
    "$(json_escape "$file")" \
    "$line" \
    "$(json_escape "$snippet")" \
    "$(json_escape "$reason")"
}

# Run all patterns against one file. Each pattern emits findings to stdout.
# IMPORTANT: scan_file runs with `set +e` because grep returning non-zero on
# no-match would otherwise terminate the script under the script-level `set -e`.
# Each pattern pipeline is independent; a no-match for one pattern is not an
# error and must not prevent subsequent patterns from running.
scan_file() {
  local f="$1"
  set +e

  # Skip binary files quickly.
  if file -b --mime "$f" 2>/dev/null | grep -q 'charset=binary'; then
    set -e
    return 0
  fi

  # Skip empty files.
  if [ ! -s "$f" ]; then
    set -e
    return 0
  fi

  # --- Secret patterns (Block verdict) ---

  # Anthropic API keys: sk-ant-<20+ alphanum chars>
  grep -nE 'sk-ant-[A-Za-z0-9_-]{20,}' "$f" 2>/dev/null | while IFS=: read -r line content; do
    snippet=$(printf '%s' "$content" | head -c 200)
    emit_finding "Secret" "Block" "$f" "$line" "$snippet" \
      "Pattern matches an Anthropic API key (sk-ant-...). High-confidence credential pattern. Acknowledge if this is a documented placeholder, a revoked test key, or otherwise non-functional; otherwise move the value to an environment variable or secrets manager."
  done

  # OpenAI API keys: sk-<20+ alphanum> but NOT sk-ant- (handled above)
  grep -nE 'sk-(proj-)?[A-Za-z0-9]{20,}' "$f" 2>/dev/null \
    | grep -v 'sk-ant-' \
    | while IFS=: read -r line content; do
        snippet=$(printf '%s' "$content" | head -c 200)
        emit_finding "Secret" "Block" "$f" "$line" "$snippet" \
          "Pattern matches an OpenAI API key (sk-... or sk-proj-...). Acknowledge if documented placeholder / revoked / dummy; otherwise move to env var."
      done

  # GitHub tokens: ghp_/gho_/ghu_/ghs_/ghr_<20+ alphanum>
  grep -nE 'gh[psour]_[A-Za-z0-9]{20,}' "$f" 2>/dev/null | while IFS=: read -r line content; do
    snippet=$(printf '%s' "$content" | head -c 200)
    emit_finding "Secret" "Block" "$f" "$line" "$snippet" \
      "Pattern matches a GitHub token (ghp_/gho_/ghu_/ghs_/ghr_...). Acknowledge if known-revoked / documentation example; otherwise rotate and move to env var."
  done

  # Slack tokens: xoxa-/xoxb-/xoxp-/xoxr-/xoxs-<chars>
  grep -nE 'xox[abprs]-[A-Za-z0-9-]{10,}' "$f" 2>/dev/null | while IFS=: read -r line content; do
    snippet=$(printf '%s' "$content" | head -c 200)
    emit_finding "Secret" "Block" "$f" "$line" "$snippet" \
      "Pattern matches a Slack token (xox[abprs]-...). Acknowledge if documented placeholder / revoked; otherwise rotate and move to env var."
  done

  # AWS access keys: AKIA<16 uppercase alphanum>
  grep -nE 'AKIA[0-9A-Z]{16}' "$f" 2>/dev/null | while IFS=: read -r line content; do
    snippet=$(printf '%s' "$content" | head -c 200)
    emit_finding "Secret" "Block" "$f" "$line" "$snippet" \
      "Pattern matches an AWS access key (AKIA...). Acknowledge if known-revoked / documentation example; otherwise rotate immediately and move to env var or AWS credential store."
  done

  # AWS secret in env-var assignment with a non-empty value
  grep -nE 'AWS_SECRET_ACCESS_KEY[[:space:]]*=[[:space:]]*[^[:space:]"'\''=]+' "$f" 2>/dev/null \
    | while IFS=: read -r line content; do
        snippet=$(printf '%s' "$content" | head -c 200)
        emit_finding "Secret" "Block" "$f" "$line" "$snippet" \
          "AWS_SECRET_ACCESS_KEY assigned a literal value. Acknowledge if the value is an obvious placeholder (e.g., literal 'PLACEHOLDER' or 'changeme'); otherwise move to env var loaded from a secrets manager."
      done

  # --- Hardcoded paths (Revise verdict — no ack scenario) ---

  # /Users/<name>/... — macOS user paths
  grep -nE '/Users/[a-zA-Z][a-zA-Z0-9._-]*(/|$|["[:space:]])' "$f" 2>/dev/null \
    | while IFS=: read -r line content; do
        snippet=$(printf '%s' "$content" | head -c 200)
        emit_finding "Hardcoded path" "Revise" "$f" "$line" "$snippet" \
          "Hardcoded macOS user path (/Users/<name>/...). Breaks portability for other machines. Replace with \$HOME, a config key, or a relative path."
      done

  # /home/<name>/... — Linux user paths
  grep -nE '/home/[a-zA-Z][a-zA-Z0-9._-]*(/|$|["[:space:]])' "$f" 2>/dev/null \
    | while IFS=: read -r line content; do
        snippet=$(printf '%s' "$content" | head -c 200)
        emit_finding "Hardcoded path" "Revise" "$f" "$line" "$snippet" \
          "Hardcoded Linux user path (/home/<name>/...). Breaks portability for other machines. Replace with \$HOME, a config key, or a relative path."
      done

  set -e
}

# Read NUL-separated file list from stdin, scan each.
while IFS= read -r -d '' f; do
  # Skip if file doesn't exist (could have been deleted in the change set).
  [ -f "$f" ] || continue
  scan_file "$f"
done

# Exit 0 even if findings emitted — findings are not errors.
exit 0
