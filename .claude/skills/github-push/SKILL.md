---
name: github-push
description: >
  Triggers when the user says "push to github", "publish [path]",
  "/github-push [path]", or similar requests to commit and push Claude Code
  infrastructure to GitHub.
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
  - Bash(jq:*)
  - Bash(date:*)
  - Bash(echo:*)
  - Bash(cat:*)
---

# /github-push — Gated Commit and Push

Commit and push Claude Code artifacts to GitHub after verifying that sharing readiness evaluation and documentation are in place. The project directory IS the repo — no file copying between repos.

## Invocation

```
/github-push [path]
```

- Optional argument: path to the project or artifact to push
- Default: current working directory
- Examples: `/github-push`, `/github-push path/to/your/project/`

## Arguments

### Step 0: Resolve target path (run this Bash command first; use its output for all subsequent steps)

This skill receives its target path through one of two mechanisms, in priority order:

1. **Slash-command path** (user types `/github-push [path]`) — the path appears in your invocation context as a `<command-args>...</command-args>` block and a trailing `ARGUMENTS: <value>` line. Extract the value yourself.
2. **Sentinel-file path** (another agent calls `Skill(skill: "github-push")` for you) — the calling orchestrator must have written the absolute target path to `~/.cache/claude/github-push-target` before invoking. The Skill tool's `args` parameter is **not** delivered to sub-agents (<TEAM>-N), so the sentinel file is the only reliable cross-agent channel.

**Do this in order:**

1. If you can see an `ARGUMENTS:` line or `<command-args>` block in your invocation context, capture that value as `<ARG>`. Otherwise, set `<ARG>` to the empty string.
2. Run this Bash command exactly, substituting `<ARG>` with the captured value (empty string is fine — the resolver will fall back to the sentinel file or PWD):

   ```bash
   ~/bin/dotty/.claude/lib/resolve-path.sh "<ARG>" "$HOME/.cache/claude/github-push-target"
   ```

3. Capture the single-line stdout. That is the canonical "target path" referenced in every later step.
4. If the command exits non-zero (`Path not found: ...`), report the error and stop.
5. State the resolved path back to the user before proceeding. The format depends on which precedence tier resolved the path:
   - **Explicit `<ARG>` or sentinel was used** → `Pushing from: <path>`
   - **`$PWD` fallback** (no `<ARG>`, no sentinel file) → `Pushing from: <path> (defaulted to current directory; no target specified)`

   The PWD-fallback annotation is load-bearing: an orchestrator that meant to push a different target will see this, recognize the mismatch, and consult the orchestrator-invocation contract below.

**Resolver precedence:** explicit `<ARG>` wins; otherwise, the sentinel file is consumed (and deleted to prevent stale reuse); otherwise, `$PWD`.

### Orchestrator-invocation contract

If you (an agent) want to call this skill for a target other than your CWD, write the absolute path to the sentinel file before invoking the Skill tool:

```bash
echo "/absolute/path/to/target" > ~/.cache/claude/github-push-target
```

Then call `Skill(skill: "github-push")` (no args needed; the args parameter is ignored). The skill consumes and deletes the sentinel on first read.

The resolved path must be inside a git repository. If not, report "No git repository found at {path}. Run `git init` first." and exit.

## Execution Flow

### Step 1: Load Policy

Before gate checks, load the per-project policy:

```bash
source ~/bin/dotty/.claude/lib/github-policy.sh
load_policy "$REPO_ROOT"
```

This populates `$GH_POLICY_HASH`, `$GH_POLICY_PREP_REQUIRED`, `$GH_POLICY_PREP_STRICTNESS`, `$GH_POLICY_PREP_TTL_HOURS`, `$GH_POLICY_VISIBILITY`, etc. Defaults are conservative when no `.claude/github-policy.yaml` exists (treat as public, prep_required, strict, 24h TTL).

### Step 2: Gate Checks

**2a. Prep status marker** (skip if `$GH_POLICY_PREP_REQUIRED == false`)

Look for `.github-prep-status.json` at the target path (or search parent directories up to the git root). Verify all of:

| Check | Failure mode |
|---|---|
| File exists | "No prep verdict on this machine; run /github-prep first." (Day-one MBP after `/update-mbp` pull will hit this — verdict marker is per-machine.) |
| `evaluated_at` within `$GH_POLICY_PREP_TTL_HOURS` | "Prep verdict expired ({age}h, TTL {ttl}h). Re-run /github-prep." |
| `policy_hash` matches current `$GH_POLICY_HASH` | "Policy changed since last prep. Re-run /github-prep." |
| `scanner_version` matches current scanner | "Scanner upgraded since last prep. Re-run /github-prep." |
| `verdict` not blocked-by-strictness | See strictness rules below |

**Strictness mapping** (from `$GH_POLICY_PREP_STRICTNESS`):
- `strict`: only `verdict == "clean"` passes; `review-needed` and `blocked` are gates
- `warn`: `verdict == "blocked"` is a gate; `review-needed` shows findings to user and asks explicit confirmation; `clean` passes silently
- `off`: any verdict passes (still requires marker present)

**2b. README check**

Check that `README.md` exists at the git root. If missing, report "No README found. Run `/github-readme {path}` first." and exit.

**2c. LICENSE check (non-blocking)**

Check for LICENSE at the git root. If missing, warn but do not block.

**2d. .gitignore check**

Verify `.gitignore` exists and excludes at minimum:
- `CLAUDE.md` (personal config)
- `.github-prep-status.json` (transient marker)

If `.gitignore` is missing or doesn't exclude `CLAUDE.md`, warn and ask user to confirm before proceeding.

**2e. Force-push check** (when push includes `--force` / `--force-with-lease`)

If user requests force push, verify the target branch matches a glob in `$GH_POLICY_FORCE_PUSH_TARGETS`. If not, refuse — "force push to {branch} not allowed by policy. Allowed targets: {list}".

### Step 3: Show Changes (diff summary, not full diff)

Run `git status --porcelain` and `git diff --stat` (NOT `git diff` — token discipline). Present to the user:

- File list (paths + add/modify/delete status)
- Per-file insertion/deletion stats from `--stat`
- Confirm that personal config files (CLAUDE.md, settings.local.json) are NOT in the changes (should be gitignored)

If the user wants to see the full diff for a specific file, they can ask. Default behavior is summary-only.

If there are no changes to commit, report "No changes to commit." and exit.

### Step 4: Confirm with User

Present a summary and ask for explicit confirmation:

```
Ready to push to {remote-name} ({remote-url}):

Files to commit ({N} files, +{ins} -{del}):
  {file list with --stat numbers}

Commit message: "{proposed message}"

Proceed? (yes/no)
```

If no remote is configured, ask the user to set one up (`git remote add origin {url}`) and exit.

**Do not proceed without user confirmation.** This is a conversation-context skill specifically because it requires human interaction.

### Step 5: Stage Files

Stage the specific changed files with `git add` using explicit paths. Never use `git add -A` or `git add .` — list each file explicitly so nothing unexpected is included.

`git add` is not a gated verb (no sentinel needed); it can run directly.

### Step 6: Commit (gated — uses two-call sentinel pattern)

Each gated git operation requires the sentinel marker created in a prior Bash call. Re-create the marker before each gated op (commit AND push are separate Bash tool calls; each consumes its own marker).

**Two-call sentinel pattern for the commit:**

**Session-id source of truth:** `$CLAUDE_SESSION_ID` is authoritative. The SessionStart hook (`session-init.sh`) writes it to `$CLAUDE_ENV_FILE` so it propagates into every Bash tool call. The cache file at `~/.cache/claude/session-id` is **diagnostic only** — it's overwritten by every session-init across all sessions on the machine, so concurrent sessions stomp each other's cache. Never use the cache file for sentinel construction.

```bash
# Bash call A: create the sentinel marker (no git verb — passes hook trivially)
[ -n "$CLAUDE_SESSION_ID" ] || { echo "CLAUDE_SESSION_ID not set; SessionStart hook may have failed" >&2; exit 1; }
touch "$HOME/.cache/claude/git-authorized-$CLAUDE_SESSION_ID"
```

```bash
# Bash call B: run the gated commit (hook checks marker, consumes it, authorizes)
git commit -m "$MESSAGE"
```

Use the user's confirmed or modified message. End the commit message with the Co-Authored-By trailer from the base system commit instructions.

If the commit Bash call fails with "Direct git mutation blocked" — the sentinel was missing. Most likely a session_id mismatch (skill saw one id, hook saw another). The hook reads its session_id from its own stdin JSON, which is always correct; the skill's source has to match. Check `echo "$CLAUDE_SESSION_ID"` returns a non-empty value matching the hook's view. If empty, the SessionStart hook didn't propagate to env — investigate `session-init.sh`, `jq` availability, or `$CLAUDE_ENV_FILE` path.

Do NOT fall back to `cat ~/.cache/claude/session-id` for the sentinel — that file may be stale from a different session.

### Step 7: Push (gated — uses two-call sentinel pattern again)

```bash
# Bash call A: re-create the sentinel marker (the commit consumed it)
touch "$HOME/.cache/claude/git-authorized-$CLAUDE_SESSION_ID"
```

```bash
# Bash call B: run the gated push
git push
```

If this is the first push, use `git push -u origin main` (or the current branch name) — same two-call pattern.

If push fails (auth, conflicts, etc.), report the error and do not retry automatically. The sentinel was already consumed; if the user wants to retry, the skill must re-create it (re-run the two-call pattern).

### Step 8: Report

```
Pushed to {remote-url}:

  {list of files committed}

Commit: {short hash} — {message}
```

## Stop Rules

| Condition | Action |
|-----------|--------|
| No prep status marker (and `prep.required`) | "No prep verdict on this machine; run /github-prep first." Exit. |
| Prep expired (>`prep.ttl_hours`) | "Prep verdict expired. Re-run /github-prep." Exit. |
| Verdict's `policy_hash` mismatch | "Policy changed since last prep. Re-run /github-prep." Exit. |
| Verdict's `scanner_version` mismatch | "Scanner upgraded since last prep. Re-run /github-prep." Exit. |
| Verdict blocked-by-strictness | Show findings + reason. Exit. |
| No README at git root | "Run /github-readme first." Exit. |
| No git repo at path | "Run git init first." Exit. |
| No remote configured | "Add a remote." Exit. |
| No changes to commit | "Nothing to push." Exit. |
| User declines confirmation | "Push cancelled." Exit. |
| Force-push to non-allowed branch | "Force push to {branch} not allowed by policy." Exit. |
| Git commit/push fails | Report error, do not retry. Sentinel was consumed; manual retry requires re-running the two-call pattern. Exit. |
| Sentinel denied (hook says "Direct git mutation blocked") | Session_id mismatch — check `$CLAUDE_SESSION_ID` and SessionStart hook. Exit. |
| CLAUDE.md not gitignored | Warn and ask for confirmation. |

## Error Handling

| Condition | Behavior |
|-----------|----------|
| Multiple prep markers in nested directories | Use the one closest to the target path |
| Merge conflicts on push | Report conflict, suggest `git pull --rebase` |
| Detached HEAD or non-main branch | Warn user and ask if they want to proceed |
| Staged changes include files that look personal | Warn before committing |
