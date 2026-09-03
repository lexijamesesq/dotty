#!/usr/bin/env bash
# smoke.sh — /smoke's probe suite.
#
# On-demand Mac-side configuration health check: proves each protection layer
# (hooks, lint gate, registered automation) is wired RIGHT NOW, not that it
# was wired the day it shipped. Read-only, no network, no credentials, no
# writes — every probe exercises the real surface (pipes JSON at the real
# hook, runs the real test suite, parses the real live settings.json) and
# reports; it never fixes anything.
#
# Output: one line per probe, "PASS|FAIL <probe-name>: <detail>", then a
# summary line. Exit 0 iff zero FAILs.
#
# Each probe runs a STALENESS assertion before its health assertion: if the
# surface it targets is missing or moved, that is itself a loud FAIL naming
# the staleness — never a silent skip. A probe that quietly stops checking
# because its target moved is worse than a probe that never existed.
#
# Growth rule: a probe is added only after a real silent-misconfiguration
# incident bites — never speculatively. See SKILL.md for the probes'
# incident provenance.
#
# Spec: SKILL.md (this directory)

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"  # -P: sessions invoke via the profile symlink; walk the physical tree or SKILLS_DIR lands in $HOME
# Self-location: smoke.sh lives at <skills-dir>/smoke/smoke.sh — its own
# parent IS the skills dir, in dotty's tree and in a packaged plugin's tree
# alike. Never assume a literal ".claude" ancestor above it (LEX-698).
SKILLS_DIR="$(cd "$HERE/.." && pwd)"

FAIL_COUNT=0
RESULT_LINES=()

# report <PASS|FAIL> <probe-name> <detail...> — records one result line and
# tallies failures. Never exits — every probe runs regardless of prior FAILs.
report() {
    local status="$1" name="$2"
    shift 2
    RESULT_LINES+=("$status $name: $*")
    [[ "$status" == "FAIL" ]] && FAIL_COUNT=$((FAIL_COUNT + 1))
}

# ---------------------------------------------------------------------------
# Probe 1: hook-tilde-expansion
#
# Proves vault-mcp-redirect.sh still expands a tilde-form VAULT_ROOT before
# comparing it against a realpath-resolved target. Regression class: the
# 2026-06-02 incident where both vault hooks compared a realpath-resolved
# absolute path against an UNEXPANDED tilde, so the `case` match never fired
# and generic tools silently passed through on every vault .md file.
# ---------------------------------------------------------------------------
probe_hook_tilde_expansion() {
    local name="hook-tilde-expansion"
    local hook="$SKILLS_DIR/../hooks/vault-mcp-redirect.sh"

    # Staleness: the hook this probe pipes JSON at must still exist and be
    # executable, or every result below is meaningless.
    if [[ ! -x "$hook" ]]; then
        report FAIL "$name" \
            "vault-mcp-redirect.sh missing or not executable at $hook (staleness — the probed surface moved)"
        return
    fi

    # The probed path need not exist — the hook's realpath fallback returns
    # the raw target unchanged when realpath can't resolve it.
    local payload rc_block rc_open
    payload='{"tool_name":"Read","tool_input":{"file_path":"'"$HOME"'/__smoke_fixture__/x.md"}}'

    # Health, block case: tilde-form VAULT_ROOT, single-quoted so THIS shell
    # never expands it — the hook must expand it internally (via its own
    # ${VAULT/#\~/$HOME}) and block (exit 2). If the hook's tilde-expansion
    # regresses, this exit code silently reverts to 0.
    # shellcheck disable=SC2088  # intentional — this probe exists to prove
    # the HOOK expands the tilde; expanding it here would defeat the test.
    printf '%s' "$payload" | VAULT_ROOT='~/__smoke_fixture__' "$hook" >/dev/null 2>&1
    rc_block=$?

    # Inverse control: VAULT_ROOT unset entirely must fail-open (exit 0).
    # Without this control, a hook that always exits 2 (e.g. broken jq
    # detection) would look like a PASS above for the wrong reason.
    printf '%s' "$payload" | env -u VAULT_ROOT "$hook" >/dev/null 2>&1
    rc_open=$?

    if [[ "$rc_block" -eq 2 && "$rc_open" -eq 0 ]]; then
        report PASS "$name" \
            "tilde VAULT_ROOT blocked (exit 2); unset VAULT_ROOT fell open (exit 0)"
    else
        report FAIL "$name" \
            "expected block=2/open=0, got block=$rc_block/open=$rc_open — tilde-expansion regression (2026-06-02 class)"
    fi
}

# ---------------------------------------------------------------------------
# Probe 2: lint-suite
#
# Proves lint.py's fixture suite still passes. Regression class: a false-
# green fixture class plus a python-version drift that changed check
# behavior between machines — both caught only by re-running the suite, not
# by reading the script.
# ---------------------------------------------------------------------------
probe_lint_suite() {
    local name="lint-suite"
    local tests_dir="$HOME/Repos/wiki/.claude/skills/lint-knowledge/tests"
    local runner="$tests_dir/run_tests.py"

    # Staleness: the suite this probe runs must still exist at its known path.
    if [[ ! -f "$runner" ]]; then
        report FAIL "$name" \
            "run_tests.py missing at $runner (staleness — the probed surface moved)"
        return
    fi

    local output rc tail_text
    output="$(cd "$tests_dir" && python3 run_tests.py 2>&1)"
    rc=$?

    if [[ "$rc" -eq 0 ]]; then
        report PASS "$name" "run_tests.py exited 0"
    else
        tail_text="$(printf '%s\n' "$output" | tail -n 5 | tr '\n' '|')"
        report FAIL "$name" "run_tests.py exited $rc — tail: $tail_text"
    fi
}

# ---------------------------------------------------------------------------
# Probe 3: hook-registration-integrity
#
# Proves every .sh hook a live settings.json registers still exists and is
# executable. Regression class: a stale registered hook — a settings.json
# entry pointing at a path that moved or lost its executable bit, invisible
# until the hook silently failed to fire.
#
# Parses with python3, not jq — jq may be at a nonstandard path and is not a
# hard dependency of this probe.
# ---------------------------------------------------------------------------
PY_HOOK_CHECK="$(cat <<'PYEOF'
import json, os, sys

def check_profile(path):
    with open(path, "r", encoding="utf-8") as f:
        data = json.load(f)
    hooks_root = data.get("hooks", {})
    total = 0
    bad = []
    for _event, entries in hooks_root.items():
        if not isinstance(entries, list):
            continue
        for entry in entries:
            if not isinstance(entry, dict):
                continue
            for h in entry.get("hooks", []):
                if not isinstance(h, dict):
                    continue
                cmd = h.get("command", "")
                if not cmd:
                    continue
                toks = cmd.split()
                if not toks:
                    continue
                first = toks[0]
                # A command counts as a file-path command iff its first
                # token, after ~ expansion, ends in .sh. This filters out
                # inline commands like `echo '...'`.
                expanded = os.path.expanduser(first) if first.startswith("~") else first
                if expanded.endswith(".sh"):
                    total += 1
                    ok = os.path.isfile(expanded) and os.access(expanded, os.X_OK)
                    if not ok:
                        bad.append(expanded)
    return total, bad

overall_bad = False
for path in sys.argv[1:]:
    if "personal" in path:
        label = "personal"
    elif "professional" in path:
        label = "professional"
    else:
        label = path
    try:
        total, bad = check_profile(path)
    except Exception as e:
        print(f"PARSE_ERROR\t{label}\t{e}")
        overall_bad = True
        continue
    ok_count = total - len(bad)
    if bad:
        overall_bad = True
        print(f"BAD\t{label}\t{ok_count}/{total} registered .sh hooks ok — missing/non-executable: {', '.join(bad)}")
    else:
        print(f"OK\t{label}\t{ok_count}/{total} registered .sh hooks ok")

sys.exit(1 if overall_bad else 0)
PYEOF
)"

probe_hook_registration_integrity() {
    local name="hook-registration-integrity"
    local personal="$HOME/.claude-personal/settings.json"
    local professional="$HOME/.claude-professional/settings.json"
    local existing=()

    [[ -f "$personal" ]] && existing+=("$personal")
    [[ -f "$professional" ]] && existing+=("$professional")

    # Staleness: at least one profile settings.json must still exist, or
    # there is nothing live to check registration against.
    if [[ "${#existing[@]}" -eq 0 ]]; then
        report FAIL "$name" \
            "neither $personal nor $professional exists (staleness — the probed surface moved)"
        return
    fi

    local py_out py_rc
    py_out="$(python3 -c "$PY_HOOK_CHECK" "${existing[@]}")"
    py_rc=$?

    local detail_parts=() overall_ok=1 line_status label rest
    while IFS=$'\t' read -r line_status label rest; do
        [[ -z "$line_status" ]] && continue
        if [[ "$line_status" == "OK" ]]; then
            detail_parts+=("$label: $rest")
        else
            overall_ok=0
            detail_parts+=("$label: $line_status $rest")
        fi
    done <<<"$py_out"

    # Manual join, not `IFS='; '; "${arr[*]}"` — array-join IFS uses only its
    # FIRST character as the separator, which would silently drop the space.
    local joined="" part
    for part in "${detail_parts[@]}"; do
        [[ -z "$joined" ]] && joined="$part" || joined="$joined; $part"
    done

    if [[ "$py_rc" -eq 0 && "$overall_ok" -eq 1 ]]; then
        report PASS "$name" "$joined"
    else
        report FAIL "$name" "$joined"
    fi
}

# ---------------------------------------------------------------------------
# Probe 4: core-symlink-integrity
#
# Proves every per-entry symlink declared in the core blueprint slice exists,
# is a symlink, and resolves to the declared target — not merely that it
# resolves. Regression class: the 2026-07-18 incidents where a dangling
# agents symlink persisted for two months after its target was deleted, and
# ~/.git pointed at a tree whose content sat one level down, producing 56
# phantom deletions visible to any session under $HOME.
# ---------------------------------------------------------------------------
probe_core_symlink_integrity() {
    local name="core-symlink-integrity"
    local state_file="$HOME/bin/dotty-private/.claude/blueprint/core.json"

    if [[ ! -f "$state_file" ]]; then
        report FAIL "$name" \
            "core.json missing at $state_file (staleness — the blueprint state file moved)"
        return
    fi

    local bad=0 checked=0 issues=""
    while IFS=$'\t' read -r profile surface entry_name declared_target; do
        [[ -z "$entry_name" ]] && continue
        local expanded_target="${declared_target/#\~/$HOME}"
        local link="$HOME/.claude-$profile/$surface/$entry_name"
        checked=$((checked + 1))

        if [[ ! -L "$link" ]]; then
            issues="$issues $profile/$surface/$entry_name(not-a-symlink)"
            bad=$((bad + 1))
        elif [[ "$(readlink "$link")" != "$expanded_target" ]]; then
            issues="$issues $profile/$surface/$entry_name(wrong-target)"
            bad=$((bad + 1))
        elif [[ ! -e "$link" ]]; then
            issues="$issues $profile/$surface/$entry_name(dangling)"
            bad=$((bad + 1))
        fi
    done < <(python3 -c '
import json, sys
with open(sys.argv[1]) as f:
    state = json.load(f)
for profile, surfaces in sorted(state.items()):
    for surface, entries in sorted(surfaces.items()):
        for name, target in sorted(entries.items()):
            print(f"{profile}\t{surface}\t{name}\t{target}")
' "$state_file")

    if [[ "$checked" -eq 0 ]]; then
        report FAIL "$name" \
            "0 declared entries read from core.json (parse failure or empty state — never a clean pass)"
    elif [[ "$bad" -eq 0 ]]; then
        report PASS "$name" "$checked declared symlinks verified"
    else
        report FAIL "$name" "$bad/$checked broken:$issues"
    fi
}

# ---------------------------------------------------------------------------
# Probe 5: blueprint-coverage
#
# Proves every skill directory in dotty's skills tree has a core-blueprint
# entry in BOTH profiles — the inverse of probe 4, which checks declared
# entries resolve. Regression class: the 2026-07-31 incident where wayfinder
# and prototype shipped in dotty but were never added to core.json, so they
# loaded nowhere until the operator noticed the skill missing globally.
# ---------------------------------------------------------------------------
probe_blueprint_coverage() {
    local name="blueprint-coverage"
    local state_file="$HOME/bin/dotty-private/.claude/blueprint/core.json"
    local skills_dir="$SKILLS_DIR"

    if [[ ! -f "$state_file" ]]; then
        report FAIL "$name" \
            "core.json missing at $state_file (staleness — the blueprint state file moved)"
        return
    fi
    if [[ ! -d "$skills_dir" ]]; then
        report FAIL "$name" \
            "skills dir missing at $skills_dir (staleness — the skills tree moved)"
        return
    fi

    local missing py_rc
    missing="$(python3 -c '
import json, os, sys
state = json.load(open(sys.argv[1]))
dirs = sorted(
    d for d in os.listdir(sys.argv[2])
    if os.path.isdir(os.path.join(sys.argv[2], d)) and not d.startswith(("__", "."))
)
gaps = []
for profile, surfaces in sorted(state.items()):
    declared = set(surfaces.get("skills", {}))
    for d in dirs:
        if d not in declared:
            gaps.append(f"{profile}:{d}")
print(" ".join(gaps))
' "$state_file" "$skills_dir" 2>&1)"
    py_rc=$?

    if (( py_rc != 0 )); then
        report FAIL "$name" \
            "core.json or skills tree unreadable: ${missing:-unknown error}"
        return
    fi

    if [[ -z "$missing" ]]; then
        report PASS "$name" "every dotty skill dir declared in both profiles"
    else
        report FAIL "$name" "undeclared in core.json: $missing"
    fi
}

# ---------------------------------------------------------------------------
# Probe 6: plugin-hook-serving-integrity
#
# Proves that when a profile's settings.json registers no hooks directly
# (hooks: {}), meaning its guards are meant to run from the
# estate-hooks@work-lifecycle plugin, that plugin is actually enabled AND its
# installed cache still serves every hook the plugin declares — cross-checked
# against plugin.json's own "hooks" list (ground truth authored alongside the
# scripts), not against hooks.json alone, which would be self-referential.
# Regression class: LEX-697's spike finding that enabling/disabling a plugin
# only mutates enabledPlugins in settings.json with nothing auditing it — a
# profile silently disabled would drop all nine guard hooks (git-hook-bypass,
# gh-pr-body, gated-verb, etc.) with zero visible signal until an incident
# proved it missing, the same failure shape as every other probe in this
# file.
#
# Generalizes to any number of profiles: globs $HOME/.claude-* for
# directories that carry a settings.json, rather than hardcoding
# personal/professional as probes 3-4 do.
# ---------------------------------------------------------------------------
PY_PLUGIN_HOOK_CHECK="$(cat <<'PYEOF'
import json, os, sys

PLUGIN_KEY = "estate-hooks@work-lifecycle"


def load_json(path):
    with open(path, "r", encoding="utf-8") as f:
        return json.load(f)


def registered_sh_basenames(hooks_root):
    names = set()
    if not isinstance(hooks_root, dict):
        return names
    for _event, entries in hooks_root.items():
        if not isinstance(entries, list):
            continue
        for entry in entries:
            if not isinstance(entry, dict):
                continue
            for h in entry.get("hooks", []):
                if not isinstance(h, dict):
                    continue
                cmd = h.get("command", "")
                if not cmd:
                    continue
                toks = cmd.split()
                if not toks:
                    continue
                first = toks[0].strip('"')
                base = os.path.basename(first)
                if base.endswith(".sh"):
                    names.add(base)
    return names


def check_profile(profile_dir):
    label = os.path.basename(profile_dir)
    settings_path = os.path.join(profile_dir, "settings.json")
    try:
        settings = load_json(settings_path)
    except Exception as e:
        return ("FAIL", label, f"settings.json unreadable at {settings_path}: {e} (staleness)")

    # Only a literal hooks: {} means "guards are meant to be plugin-served" —
    # a missing "hooks" key entirely (e.g. a pre-plugin-era profile) is not a
    # shape this probe is designed to reason about, same bucket as a profile
    # with hooks registered directly.
    _absent = object()
    hooks_value = settings.get("hooks", _absent)
    if hooks_value != {}:
        return ("PASS", label,
                 "settings.json \"hooks\" is not the literal {} shape (absent, non-empty, or "
                 "non-dict) — plugin-serving probe not applicable")

    enabled = settings.get("enabledPlugins", {}).get(PLUGIN_KEY)
    if enabled is not True:
        return ("FAIL", label,
                 f'hooks:{{}} (plugin-served) but enabledPlugins["{PLUGIN_KEY}"] is '
                 f"{enabled!r}, not true — guards are silently disabled")

    installed_path = os.path.join(profile_dir, "plugins", "installed_plugins.json")
    try:
        installed = load_json(installed_path)
    except Exception as e:
        return ("FAIL", label,
                 f"installed_plugins.json unreadable at {installed_path}: {e} (staleness)")

    entries = installed.get("plugins", {}).get(PLUGIN_KEY, [])
    user_entries = [e for e in entries if isinstance(e, dict) and e.get("scope") == "user"]
    if not user_entries:
        return ("FAIL", label,
                 f'enabledPlugins["{PLUGIN_KEY}"] is true but installed_plugins.json has no '
                 f"scope:user install entry for it — enabled but not actually installed")

    install_path = user_entries[0].get("installPath")
    if not install_path or not os.path.isdir(install_path):
        return ("FAIL", label, f"installPath missing or not a directory: {install_path}")

    plugin_json_path = os.path.join(install_path, ".claude-plugin", "plugin.json")
    try:
        plugin_json = load_json(plugin_json_path)
    except Exception as e:
        return ("FAIL", label, f"plugin.json unreadable at {plugin_json_path}: {e} (staleness)")

    declared = plugin_json.get("hooks")
    if not isinstance(declared, list) or not declared:
        return ("FAIL", label,
                 f'plugin.json at {plugin_json_path} has no non-empty "hooks" list '
                 "(staleness — ground-truth field missing)")

    hooks_json_path = os.path.join(install_path, "hooks", "hooks.json")
    try:
        hooks_json = load_json(hooks_json_path)
    except Exception as e:
        return ("FAIL", label, f"hooks/hooks.json unreadable at {hooks_json_path}: {e} (staleness)")

    registered = registered_sh_basenames(hooks_json.get("hooks", {}))

    missing_registration = sorted(set(declared) - registered)
    extra_registration = sorted(registered - set(declared))

    missing_files = []
    for fname in declared:
        p = os.path.join(install_path, "hooks", fname)
        if not os.path.isfile(p) or os.path.getsize(p) == 0:
            missing_files.append(fname)

    problems = []
    if missing_registration:
        problems.append("declared in plugin.json but not registered in hooks.json: "
                         + ", ".join(missing_registration))
    if extra_registration:
        problems.append("registered in hooks.json but not declared in plugin.json: "
                         + ", ".join(extra_registration))
    if missing_files:
        problems.append("missing or empty in cache hooks/: " + ", ".join(missing_files))

    if problems:
        return ("FAIL", label, f"cache at {install_path} — " + "; ".join(problems))

    return ("PASS", label,
            f"{len(declared)} plugin-declared hooks all registered in hooks.json and present "
            f"non-empty in cache ({install_path})")


def main():
    results = [check_profile(p) for p in sys.argv[1:]]
    overall_ok = all(r[0] == "PASS" for r in results)
    for status, label, detail in results:
        print(f"{status}\t{label}\t{detail}")
    sys.exit(0 if overall_ok else 1)


main()
PYEOF
)"

probe_plugin_hook_serving() {
    local name="plugin-hook-serving-integrity"
    local profile_dirs=() d

    for d in "$HOME"/.claude-*; do
        [[ -f "$d/settings.json" ]] && profile_dirs+=("$d")
    done

    # Staleness: at least one $HOME/.claude-* profile directory with a
    # settings.json must exist, or there is nothing live to check.
    if [[ "${#profile_dirs[@]}" -eq 0 ]]; then
        report FAIL "$name" \
            "no \$HOME/.claude-* directory with a settings.json found (staleness — the probed surface moved)"
        return
    fi

    local py_out py_rc
    py_out="$(python3 -c "$PY_PLUGIN_HOOK_CHECK" "${profile_dirs[@]}")"
    py_rc=$?

    local detail_parts=() overall_ok=1 line_status label rest
    while IFS=$'\t' read -r line_status label rest; do
        [[ -z "$line_status" ]] && continue
        if [[ "$line_status" == "PASS" ]]; then
            detail_parts+=("$label: $rest")
        else
            overall_ok=0
            detail_parts+=("$label: $line_status $rest")
        fi
    done <<<"$py_out"

    local joined="" part
    for part in "${detail_parts[@]}"; do
        [[ -z "$joined" ]] && joined="$part" || joined="$joined; $part"
    done

    if [[ "$py_rc" -eq 0 && "$overall_ok" -eq 1 ]]; then
        report PASS "$name" "$joined"
    else
        report FAIL "$name" "$joined"
    fi
}

# ---------------------------------------------------------------------------
# Run all probes, print results, summarize, exit.
# ---------------------------------------------------------------------------
probe_hook_tilde_expansion
probe_lint_suite
probe_hook_registration_integrity
probe_core_symlink_integrity
probe_blueprint_coverage
probe_plugin_hook_serving

for line in "${RESULT_LINES[@]}"; do
    printf '%s\n' "$line"
done

TOTAL="${#RESULT_LINES[@]}"
PASS_COUNT=$((TOTAL - FAIL_COUNT))
if [[ "$FAIL_COUNT" -eq 0 ]]; then
    printf 'SUMMARY: %d/%d probes passed\n' "$PASS_COUNT" "$TOTAL"
else
    printf 'SUMMARY: %d/%d probes passed, %d failed\n' "$PASS_COUNT" "$TOTAL" "$FAIL_COUNT"
fi

[[ "$FAIL_COUNT" -eq 0 ]]
