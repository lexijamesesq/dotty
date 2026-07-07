# Operator Surface Design

The operator and Claude are different kinds of minds sharing one workspace. Claude holds a thousand files at once, runs unattended, applies twenty patches without a typo. The operator knows whether work is actually finished, whether knowledge still matters, and what an interface feels like at 9am. Every surface the operator touches is a translation layer, designed from their experience — never exported from Claude's internal format. Before shipping anything operator-facing, ask: does this assume their mind works like mine?

Four rules follow. Each was learned the hard way; violations read as "built for Claude, handed to a human."

## Meaning is the operator's; metadata is Claude's

If Claude knows what to fix, fix it — that is what linting and general intelligence are for. Never surface the system's own paperwork (tags, frontmatter, provenance, index entries, repointable links) for operator approval. What may reach the operator is only a genuinely-stuck question, carrying three parts: **what this is** (plain content-level language), **why the system is stuck** (the specific fork the evidence can't close), **what the answer will cause** (consequences first; mechanics as a footnote).

**The test:** if the question can't be phrased without vault jargon, it isn't the operator's question. Theirs: "Is this work finished?" "Is this still true?" "Which claim wins?" Not theirs: anything containing a tag name.

## Session boundaries are never task surfaces

Session-start and session-closeout bracket that session's work — fast rituals, not attachment points for unrelated maintenance. A boundary being *reliable* doesn't make it the *right place* for work. Ambient state (counts, debt) goes in the statusline, passive and glanceable. Actual triage/maintenance work runs only through an explicitly invoked skill, when the operator chooses. One signal surface plus one invocation surface — two surfacing mechanisms for the same thing are duplicative and diminish both.

## Skill prose is runtime speech

Everything in a SKILL.md or playbook is candidate speech — the executing model narrates it at the operator. State rules plainly; keep a why-clause only when it aids execution. Design history, dated rulings, and rejection records live in design docs, never in narratable prose — citing the operator their own past decision as precedent is bureaucratic noise.

## Validate at the operating tier

Skills built during frontier-model sessions must work at the model tier that runs them daily (including pinned automation lanes). "Works only on the frontier model" is a defect, not a success. Never nudge the operator's operating-tier sessions up-model during validation — their session testing at the daily tier IS the acceptance test.
