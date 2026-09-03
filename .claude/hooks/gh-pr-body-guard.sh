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
#   * no ruleset located (payload-cwd / cd-prefix / own-repo / env var) -> BLOCK.
#   * located .gitleaks.toml broken ([extend] unresolvable) -> BLOCK (gl_preflight).
#   * GITLEAKS_OPERATOR_RULES set but unreadable -> BLOCK.
#   * --body-file / -F unresolvable, no arg, or unparsable command -> BLOCK.
#   * gitleaks FTL / nonzero -> BLOCK.
# A guarded literal is NEVER printed — only rule id + location (gl_summarize_report).
#
# RULESET LOCATION (works from any session with ZERO configuration):
# Claude Code's PreToolUse payload reports the SESSION cwd, not the directory a
# command cd's into — and a cd inside a Bash command does not persist. So even
# `cd ~/bin/dotty && gh pr create ...` arrives here with cwd = the session root
# (often the vault: a git repo with NO .gitleaks.toml). What the guard needs is
# the operator RULESET, not any particular checkout — so it locates one four ways
# (see "LOCATE THE OPERATOR RULESET" below), first hit wins:
#   1. the payload cwd's repo          2. a `cd <path> && ...` prefix's repo
#   3. the guard's OWN repo (this file ships in the tooling repo, which carries
#      the .gitleaks.toml [extend]ing the fixed-path operator ruleset resolved
#      by gl_preflight)
#   4. $GITLEAKS_OPERATOR_RULES        else -> BLOCK
# Paths 1-3 need NO configuration on a provisioned machine; path 4 is an override
# for an UNPROVISIONED machine and is never required. (An env var would have to be
# hand-set in two places — profile + shell — which is the drift this epic kills.)
# Paths 1-3 locate a repo CONFIG; the operator ruleset it extends is resolved by
# gl_preflight — see git-hooks/gitleaks-common.sh for the resolution contract.
# Fail-closed is UNCHANGED: once a ruleset is located, a missing binary, a broken
# config, or any finding still BLOCKS.
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
# Tests: .claude/eval/gh-pr-body-guard.test.sh
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

# Temp artifacts + a single inline trap, installed up front. The values are
# filled in below; the trap reads them live at exit, so it removes whatever
# exists (empty ones are a suppressed no-op). Inline, not a named handler:
# every path exits explicitly, which defeats shellcheck's trap-invocation
# detection for a named function (SC2329).
scan_dir=""; report=""; errf=""; WRAPPER_TMP=""
# GL_TMP_CONFIG: gl_preflight's derived effective config, when it makes one.
trap 'rm -rf "$scan_dir" "$report" "$errf" "$WRAPPER_TMP" "$GL_TMP_CONFIG" 2>/dev/null || true' EXIT INT TERM

# ---------------------------------------------------------------------------
# LOCATE THE OPERATOR RULESET (see RULESET LOCATION in the header for why).
# Resolution order, first hit wins:
#   1. the payload cwd's git repo, if it carries a readable .gitleaks.toml
#   2. an explicit `cd <path> && ...` prefix whose target is such a repo
#   3. the guard's OWN repo (HERE/../..), if it carries a readable .gitleaks.toml
#      — zero-config; works from any session on a provisioned machine
#   4. $GITLEAKS_OPERATOR_RULES — override for an unprovisioned machine only
#   else -> BLOCK, naming all four.
# CFG_DIR  = the dir we cd into so gitleaks resolves [extend] correctly.
# CFG      = the --config value (repo-relative .gitleaks.toml, or an absolute
#            temp wrapper that [extend]s the env-var rules file by ABSOLUTE path).
# BODY_CWD = the cwd gh itself runs in, for resolving relative --body-file paths.
# ---------------------------------------------------------------------------
# repo_with_config <dir> -> prints the git repo root iff <dir> is inside a repo
# whose root has a readable .gitleaks.toml; else returns 1.
repo_with_config() {
    local d="$1" root
    root="$(git -C "$d" rev-parse --show-toplevel 2>/dev/null)" || return 1
    [[ -r "$root/.gitleaks.toml" ]] || return 1
    printf '%s' "$root"
}
# resolve_cd_chain <normalised-command> -> the EFFECTIVE working directory after
# consuming ALL leading `cd <path>` segments (delimited by && || ; or a newline,
# already ';' in the normalised text). A chained `cd A && cd B && gh ...` runs gh
# in B, not A — so we apply each cd IN ORDER: an absolute or ~/$HOME target
# replaces, a relative target is appended and normalised, and every intermediate
# MUST resolve to a real directory. Prints nothing if there is no leading cd OR
# any segment fails to resolve (FAIL-CLOSED: never guess the effective dir — a
# single-cd read would collapse the chain to the wrong dir and scan the wrong body).
resolve_cd_chain() {
    local s="$1" seg path eff=""
    s="${s//&&/;}"; s="${s//||/;}"                  # canonicalise sequencing ops -> ;
    while :; do
        s="${s#"${s%%[![:space:]]*}"}"              # left-trim
        [[ "$s" == cd[[:space:]]* ]] || break       # next segment isn't a cd -> stop
        seg="${s%%;*}"                              # this segment, up to the first ;
        if [[ "$seg" == "$s" ]]; then s=""; else s="${s#*;}"; fi
        path="${seg#cd}"
        path="${path#"${path%%[![:space:]]*}"}"     # strip leading ws after 'cd'
        path="${path%"${path##*[![:space:]]}"}"     # right-trim
        [[ -n "$path" ]] || return 0                # 'cd' with no arg -> bail (fail)
        path="${path//\\ / }"                       # unescape backslash-spaces
        path="${path/#\~/$HOME}"; path="${path//\$HOME/$HOME}"
        case "$path" in
            /*) eff="$path" ;;                      # absolute -> replace
            *)  eff="${eff:-$ORIG_CWD}/$path" ;;    # relative -> append to running dir
        esac
        eff="$(cd "$eff" 2>/dev/null && pwd)" || return 0   # must be a real dir
    done
    [[ -n "$eff" ]] && printf '%s' "$eff"
}

CFG_DIR=""; CFG=""; BODY_CWD="$ORIG_CWD"; RULESET_DESC=""

# Resolve the EFFECTIVE working dir once by walking the WHOLE leading cd chain
# (see resolve_cd_chain). CD_DIR is that dir if the chain fully resolves, else
# empty. Used for: the path-2 ruleset candidate, BODY_CWD (relative --body-file
# resolution — gh runs THERE), and excluding the whole cd prefix from the scan.
CD_DIR="$(resolve_cd_chain "$_scope_norm")"

# BODY_CWD is the directory `gh` itself will run in, and a relative --body-file
# must resolve THERE. That is the `cd` target whenever the command has one, and
# it has nothing to do with which of the three paths below located the ruleset.
# Deciding it per-path was a bug: a `cd <repo-without-.gitleaks.toml> && gh pr
# create --body-file ../body.md` fell through to path 3, kept the session cwd,
# and blocked on an unreadable body that `gh` would have read without trouble.
BODY_CWD="${CD_DIR:-$ORIG_CWD}"

# Path 1 — the payload cwd's repo.
if _root="$(repo_with_config "$ORIG_CWD")"; then
    CFG_DIR="$_root"; CFG="$CONFIG"
    RULESET_DESC="payload-cwd repo: $_root"
fi

# Path 2 — an explicit `cd <path> && ...` prefix (PreToolUse reports the SESSION
# cwd, not the cd target, so we honour the cd from the command text).
if [[ -z "$CFG_DIR" && -n "$CD_DIR" ]]; then
    if _root="$(repo_with_config "$CD_DIR")"; then
        CFG_DIR="$_root"; CFG="$CONFIG"
        RULESET_DESC="cd-prefix repo: $_root"
    fi
fi

# Path 3 — the guard's OWN repo (zero configuration). This hook ships in the
# public tooling repo, which carries a tracked .gitleaks.toml whose [extend] is
# resolved by gl_preflight against the fixed-path operator ruleset (installed by
# the blueprint's gitleaks-rules apply). HERE is .../<repo>/.claude/hooks, so
# HERE/../.. is the repo root. This makes the guard work from ANY session on a
# provisioned machine with no env var and no cd.
if [[ -z "$CFG_DIR" ]]; then
    if _root="$(repo_with_config "$HERE/../..")"; then
        CFG_DIR="$_root"; CFG="$CONFIG"
        RULESET_DESC="guard's own repo: $_root"
    fi
fi

# Path 4 — $GITLEAKS_OPERATOR_RULES. Kept ONLY as an override for an unprovisioned
# machine (paths 1-3 cover the provisioned case). Set-but-unreadable is
# fail-closed. The private path is NEVER hardcoded here.
if [[ -z "$CFG_DIR" && -n "${GITLEAKS_OPERATOR_RULES:-}" ]]; then
    _rules="${GITLEAKS_OPERATOR_RULES/#\~/$HOME}"
    if [[ ! -r "$_rules" ]]; then
        block "PR-guard BLOCKED: GITLEAKS_OPERATOR_RULES is unreadable" \
            "GITLEAKS_OPERATOR_RULES points at a file that does not exist or" \
            "cannot be read, so the operator ruleset cannot be applied." \
            "Fix the path, or unset it — on a provisioned machine the guard's own" \
            "repo supplies the ruleset with no env var."
    fi
    case "$_rules" in /*) : ;; *) _rules="$PWD/$_rules" ;; esac
    _rdir="$(cd "$(dirname "$_rules")" && pwd)"
    _rabs="$_rdir/$(basename "$_rules")"
    WRAPPER_TMP="$(mktemp)"
    printf 'title = "pr-guard operator-rules wrapper"\n[extend]\npath = "%s"\n' "$_rabs" > "$WRAPPER_TMP"
    CFG_DIR="$_rdir"; CFG="$WRAPPER_TMP"
    RULESET_DESC="GITLEAKS_OPERATOR_RULES: $_rabs"
fi

# None resolved -> BLOCK. On a provisioned machine this should not happen: paths
# 1-3 need no configuration. Name all four ways.
if [[ -z "$CFG_DIR" ]]; then
    block "PR-guard BLOCKED: could not locate the operator gitleaks ruleset" \
        "A PR title/body can carry secrets, employer/product names, private" \
        "URLs, email, or infra paths, and must be scanned before it is public." \
        "No ruleset was found. On a provisioned machine paths 1-3 need NO config;" \
        "reaching this usually means the guard's own repo is not a proper dotty" \
        "checkout (its tracked .gitleaks.toml is unreadable from here). Satisfy" \
        "ANY one of:" \
        "  1. Publish from a session rooted in a repo that has .gitleaks.toml." \
        "  2. Prefix the command:  cd <repo-with-.gitleaks.toml> && gh pr create ..." \
        "  3. Run this from a proper dotty checkout, with the operator ruleset" \
        "     installed via the blueprint (gitleaks-rules apply)." \
        "  4. (override, unprovisioned machines only) export GITLEAKS_OPERATOR_RULES." \
        "(payload cwd was: $ORIG_CWD)"
fi

cd "$CFG_DIR" || block \
    "PR-guard BLOCKED: cannot enter the ruleset directory" \
    "cd '$CFG_DIR' failed — refusing to allow an unscanned PR."

# Fail-closed preconditions (reuses the git-lifecycle hooks' helper): gitleaks
# binary present, config present, operator ruleset resolved. GL_EFFECTIVE_CONFIG
# is what the scan below passes as --config.
gl_preflight "$CFG" || exit 2

# ---------------------------------------------------------------------------
# Assemble the scan corpus. The scanned command text is the PR-publishing command
# with the parts that are PROVABLY NOT PUBLISHED removed: a leading `cd <repo>`
# prefix (command mechanics), and each --body-file / -F PATH token (the file's
# CONTENTS are published and scanned separately as bodyfile-N.txt; the path is
# not). Everything else stays scanned — a guarded literal in the title, an
# unrelated flag (`-R owner/repo`), or a comment still blocks (the disclosed safe
# over-block). command.txt is written BELOW, after the body-file paths are known.
# ---------------------------------------------------------------------------
scan_dir="$(mktemp -d)"
report="$(mktemp)"
errf="$(mktemp)"
# (Cleanup trap for these was installed up front, alongside WRAPPER_TMP.)

# Resolve a body-file path relative to the cwd gh actually runs in (BODY_CWD:
# the payload cwd, or the `cd <path> && ...` prefix target), not the ruleset dir
# we cd'd into.
resolve_path() {
    case "$1" in
        /*) printf '%s' "$1" ;;
        *)  printf '%s/%s' "$BODY_CWD" "$1" ;;
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

# strip_cd_prefix <raw-command> -> the command with the WHOLE leading `cd` chain
# removed (each `cd <path> <sep>`, sep = && || ; or newline; earliest wins per
# segment). Only called when the chain resolved to a real dir, so every removed
# segment is a real cd command whose path is never published. A chained
# `cd A && cd B && gh ...` must have BOTH cds excluded, not just the first.
strip_cd_prefix() {
    local c="$1" trimmed rest found minlen s before
    while :; do
        trimmed="${c#"${c%%[![:space:]]*}"}"         # left-trim
        [[ "$trimmed" == cd[[:space:]]* ]] || break  # not a leading cd -> stop
        rest=""; found=0; minlen=-1
        for s in '&&' '||' ';' $'\n'; do
            before="${trimmed%%"$s"*}"
            [[ "$before" != "$trimmed" ]] || continue    # separator not present
            if [[ "$found" -eq 0 || ${#before} -lt "$minlen" ]]; then
                found=1; minlen=${#before}; rest="${trimmed#*"$s"}"
            fi
        done
        [[ "$found" -eq 1 ]] || { c=""; break; }     # leading cd, no separator: all cd
        c="$rest"
    done
    printf '%s' "$c"
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

# Build the scanned command text: the raw command minus the never-published
# spans (see the scan-corpus note above).
scan_text="$COMMAND"
if [[ -n "$CD_DIR" ]]; then
    scan_text="$(strip_cd_prefix "$scan_text")"        # leading `cd <repo>` prefix
fi
if [[ -n "$bf_paths" ]]; then
    # Remove each --body-file / -F flag+PATH pair, all realistic raw forms, and
    # ONLY flag-adjacent (literal match). A bare copy of the same path elsewhere
    # (e.g. in --title) is NOT preceded by a body-file flag, so it stays scanned
    # — a genuinely-published path is never dropped.
    while IFS= read -r p; do
        [[ -n "$p" ]] || continue
        for _f in "--body-file $p" "--body-file \"$p\"" "--body-file '$p'" \
                  "--body-file=$p" "--body-file=\"$p\"" "--body-file='$p'" \
                  "-F $p" "-F \"$p\"" "-F '$p'" "-F=$p" "-F=\"$p\"" "-F='$p'" \
                  "-F$p" "-F\"$p\"" "-F'$p'"; do
            scan_text="${scan_text//"$_f"/}"
        done
    done <<< "$bf_paths"
fi
printf '%s\n' "$scan_text" > "$scan_dir/command.txt"

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
    --config "$GL_EFFECTIVE_CONFIG" \
    --no-banner --redact --ignore-gitleaks-allow \
    --report-format json --report-path "$report" \
    >/dev/null 2>"$errf"
rc=$?

if grep -qE 'FTL|Failed to load config' "$errf"; then
    block "PR-guard BLOCKED: gitleaks config failed to load" \
        "Ruleset: $RULESET_DESC (operator rules: $GL_RULES_SOURCE)" \
        "The operator ruleset could not be applied, so the PR was not scanned." \
        "(gitleaks resolves a relative [extend] path against its cwd; the guard" \
        " cd'd to the config's directory, so a load failure here means a missing" \
        " or broken ruleset.)" \
        "Install it via the blueprint (gitleaks-rules apply), or set" \
        "GITLEAKS_OPERATOR_RULES."
elif [[ "$rc" -ne 0 ]]; then
    if [[ -s "$report" ]]; then
        gl_block "PR-guard BLOCKED: guarded literal in the 'gh pr create' command" \
            "gitleaks matched a guarded literal in the PR-publishing command. This" \
            "is NOT necessarily the PR body — it may be the title, an unrelated flag," \
            "or --body-file contents. Location (rule id + file:line; command.txt is" \
            "the command text, bodyfile-N.txt is a --body-file's contents; matched" \
            "values withheld):"
        gl_summarize_report "$report" >&2
        {
            echo "  The scanned command text excludes the parts that are never"
            echo "  published (a leading 'cd <repo>' prefix and any --body-file path);"
            echo "  a guarded value ANYWHERE else in the command blocks (safe over-block)."
            echo "  Remediation:"
            echo "    * Go to the flagged location and remove the sensitive value from"
            echo "      wherever it sits — title, body, or a flag."
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
