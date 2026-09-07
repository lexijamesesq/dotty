# Drift check — running it, and proving it

`provision-public-repo.sh --check <owner/repo>` reads a repo's live configuration
and reports each drift class as `OK`, `DRIFT`, or `SKIP` (not readable under the
current token) — it mutates nothing. This document covers how the check is run
across the estate and how its acceptance is proven.

## Running the estate-wide report

`drift-check-report.sh` runs `--check` across every repo declared under `.repos`
in `rulesets/default-branch.json` and aggregates the result:

```
./drift-check-report.sh            # check every declared repo; exit 1 if any DRIFT
./drift-check-report.sh <slug> ... # check only the named repos
./drift-check-report.sh --list     # list the repos that would be checked (no calls)
```

It is **read-only** and adds no scope of its own — it drives the same
App-token-safe reads the provisioner already makes, once per repo. Run it on
demand from a Claude Code session through the same path every converge uses
(the session's own App token via the gh wrapper). File its output on the map by
posting the report as a comment on the drift-check ticket.

### Identity and the (deferred) schedule

There is deliberately **no scheduled/unattended trigger**. A repo-level
self-hosted runner serves only its own repo, and the gh wrapper mints the App
token only inside a session; an unattended cross-repo run needs a read-only
identity that does not exist yet. The runner is written so it can become the
body of that scheduled job unchanged once such an identity exists — an
owner-tracked follow-up, gated on the operator's read-only-identity decision.

### Classes that need a fuller token

Under the App token, the classes that read `security_and_analysis`,
`actions/secrets`, `actions/permissions/workflow`, and `repos/<repo>/keys`
report `SKIP  … (not readable under current scope)`. They activate on the same
read path — reporting real state — once the App carries `Environments: read`,
`Secrets: read`, and `Administration: read`, or when the check is run under a
full-scope (operator) login. A `SKIP` is never counted as clean.

## Proving the check catches drift (acceptance procedure)

The synthetic eval suite (`.claude/eval/provision-public-repo.test.sh`) is the
mechanical proof that every class fires on planted drift. The steps below are
the **live** acceptance against the scratch repo `lexijamesesq/probe-local-to-merged`
— run at the acceptance pass under an authorized session (writes are real), each
plant reverted immediately after. File the before/after `--check` output on the
map.

Baseline first — the scratch repo should read clean (or only the
current-scope `SKIP`s):

```
./drift-check-report.sh lexijamesesq/probe-local-to-merged
```

### Plant 1 — a removed core call → `missing-core-call` DRIFT

On a scratch branch, delete the `uses: …/estate-ci.yml@…` line (or its job)
from `.github/workflows/ci.yml`, then check the branch's file state:

```
# publish the tampered ci.yml to a scratch branch via the App path, then:
./drift-check-report.sh lexijamesesq/probe-local-to-merged
# expect: DRIFT missing-core-call = ci.yml does not call estate-ci.yml
```

Revert by deleting the scratch branch.

### Plant 2 — a staled caller pin → `caller-pin` DRIFT (unauthorized)

Change `estate-ci.yml@main` to a dotty commit that is **not reachable on dotty
`main`** (e.g. the head of a dotty feature branch or a closed PR — a real SHA
that never merged). A non-existent ref instead reports `SKIP` ("cannot verify"),
and an older SHA that *is* on `main` reports the advisory `outdated` (not drift,
Dependabot's lane) — so the ref must be a real, unmerged dotty commit:

```
./drift-check-report.sh lexijamesesq/probe-local-to-merged
# expect: DRIFT caller-pin = <ref> not reachable on dotty main (unauthorized ref)
```

Revert by deleting the scratch branch.

### Plant 3 — a hand-pushed tag → `tag-origin` DRIFT

Push a **lightweight** tag (a ref straight to a commit, no tag object) — the
release path always annotates, so a lightweight tag, or an annotated tag whose
tagger is not a release identity, is drift:

```
# push tag scratch-canary via the App path, then:
./drift-check-report.sh lexijamesesq/probe-local-to-merged
# expect: DRIFT tag-origin = scratch-canary (lightweight tag — no release-origin tagger)
```

Revert by deleting the tag.

### What each Done-When bullet maps to

- `--check` clean on all repos, DRIFT on a staled pin and a removed core call →
  the baseline run plus Plants 1 and 2.
- Every non-release-job tag reported → Plant 3 (the release job's own annotated
  tags continue to read `OK`).
- Each repo's CODEOWNERS compared against the declared policy → the
  `codeowners-policy` class, exercised by the baseline run.
