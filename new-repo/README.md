# Create or update an estate repository

Use the existing `new-repo` skill with these native assets. The implementing agent
inspects the repository, prepares ordinary file edits and complete GitHub API
bodies, applies authorized changes, and reads them back. The replacement uses
native source and direct operations; it adds no provisioner, configuration merger
or scheduled fleet writer.

The local baseline keeps immutable, Renovate-managed hook revisions. Hosted
consumers call `estate-pr-ci.yml@v1`; the release workflow advances that channel
only after release checks pass. The reusable resolves its producer from
`job.workflow_sha`, while its private Margot instance and public review package
remain pinned to immutable numbered releases. Agents apply copied native-config
changes through the existing repository update procedure; hosted `@v1` does not
distribute local configuration. Run checkout preparation afterward to validate
and install the declared hooks. Native setup can be proved independently of
hosted activation. Deliver a reviewed enrollment and matching private policy
snapshot before exercising the caller. Do not move immutable release tags.
Existing repository contexts and policy in `rulesets/default-branch.json` remain
live declarations, not authority to change required checks early.

## Installation and retirement order

Use prepared, independently reviewed native assets and the existing shared
`new-repo` skill to prove actual local setup before publishing this coherent
retirement. Native local setup does not require the migrated hosted runtime.
Do not run old provisioners against migrated templates. Install the migrated
caller and retire a consumer's obsolete `gate.yml` only when its matching
producer/instance, credentials, local proof and required-check transition are ready.

The former convergence writer, provisioners, configuration mergers and legacy
gate template are retired. Use native source and direct operations for settings
changes.
Retain independent policy assertions, real releases and Ollie.

The one-time replacement acceptance uses one real new and one existing consumer,
both actual authoring agents, applicable negative/corrected commit and push cases,
and a conforming repeat with no source diff, redundant settings write, new PR or
release. This proof precedes deployed retirement. The matching hosted review,
normal merge/delivery and cost proof follow their runtime dependencies; an ordinary
later update does not repeat the pilot or create additional consumers.

Use the installed maintained checkout, with an explicit override when needed:

```sh
DOTTY_CHECKOUT="${DOTTY_CHECKOUT:-$HOME/bin/dotty}"
```

Use a maintained working checkout for the helper and canonical source. If
`$HOME/bin/dotty` is bare, set `DOTTY_CHECKOUT` to the maintained working checkout
before running the helper. Record the exact reviewed asset source used for
preparation and proof; before activation ensure the hosted channel and its
immutable private-instance/package references point to the reviewed releases,
and preserve ordinary native author access throughout the transition.

## Native source assets

| Duty | Canonical source in Dotty |
| --- | --- |
| Shared native hooks and tool pins | `new-repo/templates/common/.pre-commit-config.yaml` and `.pre-commit-hooks.yaml` |
| Ruff, shell, YAML, Markdown and web configuration | `ruff.toml`, `.shellcheckrc`, `.yamllint.yaml`, `.markdownlint.yaml`, `biome.json`, `.prettierrc` |
| Secret scanner configuration | `new-repo/templates/common/.gitleaks.toml` |
| Public/private content policy | `new-repo/templates/public/.house-code.json`, `new-repo/templates/private/.house-code.json` |
| Working instructions and PR body | `AGENTS.md`, `repo-claude-template.md`, `.github/pull_request_template.md` |
| Checkout preparation | `scripts/prepare-checkout.sh` |
| Migrated hosted caller | `new-repo/templates/common/.github/workflows/ci.yml` |
| Merge settings | `rulesets/repository-settings.json` |
| Reviews, updates, checks, tags and enrollment | `rulesets/default-branch.json` |
| Merger and approval relay | `.github/workflows/ollie-merge.yml`, `.github/workflows/ollie-bounce.yml` |
| Plugin release and version check | `.github/workflows/estate-plugin-release.yml`, `.github/scripts/check-plugin-version.sh`, `git-hooks/release-version.sh` |
| Dependency updates | `default.json`, `.github/workflows/renovate.yml` |

For a new consumer, prepare its `.repos["owner/repo"]` enrollment entry in
`rulesets/default-branch.json` as a reviewed Dotty source change, using its actual
visibility and prepared required-context declaration. Release
and install that producer revision before exercising the trusted caller, which
refuses unenrolled repositories; bind live rule reporters only from trustworthy
observed runs. This candidate leaves existing enrollment entries unchanged.

Read each existing consumer file before applying the baseline. Keep useful local
hooks, project-only lint, exclusions, dependencies, and project checks. Use native
`repo: local`, `language: system`, explicit `stages: [pre-push]`, and
`pass_filenames: false` for project entrypoints. Their cheap outgoing-range
selection must include deletions, renames and shared inputs and fail on an unknown
range. Keep project prerequisites in the repository’s existing setup and
entrypoints, with clear missing-dependency errors; shared checkout preparation
checks native hook environments, shared tools and system entrypoint availability.
Do not attach a blanket suite or add an inheritance/merge configuration.
Local formatters run at commit only; keep a single owner for each language.

When applying the native hook template, resolve its Dotty `rev` to the actual
immutable release of the reviewed producer source, verify that release exists,
and record it. Preserve a newer compatible pin in an existing consumer. The
template's Dotty self-pin is not automatically advanced by Renovate in Dotty;
consumer hook updates remain Renovate-managed.

File presence is separate from style policy: preserve existing required-file
arguments. Add the exported `check-file-presence` hook only for files the project
actually requires. README and license templates are available, not a mandate to
rewrite an existing README, change its sections, add scaffold checks, or relocate
skills. Copy relevant native tool configurations and extend them narrowly for
real repository syntax. Do not replace project-specific instructions with
Dotty's own repository guide; use its shared checkout/authoring contract and fill
the working-guide template with the actual project commands.

Run `bash "$DOTTY_CHECKOUT/scripts/prepare-checkout.sh" "$REPOSITORY_CHECKOUT"` in the consumer
using the reviewed maintained Dotty checkout. It validates the native declaration,
installs all three hooks and their environments, and checks applicable tools.
Repeat setup must reuse those environments without editing source or running the
project suite. Commit/push owns ordinary checks; focused diagnostics are optional
when investigating a failure. Versioned plugins add the existing exported
`release-version` hook with their actual plugin paths/names; Eve uses its own
package checker. Keep real tag/release jobs and their push conditions, removing
obsolete `needs` only during the proved consumer transition.

## Authority and prerequisites

Discover owner, visibility, default branch and the identity for each operation.
A successful repository GET is not proof of create or administration authority.
Source commits and PRs use the enrolled author identity. Use the specifically
authorized infrastructure account only for operations it is allowed to perform.
Create an empty repository with `gh repo create` under that identity; establish
actual author App access, then seed a real default-branch commit through the
normal authoring path before enforcing checks.

Verify actual author, reviewer and merger App installation/repository coverage
through their supported installation mechanism. Installation selection may need
owner-controlled settings. Do not infer coverage from an unrelated account's
installation-list endpoint or treat an unreadable response as absence. Prepare
only the necessary access change and verify it with the real actor afterward.

Resolve environment restrictions, App access and secret presence independently.
Use supported secret custody and delivery without printing values or inventing a
new service account/helper. The migrated caller lists the secrets it consumes;
Ollie's caller separately needs its existing key. Verify the `default-branch`
environment's actual branch policy, secret metadata, and the private instance's
protected immutable tag policy. Do not widen them just to make a job run.

## Direct settings operations

Capture current repository settings and full ruleset bodies before writes.
Compare owned fields first and skip a write when they already conform.
Use the canonical merge JSON directly as the repository PATCH body, then GET and
compare every owned field. Preserve other repository settings.

```sh
gh api --method PATCH "repos/$repo" --input "$DOTTY_CHECKOUT/rulesets/repository-settings.json"
gh api "repos/$repo" > repository-after.json
```

Find existing rulesets by the canonical names, not by an assumed ID. Read each
full `repos/$repo/rulesets/$id` body. For an update, start the editable request
from all writable top-level fields, not a partial `.rules` fragment:

```sh
jq '{name, target, enforcement, conditions, bypass_actors, rules}' ruleset-before.json > ruleset-request.json
```

Prepare that complete request from observed data and the declaration. Retain
unowned rule objects and conditions. Within an owned rule, update only declared
owned parameters and preserve other fields and parameters (for example,
`pull_request.parameters.allowed_merge_methods`). Do not replace its complete
parameter object with the smaller canonical subset.
The branch target is `branch`, enforcement is `active`, and a new branch ruleset's
ref condition includes `~DEFAULT_BRANCH` with an empty exclusion list. Use the
canonical review parameters for `pull_request`; `non_fast_forward` and
`deletion` need their native type objects. An `update` rule also requires
`parameters.update_allows_fetch_and_merge`: preserve the observed value on
update and use false for a new update wall or immutable-tag rule. Validate the
complete request against the current native API schema before applying it. `required_status_checks` needs the
canonical strictness value and a nonempty array of actual `{context,
integration_id}` bindings. Never substitute a check name for reporter identity.
Resolve every declared context against trusted observed check runs before any
ruleset write; failed or incomplete reads stop the operation. For the migrated
transition, bind `CI / pre-merge checks` to the GitHub Actions App (15368).
Bind each retained exception to the reporter observed for that declared context;
do not infer reporter identity from the context name. Prepare those bindings
together with the reviewed per-repository declaration change, not ahead of it.

For each split branch ruleset, union its declared bypass actors with any
repository-specific declared actors, deduplicating the complete actor triple.
If neither source declares a bypass list, preserve the live list; explicitly
empty declared lists mean an empty list. Do not convert absence into emptiness.
A ruleset bypass applies to every rule in that ruleset: keep the update wall
separate from reviews and checks. Preserve the canonical PR-only bypass modes.
Never delete other or superseded rulesets as an incidental update.

For a new ruleset, prepare the same six complete fields explicitly from these
sources instead of using the update extraction on a missing object. Validate
that all owned rules and reporter bindings are present before POST; never create
an enforced empty-check or review-only intermediate policy. Apply the prepared
body with the native endpoint, then GET that returned ID and compare all fields:

```sh
# Existing ruleset; creation uses POST repos/$repo/rulesets with the same full body.
gh api --method PUT "repos/$repo/rulesets/$id" --input ruleset-request.json
gh api "repos/$repo/rulesets/$id" > ruleset-after.json
```

Tag immutability uses target `tag`, active enforcement, canonical update/deletion
rules and no bypass. New rulesets include `refs/tags/*`; preserve live include
patterns on update. Set exclusions from the repository's declaration (absent
means none). In particular, Dotty's declared floating-major exclusion must
survive, while immutable release tags remain protected. Tag origin is a separate
readback against the declared release authors; a protected tag is not proof of
who created it.

Preserve the live `default_workflow_permissions` when PUTting the complete
Actions workflow-permissions body and set `can_approve_pull_request_reviews` to
false. For public repositories enable and read back GitHub secret scanning and
push protection; private personal repositories may not offer those features.
Unreadable is never equivalent to disabled, enabled, or verified.

## Verification and completion

Read back owned settings, exact per-context reporters, tag exclusions, environment
restrictions and App coverage. Review broad admin grants against declared reasons
and deploy-key titles against the declared allowance where present; report
unreadable access and undeclared grants rather than silently removing them.
Check the actual secret metadata/freshness through supported custody; do not read
values for evidence. Retain CODEOWNERS ownership declarations and ordinary
review behavior. Retain Ollie and dependency-update behavior; do not seed a
second dependency bot engine alongside it.

For the migrated caller, preserve its events (including base/title/body edits),
the reusable's single per-PR concurrency group, producer resolution through
`job.workflow_sha`, immutable private-instance/package pins, and separate
release duties. Existing hosted checks stay until installed local authoring proof and
the matching required-check transition are ready.

For the one-time migration acceptance, exercise one new and one existing
consumer with both actual authoring agents,
including real negative/corrected commit and push cases, review/merge behavior,
and a repeated setup/update with no source or settings churn. An ordinary later
update verifies the affected repository; it does not create extra consumers or
repeat the fleet pilot. Record observations
and unresolved permissions/artifact dependencies. Printed future instructions,
synthetic API fixtures, and source validation do not establish installed proof.
