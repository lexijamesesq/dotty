# README House Style

The canonical spine, strings, and register for project READMEs in this estate. Consumers — `/github-readme`, `/house-qa`, any session authoring a README — reference this file. Nothing here is restated elsewhere; amend here, nowhere else.

Derived from three exemplars: Metrics, Home Assistant, Incubator. Wiki and dotty are governed by this file, not sources for it.

Those exemplars live in the operator's private workspace and are often unreachable. When they are, this file is sufficient on its own — the spine, the shared patterns, and the fixed strings below are the whole standard. Never guess at what an unreachable exemplar might have done.

## The spine

Project READMEs carry these sections, in this order. `###` subsections nest under the `##` above them.

| # | Section | Form |
|---|---------|------|
| 1 | *(lede — no heading)* | One paragraph. The first thing a reader sees. |
| 2 | `## Installation` | Clone, `mv claude .claude`, `cp CLAUDE.sample.md CLAUDE.md` |
| 3 | `### Required configuration` | Table: `Field \| Location \| What to set` |
| 4 | `### Optional configuration` | Same schema. Omit if the project has none. |
| 5 | `### Dependencies` | Bullets: **bolded name** — what breaks without it. Omit if none. |
| 6 | `## What's Included` | Grouped `###` subsections, each holding one table. |
| 7 | `## Configuration` | The You-configure / Skills-handle split. |
| 8 | `## Usage` | One `###` per workflow or phase, holding one or more fenced invocations and one to three sentences each. Order varies. |
| 9 | `## How It Works` | Three to four paragraphs of architecture. |
| 10 | `## Customization` | Bullets: `**Different X:**` / `**Without Y:**`, opened by a framing sentence where the repo ships domain-specific assumptions |
| 11 | `## Security` | The strings below, plus repo-specific prose. |
| 12 | `## License` | The string below. |

## Fixed strings

Reproduce these character-for-character. They are the corpus fingerprint — a paraphrase is a defect.

**Installation** opens with this line, in all three exemplars:

```
Clone the repo, then set up the Claude Code directory:
```

Then the `mv claude .claude` fence, then a line of the form `Copy the sample config and fill in your values:` — pluralised when there is more than one sample file, and extended to `...fill in your paths and voice:` only when one of them is a persona or voice document. The count is not the trigger; the content is.

**Configuration**'s invariant is the **You configure:** / **Skills handle:** split — that survives everywhere. The opening and closing sentences below are the default form, used wherever a repo's configuration lives in one file:

```
The system separates what you configure from what skills handle.
```

```
See `CLAUDE.sample.md` for the full configuration contract with placeholder values.
```

A repo whose configuration is spread across several files may replace both sentences with its own — Metrics opens `Skills read configuration at runtime from three sources:` and closes by naming all three. Adaptation is permitted, never required: the corpus holds a two-sample project that keeps the standard lines and a three-sample project that abandons them. Only the split must survive.

**Security** always opens with:

```
Review skills before installing. They load into Claude's context and execute with your permissions.
```

and always carries this sentence:

```
Audit the contents of `claude/skills/` before use.
```

The audit clause names **every executable surface the repo ships**. Append `` and `claude/agents/` `` when it ships agents, and extend it the same way for any other directory that executes — hooks, scripts. A repo that ships an executable surface and leaves it out of the clause is under-declaring, which is the failure the clause exists to prevent. Where a repo ships `.claude/` directly rather than a `claude/` directory renamed at install, use the dotted form.

Repo-specific security prose sits either between the two fixed sentences — directly after `permissions.` — or as a paragraph after the audit sentence. Both forms are in the corpus.

**License** is exactly:

```
MIT. See [LICENSE](LICENSE).
```

## The lede

One paragraph, roughly 30–80 words, before any heading. The corpus holds two forms, and both are correct:

- **The formula** — `A Claude Code {system|pipeline|project} that {what it does}`, em-dashed clauses enumerating what makes it distinctive, closing on placement or `orchestrated through Claude Code skills`. Used by the consumer projects.
- **The plain declarative** — names what the repo holds and who it serves, in the author's own voice. Used by the infrastructure repos, where first person is the honest register for a personal dotfiles repo.

It states the system's shape once. Nothing downstream repeats it.

**A lede that already exists is authored prose. Preserve it verbatim.** Rewriting an operator's lede to fit the formula is a defect, not conformance.

## Length

The exemplars run 121–220 lines; their median is 129. Target the median, and cut before adding.

Length is not a bright line — it scales with how many artifacts the repo ships. Incubator reaches 220 lines carrying ~25 artifacts. A repo with a larger inventory may run longer, provided every line earns its place; a repo with three skills that runs to 200 lines has a padding problem, not a size one.

## What's Included

**Grouping follows inventory size, not preference.** A repo shipping a handful of artifacts groups them by kind — `### Skills`, `### Supporting files` — and needs nothing more. Once the inventory is large enough that "kind" stops being the axis a reader navigates by, group by **function** instead: `### Session orchestration`, `### Knowledge layer`, `### Enrichment`. Non-invocable files may still take a kind group at the end.

**Invocable artifacts carry the slash in their name** — `/publish`, `/refine-seed`. The name then carries the invocation, which is why no README in this corpus has a Trigger column. Never add a column whose value is derivable from another column.

**A group gets an intro sentence only where its heading does not already say when to reach for it.** In the largest exemplar, three of eight groups have one. An intro that restates its heading is filler.

## Table schemas

| Context | Columns |
|---------|---------|
| `What's Included`, small inventory of one kind | `Skill \| What it does` |
| `What's Included`, large or mixed inventory | `Artifact \| Type \| What it does` |
| `What's Included`, non-invocable files | `File \| What it does`, or the kind's own noun (`Rule \| What it enforces`) |
| `What's Included`, items with their own README | `Skill \| What it does \| Details` — the `Details` cell links to it |
| `Required` / `Optional configuration` | `Field \| Location \| What to set` |

Where the `Type` column appears across **more than one row**, its values must **vary** — `Skill`, `Skill + Agent`, `Agent`, `Contract`. A multi-row `Type` column reading `Skill` on every row is a second copy of its heading; drop it and use the two-column form. A single-row group may keep `Type` to stay aligned with its siblings, as the largest exemplar does.

Every `What it does` cell says what the artifact **does when invoked**, not what it is. "Fetches NPS responses and outputs CSV," never "NPS fetching script."

## Shared patterns

A pattern that appears in more than one README is rendered **one way**. Divergence here is the most visible defect in the corpus, because a reader comparing two repos sees the same idea wearing two costumes.

| Pattern | Canonical rendering |
|---------|---------------------|
| `Location` cell, setting inside a file's section | `CLAUDE.md > Configuration` — unbackticked, spaced `>` |
| `Location` cell, the file itself is the setting | `persona.md` — backticked filename, no section |
| `Location` cell, a place rather than a file | `Project root`, `Scripts directory` |
| Dash | Em dash, spaced: `word — word`. Never `--`. |
| Optional dependency, in a bullet | `**Name** *(optional)* — what it is for.` |
| Optional section, in a heading | `### Research database (optional)` |
| Dependency bullet | `**Name** — what it is for. Without it, <consequence>.` |
| Installation cadence | A prose line, then a fence; a prose line, then a fence. Consumer projects open `Clone the repo, then set up the Claude Code directory:`. Infrastructure repos parallel the cadence, not the words. |

## What may vary, and on what

Consistency is the default; these are the only axes that flex, each with the observable property that decides them. Anything not on this list does not vary.

| Axis | Varies with |
|------|-------------|
| Lede voice: first person or third | **Whether installation is bound to the author's own machine and identity.** dotty's install wires the author's SSH keys, 1Password, and private companion repo, so it says "I". Home Assistant and Incubator are equally the author's, but install cleanly for anyone, so they say nothing of the sort. |
| `What's Included` grouped by kind or by function | **Inventory size.** Few artifacts of one or two kinds: group by kind. Large enough that kind stops being the navigating axis: group by function. |
| Two-column table or `Type` column | **Whether `Type` would vary.** A `Type` column reading `Skill` on every row is a second copy of its heading. |
| Group intro sentences | **Whether the heading already says when to reach for the group.** In the largest exemplar, three of eight have one. |
| `Customization` framing sentence | **Whether the repo ships domain-specific assumptions** worth naming before the bullets. |
| A section is present at all | **Whether the repo has that kind of state.** A repo with no runnable code needs no `Usage`; a repo with no options needs no `Configuration`. |
| What `Installation` must state | **What the reader needs before the first command runs.** A system-setup repo names its prerequisites at the install step, where the command that needs them lives — not in a list further down. |

A shared pattern is a **cadence to match, never a stamp that displaces content.** Normalising a repo's phrasing must never delete a fact that repo's reader needs. When the two conflict, the fact wins and the pattern bends.

Two rules bound the whole thing, and neither flexes. **Never add a column whose value is derivable from an adjacent column** — no survey of well-regarded READMEs contains a name column beside an invocation column, because a slash-named artifact already carries its invocation. And **an inventory that outgrows the page gets delegated, not widened** — real projects push large, high-churn inventories to a manual, a directory, or a generated file rather than growing the table.

## Systematic omissions

These are decisions, not oversights. Reproducing them is conformance.

No H1 title — GitHub renders the repo name already. No badges. No table of contents. No emoji. No `Status`, `Roadmap`, `Contributing`, `Testing`, or `Changelog` section. No ticket IDs and no absolute local paths. Generated sections stay in the third person; the lede may not — see § The lede. If the project is genuinely unfinished, that goes in one clause of the lede, never a dedicated section.

## Rules earned from real failures

Each of these exists because a shipped README broke it.

1. **`How It Works` adds; it never paraphrases the lede.** If a reader who read the lede learns nothing new, the section is dead weight. Give it the architecture — layers, control flow, the loop, the non-obvious constraint.
2. **Notation follows the canonical source.** When a README cites a spec, it reproduces that spec's notation exactly — `mode × trust × kind`, not an ASCII transliteration. A restatement that drifts from its source is worse than a pointer.
3. **`What's Included` lists only what the repo ships.** Skills living in a companion repo belong under their own heading that names them as external.
4. **Every `Customization` bullet carries a concrete path or a concrete action.** "See the other repo for details" is a redirect, not a customization.

## Regeneration boundary

A tool regenerating a README may rebuild the **tables** inside `What's Included`, the **fenced invocations** inside `Usage`, the two lists inside `Configuration`, and the **`Required` / `Optional configuration` tables** — even though the `Installation` prose around them is preserved. All of these derive mechanically from current artifact state.

Everything else is authored, and is carried through verbatim: the lede, `Installation`, `How It Works`, `Customization`, `Security`, `License`, **`Configuration`'s opening and closing sentences** — which a repo may legitimately have adapted to name its own sample files — anything the operator added, and every prose paragraph sitting inside those three generated sections.

The `###` grouping headings inside `What's Included` are authored structure, not generated output. Preserve the headings and the grouping they express; rebuild only the rows within each. Deciding that enrichment agents and core-pipeline skills belong in separate tables is an editorial judgment, and collapsing them loses it.

Regeneration granularity is the table and the fenced block, never the whole section. A note the operator wrote under `## Usage` survives.

Two consequences a regenerating tool must honour. A generated section the spine requires and artifact state justifies is **created** when missing — a heading is structure, not authored prose. And a preserved section is **never edited to satisfy a fixed string**; the gap is reported, and the operator fixes it.
