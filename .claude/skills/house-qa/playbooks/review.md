# Playbook: review

The judgment pass — a fresh-context critic grades an artifact against its class exemplars, criticisms weighted over confirmations. Run after `check` (mechanical), before any operator-facing ship decision.

## Input

```yaml
targets: [path, ...]        # one or more artifact files
class: skill-md | playbook | readme | script | custom
exemplars: [path, ...]      # the class's real corpus instances — ground truth, not this playbook's prose
check_findings: {...}       # optional — qa.py's --json output, if `check` already ran
```

## Protocol

1. **Fresh context.** Run this in a context that has not authored or edited the target — self-evaluation rationalizes flaws (dispatch-and-delegation.md: you cannot see your own work the way a stranger does). If the calling session wrote the artifact, hand off to a subagent instead of grading in-session.

2. **Ground-truth ordering** (corpus-conformance-methodology.md § Ground-truth ordering) — read, in this order, before forming any opinion:
   - The platform/vendor floor (Claude Code skill-authoring guidance), if the artifact class has one.
   - The estate's methodology docs for this class (composable-skills-methodology.md for skills/playbooks; `../github-readme/house-style.md` for READMEs — the canonical spine, fixed strings, and systematic omissions).
   - The class exemplars themselves — read the actual files, not a description of them. "I read *about* the exemplar" doesn't count.
   - Only then, judgment.

3. **Measure the exemplars before judging the target.** For each exemplar: section order, register, what's systematically omitted, how it handles the hard parts (examples, cross-references, abstraction). This derives the standard the target is graded against — don't grade from memory of what a "good skill" looks like in general.

4. **Read the target artifact whole**, then assess four axes (the shape proven in the 2026-07-07 skill-quality audit):
   - **Construction** — does the section shape/order match the exemplars? A navigator with real mutually-exclusive branches and no playbook split is a direct violation (composable-skills-methodology.md's progressive-disclosure rule).
   - **Description** — does frontmatter density/register match the exemplars?
   - **Overcomplication** — for every section past the exemplar median, does the excess earn its place (a named failure mode, genuine combinatorial complexity) or is it restatement / padding / an always-loaded but rarely-used branch? Cite the specific excess; don't assert "too long" unsupported.
   - **Consistency** — does any judgment table, vocabulary, or worked example duplicate a canonical source declared elsewhere in the corpus? A second maintained copy of one judgment table is the exact failure mode composable-skills-methodology.md's whole architecture exists to prevent.

5. **Criticisms over confirmations.** Default to finding the defect; a clean KEEP verdict must survive actively looking for a violation on all four axes, not just failing to notice one. Write the criticism first, the confirmation (if any) second.

6. **Verdict.** One of:
   - **KEEP** — matches exemplar shape and density; no changes.
   - **SIMPLIFY** — right shape, wrong size or a minor structural deviation (one missing playbook extraction, an oversized table). Name the specific extraction/cut and a target size, stated as a line count against the exemplar median (e.g. "~110-130 lines, from 261").
   - **REWORK** — wrong shape (no playbook split despite clean mutually-exclusive branches; duplicated canonical judgment tables; narrates its own production history). Name every structural change, not just the worst one.

7. **Trace every verdict** to a specific exemplar file + line range, or a specific methodology clause. A verdict with no named source is not admissible — rewrite it until it cites one.

## Output

```yaml
verdict: KEEP | SIMPLIFY | REWORK
per_axis:
  construction: {finding, exemplar_or_clause_cited}
  description: {finding, exemplar_or_clause_cited}
  overcomplication: {finding, exemplar_or_clause_cited}
  consistency: {finding, exemplar_or_clause_cited}
target_size: "<n> lines (from <current>)"   # only for SIMPLIFY / REWORK
recommended_changes: [str, ...]              # concrete, ordered, each traced
```

## Failure modes

- **Grading from memory instead of the actual exemplar files** — the single most common failure; always re-read the exemplars in this run, even if "recently reviewed."
- **Confirmation-first** — writing "looks fine" before actively hunting for a violation. Reverse the order.
- **Untraced verdicts** — "this feels overcomplicated" without naming what specifically is excess and what it should look like instead.
- **Grading correctness instead of belonging** — a functionally correct artifact can still get REWORK; that's the point of this being a second, independent axis (corpus-conformance-methodology.md's opening principle).

## What this playbook does NOT do

- Does NOT run the mechanical checks — that's `../qa.py` / the `check` operation; run it first and hand its findings in as context, don't re-derive them by eye.
- Does NOT fix anything — the verdict and recommended changes are a report; the caller (or a separate implementation pass) applies them.
- Does NOT invent a fifth verdict tier or a numeric score — the three-way KEEP/SIMPLIFY/REWORK vocabulary is the whole surface, proven across nine artifacts in the 2026-07-07 audit.
