---
name: sample-universe
description: The estate's canonical fictional universe (Acorndyne — a woodland-tech foraging-intelligence company) for public-facing example content. Load before authoring or sanitizing ANY example, worked example, few-shot content, or *.sample.* file bound for a public repo or Wiki publication. Narrative examples draw ONLY from the bundled universe.md, extended coherently — never invented per-file. Triggers on authoring/reviewing public-facing examples, sanitizing real content for publication, or writing *.sample.* files.
---

# /sample-universe

The estate's one canonical fictional universe for public-facing example content — Acorndyne, a
deadpan-serious woodland-tech company applying enterprise product-strategy language to squirrel foraging.
Exists so every public skill, sample file, and worked example draws from ONE consistent fictional company
instead of each file inventing its own lore — the exact failure mode this skill remediates (drifting
product names, mismatched org names, hyphenation inconsistency across files written the same night).

## What This Is

`universe.md` (bundled) is the reference card: the org, its products, recurring meetings, people, a
governance body, metrics, competitors, and legacy systems — everything a rework needs to source a coherent
example. It is a reference card, not a novel — every entity is one-line-defined.

## When To Use

Load this skill whenever authoring or sanitizing:
- A worked example, few-shot example, or `<thinking>` trace in a public dotty/Wiki skill file
- A new `*.sample.*` file
- Real vault/company content being genericized for a public repo

Do NOT load it for private, non-published vault content — the universe protects publication boundaries;
it doesn't replace real content everywhere.

## The Rules

1. **Universe entities only.** Every example company/product/meeting/person name comes from `universe.md`.
   Never invent a name ad hoc, even a "flat" placeholder-sounding one — if `universe.md` doesn't have it,
   extend it (below), don't freelance.
2. **Operator config values are out of scope here.** Real installation-specific values (product names, org
   terms, credentials, issue keys) live in gitignored CLAUDE.md/config and are referenced by config-key or
   `{workspace_root}` placeholder — per `Projects/Incubator/CLAUDE.md` § Decisions Made. This skill only
   supplies the FICTION standing in for narrative/teaching examples; it never touches real config values.
3. **One citation per file.** A file using the universe cites it once (see `org-taxonomy.sample.md`'s
   Worked Example for the precedent phrasing) — not a disclaimer on every example.
4. **Cross-file consistency is load-bearing.** Same entity → same name, same tag, same hyphenation,
   everywhere. A universe entity's tag form (e.g. `topic/cachetrack`, no hyphen) is canon; conform every
   file to it — don't average across files' prior drift.
5. **Commit messages never name the real values being abstracted away** (Incubator's rule, extended to
   this skill's output).

## Extending the Universe

A rework needs an entity `universe.md` doesn't have → add it there first, in its one-line-defined style,
sourced from whatever textual grounding already exists in the file being reworked (prefer reusing a term
the target file already uses over inventing fresh vocabulary) — then use it. An extension never lives only
in the file that needed it.

## What This Skill Does NOT Do

- Does NOT decide whether content needs sanitizing — that's the `/publish` / sample-file
  convention's call.
- Does NOT replace `{workspace_root}` / config-key abstraction for real operator values — narrative
  fiction and config abstraction are different problems, solved by different mechanisms.
- Does NOT own knowledge-contract Part I's real-roster split (`tag-taxonomy-rosters.md` stays the real-roster boundary;
  this universe's people are fiction, not roster entries).

## References

- `universe.md` (bundled) — the canonical reference card.
- `Projects/Incubator/claude/skills/cross-domain/org-taxonomy.sample.md` — the themed-sample + citation
  precedent this skill generalizes.
- `Projects/Incubator/CLAUDE.md` § Decisions Made — the config-key abstraction rule this skill complements
  (fiction vs. config are separate concerns).
- `Projects/Incubator/Ideas/sample-foraging-intelligence.md` — the canonical exemplar this universe's tone
  is calibrated against.
