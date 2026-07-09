#!/usr/bin/env bash
# gh-pr-body-guard.sh — FAIL-CLOSED PreToolUse guard that scans a `gh pr create`
# (or `gh pr edit`) invocation for guarded literals BEFORE it runs. A PR title
# and body are public the instant `gh pr create` executes; gitleaks' git/commit
# hooks scan file diffs and NEVER see `gh` arguments, so without this guard the
# title/body are an unscanned public surface.
#
# WHY SCAN THE WHOLE COMMAND STRING (deliberate over-block):
#   Parsing gh's flags (--body / --body-file / --title / --fill / heredocs /
#   $(cat <<'EOF' ...)) is fragile and is defeated by the first unusual quoting.
#   Instead we write the ENTIRE tool_input.command to a temp file and run
#   `gitleaks dir` on it. The title and body are literally present in that text,
#   so any guarded literal is caught regardless of how it was passed.
#   CONSEQUENCE — this over-blocks on purpose: a guarded value ANYWHERE in the
#   command (a `-R owner/repo`, a random flag, a comment) blocks the create, not
#   only one in the body. That is the safe direction; it is stated in the block
#   message so a human is never mystified.
#   PR TITLES ARE IN SCOPE: titles are frequently synced from Linear issue titles
#   which routinely carry employer + internal product names (a guarded class).
#   Ticket refs (`Closes <TEAM>-N`) are ALLOWED and are not a guarded class — the
#   operator ruleset carries no ticket-id rule, so they do not match.
#
# --body-file / -F: those contents are NOT in the command string, so we also read
#   and scan the referenced file. To find the path we tokenize the command with a
#   shell-aware parser (python3 `shlex.split`), NOT whitespace splitting. That
#   matters: a `-F` mentioned inside a quoted body ("... use -F ...") stays inside
#   the body token and is never a standalone argv element, so it is not mistaken
#   for the flag. BOTH forms are FAIL-CLOSED: if `--body-file`/`-F` is present but
#   its path does not resolve to a readable file — or the flag has no argument, or
#   the command cannot be tokenized — we BLOCK (the intended PR body cannot be
#   scanned). python3 is a hard dependency; missing python3 -> BLOCK.
#
# FAIL-CLOSED contract (North star: a missing binary, an unresolvable config, or
# an indeterminate target must BLOCK, never silently pass):
#   * jq / python3 missing   -> BLOCK (cannot parse the invocation / its args).
#   * gitleaks missing       -> BLOCK (via gl_preflight; names the install).
#   * not inside a git repo  -> BLOCK (names the fix: run from the repo root).
#   * no .gitleaks.toml      -> BLOCK (via gl_preflight; names provisioning).
#   * broken [extend] target -> BLOCK (via gl_preflight; names provisioning).
#   * --body-file / -F unresolvable, no arg, or unparsable command -> BLOCK.
#   * gitleaks FTL / nonzero -> BLOCK.
# A guarded literal is NEVER printed — only rule id + location (gl_summarize_report).
#
# OBJECTIVE TENSION (surfaced, not resolved): `gh pr create` is often run from a
# session rooted somewhere other than the target repo (the documented "publishing
# from another session" case), and `gh pr create -R owner/repo` may target a repo
# with no local checkout at all. gitleaks resolves a config's `[extend] path`
# relative to the PROCESS cwd, so the guard must run inside a repo that carries
# the operator ruleset. When cwd is not such a repo, fail-closed BLOCKS a workflow
# the operator uses daily. This guard chooses to block and tell the operator
# exactly what to do (cd into the target checkout) rather than fail open on the
# most leak-prone path. See the block messages below.
#
# SCOPE POROSITY (disclosed, not a defect): this guard recognises a PR-publishing
# command by STRING-MATCHING the normalised command text (see SELF-SCOPE below).
# String matching cannot see through shell indirection: a command that assembles
# the subcommand via a variable (`c=create; gh pr $c --body ...`), a shell alias
# or function, or `eval`, will NOT match the scope regex and passes UNSCANNED.
# This is a known, accepted gap — the same class git-hook-bypass-guard.sh
# discloses. The threat model is an ACCIDENTAL leak in an ordinary `gh pr create`,
# NOT a determined operator routing around their own guard. Do not read the scope
# match as a security boundary; it is a best-effort trigger for the common case.
#
# Blocks a PreToolUse tool call by exiting 2 with the reason on stderr.
#
# Spec: {workspace_root}/System/Knowledge/leak-prevention-architecture.md

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$HERE/../../git-hooks/gitleaks-common.sh"

CONFIG=".gitleaks.toml"   # relative — resolved from cwd (= repo root, see below)

# block <title> [line ...] — emit a formatted gl_block to stderr and BLOCK (exit 2).
block() { gl_block "$@"; exit 2; }

# ---------------------------------------------------------------------------
# Parse the tool payload. jq is required; missing jq is fail-closed.
# ---------------------------------------------------------------------------
command -v jq >/dev/null 2>&1 || block \
    "PR-guard BLOCKED: jq is not installed" \
    "Cannot parse the tool invocation to scan the PR title/body." \
    "This guard fails closed rather than allow an unscanned 'gh pr create'." \
    "Install:  brew install jq"

INPUT="$(cat)"
TOOL_NAME="$(printf '%s' "$INPUT" | jq -r '.tool_name // empty' 2>/dev/null || true)"
[[ "$TOOL_NAME" == "Bash" ]] || exit 0   # not a Bash tool call — not our concern

COMMAND="$(printf '%s' "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null || true)"
[[ -n "$COMMAND" ]] || exit 0            # nothing to scan

# ---------------------------------------------------------------------------
# SELF-SCOPE. This guard concerns `gh pr create` / `gh pr edit` and nothing
# else, and it must decide that itself — the settings `"if"` field cannot be
# trusted to do it.
#
# `"if"` IS a supported, documented field, and it works. But it FAILS OPEN into
# running the hook: when the pattern names more than the bare command (as
# `"Bash(gh pr create *)"` does), Claude Code runs the hook anyway for any
# command containing `$(...)`, backticks, or `$VAR`, because it cannot statically
# evaluate what those expand to. So `"if"` is a performance pre-filter, never a
# correctness boundary. A non-blocking reminder hook may rely on it. A guard that
# BLOCKS may not: registered on `"if"` alone, this fail-closed hook fired on an
# ordinary shell command and blocked every Bash call issued from a cwd without a
# .gitleaks.toml. Verified the hard way. Scope here, in the script, or not at all.
#
# Match `gh pr create|edit` as a COMMAND, not as a bare substring. Two failures
# this avoids, both found by testing rather than by reading:
#
#   fail-OPEN: a shell line-continuation splitting the subcommand
#     `gh pr \`<newline>`create`
#   survives whitespace normalisation as `gh pr \ create`, so a substring test
#   misses it and the guard silently skips a real PR create. Continuations are
#   therefore stripped BEFORE matching.
#
#   fail-CLOSED over-block: a substring test fires on any command that merely
#   MENTIONS the literal — an echo, a grep, a doc edit, a test loop. Since this
#   guard blocks when cwd has no .gitleaks.toml, that makes those commands
#   unrunnable from a vault-rooted session. So `gh` must appear in command
#   position: at the start, or after a shell separator, optionally preceded by
#   env assignments (`FOO=bar gh pr create ...`).
#
# Real newlines become `;` rather than spaces — they ARE command separators, and
# collapsing them to whitespace would hide `gh pr create` on a later line of a
# multi-line script behind a leading space, reopening the fail-open.
# ---------------------------------------------------------------------------
_scope_raw="${COMMAND//\\$'\n'/ }"        # line continuations -> single space
_scope_raw="${_scope_raw//$'\n'/ ; }"     # newlines are command separators
_scope_norm="$(tr -s '[:space:]' ' ' <<<"$_scope_raw")"
# Strip shell quote characters. The shell removes them before executing, so
# `gh pr "create"`, `"gh" pr create`, and `g"h" pr create` are all REAL PR
# invocations that must normalise to `gh pr create`. Removing quotes only ever
# ADDS matches (surfaces a genuine command) — it deletes no separator, so it
# cannot mask an out-of-scope command as in-scope beyond the safe over-block.
_scope_norm="${_scope_norm//\"/}"
_scope_norm="${_scope_norm//\'/}"

# Command position = start of string, or after a separator (; && || | ( `),
# optionally preceded by wrapper words (env/time/sudo/nohup/command) and by
# leading env assignments (FOO=bar gh pr create ...).
_RE_GHPR='(^|[;&|(`])[[:space:]]*((env|time|sudo|nohup|command)[[:space:]]+)*([A-Za-z_][A-Za-z0-9_]*=[^ ]* )*gh[[:space:]]+pr[[:space:]]+(create|edit)([[:space:]]|$)'
[[ "$_scope_norm" =~ $_RE_GHPR ]] || exit 0   # not a PR-publishing command

ORIG_CWD="$(printf '%s' "$INPUT" | jq -r '.cwd // empty' 2>/dev/null || true)"
[[ -n "$ORIG_CWD" ]] || ORIG_CWD="$PWD"

# ---------------------------------------------------------------------------
# Locate a repo that carries the operator gitleaks ruleset, and cd into it so
# gitleaks resolves the config's `[extend] path` relative to the repo root.
# ---------------------------------------------------------------------------
repo_root="$(git -C "$ORIG_CWD" rev-parse --show-toplevel 2>/dev/null)" || block \
    "PR-guard BLOCKED: not inside a git repository" \
    "cwd: $ORIG_CWD" \
    "A PR title/body can carry secrets, employer/product names, private URLs," \
    "email, or infra paths. The operator gitleaks ruleset lives in each repo's" \
    ".gitleaks.toml, so this guard must run from inside the target repo." \
    "Re-run 'gh pr create' from the repo root, e.g.:" \
    "    cd ~/bin/dotty && gh pr create ..." \
    "(A 'gh pr create -R owner/repo' from elsewhere is NOT covered — the ruleset" \
    " is local to a checkout; cd into that checkout to publish.)"

cd "$repo_root" || block \
    "PR-guard BLOCKED: cannot enter the repository root" \
    "cd '$repo_root' failed — refusing to allow an unscanned PR."

# Fail-closed preconditions (reuses the git-lifecycle hooks' helper): gitleaks
# binary present, .gitleaks.toml present, and its [extend] target resolvable.
gl_preflight "$CONFIG" || exit 2

# ---------------------------------------------------------------------------
# Assemble the scan corpus: the whole command text, plus any --body-file / -F
# file contents (which are not present in the command string).
# ---------------------------------------------------------------------------
scan_dir="$(mktemp -d)"
report="$(mktemp)"
errf="$(mktemp)"
# Inline trap (not a named function) — every path below exits explicitly, which
# defeats shellcheck's trap-invocation detection for a named handler (SC2329).
trap 'rm -rf "$scan_dir" "$report" "$errf"' EXIT INT TERM

printf '%s\n' "$COMMAND" > "$scan_dir/command.txt"

# Resolve a body-file path relative to the ORIGINAL cwd (where gh runs), not the
# repo root we cd'd into.
resolve_path() {
    case "$1" in
        /*) printf '%s' "$1" ;;
        *)  printf '%s/%s' "$ORIG_CWD" "$1" ;;
    esac
}

bf_idx=0
# add_body_file <resolved-path> -> 0 if scanned, 1 if unreadable
add_body_file() {
    local rp="$1"
    if [[ -f "$rp" && -r "$rp" ]]; then
        cp "$rp" "$scan_dir/bodyfile-${bf_idx}.txt" 2>/dev/null && { bf_idx=$((bf_idx + 1)); return 0; }
    fi
    return 1
}

# Extract any --body-file / -F path with a SHELL-AWARE tokenizer (python3 shlex),
# not whitespace splitting: a `-F` mentioned inside a quoted body stays inside the
# body token and is never a standalone argv element, so it is not mistaken for the
# flag. Both --body-file and -F are fail-closed (see header). python3 required.
command -v python3 >/dev/null 2>&1 || block \
    "PR-guard BLOCKED: python3 is not installed" \
    "Shell-aware tokenization (shlex) is required to extract --body-file / -F" \
    "paths reliably; this guard fails closed rather than guess." \
    "Install:  brew install python3"

bf_paths="$(printf '%s' "$COMMAND" | python3 -c '
import sys, shlex
try:
    toks = shlex.split(sys.stdin.read())
except ValueError:
    sys.exit(4)                        # command could not be tokenized
i, n = 0, len(toks)
while i < n:
    t = toks[i]
    if t in ("--body-file", "-F"):
        if i + 1 >= n:
            sys.exit(3)                # flag present with no path argument
        sys.stdout.write(toks[i + 1] + "\n"); i += 2; continue
    if t.startswith("--body-file="):
        sys.stdout.write(t[len("--body-file="):] + "\n")
    elif t.startswith("-F") and len(t) > 2:
        v = t[2:]
        sys.stdout.write((v[1:] if v.startswith("=") else v) + "\n")
    i += 1
')"
bf_rc=$?

case "$bf_rc" in
    0) ;;
    3) block "PR-guard BLOCKED: --body-file / -F has no path argument" \
            "A body-file flag was given with no following path — the intended PR" \
            "body cannot be located or scanned. (Fail-closed.)" ;;
    4) block "PR-guard BLOCKED: the command could not be parsed" \
            "shlex could not tokenize the 'gh pr create' invocation (unbalanced" \
            "quotes?). Refusing to allow a PR whose --body-file arguments cannot be" \
            "determined. Fix the command's quoting and retry. (Fail-closed.)" ;;
    *) block "PR-guard BLOCKED: body-file extraction failed" \
            "The tokenizer exited $bf_rc unexpectedly — refusing to proceed" \
            "unscanned. (Fail-closed.)" ;;
esac

# Scan every extracted body-file; an unresolvable/unreadable one is fail-closed
# (applies equally to --body-file and -F).
if [[ -n "$bf_paths" ]]; then
    while IFS= read -r p; do
        rp="$(resolve_path "$p")"
        add_body_file "$rp" || block \
            "PR-guard BLOCKED: --body-file / -F path is unreadable" \
            "Referenced: $p" \
            "Resolved:   $rp" \
            "gh would read this file as the PR body, but it does not exist or is" \
            "not readable from here, so its contents cannot be scanned." \
            "Fail-closed: fix the path (or run from where it resolves) and retry."
    done <<< "$bf_paths"
fi

# ---------------------------------------------------------------------------
# Scan. gitleaks dir exits 1 on findings OR config-load failure; distinguish via
# stderr (FTL). Any nonzero we cannot explain is fail-closed.
# ---------------------------------------------------------------------------
gitleaks dir "$scan_dir" \
    --config "$CONFIG" \
    --no-banner --redact \
    --report-format json --report-path "$report" \
    >/dev/null 2>"$errf"
rc=$?

if grep -qE 'FTL|Failed to load config' "$errf"; then
    block "PR-guard BLOCKED: gitleaks config failed to load" \
        "Config: $repo_root/$CONFIG" \
        "The operator ruleset could not be applied, so the PR was not scanned." \
        "(gitleaks resolves the [extend] path relative to its cwd; this guard cd'd" \
        " to the repo root, so a load failure here means a missing/broken ruleset.)" \
        "Provision the ruleset symlink via: setup-claude-profiles.sh"
elif [[ "$rc" -ne 0 ]]; then
    if [[ -s "$report" ]]; then
        gl_block "PR-guard BLOCKED: sensitive content in the PR title/body" \
            "A guarded literal appears in the 'gh pr create' invocation — in the" \
            "title, body, --body-file contents, or elsewhere in the command." \
            "Findings (rule / commit / file:line — matched values withheld):"
        gl_summarize_report "$report" >&2
        {
            echo "  This guard scans the ENTIRE command plus any --body-file, so a"
            echo "  guarded value ANYWHERE in the command blocks (intentional over-block)."
            echo "  Remediation:"
            echo "    * Remove the sensitive value from the PR title and body."
            echo "    * A title synced from a Linear issue can carry employer / internal"
            echo "      product names (a guarded class) — rename it before creating the PR."
            echo "    * Ticket refs like 'Closes <TEAM>-N' are ALLOWED and do not match."
            echo ""
        } >&2
        exit 2
    fi
    block "PR-guard BLOCKED: scanner returned an error" \
        "gitleaks exited $rc without a findings report — refusing to allow an" \
        "unverified PR. (Fail-closed: an unexplained scanner error must not pass.)"
fi

exit 0
