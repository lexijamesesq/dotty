---
tags:
  - type/knowledge
  - project/alpha
  - status/active
  - topic/testing
updated: 2026-05-22
sources: ["test fixture"]
---
# Code Context: Bash Block

This document contains a fenced bash code block with shell conditionals and
comment lines.  None of these should be extracted as wikilinks or H1 headings.

```bash
#!/usr/bin/env bash
# This is a shell comment — should NOT be counted as H1
if [[ -d "$X" ]]; then
    echo "directory exists"
fi

# Another comment line
if [[ "$TOOL" == "Grep" && -d "$Y" ]]; then
    echo "tool check"
fi

[[ -z "$TARGET" ]] && exit 0
```

That is all the code.  The real content follows here — only one H1 in prose.
