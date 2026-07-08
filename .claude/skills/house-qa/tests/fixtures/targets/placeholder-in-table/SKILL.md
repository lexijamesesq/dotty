---
name: placeholder-in-table-fixture
description: Fixture — argument-form placeholders in tables must not read as broken citations; a real broken citation in the same file must still flag.
argument-hint: [idea-name]
---

# /placeholder-in-table-fixture

Usage: `/placeholder-in-table-fixture [idea-name]`

## Arguments

| Argument form | Resolution |
|---|---|
| `idea-name` | Resolve to the idea file by name |
| `idea-name.md` | Strip the extension, resolve as above |

The table's second row is the argument form with an extension — the house
convention this fixture pins. `[idea-name]` is declared in the frontmatter
argument-hint and the usage line above, so the citation check must treat
`idea-name.md` as a placeholder, not a missing source.

Per `genuinely-missing-source.md`, this sentence carries a real broken
citation the check must still flag — placeholder discrimination must not
mask actual breakage.
