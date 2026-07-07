# Tag Taxonomy (Test Fixture)

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

Current top-levels (active):
- `area/work/{employer}` — closed employer roster lives in `tag-taxonomy-rosters.md` (PII exclusion). Illustrative example only (not real vocabulary): `area/work/placeholderco`.
- `area/health` — health areas
- `area/finance` — finance areas
- `area/dance` — dance areas
- `area/home`, `area/career`, `area/photography`

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
