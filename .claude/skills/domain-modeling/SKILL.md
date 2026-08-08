---
name: domain-modeling
description: >
  Build and sharpen a project's domain model — pin down terminology,
  challenge fuzzy language, record architectural decisions. Works for
  engineering, strategy, research, and design domains.
---

# Domain Modeling

<!-- Adapted from Matt Pocock's domain-modeling skill (MIT): https://github.com/mattpocock/skills. Estate mutation: vault-native knowledge docs replace repo-level CONTEXT.md; cross-reference generalized beyond code. -->

Actively build and sharpen the project's domain model as you design. This is the *active* discipline — challenging terms, inventing edge-case scenarios, and writing the glossary and decisions down the moment they crystallise. (Merely *reading* a domain glossary for vocabulary is not this skill — that's a one-line habit any skill can do. This skill is for when you're changing the model, not just consuming it.)

## File structure

Domain glossaries and ADRs are knowledge docs in the project's Knowledge/ directory, filed under the structural contract (tags, frontmatter, index).

Most projects have a single domain context — one glossary doc:

```
Projects/<project>/Knowledge/
├── domain-glossary.md
└── ...
```

If a project spans multiple bounded contexts, a `domain-context-map.md` doc lists them and their relationships. Each context gets its own glossary doc:

```
Projects/<project>/Knowledge/
├── domain-context-map.md
├── ordering-glossary.md
├── billing-glossary.md
└── ...
```

Create files lazily — only when you have something to write. If no glossary exists, create one when the first term is resolved.

## During the session

### Challenge against the glossary

When the user uses a term that conflicts with the existing language in the domain glossary, call it out immediately. "Your glossary defines 'cancellation' as X, but you seem to mean Y — which is it?"

### Sharpen fuzzy language

When the user uses vague or overloaded terms, propose a precise canonical term. "You're saying 'account' — do you mean the Customer or the User? Those are different things."

### Discuss concrete scenarios

When domain relationships are being discussed, stress-test them with specific scenarios. Invent scenarios that probe edge cases and force the user to be precise about the boundaries between concepts.

### Cross-reference with existing knowledge

When the user states how something works, check whether the existing record agrees. For engineering work, check the code. For strategy, research, or design, check the vault's existing knowledge docs and wiki. If you find a contradiction, surface it: "Your glossary says X, but the knowledge doc on this topic says Y — which is current?"

### Update the glossary inline

When a term is resolved, update the glossary right there. Don't batch these up — capture them as they happen. Each entry is three parts: the **term** (bolded), a one-or-two-sentence **definition** (what it IS, not what it does), and an **_Avoid_** list of synonyms ruled out. The glossary itself is a knowledge doc in the project's Knowledge/ directory, filed under the structural contract.

The glossary should be totally devoid of implementation details. Do not treat it as a spec, a scratch pad, or a repository for implementation decisions. It is a glossary and nothing else.

### Offer ADRs sparingly

Only offer to create an ADR when all three are true:

1. **Hard to reverse** — the cost of changing your mind later is meaningful
2. **Surprising without context** — a future reader will wonder "why did they do it this way?"
3. **The result of a real trade-off** — there were genuine alternatives and you picked one for specific reasons

If any of the three is missing, skip the ADR. Decision records file through the project's Knowledge/ directory under the structural contract; the gatekeeper handles disposition.
