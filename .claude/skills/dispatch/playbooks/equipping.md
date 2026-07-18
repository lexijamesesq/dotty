# Equipping a Delegate

How to compose a brief that lets a delegate succeed on its first attempt. A delegate arrives with no memory of the shaping conversation — it knows only what you put in its prompt. Under-equipping is the dominant failure mode.

## The Brief — Five Components

Every delegation carries these five. Omitting any one is a known failure path.

### 1. Objective (what and why)

State the outcome as observable and falsifiable. Include WHY so the delegate can make judgment calls at decision points rather than following dead-letter instructions when premises shift.

Bad: "Refactor the auth module."
Good: "Extract token-refresh logic into a standalone function so three callsites stop duplicating retry handling. Done = each callsite calls one function, retry logic lives in one place, existing tests pass."

### 2. Context (what the delegate needs to know)

Transfer what the delegate will USE — not everything you know about the topic:
- Relevant file paths and their roles
- Constraints discovered during shaping (what was rejected, what's off-limits)
- Domain context not obvious from the code
- The north star the work serves

### 3. Check (how done is verified)

Define done as something executable. "The check is the contract." If you can't name how to verify completion, the task isn't ready to delegate.

- Exit code (tests pass, build succeeds) for mechanical correctness
- Diff inspection (output matches known shape) for structural conformance
- Behavioral probe (run it, observe result) for integration
- Independent review (fresh context) for judgment-dependent quality

A described goal ("make it good") is not a check.

### 4. Boundaries (what not to touch)

Delegates scope-creep by default. Fence the work:
- Files or systems off-limits
- Decisions that escalate rather than resolve autonomously
- Quality bars that must not degrade
- Token/time budget

### 5. Stop Conditions (when to halt and report back)

- Ambiguity the brief doesn't resolve
- Approach not working after one honest attempt
- Discovery that changes the premises
- Hit the scope boundary

A delegate without stop conditions either hallucinates through blockers or loops to context exhaustion.

## Model Selection

| Task shape | Model tier | Rationale |
|---|---|---|
| Planning, decomposition, judgment | Premium | Decision quality scales with thinking budget |
| Implementation with clear spec | Standard | Well-defined brief; premium tokens wasted |
| Mechanical transforms, boilerplate | Fast | Pattern application, no judgment needed |
| Review, critique, adversarial verification | Premium, fresh context | Judgment + contamination isolation |

Mix models within a single batch. Default model inheritance is almost always wrong for implementation tasks.

## Retry Discipline

One retry with failure context injected — what went wrong, what to do differently. This is a corrected brief, not "try again."

If the retry fails: the brief is wrong (redesign), the task is mis-shaped (not actually isolatable), or the model tier is wrong (judgment task on a labor model). Diagnose which. Never loop. Never retry without injecting failure context.

## After Dispatch

Trust the delegate. Do not pull work back — that re-contaminates the one clean window. A poor result means the brief was wrong; fix and re-send.

When the result returns: run the check you named. Pass or fail. If it requires judgment, route to an independent validator per `validation-discipline`.
