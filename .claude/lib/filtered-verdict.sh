#!/usr/bin/env bash
# filtered-verdict.sh — emit marker's verdict scoped to a specific file list.
#
# Push enforces gates only on findings whose `file` matches the files being
# pushed; out-of-scope findings (e.g. from another session's working tree)
# are inert. The caller is responsible for computing the file list — typically
# `scope_files ∩ actual_push_surface` (push) or just the staged set (legacy/tests).
# Tested via filtered-verdict.test.sh.
#
# Usage: filtered-verdict.sh <marker-path> <file-list-path>
#   file-list-path: file with NUL-separated paths relative to repo root.
#
# Stdout: JSON {filtered_verdict, filtered_findings, scope_count, marker_verdict, drift}
# Exit 0: emitted (any verdict). 1: usage. 2: marker malformed. 3: input missing.
# Exit 1: usage error.
# Exit 2: marker malformed (cannot read findings).
# Exit 3: marker file or file-list missing.

set -euo pipefail

MARKER="${1:-}"
FILE_LIST="${2:-}"

if [ -z "$MARKER" ] || [ -z "$FILE_LIST" ]; then
  echo "Usage: $0 <marker-path> <file-list-path>" >&2
  exit 1
fi

[ -f "$MARKER" ] || { echo "Marker not found: $MARKER" >&2; exit 3; }
[ -f "$FILE_LIST" ] || { echo "File list not found: $FILE_LIST" >&2; exit 3; }

if ! command -v python3 >/dev/null 2>&1; then
  echo "python3 required" >&2
  exit 2
fi

python3 - "$MARKER" "$FILE_LIST" <<'PY'
import json, sys

marker_path = sys.argv[1]
file_list_path = sys.argv[2]

try:
    with open(marker_path) as f:
        marker = json.load(f)
except (json.JSONDecodeError, OSError) as e:
    print(f"Marker unreadable: {e}", file=sys.stderr)
    sys.exit(2)

# File list is NUL-separated paths.
with open(file_list_path, 'rb') as f:
    raw = f.read()
file_set = {p.decode('utf-8') for p in raw.split(b'\0') if p}

findings = marker.get('findings', [])
filtered = [f for f in findings if f.get('file') in file_set]

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
    'scope_count': len(file_set),
    'marker_verdict': marker_verdict,
    'drift': filtered_verdict != marker_verdict,
}
print(json.dumps(out, indent=2))
PY
