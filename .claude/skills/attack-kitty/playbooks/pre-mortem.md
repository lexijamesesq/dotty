# Mandate: pre-mortem

Attacks a plan or decision by writing its failure account, not by deriving failure forward. Tier: **fable** — same adversarial-reasoning weight as `pressure-test.md`, different cognitive mode.

`pressure-test.md` attacks forward: it takes the plan as given and derives the case that breaks it. This mandate attacks backward: it's six months later, the plan failed, and you write the retrospective as if the failure already happened — then work back to what caused it. The premise of failure is fixed; your job is to make the account concrete and internally consistent, not to argue whether failure is likely. Use this mandate when the caller wants the failure-mode surface a forward attack tends to miss — the slow drift, the compounding small gaps, the thing that was fine at launch and wasn't six months on.

## What the caller gives you

- The plan or decision, in full — whatever document, ticket, or written form it takes.
- Any stated constraints, success criteria, or timeline the caller considers load-bearing.

## Fetch your own evidence

If the plan references external facts (an existing system's behavior, a prior decision, a resource constraint), verify those yourself rather than accepting the plan's characterization of them.

## The mandate

Write the failure account. It's the stated horizon (six months, or whatever the caller names) later, and the plan has failed. Narrate why, as a retrospective would — not as a list of risks, but as a causal account:

- **What broke first** — the initial crack, stated as something that actually happened, not a hedge.
- **What it cascaded into** — how the first failure compounded, given what the plan didn't account for.
- **What the plan's author would say in hindsight** — the assumption that looked safe at the time and wasn't; state it as their own retrospective admission, not your outside critique.

Write one coherent account, not a list of unrelated failure scenarios — a real retrospective has one throughline. If more than one failure mode is worth naming, write the most damaging one in full and name the others as alternates you didn't develop.

## Verdict

Post via `@linear` if the plan lives on a Linear issue, or return directly to the caller otherwise:

```
Checked:     what you attacked, and how — the failure account you constructed
Verdict:     CONFIRMED (no plausible failure account) | REFUTED (account holds) | CONFIRMED-WITH-GAPS (account holds under named exposure)
Specifics:   the failure account in full — what broke first, what it cascaded into, the assumption that didn't hold
Not covered: explicit scope boundary — what you didn't attempt to attack and why
Mode:        pre-mortem, informed
```

A CONFIRMED verdict here means you couldn't construct a plausible failure account, not that none exists — treat it with the same caution `pressure-test.md`'s SKILL.md note gives a clean confirmation.
