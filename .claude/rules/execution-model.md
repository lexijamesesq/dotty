# Execution Model

Claude operates as orchestrator by default. The main context window decomposes work, delegates to subagents, and presents results. It does not implement deliverables itself unless the work is trivially small (single edit, quick lookup). The goal is to push delegation outward — use platform verification features (Outcomes, /goal supervisors) to increase what can be fully delegated without manual checkpoints.

| Orchestrator (Main Window) | Workers (Subagents) |
|---|---|
| Read state, decompose work | Create or substantially modify files |
| Route subtasks to workers | Research requiring multiple tool calls |
| Present results to human | Testing and validation |
| Update tracking (backlog, progress, CLAUDE.md) | Spec writing, multi-file edits |

**Heuristic:** If the work produces a deliverable, delegate it. If it informs a decision, do it here. When uncertain, delegate — the cost of an unnecessary subagent is lower than the cost of a bloated orchestrator context.

## Delegation Patterns

**Pattern selection:**
- Independent subtasks: run workers in parallel
- Sequential dependencies: chain outputs
- Quality-critical: pair with Outcomes grader or evaluator subagent

**Effort-scaling:** Match subagent count to task complexity. Over-scaling compounds cost without improving quality.
- **1 agent** — simple fact-finding, single-file edits
- **2-4 agents** — direct comparisons, parallel independent research tracks
- **10+ agents** — complex multi-source research, large codebase changes

**When to use /goal instead:** If the task has a verifiable completion condition (tests pass, lint clean, build succeeds), prefer `/goal` over manual orchestrator/worker decomposition. `/goal` runs its own lightweight evaluator and a supervisor that verifies the final state independently. Reserve manual orchestration for work that requires human judgment at intermediate steps or doesn't have a falsifiable end state.

**Structured handoff:** When delegating, provide the subagent with explicit success criteria and the specific files/context it needs. Don't rely on the subagent to discover scope — discovery is the orchestrator's job.

## Evaluator Pattern

Use Outcomes (platform-managed grader in a separate context window) when available. Outcomes runs a rubric-based grader that evaluates output independently of the writer's reasoning, returns per-criterion gap lists, and loops revision until criteria are met or an iteration cap is reached.

In Claude Code sessions where Outcomes isn't available, use a separate critic subagent. The principle is the same: self-evaluation causes rationalization of flaws — independent evaluation in a clean context window doesn't.

**When to use evaluation:**
- **Plans** — before committing to implementation
- **Multi-file or infrastructure changes** — deliverables that affect other sessions or cross repo boundaries
- **Any situation where the author is also the reviewer** — the core self-evaluation bias problem

**Rubric design:** The grader checks against criteria, not vibes. Define what "good" looks like before implementation when possible. Per-criterion scoring with specific gap descriptions is more actionable than pass/fail.

**Name platform features by name.** A doc that is conceptually aligned with a platform feature (evaluator → Outcomes, verifiable completion → `/goal`) still must point at the feature explicitly — given only the pattern, Claude recreates it from scratch (hand-rolled critic subagents, manual verification loops) instead of reaching for the feature.

Full methodology (calibration, sprint contracts, three-agent architecture): path configured in global CLAUDE.md > Configuration > `references.three_disciplines`

## Model Selection

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
