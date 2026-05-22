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

This contract governs vault knowledge-layer infrastructure types only. Two concerns sit outside the `type/` model entirely, and every other `type/` falls into one of two exemption tiers.

**Exemption tiers** — a governed file's `type/` places it in exactly one tier. Lint derives the tier from this table:

| Tier | Lint treatment | `type/` values |
|---|---|---|
| **Invariant-core-only** | Invariant Core enforced; Per-Type Additions skipped | `type/recipe`, `type/workout`, `type/meeting-capture`, `type/dashboard`, `type/hub` — and any closed-vocabulary `type/` value not in Per-Type Additions nor Structure-not-imposed |
| **Structure-not-imposed** | No structural-contract check applies; only tag-taxonomy tag validity | `type/claude-project`, `type/claude-hub`, `type/claude-wiki`, `type/claude-space`, `type/claude-system`, `type/summary`, `type/scratchpad`, `type/working-notes` |

---

## Parsing Contract

| What to extract | Where | How to parse |
|---|---|---|
| Invariant-core elements | "Invariant Core" table | Each row = one check |
| Per-type additions | "Per-Type Additions" table | Keyed by type/ value |
| Destination modifiers | "Destination Modifiers" table | Rows = aspects |
| Exemption tiers | "Scope Boundaries" › Exemption tiers table | Two tiers, keyed by type/ |
