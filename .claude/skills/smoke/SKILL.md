---
name: smoke
description: >
  On-demand Mac-side configuration health check — makes each of the estate's
  local protection layers (a PreToolUse hook, the lint fixture suite, every
  hook a live settings.json registers) prove it is wired RIGHT NOW, not that
  it was wired the day it shipped. Five probes, grown by regression only —
  each one exists because a real silent-misconfiguration incident bit before
  it existed. Reports only; never fixes. Triggers on "/smoke", "run smoke",
  "smoke test the config", "check the hooks are wired".
---

# /smoke

Domain check for Mac-side configuration health. The estate's protection layers — hooks, the lint gate, registered automation — fail silently: a broken one doesn't error, it stops existing, and nothing distinguishes "this is fine" from "this stopped working three weeks ago" until the next incident proves it. `/smoke` is the check that would have caught each incident that motivated it, runnable again on demand.

## Identity

This skill owns ONE thing: proving five specific local surfaces are wired correctly at the moment it runs. It does not scan for new problems, does not audit the whole harness, and does not fix anything it finds.

- **Mechanical only** — the bundled `smoke.sh` is the entire implementation: read-only, no network, no credentials, no writes. Every probe exercises the real surface (pipes real JSON at the real hook, runs the real fixture suite, parses the real live `settings.json`) — never a re-derivation from memory of what the surface *should* do.
- **Grows by regression, never speculatively.** A probe is added only after a real silent-misconfiguration incident bites. Five probes, five incidents:

| Probe | Proves | Incident that added it |
|---|---|---|
| `hook-tilde-expansion` | `vault-mcp-redirect.sh` still expands a tilde-form `VAULT_ROOT` before the realpath comparison | 2026-06-02 — both vault-aware hooks compared a `realpath`-resolved absolute path against an *unexpanded* tilde in `VAULT_ROOT`, so the `case` match never fired; generic tools silently passed through unblocked on every vault `.md` file until caught |
| `lint-suite` | `lint.py`'s fixture suite still passes | a false-green fixture class plus a python-version drift that changed check behavior between machines — both surfaced only by re-running the suite, never by reading the script |
| `hook-registration-integrity` | every `.sh` hook a live `settings.json` registers still exists and is executable | a stale registered hook — an entry pointing at a path that had moved or lost its executable bit, invisible until the hook silently failed to fire |
| `core-symlink-integrity` | every per-entry symlink the core blueprint slice declares exists, is a symlink, and resolves to its declared target | 2026-07-18 — a dangling agents symlink persisted two months after its target was deleted, and `~/.git` pointed at a tree whose content sat one level down, producing 56 phantom deletions visible to any session under `$HOME` |
| `blueprint-coverage` | every skill directory in dotty's skills tree has a core-blueprint entry in both profiles | 2026-07-31 — wayfinder and prototype shipped in dotty but were never added to `core.json`, so they loaded nowhere until the operator noticed the skill missing globally |

Do not add a sixth probe without a new failure to justify it.

## Intent

**Objective.** Without this skill, "did my hook/settings/lint change actually take" is answered by re-reading the diff and trusting it, at exactly the moment (right after editing config) when a silent break is most likely and least visible. `/smoke` replaces that ad hoc check with one deterministic pass, cheap enough to run habitually.

**Desired outcomes:**
1. Every infrastructure-touching session runs `/smoke` and trusts a clean run without manually re-deriving verification.
2. A regression in any of the protected surfaces is caught by the next `/smoke` run, not by the next incident.
3. The probe set stays exactly as large as real failures justify — no speculative coverage, no untested drift between what's probed and what's registered.

**Health metrics — must NOT degrade.**
- Zero writes, ever — `smoke.sh` reports; a fix path here would blur into the surfaces it's supposed to independently verify.
- Every probe fails loud on staleness before it evaluates health — a probe silently skipping because its target moved is worse than a probe that never existed.
- Exit code is the interface: 0 iff zero FAILs. No downstream consumer should need to parse prose.

**Strategic context.** The Pi side of the estate has Kuma heartbeats and maintenance-run gates watching its always-on processes; the Mac has no always-on process to host an equivalent. `/smoke` is the pull-based answer for the Mac specifically — verification the operator or session runs on demand, not push-based alerting.

**Constraints.**
- **Hard:** no writes, no network, no credential access. `smoke.sh` never fixes a finding.
- **Steering:** cadence is deliberately NOT scheduled. The Mac carries no wall-clock automation by estate ruling (unlike the Pi's cron-driven lanes), so invocation is an operator-initiated convention: run at session-start for any infrastructure-touching session, and after any infrastructure change (a hook edit, a `settings.json` edit, a `lint.py` change). Nothing enforces this — the discipline is the caller's.

**Decision authority.**
- **Autonomous:** running all five probes; reporting PASS/FAIL per probe plus a summary line.
- **Escalate:** every FAIL — `/smoke` never remediates its own findings; the caller reads the detail and edits the broken surface directly.

**Stop rules.**
- `/smoke` only reports. It never edits a hook, a `settings.json`, or `lint.py` — the exit contract (0 iff zero FAILs) is the entire interface a caller needs.
- A probe's staleness check fails → that probe reports FAIL naming what moved. Never silently skip a probe whose target can't be found.

## Navigation

| Operation | Input | Output | How |
|---|---|---|---|
| **run** | none | One `PASS\|FAIL <probe-name>: <detail>` line per probe, then a summary line; exit 0 iff zero FAILs | `bash <skill-base-dir>/smoke.sh` |

## What this skill does NOT do

- Does NOT fix anything it finds — report only, same discipline as `/lint-knowledge` and `/house-qa`.
- Does NOT run on any schedule or session boundary automatically — invocation is always explicit, per the cadence convention above.
- Does NOT replace `/lint-knowledge`'s periodic content-health pass — `lint-suite` here only proves the *test suite* still passes, not that the corpus itself is clean; run `/lint-knowledge` separately for that.
- Does NOT probe MCP servers or plugins — of the blueprint's domain this skill checks only the core slice's wiring (symlink integrity, skill coverage; probes 4–5); everything else `/system-blueprint` governs stays `/system-blueprint`'s.

## References

- `smoke.sh` — the entire probe implementation; read it before trusting a change to this skill.
- `../../hooks/vault-mcp-redirect.sh` — probe 1's target.
- `../lint-knowledge/tests/run_tests.py` — probe 2's target.
- `~/.claude-personal/settings.json`, `~/.claude-professional/settings.json` — probe 3's targets.
- `~/bin/dotty-private/.claude/blueprint/core.json` — probes 4 and 5's declared state; probe 5 also walks dotty's skills tree.
