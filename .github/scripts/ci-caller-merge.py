#!/usr/bin/env python3
"""ci-caller-merge.py -- bring a repo's ci.yml onto the floor-first shape, keeping
what is the repo's own.

The floor (operator, 2026-09-26): Jev classifies first; a mechanical PR runs the
mechanical suite and skips lint, tests and the council; a functional PR runs the
full floor once, then the council. One hosted job per PR for the floor itself.

What this does to a caller's ci.yml, as TEXT (the repo's own jobs and every
comment outside a replaced or deleted job survive unchanged, except that a run
of two or more blank lines anywhere collapses to one blank line; the file is
read only to find the job blocks -- no YAML parse; see the last paragraph):

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
    A job whose block carries the line `# floor: always-run` is not gated --
    the per-repo override for a check a mechanical PR can break; only a
    `needs:` naming `universal-ci` is renamed to `floor`. (A multi-line
    `needs:`/`if:` is refused for it too, like any job.)
  * the one exception to "every other job": a job that itself calls a
    reusable workflow (a job-level `uses:` line -- e.g. a caller's own
    `release-check`/`release-tag` delegating to `estate-plugin-release.yml`)
    is left otherwise alone: no rename, no gating. GitHub composes a called
    job's required-context name as `<calling job name> / <called job
    name>`; renaming the calling job from `ci` to `ci / release-check`
    would compose `ci / release-check / release-check`, breaking the
    required context `ci / release-check`. The reusable owns its own
    contract (its own `if:`/`needs:`, documented at its call site); this
    tool's job is the floor, not every caller into a different reusable.
    The one exception to THAT exception: a `needs:` naming the retired
    `universal-ci` job still becomes `floor` here too (passthrough_reusable,
    sharing rename_universal_ci_in_needs with the `# floor: always-run`
    shape below -- the same rule, the same reason: the file would otherwise
    depend on a job that no longer exists). `floor` is never ADDED, though,
    the way it is for an ordinary job's `needs:`: a reusable-calling job
    that never depended on `universal-ci` keeps not depending on `floor`
    either.
  * `all-checks-passed` (job id; check `ci / all-passed`): DELETED. Every
    repo runs the same shape (operator, 2026-09-27: one universal CI, no
    public/private split): the ruleset requires `ci / checks` and each of the
    repo's own `ci / <job>` checks directly. A job the floor skips on a
    mechanical PR reports skipped, which satisfies a required check; a floor
    that fails fails `ci / checks`, so nothing it skipped can let a PR through.

Usage: ci-caller-merge.py --ref v1 [--in ci.yml]        # merged YAML on stdout
Exit codes:
  0  merged YAML on stdout
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
    # The required check is `ci / checks`: this job's name, then the called
    # job's (estate-ci.yml's check_name). Convention `<lane> / <what it checks>`.
    name: ci
    # Read scopes the floor uses with github.token (Jev's triage answer on the
    # head's check-runs). A called workflow gets no more than this; on a
    # private repo the triage read 403s without it and the PR runs the full
    # suite. No write scope, no secret: this is the lane a PR controls.
    permissions:
      contents: read
      pull-requests: read
      checks: read
    uses: lexijamesesq/dotty/.github/workflows/estate-ci.yml@{ref}
    with:
      dotty_ref: {ref}
      check_name: checks
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
    whenever this block is replaced or deleted (the floor, the aggregator). It is re-emitted
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


def rename_universal_ci_in_needs(block):
    """Rewrite ONLY a `needs:` naming the retired `universal-ci` job to
    `floor` -- never adding `floor` to a `needs:` that doesn't already
    depend on it, and never touching `name:`/`if:`. Shared by the two
    shapes that otherwise leave a job alone (an `# floor: always-run` job
    in gate_job, a reusable-calling job in passthrough_reusable): both
    must still not leave the file depending on a job that no longer
    exists, without applying rewrite_needs' OTHER rule (every job gets
    `floor` even if it never asked for it) to a job that was deliberately
    left alone."""
    out = []
    for line in block:
        m = NEEDS_RE.match(line)
        if m and "universal-ci" in m.group(2):
            items = [x.strip() for x in m.group(2).strip("[]").split(",") if x.strip()]
            items = ["floor" if x == "universal-ci" else x for x in items]
            line = f"{m.group(1)}[{', '.join(items)}]"
        out.append(line)
    return out


NAME_RE = re.compile(r"^    name:")
JOB_KEY_RE = re.compile(r"^  ([A-Za-z0-9_-]+):")
# Job-level `uses:`, exactly 4 spaces in -- the shape a job takes to call a
# reusable workflow (`jobs.<id>.uses:`). A STEP's `uses:` (inside `steps:`)
# is a list item, always deeper and dashed (`      - uses: ...`), so this
# never matches one of those.
JOB_USES_RE = re.compile(r"^    uses:\s")


def calls_reusable(block):
    """True if this job itself calls a reusable workflow -- the one shape
    this tool never rewrites (see the module docstring's "one exception")."""
    return any(JOB_USES_RE.match(line) for line in block)


def passthrough_reusable(block):
    """A job that calls a reusable workflow is left untouched -- EXCEPT a
    `needs:` naming the retired `universal-ci` job still becomes `floor`,
    same as every other job (module docstring): the file would otherwise
    depend on a job that no longer exists and GitHub would reject the whole
    workflow. Shares refuse_multiline and rename_universal_ci_in_needs with
    gate_job's identical `# floor: always-run` shape (rename, don't gate,
    don't add `floor` if it isn't already depended on) -- this function is
    just that shape minus the final `with_ci_name` rename gate_job still
    applies there, because a reusable-calling job's `name:` is never ours
    to rename (see calls_reusable's docstring on the required-context
    composition this would otherwise break).
    """
    refuse_multiline(block)
    return rename_universal_ci_in_needs(block)


def job_id(key_line):
    """The job id from its key line -- never the raw line: `  tests:  # note`
    must name the job `ci / tests`, not `ci / tests:  # note`."""
    return JOB_KEY_RE.match(key_line).group(1)


def with_ci_name(block, name):
    """Give a job the check name `name` (convention `<lane> / <what>`): an
    existing `name:` line is replaced, else one goes right after the job key.
    The job id is untouched, so every `needs:` and output keeps working."""
    line = f"    name: {name}"
    out = [line if NAME_RE.match(x) else x for x in block]
    if not any(NAME_RE.match(x) for x in block):
        out = out[:1] + [line] + out[1:]
    return out


def refuse_multiline(block):
    """Exit 1 on a `needs:`/`if:` whose value is not on its own line (a block
    list, a folded or literal scalar) -- a line edit would leave the old items
    dangling below the rewritten line. Every rewritten job goes through this."""
    for line in block:
        if re.match(r"^    (needs|if):\s*([>|]-?\s*)?$", line):
            refuse(
                f"job {block[0].strip()} has a multi-line `needs:`/`if:` "
                "-- not a shape this tool rewrites; edit by hand"
            )


ALWAYS_RUN = "# floor: always-run"


def gate_job(block):
    """Add floor to needs and the mechanical clause to if, for one job block.

    Refuses (exit 1) the shapes a line-based edit would mangle: a `needs:` or
    `if:` whose value is not on the same line (a block list, a folded or
    literal scalar). Those callers are edited by hand, not silently rewritten.
    """
    refuse_multiline(block)
    # The per-repo override: a job carrying `# floor: always-run` is not
    # gated on the floor and runs on mechanical PRs too.
    # For a cheap correctness gate that a mechanical change can still break
    # (a plugin repo's release-check: a Renovate bump inside a plugin must
    # still bump the plugin's version -- Margot on core-skills #114).
    if any(line.strip() == ALWAYS_RUN for line in block):
        # Not gated -- but a `needs:` naming the retired `universal-ci` job
        # still becomes `floor` (rename_universal_ci_in_needs, shared with
        # passthrough_reusable's identical rule), or the file would depend
        # on a job that no longer exists and GitHub would reject the whole
        # workflow.
        out = rename_universal_ci_in_needs(block)
        return with_ci_name(out, "ci / " + job_id(block[0]))
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
    return with_ci_name(out, "ci / " + job_id(block[0]))


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
            # deleted: the ruleset requires each job's own check directly
            out.extend(trailing)
        elif calls_reusable(block):
            # the one exception (see the module docstring): a job that itself
            # calls a reusable workflow owns its own name/needs/if contract.
            # Not re-emitted through gate_job -- but a `needs:` naming the
            # retired `universal-ci` still becomes `floor` (passthrough_reusable),
            # the one rewrite every job gets regardless of shape.
            out.extend(passthrough_reusable(block))
            out.extend(trailing)
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
    return result


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--ref", required=True)
    ap.add_argument("--in", dest="inp", default="-")
    a = ap.parse_args()
    text = sys.stdin.read() if a.inp == "-" else open(a.inp, encoding="utf-8").read()
    sys.stdout.write(merge(text, a.ref))


if __name__ == "__main__":
    main()
