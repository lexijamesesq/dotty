# Playbook: knowledge-intent

Step 2 (knowledge branch) + Step 3 — package a knowledge-intent capture as candidates, hand off to the gatekeeper, and relay its report. wiki-intake does NOT file knowledge directly.

## Input

```yaml
content: <string>      # the capture, classified as `knowledge`
```

## Protocol

1. **Package the capture** as one or more typed candidates:

   | Field | Derivation |
   |---|---|
   | `content` | The capture text, enriched to be self-contained — resolve pronouns and implicit references from the invocation context before packaging |
   | `kind` | `durable-knowledge` — a proposal; the gatekeeper may re-grade |
   | `source_attribution` | Human-readable origin, e.g. "wiki-intake {date} (router delivery)" or "wiki-intake {date} (operator paste)" |
   | `provenance` | `structural-contract` › Provenance vocabulary: `inbox-capture`, the original URL, or `user-stated` |
   | `scope_hint` | Proposed `project/*` or `area/*` — a hint, not authoritative; the gatekeeper resolves the destination |
   | `topic_hints` | Proposed `topic/*` values (collapse-bias: prefer existing terms over near-synonyms) |
   | `trust` | `registered` for operator-authored or router-delivered content; `unregistered` for pasted third-party or forwarded content |
   | `mode` | `interactive` — wiki-intake is an operator-present surface |
   | `content_hash` | Hash of `content` (idempotency key) |

   One capture may yield multiple candidates (e.g., two distinct findings) — split at packaging if needed; the gatekeeper never splits a candidate.

2. **Invoke** `/knowledge-integration assess candidates` with the candidate list. It owns the coherence assessment (dimensions and thresholds per its bundled `calibration-surface.md` — cited there, not reinvented here), destination resolution, filing (full `structural-contract` envelope per `handoff-contracts` §1), duplicate scan, and filing-validator invocation. It returns per-candidate dispositions — file (with target path), queue, surface, or discard, each with reasons.

3. **Confirm the report:**
   - **Completeness check** — every candidate handed over has exactly one disposition. A candidate with no disposition is a lost capture; re-invoke or halt and report.
   - **Relay the report** — filed items with paths; queued items with the queue-item path and reasons; discards with reasons.
   - **Surface, don't resolve** — if the gatekeeper surfaced a conflict, an ambiguity, or an unregistered-trust hold, present it to the operator. Do not resolve it unilaterally.

## Output

```yaml
candidates_submitted: <int>
dispositions: [ { content_hash, disposition: file|queue|discard, target, reasons[] } ]
```

## What this playbook does NOT do

- Does NOT judge coherence, resolve destinations, or file content itself — all gatekeeper-owned.
- Does NOT re-run duplicate scans, tag validation, or filing-validator — those run behind the gatekeeper.
- Does NOT resolve a surfaced conflict or ambiguity unilaterally — presents it to the operator.
