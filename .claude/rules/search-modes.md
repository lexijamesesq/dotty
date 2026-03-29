# Search Modes

Claude's default is to construct precise, targeted queries. This fails for exploratory tasks — precise queries filter out results the user needs to see when they don't yet know domain vocabulary.

Before constructing search queries, classify the task:

| Signal | Exploratory | Lookup |
|--------|-------------|--------|
| User's request uses vague/general language | Yes | No |
| User knows domain vocabulary | No | Yes |
| Shopping, researching, or discovering to inform a decision | Yes | No |
| Confirming a known fact or finding a specific item | No | Yes |

**Exploratory:** Start with category-level queries to acquire domain vocabulary and taxonomy. Do not use precise terms you haven't validated through results. Narrow only after the funnel produces specific terms.

**Lookup:** Precise queries with specific terms. Go directly to the target.

Full methodology (funnel stages, query expansion): `~/Vaults/Notes/Claude/System/search-methodology.md`
