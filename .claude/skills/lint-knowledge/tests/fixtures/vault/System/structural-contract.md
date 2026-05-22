# Structural Contract (Test Fixture)

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
