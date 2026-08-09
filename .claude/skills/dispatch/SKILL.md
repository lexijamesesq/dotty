---
name: dispatch
description: >
  Fires before the first Agent, Task, or Workflow call of a piece of work —
  about to spawn a subagent, fan out, parallelize, split work across contexts,
  or run one problem as several attempts. Skipped, delegates ship dead-on-arrival
  work from vague briefs. Consulted, it picks the execution shape (including not
  delegating at all) and gives each brief a checkable done-condition.
---

# /dispatch

Delegation discipline at the execution boundary — the moment shaped intent becomes divided labor. Two symmetric failures to prevent: over-engineering a team when one context suffices, and under-equipping a delegate so its work arrives dead on arrival.

This skill carries the decision procedure, the cost model, and the routing that resolves "how should this execute?" into a concrete shape.

## The Execution Boundary

The dispatch decision happens AFTER collaborative shaping — after the idea has been pressure-tested and refined into something buildable. The input is shaped intent with a clear north star. The output is an execution architecture: who does what, at what model tier, with what checks.

Do not conflate shaping with execution. Shaping is exploratory, tolerant of ambiguity. Execution is convergent and intolerant of unclear success criteria. The boundary is the moment the work is clearly defined enough to build.

## The Decision — Four Estimates

Before spawning anything, answer four questions (seconds, not minutes):

1. **Capacity.** Bigger than one context holds at full quality? A 60%-full context outperforms a 95%-full one. But capacity expires as a reason to divide — today's models hold more than yesterday's.

2. **Interdependence.** Do parts need to know what other parts did? High = single context or sequential — or, rarely, a communicating team when serializing genuinely loses. Low = parallelizable.

3. **Contamination.** Does seeing one part's output compromise judgment of another? Never expires as a reason to divide.

4. **Checkability.** Is verifying far cheaper than producing? When yes, cheap attempts + mechanical selection beats one expensive attempt. When no, spending stops paying — without a mechanical check, common selection methods (majority voting, reward models) plateau near a hundred attempts (Large Language Monkeys, Brown et al. 2024).

These resolve to six shapes:

| Shape | When |
|---|---|
| Work it here | Fits in context, parts interdependent, no contamination concern |
| One agent | Isolatable subtask with a clear mechanical check |
| A team | Independent tracks, each checkable, parallelism justified |
| Communicating team | Interdependent halves that genuinely can't serialize; rare |
| Redundant runs | One problem worth more than one attempt — same brief to N independent contexts, read convergence and variance |
| Leave it alone | Nothing can check the output |

**Two vetoes override every shape:** recurrence (one-off vs amortizable) and downstream value of a better answer.

**Depth cap.** Orchestrators (L0) spawn teammates, `` `@attack-kitty` ``, and `` `@traffic-cone` ``. Teammates (L1) may invoke `/dispatch` to decide their approach to complex work; when dispatch recommends fan-out, L1 spawns unnamed subagents for the pieces. L2 subagents are true leaves — they do the work and return results, no further spawning. L1 may spawn `` `@attack-kitty` `` for mandates its Mandate authority section classifies as any-depth. L1 cannot spawn named teammates (harness enforces flat roster), `` `@traffic-cone` `` (state mutations are L0 only), or `` `@attack-kitty` `` for mandates classified as L0-only. When spawning `` `@attack-kitty` ``, the caller includes its depth declaration in the spawn prompt — `Caller: L0 orchestrator` or `Caller: L1 teammate`. Attack-kitty checks this declaration against the mandate category and refuses gate mandates from L1 or undeclared callers.

## Shape Discipline

- **Prompt caching dies at fan-out.** Each agent pays full price for shared context. Three agents reading the same codebase pay 3x what one context pays once. Parallelism defeats caching.

- **Model inheritance is a trap.** Subagents inherit the dispatching model by default. Route explicitly: premium for judgment/planning, standard for implementation with clear specs, fast for mechanical transforms. Work already carrying a `model:*` label is routed — pass it through (gate validators excepted: the mandate's tier, never the work's label).

- **Agent count scope-creeps.** Start with the minimum viable team. Add agents only when a concrete bottleneck demands it — not when the task "could be" parallel.

- **Cap the work.** An uncapped agent fills its context, and an uncapped workflow run has no natural stop either. Set explicit scope, stop conditions, and a total ceiling at dispatch time. For redundant runs, the cap is N — gate it on the two vetoes and the checkability estimate; mechanical checks justify high N, convergence checks plateau fast.

## Routing Table

### Single-context (don't delegate)

- Fits comfortably in the current context window
- Parts are tightly coupled or serial-discoverable (each step reveals the next)
- A lookup, a single-file edit, a straightforward implementation
- The task would gain nothing from isolation — no contamination, no capacity pressure

Working it here changes who does the piece, not whether it names its proof.

### One agent (delegate, don't fan out)

- Isolatable subtask with a falsifiable completion condition
- Doesn't need the orchestrator's full context — just a spec and relevant files
- A mechanical check can verify the output (tests pass, schema matches, diff is clean)
- Would pollute the orchestrator's context if done inline

### Multiple agents (fan out)

- Genuinely independent tracks whose outputs don't depend on each other
- Each track has its own verifiable completion condition
- The overhead of context duplication is justified by parallelism gain or contamination isolation
- Sizing: 2-4 agents for direct comparisons or parallel research tracks; 10+ only for complex multi-source research where breadth justifies the cost

### Communicating team (interdependent halves)

- High interdependence AND genuine parallelism: interlocking halves of one deliverable where coordinating beats serializing
- Teammates share context and talk — the cost is correlated blind spots: a team converges on shared mistakes
- The validator is never on the team; it arrives fresh at the gate
- Reaching for this shape is usually a sizing smell — one deliverable needing several authors was probably cut too big; flag it upstream to whoever cut the work
- Structurally unavailable to L1 callers — the harness enforces flat rosters, so teammates cannot spawn named teammates with SendMessage. An L1 needing this shape surfaces it to its caller for re-scoping

### Redundant runs (same problem, N contexts)

- With a mechanical check, scale N aggressively: coverage converts directly into results (250 attempts from a cheap model beat one frontier attempt on SWE-bench Lite — Brown et al. 2024)
- Without a mechanical check, convergence IS the check — but selection plateaus near ~100 attempts. Convergence = confidence; divergence = a finding, not a failure: underspecified brief, wide option space, or genuine uncertainty. Read what each run noticed and what it ignored.
- Same-model runs measure spec stability (does the brief produce one answer or many?); multi-model runs expose framing bias — N copies of one model can converge on a shared blind spot
- Gate on the two vetoes: N× cost pays only when recurrence or the downstream value of a better answer justifies it
- Pure taste calls stay un-checkable at any N — judging costs what producing costs, so extra opinions just grow the pile. That's "leave it alone."

### Separate critic (contamination boundary)

- The orchestrator authored the work and cannot grade it
- A claim needs adversarial verification from a context with no authorship stake
- The artifact must stand alone (comprehension test requires a naive reader)
- Self-evaluation bias observed: identifying flaws then rationalizing acceptance
- Fulfilled by `` `@attack-kitty` `` — the estate's non-author validator; spawned with a typed mandate, returns a verdict

## Anti-patterns — Hard Stops

**Spawning agents for trivial lookups.** A grep, a file read, a web search — these are tool calls, not delegation opportunities. Spawning overhead exceeds the work.

**Self-validating own work.** The builder never issues its own PASS. Self-graded work is incomplete — this skill's boundary is the dispatch decision; `` `@traffic-cone` ``'s `mark_done` carries the validation protocol.

**Parallelism as default.** Sequential with prompt caching is often cheaper AND higher quality than parallel with duplicated context. Parallelize only when tracks are genuinely independent, when N attempts at one problem are the deliberate point (redundant runs), or when interdependent halves genuinely can't serialize (communicating team) — never as an accident of enthusiasm.

**Drift-back-to-solo.** Between dispatches, agents absorb subtasks that should be routed. The inverse also applies: orchestrators that delegate everything lose the context advantage of having shaped the work.

**Infinite retry loops.** One honest second chance with failure context injected. If it fails again, the brief was wrong — redesign, don't retry.

## When You Decide to Delegate

Load `playbooks/equipping.md` — brief composition, defining done as a checkable contract, model selection per task shape, and retry discipline.

## Relationship to Other Surfaces

- **`ways-of-working` rule** (always-on): "self-graded work is incomplete" — the principle. `` `@traffic-cone` ``'s `mark_done` carries the validation protocol.
- **Three Disciplines doc**: methodology source for composable agent patterns. This skill operationalizes those into dispatch decisions.
