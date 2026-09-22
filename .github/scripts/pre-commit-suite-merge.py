"""pre-commit-suite-merge.py — by-line/additive ownership of a caller's
`.pre-commit-config.yaml`.

The estate's pre-commit gate proved a standard suite on dotty itself in PR
#310: dotty's own remote hooks (gitleaks-*, house-code, house-scaffold-*,
vale-self-narration), upstream pre-commit-hooks, shellcheck, and the four
tools #310 added (ruff/ruff-format, shfmt, yamllint, markdownlint). This
script is the CONVERGENCE for rolling that suite out uniformly: it ENSURES
every required hook id is present, ADDING whatever is missing, and otherwise
touches nothing.

This is deliberately NOT a whole-file template compare (an earlier version of
this capability was; superseded on direction after an audit found the whole-
file model would silently destroy real per-repo content). Two things a caller
repo's own `.pre-commit-config.yaml` legitimately carries, which this script
must never touch:

  * `rev:` pins. Renovate owns bumping them (the repo's `default.json` preset
    enrolls the `pre-commit` manager for exactly this); this script only ever
    WRITES a `rev:` when a repo: block does not exist yet at all, so Renovate
    has something to bump going forward. An existing `rev:` is read only to
    locate a block, never rewritten.
  * `repo: local` blocks — a repo's own hooks (`check-file-presence`,
    `track-list-guard`, `network-rule-fixtures`, or a private repo's own
    gitleaks/operator-rules mechanism). This script only recognizes blocks by
    an EXACT `repo:` URL match against its own required list; a `repo: local`
    block, or any repo: URL not in that list, is never inspected or moved.

Line-based, not a full YAML parse — the same idiom this repo already uses
elsewhere (extract_uses_ref, repin_content, precommit-pin-lag's awk scan) for
this same file shape, on principle: a generic YAML round-trip would reformat
untouched content (quote style, key order, comment placement) as a side
effect, which is a worse failure mode here than a narrow scanner that
under-recognizes an unusual shape and leaves it alone. Every insertion is
plain YAML text matching this file's own established indentation (2-space
`- repo:`, 4-space `rev:`/`hooks:`, 6-space `- id:`), never a generic dumper.

Per-repo overrides live in ONE constant, EXCLUDED_HOOKS_BY_REPO: a slug's
excluded (repo url, hook id) pairs are hooks this script must never add for
that repo, because the repo's own config already covers the same ground a
different way. Today's one entry: lexijamesesq/dotty-private already runs its
own operator-rules gitleaks (see its own .pre-commit-config.yaml header) —
adding dotty's remote gitleaks-staged/-pre-push/-commit-msg there would not
strip that mechanism, but it WOULD run two competing secret scanners, which
is not this script's call to make.

Usage: read a single JSON object on stdin, write a single JSON verdict object
on stdout. No arguments, no external dependencies (stdlib only) — matches
codeowners-drift.py's contract in this same directory.

Input object keys:
  repo_slug  str        the target repo, e.g. "lexijamesesq/core-skills"
  content    str | null the repo's current .pre-commit-config.yaml text, or
                        null if the repo carries none at all (nothing to do
                        — the caller decides whether an empty-appendix repo
                        adopts the suite; this script is never the one that
                        invents the file from nothing)
  dotty_rev  str         dotty's current release tag, used ONLY as the
                        starting rev if a repo's dotty: block does not exist
                        yet (home-assistant today) — an existing dotty: block
                        keeps whatever rev it already has

Output object:
  changed  bool         false when content was null, or already carried every
                        required hook
  content  str | null   the merged text (unchanged echo if changed is false),
                        or null if input content was null
  reasons  list[str]    one line per distinct change made, for the caller's
                        drift/PR-reason reporting; empty when changed is false
"""

import json
import sys

# --- The standard suite -----------------------------------------------------
# Each entry: (repo url, default rev for a brand-new block, [(hook id, extra
# YAML lines to attach under it)]). "extra lines" are inserted verbatim,
# already indented to sit under a hook id at 6-space indent (8-space for
# their own body) — used only where the hook's own upstream manifest does not
# already default to pre-commit-only (shfmt/yamllint/markdownlint; every
# dotty-published hook bakes its own correct `stages:` at the source, so
# those are always bare).
#
# "dotty_rev" as the literal default_rev value is a sentinel the merge
# resolves from the input's dotty_rev field, never a real pin.
REQUIRED_BLOCKS = [
    (
        "https://github.com/lexijamesesq/dotty",
        "dotty_rev",
        [
            ("gitleaks-staged", []),
            ("gitleaks-pre-push", []),
            ("gitleaks-commit-msg", []),
            ("house-code", []),
            ("house-scaffold-no-tracked-scratch", []),
            ("house-scaffold-sample-shape", []),
            ("house-scaffold-sample-placeholder", []),
            ("vale-self-narration", []),
        ],
    ),
    (
        "https://github.com/pre-commit/pre-commit-hooks",
        "v6.0.0",
        [
            ("check-yaml", []),
            ("check-json", []),
            ("end-of-file-fixer", []),
            ("trailing-whitespace", []),
        ],
    ),
    (
        "https://github.com/shellcheck-py/shellcheck-py",
        "v0.10.0.1",
        [("shellcheck", [])],
    ),
    (
        "https://github.com/astral-sh/ruff-pre-commit",
        "v0.16.5",
        [("ruff", []), ("ruff-format", [])],
    ),
    (
        "https://github.com/scop/pre-commit-shfmt",
        "v3.14.1-1",
        [("shfmt", ["        stages: [pre-commit]"])],
    ),
    (
        "https://github.com/adrienverge/yamllint",
        "v1.38.0",
        [("yamllint", ["        stages: [pre-commit]"])],
    ),
    (
        "https://github.com/igorshubovych/markdownlint-cli",
        "v0.49.1",
        [("markdownlint", ["        stages: [pre-commit]"])],
    ),
]

# Hook ids that, when newly added (block created OR inserted into an
# existing block), require their stage present in default_install_hook_types
# — the git-hook-TYPE install list — or the hook is declared but never runs.
# The hook's own `stages:` (baked in at dotty's .pre-commit-hooks.yaml)
# controls WHEN it fires once installed; this controls whether the git hook
# script that would fire it is installed AT ALL by a bare `pre-commit
# install`. Both are required; neither substitutes for the other.
STAGE_NEEDED_BY_HOOK = {
    "gitleaks-pre-push": "pre-push",
    "gitleaks-commit-msg": "commit-msg",
}
# Canonical order for default_install_hook_types — matches every existing
# caller's own convention ([pre-commit, pre-push, commit-msg]), not an
# arbitrary sort.
STAGE_CANONICAL_ORDER = ["pre-commit", "pre-push", "commit-msg"]

# Per-repo exclusions: hooks this script must never add for that repo,
# because the repo's own config already covers the same ground a different,
# deliberate way. See the module docstring for why.
EXCLUDED_HOOKS_BY_REPO = {
    "lexijamesesq/dotty-private": {
        ("https://github.com/lexijamesesq/dotty", "gitleaks-staged"),
        ("https://github.com/lexijamesesq/dotty", "gitleaks-pre-push"),
        ("https://github.com/lexijamesesq/dotty", "gitleaks-commit-msg"),
    },
}

BLOCK_RE_PREFIX = "  - repo: "


def _find_blocks(lines):
    """Return {url: (start, end)} for every `  - repo: <url>` block, where
    `end` is the index of the next such line (any url, including `local`) or
    len(lines). `local` blocks are returned too, keyed "local", so callers
    that only ever look up a REQUIRED_BLOCKS url never touch them — but a
    `repo: local` line still correctly terminates the PRECEDING block."""
    starts = []
    for i, line in enumerate(lines):
        if line.startswith(BLOCK_RE_PREFIX):
            url = line[len(BLOCK_RE_PREFIX) :].strip()
            starts.append((url, i))
    blocks = {}
    for idx, (url, start) in enumerate(starts):
        end = starts[idx + 1][1] if idx + 1 < len(starts) else len(lines)
        # First match wins if a url somehow repeats (should not happen in a
        # valid file); never overwritten by a later duplicate.
        blocks.setdefault(url, (start, end))
    return blocks


def _last_content_line(lines, start, end):
    """Index of the last non-blank line in [start, end) — where a new hook
    id line is inserted, so it lands inside the block and before any blank
    line separating it from the next block, rather than after."""
    j = end - 1
    while j >= start and lines[j].strip() == "":
        j -= 1
    return j


def _hook_present(lines, start, end, hook_id):
    needle = f"- id: {hook_id}"
    return any(needle in lines[i] for i in range(start, end))


def merge(repo_slug, content, dotty_rev):
    if content is None:
        return False, None, []

    had_trailing_newline = content.endswith("\n")
    lines = content[:-1].split("\n") if had_trailing_newline else content.split("\n")

    excluded = EXCLUDED_HOOKS_BY_REPO.get(repo_slug, set())
    reasons = []
    stages_needed = set()

    blocks = _find_blocks(lines)
    new_blocks_text = []  # whole new `- repo:` blocks appended at the end

    # Track index shifts as we insert into existing blocks, in file order,
    # so later insertion points (computed against the ORIGINAL line
    # positions) still land correctly after earlier ones shifted the file.
    # Simplest correct approach: collect all existing-block insertions as
    # (line_index, [new_lines]) against the ORIGINAL indices, then apply
    # them in a single pass from the BOTTOM of the file upward, so an
    # earlier insertion's shift never invalidates a later one's index.
    pending_inserts = []  # (insert_at_original_index, [new_lines], reason)

    for url, default_rev, hooks in REQUIRED_BLOCKS:
        wanted = [
            (hook_id, extra)
            for hook_id, extra in hooks
            if (url, hook_id) not in excluded
        ]
        if not wanted:
            continue
        if url in blocks:
            start, end = blocks[url]
            missing = [
                (hook_id, extra)
                for hook_id, extra in wanted
                if not _hook_present(lines, start, end, hook_id)
            ]
            if not missing:
                continue
            insert_at = _last_content_line(lines, start, end) + 1
            new_lines = []
            for hook_id, extra in missing:
                new_lines.append(f"      - id: {hook_id}")
                new_lines.extend(extra)
                if hook_id in STAGE_NEEDED_BY_HOOK:
                    stages_needed.add(STAGE_NEEDED_BY_HOOK[hook_id])
            reason = (
                f".pre-commit-config.yaml: added missing hook(s) "
                f"{', '.join(h for h, _ in missing)} under the existing "
                f"{url} block (rev: line untouched — Renovate's lane)"
            )
            pending_inserts.append((insert_at, new_lines, reason))
        else:
            rev = dotty_rev if default_rev == "dotty_rev" else default_rev
            block_lines = [f"  - repo: {url}", f"    rev: {rev}", "    hooks:"]
            for hook_id, extra in wanted:
                block_lines.append(f"      - id: {hook_id}")
                block_lines.extend(extra)
                if hook_id in STAGE_NEEDED_BY_HOOK:
                    stages_needed.add(STAGE_NEEDED_BY_HOOK[hook_id])
            new_blocks_text.append(block_lines)
            reasons.append(
                f".pre-commit-config.yaml: added a new {url} block "
                f"({', '.join(h for h, _ in wanted)}) — not present at all before"
            )

    for _insert_at, _new_lines, reason in pending_inserts:
        reasons.append(reason)

    if not pending_inserts and not new_blocks_text:
        return False, content, []

    # Apply existing-block insertions bottom-up so indices stay valid.
    for insert_at, new_lines, _reason in sorted(
        pending_inserts, key=lambda t: t[0], reverse=True
    ):
        lines[insert_at:insert_at] = new_lines

    # Append brand-new blocks at the end of the file, each preceded by a
    # blank-line separator (this file's own convention between blocks).
    for block_lines in new_blocks_text:
        if lines and lines[-1].strip() != "":
            lines.append("")
        lines.extend(block_lines)

    # default_install_hook_types: extend or create, only for stages a newly
    # added hook actually needs and that are not already present. Never
    # touches default_stages (already [pre-commit] in every observed
    # caller) or any other existing value in the list.
    if stages_needed:
        idx = next(
            (
                i
                for i, l in enumerate(lines)
                if l.startswith("default_install_hook_types:")
            ),
            None,
        )
        if idx is not None:
            m_start = lines[idx].find("[")
            m_end = lines[idx].find("]")
            if m_start != -1 and m_end != -1:
                existing = [
                    v.strip()
                    for v in lines[idx][m_start + 1 : m_end].split(",")
                    if v.strip()
                ]
                added = [
                    s
                    for s in STAGE_CANONICAL_ORDER
                    if s in stages_needed and s not in existing
                ]
                if added:
                    merged_list = existing + added
                    lines[idx] = (
                        "default_install_hook_types: [" + ", ".join(merged_list) + "]"
                    )
                    reasons.append(
                        ".pre-commit-config.yaml: default_install_hook_types "
                        f"extended with {', '.join(added)} — a newly added hook "
                        "needs that stage installed or it never runs"
                    )
        else:
            # No such key at all (home-assistant's current shape): create it
            # right before default_stages if present, else at the top.
            canonical = [
                s
                for s in STAGE_CANONICAL_ORDER
                if s == "pre-commit" or s in stages_needed
            ]
            new_line = "default_install_hook_types: [" + ", ".join(canonical) + "]"
            ds_idx = next(
                (i for i, l in enumerate(lines) if l.startswith("default_stages:")),
                None,
            )
            at = ds_idx if ds_idx is not None else 0
            lines[at:at] = [new_line]
            reasons.append(
                ".pre-commit-config.yaml: added default_install_hook_types "
                f"[{', '.join(canonical)}] — this repo had none, and a newly "
                "added hook needs those stages installed to ever run"
            )

    new_content = "\n".join(lines) + ("\n" if had_trailing_newline else "")
    return True, new_content, reasons


def main():
    try:
        data = json.load(sys.stdin)
    except (json.JSONDecodeError, ValueError):
        print(json.dumps({"changed": False, "content": None, "reasons": []}))
        return
    changed, content, reasons = merge(
        data.get("repo_slug", ""), data.get("content"), data.get("dotty_rev", "")
    )
    print(json.dumps({"changed": changed, "content": content, "reasons": reasons}))


if __name__ == "__main__":
    main()
