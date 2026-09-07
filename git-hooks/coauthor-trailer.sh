#!/usr/bin/env bash
# coauthor-trailer.sh — a git `prepare-commit-msg` hook.
#
# In an estate ("personal profile") Claude session the commit author is the
# Claude App bot; this adds the operator as co-author so her attribution rides
# every bot commit, idempotently — the way the retired API publisher used to
# add it. It fires ONLY for a fresh commit whose author IS the bot: it no-ops
# for her own commits (her terminal, the professional profile) and skips
# merge / squash / amend so it never relabels imported or rewritten history.
#
# Delivery (matches the scanner hooks): consumed remotely from dotty via
# `.pre-commit-hooks.yaml` (id: coauthor-trailer), installed per repo by the
# same `pre-commit install --install-hooks` that installs the scanner — the
# consumer adds `prepare-commit-msg` to `default_install_hook_types` and the
# `coauthor-trailer` entry at its next consumer bump. The hook LOGIC lives once,
# here.
#
# The commit source is read from positional $2 (git's native prepare-commit-msg
# contract) OR $PRE_COMMIT_COMMIT_MSG_SOURCE (pre-commit sets it in the env and
# does not pass it positionally), so the same script is correct whether it runs
# as a raw .git/hooks/prepare-commit-msg or through pre-commit.

set -uo pipefail

MSG_FILE="${1:-}"
SRC="${2:-${PRE_COMMIT_COMMIT_MSG_SOURCE:-}}"
[[ -n "$MSG_FILE" && -f "$MSG_FILE" ]] || exit 0

# Never touch imported/rewritten history — only a fresh commit's own message.
case "$SRC" in
  merge|squash|commit) exit 0 ;;
esac

# Estate mode only: the commit's author must be the App bot.
BOT_EMAIL="325510841+claude-the-enduring[bot]@users.noreply.github.com"
[[ "${GIT_AUTHOR_EMAIL:-}" == "$BOT_EMAIL" ]] || exit 0

TRAILER="Co-authored-by: Alexis Bussa <938162+lexijamesesq@users.noreply.github.com>"

# git interpret-trailers places it in the message's trailer block correctly
# (creating the blank-line-separated block if there is none) and
# addIfDifferentNeighbor makes it idempotent — a second run adds nothing.
if command -v git >/dev/null 2>&1; then
  git interpret-trailers --if-exists addIfDifferentNeighbor \
    --trailer "$TRAILER" --in-place "$MSG_FILE" 2>/dev/null && exit 0
fi

# Fallback if interpret-trailers is somehow unavailable: append idempotently.
grep -qiF "$TRAILER" "$MSG_FILE" && exit 0
[[ -n "$(tail -c1 "$MSG_FILE" 2>/dev/null)" ]] && printf '\n' >> "$MSG_FILE"
printf '\n%s\n' "$TRAILER" >> "$MSG_FILE"
exit 0
