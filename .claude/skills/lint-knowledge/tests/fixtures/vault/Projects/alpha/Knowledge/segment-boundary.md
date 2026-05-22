---
tags:
  - type/knowledge
  - project/alpha
  - status/active
  - topic/testing
updated: 2026-05-22
sources: ["test fixture"]
---
# Segment Boundary Wikilink

This file uses a bare wikilink [[note]] where "note" is a substring-suffix of
"subfolder-note" but is NOT the stem of any vault file. The fix must NOT match
"subfolder-note.md" for target "note" — segment boundary means exact stem equality
for bare names. This MUST produce a HIGH broken-wikilink finding.
