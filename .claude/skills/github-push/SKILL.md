---
name: github-push
description: >
  Triggers when the user says "push to github", "publish [path]",
  "/github-push [path]", or similar requests to commit and push Claude Code
  infrastructure to GitHub. Enforces the four-way verdict from /github-prep at
  the action boundary; refuses push on Revise / Escalate; offers per-finding ack
  on Block; passes on Allow.
argument-hint: [path]
user_invokable: true
context: conversation
allowed-tools:
  - Read
  - Glob
  - Grep
  - Bash(git:*)
  - Bash(ls:*)
  - Bash(touch:*)
  - Bash(rm:*)
  - Bash(source:*)
  - Bash(~/bin/dotty/.claude/lib/github-policy.sh*)
  - Bash(~/bin/dotty/.claude/lib/resolve-path.sh*)
  - Bash(~/bin/dotty/.claude/lib/filtered-verdict.sh*)
  - Bash(jq:*)
  - Bash(date:*)
  - Bash(echo:*)
  - Bash(cat:*)
---

# /github-push — Action Boundary

Commit and push Claude Code artifacts to GitHub after verifying the prep marker's verdict. The project directory IS the repo — no file copying between repos.

This is the action boundary in the judge architecture: `/github-prep` is the judge (writes marker with per-finding verdicts); `/github-push` enforces the verdict at the moment of action. Push does not classify — it reads, gates, and acts.

Design source: `~/Vaults/Notes/System/Knowledge/github-prep-methodology.md` (editorial only — not loaded at runtime).

## Invocation

```
/github-push [path]
```

- Optional argument: path to the project or artifact to push
- Default: current working directory

## Step 0: Resolve target path

Two mechanisms for receiving the target path:

1. **Slash-command path** — user types `/github-push [path]`. Path appears in invocation context as `<command-args>...</command-args>` + `ARGUMENTS: <value>` line. Extract value yourself.
2. **Sentinel-file path** — another agent calls `Skill(skill: "github-push")` for you. Calling orchestrator writes a JSON sentinel to `~/.cache/claude/github-push-target`. Skill tool's `args` parameter is not delivered to forked sub-agents (LEX-112); sentinel is the only reliable cross-agent channel.

**Do this in order:**

1. If you see an `ARGUMENTS:` line or `<command-args>` block, capture as `<ARG>`. Otherwise empty.
2. Run:

   ```bash
   ~/bin/dotty/.claude/lib/resolve-path.sh "<ARG>" "$HOME/.cache/claude/github-push-target"
   ```

3. Capture single-line stdout. That is the canonical target path.
4. Non-zero exit → report error, stop.
5. State resolved path:
   - Explicit `<ARG>` or sentinel → `Pushing from: <path>`
   - `$PWD` fallback → `Pushing from: <path> (defaulted to current directory; no target specified)` — annotation is load-bearing.

**Resolver precedence:** explicit `<ARG>` wins; otherwise sentinel (TTL-bounded per LEX-144, NOT auto-deleted); otherwise `$PWD`.

### Orchestrator-invocation contract

Other agents wanting to call this skill write a JSON sentinel:

```bash
NOW_UTC=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
printf '{"path": "/absolute/path/to/target", "created_at": "%s"}\n' "$NOW_UTC" \
  > ~/.cache/claude/github-push-target
```

Then call `Skill(skill: "github-push")`. Sentinel is TTL-bounded (5 minutes); stale sentinels treated as absent. NOT auto-deleted (chained calls survive); operators may clear via `rm ~/.cache/claude/github-push-target`.

The resolved path must be inside a git repository. If not, report "No git repository found at {path}. Run `git init` first." and exit.

## Execution flow

### Step 1: Load policy

```bash
source ~/bin/dotty/.claude/lib/github-policy.sh
load_policy "$REPO_ROOT"
```

Populates `$GH_POLICY_HASH`, `$GH_POLICY_PREP_REQUIRED`, `$GH_POLICY_PREP_STRICTNESS`, `$GH_POLICY_PREP_TTL_HOURS`, `$GH_POLICY_VISIBILITY`, etc. Defaults: treat as public, prep_required, strict, 24h TTL.

### Step 2: Gate checks

#### 2a. Marker schema check (load-bearing)

Read `.github-prep-status.json` from the target path (or search parent directories up to git root).

| Check | Failure mode |
|---|---|
| File exists | "No prep marker on this machine. Run `/github-prep` first." (Day-one machine after `/update-mbp` pull will hit this — marker is per-machine.) |
| `marker_schema_version == 2` | "Marker schema is v1 (legacy) — incompatible. Re-run `/github-prep` to produce a v2 marker." This is the v5 breaking change; v1 markers must be re-prepped. |
| `evaluated_at` within `$GH_POLICY_PREP_TTL_HOURS` | "Prep verdict expired ({age}h, TTL {ttl}h). Re-run `/github-prep`." |
| `policy_hash` matches current `$GH_POLICY_HASH` | "Policy changed since last prep. Re-run `/github-prep`." |
| `scanner_version` matches current scanner | "Scanner upgraded since last prep. Re-run `/github-prep`." |

If any check fails, exit with the failure message — no retry, no override.

#### 2b. Verdict enforcement (four-way, scoped to staged files)

**Use the `filtered-verdict.sh` script** to compute the staged-scope verdict from the marker. Do NOT re-implement filtering logic in prose — the script is the load-bearing path (covered by 12/12 tests including the verdict-poisoning regression).

```bash
# 1. Capture the staged file list as NUL-separated.
git -C "$REPO_ROOT" diff --cached --name-only -z > /tmp/push-staged-$$.list

# 2. If staged list is empty, exit "Nothing to push" — no findings apply.
[ -s /tmp/push-staged-$$.list ] || { echo "Nothing to push."; rm -f /tmp/push-staged-$$.list; exit 0; }

# 3. Filter the marker to staged-scope and read the verdict.
~/bin/dotty/.claude/lib/filtered-verdict.sh \
  "$REPO_ROOT/.github-prep-status.json" \
  /tmp/push-staged-$$.list \
  > /tmp/push-verdict-$$.json

FILTERED_VERDICT=$(jq -r '.filtered_verdict' /tmp/push-verdict-$$.json)
MARKER_VERDICT=$(jq -r '.marker_verdict' /tmp/push-verdict-$$.json)
DRIFT=$(jq -r '.drift' /tmp/push-verdict-$$.json)
```

**If drift is true** (filtered verdict differs from marker's stored verdict — typical case: marker says `revise` because of out-of-scope findings, but staged scope is `allow`), report this clearly to the operator:

```
Marker verdict: <marker_verdict> (<N> total findings across the repo)
Staged-scope verdict: <filtered_verdict> (M findings on the <scope_count> staged files)
Proceeding under staged-scope verdict.
```

This is the multi-session-safe gate behavior: another operator's in-flight working tree does not block your push if their findings are on files you're not committing.

**Use `$FILTERED_VERDICT` for all subsequent gate logic in this step.**

Read `$FILTERED_VERDICT` (one of `allow`, `block`, `revise`, `escalate`).

**`allow`** — push proceeds. No operator prompt for verdict (subsequent gate checks 2c–2e still apply).

**`escalate`** — push REFUSED. No ack path.

Present the Escalate findings to the operator with category + file:line + snippet + reason + "Human judgment needed: <what>". Tell the operator: "These require human judgment that the LLM judge could not resolve. Decide on each, then either fix the underlying content or update the policy's known-references list, and re-run `/github-prep`."

Exit.

**`revise`** — push REFUSED. No ack path.

Present the Revise findings to the operator with category + file:line + snippet + reason + suggested fix. Tell the operator: "These must be fixed in code before push. There is no override path. After fixing, re-run `/github-prep`."

Exit.

**`block`** — push REFUSED unless operator acknowledges per finding.

Per-finding acknowledge-and-proceed flow (when `$GH_POLICY_PREP_STRICTNESS` is `strict` or `warn`; under `off`, Block surfaces for awareness but does not gate):

1. Present every Block finding to the operator, numbered, with category + file:line + snippet + reason from the marker.
2. For each finding, require an exact-string acknowledgment: `I acknowledge Block finding #N: <category> at <file>:<line>`. Any other input aborts the push.
3. On valid ack: append an entry to the marker's `acknowledgments` array recording `{finding_index, finding_hash, acknowledged_at, ack_string, operator_reason}`.
4. After all Block findings are acked (or the operator aborts), proceed to next gate.

**Design principle:** Block findings have an override path because a reasonable operator may have context the judge doesn't. Revise and Escalate findings have NO override because the override scenarios for those verdicts don't exist (Revise → fix in code; Escalate → human decides outside the gate).

#### 2c. README check

`visibility: public`: README.md at git root must exist. Missing → "No README. Run `/github-readme {path}` first." Exit.
`visibility: private`: skip — no consumers.

#### 2d. LICENSE check (non-blocking)

`visibility: public`: warn if missing.
`visibility: private`: skip silently.

#### 2e. .gitignore check

Required entries (depend on visibility):
- `.github-prep-status.json` — both visibilities
- `settings.local.json` — both visibilities
- `CLAUDE.md` — **public only**. Private repos intentionally commit non-vault CLAUDE.md for backup.

Missing entries → warn + ask for confirmation before proceeding.

#### 2f. Force-push check (when push includes `--force` / `--force-with-lease`)

Target branch must match a glob in `$GH_POLICY_FORCE_PUSH_TARGETS`. If not → "Force push to {branch} not allowed by policy. Allowed targets: {list}". Exit.

### Step 3: Show changes (diff summary)

Run `git status --porcelain` and `git diff --stat` (NOT `git diff` — token discipline).

Present:
- File list (paths + add/modify/delete status)
- Per-file insertion/deletion stats
- Confirm personal config files (CLAUDE.md, settings.local.json) are NOT in the changes (should be gitignored)

If user wants full diff for a specific file, they can ask. Default = summary-only.

No changes → "No changes to commit." Exit.

### Step 4: Confirm with user

```
Ready to push to {remote-name} ({remote-url}):

Files to commit ({N} files, +{ins} -{del}):
  {file list with --stat numbers}

Commit message: "{proposed message}"

Proceed? (yes/no)
```

No remote configured → ask user to set one up (`git remote add origin {url}`) and exit.

**Do not proceed without user confirmation.** Conversation-context skill specifically because it requires human interaction.

### Step 5: Stage files

Stage specific changed files with `git add` using explicit paths. Never `git add -A` or `git add .` — list each file explicitly.

`git add` is not a gated verb (no sentinel needed); runs directly.

### Step 6: Commit (gated — two-call sentinel pattern)

Each gated git operation requires the sentinel marker. Re-create before each gated op (commit AND push are separate Bash calls; each consumes its own marker).

**Session-id source of truth:** `${CLAUDE_CODE_SESSION_ID:-$CLAUDE_SESSION_ID}` is authoritative. SessionStart hook (`session-init.sh`) writes it to `$CLAUDE_ENV_FILE` so it propagates into every Bash tool call. Cache file at `~/.cache/claude/session-id` is diagnostic only — it's overwritten by every session-init across all sessions; concurrent sessions stomp each other's cache. Never use the cache for sentinel construction.

```bash
# Bash call A: create the sentinel marker (no git verb — passes hook trivially)
[ -n "${CLAUDE_CODE_SESSION_ID:-$CLAUDE_SESSION_ID}" ] || { echo "CLAUDE_SESSION_ID not set; SessionStart hook may have failed" >&2; exit 1; }
touch "$HOME/.cache/claude/git-authorized-${CLAUDE_CODE_SESSION_ID:-$CLAUDE_SESSION_ID}"
```

```bash
# Bash call B: run the gated commit (hook checks marker, consumes it, authorizes)
git commit -m "$MESSAGE"
```

Use the user's confirmed or modified message. End with the Co-Authored-By trailer from base system commit instructions.

If commit fails with "Direct git mutation blocked" — sentinel was missing. Most likely a session-id mismatch (skill saw one id, hook saw another). Check `echo "${CLAUDE_CODE_SESSION_ID:-$CLAUDE_SESSION_ID}"` returns non-empty matching the hook's view. If empty, SessionStart hook didn't propagate — investigate `session-init.sh`, `jq` availability, or `$CLAUDE_ENV_FILE` path.

Do NOT fall back to `cat ~/.cache/claude/session-id` — may be stale from a different session.

### Step 7: Push (gated — two-call sentinel pattern again)

```bash
# Bash call A: re-create the sentinel (commit consumed it)
touch "$HOME/.cache/claude/git-authorized-${CLAUDE_CODE_SESSION_ID:-$CLAUDE_SESSION_ID}"
```

```bash
# Bash call B: run the gated push
git push
```

First push: `git push -u origin main` (or current branch name) — same two-call pattern.

Push fails (auth, conflicts, etc.) → report error, do not retry automatically. Sentinel was already consumed; retry requires re-running the two-call pattern.

### Step 8: Report

```
Pushed to {remote-url}:

  {list of files committed}

Commit: {short hash} — {message}
```

## Stop rules

| Condition | Action |
|---|---|
| No prep marker (and `prep.required`) | "No prep marker on this machine. Run `/github-prep` first." Exit. |
| Marker `marker_schema_version != 2` | "Marker schema is v1 (legacy). Re-run `/github-prep`." Exit. |
| Prep expired (`>prep.ttl_hours`) | "Prep verdict expired. Re-run `/github-prep`." Exit. |
| `policy_hash` mismatch | "Policy changed since last prep. Re-run `/github-prep`." Exit. |
| `scanner_version` mismatch | "Scanner upgraded since last prep. Re-run `/github-prep`." Exit. |
| Verdict `escalate` | Show Escalate findings; refuse with "human judgment required." Exit. |
| Verdict `revise` | Show Revise findings; refuse with "fix in code, re-run prep." Exit. |
| Verdict `block` AND operator did not provide per-finding acks | Show each Block finding; request per-finding ack string; abort if not received. |
| No README at git root (public repos) | "Run `/github-readme` first." Exit. |
| No git repo at path | "Run `git init` first." Exit. |
| No remote configured | "Add a remote." Exit. |
| No changes to commit | "Nothing to push." Exit. |
| User declines confirmation | "Push cancelled." Exit. |
| Force-push to non-allowed branch | "Force push to {branch} not allowed by policy." Exit. |
| Git commit/push fails | Report error, do not retry. Manual retry requires re-running two-call pattern. Exit. |
| Sentinel denied (hook says "Direct git mutation blocked") | Session-id mismatch — check `${CLAUDE_CODE_SESSION_ID:-$CLAUDE_SESSION_ID}` and SessionStart hook. Exit. |
| CLAUDE.md not gitignored (public repo) | Warn and ask for confirmation. |

## Error handling

| Condition | Behavior |
|---|---|
| Multiple prep markers in nested directories | Use the one closest to the target path |
| Merge conflicts on push | Report conflict, suggest `git pull --rebase` |
| Detached HEAD or non-main branch | Warn user and ask if they want to proceed |
| Staged changes include files that look personal | Warn before committing |
