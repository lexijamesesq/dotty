# Playbook: classify

Step 1 — read the capture and classify it into one of four intents. Reached only when Step 0 found no matching handler.

## Input

```yaml
content: <string>   # the raw capture
```

## Protocol

1. Evaluate what the capture IS, not what it could become, against the taxonomy:

   | Intent | Signal | Example |
   |---|---|---|
   | **knowledge** | Substantive content about a topic, with enough detail to stand alone | "Dedicating a backhaul channel on the mesh Wi-Fi restored full throughput — sharing a channel between nodes halved it" |
   | **data-correction** | A fact change to existing data — not new knowledge, a mutation to current state | "Switched ISP to FiberCo", "Streaming plan downgraded to the ad-supported tier", "Gym membership cancelled" |
   | **explore** | A topic the user wants to research later — no real content yet | "Look into rsync alternatives for incremental backup" |
   | **triage** | Content too incoherent or ambiguous to classify cleanly | Partial thoughts, mixed topics, unclear intent |

2. If intent is ambiguous → **halt and ask.** An honest "I'm not sure where this goes" is better than a wrong placement. Use the reasoning dimensions below to test ambiguous cases before halting.

## Output

```yaml
intent: knowledge | data-correction | explore | triage
```

Route per the navigator's Navigation table to the matching playbook.

## Classification examples

These demonstrate the reasoning pattern.

**Knowledge:**
> "The mesh Wi-Fi backhaul drops to half throughput when both nodes share a channel — moving the backhaul to a dedicated channel restored full speed. Confirmed across three evenings of testing."

→ **knowledge.** Self-contained finding. Clear topic (e.g. `topic/networking`, home-infrastructure area). Specific enough to stand alone. Single question: why was the mesh backhaul slow, and what fixed it.

**Data-correction:**
> "Cancelled the streaming-service-X subscription as of today"

→ **data-correction.** State change to existing tracked data, not new knowledge. The subscription was previously active; the mutation is active → cancelled. Propagate through the subscriptions tracking chain.

**Explore:**
> "Look into rsync alternatives for incremental backup over flaky network"

→ **explore.** No substantive content — just a topic to research later. Nothing to file as knowledge yet.

**Triage:**
> "Something about the way the Zigbee mesh handles... maybe we need to think about the coordinator placement, or is it the channel? Related to the interference from the microwave probably."

→ **triage.** Multiple possible topics (mesh routing, coordinator placement, channel selection, RF interference), no clear single question, stream-of-consciousness rather than a finding. Preserve as a queue item so it's not lost.

**Boundary — knowledge vs data-correction:**
> "The annual renewal for the backup tool posted — it's $X now, up from $Y"

→ **data-correction.** The primary signal is "a tracked value changed." The renewal price is a fact update to existing subscription data. If the increase also carries strategic implications worth capturing (e.g., triggers a keep/replace analysis), that's a separate knowledge capture — don't conflate the mutation with the analysis.

**Boundary — knowledge vs explore:**
> "Filesystem X reportedly corrupts data on drive firmware Y"

→ Depends on context. If the user runs that filesystem on that hardware → **knowledge** (actionable operational note, self-contained). If speculative/general → **explore** (needs research before it's a finding). **When uncertain → halt and ask.**

## Reasoning dimensions for ambiguous cases

When classification isn't obvious, evaluate along these axes:

| Dimension | Knowledge signal | Not-knowledge signal |
|---|---|---|
| **Specificity** | Contains a concrete claim, finding, or fact | Vague interest, question, or direction |
| **Completeness** | A reader can understand it standalone | Requires conversation context to parse |
| **Actionability** | Changes understanding or behavior | Observation without conclusion |
| **Scope** | One identifiable question/topic | Multiple tangled threads |
| **Mutation signal** | "X is now Y", "stopped X", "changed to Y" | No state change implied |

A capture that scores high on specificity + completeness + actionability + single scope → knowledge. High on mutation signal → data-correction. Low across the board → triage. Clear topic but no content yet → explore.

## What this playbook does NOT do

- Does NOT package candidates or execute any routing action — classification only. Routing lives in the destination playbook (`knowledge-intent.md`, `data-correction.md`, or `explore-triage.md`).
- Does NOT guess when ambiguous — halts and asks per the navigator's stop rules.
