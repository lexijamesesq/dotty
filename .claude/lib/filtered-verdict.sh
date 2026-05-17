#!/usr/bin/env bash
# filtered-verdict.sh — given a marker file and a NUL-separated list of files
# being committed, emit the marker's verdict scoped to JUST those files.
#
# This is the load-bearing logic at the prep<->push boundary that Stage 3-bis
# introduced: even if prep scanned more broadly (--working-tree or --full-audit),
# push enforces gates only on findings whose `file` matches the files being
# committed. Out-of-staged-scope findings are inert at push time.
#
# Without this filtering, another operator's in-flight working-tree changes
# poison the verdict for an unrelated push — the verdict-poisoning bug
# Stage 3-bis fixed in prose. Extracting to a script makes the logic testable
# and removes load-bearing behavior from agent prose interpretation.
#
# Usage:
#   filtered-verdict.sh <marker-path> <staged-file-list-path>
#     - marker-path: path to .github-prep-status.json
#     - staged-file-list-path: file with NUL-separated paths (relative to repo root)
#                              that are being committed in this push.
#
# Output (stdout): JSON object with:
#   {
#     "filtered_verdict": "allow|block|revise|escalate",
#     "filtered_findings": [...],   // subset of marker.findings, .file in staged
#     "scope_count": N,             // number of staged files
#     "marker_verdict": "...",      // marker's stored overall verdict
#     "drift": true|false           // true if filtered != marker
#   }
#
# Exit 0: emitted successfully (regardless of verdict).
# Exit 1: usage error.
# Exit 2: marker malformed (cannot read findings).
# Exit 3: marker file or staged-file-list missing.

set -euo pipefail

MARKER="${1:-}"
STAGED_LIST="${2:-}"

if [ -z "$MARKER" ] || [ -z "$STAGED_LIST" ]; then
  echo "Usage: $0 <marker-path> <staged-file-list-path>" >&2
  exit 1
fi

[ -f "$MARKER" ] || { echo "Marker not found: $MARKER" >&2; exit 3; }
[ -f "$STAGED_LIST" ] || { echo "Staged-file list not found: $STAGED_LIST" >&2; exit 3; }

if ! command -v python3 >/dev/null 2>&1; then
  echo "python3 required" >&2
  exit 2
fi

python3 - "$MARKER" "$STAGED_LIST" <<'PY'
import json, sys

marker_path = sys.argv[1]
staged_list_path = sys.argv[2]

try:
    with open(marker_path) as f:
        marker = json.load(f)
except (json.JSONDecodeError, OSError) as e:
    print(f"Marker unreadable: {e}", file=sys.stderr)
    sys.exit(2)

# Staged list is NUL-separated paths.
with open(staged_list_path, 'rb') as f:
    raw = f.read()
staged = {p.decode('utf-8') for p in raw.split(b'\0') if p}

findings = marker.get('findings', [])
filtered = [f for f in findings if f.get('file') in staged]

# Precedence: Escalate > Revise > Block > Allow.
order = {'Allow': 0, 'Block': 1, 'Revise': 2, 'Escalate': 3}
inv_order = {v: k for k, v in order.items()}

def derive_verdict(finding_list):
    if not finding_list:
        return 'allow'
    max_v = max(order.get(f.get('verdict', 'Allow'), 0) for f in finding_list)
    return inv_order[max_v].lower()

filtered_verdict = derive_verdict(filtered)
marker_verdict = marker.get('verdict', 'unknown')

out = {
    'filtered_verdict': filtered_verdict,
    'filtered_findings': filtered,
    'scope_count': len(staged),
    'marker_verdict': marker_verdict,
    'drift': filtered_verdict != marker_verdict,
}
print(json.dumps(out, indent=2))
PY
