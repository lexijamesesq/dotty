---
name: research
description: >
  Research discipline for exploratory search, purchase research, and
  primary-source investigation. Carries search methodology (mode detection,
  funnel stages, validation, retrieval tactics) and routes to playbooks by
  search type. Triggers on research tasks, shopping, purchase decisions,
  "find me", "what should I buy", "research this", exploratory searches,
  evaluating products/options to inform a decision, when the user shares
  a link/article/video asking "what do you think of this" or "analyze this,"
  or invoked as "/research ticket <issue-id>" to resolve a research ticket.
---

# /research

Research discipline that prevents the two root failures: reasoning before researching (building frameworks about a solution space you haven't examined) and asserting before validating (presenting facts from parametric knowledge or stale results without live verification).

## Core Discipline

**Discover before you deliberate.** Landscape data first. Do not build evaluation frameworks, comparison matrices, or recommendation structures before pulling real data. Reasoning on an unexamined solution space is speculation.

**Let the user's input prune the search before you run it.** Extract hard constraints from their own words — format, tool, ingredient, budget, ecosystem. A stated constraint eliminates options before you search, not after. When you deviate from a stated preference, name why the deviation is forced.

**Every factual claim is a hypothesis until verified at the point of presentation** — including claims from earlier in this session. Product names, prices, formulations, and availability drift. Fetch and verify before asserting, regardless of when you last checked.

## Mode Detection

Before constructing any query, classify the task:

| Signal | Exploratory | Lookup |
|---|---|---|
| User knows exactly what they want | No | Yes |
| User knows domain vocabulary | No | Yes |
| Shopping, researching, or discovering | Yes | No |
| Confirming a known fact or finding a specific item | No | Yes |

**Exploratory:** broad category queries to acquire domain vocabulary. Do not use precise terms you haven't validated through results. Narrow only after the funnel produces specific terms.

**Lookup:** precise queries with specific terms. Go directly to the target.

## The Funnel

### Stage 1: Landscape Scan
Category-level queries. Acquire the domain's taxonomy and axes of differentiation before applying them.

### Stage 2: Vocabulary Acquisition
Extract terms and facets from Stage 1. Transform user language into domain language. Map the axes that differentiate options in this space.

### Stage 3: Guided Narrowing
Use terms discovered through the funnel, not assumed at start. Combine 2-3 facets per query. Follow information scent — new vocabulary in results warrants investigation before committing to a path. When results are sparse, expand (broader terms, synonyms, adjacent categories). When too broad, add a facet.

### Stage 4: Convergence
Targeted lookups are now appropriate. Decompose verification into separate targeted queries rather than one broad sweep. Verify against independent sources, not marketing copy. What convergence looks like varies by search type — the active playbook defines it.

**The session is the unit of work, not the query.** Each result informs the next. Evolving queries across turns is correct behavior. Static one-shot queries are the primary failure mode in research — adaptive multi-turn refinement is what produces good results.

## Retrieval Tactics

**Fetch first, browser when fetch fails.** API-based retrieval (web search, web fetch) is fast and sufficient for most content. Fall back to browser automation when:
- A site returns 403 or minimal content (anti-bot protection)
- Content is JavaScript-rendered and fetch returns only the shell
- Results require scrolling, pagination, or interaction to fully load

**A fetch failure is not "can't verify."** It means the retrieval method is wrong, not that the information is unavailable. Try a different tool before giving up.

**Manage context window cost.** Search results consume tokens. Excessive unfiltered searching degrades quality by saturating context. Decompose into targeted subqueries rather than broad sweeps. Use domain filtering when the authoritative sources are known.

## Domain Context

Before searching, check the vault for existing domain knowledge. Context pages and domain knowledge docs carry prior research, hard constraints, calibrated preferences, and validated methodology. Loading domain context BEFORE searching prevents rediscovering established ground and violating constraints already established.

## Navigation

| Search type | Signal | Playbook |
|---|---|---|
| Purchase research | Shopping, buying, comparing products, "which one should I get" | `playbooks/purchase.md` |
| Exploratory research | Learning a domain, informing a decision, understanding options | `playbooks/exploratory.md` |
| Primary-source investigation | Analyzing a derivative (video, blog, thread) about someone else's work | `playbooks/primary-source.md` |
| Ticket resolution | Invoked `/research ticket <issue-id>` — a delegate resolving a map's research ticket | `playbooks/ticket.md` |

**Lookup** tasks (user knows the exact item and vocabulary) need no playbook — apply core discipline directly with precise queries.

For any playbook-routed task, load the matching playbook before proceeding. If the choice between purchase and exploratory is ambiguous, default to exploratory — it's the safer starting point.

## Anti-Patterns

**"No results" ≠ "no options exist."** A sparse or empty search result is a signal about your query or retrieval method, not about reality. Before concluding nothing exists: broaden the query, try adjacent vocabulary, switch retrieval tools, check a different source. Treat empty results as feedback on the search, not on the solution space.

**Never abandon the medium.** When online research fails to produce candidates, the fix is a better search method — not suggesting the user shop in person, call a store, or ask a human expert. Failure to surface candidates is a method failure. Fix the method.

**Don't reason from parametric knowledge as ground truth.** Training data is a starting hypothesis, not a verified source. Product details, availability, pricing, and formulations from training data are stale by definition. Use parametric knowledge to construct search queries, not to answer questions.

**Don't build frameworks before looking.** Comparison matrices, evaluation rubrics, and decision frameworks constructed before examining the solution space encode assumptions about what the axes of differentiation are. The landscape scan discovers these; premature frameworks lock in wrong ones.

## What This Skill Is NOT

- Not a heavy multi-agent workflow for exhaustive cited reports — this skill is single-session research discipline.
- Not a substitute for domain-specific methodology docs in the vault. Those carry domain expertise (what to look for, how to evaluate quality in a specific domain); this skill carries search discipline (how to search, when to validate, how to handle retrieval failures).
