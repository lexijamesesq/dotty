#!/usr/bin/env bash
# validate-marker.sh — assert a .github-prep-status.json marker conforms to
# the v3 schema at .claude/lib/contracts/marker-v2.schema.json (filename
# preserved across the v2→v3 bump; the file itself declares
# marker_schema_version: 3).
#
# This is the load-bearing contract test at the prep↔push boundary. If push
# reads a marker that fails this check, push refuses (mismatch is a v1/v2
# marker or a malformed v3). If prep writes a marker that fails this check,
# the emitting code has a bug.
#
# Usage:
#   validate-marker.sh <path-to-marker.json>
#
# Exit 0: marker validates against v3 schema.
# Exit 1: marker is malformed or wrong version.
# Exit 2: schema file missing or unreadable.
# Exit 3: marker file missing or unreadable.

set -euo pipefail

MARKER="${1:-}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SCHEMA="${SCHEMA_PATH:-$SCRIPT_DIR/contracts/marker-v2.schema.json}"

if [ -z "$MARKER" ]; then
  echo "Usage: $0 <path-to-marker.json>" >&2
  exit 1
fi

if [ ! -f "$SCHEMA" ]; then
  echo "Schema file not found: $SCHEMA" >&2
  exit 2
fi

if [ ! -f "$MARKER" ]; then
  echo "Marker file not found: $MARKER" >&2
  exit 3
fi

# Use python3 + jsonschema if available (most reliable). Fall back to a basic
# jq-based structural check.

if command -v python3 >/dev/null 2>&1; then
  python3 - "$MARKER" "$SCHEMA" <<'PY'
import json, sys

marker_path = sys.argv[1]
schema_path = sys.argv[2]

try:
    with open(marker_path) as f:
        marker = json.load(f)
except json.JSONDecodeError as e:
    print(f"Marker is not valid JSON: {e}", file=sys.stderr)
    sys.exit(1)
except OSError as e:
    print(f"Cannot read marker: {e}", file=sys.stderr)
    sys.exit(3)

try:
    with open(schema_path) as f:
        schema = json.load(f)
except (json.JSONDecodeError, OSError) as e:
    print(f"Cannot read schema: {e}", file=sys.stderr)
    sys.exit(2)

# Prefer the jsonschema library if installed; else fall back to manual checks.
try:
    import jsonschema
    try:
        jsonschema.validate(marker, schema)
        print(f"OK: {marker_path} conforms to marker v3 schema.")
        sys.exit(0)
    except jsonschema.ValidationError as e:
        print(f"FAIL: schema violation at {list(e.absolute_path)}: {e.message}", file=sys.stderr)
        sys.exit(1)
except ImportError:
    pass

# Manual structural checks (subset of the schema; enough to catch v1/v2
# confusion and the most-common malformations).
errors = []

required = [
    "marker_schema_version", "evaluated_path", "evaluated_at", "scope",
    "scope_files", "scanner_version", "policy_hash", "verdict", "findings",
    "acknowledgments", "summary",
]
for k in required:
    if k not in marker:
        errors.append(f"missing required field: {k}")

if marker.get("marker_schema_version") != 3:
    errors.append(f"marker_schema_version must be 3, got: {marker.get('marker_schema_version')!r}")

# scope_files must be an array of strings
sf = marker.get("scope_files")
if sf is not None:
    if not isinstance(sf, list):
        errors.append(f"scope_files must be an array, got: {type(sf).__name__}")
    else:
        for i, p in enumerate(sf):
            if not isinstance(p, str) or not p:
                errors.append(f"scope_files[{i}] must be a non-empty string")

allowed_verdicts = {"allow", "block", "revise", "escalate"}
if marker.get("verdict") not in allowed_verdicts:
    errors.append(f"verdict must be one of {sorted(allowed_verdicts)}, got: {marker.get('verdict')!r}")

allowed_scopes = {"change-set", "full-audit", "docs-only"}
if marker.get("scope") not in allowed_scopes:
    errors.append(f"scope must be one of {sorted(allowed_scopes)}, got: {marker.get('scope')!r}")

# Each finding shape
allowed_finding_verdicts = {"Allow", "Block", "Revise", "Escalate"}
allowed_categories = {
    "Secret", "PII", "Hardcoded path", "Internal reference",
    "Personal context", "Domain knowledge", "Separation of concerns",
    "Sample drift",
}
for i, f in enumerate(marker.get("findings", [])):
    for k in ("category", "verdict", "file", "line", "snippet", "reason"):
        if k not in f:
            errors.append(f"finding[{i}] missing required field: {k}")
    if f.get("verdict") not in allowed_finding_verdicts:
        errors.append(f"finding[{i}].verdict must be one of {sorted(allowed_finding_verdicts)}, got: {f.get('verdict')!r}")
    if f.get("category") not in allowed_categories:
        errors.append(f"finding[{i}].category must be one of {sorted(allowed_categories)}, got: {f.get('category')!r}")

# Summary required keys
if "summary" in marker:
    for k in ("allow", "block", "revise", "escalate"):
        if k not in marker["summary"]:
            errors.append(f"summary missing required key: {k}")

if errors:
    print(f"FAIL: marker {marker_path} has {len(errors)} schema violations:", file=sys.stderr)
    for e in errors:
        print(f"  - {e}", file=sys.stderr)
    sys.exit(1)

print(f"OK: {marker_path} passes structural v3 check (jsonschema library not installed; structural check only).")
sys.exit(0)
PY
  exit $?
fi

# No python3 — fall back to bare jq check (very minimal).
if ! command -v jq >/dev/null 2>&1; then
  echo "Neither python3 nor jq available; cannot validate." >&2
  exit 2
fi

# Just check marker_schema_version and verdict enum.
SCHEMA_VER=$(jq -r '.marker_schema_version // "missing"' "$MARKER")
VERDICT=$(jq -r '.verdict // "missing"' "$MARKER")

if [ "$SCHEMA_VER" != "3" ]; then
  echo "FAIL: marker_schema_version is $SCHEMA_VER (expected 3)" >&2
  exit 1
fi

# Bare jq cannot deeply validate scope_files; check presence as array.
SCOPE_FILES_TYPE=$(jq -r '.scope_files | type' "$MARKER" 2>/dev/null || echo "missing")
if [ "$SCOPE_FILES_TYPE" != "array" ]; then
  echo "FAIL: scope_files must be an array, got type: $SCOPE_FILES_TYPE" >&2
  exit 1
fi

case "$VERDICT" in
  allow|block|revise|escalate) ;;
  *)
    echo "FAIL: verdict is '$VERDICT' (expected allow|block|revise|escalate)" >&2
    exit 1
    ;;
esac

echo "OK: $MARKER passes bare jq check (limited — install python3 + jsonschema for full validation)."
exit 0
