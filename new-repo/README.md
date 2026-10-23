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
distribute local configuration. Follow `AGENTS.md` to validate the native config
and install hooks once if missing. Native setup can be proved independently of
hosted activation. Deliver a reviewed native enrollment through the producer
release before exercising the caller. The current private route consumes that
released declaration directly; enrollment alone does not require another private
instance or prompt release. Do not move immutable release tags.
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

The original created/existing consumer and both-agent setup/repeat acceptance
belongs to the completed initial rollout. Reuse it; a later create or update does
not require another pilot repository or test matrix. Verify the requested target's
ordinary local checks, installed caller, protections and normal review/merge,
preserving its actual delivery duties. A conforming repeat has no source diff,
redundant settings write, new PR or release. Cost accounting is separate from
ordinary repository setup.

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
| Local hook installation | Existing estate Git template and native `pre-commit install` |
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
entrypoints, with clear missing-dependency errors. Native hook installation does
not install system binaries; existing host provisioning supplies tools including
Vale for prose checks through the established package manager.
Do not attach a blanket suite or add an inheritance/merge configuration.
Local formatters run at commit only; keep a single owner for each language.

An independently justified hosted project check can consume the universal
workflow's native `classification` and `head_sha` outputs with `needs` and `if`.
Skip software checks for `mechanical` and `documentation`; run them for
`functional`. Do not add a path classifier or classify again. Before executing PR
code, require the functional output and an exact bound head matching the event's
PR head, so missing producer outputs fail before checkout. Keep that code in a
separate fresh job with only `contents: read`, no secrets or named deployment
environment, no cache use or cache write override, and `persist-credentials: false`;
the shared trusted job treats PR content as data. Before PR checkout, the trusted
step must read the runner's effective `ACTIONS_CACHE_MODE` through a trusted,
SHA-pinned JavaScript action and require it to be `read` or `none`; missing or
write-capable modes fail before executing PR code. Ordinary shell steps do not
receive this variable in runner 2.337.0; do not set it yourself or assume
`run: node` supplies it. GitHub
enforces cache access through scoped tokens and currently grants
`pull_request_target` read-only cache access by default; see its
[cache access controls](https://docs.github.com/en/actions/reference/workflows-and-actions/dependency-caching#cache-access-for-low-trust-workflow-triggers).
Retain the project's declared required context and reporter, verifying native
skips through the existing Margot floor. Publish the producer outputs through the
normal release and `@v1` channel before activating a consumer that uses them.

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

The existing estate Git template installs pre-commit, pre-push, commit-msg and
prepare-commit-msg entrypoints in new agent clones. Linked worktrees reuse their
repository's hooks. Follow `AGENTS.md` for a one-time native installation in an
existing unprepared checkout. Pre-commit installs managed environments lazily and
reuses its cache; existing host provisioning supplies system binaries and the
repository's ordinary setup supplies project dependencies. No Claude startup or
shared preparation helper is required. Commit/push owns ordinary checks; focused diagnostics are optional
when investigating a failure. Versioned plugins add the existing exported
`release-version` hook with their actual plugin paths/names; Eve uses its own
package checker. Keep real tag/release jobs and their push conditions, removing
obsolete `needs` only during the proved consumer transition.

## Ordered create or update procedure

Use this order for both public and private repositories. Run source operations
through the intended author identity; run creation and administration only under
the owner's already authorized identity. The `gh` commands below mean that
identity's supported client. Codex uses the `estate-codex` boundary in `AGENTS.md`
and its `APP_GH`; Claude retains its enrolled profile. Preserve unrelated source,
rules, restrictions and intentionally disabled workflows at every step.

1. **Read identity and state.** Set `repo` to the requested `owner/name`,
   `DOTTY_CHECKOUT` to reviewed working Dotty source, and `REPOSITORY_CHECKOUT` to
   the target clone or worktree. Read repository metadata and the complete live
   settings/rulesets, environment policies, workflow states and App coverage.
   An inaccessible repository is not proof that it is absent.

   ```sh
   gh api "repos/$repo" --jq '{full_name,visibility,default_branch}'
   ```

   If the available Dotty path is bare, stale or lacks these assets, obtain a new
   working checkout through ordinary Git and select the actual reviewed release;
   choose a new nonexistent destination and set `DOTTY_CHECKOUT` to it before
   cloning. Do not clone over or reset the bare/stale path. Set `dotty_ref` to the
   verified release.

   ```sh
   gh repo clone lexijamesesq/dotty "$DOTTY_CHECKOUT"
   git -C "$DOTTY_CHECKOUT" checkout --detach "$dotty_ref"
   git -C "$DOTTY_CHECKOUT" rev-parse HEAD
   ```

2. **Create only if absent; establish real App access.** Under the authorized
   creation identity, use `gh repo create "$repo" --private` or `--public` for
   the requested visibility, then read the result back. Verify actual author,
   reviewer and merger installation coverage. Missing repository selection is
   an owner-controlled App installation action, not something a token can grant
   itself. With author access established, use a usable existing target clone or
   worktree. Only when none exists, choose a new nonexistent
   `REPOSITORY_CHECKOUT` destination and clone through that author identity:

   ```sh
   gh repo clone "$repo" "$REPOSITORY_CHECKOUT"
   ```

   For an existing repository, retain its observed default branch and visibility;
   do not create another repository. Set `default_branch` from the observed
   metadata once its real default branch exists.

3. **Prepare native files and seed an empty default branch.** Read each target
   file and apply the common assets listed above plus the public or private
   `.house-code.json` for its actual visibility. Preserve native project hooks,
   working instructions, ownership declarations and release jobs. Install the
   current `ci.yml`, `ollie-merge.yml` receiver and `ollie-bounce.yml` relay from
   these sources; add no legacy gate or self-instrument alert. Resolve immutable
   local hook revisions to an actual released Dotty version.

   Existing estate templates install hooks for the new clone. If this is an
   existing unprepared checkout, use the native installation in `AGENTS.md` once;
   preserve custom hook owners and `core.hooksPath`.

   Use normal `git add`, `git commit` and `git push` with the effective native
   hooks. For an empty repository, seed its intended default branch through this
   authoring path before imposing requirements that no initial commit can satisfy.
   Do not activate a newly installed automatic merger before complete protections
   are verified. Existing repositories retain their ordinary protections and
   authorized maintenance sequence.

4. **Release enrollment before exercising CI.** Prepare the target's
   `.repos["owner/name"]` entry in Dotty's `rulesets/default-branch.json`, using
   its actual visibility, current `Shared / Pre-Merge Checks` requirement and real
   native extensions/owned paths. Publish that source through normal review and
   the owner-controlled merge path. Wait for the normal producer release and
   verify its published `@v1` source contains the entry. The current private route
   reads this released declaration; it rejects unenrolled targets. No separate
   per-new-repository private-policy, package or prompt release is required unless
   an actual implementation change independently needs one.

5. **Install on the default branch and hold a newly installed merger.**
   `pull_request_target` uses the installed default-branch `ci.yml`, and an Ollie
   approval dispatch requires `ollie-merge.yml` on that branch. An existing
   repository's installation PR cannot use the receiver it is adding to merge
   itself. The owner handles an explicitly authorized first-install bootstrap
   merge when required; an agent never assumes or performs a bypass. Once a new
   receiver exists on the default branch, the authorized setup owner holds it
   before delivering its merge key or opening a ready PR, until complete
   protections are verified. Record its observed and intended final workflow
   state, then use the native disable and readback:

   ```sh
   gh api "repos/$repo/actions/workflows/ollie-merge.yml" --jq '{path,state}'
   gh workflow disable ollie-merge.yml --repo "$repo"
   gh api "repos/$repo/actions/workflows/ollie-merge.yml" --jq .state
   ```

   Verify `disabled_manually`. This hold applies to first installation or the
   specifically authorized maintenance transition, not an incidental update or
   conforming repeat. Preserve an existing active merger and any pre-existing
   intentional disabled state unless that transition explicitly owns the change.

6. **Deliver the environment inputs and observe the real caller.** Use the
   native environment/custody operations below. Restrict `default-branch` to the
   target's actual default branch. Verify App coverage, all required nonempty
   inputs and owner authorization before secret writes; then deliver through
   native `gh secret set` stdin and read back metadata, never values. The central
   producer does not eliminate these target-environment responsibilities. Use an
   ordinary ready PR for useful target work to observe the actual installed
   caller after enrollment release and environment setup. Record its
   base/head, check/run IDs and numeric reporters. The shared required result is
   `Shared / Pre-Merge Checks` from GitHub Actions App `15368`; verify it on this
   target. Preserve independently declared native checks. Retired `ci / checks`
   and `trusted-scan / trusted-scan` are not the shared baseline.

7. **Apply complete protections and finish ordinary delivery.** Use the direct
   settings operations below, with complete canonical bodies, the target's real
   extensions and observed reporter bindings. POST missing rulesets or PUT their
   observed IDs; read back merge preferences, reviews/checks, the separate update
   wall, tags, environment restrictions and App coverage. Skip conforming writes.
   If the intended final state is active, enable the newly installed/held Ollie
   merger only after these protections are verified, then read back `active`:

   ```sh
   gh workflow enable ollie-merge.yml --repo "$repo"
   gh api "repos/$repo/actions/workflows/ollie-merge.yml" --jq .state
   ```

   Leave an intentionally disabled merger disabled. Then observe intended review, normal merge
   and applicable post-merge delivery for the target. A conforming repeat compares
   existing state without another PR, release or pilot.

For an older PR branch that lacks `ollie-bounce.yml`, update it through the normal
reviewed branch workflow. Once the receiver exists on the observed default
branch, a specifically authorized targeted recovery can instead use its existing
dispatch input:

```sh
gh workflow run ollie-merge.yml --repo "$repo" --ref "$default_branch" -f "pr=$pr"
```

This requests the ordinary receiver; it does not bypass checks or review and is
not an automatic dispatch policy. A 404 before first installation is a missing
default-branch receiver, not a reason to replace Ollie or widen permissions.

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
new service account/helper. Read the current caller declarations before delivery:
`ci.yml` passes the first four names below; Ollie's caller separately needs its
existing key. The known custody metadata is:

| Target `default-branch` secret | Existing custody source |
| --- | --- |
| `OPERATOR_RULES` | Authorized installed `${XDG_CONFIG_HOME:-$HOME/.config}/gitleaks/operator-rules.toml`, the same path used by `gl_overlay_path` in `git-hooks/gitleaks-common.sh` |
| `MARGOT_APP_KEY` | `op://Margot Ops/GitHub App Private Key - Margot/private key` |
| `MARGOT_JEV_KEY` | `op://Margot Ops/Jev API Key/credential` |
| `MARGOT_ANTHROPIC_TOKEN` | `op://Margot Ops/Anthropic OAuth Token - Margot/credential` |
| `OLLIE_APP_KEY` | `op://Calcifer Ops/GitHub App - Ollie/private key` |

Every 1Password value (the four `op://` rows above) is delivered with the operator's own
native `op read` (desktop 1Password, her biometric grant), under explicit human
authorization for that delivery; `OPERATOR_RULES` is read from the installed rules file
named in its row. Knowing
these references, or a prior repository's human approval, does not grant fresh value
access. Honor applicable authorization and obtain only missing authority before
reading or delivering values. There is no service-account or Connect path for these
items: the estate's Connect server is scoped to the Agent Ops vault, and the service
account that once read Margot Ops is retired. Do not create or substitute an account
or helper. The operator-input path likewise requires existing authorization; do not
search operator files or access `~/.config/estate/`.

Prepare valid environment request files from the native state/declaration. For
a new environment, the policy body is
`{"deployment_branch_policy":{"protected_branches":false,"custom_branch_policies":true}}`;
the branch policy body is `{"name":"<actual default branch>","type":"branch"}`.
Use the actual branch rather than a PR/tag wildcard. On updates preserve other
restrictions and skip an already conforming policy.

```sh
gh api --method PUT "repos/$repo/environments/default-branch" --input environment-request.json
gh api "repos/$repo/environments/default-branch"
gh api --method POST "repos/$repo/environments/default-branch/deployment-branch-policies" --input branch-policy-request.json
gh api "repos/$repo/environments/default-branch/deployment-branch-policies"
```

Skip conforming secret delivery; do not reread or rewrite values merely for a
repeat. For authorized first delivery, the following native Bash commands name
each reader and target explicitly. Run without shell tracing. They resolve all
five inputs in process memory and require them to be nonempty before any secret
write. Every `op read` and the operator-input read require their own applicable
authorization; do not run this example simply because the references are known.

```sh
set -euo pipefail
margot_app_key="$(op read 'op://Margot Ops/GitHub App Private Key - Margot/private key')"
ollie_app_key="$(op read 'op://Calcifer Ops/GitHub App - Ollie/private key')"
margot_jev_key="$(op read 'op://Margot Ops/Jev API Key/credential')"
margot_anthropic_token="$(op read 'op://Margot Ops/Anthropic OAuth Token - Margot/credential')"
operator_rules_file="${XDG_CONFIG_HOME:-$HOME/.config}/gitleaks/operator-rules.toml"
operator_rules="$(cat "$operator_rules_file")"
[[ -n "$margot_app_key" && -n "$ollie_app_key" && -n "$margot_jev_key" && -n "$margot_anthropic_token" && -n "$operator_rules" ]]
printf '%s' "$operator_rules" | gh secret set OPERATOR_RULES --env default-branch --repo "$repo"
printf '%s' "$margot_app_key" | gh secret set MARGOT_APP_KEY --env default-branch --repo "$repo"
printf '%s' "$margot_jev_key" | gh secret set MARGOT_JEV_KEY --env default-branch --repo "$repo"
printf '%s' "$margot_anthropic_token" | gh secret set MARGOT_ANTHROPIC_TOKEN --env default-branch --repo "$repo"
printf '%s' "$ollie_app_key" | gh secret set OLLIE_APP_KEY --env default-branch --repo "$repo"
unset margot_app_key ollie_app_key margot_jev_key margot_anthropic_token operator_rules
gh secret list --env default-branch --repo "$repo" --json name,updatedAt
```

Read back names/freshness and verify the environment's actual branch policy and
the private instance's protected immutable tag policy. Do not widen them just to
make a job run.

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
transition, bind `Shared / Pre-Merge Checks` to the GitHub Actions App (15368).
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

Reuse the completed initial migration's created/existing consumer and both-agent
setup/repeat proof. A later operation verifies the affected repository's ordinary
behavior; it does not create extra consumers or repeat the fleet pilot. Record
observations and unresolved permissions/artifact dependencies. Printed future
instructions, synthetic API fixtures and source validation do not establish
installed proof.

The agent executing setup owns resolving or reporting each failed step. Report
the command, nonsecret error and exact missing prerequisite; a shared Dotty source
defect goes to the Dotty owner (`system-lead`). Preserve a blocked step and its
already completed work; do not improvise a hand workaround or credential route.
