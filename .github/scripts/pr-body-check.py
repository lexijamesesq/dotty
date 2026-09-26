"""pr-body-check.py — the mechanical PR-body-template gate (CI, required).

Enforces the estate's pr-body:v1 template STRUCTURE on a pull request's body —
the last piece of the mechanical floor. A PR body's claims are the evidence a
reviewer (human or Margot) verifies, so a body must actually follow the template
rather than being empty, adhoc, or left with the template's own placeholder text.

Structural checks ONLY (content quality is judgment — Margot's / a later slice's
job, NEVER this gate's; a lazy "Not applicable — n/a" in every section passes):
  1. The marker `<!-- pr-body:v1 -->` is the FIRST line (author started from the
     template). A blank line before it is a distinct, named failure.
  2. Every required `##` heading from the template is present (extra headings are
     fine; a section that does not apply reads "Not applicable — <reason>" /
     "None — <reason>", which is content, not a missing heading).
  3. No template placeholder line survives verbatim (an untouched section).
  4. No duplicate heading (a copy-paste / merge artifact).

The required heading set AND the placeholder lines are derived from the committed
template itself (passed via --template), so the gate and the template can never
drift. Headings inside fenced code blocks (``` or ~~~) are ignored — an author
pasting a diff or another template as an example must not satisfy or trip a rule.
Lines are normalized (CRLF stripped, trailing whitespace trimmed) before compare.

The PR body is read from the event payload file ($GITHUB_EVENT_PATH), NOT a
step-level env var — a step env prints its value in the runner log header, and
author-controlled text has no reason to sit in a log (matches estate-gate.yml's
own handling). The body is DATA: parsed, never executed, never interpolated.

Exit 0 = body conforms (or event is not a pull_request — nothing to check);
1 = one or more structural failures (each printed); 2 = the check could not run.
"""

import json
import os
import re
import sys

MARKER = "<!-- pr-body:v1 -->"
HEADING_RE = re.compile(r"^##\s+(.+?)\s*$")
FENCE_RE = re.compile(r"^\s*(```|~~~)")
COMMENT_OPEN_RE = re.compile(r"<!--")
COMMENT_CLOSE_RE = re.compile(r"-->")


def norm_lines(text: str) -> list[str]:
    """Split into lines with CRLF normalized and trailing whitespace trimmed."""
    return [
        ln.rstrip() for ln in text.replace("\r\n", "\n").replace("\r", "\n").split("\n")
    ]


def headings(lines: list[str]) -> list[str]:
    """`##` heading texts that are real content, in order — OUTSIDE fenced code
    blocks AND outside HTML comment blocks. Both exclusions matter: a heading
    pasted as a fenced example is not a section, and a heading buried in an
    invisible `<!-- ... -->` comment renders as nothing on GitHub, so it must not
    count as "present" (that would let an all-comment body pass with no real
    sections). Fence and comment are treated as mutually-exclusive states so a
    `<!--` inside a fence, or a ``` inside a comment, stays literal."""
    out: list[str] = []
    in_fence = False
    in_comment = False
    for ln in lines:
        if in_comment:
            if COMMENT_CLOSE_RE.search(ln):
                in_comment = False
            continue
        if in_fence:
            if FENCE_RE.match(ln):
                in_fence = False
            continue
        if FENCE_RE.match(ln):
            in_fence = True
            continue
        if COMMENT_OPEN_RE.search(ln) and not COMMENT_CLOSE_RE.search(ln):
            in_comment = True
            continue
        if COMMENT_OPEN_RE.search(ln):  # single-line <!-- ... -->
            continue
        m = HEADING_RE.match(ln)
        if m:
            out.append(m.group(1).strip())
    return out


def template_spec(template_text: str) -> tuple[list[str], set[str]]:
    """Derive (required headings in order, placeholder lines) from the template.

    Placeholders are the template's non-empty content lines that are not the
    marker, not `##` headings, and not inside its top HTML comment block."""
    lines = norm_lines(template_text)
    req_headings = headings(lines)
    placeholders: set[str] = set()
    in_comment = False
    in_fence = False
    for ln in lines:
        if FENCE_RE.match(ln):
            in_fence = not in_fence
            continue
        if in_fence:
            continue
        stripped = ln.strip()
        if not stripped or stripped == MARKER:
            continue
        # Track (possibly multi-line) HTML comment blocks; skip their contents.
        if in_comment:
            if COMMENT_CLOSE_RE.search(ln):
                in_comment = False
            continue
        if COMMENT_OPEN_RE.search(ln) and not COMMENT_CLOSE_RE.search(ln):
            in_comment = True
            continue
        if COMMENT_OPEN_RE.search(ln):  # single-line comment
            continue
        if HEADING_RE.match(ln):
            continue
        placeholders.add(stripped)
    return req_headings, placeholders


def check(body: str, template_text: str) -> list[str]:
    req_headings, placeholders = template_spec(template_text)
    findings: list[str] = []
    lines = norm_lines(body)

    # 1. Marker is line 1.
    if not lines or not body.strip():
        return ["PR body is empty — start from the pr-body:v1 template."]
    if lines[0].strip() != MARKER:
        if MARKER in body:
            findings.append(
                f"marker `{MARKER}` must be the FIRST line "
                f"(found other content — e.g. a blank line — before it)."
            )
        else:
            findings.append(
                f"missing the `{MARKER}` marker as the first line "
                f"(the PR was not started from the template)."
            )

    body_headings = headings(lines)

    # 2. Every required heading present.
    present = set(body_headings)
    for h in req_headings:
        if h not in present:
            findings.append(f"missing required section heading: `## {h}`")

    # 3. No untouched placeholder survives verbatim.
    body_content = {ln.strip() for ln in lines if ln.strip()}
    for ph in sorted(placeholders & body_content):
        findings.append(
            f"untouched template placeholder — replace it with real "
            f'content (or "Not applicable — <reason>"): "{ph}"'
        )

    # 4. No duplicate heading.
    seen: set[str] = set()
    for h in body_headings:
        if h in seen:
            findings.append(f"duplicate section heading: `## {h}`")
        seen.add(h)

    return findings


def main() -> int:
    template_path = None
    args = sys.argv[1:]
    for i, a in enumerate(args):
        if a == "--template" and i + 1 < len(args):
            template_path = args[i + 1]
    if not template_path:
        print("pr-body-check: BLOCKED — --template <path> is required", file=sys.stderr)
        return 2

    event_path = os.environ.get("GITHUB_EVENT_PATH")
    if not event_path or not os.path.isfile(event_path):
        print(
            "pr-body-check: BLOCKED — GITHUB_EVENT_PATH not set/readable "
            "(refusing to skip a check we cannot run)",
            file=sys.stderr,
        )
        return 2
    try:
        with open(event_path, encoding="utf-8") as f:
            event = json.load(f)
    except (OSError, ValueError) as e:
        print(
            f"pr-body-check: BLOCKED — cannot read event payload: {e}", file=sys.stderr
        )
        return 2

    pr = event.get("pull_request")
    if not isinstance(pr, dict):
        # Not a pull_request event — nothing to check.
        return 0
    body = pr.get("body") or ""

    try:
        with open(template_path, encoding="utf-8") as f:
            template_text = f.read()
    except OSError as e:
        print(
            f"pr-body-check: BLOCKED — cannot read template {template_path}: {e}",
            file=sys.stderr,
        )
        return 2

    findings = check(body, template_text)
    if not findings:
        return 0
    print(
        "pr-body-check: PR body does not conform to the pr-body:v1 template:",
        file=sys.stderr,
    )
    for f_ in findings:
        print(f"  - {f_}", file=sys.stderr)
    print(
        "  See .github/pull_request_template.md. Body claims are evidence a "
        "reviewer verifies; the template's sections must be filled, not left as placeholders.",
        file=sys.stderr,
    )
    return 1


if __name__ == "__main__":
    sys.exit(main())
