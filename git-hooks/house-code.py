#!/usr/bin/env python3
"""
house-code.py — the four house-code pattern checks as a pre-commit hook.

Ported from publish-skills' qa.py (check_forbidden_patterns, load_roster_names)
so the same four rules run over EVERY tracked non-binary file type, on every
machine, at every commit — not markdown-only, not verb-only. qa.py keeps its
own copy of this logic for now — this hook is the single definition going
forward; qa.py's copy retires once the estate's reusable CI workflow makes
this hook's mirror a required check everywhere qa.py's copy currently gates
a merge.

Four rules, each {severity: HIGH, rule, file, count}. NEVER the matched text —
not just the roster-name class. A ticket id, a vault path, a §-reference
snippet, and a roster name are each treated as a private-pattern class for
this hook's OWN output, a stricter posture than qa.py's (which still prints
matched text at the verb layer) per this ticket's boundary: never print a
matched private pattern anywhere this hook's output reaches.

  ticket-id-leak                  — LEX/SYS/INST/INC/MAST/GOAL-<n> references
  vault-path-leak                 — a literal vault path, not the
                                     {workspace_root} placeholder form
  internal-section-reference-leak — a "§" reference to a non-shipping
                                     (vault-only) doc
  roster-name-leak                — a real person/employer name from the
                                     installed roster file

Exit 0 = clean. Exit 1 = one or more findings (printed to stderr, counts only).
Exit 2 = the hook itself could not run (fail-closed: never a silent pass).

Roster resolution: fixed path only, same discipline as
gitleaks-common.sh's gl_fixed_rules_path — an install-time path under
$HOME/.config (XDG_CONFIG_HOME-overridable, so tests isolate with their own
XDG_CONFIG_HOME rather than touching $HOME or reading the real file), never a
checkout-relative fallback. Missing or malformed -> BLOCK, never a silent skip
(same rationale qa.py's load_roster_names documents).

APPLICABILITY (rollout receipt: a broad "tests/fixtures are exempt" class
rule was built, then withdrawn — it enlarges the exact blind spot these
rules exist to close; a fixture is exactly where an LLM-authored literal
most plausibly leaks). Every rule below applies to EVERY tracked file,
tests and fixtures included, with only two narrow, explicit escapes:

  1. THIS detector's own fixtures — declared here, beside the rules, never
     guessed at by path shape. A test proving ticket-id-leak detection
     necessarily contains a real matching literal; that is this hook's own
     fixture, not a class of fixture. See _OWN_FIXTURES below. Every other
     repo's test fixtures either use synthetic, non-matching literals (the
     fix belongs in that fixture's content) or are that repo's OWN
     detector's fixtures, declared the same narrow way in that repo's
     `.house-code.json` (case 2).
  2. One declared file at the repo root, `.house-code.json` — read once,
     never searched for:
       {"private_repo": true,
        "exemptions": [{"path": "<repo-relative regex, anchored>",
                          "rule": "<rule-id>", "reason": "<why, required>"}]}
     `private_repo: true` is a claim this hook VERIFIES live against the
     repository's actual GitHub visibility (see verify_private_repo) before
     honoring it — a stale or wrong declaration never silently grants the
     profile, and a repo that flips to public loses it automatically, no
     second edit required. Verified-private disables vault-path-leak only
     (the operator's visibility policy: a private repo carries real
     infrastructure paths by design). ticket-id-leak, roster-name-leak, and
     internal-section-reference-leak stay active regardless of visibility —
     a real ticket-id or roster leak is never made acceptable by a repo
     being private. `exemptions` covers a true one-off: a specific rule
     against a specific, narrowly-targeted path (a single file, or one
     detector's own fixture directory), with a required reason. A cause
     that recurs across repos is a defect in this script, not a second
     declared entry — it gets fixed here instead.

--report prints, to stderr, every exemption (declared or the private-repo
profile) that actually suppressed a finding this run — file and finding
counts per entry, never the matched text — so growth is visible rather than
accumulating silently. Exit code is unaffected by --report.
"""

import argparse
import json
import os
import re
import subprocess
import sys
from pathlib import Path

TICKET_ID_RE = re.compile(r"\b(?:LEX|SYS|INST|INC|MAST|GOAL)-\d+\b")

VAULT_ABS_PATH_RE = re.compile(r"(?:/Users/[\w.-]+/Vaults/Notes|~/Vaults/Notes)[^\s)\]`,]*")
BARE_VAULT_DIR_RE = re.compile(
    r"(?<!\{workspace_root\}/)\b(?:System/Knowledge|System/Context|"
    r"Projects/[\w-]+/Knowledge|Projects/[\w-]+/Context|Wiki/Knowledge|Wiki/Contexts)\b"
)

# This hook's OWN fixtures — declared narrowly, beside the rules, never a
# path-shape guess. Exact repo-relative paths only; these exist only when
# this exact file is dotty itself (dogfooding), never coincide with another
# consumer's tree.
_OWN_FIXTURES = frozenset(
    {
        "git-hooks/house-code.py",
        ".claude/eval/house-code.test.sh",
        ".claude/eval/house-scaffold.test.sh",
    }
)

DECLARATION_FILENAME = ".house-code.json"


def load_declaration(repo_root: Path, override_path: Path | None = None) -> dict:
    """The one per-repo declaration file. Absent is the common case and not
    an error. Present-but-malformed IS an error — fail-closed, same
    discipline as the roster file: a declaration this hook can't parse must
    never be silently treated as "no exemptions declared", since that would
    also silently drop the private_repo claim this hook still needs to
    verify or refuse. override_path (tests only) still goes through every
    check below — a test-only entry point is not an excuse for a second,
    unvalidated read path."""
    path = override_path if override_path is not None else repo_root / DECLARATION_FILENAME
    if not path.is_file():
        return {}
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except (json.JSONDecodeError, OSError) as e:
        raise RuntimeError(f"{DECLARATION_FILENAME} exists but could not be read/parsed: {e}") from e
    if not isinstance(data, dict):
        raise TypeError(f"{DECLARATION_FILENAME} must be a JSON object at the top level.")
    for entry in data.get("exemptions", []):
        missing = [k for k in ("path", "rule", "reason") if not entry.get(k)]
        if missing:
            raise RuntimeError(
                f"{DECLARATION_FILENAME}: an exemptions entry is missing {missing} — "
                "path, rule, and reason are all required, no partial entries."
            )
    return data


def verify_private_repo(declared: bool) -> bool:
    """A `private_repo: true` declaration is a claim, never trusted blind.
    Verified live against GitHub's own record of this repo's visibility —
    `gh api repos/<owner>/<repo> --jq .visibility` — so a repo that flips
    to public loses the profile the moment this hook next runs, with no
    second edit anywhere. Any failure to verify (no network, no `gh`, no
    auth, a timeout, an unexpected answer) resolves to NOT private — the
    safe direction: uncertain means treat as public, never silently grant
    the relaxation.
    """
    if not declared:
        return False
    try:
        remote = subprocess.run(
            ["git", "remote", "get-url", "origin"],
            capture_output=True, text=True, timeout=5, check=True,
        ).stdout.strip()
    except (subprocess.SubprocessError, OSError):
        return False
    m = re.search(r"[:/]([^/:]+)/([^/]+?)(?:\.git)?$", remote)
    if not m:
        return False
    owner, repo = m.group(1), m.group(2)
    try:
        result = subprocess.run(
            ["gh", "api", f"repos/{owner}/{repo}", "--jq", ".visibility"],
            capture_output=True, text=True, timeout=10, check=True,
        )
    except (subprocess.SubprocessError, OSError):
        return False
    return result.stdout.strip() == "private"


# Count-floor (F1, ported from qa.py): a roster section parsing below this was
# almost certainly reformatted/truncated. Modest because this also runs
# against small test fixtures; the real roster carries far more.
ROSTER_MIN_NAMES = 2


def fixed_rosters_path() -> Path:
    """Install-time path for the real roster file. Never a checkout-relative
    fallback — see module docstring."""
    xdg = os.environ.get("XDG_CONFIG_HOME") or str(Path.home() / ".config")
    return Path(xdg) / "estate" / "tag-taxonomy-rosters.md"


def load_roster_names(path: Path) -> list[str]:
    """Real person/employer names, read at runtime from the installed rosters
    file — never hardcoded here. Fail-loud if the file is missing or its
    shape looks truncated: a roster-name-leak check that silently no-ops
    because its data source vanished is worse than no check at all.
    (Ported verbatim from qa.py's load_roster_names.)"""
    if not path.exists():
        raise RuntimeError(
            f"tag-taxonomy-rosters.md not found at {path} — required for the "
            "roster-name-leak check (fail-closed)."
        )
    text = path.read_text(encoding="utf-8")
    names: list[str] = []
    for label in ("Current roster", "Current employers"):
        m = re.search(re.escape(label) + r"[^\n]*:[^\S\n]*([^\n]+)", text)
        if not m:
            raise RuntimeError(
                f"tag-taxonomy-rosters.md: '{label} ...:' line missing or reformatted "
                f"off its own line — the roster-name-leak check would silently under-read. "
                f"Restore the single comma-joined line."
            )
        section = [
            tok.strip().rstrip(".")
            for tok in re.split(r",\s*", m.group(1))
            if tok.strip().rstrip(".")
        ]
        if len(section) < ROSTER_MIN_NAMES:
            raise RuntimeError(
                f"tag-taxonomy-rosters.md: '{label} ...:' parsed to only {len(section)} "
                f"value(s) (floor {ROSTER_MIN_NAMES}) — the line was likely reformatted/"
                f"truncated; the roster-name-leak check would silently under-read. "
                f"Restore the single comma-joined line."
            )
        names.extend(section)
    return names


def make_finding(rule: str, file_rel: str, count: int) -> dict:
    # NEVER a matched literal here — rule id, file, count only.
    return {"rule": rule, "file": file_rel, "count": count}


class Exemptions:
    """Resolves whether a (rule, file) is exempt, and tracks what actually
    got used — for --report. Three sources, checked in order: this hook's
    own fixtures (hardcoded), the verified private-repo profile
    (vault-path-leak only), and the repo's declared one-offs (regex path,
    exact rule)."""

    def __init__(self, private_repo_verified: bool, declared_exemptions: list[dict]):
        self.private_repo_verified = private_repo_verified
        self.declared = [
            {**e, "_re": re.compile(e["path"])} for e in declared_exemptions
        ]
        # entry index -> {"files": set(), "findings": int}
        self.declared_usage: list[dict] = [{"files": set(), "findings": 0} for _ in self.declared]
        self.private_repo_usage = {"files": set(), "findings": 0}
        self.own_fixture_usage = {"files": set(), "findings": 0}

    def resolve(self, rule: str, rel: str, count: int) -> bool:
        """Returns True if this (rule, file) finding is suppressed, and
        records the usage against whichever source suppressed it."""
        if rel in _OWN_FIXTURES:
            self.own_fixture_usage["files"].add(rel)
            self.own_fixture_usage["findings"] += count
            return True
        if rule == "vault-path-leak" and self.private_repo_verified:
            self.private_repo_usage["files"].add(rel)
            self.private_repo_usage["findings"] += count
            return True
        for i, entry in enumerate(self.declared):
            if entry["rule"] == rule and entry["_re"].fullmatch(rel):
                self.declared_usage[i]["files"].add(rel)
                self.declared_usage[i]["findings"] += count
                return True
        return False

    def report(self) -> None:
        print("house-code --report: exemptions applied this run (files / findings suppressed):", file=sys.stderr)
        if self.own_fixture_usage["findings"]:
            print(
                f"  [this hook's own fixtures] {len(self.own_fixture_usage['files'])} file(s), "
                f"{self.own_fixture_usage['findings']} finding(s)",
                file=sys.stderr,
            )
        if self.private_repo_usage["findings"]:
            print(
                f"  [private_repo profile, verified live] vault-path-leak: "
                f"{len(self.private_repo_usage['files'])} file(s), {self.private_repo_usage['findings']} finding(s)",
                file=sys.stderr,
            )
        for entry, usage in zip(self.declared, self.declared_usage):
            if usage["findings"]:
                print(
                    f"  [{entry['rule']}] {entry['path']!r} — {entry['reason']} "
                    f"({len(usage['files'])} file(s), {usage['findings']} finding(s))",
                    file=sys.stderr,
                )
            else:
                print(
                    f"  [{entry['rule']}] {entry['path']!r} — declared but matched NOTHING this run "
                    "(stale entry? consider removing it)",
                    file=sys.stderr,
                )


def check_file(rel: str, text: str, roster_names: list[str], exemptions: Exemptions) -> list[dict]:
    findings: list[dict] = []

    ids = set(TICKET_ID_RE.findall(text))
    if ids and not exemptions.resolve("ticket-id-leak", rel, len(ids)):
        findings.append(make_finding("ticket-id-leak", rel, len(ids)))

    section_hits = sum(
        1
        for line in text.splitlines()
        if "§" in line and (VAULT_ABS_PATH_RE.search(line) or BARE_VAULT_DIR_RE.search(line))
    )
    if section_hits and not exemptions.resolve("internal-section-reference-leak", rel, section_hits):
        findings.append(make_finding("internal-section-reference-leak", rel, section_hits))

    path_hits = len(VAULT_ABS_PATH_RE.findall(text)) + len(BARE_VAULT_DIR_RE.findall(text))
    if path_hits and not exemptions.resolve("vault-path-leak", rel, path_hits):
        findings.append(make_finding("vault-path-leak", rel, path_hits))

    # Case-sensitive, same rationale as qa.py: roster names are proper nouns,
    # and narrowing to case-sensitive avoids a single-token roster entry that
    # is also a common English word firing on ordinary lowercase prose.
    hits = {name for name in roster_names if re.search(r"\b" + re.escape(name) + r"\b", text)}
    if hits and not exemptions.resolve("roster-name-leak", rel, len(hits)):
        findings.append(make_finding("roster-name-leak", rel, len(hits)))

    return findings


def read_text_or_none(path: Path) -> str | None:
    """None means "skip this file, it isn't text" (binary — pre-commit's
    `types: [text]` should already exclude these). An OSError (permission
    denied, a race against deletion, ...) is NOT skippable — it means a
    tracked file could not be scanned at all, so it propagates to the
    caller, which fails closed (same contract as gitleaks-common.sh's
    gl_preflight: an inability to complete a scan is a BLOCK, never a
    silent pass)."""
    try:
        return path.read_text(encoding="utf-8")
    except UnicodeDecodeError:
        return None


def main() -> int:
    parser = argparse.ArgumentParser(description="House-code pattern checks (pre-commit hook).")
    parser.add_argument("files", nargs="*", metavar="FILE")
    parser.add_argument(
        "--rosters-path",
        default=None,
        help="Override the roster file path (tests only — never the real fixed path in a fixture run).",
    )
    parser.add_argument(
        "--declaration-path",
        default=None,
        help="Override the .house-code.json path (tests only — defaults to repo-root-relative).",
    )
    parser.add_argument(
        "--report", action="store_true",
        help="Print every exemption actually applied this run, to stderr. Does not change the exit code.",
    )
    args = parser.parse_args()

    # HC_NO_OVERLAY: the roster-name-leak class is the same private-pattern
    # class as gitleaks' operator overlay (GL_NO_OVERLAY, git-hooks/
    # gitleaks-common.sh) — two tools, one concept. A CI runner never holds
    # the real roster by design, so the routine lane runs the other three
    # house-code checks (ticket-id, vault-path, section-ref — pure pattern,
    # no roster needed) and explicitly skips roster-name-leak rather than
    # failing closed on a file that is never supposed to be there. Never
    # attempts fixed_rosters_path() at all in this mode.
    if os.environ.get("HC_NO_OVERLAY"):
        roster_names = []
        print("house-code: roster-name-leak skipped — base only by design (HC_NO_OVERLAY)", file=sys.stderr)
    else:
        rosters_path = Path(args.rosters_path).expanduser().resolve() if args.rosters_path else fixed_rosters_path()
        try:
            roster_names = load_roster_names(rosters_path)
        except RuntimeError as e:
            print(f"BLOCKED: {e}", file=sys.stderr)
            return 2

    declaration_path = Path(args.declaration_path).expanduser().resolve() if args.declaration_path else None
    try:
        declaration = load_declaration(Path.cwd(), override_path=declaration_path)
    except (RuntimeError, TypeError) as e:
        print(f"BLOCKED: {e}", file=sys.stderr)
        return 2

    private_repo_verified = verify_private_repo(bool(declaration.get("private_repo", False)))
    exemptions = Exemptions(private_repo_verified, declaration.get("exemptions", []))

    all_findings: list[dict] = []
    for f in args.files:
        path = Path(f)
        if not path.is_file():
            continue
        try:
            text = read_text_or_none(path)
        except OSError as e:
            print(f"BLOCKED: could not read {f}: {e} — refusing to scan a tracked file we cannot read.", file=sys.stderr)
            return 2
        if text is None:
            continue
        all_findings.extend(check_file(f, text, roster_names, exemptions))

    if args.report:
        exemptions.report()

    if not all_findings:
        return 0

    print("house-code: forbidden pattern(s) found (counts only — see the rule id and file):", file=sys.stderr)
    for finding in all_findings:
        print(f"  [{finding['rule']}] {finding['file']}: {finding['count']}", file=sys.stderr)
    return 1


if __name__ == "__main__":
    sys.exit(main())
