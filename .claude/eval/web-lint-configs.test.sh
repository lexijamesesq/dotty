#!/usr/bin/env bash
# The web-language gate is only as real as the rules it switches on. This
# suite runs the EXACT Biome and Prettier versions the pre-commit hooks pin
# (read from .pre-commit-config.yaml, never hardcoded here) against the
# shipped biome.json / .prettierrc and deliberately bad fixtures, and asserts
# that the recommended rules fire, that a clean file passes, and that each
# formatting setting is honoured. Margot's finding on the suite PR: the
# configs were asserted as text only, so nothing automatic would notice if
# `linter.rules.preset` (Biome 2.5's schema form) silently switched nothing on.
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
PRETTIER_VER="$(grep -oE '"prettier@[^"]+"' "$REPO/.pre-commit-config.yaml" | head -1 | sed -E 's/.*prettier@([^"]+)"/\1/')"
[[ -n "$BIOME_VER" ]] && pass "biome pin read from the hook: $BIOME_VER" || fail "biome pin present in .pre-commit-config.yaml"
[[ -n "$PRETTIER_VER" ]] && pass "prettier pin read from the hook: $PRETTIER_VER" || fail "prettier pin present in .pre-commit-config.yaml"
SCHEMA_VER="$(jq -r 'to_entries[] | select(.key | endswith("schema")) | .value' "$REPO/biome.json" | sed -E 's#.*/schemas/([^/]+)/.*#\1#')"
assert_eq "biome.json \$schema version matches the hook's tool pin" "$BIOME_VER" "$SCHEMA_VER"

biome() { npx --yes "@biomejs/biome@$BIOME_VER" "$@"; }
prettier() { npx --yes "prettier@$PRETTIER_VER" "$@"; }

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

# The discriminating control: with the preset off, the same fixture must NOT
# report the recommended rules — otherwise the assertions above would pass on
# any failing run and prove nothing about the preset key.
mkdir -p "$WORK/biome-none" && cp "$WORK/biome/bad.ts" "$WORK/biome-none/"
python3 - "$REPO/biome.json" "$WORK/biome-none/biome.json" <<'PY'
import json,sys
c=json.load(open(sys.argv[1])); c["linter"]["rules"]["preset"]="none"
json.dump(c,open(sys.argv[2],"w"))
PY
out_none="$(cd "$WORK/biome-none" && biome lint bad.ts 2>&1)"
if grep -q 'noUnusedVariables' <<<"$out_none"; then fail "control: preset none does not fire noUnusedVariables" "$out_none"; else pass "control: preset none does not fire noUnusedVariables"; fi
if grep -q 'noDebugger' <<<"$out_none"; then fail "control: preset none does not fire noDebugger" "$out_none"; else pass "control: preset none does not fire noDebugger"; fi
grep -q 'noUnusedImports' <<<"$out_none" && pass "control: the explicit rule still fires with preset none" || fail "control: the explicit rule still fires with preset none" "$out_none"

section "biome: a clean file passes the hook's own command"
cat >"$WORK/biome/good.ts" <<'EOF'
export function add(a: number, b: number): number {
  return a + b;
}
EOF
(cd "$WORK/biome" && biome check --files-ignore-unknown=true --no-errors-on-unmatched good.ts >/dev/null 2>&1) && pass "check passes a clean, formatted file" || fail "check passes a clean, formatted file" "$(cd "$WORK/biome" && biome check good.ts 2>&1)"

section "biome: the formatter settings are honoured"
printf 'function f(a,b){\n\treturn a+b;\n}\n' >"$WORK/biome/ugly.ts"
if (cd "$WORK/biome" && biome format ugly.ts >/dev/null 2>&1); then fail "format reports the tab-indented fixture" "exit 0"; else pass "format reports the tab-indented fixture"; fi
fmt="$(cd "$WORK/biome" && biome format --stdin-file-path=x.ts <"$WORK/biome/ugly.ts" 2>/dev/null)"
grep -q '^  return a + b;' <<<"$fmt" && pass "indentStyle space / indentWidth 2 applied" || fail "indentStyle space / indentWidth 2 applied" "$fmt"
long="const s = \"$(printf 'x%.0s' $(seq 1 60))\" + \"$(printf 'y%.0s' $(seq 1 20))\";" # 97 chars: fits 100, not 80
fmt_long="$(cd "$WORK/biome" && biome format --stdin-file-path=x.ts <<<"$long" 2>/dev/null)"
[[ "$(wc -l <<<"$fmt_long" | tr -d ' ')" == "1" ]] && pass "lineWidth 100 keeps a 97-char statement on one line" || fail "lineWidth 100 keeps a 97-char statement on one line" "$fmt_long"

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
# Control: without files.includes the same tree DOES flag dist/ and
# renovate.json, so the passes above prove the key, not an empty run.
python3 - "$T/biome.json" <<'PY2'
import json,sys
c=json.load(open(sys.argv[1])); c.pop("files",None); json.dump(c,open(sys.argv[1],"w"))
PY2
out_ctl="$(cd "$T" && biome check . 2>&1)"
grep -q 'dist/out.js' <<<"$out_ctl" && grep -q 'renovate.json' <<<"$out_ctl" && pass "control: without files.includes, dist/ and renovate.json are flagged" || fail "control: without files.includes, dist/ and renovate.json are flagged" "$out_ctl"

section "prettier: the shipped .prettierrc governs HTML"
mkdir -p "$WORK/prettier" && cp "$REPO/.prettierrc" "$WORK/prettier/"
printf '<div>\n<p>hi</p>\n</div>\n' >"$WORK/prettier/bad.html" # child not indented
if (cd "$WORK/prettier" && prettier --check bad.html >/dev/null 2>&1); then fail "--check fails an unformatted HTML file" "exit 0"; else pass "--check fails an unformatted HTML file"; fi
(cd "$WORK/prettier" && prettier bad.html >good.html 2>/dev/null && prettier --check good.html >/dev/null 2>&1) && pass "--check passes the file prettier itself wrote" || fail "--check passes the file prettier itself wrote"
# 92-char line: under printWidth 100 it stays; under prettier's default 80 it wraps.
printf '<p class="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" id="bbbbbbbbbbbbbbbbbbbbbbbb">wide</p>\n' >"$WORK/prettier/wide.html"
(cd "$WORK/prettier" && prettier --check wide.html >/dev/null 2>&1) && pass "printWidth 100: a 92-char line is left alone" || fail "printWidth 100: a 92-char line is left alone" "$(cd "$WORK/prettier" && prettier wide.html 2>&1)"
if (cd "$WORK/prettier" && prettier --no-config --check wide.html >/dev/null 2>&1); then fail "control: without .prettierrc the same line is reflowed" "exit 0"; else pass "control: without .prettierrc the same line is reflowed"; fi

finish
