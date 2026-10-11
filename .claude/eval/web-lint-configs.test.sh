#!/usr/bin/env bash
# The web-language gate checks that the shipped Biome config enables the
# recommended rules and keeps build output and JSON exclusions in effect.
# Margot's finding on the suite PR: the configs were asserted as text only, so
# nothing automatic would notice if `linter.rules.preset` (Biome 2.5's schema
# form) silently switched nothing on.
#
# Requires node/npx on PATH (ubuntu-latest ships it; every estate machine has
# it). Hard-fails when absent — a skipped proof is the gap this suite closes.

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=lib/assert.sh
source "$SCRIPT_DIR/lib/assert.sh"

command -v npx >/dev/null 2>&1 || {
	echo "FATAL: npx not on PATH — this suite never skips" >&2
	exit 2
}

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

section "pins"
BIOME_VER="$(grep -oE '"@biomejs/biome@[^"]+"' "$REPO/.pre-commit-config.yaml" | head -1 | sed -E 's/.*@biomejs\/biome@([^"]+)"/\1/')"
[[ -n "$BIOME_VER" ]] && pass "biome pin read from the hook: $BIOME_VER" || fail "biome pin present in .pre-commit-config.yaml"
SCHEMA_VER="$(jq -r 'to_entries[] | select(.key | endswith("schema")) | .value' "$REPO/biome.json" | sed -E 's#.*/schemas/([^/]+)/.*#\1#')"
assert_eq "biome.json \$schema version matches the hook's tool pin" "$BIOME_VER" "$SCHEMA_VER"

biome() { npx --yes "@biomejs/biome@$BIOME_VER" "$@"; }

section "biome: the shipped config switches the recommended rules on"
mkdir -p "$WORK/biome" && cp "$REPO/biome.json" "$WORK/biome/"
cat >"$WORK/biome/bad.ts" <<'EOF'
import { never } from "./never";
const unused = 1;
debugger;
EOF
out="$(cd "$WORK/biome" && biome lint bad.ts 2>&1)"
rc=$?
[[ $rc -ne 0 ]] && pass "lint exits non-zero on the bad fixture" || fail "lint exits non-zero on the bad fixture" "rc=$rc"
grep -q 'lint/correctness/noUnusedVariables' <<<"$out" && pass "recommended rule fires: noUnusedVariables" || fail "recommended rule fires: noUnusedVariables" "$out"
grep -q 'lint/suspicious/noDebugger' <<<"$out" && pass "recommended rule fires: noDebugger" || fail "recommended rule fires: noDebugger" "$out"
grep -q 'lint/correctness/noUnusedImports' <<<"$out" && pass "explicit rule fires: noUnusedImports" || fail "explicit rule fires: noUnusedImports" "$out"

section "biome: a clean file passes the hook's own command"
cat >"$WORK/biome/good.ts" <<'EOF'
export function add(a: number, b: number): number {
  return a + b;
}
EOF
(cd "$WORK/biome" && biome check --files-ignore-unknown=true --no-errors-on-unmatched good.ts >/dev/null 2>&1) && pass "check passes a clean, formatted file" || fail "check passes a clean, formatted file" "$(cd "$WORK/biome" && biome check good.ts 2>&1)"

section "biome: build output and the hook-excluded JSON are not checked; tracked code still is"
# eve-delegate on eve-plus: after a local build, a bare `biome check .` linted
# gitignored build output (packages/memory/dist) and the provisioner-written
# renovate.json. biome.json's files.includes now carries what the pre-commit
# hook already excluded, so a bare check, an editor and the hook agree.
T="$WORK/biome-tree"
mkdir -p "$T/src" "$T/dist" "$T/build" "$T/coverage" "$T/packages/memory/dist"
cp "$REPO/biome.json" "$T/"
bad='var  x=1;;'
for f in dist/out.js build/out.js coverage/out.js packages/memory/dist/index.js src/bad.js; do printf '%s\n' "$bad" >"$T/$f"; done
printf '{\n  "extends": [\n    "github>lexijamesesq/dotty"\n  ]\n}\n' >"$T/renovate.json"
out="$(cd "$T" && biome check . 2>&1)"
grep -q 'src/bad.js' <<<"$out" && pass "tracked code is still checked (src/bad.js flagged)" || fail "tracked code is still checked (src/bad.js flagged)" "$out"
for d in dist/ build/ coverage/ packages/memory/dist/; do
	if grep -q "$d" <<<"$out"; then fail "build output not checked: $d" "$out"; else pass "build output not checked: $d"; fi
done
if grep -q 'renovate.json' <<<"$out"; then fail "JSON not checked (renovate.json, the hook's exclusion)" "$out"; else pass "JSON not checked (renovate.json, the hook's exclusion)"; fi
finish
