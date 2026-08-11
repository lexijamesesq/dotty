#!/usr/bin/env bash
# git-hook-bypass-guard.sh
#
# PreToolUse hook (matcher: Bash): denies Bash commands that bypass git's
# commit/push hook chain (--no-verify / -n, pre-commit's SKIP var, or a
# core.hooksPath override). That hook chain is where gitleaks and the
# operator-rules staleness gate run — the mechanical layer that keeps
# genuinely-sensitive data out of public repos.
#
# Registered by path in the private profile's settings.json under
# hooks.PreToolUse, alongside the estate's other PreToolUse hooks.
#
# Honesty note: this is tool-scoped, Bash-porous defense-in-depth, NOT a
# boundary. It is the reliable second layer behind the cheap permissions.deny
# glob patterns in settings.json (glob flag-matching is documented as fragile
# — quoting variants, option reordering). Both layers only string-match a
# single Bash tool_input.command, so any shell indirection that keeps the
# literal pattern out of that one string slips past. Verified-porous examples
# (each checked to return exit 0 through this guard): a variable-assembled
# subcommand `c=commit; git $c --no-verify`; a shell alias or function whose
# name doesn't contain the pattern (the guard sees only `gc`); or
# `eval "$cmd"`. (Note: `env -i git commit --no-verify` is NOT porous — the
# --no-verify substring still matches through the env prefix; it is blocked.)
# Do not read either layer as a boundary. The boundary is the pre-push hook,
# which git itself runs.
#
# Subagent coverage (verified by live probe, not inferred): both layers reach
# subagents. The parent permissions.deny layer blocked a sentinel command
# inside a subagent, and this hook fired inside a subagent and blocked a
# quoted `-n`, naming itself by path. Subagents inherit the parent
# conversation's permissions and PreToolUse hooks.
#
# Vectors denied:
#   1. git commit --no-verify / git commit -n — including bundled short-flag
#      clusters such as -an, -vn, -nm (git parses -an as -a -n). A regex
#      matches any single-dash lowercase cluster containing n; double-dash
#      long flags (--no-edit, --no-gpg-sign, --amend) are deliberately NOT
#      matched, nor is -am / -m.
#   2. git push --no-verify
#      (git push -n is --dry-run per `git help push` — NOT a hook bypass,
#       deliberately NOT blocked)
#   3. SKIP=<hook-id> ... on a git commit or git push (pre-commit's own
#      skip-hook-id env var)
#   4. git -c core.hooksPath=... / git config ... core.hooksPath ...
#      (redirects git away from the installed hook scripts entirely)
#   NOT denied: PRE_COMMIT_ALLOW_NO_CONFIG=1 — verified against pre-commit's
#   own docs: it only suppresses the "no .pre-commit-config.yaml found" error.
#   It has no effect when a config file is present, so it does not bypass any
#   hook that is actually configured to run. Blocking it would deny a no-op.
#
# Accepted over-blocks (safe direction — a false deny costs a retype, a false
# allow can leak): the vector-1 short-flag regex fires on a literal `-n`
# (or any -<letters>n<letters> cluster) that appears anywhere in a command
# containing "git commit", including inside the commit MESSAGE
# (git commit -m "use -n for dry run") or in an unrelated segment of a
# compound command (git commit -m x && echo -n done). Vector 4 likewise fires
# on the harmless read `git config --get core.hooksPath`. These are
# string-match false positives, not security holes; we accept them rather than
# build a shell-parser to plug them.
#
# Failure posture: FAIL-OPEN on infra errors (jq missing, empty/malformed
# stdin, wrong tool_name). This script never opines in that case — no
# stdout, exit 0 — which lets normal permission evaluation (the
# permissions.deny glob layer, then ask/allow) run untouched. It does NOT
# fail-closed (deny every Bash call) on error, and it does NOT affirmatively
# allow either; declining to have an opinion is not the same claim as "this
# command is safe."
#
# Why fail-open and not fail-closed: permissions.deny in settings.json is
# evaluated by the Claude Code harness itself, independent of this script —
# verified live to fire on its own, including inside a subagent. It stays
# live even if this file is deleted, non-executable, or crashes on every
# invocation. So a broken hook degrades this control to layer-1-only (the
# fragile glob patterns), it does not remove protection outright. Fail-closed
# (deny every Bash call on any script error) would brick the operator's
# entire Bash tool session-wide on something as mundane as a `jq` uninstall
# or Homebrew upgrade hiccup — a session-wide outage is a worse failure mode
# than a narrowed defense-in-depth layer, and is exactly the kind of
# "elaborate machinery" this control is scoped to avoid.
#
# Tests: .claude/eval/git-hook-bypass-guard.test.sh
# Spec: {workspace_root}/System/Knowledge/leak-prevention-architecture.md

set -uo pipefail

# Fail-open: no jq, no opinion. (Matches the convention in the estate's other
# PreToolUse hooks — vault-mcp-redirect.sh, session-init.sh.)
command -v jq >/dev/null 2>&1 || exit 0

INPUT=$(cat 2>/dev/null)
[[ -z "$INPUT" ]] && exit 0

TOOL_NAME=$(jq -r '.tool_name // empty' <<<"$INPUT" 2>/dev/null)
[[ "$TOOL_NAME" == "Bash" ]] || exit 0

CMD=$(jq -r '.tool_input.command // empty' <<<"$INPUT" 2>/dev/null)
[[ -z "$CMD" ]] && exit 0

# Normalize every whitespace run (space, tab, newline) to a single space so
# `git<TAB>commit` and `git   commit -n` cannot slip past the substring
# checks below.
CMD_NORM=$(tr -s '[:space:]' ' ' <<<"$CMD")
LOWER_NORM=$(tr '[:upper:]' '[:lower:]' <<<"$CMD_NORM")

deny() {
    {
        echo "git-hook-bypass-guard: blocked — $1"
        echo ""
        echo "Hooks exist to run gitleaks + the operator-rules staleness gate before a"
        echo "commit or push leaves the machine. This guard is defense-in-depth, not a"
        echo "boundary — if you genuinely need to bypass hooks (e.g. a hook is broken),"
        echo "ask the operator rather than routing around this check."
    } >&2
    exit 2
}

# Boundary character class for flag/token matching: start/end of string, plus
# whitespace, a shell quote, or a shell operator (; & |). Including the shell
# operators is load-bearing — without them, `git commit -n;echo` sits the -n
# flag against a delimiter the regex would not treat as a boundary, letting a
# hook-bypassing commit through whenever an operator abuts -n. (Built as a var
# so the =~ regexes stay readable.)
BND="[[:space:];&|\"']"

# --- Vector 1: commit hook bypass (--no-verify, or -n in any short cluster) ---
if [[ "$LOWER_NORM" == *"git commit"* ]]; then
    if [[ "$LOWER_NORM" == *"--no-verify"* ]]; then
        deny "git commit --no-verify"
    fi
    # Single-dash lowercase cluster containing n: -n, -an, -nm, -vn, ...
    # The leading boundary must be a SINGLE dash (preceded by space/quote/
    # start), which structurally excludes double-dash long flags like
    # --no-edit / --no-gpg-sign / --amend, and the value-attached message
    # flag forms -am / -m never contain a matchable n.
    RE_SHORT_N="(^|$BND)-[a-z]*n[a-z]*($|$BND)"
    if [[ "$LOWER_NORM" =~ $RE_SHORT_N ]]; then
        deny "git commit -n / bundled short flag containing -n (e.g. -an); -n is --no-verify"
    fi
fi

# --- Vector 2: push hook bypass (--no-verify only; -n is --dry-run, not a bypass) ---
if [[ "$LOWER_NORM" == *"git push"* && "$LOWER_NORM" == *"--no-verify"* ]]; then
    deny "git push --no-verify"
fi

# --- Vector 3: pre-commit SKIP env var on a commit or push ---
RE_SKIP="(^|$BND)SKIP="
if [[ "$CMD_NORM" =~ $RE_SKIP ]] && [[ "$LOWER_NORM" == *"git commit"* || "$LOWER_NORM" == *"git push"* ]]; then
    deny "SKIP=<hook-id> on a git commit/push (pre-commit's own hook-skip var)"
fi

# --- Vector 4: hooksPath override (git -c core.hooksPath=... / git config core.hooksPath ...) ---
if [[ "$LOWER_NORM" == *"hookspath"* ]]; then
    deny "core.hooksPath override (redirects git away from the installed hooks)"
fi

exit 0
