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
---

# /github-push — Gated Commit and Push

Commit and push Claude Code artifacts to GitHub after verifying that sharing readiness evaluation and documentation are in place. The project directory IS the repo — no file copying between repos.

## Invocation

```
/github-push [path]
```

- Optional argument: path to the project or artifact to push
- Default: current working directory
- Examples: `/github-push`, `/github-push ~/Vaults/Notes/Claude/Professional/Incubator/`

## Arguments

Parse `$ARGUMENTS` to resolve the target path.

**Resolution rules:**

| Input | Behavior |
|-------|----------|
| Empty | Use current working directory |
| Absolute path | Use as-is |
| Relative path | Resolve relative to current working directory |

The resolved path must be inside a git repository. If not, report "No git repository found at {path}. Run `git init` first." and exit.

## Execution Flow

### Step 1: Gate Checks

Before any git operations, verify prerequisites:

**1a. Prep status marker**

Look for `.github-prep-status.json` at the target path (or search parent directories up to the git root).

- **Missing:** Report "No sharing readiness evaluation found. Run `/github-prep {path}` first." and exit.
- **Expired:** Read the `evaluated_at` timestamp. If older than 24 hours, report "Sharing readiness evaluation expired ({age}). Re-run `/github-prep {path}`." and exit.
- **Blocked:** If `result` is `"blocked"`, report "Sharing readiness evaluation found blocking issues. Fix them and re-run `/github-prep {path}`." List the findings summary and exit.
- **Valid:** `result` is `"review-needed"` or `"clean"`, timestamp is within 24 hours. Proceed.

**1b. README check**

Check that `README.md` exists at the git root. If missing, report "No README found. Run `/github-readme {path}` first." and exit.

**1c. LICENSE check (non-blocking)**

Check for LICENSE at the git root. If missing, warn but do not block.

**1d. .gitignore check**

Verify `.gitignore` exists and excludes at minimum:
- `CLAUDE.md` (personal config)
- `.github-prep-status.json` (transient marker)

If `.gitignore` is missing or doesn't exclude `CLAUDE.md`, warn and ask user to confirm before proceeding.

### Step 2: Show Changes

Run `git status` to show the current state. Present to the user:

- Files that will be committed (staged + unstaged changes to tracked files, new untracked files that aren't gitignored)
- Confirm that personal config files (CLAUDE.md, settings.local.json) are NOT in the changes (should be gitignored)

If there are no changes to commit, report "No changes to commit." and exit.

### Step 3: Confirm with User

Present a summary and ask for explicit confirmation:

```
Ready to push to {remote-name} ({remote-url}):

Files to commit:
  {list of specific files}

Commit message: "{proposed message}"

Proceed? (yes/no)
```

If no remote is configured, ask the user to set one up (`git remote add origin {url}`) and exit.

**Do not proceed without user confirmation.** This is a conversation-context skill specifically because it requires human interaction.

### Step 4: Stage Files

Stage the specific changed files with `git add` using explicit paths. Never use `git add -A` or `git add .` — list each file explicitly so nothing unexpected is included.

### Step 5: Commit

Create a commit with a descriptive message:

- For initial publish: `"Initial publish: {project name} — {brief description}"`
- For updates: `"Update {what changed}"`

Use the user's confirmed or modified message. End the commit message with the Co-Authored-By trailer from the base system commit instructions.

### Step 6: Push

Push to the remote: `git push`

If this is the first push, use `git push -u origin main` (or the current branch name).

If push fails (auth, conflicts, etc.), report the error and do not retry automatically.

### Step 7: Report

```
Pushed to {remote-url}:

  {list of files committed}

Commit: {short hash} — {message}
```

## Stop Rules

| Condition | Action |
|-----------|--------|
| No prep status marker | Report: run /github-prep first. Exit. |
| Prep expired (>24h) | Report: re-run /github-prep. Exit. |
| Prep result is "blocked" | Report: fix blocking issues. Exit. |
| No README at git root | Report: run /github-readme first. Exit. |
| No git repo at path | Report: run git init first. Exit. |
| No remote configured | Report: add a remote. Exit. |
| No changes to commit | Report: nothing to push. Exit. |
| User declines confirmation | Report: push cancelled. Exit. |
| Git push fails | Report error, do not retry. Exit. |
| CLAUDE.md not gitignored | Warn and ask for confirmation. |

## Error Handling

| Condition | Behavior |
|-----------|----------|
| Multiple prep markers in nested directories | Use the one closest to the target path |
| Merge conflicts on push | Report conflict, suggest `git pull --rebase` |
| Detached HEAD or non-main branch | Warn user and ask if they want to proceed |
| Staged changes include files that look personal | Warn before committing |
