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

Commit and push after verifying the prep marker's verdict. The project directory IS the repo.

## Invocation

```
/github-push [path]
```

## Step 0: Resolve target path

Capture the argument from `ARGUMENTS:` / `<command-args>` (empty if none), then run:

```bash
~/bin/dotty/.claude/lib/resolve-path.sh "<arg-or-empty>" "$HOME/.cache/claude/github-push-target"
```

Resolver's stdout is the target path. Non-zero exit → report stderr and stop.

State resolved path:
- Explicit arg or sentinel → `Pushing from: <path>`
- PWD fallback → `Pushing from: <path> (defaulted to current directory; no target specified)`

Precedence: explicit arg > sentinel (TTL-bounded, not deleted) > PWD.

### Orchestrator-invocation contract

Other agents must write a JSON sentinel first:

```bash
NOW_UTC=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
printf '{"path": "/absolute/path/to/target", "created_at": "%s"}\n' "$NOW_UTC" \
  > ~/.cache/claude/github-push-target
```

Then call `Skill(skill: "github-push")`. Sentinel TTL: 5 min.

Resolved path must be inside a git repo. If not, report "No git repository found at {path}" and exit.

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

Compute the staged-scope verdict via the script (covered by `filtered-verdict.test.sh`):

```bash
git -C "$REPO_ROOT" diff --cached --name-only -z > /tmp/push-staged-$$.list
[ -s /tmp/push-staged-$$.list ] || { echo "Nothing to push."; exit 0; }

~/bin/dotty/.claude/lib/filtered-verdict.sh \
  "$REPO_ROOT/.github-prep-status.json" \
  /tmp/push-staged-$$.list \
  > /tmp/push-verdict-$$.json

FILTERED_VERDICT=$(jq -r '.filtered_verdict' /tmp/push-verdict-$$.json)
MARKER_VERDICT=$(jq -r '.marker_verdict' /tmp/push-verdict-$$.json)
DRIFT=$(jq -r '.drift' /tmp/push-verdict-$$.json)
```

If `$DRIFT == true`, report:
```
Marker verdict: <marker_verdict> (<N> total findings across the repo)
Staged-scope verdict: <filtered_verdict> (M findings on the <scope_count> staged files)
Proceeding under staged-scope verdict.
```

Then act on `$FILTERED_VERDICT`:

- **`allow`** — proceed to 2c.
- **`escalate`** — refuse. Present findings (category, file:line, snippet, reason). Tell operator to decide each (fix content or update policy's known-references list) and re-run prep. Exit.
- **`revise`** — refuse. Present findings + suggested fixes. Tell operator to fix in code and re-run prep. Exit.
- **`block`** — refuse unless operator acks each finding. Under `off` strictness, surface but don't gate. Otherwise:
  1. Present each Block finding numbered, with full context from marker.
  2. Require exact-string ack: `I acknowledge Block finding #N: <category> at <file>:<line>`.
  3. On valid ack, append to marker's `acknowledgments`: `{finding_index, finding_hash, acknowledged_at, ack_string, operator_reason}`.
  4. After all acked (or abort), proceed to 2c.

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

### Step 4: Draft commit message + confirm with user

Draft a commit message describing the staged work. **Do not include Linear ticket references (e.g., <TEAM>-N, INST-42) in the message.** Ticket context belongs in the Linear ticket itself; the commit message should stand alone for a public reader.

Present the message + file list and STOP. End with a clearly-named approval phrase so the operator can copy-or-type it back:

```
Ready to push to {remote-name} ({remote-url}):

Files to commit ({N} files, +{ins} -{del}):
  {file list with --stat numbers}

Commit message: "{proposed message}"

To authorize, send: approve commit and push
(Or reply with a modified message; or `no` to abort.)
```

Do NOT proceed until the operator sends an approval message. "Keep going" earlier in the conversation does not authorize this commit — ask each time. The Claude Code classifier enforces this: a sentinel created without explicit conversational approval is denied.

No remote configured → ask user to set one up (`git remote add origin {url}`) and exit.

### Step 5: Stage files

Stage specific changed files with `git add` using explicit paths. Never `git add -A` or `git add .` — list each file explicitly.

`git add` is not a gated verb (no sentinel needed); runs directly.

### Step 6: Commit (gated — two-call sentinel pattern)

Each gated git op requires the sentinel marker. Re-create before each op (commit and push are separate Bash calls; each consumes its own sentinel).

Use `${CLAUDE_CODE_SESSION_ID:-$CLAUDE_SESSION_ID}` for the sentinel name. Never read `~/.cache/claude/session-id` — that file races across concurrent sessions.

```bash
# Bash call A: create sentinel (no git verb)
SID="${CLAUDE_CODE_SESSION_ID:-$CLAUDE_SESSION_ID}"
[ -n "$SID" ] || { echo "session id unset; SessionStart hook failed" >&2; exit 1; }
touch "$HOME/.cache/claude/git-authorized-$SID"
```

```bash
# Bash call B: gated commit
git commit -m "$MESSAGE"
```

Use the user's confirmed message + Co-Authored-By trailer.

Failure "Direct git mutation blocked" = session-id mismatch. Verify `${CLAUDE_CODE_SESSION_ID:-$CLAUDE_SESSION_ID}` is non-empty.

### Step 7: Push (gated — same two-call pattern + push approval)

After the commit lands, report the commit hash. Then STOP and ask for explicit push approval — the classifier requires a fresh sentinel-creation approval for the push step even though the commit was already approved:

```
Commit landed: {short-hash}

To push to {remote-name}, send: push it
(Or `no` to leave the commit local.)
```

After the operator sends approval, proceed with the two-call sentinel pattern:

```bash
touch "$HOME/.cache/claude/git-authorized-${CLAUDE_CODE_SESSION_ID:-$CLAUDE_SESSION_ID}"
```

```bash
git push
```

First push: `git push -u origin main` (or current branch).

Push failures (auth, conflicts) → report and stop. Sentinel already consumed; retry requires re-running both calls + a fresh approval.

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
