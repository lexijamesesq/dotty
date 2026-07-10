# Sample Universe — Reference Card

The estate's one canonical fictional company for public-facing examples. Woodland-tech, deadpan-corporate
register — the humor is playing enterprise product-strategy language completely straight against squirrel
foraging (see Provenance). Every entity below is one-line-defined; extend, don't replace — see `SKILL.md`.

## Org

**Acorndyne** — woodland-tech company building foraging-intelligence software for squirrels. `area/work/acorndyne`.

## Products

| Product | One-liner | Tag |
|---|---|---|
| **CacheTrack** | Per-forager cache-site tracking & retrieval telemetry. | `topic/cachetrack` |
| **GMS** (Grove Management Suite) | Colony/territory-wide resource planning & coordination platform; sub-feature **GMS Delivery Settings**. | `topic/gms` |
| **Ledger** | Colony-wide cached-resource inventory & accounting system; target of the ongoing Cache-to-Ledger migration off the legacy **Hollow** system. | `topic/ledger` |
| **CAP** (Cache Access Platform) | Shared access-control/permissions layer for cache data across colonies. | `topic/cap` |

## Legacy / Retired

**Hollow** — the cache-inventory system Ledger is replacing. Being sunset (EOL slipping FY27-Q2 → FY27-Q4 as migration tooling scope grows to include district-level exports).

## Recurring Meetings

- **Canopy Triad Sync** — weekly (Thursdays), cross-team product-leads sync. Registry key `canopy-triad-sync` (`Wiki/claude/skills/capture-meeting/meeting-registry.sample.json`, vault-root-relative).
- **Hollow Migration Sync** — periodic working sync for the Hollow→Ledger migration effort.

## Governance

**Drey Council** — Acorndyne's cross-team leadership/steering body; approves major timeline and strategy calls (a drey is a squirrel's nest — the leadership "nest").

## People & Roles

- **Hazel Acorn** — Director of Product, Acorndyne; chairs the Drey Council. `person/hazel-acorn`.
- **Chip Chestnut** — Engineering Lead, GMS. `person/chip-chestnut`.

## Adjacent Teams (org shape)

- **Avian Division** — seed-dispersal prediction (adjacent capability, not competing).
- **Chipmunk Squad** — underground cache-mapping, prototype stage.

## Competitors (external)

**AcornTracker**, **NutCache Pro**, **SquirrelSense** — single-signal (location-only) cache trackers; none does multi-signal (soil/competitor/yield) optimization.

## Metrics Register

| Metric | What it measures |
|---|---|
| Retrieval Success Rate | % of caches successfully retrieved by season-end (baseline ~74%, urban ~68%; platform thesis targets >95%). |
| CAP Uptime | % availability of the shared access layer. |
| GMS Delivery Settings Adoption | % of colonies onboarded. |

## Prior Employers (historical)

**Bramblesoft**, **Twig** — two fictional pre-Acorndyne employers, added solely to give `knowledge-contract.md § Part I`'s grandfathered legacy `project/{employer}/*` depth-exception examples (a pre-`area/`-namespace convention) a sample-universe-conformant pair. Not otherwise part of this universe's narrative — distinct from `area/work/pinecone`, which serves the current-employer multi-employer example instead.

## Tag Examples

`area/work/acorndyne` (this universe) · `area/work/pinecone` (a second illustrative employer from `knowledge-contract.md § Part I` — NOT part of this universe, kept distinct for multi-employer tag examples) · `person/hazel-acorn` · `person/chip-chestnut` · `topic/cachetrack` (no hyphen — canon) · `topic/gms` · `topic/ledger` · `topic/cap` · `topic/canopy-triad-sync`.

## Provenance

Derived from, not invented against: `Projects/Incubator/Ideas/sample-foraging-intelligence.md` (competitors,
Avian Division/Chipmunk Squad, retrieval-rate thesis, tone) · `Projects/Incubator/claude/skills/cross-domain/org-taxonomy.sample.md`
(the themed-sample + one-citation pattern) · `Wiki/spec/knowledge-contract.md § Part I` (Acorndyne, Hazel Acorn, Chip Chestnut,
Pinecone as pre-existing illustrative tags) · `Wiki/claude/skills/capture-meeting/meeting-registry.sample.json`
(Canopy Triad Sync, CacheTrack, GMS naming + product-area shape). Ledger, CAP, Hollow, Drey Council, and Hollow
Migration Sync are this skill's extensions — added because reworked files already referenced them in passing
("Cache-to-Ledger migration", "Cache Access Platform strategy") without a canonical definition to anchor to.
Bramblesoft and Twig are a later extension — a Wiki publication PII sweep found two real prior-employer names
grandfathered into `knowledge-contract.md § Part I`'s legacy `project/*` depth-exception examples with no fictional stand-in
to swap to.
