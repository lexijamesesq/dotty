---
tags:
  - type/knowledge
  - area/health
  - status/active
  - topic/fitness
updated: 2026-07-10
sources:
  - "test fixture"
  - "AI research 07-10-2026"
  - "user-stated"
---
# Invalid Sources Values

Two of the three `sources` elements do not match a Provenance vocabulary shape (`"test fixture"` matches none; `"AI research 07-10-2026"` has the wrong date format). Fixture for the `invalid-sources-value` check — filing mode only. Expect two HIGH `invalid-sources-value` findings under `--filing`, and none under periodic mode.
