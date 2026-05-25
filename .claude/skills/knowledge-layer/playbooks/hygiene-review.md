# Playbook: hygiene-review (load-boundary guard)

**LOAD BOUNDARY:** This file is loaded ONLY by a fresh subagent invocation given one doc + the anti-pattern definitions. The scan path (`hygiene.md`) NEVER loads this file. The load boundary IS the structural self-evaluation guard per `[[composable-skills-methodology]]`.

The orchestrator (typically `/session-closeout`) spawns a critic subagent for each doc flagged as `for_review` by the scan path. The subagent reads:
1. This file (the review rubric)
2. The doc being reviewed
3. Nothing else (no scan reasoning, no session context, no list of other docs)

The subagent returns a per-doc verdict; the orchestrator decides how to act. Iteration cap 3 per doc.

## Rubric (per-anti-pattern PASS/FAIL with specific gap)

For each of the seven anti-patterns, evaluate the doc independently:

### 1. Appendix syndrome

- Look for: dated section headers near the end of the doc that reads like an appendix (`## Extended Research: YYYY-MM-DD`, `## Update: YYYY-MM-DD`, `## Addendum: YYYY-MM-DD`).
- Exception: a single "Sources" or "References" section at the end is NOT appendix syndrome.
- Verdict: HIT if dated appendix found; PASS otherwise.
- **Suggested fix:** integrate the appendix content into the relevant existing section; delete the dated header.

### 2. Duplicate structures

- Look for: tables that repeat earlier content with added rows; lists that re-enumerate items from a prior section with additions; sections that overlap >50% with a previous section's content.
- Verdict: HIT if duplication clear; PASS otherwise.
- **Suggested fix:** merge the duplicates into a single authoritative structure; delete the duplicate.

### 3. Historical framing

- Look for: prose about HOW/WHEN/WHY research was conducted ("Last session I investigated X", "This was discovered during Y", "After several iterations I found Z").
- Exception: methodology/provenance markers are FINE ("Analysis used the X framework", "Conducted via A/B testing").
- Verdict: HIT if process-narrative bleed found; PASS for methodology markers.
- **Suggested fix:** rewrite to present-tense statement of current understanding; move the historical context to Linear Project Updates if useful or just delete.

### 4. Progress-log bleed

- Look for: "Session N findings:", dated bullet entries, "Today's work:", "What I did:" language in a doc that should present timeless knowledge.
- Verdict: HIT if log-style entries present; PASS otherwise.
- **Suggested fix:** strip the log scaffolding; preserve the substantive content as integrated knowledge prose.

### 5. Unbounded growth

- Look for: doc length >300 lines AND lack of clear top-level structure (e.g., no section headers to navigate by, or sections so long they need their own structure).
- Note: long docs are not inherently bad; structure is what matters.
- Verdict: HIT if both length + lack of structure; PASS otherwise.
- **Suggested fix:** split into multiple docs OR add structural headers; if splitting, also update the Knowledge index.

### 6. Stale content

- Look for: explicit claims that you can verify are no longer true (e.g., reference to a tool by an old name that's been renamed, or a count that's been superseded).
- Best-effort only — you can only catch what's checkable without external research.
- Verdict: HIT if verifiable staleness found; PASS otherwise (don't speculate).
- **Suggested fix:** update the specific claim or flag for the caller to verify with current info.

### 7. Orphaned sections

- Look for: content no longer connected to the doc's stated purpose or active project concerns. Often: legacy notes from an earlier version of the project, or a tangent that became its own concern and is now adrift here.
- Verdict: HIT if section is clearly disconnected; PASS otherwise.
- **Suggested fix:** move the orphan to where it belongs (a different doc, a Linear issue) OR delete if not useful.

## Output format

```yaml
doc: <path>
verdict: PASS | REVISE | FAIL
findings:
  - pattern: <number + name>
    severity: HIGH | MEDIUM | LOW
    excerpt: <quoted excerpt from doc, ≤100 chars>
    issue: <specific gap>
    suggested_fix: <one line>
```

- **PASS** = zero HIGH findings, ≤2 MEDIUM. Doc is clean enough for current session.
- **REVISE** = HIGH findings present. Orchestrator should apply suggested fixes and re-invoke (iteration cap 3).
- **FAIL** = same findings after 3 iterations OR doc has fundamental structural issues beyond pattern-matching (e.g., the doc's purpose is unclear and patterns reflect that). Escalate to operator.

## Adversarial framing

You are the structural guard. The scan path flagged this doc as ambiguous because pattern-matching wasn't clear-cut — your job is to provide the rigorous read.

Default to surfacing concerns. A pattern that *might* be a hit deserves at least a LOW finding. Better to over-report and let the orchestrator filter than to under-report and let an anti-pattern land in the corpus.

But: methodology + provenance markers are NOT hits. Be specific about the exception (criterion 3). A doc that says "Analysis used X framework" is well-formed; a doc that says "I analyzed using X framework last week" is process-narrative bleed.

If you can't tell whether a pattern hits, name the ambiguity in the finding's `issue` field and use MEDIUM severity. The orchestrator escalates ambiguous-after-review to the operator.
