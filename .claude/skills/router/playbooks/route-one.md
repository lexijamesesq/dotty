# Playbook: route-one

Route a single named capture through the full per-capture flow. Same rules as `process.md`, scoped to one file — no sweep plan; per-file confirmation is inherent.

## Input

- `capture` — filename (or unambiguous name fragment) of one file in `Inbox/`
- `today` — ISO date (defaults to system date)

## Protocol

### 1. Resolve the capture

- Resolve the vault root via the `workspace_root` config key (fallback `VAULT_ROOT` env). Unresolvable → halt.
- Locate the named file in `Inbox/`. Not found → report and stop (do not search other folders; the Router routes Inbox captures only).
- File is tagged `type/dashboard` → refuse: dashboards are generated views, not captures.
- File carries a `routed:` frontmatter stamp → it was already delivered in a prior run and retained; surface that state and ask the operator whether to delete it now (re-verify provenance first) — do not re-route.

### 2. Discover destinations (runtime)

Per SKILL.md § Destination resolution. Fresh discovery even for a single capture — never a cached map.

### 3. Classify

Read the full content + frontmatter (`mcp__obsidian__read_note`), then:

1. Classify per spec § Classification Taxonomy (`professional-strategy | professional-operational | personal | meta`) + confidence.
2. Two-axis evaluation per spec § Knowledge Axis Classification (Task / Knowledge fire independently).
3. Detect specialized routes per spec § Contract Resolution (weekly team update, ad-hoc Slack, strategy seed).
4. Coverage check: Linear duplicate check per `linear-discipline` § Integrity on Creation; existing seed filenames per spec. Prior coverage found → superseded-candidate: present the evidence; the operator chooses discard (logged), queue, or deliver anyway. Never auto-discard.

State the proposed route (classification, confidence, axes, destination, delivery method, proposed end state) to the operator before delivering. Ambiguity the operator can settle in a sentence → ask now; anything needing deferred judgment → `/queue create-item` (triage).

### 4. Deliver

Same routing order and rules as `process.md` § 5:

- **Specialized (spec-owned):** strategy → a strategy seed per spec § Seed Creation + the destination project's contract; weekly team update → activity logs per spec § Team Activity Log Creation + the destination project's contract; ad-hoc Slack → spec § Slack Signal Extraction, then the default path.
- **Project-owned:** Task axis → Linear per `{workspace_root}/System/Knowledge/unified-ingress-design.md §14` + `linear-discipline` (context doc for 3+ sentence captures). Knowledge axis → only if the destination's CLAUDE.md frontmatter includes `knowledge_intake: true` (read via `get_frontmatter`; absent/false = opt-out). `Knowledge/` is the standardized location. Per spec § Knowledge Delivery Rules (envelope, `sources` provenance, index update, the filing-time lint gate; `Knowledge/` dir absent → queue, never create).
- **Domain-owned:** Knowledge axis → full verbatim capture + lightweight area identification to `/wiki-intake` (`mode: interactive`, `trust: registered`) — full stop. Task axis → domain-page task-section append per spec § Domain Destinations; page/section absent → queue-triage.
- **No home / ambiguous** → `/queue create-item`: `queue_kind: disposition`, `source: router`, reasons, scope tags when identifiable, payload = full verbatim capture + evidence.

### 5. Verify provenance, confirm, delete

Apply the route-specific provenance check from `process.md` § 6 (seed `## Original Capture`; Linear description-or-context-doc; Knowledge `sources` + validator PASS; wiki-intake reported disposition; domain-page item present; queue item created with verbatim payload). Then ask the operator to confirm deletion of the Inbox file and delete via `mcp__obsidian__delete_note`.

Declined or verification failed → the file stays; stamp additive `routed: <destination> (<date>)` frontmatter via `mcp__obsidian__update_frontmatter` (body untouched) and say so in the report.

### 6. Report

Emit the per-item YAML record per spec § Output Schema plus a one-paragraph disposition statement: classification, destination(s), provenance verification result, and the capture's end state (deleted / retained-stamped / queued / asked).

## Discipline

- **Zero silent drops** — this one capture ends as a filed artifact, a queue item, or an explicit halt-and-ask; a discard only as a logged operator decision.
- **Never modify the capture body.** Additive `routed` frontmatter is the only permitted mutation, and only after confirmed delivery.
- **Routing only.** No development, no enrichment, no consolidation, no Wiki-internal decisions.

## What this playbook does NOT do

- Does NOT sweep the rest of the Inbox — one capture, one disposition.
- Does NOT bypass operator confirmation for deletion; there is no batch mode here.
