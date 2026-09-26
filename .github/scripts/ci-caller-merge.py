#!/usr/bin/env python3
"""ci-caller-merge.py -- bring a repo's ci.yml onto the floor-first shape, keeping
what is the repo's own.

The floor (operator, 2026-09-26): Jev classifies first; a mechanical PR runs the
mechanical suite and skips lint, tests and the council; a functional PR runs the
full floor once, then the council. One hosted job per PR for the floor itself.

What this does to a caller's ci.yml, as TEXT (comments and the repo's own jobs
survive byte-for-byte; the file is parsed only to find the job blocks and to
prove the result is still valid YAML):

  * the `universal-ci` job becomes `floor`: `uses: .../estate-ci.yml@<ref>`,
    `with: dotty_ref: <ref>`, and NO secrets -- ci.yml runs in the
    `pull_request` context where a PR could redirect them; the trusted half of
    the floor (secrets, the hand-off to Margot) is gate.yml on
    `pull_request_target`. Whatever the old block carried is replaced.
  * every OTHER job (the repo's own: tests, release checks, extra linters) is
    gated on the floor so it does not run on a mechanical PR:
    `needs:` gains `floor` (renaming `universal-ci` where it was named), and
    `if:` becomes `${{ <existing> && needs.floor.outputs.mechanical != 'true' }}`
    (or just the mechanical clause when the job had no `if:`).
  * `all-checks-passed` (the aggregator that exists only so one required
    context covers every job): DELETED when the repo has no jobs of its own --
    the required context becomes the floor's own check (`floor / floor`).
    KEPT when the repo has its own jobs, with `needs:` renamed and its run
    step replaced by one that treats a job SKIPPED on a mechanical PR as
    satisfied (today's step fails on any skipped job, which would block every
    mechanical PR in such a repo).

Usage: ci-caller-merge.py --ref v1 [--in ci.yml]        # merged YAML on stdout
       ci-caller-merge.py --ref v1 [--in ci.yml] --plain-required
                                     # prints the required context this repo's
                                     # ruleset should carry
Exit codes:
  0  merged YAML on stdout (or the required context with --plain-required)
  1  REFUSED: a shape a line edit would mangle (a multi-line `needs:`/`if:`,
     both `universal-ci` and `floor` present). Message on stderr; edit by hand.
     The provisioner reports this as drift, never as a skip.
  2  NOT A CALLER: no `universal-ci`/`floor` job at all. The provisioner skips
     the file (nothing here is ours to own).

Stdlib only, like every script the provisioner runs with plain `python3`: the
result is not parsed as YAML here -- it is checked structurally (a `floor` job
must be present) and proven by actionlint and the eval suite, which parse it.
"""

import argparse
import re
import sys

EXIT_REFUSED = 1
EXIT_NOT_CALLER = 2


def refuse(msg, code=EXIT_REFUSED):
    print(f"ci-caller-merge: {msg}", file=sys.stderr)
    sys.exit(code)


FLOOR_BLOCK = """  floor:
    uses: lexijamesesq/dotty/.github/workflows/estate-ci.yml@{ref}
    with:
      dotty_ref: {ref}
"""

AGGREGATOR_RUN = """    steps:
      - name: Require every dependency to have succeeded (a job skipped on a mechanical PR is satisfied)
        env:
          RESULTS: ${{ toJSON(needs) }}
          MECHANICAL: ${{ needs.floor.outputs.mechanical }}
        run: |
          set -euo pipefail
          bad="$(jq -r --arg mech "$MECHANICAL" '
            to_entries[]
            | select(.value.result == "failure" or .value.result == "cancelled"
                     or (.value.result == "skipped" and $mech != "true"))
            | .key' <<<"$RESULTS")"
          if [[ -n "$bad" ]]; then
            echo "required job(s) not satisfied: $bad"
            exit 1
          fi
          echo "all checks passed (mechanical=${MECHANICAL:-false})"
"""

MECH_CLAUSE = "needs.floor.outputs.mechanical != 'true'"


def job_spans(lines):
    """[(name, start, end)] for each top-level job under `jobs:` (end exclusive)."""
    spans = []
    in_jobs = False
    start = None
    name = None
    for i, line in enumerate(lines):
        if not in_jobs:
            if re.match(r"^jobs:\s*(#.*)?$", line):
                in_jobs = True
            continue
        if re.match(r"^[^\s#]", line):  # a new top-level key ends the jobs map
            if name is not None:
                spans.append((name, start, i))
                name = None
            in_jobs = False
            continue
        m = re.match(r"^  ([A-Za-z0-9_-]+):\s*(#.*)?$", line)
        if m:
            if name is not None:
                spans.append((name, start, i))
            name, start = m.group(1), i
    if name is not None:
        spans.append((name, start, len(lines)))
    return spans


def trim_trailing_blank(block):
    """Split off a job block's trailing blank AND comment lines.

    A comment written above the NEXT job sits inside this job's span (a span
    ends at the next job key). Treating it as part of the block would delete it
    whenever this block is replaced (the floor, the aggregator). It is re-emitted
    in place, so the caller's prose survives byte-for-byte.
    """
    while block and (block[-1].strip() == "" or block[-1].lstrip().startswith("#")):
        block = block[:-1]
    return block


NEEDS_RE = re.compile(r"^(    needs:\s*)(.*?)\s*$")


def rewrite_needs(match):
    """One rule for every `needs:` line: universal-ci -> floor, floor first.

    Accepts `[a, b]`, a bare `a`, or an empty value (an empty value becomes
    `[floor]`, never `[floor, ]`).
    """
    val = match.group(2)
    if val.startswith("["):
        items = [x.strip() for x in val.strip("[]").split(",") if x.strip()]
    else:
        items = [val] if val else []
    items = ["floor" if x == "universal-ci" else x for x in items]
    if "floor" not in items:
        items.insert(0, "floor")
    return f"{match.group(1)}[{', '.join(items)}]"


def gate_job(block):
    """Add floor to needs and the mechanical clause to if, for one job block.

    Refuses (exit 1) the shapes a line-based edit would mangle: a `needs:` or
    `if:` whose value is not on the same line (a block list, a folded or
    literal scalar). Those callers are edited by hand, not silently rewritten.
    """
    for line in block:
        if re.match(r"^    (needs|if):\s*([>|]-?\s*)?$", line):
            refuse(
                f"job {block[0].strip()} has a multi-line `needs:`/`if:` "
                "-- not a shape this tool rewrites; edit by hand"
            )
    out = []
    has_needs = has_if = False
    for line in block:
        m = NEEDS_RE.match(line)
        if m:
            has_needs = True
            out.append(rewrite_needs(m))
            continue
        m = re.match(r"^(    if:\s*)(.*?)\s*$", line)
        if m:
            has_if = True
            cond = m.group(2)
            inner = re.sub(r"^\$\{\{\s*(.*?)\s*\}\}$", r"\1", cond).strip()
            if MECH_CLAUSE in inner:
                out.append(line)
            else:
                out.append(f"{m.group(1)}${{{{ ({inner}) && {MECH_CLAUSE} }}}}")
            continue
        out.append(line)
    # insert what was missing right after the job key line
    inserts = []
    if not has_needs:
        inserts.append("    needs: [floor]")
    if not has_if:
        inserts.append(f"    if: ${{{{ {MECH_CLAUSE} }}}}")
    if inserts:
        out = out[:1] + inserts + out[1:]
    return out


def rewrite_aggregator(block):
    """Rename universal-ci in needs, keep if: always(), replace the steps."""
    head = []
    for line in block:
        if re.match(r"^    steps:", line):
            break
        m = NEEDS_RE.match(line)
        head.append(rewrite_needs(m) if m else line)
    return head + AGGREGATOR_RUN.rstrip("\n").split("\n")


def merge(text, ref):
    lines = text.split("\n")
    spans = job_spans(lines)
    names = [n for n, _, _ in spans]
    core = (
        "universal-ci"
        if "universal-ci" in names
        else ("floor" if "floor" in names else None)
    )
    if core is None:
        refuse(
            "no universal-ci/floor job -- not a caller this tool owns",
            EXIT_NOT_CALLER,
        )
    if "universal-ci" in names and "floor" in names:
        refuse(
            "both `universal-ci` and `floor` jobs present -- ambiguous; edit by hand"
        )
    own = [n for n in names if n not in (core, "all-checks-passed")]
    out = []
    cursor = 0
    for name, start, end in spans:
        out.extend(lines[cursor:start])
        block = trim_trailing_blank(lines[start:end])
        trailing = lines[start + len(block) : end]
        if name == core:
            out.extend(FLOOR_BLOCK.format(ref=ref).rstrip("\n").split("\n"))
            out.extend(trailing)
        elif name == "all-checks-passed":
            if own:
                out.extend(rewrite_aggregator(block))
                out.extend(trailing)
            # else: deleted -- the floor's own check is the required context
        else:
            out.extend(gate_job(block))
            out.extend(trailing)
        cursor = end
    out.extend(lines[cursor:])
    result = "\n".join(out)
    result = re.sub(r"\n{3,}", "\n\n", result)
    if not result.endswith("\n"):
        result += "\n"
    # Structural check, stdlib only (see the module docstring): the result must
    # still carry a `floor` job at the top level of `jobs:`.
    if "floor" not in [n for n, _, _ in job_spans(result.split("\n"))]:
        refuse("result has no floor job (internal error)")
    return result, bool(own)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--ref", required=True)
    ap.add_argument("--in", dest="inp", default="-")
    ap.add_argument(
        "--plain-required",
        action="store_true",
        help="print the required context for this repo instead of the merged file",
    )
    a = ap.parse_args()
    text = sys.stdin.read() if a.inp == "-" else open(a.inp, encoding="utf-8").read()
    merged, has_own = merge(text, a.ref)
    if a.plain_required:
        print("all-checks-passed" if has_own else "floor / floor")
        return
    sys.stdout.write(merged)


if __name__ == "__main__":
    main()
