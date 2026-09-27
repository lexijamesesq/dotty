#!/usr/bin/env python3
"""ollie-state.py -- Ollie as a teammate: the one place that asks the operator.

Design: the Ollie-as-teammate design (2026-09-27) (operator-
approved 2026-09-27). Margot judges; Ollie owns each PR from verdict to merge
and is the only thing that asks the operator for anything. For each open PR it
decides one state and makes GitHub match it:

  waiting-on-operator  the merge is blocked on her -> ONE signal, by what she
                       must do (decide()'s `via`):
                         review: her judgment on the change (Margot held it
                           for her; it changes Margot's own machinery) -> her
                           REVIEW is requested, once per head (not again after
                           she reviews that head)
                         assign: the pipeline needs her (no verdict, a hold
                           with no verdict, approved but not merged, a stalled
                           bot author) -> she is ASSIGNED
                       Neither on her own PR: Margot's review already reaches
                       her as the author, and GitHub refuses a review request
                       of the author.
  waiting-on-author    Margot asked the author for changes -> label only
  outage               Margot's verdict came from the fallback or errored ->
                       label only; one estate-wide outage issue instead
  (none)               nothing is needed -> no label; a pending review request
                       is withdrawn and she is unassigned (on an OPEN PR only:
                       a merged or closed PR is history, never rewritten)

One signal per PR (operator, 2026-09-27): review a change -> review
request; unblock the pipeline -> assignment. Ollie never @mentions her. One
comment per PR (marker below), edited in place as the state changes; edits do
not notify. Labels do not notify either; they power the operator's saved view
(`is:open is:pr label:waiting-on-operator`).

The rules live in decide(), a pure function (tested by
.claude/eval/ollie-state.test.sh). Everything else reads GitHub or writes it.

Usage:
  ollie-state.py --repo owner/name [--pr N] [--refusal TEXT] [--dry-run]
      one repo: every open PR (--pr puts that PR first; --refusal is GitHub's
      reason from Ollie's merge attempt on it, quoted in its comment)
  ollie-state.py --estate --rulesets-file rulesets/default-branch.json [--dry-run]
      every enrolled repo, plus the single outage issue in dotty

Stdlib only; talks to GitHub through the gh CLI (GH_TOKEN = Ollie's token).
"""

from __future__ import annotations

import argparse
import json
import subprocess
import sys
from datetime import datetime, timezone

OPERATOR = "lexijamesesq"
MARGOT_APP = "margot-the-meticulous"
VERDICT_CHECK = "review / margot"
SELF_INSTRUMENT_CHECK = "review / self-instrument"
MARKER = "<!-- ollie:state -->"
OLLIE_LOGIN = "ollie-the-intern[bot]"
NO_VERDICT_HOURS = 6.0
STALLED_HOURS = 1.0
LABELS = {
    "waiting-on-operator": ("d93f0b", "Ollie: the merge is blocked on the operator"),
    "waiting-on-author": ("fbca04", "Ollie: Margot asked the author for changes"),
    "outage": ("b60205", "Ollie: Margot's verdict came from the fallback or errored"),
}
OUTAGE_REPO = "lexijamesesq/dotty"
OUTAGE_TITLE = "Margot outage: reviews are not reaching Jev or the council"


def hours_since(ts: str | None, now: datetime) -> float:
    if not ts:
        return 0.0
    t = datetime.fromisoformat(ts.replace("Z", "+00:00"))
    return (now - t).total_seconds() / 3600.0


def parse_verdict(text: str | None) -> dict:
    """outcome, band and decision source from the verdict check's text."""
    out = {"outcome": "", "band": "", "source": ""}
    for line in (text or "").splitlines():
        if line.startswith("outcome:"):
            parts = [p.strip() for p in line[len("outcome:") :].split("|")]
            out["outcome"] = parts[0]
            for p in parts[1:]:
                if p.startswith("band:"):
                    out["band"] = p[len("band:") :].strip()
        elif line.startswith("decision_source:"):
            out["source"] = line[len("decision_source:") :].strip()
    return out


def decide(f: dict, now: datetime) -> dict:
    """The rules. `f` holds the PR's facts; returns {state, ask}."""
    none = {"state": None, "ask": ""}
    if f["pr_state"] != "OPEN":
        # A merged or closed PR is history: its assignee, reviewers and labels
        # record who did what, and Ollie never rewrites them (operator,
        # 2026-09-27). Anything that needed her was done by her.
        return {"state": None, "ask": "", "leave": True}
    if f.get("draft"):
        return none
    v = f.get("verdict")  # latest review / margot check-run, or None
    if not v or v.get("status") != "completed":
        # From the later of the PR opening and its head commit: a push starts
        # a new review, so an old PR pushed a minute ago is not overdue.
        since = max(filter(None, [f["created_at"], f.get("head_at")]))
        if hours_since(since, now) >= NO_VERDICT_HOURS:
            return {
                "state": "waiting-on-operator",
                "via": "assign",
                "ask": f"No Margot verdict after {NO_VERDICT_HOURS:g} hours. The review may be stuck on the Pi runner or failing to start; check the margot repo's review runs.",
            }
        return none
    p = parse_verdict(v.get("text"))
    waited = hours_since(v.get("completed_at"), now)
    if not p["outcome"] and v.get("conclusion") in ("action_required", "failure"):
        # Margot held the PR without a verdict: a driver or Jev failure with no
        # outcome, an attribution leak, a template hold, a poster exception.
        # Her check carries only a title and a reason then (margot-builder,
        # 2026-09-27). Not a model outage -- a hold only she can clear.
        return {
            "state": "waiting-on-operator",
            "via": "assign",
            "ask": f"Margot held this without posting a verdict: {v.get('title') or 'no reason given'}. Check the margot repo's review run for this PR.",
        }
    if p["outcome"] == "ERROR" or p["source"] == "fallback":
        return {
            "state": "outage",
            "ask": "Margot could not score this with Jev or the council (fallback or error). It is listed on the estate's outage issue and will be re-reviewed when the model is back.",
        }
    if p["outcome"] in ("CHANGES_REQUESTED", "CLARIFICATION_REQUESTED"):
        if f["author_is_bot"] and waited >= STALLED_HOURS:
            return {
                "state": "waiting-on-operator",
                "via": "assign",
                "ask": f"Margot asked for changes {waited:.1f} hours ago and the author ({f['author']}) has not pushed since. The author may be paused or stuck.",
            }
        return {"state": "waiting-on-author", "ask": ""}
    if p["outcome"] == "APPROVED":
        if f.get("self_instrument") == "action_required":
            return {
                "state": "waiting-on-operator",
                "via": "review",
                "ask": "Margot approved this, but it changes Margot's own machinery, so only you can merge it: admin-merge.",
            }
        if v.get("conclusion") != "success" and not f.get("operator_approved"):
            # Margot approved but held it for the operator: a MEDIUM or HIGH
            # band, or a LOW one she could not vouch for (an unresolved or
            # established finding, an open clarification, an uncomputed owned
            # tier, a review that failed its own checks). Her check's title
            # names the reason; she posts a COMMENT review, not an APPROVE, so
            # GitHub will not let Ollie merge it until the operator approves.
            reason = (v.get("title") or "").removeprefix("Margot: ").strip()
            return {
                "state": "waiting-on-operator",
                "via": "review",
                "ask": f"Margot approved this but held it for you ({reason or 'no reason given'}). Approve it and Ollie merges it.",
            }
        if waited >= STALLED_HOURS:
            why = f.get("refusal") or f.get("merge_state") or "unknown"
            return {
                "state": "waiting-on-operator",
                "via": "assign",
                "ask": f"Approved {waited:.1f} hours ago but not merged. GitHub's reason: {why}.",
            }
        return none
    return none


# --- GitHub I/O -------------------------------------------------------------


def gh(*args: str, data: dict | None = None) -> str:
    cmd = ["gh", "api", *args]
    if data is not None:
        cmd += ["--input", "-"]
    r = subprocess.run(
        cmd,
        input=json.dumps(data) if data is not None else None,
        capture_output=True,
        text=True,
    )
    if r.returncode != 0:
        raise RuntimeError(f"gh api {' '.join(args)}: {r.stderr.strip()[:300]}")
    return r.stdout


def gh_json(*args: str):
    out = gh(*args)
    return json.loads(out) if out.strip() else None


def gh_list(path: str, items: str = ".[]") -> list:
    """Every page of a list endpoint, one item per line from gh's --jq."""
    out = gh("--paginate", "--jq", items, path)
    return [json.loads(line) for line in out.splitlines() if line.strip()]


def open_prs(repo: str) -> list[dict]:
    return gh_list(f"repos/{repo}/pulls?state=open&per_page=100")


def facts(repo: str, pr: dict, refusal: str = "") -> dict:
    n = pr["number"]
    head = pr["head"]["sha"]
    runs = gh_list(
        f"repos/{repo}/commits/{head}/check-runs?per_page=100", ".check_runs[]"
    )
    mine = [r for r in runs if (r.get("app") or {}).get("slug") == MARGOT_APP]

    def latest(name):
        named = [r for r in mine if r.get("name") == name]
        named.sort(key=lambda r: (r.get("started_at") or "", r.get("id") or 0))
        return named[-1] if named else None

    v = latest(VERDICT_CHECK)
    si = latest(SELF_INSTRUMENT_CHECK)
    reviews = gh_list(f"repos/{repo}/pulls/{n}/reviews?per_page=100")
    op_reviews = [r for r in reviews if (r.get("user") or {}).get("login") == OPERATOR]
    op_approved = any(r.get("state") == "APPROVED" for r in op_reviews)
    op_reviewed_head = any(r.get("commit_id") == head for r in op_reviews)
    detail = gh_json(f"repos/{repo}/pulls/{n}") or {}
    commit = gh_json(f"repos/{repo}/commits/{head}") or {}
    login = (pr.get("user") or {}).get("login", "")
    return {
        "number": n,
        "pr_state": "OPEN" if pr.get("state") == "open" else "CLOSED",
        "draft": pr.get("draft", False),
        "created_at": pr.get("created_at"),
        "head_at": ((commit.get("commit") or {}).get("committer") or {}).get("date"),
        "author": login,
        "author_is_bot": login.endswith("[bot]")
        or (pr.get("user") or {}).get("type") == "Bot",
        "verdict": {
            "status": v.get("status"),
            "conclusion": v.get("conclusion"),
            "completed_at": v.get("completed_at"),
            "title": (v.get("output") or {}).get("title"),
            "text": (v.get("output") or {}).get("text"),
        }
        if v
        else None,
        "self_instrument": (si or {}).get("conclusion"),
        "operator_approved": op_approved,
        "merge_state": detail.get("mergeable_state"),
        "refusal": refusal,
        "review_requested": OPERATOR
        in [u.get("login") for u in pr.get("requested_reviewers") or []],
        "operator_reviewed_head": op_reviewed_head,
        "assignees": [a["login"] for a in pr.get("assignees") or []],
        "labels": [lbl["name"] for lbl in pr.get("labels") or []],
    }


def ensure_labels(repo: str, dry: bool) -> None:
    have = {lbl["name"] for lbl in gh_list(f"repos/{repo}/labels?per_page=100")}
    for name, (color, desc) in LABELS.items():
        if name not in have and not dry:
            gh(
                f"repos/{repo}/labels",
                data={"name": name, "color": color, "description": desc},
            )


def comment_body(d: dict) -> str:
    if d["state"] is None:
        return f"{MARKER}\nNothing needed from anyone right now."
    head = {
        "waiting-on-operator": "**This needs you.**",
        "waiting-on-author": "**Waiting on the author** to answer Margot's review.",
        "outage": "**Margot is in an outage** for this PR.",
    }[d["state"]]
    return f"{MARKER}\n{head}\n\n{d['ask']}".rstrip()


def apply(repo: str, f: dict, d: dict, dry: bool) -> str:
    n = f["number"]
    if d.get("leave"):
        return f"{repo}#{n}: closed -- history, left as it is"
    want = d["state"]
    actions = []
    # labels: exactly the one for this state
    for name in LABELS:
        if name == want and name not in f["labels"]:
            actions.append(
                ("POST", f"repos/{repo}/issues/{n}/labels", {"labels": [name]})
            )
        elif name != want and name in f["labels"]:
            actions.append(("DELETE", f"repos/{repo}/issues/{n}/labels/{name}", None))
    # the one signal: a review request when her judgment on the change is
    # needed, an assignment when the pipeline needs her to act; nothing on her
    # own PR (Margot's review already reaches her as the author)
    via = d.get("via") if f["author"] != OPERATOR else None
    ask = {"reviewers": [OPERATOR]}
    reviewers = f"repos/{repo}/pulls/{n}/requested_reviewers"
    if via == "review":
        if not (f["review_requested"] or f["operator_reviewed_head"]):
            actions.append(("POST", reviewers, ask))
    elif f["review_requested"]:
        actions.append(("DELETE", reviewers, ask))
    who = {"assignees": [OPERATOR]}
    assignees = f"repos/{repo}/issues/{n}/assignees"
    assigned = OPERATOR in f["assignees"]
    if via == "assign" and not assigned:
        actions.append(("POST", assignees, who))
    elif via != "assign" and assigned:
        actions.append(("DELETE", assignees, who))
    # one comment, edited in place; created only when there is something to say
    comments = gh_list(f"repos/{repo}/issues/{n}/comments?per_page=100")
    own = next(
        (
            c
            for c in comments
            if (c.get("user") or {}).get("login") == OLLIE_LOGIN
            and (c.get("body") or "").startswith(MARKER)
        ),
        None,
    )
    body = comment_body(d)
    if own and own.get("body") != body:
        actions.append(
            ("PATCH", f"repos/{repo}/issues/comments/{own['id']}", {"body": body})
        )
    elif not own and want is not None:
        actions.append(("POST", f"repos/{repo}/issues/{n}/comments", {"body": body}))
    for method, path, data in actions:
        if dry:
            continue
        gh("-X", method, path, data=data)
    verb = "would" if dry else "did"
    summary = (
        ", ".join(
            f"{m} {p.split(f'/{n}/')[-1] if f'/{n}/' in p else 'comment'}"
            for m, p, _ in actions
        )
        or "nothing"
    )
    return f"{repo}#{n}: {want or 'none'} ({verb}: {summary})"


def sweep_repo(
    repo: str, dry: bool, first_pr: str = "", refusal: str = ""
) -> tuple[list[dict], int]:
    """Returns (per-PR results, number of PRs or reads that failed)."""
    try:
        prs = open_prs(repo)
        if first_pr:
            prs.sort(key=lambda p: 0 if str(p["number"]) == first_pr else 1)
        if prs:
            ensure_labels(repo, dry)
    except RuntimeError as e:
        print(f"::error::{repo}: {e}")
        return [], 1
    now = datetime.now(timezone.utc)
    results, failed = [], 0
    for pr in prs:
        try:
            f = facts(repo, pr, refusal if str(pr["number"]) == first_pr else "")
            d = decide(f, now)
            print(apply(repo, f, d, dry))
            results.append({"repo": repo, "number": pr["number"], "state": d["state"]})
        except RuntimeError as e:
            print(f"::error::{repo}#{pr['number']}: {e}")
            failed += 1
    return results, failed


def sync_outage_issue(outages: list[dict], dry: bool, complete: bool = True) -> None:
    found = (
        gh_json(
            f"repos/{OUTAGE_REPO}/issues?state=open&creator=ollie-the-intern%5Bbot%5D&per_page=100"
        )
        or []
    )
    issue = next((i for i in found if i.get("title") == OUTAGE_TITLE), None)
    if outages:
        lines = "\n".join(f"- {o['repo']}#{o['number']}" for o in outages)
        body = f"{MARKER}\nMargot's reviews are coming back from the fallback or erroring, so these PRs are held:\n\n{lines}\n\nOllie closes this issue when none are left."
        if dry:
            print(
                f"outage issue: would {'update' if issue else 'open'} ({len(outages)} PRs)"
            )
        elif issue:
            gh(
                "-X",
                "PATCH",
                f"repos/{OUTAGE_REPO}/issues/{issue['number']}",
                data={"body": body},
            )
        else:
            gh(
                f"repos/{OUTAGE_REPO}/issues",
                data={"title": OUTAGE_TITLE, "body": body, "assignees": [OPERATOR]},
            )
    elif issue and not complete:
        # A repo or PR could not be read, so an outage may be hiding there.
        print("outage issue: left open (the sweep did not read every PR)")
    elif issue:
        if dry:
            print("outage issue: would close")
        else:
            gh(
                "-X",
                "PATCH",
                f"repos/{OUTAGE_REPO}/issues/{issue['number']}",
                data={"state": "closed"},
            )


def enrolled(rulesets_file: str) -> list[str]:
    with open(rulesets_file, encoding="utf-8") as fh:
        return sorted(json.load(fh).get("repos", {}).keys())


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--repo", default="")
    ap.add_argument("--pr", default="")
    ap.add_argument("--refusal", default="")
    ap.add_argument("--estate", action="store_true")
    ap.add_argument("--rulesets-file", default="rulesets/default-branch.json")
    ap.add_argument("--dry-run", action="store_true")
    a = ap.parse_args()
    if a.estate:
        outages, failed = [], 0
        for repo in enrolled(a.rulesets_file):
            results, n = sweep_repo(repo, a.dry_run)
            outages += [r for r in results if r["state"] == "outage"]
            failed += n
        sync_outage_issue(outages, a.dry_run, complete=failed == 0)
        return 1 if failed else 0
    if not a.repo:
        ap.error("--repo or --estate is required")
    _, failed = sweep_repo(a.repo, a.dry_run, a.pr, a.refusal)
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
