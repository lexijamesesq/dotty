# fenced-citation fixture

Worked example — the backtick-wrapped filename below is in-scenario
illustrative content inside a `<thinking>` trace, not a citation to a real
canonical source:

<thinking>
Search: topic/cachetrack surfaces `meeting-canopy-triad-sync-cachetrack.md`
as a same-topic hit, but it's a different destination class.
</thinking>

Fenced code block — same idea, a templated report string, not a citation:

```
Rolling logs:
  - `meeting-canopy-triad-sync-gms.md` -- {N} entries ({date1})
```

Negative control — this citation is outside any block and the file genuinely
does not exist, so it must still be flagged: `definitely-does-not-exist-fixture.md`.
