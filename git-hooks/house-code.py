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
"""

import argparse
import os
import re
import sys
from pathlib import Path

TICKET_ID_RE = re.compile(r"\b(?:LEX|SYS|INST|INC|MAST|GOAL)-\d+\b")

VAULT_ABS_PATH_RE = re.compile(r"(?:/Users/[\w.-]+/Vaults/Notes|~/Vaults/Notes)[^\s)\]`,]*")
BARE_VAULT_DIR_RE = re.compile(
    r"(?<!\{workspace_root\}/)\b(?:System/Knowledge|System/Context|"
    r"Projects/[\w-]+/Knowledge|Projects/[\w-]+/Context|Wiki/Knowledge|Wiki/Contexts)\b"
)

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


def check_file(rel: str, text: str, roster_names: list[str]) -> list[dict]:
    findings: list[dict] = []

    ids = set(TICKET_ID_RE.findall(text))
    if ids:
        findings.append(make_finding("ticket-id-leak", rel, len(ids)))

    section_hits = sum(
        1
        for line in text.splitlines()
        if "§" in line and (VAULT_ABS_PATH_RE.search(line) or BARE_VAULT_DIR_RE.search(line))
    )
    if section_hits:
        findings.append(make_finding("internal-section-reference-leak", rel, section_hits))

    path_hits = len(VAULT_ABS_PATH_RE.findall(text)) + len(BARE_VAULT_DIR_RE.findall(text))
    if path_hits:
        findings.append(make_finding("vault-path-leak", rel, path_hits))

    # Case-sensitive, same rationale as qa.py: roster names are proper nouns,
    # and narrowing to case-sensitive avoids a single-token roster entry that
    # is also a common English word firing on ordinary lowercase prose.
    hits = {name for name in roster_names if re.search(r"\b" + re.escape(name) + r"\b", text)}
    if hits:
        findings.append(make_finding("roster-name-leak", rel, len(hits)))

    return findings


def read_text_or_none(path: Path) -> str | None:
    try:
        return path.read_text(encoding="utf-8")
    except UnicodeDecodeError:
        return None  # binary — pre-commit's `types: [text]` should already exclude these
    except OSError as e:
        print(f"ERROR: could not read {path}: {e}", file=sys.stderr)
        return None


def main() -> int:
    parser = argparse.ArgumentParser(description="House-code pattern checks (pre-commit hook).")
    parser.add_argument("files", nargs="*", metavar="FILE")
    parser.add_argument(
        "--rosters-path",
        default=None,
        help="Override the roster file path (tests only — never the real fixed path in a fixture run).",
    )
    args = parser.parse_args()

    rosters_path = Path(args.rosters_path).expanduser().resolve() if args.rosters_path else fixed_rosters_path()

    try:
        roster_names = load_roster_names(rosters_path)
    except RuntimeError as e:
        print(f"BLOCKED: {e}", file=sys.stderr)
        return 2

    all_findings: list[dict] = []
    for f in args.files:
        path = Path(f)
        if not path.is_file():
            continue
        text = read_text_or_none(path)
        if text is None:
            continue
        all_findings.extend(check_file(f, text, roster_names))

    if not all_findings:
        return 0

    print("house-code: forbidden pattern(s) found (counts only — see the rule id and file):", file=sys.stderr)
    for finding in all_findings:
        print(f"  [{finding['rule']}] {finding['file']}: {finding['count']}", file=sys.stderr)
    return 1


if __name__ == "__main__":
    sys.exit(main())
