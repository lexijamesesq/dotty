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
- Quality-critical: follow with an evaluator

**Model selection for Agent tool calls:**
- **Opus:** Strategic synthesis, voice-sensitive writing, complex judgment (drafting, refining, multi-source synthesis)
- **Sonnet:** Structured research, template-driven analysis, classification tasks, web search synthesis, competitive analysis, MCP queries with structured output
- Default Agent tool calls to Sonnet unless the task requires complex judgment. Specify `model: "sonnet"` explicitly.
- Note: The Skill tool does not support model selection — skills inherit the parent model. Model optimization only applies to Agent tool delegations.

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
