---
name: publish
description: >
  The estate's one-step publishing gate — orchestration-enforced, human mode:
  the operator keeps publish authority and consumes a verdict, this skill
  never decides for her. Composes scaffold verification, sample-file audit,
  sample-universe conformance, house-qa review, a full-change gitleaks scan,
  and the advisory security review into one Evaluator-Optimizer pass ahead of
  any push/PR/merge. Triggers on "/publish", "publish this repo", "run the
  publishing gate".
---

# /publish (Orchestrator)

Runs the one gate a change crosses before it reaches public GitHub. Composes `/house-qa` and `/sample-universe` (domain experts, never re-implemented here) with mechanical scaffold/gitleaks checks and the advisory security review, then hands the operator one verdict.

## Intent

**Objective.** publishing-gate-architecture.md names the gap this closes: scattered checks (`permissions.ask`, ad-hoc `/security-review`, eyeballing) with no single enforced pass — the exact hole the executable-path fix exposed (a check executable from one cwd, silently not from another). This skill is P1: consolidate the scattered checks into one orchestration-enforced Evaluator with a written rubric.

**Desired outcomes** (observable):
1. Every repo-level publish gets one verdict — pass or fail — never a partial, ad-hoc subset of checks.
2. A FAIL verdict carries named, per-criterion findings; the operator never re-derives what broke.
3. The verdict is a structured block a future autonomous consumer (the gateway-Pi's P3 mode) could read, even though nothing consumes it that way yet.

**Health metrics — must NOT degrade.**
- False-pass rate = 0 (publishing-gate-architecture.md's non-negotiable) — a clean verdict on a repo with an actual leak, oversized artifact, or exploitable finding is the one failure this skill cannot have.
- cwd-independence: every check runs against the target repo passed as an argument (`git -C <target>`), never the session's own cwd — the executable-path lesson, structural now, not advisory.
- Decision Authority stays narrow: this skill reports; it never pushes, merges, or bypasses a `permissions.ask` prompt on its own authority.

**Strategic context.** publishing-gate-architecture.md's P1 phase — human mode, Decision Authority narrow, the operator consumes the verdict (`permissions.ask`). P2 (shadow calibration against operator judgment) and P3 (autonomous mode on the gateway Pi) are later phases this skill does not build.

**Constraints.**
- **Hard:** cwd-independence — the gate takes a target repo path; it never assumes the session's own repo is the target. Human mode only; no autonomous publish path exists here.
- **Steering:** which sub-checks short-circuit the two judgment passes (house-qa review, security review) is cost judgment — see `playbooks/gate.md`'s ordering rules.

**Decision authority.**
- **Autonomous:** running the gate; reporting the verdict at its derived pass/fail per criterion.
- **Escalate:** verdict FAIL → stop, report findings, do not proceed to push/PR. Repo visibility unrecognized → ask before choosing a push/PR path. Every `permissions.ask`-gated action (push, PR create, merge) still prompts — unchanged.

**Stop rules.**
- Verdict FAIL → no push/PR guidance beyond the findings; the operator resolves and re-runs.
- Repo visibility unknown → ask, don't guess.
- A composed skill's required reference file is missing (house-qa's rosters/universe files) → it already fails loud; propagate, don't retry silently.

## Trigger handling

`/publish`, `/publish <repo-path>`, "publish this repo", "run the publishing gate" → resolve the target repo: the argument if given, else `git rev-parse --show-toplevel` from cwd. Confirm the resolved path before running anything — this IS the cwd-independence boundary; get it right before spending a single check.

## The gate — seven-step composition

Full rubric, commands, and verdict schema live in `playbooks/gate.md`. Each step here names its owner in ≤3 lines.

1. **Scaffold verification** — `playbooks/gate.md` § Scaffold. Root-anchored `.gitignore` actually effective, gitleaks `[allowlist]` present if content-bearing (or, absent one, a clean operator-pattern sweep of tracked HEAD content), LICENSE+README present, every operator-config referenced by tracked machinery has a `*.sample.*` shape. Findings that reproduce on `origin/HEAD` are pre-existing debt, not gate failures — `playbooks/gate.md` § Criteria.
2. **Sample-file audit** — `playbooks/gate.md` § Scaffold (placeholder-integrity sub-check). Every tracked `*.sample.*` file still carries a placeholder marker; zero hits means a filled-in copy leaked.
3. **Sample-universe conformance** — house-qa's `check` (fiction-detection checks) covers the mechanical half; for genuinely new narrative content in this change, load `/sample-universe` directly and confirm its citation + universe-only rules.
4. **House-qa mechanical** — invoke `/house-qa check` against the target repo. Zero HIGH, excluding paths under any skill's own `tests/fixtures/` (documented literal test data, not shipped content). Findings that reproduce on `origin/HEAD` are pre-existing debt, not gate failures — `playbooks/gate.md` § Criteria.
5. **House-qa judgment** — invoke `/house-qa review` (fresh context) before any ship decision. KEEP passes; SIMPLIFY passes once its named edits are applied and re-reviewed to KEEP; REWORK fails.
6. **Gitleaks full-change scan** — `gitleaks detect --source <target> --log-opts="origin/HEAD..HEAD" --ignore-gitleaks-allow` — the full branch diff, not just pre-commit's staged slice. Zero leaks.
7. **Advisory security review** — per `publishing-workflow.md` § Advisory security review. **cwd-independence is REQUIRED**: always `git -C <target> diff origin/HEAD...`, never a bare `git diff` — a check that only works from the target repo's own cwd is the exact failure this gate exists to close.

**Short-circuit.** Any HIGH-severity mechanical finding (steps 1–4, 6) skips both judgment passes (5, 7) and returns FAIL immediately — don't spend a fresh-context critic or a security review on a change that's already failing.

## Push/PR flow (only on PASS)

Unchanged from `publishing-workflow.md`: branch → commit → push → PR → merge for public repos, every step still prompting via `permissions.ask`; direct push for `dotty-private` and other declared-private repos. This skill orchestrates up to the verdict — it does not touch push/PR mechanics or bypass a single prompt.

## What this skill does NOT do

- Does NOT implement autonomous/P3 mode. Decision Authority stays narrow — the operator consumes the verdict; the gateway-Pi's wide-authority mode is a later workload, gated behind the P2 shadow-calibration phase this skill doesn't run.
- Does NOT fix findings — `/house-qa` and `/sample-universe` report; the caller edits.
- Does NOT replace `/security-review` when the session is already rooted in the target repo — `playbooks/gate.md` names both paths.

## References

- `{workspace_root}/System/Knowledge/publishing-gate-architecture.md` — the design doc (P1 scope, Decision Authority, Evaluator-Optimizer framing).
- `../../rules/publishing-workflow.md` — the workflow this skill orchestrates.
- `../house-qa/SKILL.md`, `../sample-universe/SKILL.md` — composed domain experts.
- `playbooks/gate.md` — rubric, commands, verdict schema.
