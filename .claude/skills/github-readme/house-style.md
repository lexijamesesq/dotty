# README House Style

The canonical spine, strings, and register for project READMEs in this estate. Consumers — `/github-readme`, `/house-qa`, any session authoring a README — reference this file. Nothing here is restated elsewhere; amend here, nowhere else.

Derived from four exemplars: Metrics, Home Assistant, Incubator, Wiki.

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
| 10 | `## Customization` | Bullets: `**Different X:**` / `**Without Y:**` |
| 11 | `## Security` | The strings below, plus repo-specific prose. |
| 12 | `## License` | The string below. |

## Fixed strings

Reproduce these character-for-character. They are the corpus fingerprint — a paraphrase is a defect.

**Installation** opens with this line, in all four exemplars:

```
Clone the repo, then set up the Claude Code directory:
```

Then the `mv claude .claude` fence, then a line of the form `Copy the sample config and fill in your values:` — pluralised, and extended (`...fill in your paths and voice:`) when the project ships more than one sample file — then the `cp` fence.

**Configuration**'s invariant is the **You configure:** / **Skills handle:** split. It opens and closes verbatim:

```
The system separates what you configure from what skills handle.
```

```
See `CLAUDE.sample.md` for the full configuration contract with placeholder values.
```

A project whose configuration contract spans several sample files may adapt both lines to name them. Adaptation is permitted, never required — the corpus holds a two-sample project that keeps the standard lines and a three-sample project that adapts them. The split is what must survive either way.

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

One paragraph, roughly 45–80 words, before any heading. It opens `A Claude Code {system|pipeline|project} that {what it does}`, uses em-dashed clauses to enumerate what makes it distinctive, and closes on placement — who it is for, or `orchestrated through Claude Code skills`.

It states the system's shape once. Nothing downstream repeats it.

## Length

The corpus runs 121–220 lines; the median is ~131. Target the median, never exceed the longest instance, and cut before adding.

## Table schemas

| Context | Columns |
|---------|---------|
| `What's Included`, mixed artifact kinds | `Artifact \| Type \| What it does` |
| `What's Included`, one kind | `Skill \| What it does` |
| `Required` / `Optional configuration` | `Field \| Location \| What to set` |

Every `What it does` cell says what the artifact **does when invoked**, not what it is. "Fetches NPS responses and outputs CSV," never "NPS fetching script."

## Systematic omissions

These are decisions, not oversights. Reproducing them is conformance.

No H1 title — GitHub renders the repo name already. No badges. No table of contents. No emoji. No `Status`, `Roadmap`, `Contributing`, `Testing`, or `Changelog` section. No ticket IDs, absolute local paths, or first-person voice. If the project is genuinely unfinished, that goes in one clause of the lede, never a dedicated section.

## Rules earned from real failures

Each of these exists because a shipped README broke it.

1. **`How It Works` adds; it never paraphrases the lede.** If a reader who read the lede learns nothing new, the section is dead weight. Give it the architecture — layers, control flow, the loop, the non-obvious constraint.
2. **Notation follows the canonical source.** When a README cites a spec, it reproduces that spec's notation exactly — `mode × trust × kind`, not an ASCII transliteration. A restatement that drifts from its source is worse than a pointer.
3. **`What's Included` lists only what the repo ships.** Skills living in a companion repo belong under their own heading that names them as external.
4. **Every `Customization` bullet carries a concrete path or a concrete action.** "See the other repo for details" is a redirect, not a customization.

## Regeneration boundary

A tool regenerating a README may rebuild the **tables** inside `What's Included`, the **fenced invocations** inside `Usage`, and the two lists inside `Configuration`. These derive mechanically from current artifact state.

Everything else is authored, and is carried through verbatim: the lede, `Installation`, `How It Works`, `Customization`, `Security`, `License`, anything the operator added — **and every prose paragraph sitting inside those three generated sections**.

The `###` grouping headings inside `What's Included` are authored structure, not generated output. Preserve the headings and the grouping they express; rebuild only the rows within each. Deciding that enrichment agents and core-pipeline skills belong in separate tables is an editorial judgment, and collapsing them loses it.

Regeneration granularity is the table and the fenced block, never the whole section. A note the operator wrote under `## Usage` survives.
