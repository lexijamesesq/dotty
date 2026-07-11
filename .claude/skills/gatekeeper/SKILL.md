---
name: gatekeeper
description: >-
  Universal router + gatekeeper for everything entering the vault's knowledge
  layer. Receives typed candidates from any ingress surface (automated
  pipeline, Inbox routing, live sessions via /capture and closeout), resolves
  each to a terminal disposition — file (through a write contract), queue
  (Wiki/Queue/ item), or discard (logged) — under the two-axis trust/mode
  authority model. No candidate bypasses it; no extractor writes destinations.
  Triggers on "/gatekeeper assess candidates" or
  "/gatekeeper assess single".
argument-hint:
  - "assess candidates"
  - "assess single"
context: fork
allowed-tools:
  - Task
  - Skill
  - 'Bash(date:*)'
  - 'Bash(shasum:*)'
  - mcp__obsidian__read_note
  - mcp__obsidian__read_multiple_notes
  - mcp__obsidian__search_notes
  - mcp__obsidian__write_note
  - mcp__obsidian__patch_note
  - mcp__obsidian__get_frontmatter
  - mcp__obsidian__update_frontmatter
  - mcp__obsidian__list_directory
  - mcp__obsidian__get_notes_info
---

# gatekeeper — Router + Gatekeeper

One judgment pass per candidate: routing and vault-fit are two halves of one judgment — "does this help me help Lexi?" includes "where would it help?". Extractors (capture-meeting, `/capture`, `/wiki-intake`'s knowledge branch, the Router) produce typed candidates; this skill disposes of them. Filing contracts: knowledge-contract Part III §4 (session capture), §5 (automated capture), and §1 (wiki-intake-delivered captures). Where this skill is silent, the ingress design governs.

## Identity

Discipline rules applied on every invocation:

- **Resolve the vault root via the `workspace_root` config key** (global CLAUDE.md > Configuration). Never hardcode a vault path.
- **Vault `.md` operations go through Obsidian MCP tools** — never generic Read/Write/Edit.
- **The caller declares `trust` and `mode`, always.** Trust is a source property; mode is an invocation property. This skill never decides its own mode.
- **The calibration surface is the canonical judgment home.** `Wiki/spec/calibration-surface.md` (vault spec layer, vault-root-relative) holds the kind definitions, the four dimensions + thresholds, the full disposition matrix, destination-resolution guidance, and worked examples (interactive AND automated). Load it on every invocation; reference its tables, never restate them.
- **One vault search feeds routing AND assessment** — never two passes.
- **Per-candidate accounting.** The gatekeeper never splits a candidate (multi-kind duplication happens at extraction only, with shared provenance); every candidate ends with exactly one terminal disposition.

## Intent

**Objective.** Noise has negative value — bad entries degrade search, dilute context windows, and make future answers less reliable; misrouted entries are buried where no future query finds them. Every ingress surface produces candidates; without one gatekeeper owning both routing and vault-fit, each surface re-invents partial judgment and the automated lanes accrete write authority nobody audited. This skill is the single point where candidates become vault state: file, queue, or discard — nothing else, no exceptions.

**Desired outcomes** (observable):
1. Every candidate gets exactly one terminal disposition — file / queue / discard — no silent drops, no unaccounted candidates.
2. Filed content is discoverable via tag queries in its first session and satisfies the full knowledge-contract Part II envelope.
3. The automated write surface stays deliberately narrow: Knowledge-layer appends/creates + meeting logs (registered playbook) + `Wiki/Queue/` items — nothing else, ever.
4. Every queued candidate is one self-contained adjudication package carrying ALL applicable reasons plus search evidence — no evidence loss to branch ordering.
5. Every run emits the machine-readable extraction report — the audit artifact, the critic rubric's input, and the fixture-eval interface.

**Health metrics — must NOT degrade:**
- Zero automated-mode edits to existing substance (appends/creates only; edits are human-approved, ever — surfacing a conflict is not approval).
- Zero filings from any trust value other than `registered` (missing or unknown trust ≠ registered).
- Zero pinned candidates silently discarded.
- Zero double-appends — the idempotency check (`content_hash` / attribution+date) runs before every append.
- Zero files created without the full knowledge-contract Part II envelope.
- Report reconciliation: `dispositions[]` covers every candidate; `queue_items[]` count matches actual queue writes (rubric R1/R7).

**Strategic context.** The universal gatekeeper of the ingress design — router AND gatekeeper, one skill. Consumers: capture-meeting (pipeline dual-write Tier 1 + unregistered fallback), `/capture` (mid-session, plus `/capture batch` — the boundary entry `/knowledge-layer` query-and-file delegates to), `/wiki-intake` (knowledge-intent branch), the interactive Router (via `/wiki-intake`). Automated capture-lane filing authority is additionally subject to the Phase-3 enablement gate; the Pi lane config owns that gate — when the lane declares it uncleared, automated runs operate queue-only regardless of the matrix.

**Constraints.**
- **Hard:** No enum value other than `registered` grants autonomous filing — unbypassable by construction.
- **Hard:** Undeclared mode → automated-strictness dispositions (queue-only; no filing, no mutation) + report flag. See Stop rules for the why.
- **Hard:** Automated mode never mutates existing substance, never writes human surfaces (Personal/Work), never creates Linear issues, never runs the data-correction chain. The matrix's automated column IS the complete automated write authority; everything not listed as "file" queues or discards.
- **Hard:** Re-grade lattice rule (Order of operations, step 1) — a re-grade never gains filing authority in automated mode.
- **Hard:** Every queue landing goes through `/queue create-item`; one item per queued candidate, carrying `reasons[]`.
- **Hard:** Interactive data-mutation executes only per its matrix cell — explicit operator mutation intent required (calibration surface §4); extraction-inferred mutations are asked, never assumed.
- **Steering:** four dimensions as context, not a mechanical checklist; append-bias; collapse-bias on topics; precision-over-recall in automated mode.

**Decision authority.** The disposition matrix (calibration surface §4) IS the authority model — mode × trust × kind, complete and closed. Within it, autonomous: re-grade, vault search, coherence assessment, destination resolution, batching, filing where the matrix says file, queue-item creation via `/queue create-item`, discard logging, report emission. Operator (interactive mode): ambiguity asks, destination overrides, mutation-intent confirmations, borderline-noise asks. The filing-time lint gate (`lint.py --filing`) holds PASS/FAIL authority on filed envelopes.

**Stop rules.**
- No candidates provided → halt. Do not invent candidates.
- Vault search unavailable (MCP down) → halt; do not assess without vault context. Automated: report FAIL (the orchestrator suppresses the heartbeat).
- **Undeclared mode → automated-strictness queue-only + `undeclared_mode` report flag.** This REWRITES the previous stop rule ("default to interactive (conservative)"): interactive is now the higher-authority column, so it can no longer be the fallback — a missing declaration must never grant MORE authority. Operator-safety fix.
- `Wiki/Queue/` missing, or a queue-item write fails → report FAIL loudly per `/queue` stop rules; a dropped judgment is invisible forever.
- Interactive filing-time lint gate FAIL persisting after 3 fix iterations → surface the full finding list; do not mark the filing complete.

## Candidate schema

The candidate schema, plus the `pinned` marker that carries the pinned rule:

```
{
  content:            string        # self-contained after context enrichment
  kind:               enum          # extractor's PROPOSAL; gatekeeper may re-grade
  source_attribution: string        # "Canopy Triad Sync 2026-05-28" / "CC session 2026-07-06 (Infrastructure)"
  provenance:         string[]      # knowledge-contract Part II Provenance vocabulary (incl. routine/<action> <run-id>)
  scope_hint:         string|null   # proposed project/* or area/* — hint, not authoritative
  topic_hints:        string[]
  trust:              registered | unregistered      # SOURCE property
  mode:               automated | interactive        # INVOCATION property, declared by caller
  content_hash:       string        # idempotency key at candidate level (SHA-256 of content)
  pinned:             boolean       # optional, default false — explicit operator "capture this"
}
```

`kind` ∈ the closed enum in calibration surface §3; each kind maps to exactly one destination class. Kind is a proposal — re-grading is this skill's first move, with full any-kind → any-kind authority, bounded by the lattice rule below.

## Order of operations (per candidate)

1. **Re-grade check.** Full authority, any kind → any kind. **Lattice rule (automated mode):** a re-grade whose new kind has a more permissive automated disposition than the old kind's — concretely, any re-grade INTO {durable-knowledge, meeting-log} from any other kind — forces disposition `queue`. Re-grades among queue-bound kinds, or into noise, may execute. Why: this closes the smuggling path (mutation-flavored content re-graded to "knowledge" and appended as fact) while preserving misclassification recovery — wrong-kind candidates get corrected or safely parked, never executed under the wrong contract.
2. **Vault search** — one search feeding routing and assessment: scope determination → target search → relationship (updates / extends / contradicts / none). Retain the evidence for the report and any queue item.
3. **Coherence assessment** — four dimensions at the mode's threshold (calibration surface §§1–2).
4. **Disposition** — evaluate ALL applicable conditions, collect ALL reasons; look up the matrix (calibration surface §4). A queued candidate produces ONE queue item carrying `reasons[]` — conflict payload included even when unregistered also applies; no evidence loss to branch ordering.

**Destination resolution** (within step 4, durable-knowledge only) is a named judgment with a mechanical consequence. Outcome ∈ {resolved-unique, resolved-multiple, unresolved} — judgment guidance + worked examples in calibration surface §5. Mechanical consequence (calibration surface §4 cell + §5 defensible best home): automated mode files on resolved-unique OR resolved-multiple's defensible best home (alternative home noted in the entry); unresolved → queue only if §0.3 (critically important AND stuck), else discard logged (`placement-unresolved`). Interactive: resolved-unique → file; resolved-multiple / unresolved → ask (operator present). **Project-hosted opt-in gate (mechanical):** the destination project's CLAUDE.md must declare `### Knowledge` under `## Intake` (knowledge-contract Part III §2, inherited by §§4–5). Absent → the content files to the Wiki-hosted domain home instead (`area/*` + `topic/*`, no opt-in required — calibration surface §5: a missing declaration never black-holes content), AND the declaration proposal queues separately (reason `opt-in-gate-absent`). In interactive mode the operator may add the declaration on the spot — re-run the mechanical check, then proceed. **Integration-mode guard (mechanical, automated):** before planning an automated append, read the destination's `integration:` frontmatter override ([[integration-modes]] §3; class default §2). An `integration: current-truth` target is a mutation surface — an automated write there queues (reason `mutation-path-inactive`) until the validated-mutation path is active ([[integration-modes]] §4–§5 own the activation state), never appends; evolution targets proceed.

**Batching:** after per-candidate routing, group file-disposition candidates by target file; check each group pairwise for internal contradictions; one ordered append per target per run. A within-group contradiction → neither candidate files as fact: interactive → surface both versions to the operator; automated → one `disposition` queue item carrying both + evidence.

**Pinned:** an explicit operator "capture this" pins inclusion. Pinned + coherence-fail → queue (`disposition`, with a note naming the failed dimensions) — never silent discard, in any mode.

**Idempotency:** before any append, check the target for an existing entry matching `content_hash` or attribution+date → discard with reason `duplicate`. Double-append is thereby never silent. (Pipeline-level idempotency remains n8n's; this is the candidate-level backstop.)

**Interactive override:** an operator-chosen destination wins within contract-legal space, silently. A contract-violating override (e.g., personal-action → Linear; creating a rollup) gets the violated rule stated + explicit confirmation; confirmed = user-initiated action (the constraint system binds autonomous action only). A filing-time lint gate FAIL on a user-chosen destination → fix the envelope, keep the destination — orthogonal concerns.

## Write execution

- **Interactive** (knowledge-contract Part III §4): file-then-fix. New files: write the full envelope, then run `python3 ~/bin/dotty/.claude/skills/lint-knowledge/lint.py --filing --no-manifest --json --vault-root <vault-root> <target-path>`. PASS = zero HIGH findings. FAIL → fix each HIGH finding, re-run; cap 3. Appends: idempotency-checked suffix with date attribution, `updated` bump, suffix-presence verify. Project-hosted filings: `index.md` sync (§4 post-file) — performed here, reported to the caller as done.
- **Automated** (knowledge-contract Part III §5): emit a pre-commit write plan — load `playbooks/automated-write-plan.md`. This skill NEVER applies the plan; in automated mode its only direct vault writes are `/queue create-item` files.

## Extraction report

Every run emits (both modes):

```
{ run_id, source, candidates[],
  dispositions[],   # candidate → {file|queue|discard, reasons[], target}
  write_plan,       # automated mode; null in interactive
  applied[],        # interactive: filled by this skill; automated: completed by the apply/verify stage
  queue_items[],    # paths of created Wiki/Queue/ items
  flags[] }         # e.g., undeclared_mode
```

Interactive runs additionally present the human-readable summary: filed / queued / discarded, with paths and reasons.

## Navigation

| Invocation | Input | Output | Playbook |
|---|---|---|---|
| `assess candidates` | candidate list (schema above) + declared trust/mode | dispositions + extraction report (+ write plan when automated) | `playbooks/assess-candidates.md` |
| `assess single` | one candidate | same, single-candidate | `playbooks/assess-candidates.md` |

`playbooks/automated-write-plan.md` is loaded from within assess-candidates when `mode: automated` — never as a direct entry.

**Load boundaries.** Validation is never self-performed: interactive envelope validation runs the deterministic filing-time lint gate (`lint.py --filing` — a script, not judgment, so no separate-context requirement; validation-discipline's narrow exemption); automated plan validation goes to the orchestration-tier critic gate (capture-rubric v2, pi-cc dispatch) in a separate context. This skill judges and composes; the lint gate and independent contexts verify.

## What this skill does NOT do

- Does NOT extract candidates from raw content — the calling surface's job.
- Does NOT decide its own mode or trust — the caller declares both, always.
- Does NOT split candidates — multi-kind duplication happens at extraction only, with shared provenance.
- Does NOT write meeting logs — the registered capture-meeting playbook's dual-write branch owns those.
- Does NOT execute the data-correction chain itself — interactive data-mutations delegate to `/wiki-intake`'s data-correction branch, the existing chain owner.
- Does NOT restate the personal-action append format — `router-spec.md` owns it; appends conform by reference.
- Does NOT apply automated write plans — apply is a deterministic script at the orchestration tier (plan → validate → apply → verify).
- Does NOT own queue mechanics — `/queue` owns the item schema, triage, and expiry.

## References

- The ingress design — the spec this skill implements.
- `Wiki/spec/calibration-surface.md` (vault spec layer) — canonical judgment tables + worked examples.
- knowledge-contract Part II (envelope, Provenance vocabulary) + knowledge-contract Part III §§4–5 — resolve paths via the `references.structural_contract` / `references.handoff_contracts` config keys (global CLAUDE.md > Configuration).
- `/queue` — the queue-item interface (`create-item`).
- `lint.py --filing` (`~/bin/dotty/.claude/skills/lint-knowledge/`) — the filing-time lint gate; envelope PASS/FAIL authority.
- `router-spec.md` — personal-action append format owner. `linear-discipline` — project-work creation integrity.
