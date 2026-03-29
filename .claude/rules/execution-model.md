# Execution Model

The main context window orchestrates. Subagents implement.

| Main window (Orchestrator) | Subagents (Workers) |
|---|---|
| Read state, decompose work | Create or substantially modify files |
| Route subtasks to workers | Research requiring multiple tool calls |
| Present results to human | Testing and validation |
| Update tracking (backlog, progress, CLAUDE.md) | Spec writing, multi-file edits |

**Heuristic:** If the work produces a deliverable, delegate it. If it informs a decision, do it here.

**Pattern selection within subtasks:**
- Independent subtasks: run workers in parallel
- Sequential dependencies: chain outputs
- Quality-critical: follow with an evaluator (see below)

**Model selection for Agent tool calls:**
- **Opus:** Strategic synthesis, voice-sensitive writing, complex judgment (drafting, refining, multi-source synthesis)
- **Sonnet:** Structured research, template-driven analysis, classification tasks, web search synthesis, competitive analysis, MCP queries with structured output
- Default Agent tool calls to Sonnet unless the task requires complex judgment. Specify `model: "sonnet"` explicitly.
- Note: The Skill tool does not support model selection — skills inherit the parent model. Model optimization only applies to Agent tool delegations.

## Evaluator Pattern

Use a separate critic subagent to review work before finalizing. Self-evaluation bias causes rationalization of flaws — a standalone evaluator tuned for skepticism is more reliable than self-review.

**When to use a critic:**
- **Plans** — before committing to implementation. Catches missing steps, overcomplicated approaches, unvalidated assumptions. Cheaper to fix a plan than undo built work.
- **Multi-file or infrastructure changes** — deliverables that affect other sessions or cross repo boundaries. Catches format inconsistencies, missed references, schema mismatches.
- **Any situation where the author is also the reviewer** — the core self-evaluation bias problem. The critic provides the adversarial perspective the author cannot.

**How:**
- Launch a critic agent (Opus for judgment-heavy review) with the deliverable AND explicit success criteria
- The critic checks against the criteria, not vibes — negotiate what "good" looks like before implementation when possible
- Fix issues before proceeding to the next deliverable
- For multi-deliverable work, critic after each deliverable (not batched at the end)

Full methodology (calibration, sprint contracts, three-agent architecture): `~/Vaults/Notes/Claude/System/sustained-autonomous-agentic-workflows.md`

## Task Decomposition

When breaking work into subtasks:

1. **Draft subtasks** that are concrete and independently completable
   - "Read all inbox items and classify" is a good subtask
   - "Process the inbox" is not — too vague to execute without interpretation

2. **Verify coverage** with this checklist:
   - **Implementation steps** — the actual work to be done
   - **Validation/eval subtask** — if the item changes behavior or touches external systems, include a concrete test (live run, mock validation, or accuracy check)
   - **Documentation updates** — specs, CLAUDE.md, progress log
   - **Human decision points** — any subtask that blocks on human input should be explicit

3. **Flag human dependencies** — if a subtask requires a human decision, make that explicit in the subtask description so it surfaces during execution rather than blocking silently
