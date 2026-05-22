---
tags:
  - type/knowledge
  - project/alpha
  - status/active
  - topic/testing
updated: 2026-05-22
sources: ["test fixture"]
---
# Code Context: Bare Path In Code Block

This file shows a cross-project bare path reference inside a code block.
It should NOT produce a cross-project-bare-path finding.

```bash
# Example showing how a cross-project path might appear in shell code
cp Projects/beta/Knowledge/some-note.md /tmp/
```

The path above is inside a code block and should not be flagged.
