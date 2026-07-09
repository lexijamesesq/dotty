# Calibration Surface — Knowledge-Ingress Judgment

The **canonical home** of the ingress judgment tables (per the ingress design's canonical-home table): kind definitions + destination classes, the four dimensions + thresholds, the mode × trust × kind disposition matrix, destination-resolution judgment guidance, and worked examples — interactive AND automated. Consumers — knowledge-integration (the gatekeeper), `/capture` (kind proposals), capture-meeting (extraction guidance), `/wiki-intake` (knowledge branch), handoff-contracts §§4–5 — REFERENCE this file. Nothing here is restated elsewhere; amend here, nowhere else.

## §1 The four dimensions

Evaluate every candidate against these as reasoning context, not a mechanical checklist.

**Queryability** — Would a future session plausibly search for this? Can you name a question this content answers? "What's the CacheTrack-to-GMS timeline?" is a real question someone will ask. "How many engineers are on the team?" probably isn't.

**Durability** — Will this still matter in 30 days? Timeline shifts, strategy pivots, decisions, blockers, and validated findings are durable. Sprint velocity, staffing moves, and "we're on track" updates are transient.

**Specificity** — Does it contain concrete claims — dates, names, numbers, named blockers, decisions, external dependencies? Specific claims are knowledge. "Good progress on the project" is noise.

**Independence** — Understandable without having been in the source meeting/session/conversation? Dangling pronouns ("this issue"), unexplained context ("as we discussed"), or references that only make sense in the source flow mean it needs context enrichment or it fails.

## §2 Thresholds

| Context | Bar |
|---|---|
| Standard | clearly strong on ≥2 of 4 dimensions |
| Elevated (1:1 meetings — the Tier-2 calibration, cited not reinvented) | ≥3 of 4, with stricter queryability: "would a future session search for this in a *professional* context?" |

**Mode bias at the gatekeeper** (extraction-layer discard-when-uncertain is unchanged and upstream of this):

- **Automated** — precision-over-recall. Clear pass → proceed to routing. Clear fail → noise → discard (logged). Uncertain at the bar → **queue**, not discard — the gatekeeper's defined surface categories land in `Wiki/Queue/`, so borderline judgment is deferred to the operator, never silently lost.
- **Interactive** — the operator is present. Clear pass → proceed. Clear fail → discard (borderline → ask). Uncertain → ask.

## §3 Kinds and destination classes

Each kind maps to exactly one destination class (spec §1, verbatim):

| Kind | Destination class |
|---|---|
| durable-knowledge | Knowledge layer (project Knowledge/ or `{workspace_root}/Wiki/Knowledge/` by scope) |
| meeting-log | registered meeting's per-area rolling log (`type/meeting-capture`) — Tier-1 dual-write branch only |
| data-mutation | Wiki/Data/ correction chain (interactive-only execution; automated → queue) |
| context-shift | `{workspace_root}/Wiki/Contexts/` domain context page (interactive/closeout autonomous; automated → queue) |
| personal-action | Personal/Work domain-page task section (interactive-only append; automated → queue) |
| project-work | Linear (interactive-only creation; automated → queue) |
| noise | discard, logged |

1:1 kind→class holds: context-shift targets `{workspace_root}/Wiki/Contexts` ONLY — project working-understanding is `/project-state`'s surface; pipeline candidates never target CLAUDE.md. One source item may yield multiple candidates of different kinds — **duplication happens at EXTRACTION only** (extractor emits both, shared provenance); the gatekeeper never splits a candidate.

**Kind signals:**

- **durable-knowledge** — a substantive finding, decision, synthesis, or dated fact that stands alone and answers a future question. New understanding, not a change to tracked state.
- **meeting-log** — a dated entry in a registered meeting's per-area rolling log. Only the registered capture-meeting playbook produces these (dual-write); exempt from the no-rollup rule by construction (the log derives from the external meeting source).
- **data-mutation** — a fact change to existing tracked state: "X is now Y", "stopped X", "switched to Y", "cancelled X". The signal is a state transition on data the vault already tracks, not new understanding.
- **context-shift** — a shift in working understanding of a Wiki domain (what's currently true/active in a domain), belonging on that domain's `{workspace_root}/Wiki/Contexts/` page rather than in a Knowledge file.
- **personal-action** — an action item owned by the operator personally ("Lexi to escalate…", "need to renew…"). Personal tasks are NOT Linear tickets — they append to the Personal/Work domain-page task section (format owned by router-spec).
- **project-work** — a trackable work item for a project's queue → Linear, per linear-discipline's Integrity on Creation.
- **noise** — fails the bar: routine status, transient chatter, template/placeholder text, pleasantries.

**Boundary: durable-knowledge vs data-mutation.** "The annual fee on the rewards card is $X now, up from $Y" → data-mutation (a tracked value changed). If the change also carries analysis worth keeping ("this triggers the keep/cancel analysis because…"), that analysis is a *separate* durable-knowledge candidate — split at extraction, don't conflate the mutation with the analysis.

**Boundary: durable-knowledge vs context-shift.** A dated durable fact ("CacheTrack-to-GMS integration is now 2028") can be BOTH a knowledge entry and a working-understanding shift — two candidates at extraction, shared provenance, each disposed independently.

## §4 Trust, mode, and the disposition matrix

Two orthogonal axes:

- **trust** = source property. `registered`: the operator configured or authored the source (registry-matched meeting; operator-authored Inbox capture; operator-present session content). `unregistered`: external/unconfigured (unregistered meeting, forwarded/third-party content). Hard line, unbypassable by construction: **no enum value other than `registered` grants autonomous filing.**
- **mode** = invocation property, **declared by the caller, always**. Staging-file presence implies automated (Pi convention). All scheduler-invoked runs are Pi-lane runs and declare automated. Subagents/background workers invoking capture machinery MUST declare automated — no human in their loop. Undeclared mode → the gatekeeper's stop rule applies (automated-strictness, queue-only).

**Surface defaults:**

| Surface | trust default | mode |
|---|---|---|
| Pipeline, registry-matched meeting | registered | automated |
| Pipeline, unregistered meeting | unregistered | automated |
| Inbox capture via interactive Router session | registered | interactive |
| Live session, operator present (/capture, closeout) | registered | interactive |
| Subagent-produced candidates | per source | automated |
| Third-party content pasted/forwarded | unregistered | per invoker |

(A scheduled Router is a FUTURE lane — it must be declared as its own named amendment to this table before any automated filing authority attaches.)

**Disposition matrix (mode × trust × kind).** The automated column IS the complete automated write authority; everything not listed as "file" queues or discards:

| Kind | automated + registered | automated + unregistered | interactive + registered | interactive + unregistered |
|---|---|---|---|---|
| durable-knowledge | file (resolved-unique) / queue (else) | queue | file / ask (ambiguous) | surface in-conversation |
| meeting-log | file (registered playbook only) | n/a (no registry) | file | n/a |
| data-mutation | queue | queue | execute chain ONLY on explicit operator mutation intent (the capture IS a correction statement — wiki-intake's existing pattern); extraction-*inferred* mutations → ask/confirm | surface |
| context-shift | queue | queue | autonomous per update-on-shift discipline | surface |
| personal-action | queue | queue | append to existing task section; queue if section absent | surface |
| project-work | queue | queue | create per linear-discipline integrity-on-creation | surface |
| noise | discard (logged) | discard (logged) | discard (logged; borderline → ask) | discard/ask |

Consequences: the unattended pipeline **never** mutates existing substance, never writes human surfaces, never creates Linear issues, never runs the data-correction chain. Automated Linear creation is deliberately absent — queue-only loses nothing; the next session promotes. Interactive `surface in-conversation` outcomes resolve with the operator to a terminal disposition; an operator's "file it" on surfaced unregistered content is a user-initiated action.

## §5 Destination resolution (durable-knowledge)

A named judgment with a mechanical consequence (the consequence rule lives with the gatekeeper; the judgment is calibrated here):

- **resolved-unique** — exactly one existing doc answers *the same question* as the candidate (one-question-per-file rule), OR no existing doc does and scope + topic yield an unambiguous new-file placement.
- **resolved-multiple** — two or more plausible homes at similar confidence — including a NEW-file placement where scope/topic plausibly span two established areas or projects at similar confidence (no existing doc required on either side). A candidate spanning two valid domains (e.g., a technology setup undertaken for a personal-care or health outcome) is resolved-multiple, not a silent pick of the more obvious-sounding tag. **Scope-first exclusion:** an explicit `project/*` scope claim RESOLVES scope — a co-occurring `area/*` tag on project-scoped content is descriptive metadata, never a competing home. Dual-domain applies only when no single scope claim wins: two projects, or two areas with no project claim.
- **unresolved** — no confident scope or topic; no natural placement.

Judgment guidance:

- **Match questions, not keywords.** A decoy doc sharing vocabulary with the candidate is not a home unless it answers the same question. Ask: "if a future session searched for the candidate's question, is THIS the doc it should land on?" Discrimination, not echo.
- **Scope first.** Who consumes this — sessions of one project (→ project-hosted, subject to the `### Knowledge` opt-in gate) or any session touching a life/work domain (→ Wiki-hosted, `area/*` + `topic/*`)?
- **Append-bias.** When a resolved-unique home exists, append to it; a near-duplicate new file is worse than a longer existing one.
- **Collapse-bias on topics.** Prefer an existing `topic/*` over a near-synonym when placing a new file.
- **Dated accretion is not contradiction.** A newer dated entry superseding an older dated entry in an accreting file (meeting logs, dated Knowledge sections) is the normal append pattern. A **contradiction** is an incompatible claim about the same fact with no supersession structure — that surfaces/queues as conflict.

## §6 Worked examples

Worked examples use Acorndyne — the vault's canonical fictional-company universe (`dotty/.claude/skills/sample-universe/universe.md`) — for narrative consistency across the knowledge-ingress skill family. The `<thinking>` traces demonstrate the reasoning style. Interactive first, then automated.

### Interactive

**I1 — file (resolved-unique append)**

Candidate (durable-knowledge, registered, interactive): `The Cache-to-Ledger data migration is a fundamental prerequisite to the GMS; earliest CacheTrack-into-GMS integration is now likely 2028 — a timeline the Drey Council had previously found unacceptable.`

<thinking>
Re-grade: durable-knowledge is right — a dated strategic fact, not a mutation to tracked data.
Search: topic/cachetrack surfaces two hits — `meeting-canopy-triad-sync-cachetrack.md` (same topic, but destination class meeting-log — §3's kind→class mapping is 1:1, and this skill does NOT write meeting logs, so a same-topic meeting log is never a candidate destination regardless of topic overlap) and `cachetrack-gms-integration.md` (destination class Knowledge layer), which answers "what's happening with the CacheTrack-to-GMS timeline?" — same question, matching class. Relationship: extends (new dated entry).
Coherence: strong on all four dimensions.
Resolution: resolved-unique — on the Knowledge-layer doc. (Had no Knowledge-layer doc existed, scope + topic would still route to a NEW `{workspace_root}/Wiki/Knowledge/` file, never to the meeting log.)
Disposition: file — append to `cachetrack-gms-integration.md` with date attribution; bump updated; verify suffix.
</thinking>

**I2 — discard (noise)**

Candidate: `Onboarding one additional engineer (3rd in total) to GMS Delivery Settings. Overall progress is steady.`

<thinking>
Queryability low (no one searches historical team size), durability low (stale within a sprint), specificity moderate but routine, independence fine.
Clearly fails the bar; not borderline, not pinned. Disposition: discard, logged (reason: transient status).
</thinking>

**I3 — data-mutation, explicit intent → execute chain**

Operator: `Capture this: I switched the house ISP to FiberCo yesterday — old service cancels on the 15th.`

<thinking>
Kind: data-mutation — "switched to Y" is a state transition on tracked home-services data, not new understanding.
Mode interactive, trust registered. Matrix cell: execute chain ONLY on explicit operator mutation intent. The capture IS the correction statement — the operator dictated it as a fact change. Intent is explicit.
Disposition: file (mutation) — delegate to /wiki-intake's data-correction chain (Data/ → Knowledge append → Context → Personal/Work as affected). Report every layer touched.
</thinking>

**I4 — data-mutation, extraction-inferred → ask**

During a broad "capture this session", the sweep finds an aside: `…oh, and the gym membership lapsed last month, which is why…`

<thinking>
Kind: data-mutation (active → lapsed on tracked data). But the operator never asked to record it — the mutation was *inferred by extraction* from a passing remark.
Matrix cell condition: extraction-inferred mutations → ask/confirm. Asking costs one sentence; a wrong mutation corrupts tracked state.
Disposition: ask — "Also record the gym membership as lapsed in the tracking chain?" On confirm → execute chain; on decline → discard or re-grade per the operator.
</thinking>

**I5 — pinned + coherence-fail → queue with note**

Operator: `capture that` → referent: `Something about how the Zigbee mesh handles… maybe coordinator placement, or the channel? Probably the microwave interference thing too.`

<thinking>
Pinned: explicit ask — inclusion is pinned regardless of my judgment.
Coherence: fails — no single question (mesh routing? placement? channel? interference?), not self-contained, no concrete claim. Unpinned this would be discard/ask.
Pinned + coherence-fail → queue, never silent discard. Disposition: queue — /queue create-item, queue-kind disposition, note naming the failed dimensions (single-question, specificity), payload carrying the verbatim content + candidate topics.
</thinking>

**I6 — ambiguous destination → ask**

Candidate (durable-knowledge, registered, interactive): a validated finding about home-automation testing practices produced during a personal-infrastructure project session.

<thinking>
Search: two plausible homes at similar confidence — `{workspace_root}/Projects/Home Automation/Knowledge/` (project-hosted; the home-automation project owns testing practice) and `{workspace_root}/Wiki/Knowledge/` under area/home (domain knowledge any session could need).
Resolution: resolved-multiple. Matrix: interactive + registered durable-knowledge, ambiguous → ask.
Disposition: ask — present both homes with the evidence; the operator's contract-legal choice wins silently.
</thinking>

**I7 — unregistered trust → surface in-conversation**

Operator pastes a colleague's Slack summary of a platform decision: `From #eng-announce: the platform team decided…`

<thinking>
Trust: unregistered — third-party content, not operator-authored (the operator forwarded it; they didn't author the claims).
Coherence passes; that changes nothing about trust. Matrix: interactive + unregistered durable-knowledge → surface in-conversation.
Disposition: surface — present the candidate + proposed destination + evidence; the operator's "file it" is a user-initiated action and proceeds; silence or "no" → discard or queue per their call.
</thinking>

### Automated

**A1 — clean resolved-unique append → file**

Candidate (durable-knowledge, registered, automated; source "Hollow Migration Sync 2026-07-02"): `Hollow EOL moved from FY27-Q2 to FY27-Q4; migration tooling scope now includes district-level exports. Decided at the migration sync; supersedes the Q2 assumption.`

<thinking>
Re-grade: durable-knowledge correct — dated decision + timeline, no tracked Data/ record involved.
Search: topic tags → fy26-hollow-migration.md answers "what is the Hollow migration plan?" — same question. Two keyword decoys (acorndyne-org-strategy, gms-timeline docs) answer different questions — discrimination, not echo.
Relationship: extends — dated accretion with explicit supersession, not a contradiction (§5: dated accretion is not contradiction).
Coherence: clear pass. Resolution: resolved-unique. Idempotency: no hash/attribution match in target.
Matrix: automated + registered, resolved-unique → file. Disposition: file — write-plan append entry {target, pre_state_hash, append_suffix}; NO new file.
</thinking>

**A2 — resolved-multiple → queue**

Candidate (durable-knowledge, registered, automated): a "Program Priorities Tracker" summary mixing org-initiative status, the operator's own professional-development notes, and team-process observations.

<thinking>
Coherence: passes (specific, durable, queryable) — the problem is placement, not quality.
Search: three plausible homes at similar confidence — a Team project Knowledge/ doc, `{workspace_root}/Wiki/Knowledge/` under area/work, and an existing initiatives context page. No single doc answers the same question; content spans scopes.
Resolution: resolved-multiple. Matrix: automated files only on resolved-unique.
Disposition: queue — one disposition item, reasons [resolved-multiple], payload + all candidate homes + search evidence. Must NOT file confidently; a wrong confident home buries it.
</thinking>

**A3 — re-grade INTO durable-knowledge → forced queue**

Candidate (proposed kind context-shift, registered, automated): `CacheTrack-to-GMS integration timeline is now 2028 (was 2027), per the Ledger migration dependency.`

<thinking>
Re-grade check: the extractor graded this context-shift, but it is a dated durable fact with a named dependency — durable-knowledge by the §3 definitions. Re-grade context-shift → durable-knowledge.
Lattice rule: this re-grade moves INTO durable-knowledge in automated mode — the new kind's automated disposition (file) is more permissive than the old kind's (queue). A re-grade must never gain filing authority: forced queue, even though the new kind's matrix cell would allow filing on resolved-unique.
Disposition: queue — disposition item, reasons [re-grade-forced], payload carrying both gradings (proposed context-shift, re-graded durable-knowledge) + evidence. The operator confirms the re-grade at triage; the next interactive pass may file it.
</thinking>

**A4 — duplicate → discard**

Candidate (durable-knowledge, registered, automated; source "Canopy Triad Sync 2026-06-25"): a re-delivered payload after a pipeline retry; target log already carries the 2026-06-25 dated section.

<thinking>
Re-grade: fine. Search: resolved-unique to the existing per-area file.
Idempotency: target contains an entry matching this candidate's attribution+date, and the content_hash matches the prior append.
Disposition: discard, reason duplicate — logged in the report, never a second append. Pipeline idempotency is n8n's job; this is the candidate-level backstop that keeps a double-delivery from becoming a double-append silently.
</thinking>

## Amendment discipline

This file changes only by operator-approved edit. Consumers reference sections by number (§1–§6); renumbering requires sweeping consumer references (knowledge-integration SKILL.md + playbooks, /capture, capture-meeting, /wiki-intake, handoff-contracts §§4–5).
