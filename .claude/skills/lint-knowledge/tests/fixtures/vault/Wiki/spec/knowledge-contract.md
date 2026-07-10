# Knowledge Contract (Test Fixture)


---

## The Namespaces

| Namespace | Question | Vocabulary shape | Typical consumer |
|---|---|---|---|
| `type/<x>` | What KIND of page is this? | Closed set | Router |
| `project/<x>` | Which active Claude project OWNS this? | Closed set | Router |
| `area/<hierarchy>` | Which life/work area is this ABOUT? | Hierarchical | Summary |
| `topic/<x>` | What specific SUBJECTS does this cover? | Open | Discovery |
| `person/<x>` | Who is REFERENCED on this page? | Closed per roster | Relationship |
| `status/<x>` | What LIFECYCLE state is this in? | Closed set | Lint |

---

## Per-Namespace Rules

### `type/`

**Vocabulary (closed set):**

| Value | Meaning |
|---|---|
| `type/knowledge` | Maintained narrative knowledge |
| `type/raw` | **Deprecated.** Retag to `type/knowledge`. |
| `type/data` | Structured per-item record |
| `type/context` | Domain schema + Claude's working understanding |
| `type/project-pointer` | Wiki/Contexts/ redirect to an active project |
| `type/summary` | Human-readable page |
| `type/scratchpad` | Human-owned persistent scratch space |
| `type/working-notes` | Claude's ephemeral session scratch |
| `type/spec` | Technical specification |
| `type/agent-spec` | Agent definition |
| `type/reference` | Stable reference material |
| `type/log` | Append-only log |
| `type/dashboard` | Bases view / dashboard page |
| `type/claude-project` | Project CLAUDE.md |
| `type/claude-hub` | Hub CLAUDE.md |
| `type/claude-wiki` | Wiki CLAUDE.md |
| `type/claude-space` | Space sidecar |
| `type/claude-system` | System project CLAUDE.md |
| `type/hub` | General hub page |
| `type/eval` | Evaluation artifact |
| `type/recipe`, `type/workout`, `type/lodging-destination`, `type/travel-profile` | Domain-specific content shapes |
| `type/job_interview`, `type/candidate_interview`, `type/interview`, `type/interview_comms`, `type/interview_questions`, `type/recruiting`, `type/discovery`, `type/onboarding` | Interview/recruiting content shapes |
| `type/meeting-capture` | Curated meeting captures |
| `type/strategy`, `type/docker` | Other domain-specific shapes |

**Threshold:** HIGH.

**Depth:** Always 2.

### `project/`

**Vocabulary:** Closed set, matches `Projects/{Name}/` folder names in kebab-case.

**Authoritative source for active values:** runtime `list_directory` on `Projects/`.

**Threshold:** HIGH (procedural).

**Depth:** 2 preferred; 3 only for durable sub-projects. Historical project tags (`project/bramblesoft/*`, `project/twig/*`) grandfathered at deeper levels.

### `area/`

**Vocabulary:** Hierarchical, semi-closed.

**Top-level roster:** the closed set of top-level `area/` values lives in `tag-taxonomy-rosters.md` (PII exclusion), same treatment as `person/` and `area/work/`.

**Sub-areas:** open growth under a recognized top-level; not roster-governed — discover existing sub-areas via `list_all_tags`.

**Illustrative examples only (not real vocabulary):**
- `area/work/{employer}` — `area/work/placeholderco`.
- `area/sample-hobby` — a plain top-level with two sub-areas: `area/sample-hobby/alpha`, `area/sample-hobby/beta`.

**Threshold:** MEDIUM.

**Depth:** 2-3 natural. Max 3.

### `topic/`

**Vocabulary:** Open, stewarded.

**Threshold:** LOW (stewarded).

**Depth:** Always 2.

### `person/`

**Vocabulary:** Closed per known roster. Kebab-case: `person/first-last`.

Roster lives in `tag-taxonomy-rosters.md`, not here (PII exclusion). Illustrative example only (not real vocabulary): `person/sample-placeholder`.

**Threshold:** MEDIUM.

**Depth:** Always 2.

### `status/`

**Vocabulary (closed set):**

| Value | Meaning |
|---|---|
| `status/stub` | Pending research |
| `status/active` | Current, maintained |
| `status/archived` | Kept for history |
| `status/deprecated` | Superseded |
| `status/draft` | In-progress |

**Threshold:** HIGH.

**Depth:** Always 2.

---

## Growth Thresholds (Summary)

| Namespace | Threshold | Enforcement |
|---|---|---|
| `type/` | HIGH | This doc |
| `status/` | HIGH | This doc |
| `project/` | HIGH (procedural) | `/new-project` |
| `area/` | MEDIUM | Claude proposes |
| `person/` | MEDIUM | Second+ appearance |
| `topic/` | LOW (stewarded) | Fuzzy-match |

## Depth Limits (Summary)

| Namespace | Typical | Max |
|---|---|---|
| `type/` | 2 | 2 |
| `status/` | 2 | 2 |
| `project/` | 2 | 3 (historical tags grandfathered deeper) |
| `area/` | 2-3 | 3 |
| `topic/` | 2 | 2 |
| `person/` | 2 | 2 |

---

## Downstream Consumers

| Artifact | What it consumes | Status |
|---|---|---|
| `/lint-knowledge` | Validates namespace membership | Pending |

---

## Tag Migration Legacy

Pre-v2 tag state requiring cleanup.


---

## Invariant Core

Every knowledge-layer file MUST have:

| Element | Requirement |
|---|---|
| `type/` tag | Exactly one, from the closed `type/` vocabulary |
| Scope tag | At least one `project/<name>` OR `area/<hierarchy>` |
| `status/` tag | Exactly one, from the closed `status/` vocabulary **[tightening]** |
| `updated` | `updated: YYYY-MM-DD` frontmatter |
| Title | Exactly one level-1 heading (`# Title`) **[tightening]** |
| Tag validity | All tags conform to tag-taxonomy |

---

## Per-Type Additions

| `type/` | Also requires | `sources` |
|---|---|---|
| `type/knowledge` | `topic/` — Wiki-hosted only (see Destination Modifiers) | Required |
| `type/context` | — | Optional |
| `type/data` | — | Optional |
| `type/reference` | — | Optional |
| `type/spec` | — | Optional |
| `type/agent-spec` | — | Optional |
| `type/project-pointer` | `project/`, `topic/` | n/a |
| `type/log` | — | n/a |
| `type/eval` | — | Optional |

---

## Destination Modifiers

| Aspect | Wiki-hosted (`Wiki/Knowledge`, `Data`, `Contexts`) | Project-hosted (`Projects/<name>/Knowledge`, `System/`) |
|---|---|---|
| Scope tag | `area/<hierarchy>` | `project/<name>` |
| `topic/` on `type/knowledge` | Required, ≥1 **[tightening]** | Optional |
| Index participation | None — `area/` + `topic/` tags ARE the index | An `index.md` entry for the file exists |

---

## Freshness

| Field | Meaning | Requirement |
|---|---|---|
| `updated` | File last touched | Required |
| `verified` | Content last reviewed | Optional |

---

## Scope Boundaries

This contract governs genuine knowledge-layer documents only. A file is in governed scope only if it passes the Location Gate AND carries a governed `type/`.

### Location Gate

A file is in a governed location only if its vault path matches one of:

| Governed location | What lives there |
|---|---|
| `System/*.md` and `System/Knowledge/**` | Vault knowledge-layer docs |
| `System/Context/**` | System Claude working-context docs |
| `Projects/<name>/Knowledge/**` | Per-project knowledge-layer docs |
| `Projects/<name>/Context/**` | Per-project Claude working-context docs |
| `Wiki/Knowledge/**` | Wiki maintained narrative knowledge |
| `Wiki/Contexts/**` | Wiki domain context docs |

Every other location is ungoverned and lint skips it entirely.

### Exemption tiers

**Exemption tiers** — a governed file's `type/` places it in exactly one tier. Lint derives the tier from this table:

| Tier | Lint treatment | `type/` values |
|---|---|---|
| **Fully governed** | Invariant Core + Per-Type row | every `type/` in the Per-Type Additions table |
| **Invariant-core-only** | Invariant Core enforced; Per-Type Additions skipped | `type/recipe`, `type/workout`, `type/dashboard`, `type/hub` — and any closed-vocabulary `type/` value not in Per-Type Additions nor Structure-not-imposed |
| **Structure-not-imposed** | No structural-contract check applies; only tag-taxonomy tag validity | `type/claude-project`, `type/claude-hub`, `type/claude-wiki`, `type/claude-space`, `type/claude-system`, `type/summary`, `type/scratchpad`, `type/working-notes` |
| **Out of scope** | No check at all — file is ungoverned | `type/data`, `type/meeting-capture` |

---

## Parsing Contract

| What to extract | Where | How to parse |
|---|---|---|
| Invariant-core elements | "Invariant Core" table | Each row = one check |
| Per-type additions | "Per-Type Additions" table | Keyed by type/ value |
| Destination modifiers | "Destination Modifiers" table | Rows = aspects |
| Location Gate | "Scope Boundaries" › Location Gate table | Col 0 = path globs; union is the governed set |
| Exemption tiers | "Scope Boundaries" › Exemption tiers table | Four tiers, keyed by type/ |
