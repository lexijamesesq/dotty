---
tags:
  - type/knowledge
  - project/alpha
  - status/active
  - topic/testing
updated: 2026-05-22
sources: ["test fixture"]
---
# Rename Candidate Detection

This file exercises the broken-wikilink rename/basename downgrade and the
any-extension existence fix together.

Moved to a sibling folder — [[Retired/moved-target-note]] used to live under
`Retired/` but now lives at `CurrentFolder/moved-target-note.md`. Must
downgrade to a WARNING "moved/renamed candidate" finding, not a flat MEDIUM
missing-target finding.

Versioned rename — [[versioned-doc]] has no exact stem match, but
`versioned-doc-v2.md` exists. Must also downgrade to a WARNING
"moved/renamed candidate" finding.

Existing attachment — [[Attachments/report.pdf]] exists on disk. Non-md
targets that exist must produce NO finding at all.

Genuinely missing — [[totally-fabricated-nonexistent-xyz]] does not exist
anywhere under any name. Must still fire the original MEDIUM broken-wikilink
finding (no false downgrade).
