# CI workflow shape

The pattern every repo's `.github/workflows/*.yml` copies. Land new
workflows this way; bring existing ones up to it opportunistically, not as a
standalone effort.

## The shape

- **Least-privilege `permissions:`** at the workflow's top level, not per-job
  unless a job genuinely needs more. `contents: read` covers a workflow that
  only checks out code and runs tests/lint — no PR comments, no pushes, no
  releases. Widen only for a job that actually calls the GitHub API.
- **`concurrency:`** with `cancel-in-progress: true`, grouped on
  `${{ github.workflow }}-${{ github.ref }}` (or similarly unique per-branch)
  — a superseded push shouldn't keep burning runner minutes on a PR nobody's
  looking at anymore.
- **`timeout-minutes:`** on every job. A hung step should fail loud, not eat
  the default 6-hour runner cap.
- **Diff-scoped checks use git's own rename detection** (`git diff
  --name-status -M100% --diff-filter=d`, excluding `R100` entries) —
  exact renames are not changed content. A raw `--name-only` diff, or a
  third-party action's default changed-files list, doesn't make this
  distinction: a whole-directory rename (e.g. `claude/` -> `.claude/`)
  makes every file's path change with zero content change, so any check
  gated on "files this PR touched" ends up gating on the entire
  pre-existing tree instead. See Wiki's `.github/workflows/ci.yml` for the
  reference implementation, including the path-scoped-exemption edge case
  (a file moving out of an exempt directory via a pure rename still needs
  re-evaluating under its new path).
- **Every `uses:` action pinned to a full commit SHA**, version in a trailing
  comment (`uses: owner/repo@<40-char-sha> # vX.Y.Z`) — never a floating tag.
  A tag can be retargeted; `tj-actions/changed-files`' tags v1–v45.0.7 were
  retroactively rewritten in a real 2025 supply-chain compromise
  (CVE-2025-30066, CVSS 8.6) that exfiltrated CI secrets from 23,000+ repos.
  Resolve a tag's SHA once (`gh api repos/<owner>/<repo>/git/refs/tags/<tag>`
  or `gh api repos/<owner>/<repo>/commits/<tag>`) and pin it; bump
  deliberately, not automatically.

## Decisions recorded here so they aren't re-proposed without new facts

**gitleaks: a composite action (`.github/actions/setup-gitleaks`), not
`gitleaks/gitleaks-action`.** The vendor action runs its own self-contained
scan inside a Node process with no documented way to leave the `gitleaks`
binary on PATH for a later step — dotty's eval suite hard-requires the real
binary on PATH (`gh-pr-body-guard.test.sh` and `gitleaks-hooks.test.sh` both
drive the actual pre-commit gitleaks hook during tests, `exit 2` if the
binary is missing). Its default PR-scan-range and `gitleaks:allow`-comment
handling are also undocumented, which would silently change security
behavior this repo currently controls explicitly (`--log-opts` range
scoping, `--ignore-gitleaks-allow`). No license cost either way (free for
personal-account repos; only orgs need `GITLEAKS_LICENSE`) — the rejection
is purely functional. Consumers (Wiki, hazel) pin
`uses: lexijamesesq/dotty/.github/actions/setup-gitleaks@<full-sha>` (or, if
already checking dotty out locally for another reason, the local relative
path) — only once `<full-sha>` is a commit on dotty's `main`, never a
pre-merge branch tip.

**actionlint: kept as a pinned curl+checksum install, not a reusable
action.** `rhysd/actionlint` publishes no official `uses:` action — only a
curl-run shell script with no documented independent checksum verification.
dotty's existing install (pinned release, checksums-file verified,
`sha256sum -c`, exact-match assertion) is at least as rigorous. Revisit only
if actionlint ships an official reusable action with equivalent integrity
verification.

**This repo's own release scheme is local, not CI — `release-dotty`, a
skill in the `work-lifecycle` plugin, not a workflow here.** A hosted
runner's token can't open PRs in other repos, and this repo's real
credentials (`gh` auth, the SA SSH key) are local by design — see
work-lifecycle's `CI.md` for the plugin channel's own CI-hosted release
job, which this repo deliberately doesn't mirror. The scheme, run
by the operator (`/release-dotty <this checkout> [--dry-run]`):
computes a UTC calendar-versioned tag — `vYYYY.MM.DD` for the day's
first release touching an exported hook (`.pre-commit-hooks.yaml`,
`git-hooks/**`), `vYYYY.MM.DD-N` for a later one that day, N the next
integer (compared numerically, never lexically) after the highest
existing suffix, bare tag counting as `-1` — and refuses rather than
guesses on a same-day tag that doesn't fit the scheme, or a computed
tag that already exists on origin. Once cut, it opens a bump PR in
every repo whose `.pre-commit-config.yaml` pins this repo's exports,
enumerated at run time, never a fixed list. Full mechanism:
`work-lifecycle`'s `plugins/work-lifecycle/skills/release-dotty/
SKILL.md`.
