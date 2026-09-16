"""codeowners-drift.py — the CODEOWNERS coverage matcher for one repository.

The estate un-inverted CODEOWNERS: from default-OWNED (a `* @owner` catch-all
plus a small ownerless doc appendix) to default-UNOWNED plus an owned allow-list
of safety paths. This script is the CHECK for that new model: it decides whether
every path the policy insists a human must review is, in fact, owned by the
owner in a repo's live CODEOWNERS — resolved against the repo's REAL file tree,
not by string-comparing patterns (a later, broader, differently-worded ownerless
line could clear an owned path, and only real last-match-wins resolution catches
that).

It accepts BOTH the new owned-only files and the OLD inverted files during the
transition: over-coverage (a `* @owner` catch-all, or extra owned lines) is
never drift, so an old file's catch-all owns every required path and passes.

Usage: read a single JSON object on stdin, write a single JSON verdict object on
stdout. No arguments, no external dependencies (stdlib only).

Input object keys:
  owner          str   the owner token every required-owned path must resolve to
  required_owned list  shared owned patterns (owned in every repo where present)
  repo_owned     list  this repo's own owned patterns
  full_owned     bool  true only for a deliberately fully-owned repo (dotty-
                       private): every path must be owned, so the `*` catch-all
                       is REQUIRED
  paths          list  every real blob path in the repo, no leading slash
  codeowners     str   the repo's .github/CODEOWNERS text, or null if absent

Output object: {"verdict": "OK"|"DRIFT"|"SKIP", "message": "..."}
  OK    every required-owned real path resolves to the owner (over-coverage safe)
  DRIFT a required-owned real path is unowned, or a full_owned repo lacks the
        catch-all, or there is no CODEOWNERS file at all
  SKIP  the tree is empty/unavailable — never counted clean

CODEOWNERS matching semantics (GitHub, implemented exactly): gitignore-style
globs; the LAST matching pattern wins (not most-specific); NO negation (`!`);
CASE-SENSITIVE; a trailing `/` matches that directory recursively; `*` does NOT
cross `/`; a leading `/` anchors to the repo root; a bare name matches at any
depth; a line with a pattern and no owner token clears ownership for its matches.
"""

import json
import re
import sys

# How many offending paths a DRIFT message names before it summarizes the rest.
_MAX_NAMED = 8


def tokenize(line):
    """Split a CODEOWNERS line into whitespace-separated tokens, honoring a
    backslash-escaped space inside a pattern (e.g. `/UX\\ Bugs/`). The escaped
    space is kept as a literal space in the token, so the pattern round-trips."""
    tokens = []
    cur = []
    i = 0
    n = len(line)
    while i < n:
        c = line[i]
        if c == "\\" and i + 1 < n and line[i + 1] in (" ", "\t"):
            cur.append(line[i + 1])
            i += 2
            continue
        if c in (" ", "\t"):
            if cur:
                tokens.append("".join(cur))
                cur = []
            i += 1
            continue
        cur.append(c)
        i += 1
    if cur:
        tokens.append("".join(cur))
    return tokens


def parse_rules(text):
    """Ordered list of (pattern, owners) rules from CODEOWNERS text. `owners` is
    a possibly-empty list; empty means the line clears ownership for its matches.
    Comments (`#`) and blank lines are dropped."""
    rules = []
    for raw in text.splitlines():
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        tokens = tokenize(line)
        if not tokens:
            continue
        rules.append((tokens[0], tokens[1:]))
    return rules


def _translate(core):
    """Translate a glob body (anchoring and dir handling stripped by the caller)
    to a regex fragment: `**` crosses `/`, `*` does not, `?` is one non-`/`
    char, everything else is a literal."""
    out = []
    i = 0
    n = len(core)
    while i < n:
        c = core[i]
        if c == "*":
            if i + 1 < n and core[i + 1] == "*":
                # `**` crosses `/`. A `**/` segment means zero-or-more
                # directories, so `a/**/b` must ALSO match `a/b` (zero
                # intervening dirs): collapse `**/` with its trailing slash to
                # an optional path prefix. A bare/trailing `**` stays `.*`.
                if i + 2 < n and core[i + 2] == "/":
                    out.append("(?:.*/)?")
                    i += 3
                    continue
                out.append(".*")
                i += 2
                continue
            out.append("[^/]*")
            i += 1
            continue
        if c == "?":
            out.append("[^/]")
            i += 1
            continue
        out.append(re.escape(c))
        i += 1
    return "".join(out)


def compile_pattern(pattern):
    """Compile a CODEOWNERS pattern into a regex that matches a repo-root-
    relative file path (no leading slash). A declared pattern may still carry a
    CODEOWNERS-escaped space (`\\ `); unescape it to a literal space so declared
    patterns and CODEOWNERS-content patterns (already unescaped by `tokenize`)
    resolve against real paths identically."""
    pattern = pattern.replace("\\ ", " ").replace("\\\t", "\t")
    dir_only = pattern.endswith("/")
    core = pattern[:-1] if dir_only else pattern
    anchored = False
    if core.startswith("/"):
        anchored = True
        core = core[1:]
    elif "/" in core:
        # A slash anywhere but the trailing position anchors to the root.
        anchored = True
    body = _translate(core)
    prefix = "^" if anchored else "^(?:.*/)?"
    # dir_only matches only paths strictly under the directory; a plain pattern
    # matches the path itself OR anything under it (a matched directory owns its
    # contents), exactly as gitignore/CODEOWNERS resolves.
    suffix = "/.*$" if dir_only else "(?:/.*)?$"
    return re.compile(prefix + body + suffix)


def effective_owners(path, compiled_rules):
    """Resolve `path` by real last-match-wins over the compiled rules. Returns
    the owner list of the last matching rule, or [] if none matched."""
    result = []
    for regex, owners in compiled_rules:
        if regex.match(path):
            result = owners
    return result


def matched_paths(pattern, paths):
    """The real paths a single owned pattern covers (may be empty — a pattern
    matching zero real files contributes nothing, never drift)."""
    regex = compile_pattern(pattern)
    return [p for p in paths if regex.match(p)]


def _unowned_message(owner, paths, label):
    shown = paths[:_MAX_NAMED]
    listed = ", ".join(shown)
    extra = len(paths) - len(shown)
    if extra > 0:
        listed += f" (+{extra} more)"
    return f"{label}(s) not owned by {owner}: {listed}"


def evaluate(data):
    """Return (verdict, message) for one repo's CODEOWNERS state."""
    owner = data["owner"]
    required = data.get("required_owned") or []
    repo_owned = data.get("repo_owned") or []
    full_owned = bool(data.get("full_owned"))
    paths = data.get("paths") or []
    text = data.get("codeowners")

    if not paths:
        return "SKIP", "repo tree empty or unavailable — CODEOWNERS not verifiable"

    if text is None or not text.strip():
        return (
            "DRIFT",
            "no .github/CODEOWNERS file (a default-unowned repo needs the owned allow-list)",
        )

    rules = parse_rules(text)
    compiled = [(compile_pattern(p), o) for p, o in rules]

    if full_owned:
        # A deliberately full-owned repo REQUIRES the catch-all present, and
        # every real path must resolve to the owner (a later ownerless line
        # clearing anything is drift).
        has_catch_all = any(p == "*" and owner in o for p, o in rules)
        if not has_catch_all:
            return (
                "DRIFT",
                f"full-owned repo missing the '* {owner}' catch-all (every path must be owned)",
            )
        unowned = sorted(
            p for p in paths if owner not in effective_owners(p, compiled)
        )
        if unowned:
            return "DRIFT", _unowned_message(owner, unowned, "path")
        return (
            "OK",
            f"full-owned: '* {owner}' catch-all present; all {len(paths)} path(s) owned",
        )

    # Default-unowned model: resolve the union of the required patterns to the
    # concrete real paths they cover, then assert each is effectively owned.
    req_patterns = list(dict.fromkeys(required + repo_owned))
    req_paths = set()
    for pat in req_patterns:
        req_paths.update(matched_paths(pat, paths))

    if not req_paths:
        return "OK", "no required-owned paths present in the tree (nothing to own)"

    unowned = sorted(
        p for p in req_paths if owner not in effective_owners(p, compiled)
    )
    if unowned:
        return "DRIFT", _unowned_message(owner, unowned, "required-owned path")
    return (
        "OK",
        f"{len(req_paths)} required-owned path(s), all owned by {owner}",
    )


def main():
    try:
        data = json.load(sys.stdin)
    except (json.JSONDecodeError, ValueError):
        print(json.dumps({"verdict": "SKIP", "message": "matcher received no/invalid input"}))
        return
    verdict, message = evaluate(data)
    print(json.dumps({"verdict": verdict, "message": message}))


if __name__ == "__main__":
    main()
