# Playbook: assess-candidates

Protocol for `assess candidates` and `assess single` (a single candidate is a batch of one). Load `../calibration-surface.md` before the first candidate — every judgment below (kind definitions, dimensions, thresholds, the disposition matrix, resolution guidance, worked examples) lives there and is referenced, never restated.

## 0. Validate the invocation

- Candidates present? None → halt (stop rule). Do not invent candidates.
- Read `trust` and `mode` per candidate.
  - `mode` missing/undeclared → process that candidate at **automated strictness, queue-only** (no filing, no mutation) and set `undeclared_mode` in report `flags[]` (SKILL.md stop rule; the why lives there).
  - `trust` missing/unknown → treat as `unregistered` — only the literal `registered` grants autonomous filing (hard constraint).
- Resolve run metadata: `run_id` (caller-provided, else `{source-slug}-{YYYY-MM-DD}` via `Bash(date:*)`) and `source`.

## 1. Per candidate — re-grade check

Read `content` against the proposed `kind` (calibration surface §3). Wrong proposal → re-grade; full authority, any kind → any kind.

**Lattice rule (automated mode):** any re-grade INTO {durable-knowledge, meeting-log} from any other kind → force disposition `queue` with reason `re-grade-forced`, regardless of the new kind's matrix cell. Re-grades among queue-bound kinds, or into `noise`, execute normally. Interactive mode: re-grade freely; the new kind's interactive column governs.

Record `{kind_proposed, kind_final, regrade_forced: bool}` per candidate for the report.

## 2. Per candidate — one vault search

One search pass feeds BOTH routing and assessment:

1. **Scope determination** — verify or derive `scope_hint`: project (`project/*`) or Wiki (`area/*`)? Tag search (`mcp__obsidian__search_notes` with `searchFrontmatter` on candidate area/topic/project tags) + content search on key terms.
2. **Target search** — existing docs answering the candidate's question: tag matches, content matches, path check on the natural destination.
3. **Relationship** — per related doc: updates / extends / contradicts / none. Apply calibration surface §5's "dated accretion is not contradiction" distinction.

Retain the evidence (paths, matched queries, quoted lines). It goes into the report and, verbatim, into any queue item.

## 3. Per candidate — coherence

Four dimensions at the mode's threshold (calibration surface §§1–2). Assess pinned candidates too — a pin changes the landing of a fail (queue, not discard), never the assessment.

## 4. Per candidate — disposition

Evaluate ALL applicable conditions and collect ALL reasons — never stop at the first:

- `trust` ≠ registered
- coherence: clear fail (→ noise path) vs uncertain-at-the-bar (automated → queue; interactive → ask)
- contradiction with existing vault content — include BOTH versions in the payload
- destination resolution (durable-knowledge only): resolved-unique / resolved-multiple / unresolved (judgment: calibration surface §5). Mechanical consequence: automated files ONLY on resolved-unique; interactive asks on anything else.
- project-hosted opt-in gate: read the destination project's CLAUDE.md; is `### Knowledge` present under `## Intake`? Mechanical presence check. Absent → reason `opt-in-gate-absent` → queue as `proposal` (interactive: the operator may add the declaration now; re-check, then proceed).
- re-grade forced (step 1)
- idempotency (appends): target already contains an entry matching `content_hash` or attribution+date → disposition `discard`, reason `duplicate`
- pinned + coherence-fail → disposition `queue` (queue-kind `disposition`) with a note naming the failed dimensions — never silent discard

Then look up the matrix (calibration surface §4) with `mode × trust × kind_final`. Interactive `ask` / `surface in-conversation` outcomes resolve with the operator to a terminal disposition (file / queue / discard) before the report — `ask` is never terminal.

## 5. Batch — group + within-group contradiction check

Group `file`-disposition candidates by target file. Pairwise-check each group for internal contradictions (incompatible claims about the same fact — calibration surface §5 distinction). On contradiction:

- Interactive → surface both versions to the operator; their decision yields terminal dispositions.
- Automated → remove both from the write plan; ONE `disposition` queue item carrying both candidates + evidence.

Compose one ordered append per surviving target per run (source order, oldest attribution first).

## 6. Queue landings

Every `queue` disposition → `/queue create-item`, one item per queued candidate (within-group conflicts: one item per conflict pair):

| Dominant reason(s) | queue_kind |
|---|---|
| `opt-in-gate-absent` / proposing a new Data/ record / project-work deferred from automated mode (next session promotes to Linear) | `proposal` |
| everything else — contradiction (vault or within-group), unregistered trust, uncertain coherence, resolved-multiple / unresolved, `re-grade-forced`, pinned coherence-fail, undeclared mode, automated kind-authority deferral (data-mutation / context-shift / personal-action) | `disposition` |

Pass to create-item: `queue_kind`; `source` = this run's source; `reasons[]` = ALL collected reasons; scope tags from the resolved or hinted scope; evidence = the step-2 search evidence plus attribution + provenance (+ both gradings when re-graded, both versions when conflicting) — all of which lands in the item's `## Mechanics` section, not the ask.

**The payload is a human ask, not a data dump.** This playbook is the only party holding both the candidate and the reasons, so it composes the three parts create-item requires (create-item.md § The human-question test): *what this is* — the candidate's content in plain terms; *why I'm stuck* — the collected reasons translated into the specific fork only the operator can close (e.g. `resolved-multiple` becomes "this could live with your X notes or your Y notes and I can't tell which"; `unregistered trust` becomes "this came from pasted third-party material, so I won't file it as your knowledge without your say-so"); *what your answer changes* — each plausible answer mapped to the disposition it triggers, consequences first. Reason codes, kind names, trust levels, and check ids never appear in the ask. The title handed over is the plain question itself.

An item-write FAIL fails the run loudly (stop rule) — never proceed as if queued.

## 7. Execute — interactive mode (handoff-contracts §4)

Per `kind_final`; the matrix cells govern, the owners below execute:

| kind_final | Execution |
|---|---|
| durable-knowledge | **New file:** compose the full structural-contract envelope (field derivation per handoff-contracts §4; sources from the Provenance vocabulary), write via `write_note`, then invoke the `filing-validator` agent (Task tool) with target path + handoff `§4 session capture` (wiki-intake-delivered: `§1 wiki intake`) + destination class. FAIL → fix each HIGH violation, re-invoke; cap 3; still failing → surface all findings, do not mark complete. **Append:** idempotency-checked, date-attributed suffix via `patch_note`; bump `updated`; verify suffix presence. **Project-hosted:** sync the `index.md` entry (§4 post-file) and report it done. |
| meeting-log | Only the registered capture-meeting playbook writes these (dual-write branch). A meeting-log candidate arriving here without a registry match → re-grade or queue. |
| data-mutation | Explicit operator mutation intent (the capture IS a correction statement) → delegate to `/wiki-intake` (data-correction intent — the existing chain owner: Data/ → Knowledge append → Context → Personal/Work). Extraction-inferred → ask/confirm first; confirm → delegate; decline → re-grade or discard per the operator. |
| context-shift | Update the `{workspace_root}/Wiki/Contexts/` domain context page per the update-on-shift discipline (autonomous). Never a project CLAUDE.md. |
| personal-action | Append to the existing Personal/Work task section per router-spec's personal-action append format (the format owner). Section absent → queue (`disposition`) — never create the section. |
| project-work | Create the Linear issue per `linear-discipline`'s Integrity on Creation: duplicate check, falsifiable acceptance criteria, relations as Linear relations, project + priority matching the work. |
| noise | Discard, logged in the report. Borderline → ask. |

## 8. Execute — automated mode (handoff-contracts §5)

Load `automated-write-plan.md`. Summary of the contract: this skill emits the write plan + queue items + report; the orchestration tier validates (critic gate, capture-rubric v2), applies (deterministic script), and verifies (filing-validator / suffix checks). No destination write happens in this context — the skill's only direct vault writes in automated mode are `/queue create-item` files.

## 9. Report

Emit the extraction report (schema: SKILL.md › Extraction report). Reconcile before returning:

- every candidate has exactly one terminal disposition (rubric R1);
- `queue_items[]` matches the step-6 writes (rubric R7);
- interactive: also present the human-readable summary — filed (paths + validator verdicts), queued (item paths + reasons), discarded (reasons) — and any `flags[]`.
