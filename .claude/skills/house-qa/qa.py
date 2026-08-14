#!/usr/bin/env python3
"""
qa.py — Mechanical pass for the corpus-conformance QA suite.

Executes the mechanical half of the "does it belong" validation axis defined in:
  {workspace_root}/System/Knowledge/corpus-conformance-methodology.md

Six checks, each traceable to a methodology clause (see SKILL.md for the full
traceability table). Every finding is {severity, check, file, detail, suggestion} —
same shape as lint-knowledge/lint.py, so callers can reuse the same JSON handling.

  1. size-vs-class-median      — length ratio vs. class exemplar median
                                  (>1.5x -> WARNING, >3x -> HIGH)
  2. forbidden-pattern scan    — ticket IDs, internal section-references to
                                  non-shipping docs, literal vault paths, real
                                  roster names (read at runtime from
                                  tag-taxonomy-rosters.md; fail-loud if missing)
  3. self-narration scan       — provenance parentheticals, generator
                                  self-naming, validation-status narrative
  4. citation integrity        — a cited canonical-source file must exist
                                  relative to the artifact's repo root.
                                  Skips filenames inside fenced code blocks or
                                  <thinking> worked-example traces — an
                                  illustrative example/report-template/
                                  worked-example payload is not a citation.
  5. fiction detection         — proper-noun entities not present in the
                                  sample-universe reference (read at runtime;
                                  fail-loud if missing) -> WARNING
  6. cross-file fiction continuity — a fictional recurring-event entity
                                  (name + date) must be cited under the same
                                  name in every file that mentions it; a
                                  same-date, different-name mismatch across
                                  the target set -> HIGH

Read-only. No model. No network. Exit 0 on a successful run (findings are
data); non-zero only on a script-level failure (a required reference file —
the rosters or the sample universe — is missing).

Directory targets walk every *.md by default; pass --git-tracked-only to
scope to `git ls-files` instead — the SKILL.md-documented default for a
repo-level target, so untracked scratch/eval content never gets swept in.

This suite grows one regression at a time, never speculatively (per the
methodology's Validation pattern clause). Known, documented gaps — not built
tonight because no real failure motivated them yet:
  - Structure conformance (Navigation-table presence, playbook-extraction
    triggers) is judgment-pass territory (see playbooks/review.md), not
    mechanized here.
  - Fiction detection only catches CamelCase compounds and a small
    Council/Sync/Suite/... suffix-phrase pattern — it will not catch an
    invented ALL-CAPS acronym (e.g. a single bare word with no internal
    lowercase-to-uppercase transition). WARNING-severity by design: it feeds
    the judgment pass, it does not gate alone.
  - Cross-file fiction continuity shares that same suffix-phrase pattern's
    blind spot, and only groups by a two-word suffix — a genuinely renamed
    entity that shares no suffix words with its prior name won't be linked.
"""

import argparse
import json
import os
import re
import statistics
import subprocess
import sys
from pathlib import Path

# ---------------------------------------------------------------------------
# Self-location: qa.py lives at <dotty>/.claude/skills/house-qa/qa.py
# ---------------------------------------------------------------------------

SCRIPT_DIR = Path(__file__).resolve().parent
DOTTY_ROOT = SCRIPT_DIR.parents[2]
SKILLS_DIR = DOTTY_ROOT / ".claude" / "skills"
SAMPLE_UNIVERSE_DEFAULT = SKILLS_DIR / "sample-universe" / "universe.md"

# The construction-standard exemplar trio (skill-quality-audit.md, 2026-07-07):
# SKILL.md 112/89/108 lines -> median 108; 15 playbooks 40-116 lines -> median ~79.
# Resolved dynamically (file contents/counts, never hardcoded numbers) so the
# median tracks the live corpus instead of drifting from it.
_EXEMPLAR_SKILLS = ["linear", "project-state", "grilling"]

SEVERITY_ORDER = ["HIGH", "MEDIUM", "WARNING", "INFO"]


def make_finding(severity: str, check: str, file_rel: str, detail: str, suggestion: str = "") -> dict:
    return {"severity": severity, "check": check, "file": file_rel, "detail": detail, "suggestion": suggestion}


# ---------------------------------------------------------------------------
# Class + exemplar resolution — check 1
# ---------------------------------------------------------------------------

def detect_class(path: Path) -> str | None:
    """Auto-detect artifact class from filename/location convention."""
    if path.name == "SKILL.md":
        return "skill-md"
    if path.parent.name == "playbooks":
        return "playbook"
    if path.name == "README.md":
        return "readme"
    return None


HOUSE_QA_CONFIG = ".house-qa.json"


def repo_config_exemplars(repo_root: Path, cls: str | None) -> list[Path] | None:
    """Repo-local exemplar override: <repo_root>/.house-qa.json maps class ->
    exemplar path globs (relative to repo root). Lets a consumer repo grade an
    artifact against its OWN class corpus instead of this repo's built-ins —
    a pipeline orchestrator measured against dotty's skill-md median is the
    wrong distribution. Resolution order per target:
    --exemplars CLI > repo-local config > built-in defaults.

    Shape: {"exemplars": {"skill-md": ["claude/skills/*/SKILL.md"], ...}}
    Unreadable config fails loud (config present = config trusted); a missing
    file or missing class entry falls through to the built-ins silently.
    """
    if cls is None:
        return None
    cfg_path = repo_root / HOUSE_QA_CONFIG
    if not cfg_path.is_file():
        return None
    try:
        cfg = json.loads(cfg_path.read_text(encoding="utf-8"))
    except (json.JSONDecodeError, OSError) as e:
        raise RuntimeError(f"Unreadable {cfg_path}: {e}")
    globs = (cfg.get("exemplars") or {}).get(cls)
    if not globs:
        return None
    paths: list[Path] = []
    for g in globs:
        paths.extend(sorted(repo_root.glob(g)))
    return paths or None


def default_exemplars(cls: str | None) -> list[Path]:
    """Small class-map fallback when --exemplars isn't passed. 'readme' has no
    built-in exemplar set yet (no corpus baseline established) — pass
    --exemplars explicitly for README-class checks."""
    if cls == "skill-md":
        return [SKILLS_DIR / name / "SKILL.md" for name in _EXEMPLAR_SKILLS]
    if cls == "playbook":
        paths: list[Path] = []
        for name in _EXEMPLAR_SKILLS:
            pb_dir = SKILLS_DIR / name / "playbooks"
            if pb_dir.is_dir():
                paths.extend(sorted(pb_dir.glob("*.md")))
        return paths
    return []


def check_size_vs_median(target: Path, cls: str | None, exemplars: list[Path]) -> list[dict]:
    rel = str(target)
    resolved = [e for e in exemplars if e.exists()]
    if not resolved:
        return [make_finding(
            "INFO", "size-check-skipped", rel,
            f"No exemplar set resolvable for class '{cls or 'unknown'}' — pass --exemplars to enable this check.",
        )]
    counts = [len(e.read_text(encoding="utf-8").splitlines()) for e in resolved]
    median = statistics.median(counts)
    if median == 0:
        return []
    target_lines = len(target.read_text(encoding="utf-8").splitlines())
    ratio = target_lines / median
    if ratio > 3.0:
        sev = "HIGH"
    elif ratio > 1.5:
        sev = "WARNING"
    else:
        return []
    return [make_finding(
        sev, "oversized-vs-exemplar-median", rel,
        f"{target_lines} lines vs. class '{cls or 'custom'}' exemplar median {median:.0f} "
        f"({len(resolved)} exemplars) — {ratio:.1f}x",
        "Read the class exemplars first and cut toward the median; verbosity is a runtime "
        "cost, not a style preference (corpus-conformance-methodology.md § Output is context input).",
    )]


# ---------------------------------------------------------------------------
# Check 2 — forbidden-pattern scan
# ---------------------------------------------------------------------------

TICKET_ID_RE = re.compile(r"\b(?:LEX|SYS|INST|INC|MAST|GOAL)-\d+\b")

VAULT_ABS_PATH_RE = re.compile(r"(?:/Users/[\w.-]+/Vaults/Notes|~/Vaults/Notes)[^\s)\]`,]*")
BARE_VAULT_DIR_RE = re.compile(
    r"(?<!\{workspace_root\}/)\b(?:System/Knowledge|System/Context|"
    r"Projects/[\w-]+/Knowledge|Projects/[\w-]+/Context|Wiki/Knowledge|Wiki/Contexts)\b"
)


# Count-floor (F1): a roster section parsing below this was almost certainly
# reformatted/truncated. Modest because this also runs against small test fixtures;
# the real person/employer rosters carry far more.
ROSTER_MIN_NAMES = 2


def load_roster_names(vault_root: Path) -> list[str]:
    """Real person/employer names, read at runtime from the gitignored rosters
    file — never hardcoded here (same discipline as lint.py's parse_tag_rosters).
    Fail-loud if the file is missing: a roster-name-leak check that silently
    no-ops because its data source vanished is worse than no check at all."""
    path = vault_root / "Wiki" / "spec" / "tag-taxonomy-rosters.md"
    if not path.exists():
        raise RuntimeError(
            f"tag-taxonomy-rosters.md not found at {path} — required for the roster-name-leak "
            "check (fail-loud, per corpus-conformance-methodology.md § Validation pattern)."
        )
    text = path.read_text(encoding="utf-8")
    names: list[str] = []
    for label in ("Current roster", "Current employers"):
        # Same-line capture ([^\S\n], not \s): the values must sit on the SAME line
        # as the label. Plain \s crossed newlines, so a blanked/bulleted roster line
        # silently captured the NEXT prose paragraph — a fail-open that would shrink
        # the roster-name-leak check's coverage (F1). Fail loud below the floor: a
        # roster-leak check running on a silently-truncated name list is worse than
        # none (same rationale as the missing-file guard above).
        m = re.search(re.escape(label) + r"[^\n]*:[^\S\n]*([^\n]+)", text)
        if not m:
            raise RuntimeError(
                f"tag-taxonomy-rosters.md: '{label} ...:' line missing or reformatted "
                f"off its own line — the roster-name-leak check would silently under-read. "
                f"Restore the single comma-joined line.")
        section = [tok.strip().rstrip(".") for tok in re.split(r",\s*", m.group(1))
                   if tok.strip().rstrip(".")]
        if len(section) < ROSTER_MIN_NAMES:
            raise RuntimeError(
                f"tag-taxonomy-rosters.md: '{label} ...:' parsed to only {len(section)} "
                f"value(s) (floor {ROSTER_MIN_NAMES}) — the line was likely reformatted/"
                f"truncated; the roster-name-leak check would silently under-read. "
                f"Restore the single comma-joined line.")
        names.extend(section)
    return names


def check_forbidden_patterns(target: Path, text: str, roster_names: list[str]) -> list[dict]:
    rel = str(target)
    findings = []

    ids = sorted(set(TICKET_ID_RE.findall(text)))
    if ids:
        findings.append(make_finding(
            "HIGH", "ticket-id-leak", rel,
            f"Ticket ID reference(s): {', '.join(ids)}",
            "Ticket IDs belong in PR bodies / commit trailers, never shipped artifacts (publishing-workflow.md).",
        ))

    section_hit = None
    for line in text.splitlines():
        if "§" in line and (VAULT_ABS_PATH_RE.search(line) or BARE_VAULT_DIR_RE.search(line)):
            section_hit = line.strip()
            break
    if section_hit:
        findings.append(make_finding(
            "HIGH", "internal-section-reference-leak", rel,
            f"§-reference to a non-shipping (vault-only) doc: \"{section_hit[:120]}\"",
            "Cite the public companion doc, or drop the internal section pointer.",
        ))

    path_hit = None
    m = VAULT_ABS_PATH_RE.search(text) or BARE_VAULT_DIR_RE.search(text)
    if m:
        path_hit = m.group(0)
        findings.append(make_finding(
            "HIGH", "vault-path-leak", rel,
            f"Literal vault path (not in {{workspace_root}} form): {path_hit}",
            "Use the {workspace_root}/... placeholder form (shared-infrastructure.md).",
        ))

    # Case-SENSITIVE (no re.IGNORECASE): roster names are proper nouns, and a
    # genuine leak preserves their capitalization. A single-token roster entry
    # that is also a common English word (e.g. an employer name that doubles as
    # a dictionary verb) otherwise fires on ordinary lowercase prose usage of
    # that word — a false HIGH that the check's own health metric (zero false
    # HIGHs) forbids. Multi-token person names ("First Last") never hit this;
    # this narrows only the single-token common-word collision, and still
    # catches the name used as a proper noun. Accepted trade-off: this also
    # forgoes matching roster names written in non-canonical case (all-lower/
    # all-caps) — accepted because the health metric is precision-over-recall
    # for this check, and a leaked name in prose overwhelmingly appears in its
    # proper-noun form.
    hits = sorted({name for name in roster_names if re.search(r"\b" + re.escape(name) + r"\b", text)})
    if hits:
        findings.append(make_finding(
            "HIGH", "roster-name-leak", rel,
            f"Real roster name(s) found: {', '.join(hits)}",
            "Replace with sample-universe fictional vocabulary, or a generic placeholder.",
        ))

    return findings


# ---------------------------------------------------------------------------
# Check 3 — self-narration scan
# ---------------------------------------------------------------------------

PROVENANCE_RE = re.compile(
    r"\((?:[^)]{0,80}\b(?:generated|written|authored|drafted|produced|created)\b\s+by\s+"
    r"(?:Claude|AI|an?\s+(?:LLM|language model)|this\s+(?:skill|script|agent))[^)]{0,40})\)",
    re.IGNORECASE,
)
SELF_NAMING_RE = re.compile(
    r"\b(?:I am|I'm)\s+(?:Claude|an AI|a language model)\b|\bAs an AI\b|"
    r"\bGenerated by Claude\b|\bCo-Authored-By:\s*Claude\b",
    re.IGNORECASE,
)
VALIDATION_NARRATIVE_RE = re.compile(
    r"(?:✅|✓)\s*(?:all\s+)?(?:tests?|checks?)\b[^.\n]{0,40}\b(?:pass(?:ing|ed)?|green|clean)\b|"
    r"\ball\s+\d+\s+tests?\s+pass(?:ing|ed)?\b|"
    r"\bvalidated\s+(?:on|as of)\s+\d{4}-\d{2}-\d{2}\b",
    re.IGNORECASE,
)


def check_self_narration(target: Path, text: str) -> list[dict]:
    rel = str(target)
    hits = []
    for label, rx in (
        ("provenance parenthetical", PROVENANCE_RE),
        ("generator self-naming", SELF_NAMING_RE),
        ("validation-status narrative", VALIDATION_NARRATIVE_RE),
    ):
        m = rx.search(text)
        if m:
            hits.append(f"{label}: \"{m.group(0)[:80].strip()}\"")
    if not hits:
        return []
    return [make_finding(
        "WARNING", "self-narration", rel,
        "; ".join(hits),
        "Provenance and validation status belong in git history or Linear, not the artifact body "
        "(corpus-conformance-methodology.md § Output is context input; § Failure smells).",
    )]


# ---------------------------------------------------------------------------
# Check 4 — canonical-source citation integrity
# ---------------------------------------------------------------------------

CITATION_RE = re.compile(r"`([\w./~-]+\.(?:md|py|sh|json|ya?ml|txt))`")
FENCED_CODE_BLOCK_RE = re.compile(r"```.*?```", re.DOTALL)
THINKING_BLOCK_RE = re.compile(r"<thinking>.*?</thinking>", re.DOTALL | re.IGNORECASE)

# A token declared in bracket/brace form anywhere in the file ([idea-name],
# {idea-name}) is an argument/template placeholder, not a filename. The
# negative lookahead excludes markdown link text ([README](...)), which would
# otherwise mask a real broken citation to a same-named file.
PLACEHOLDER_DECL_RE = re.compile(r"[\[{]([\w-]+)[\]}](?!\()")


def _strip_illustrative_blocks(text: str) -> str:
    """Blank fenced-code-block and <thinking>-worked-example bodies (newlines
    preserved, so this stays safe to reuse anywhere line numbers might matter
    later) before a citation scan. A filename mentioned only as illustrative
    content inside an example/report-template/worked-example block — a
    sample JSON payload, a templated report string, a worked-example
    reasoning trace — is not a citation to a canonical source; only prose
    outside these blocks names one. Real failure that motivated this:
    calibration-surface.md's worked examples quote in-universe filenames
    (`meeting-canopy-triad-sync-cachetrack.md`-style) inside <thinking>
    traces, and the unqualified citation check flagged them as broken."""
    text = FENCED_CODE_BLOCK_RE.sub(lambda m: "\n" * m.group(0).count("\n"), text)
    text = THINKING_BLOCK_RE.sub(lambda m: "\n" * m.group(0).count("\n"), text)
    return text


def find_repo_root(target: Path) -> Path:
    """Walk up from the target's directory looking for a .git entry (dir or
    worktree file). Falls back to the target's own directory if none found."""
    cur = target.parent
    for _ in range(20):
        if (cur / ".git").exists():
            return cur
        if cur.parent == cur:
            break
        cur = cur.parent
    return target.parent


def git_tracked_md_files(dir_path: Path) -> list[Path]:
    """Return dir_path's git-tracked *.md files as absolute paths, via
    `git ls-files`. Backs --git-tracked-only: scoping a directory target to
    what's actually tracked, instead of walking every *.md on disk, which
    otherwise sweeps in untracked scratch/eval content never meant for a
    corpus-conformance pass (the real failure that motivated this: a
    house-qa run against the Wiki repo picked up its untracked Evals/ dir
    alongside the tracked corpus). Requires dir_path to be inside a git
    working tree — fails loud, same discipline as the roster/universe
    reference-file checks."""
    try:
        result = subprocess.run(
            ["git", "-C", str(dir_path), "ls-files", "-z", "--", "*.md"],
            capture_output=True, text=True, check=True,
        )
    except (subprocess.CalledProcessError, FileNotFoundError) as e:
        raise RuntimeError(f"--git-tracked-only requires a git repo at {dir_path}: {e}")
    return [dir_path / rel for rel in result.stdout.split("\0") if rel]


def check_citation_integrity(target: Path, text: str, repo_root: Path) -> list[dict]:
    rel = str(target)
    findings = []
    seen: set[str] = set()
    scan_text = _strip_illustrative_blocks(text)
    # Scan the ORIGINAL text for placeholder declarations — argument-hint
    # frontmatter and usage lines often live inside stripped blocks.
    declared_placeholders = set(PLACEHOLDER_DECL_RE.findall(text))
    for m in CITATION_RE.finditer(scan_text):
        cited = m.group(1)
        if cited in seen or "{" in cited:
            continue  # {workspace_root}/... placeholders are intentionally symbolic, not resolved
        seen.add(cited)
        if Path(cited).stem in declared_placeholders:
            # `idea-name.md` in an arguments table, with `[idea-name]` declared
            # elsewhere in the file, is the argument form with an extension —
            # a placeholder, not a citation (house convention; see the
            # placeholder-in-table fixture).
            continue
        candidates = [repo_root / cited, target.parent / cited]
        resolved = any(c.exists() for c in candidates)
        if not resolved:
            # Fallback: a same-repo citation to a sibling skill/script commonly
            # names the file without its full relative path (e.g. "lint.py"
            # cited from a different skill's directory) — search the repo tree
            # for the exact basename before calling it broken.
            basename = Path(cited).name
            resolved = any(repo_root.rglob(basename))
        if not resolved:
            findings.append(make_finding(
                "MEDIUM", "broken-citation", rel,
                f"Cited source `{cited}` does not exist relative to the repo root ({repo_root}), "
                "the artifact's own directory, or anywhere else in the repo by basename.",
                "Fix the path, or remove the citation if the source no longer exists.",
            ))
    return findings


# ---------------------------------------------------------------------------
# Check 5 — per-file fiction detection
# ---------------------------------------------------------------------------

CAMEL_RE = re.compile(r"\b[A-Z][a-z]+(?:[A-Z][a-zA-Z]*)+\b")
SUFFIX_PHRASE_RE = re.compile(
    r"\b(?:[A-Z][a-zA-Z]*\s){1,2}(?:Council|Sync|Suite|Squad|Division|Platform|Committee|Board)\b"
)

# Established real-world / platform vocabulary, excluded so the heuristic targets
# invented per-file fiction rather than flagging legitimate tool and product
# nomenclature that recurs throughout this corpus. Bounded and documented, not
# grown per fictional entity.
_KNOWN_VOCAB = {
    "GitHub", "YouTube", "LinkedIn", "PayPal", "WordPress", "JavaScript", "TypeScript",
    "GraphQL", "MacBook", "WiFi", "OAuth", "GitLab", "BitBucket", "DevOps", "PowerPoint",
    "OneDrive", "SharePoint", "CamelCase",
    "SessionStart", "SessionEnd", "PreToolUse", "PostToolUse", "UserPromptSubmit", "PreCompact",
    "WebFetch", "WebSearch", "ToolSearch", "NotebookEdit", "TaskStop", "SendMessage",
    "ExitWorktree", "EnterWorktree", "ExitPlanMode",
    # Real products/tools flagged as fiction in real infra docs:
    "CrashPlan", "Obsidian Sync", "LinkML",
    # OpenSSH config options (CamelCase by convention):
    "IdentitiesOnly", "IdentityFile", "ForwardAgent", "ConnectTimeout", "BatchMode",
    # Claude Code tool names not already listed:
    "BashOutput", "KillShell", "SlashCommand", "TodoWrite", "AskUserQuestion",
    # Real products/people in attributions and tool references:
    "HumanLayer", "NateBJones", "TailwindCSS",
    # /prototype's own method nomenclature (the variant naming is the skill's instruction):
    "PrototypeSwitcher", "VariantA", "VariantB", "VariantC",
}


def load_universe_entities(universe_path: Path) -> set[str]:
    """Canonical fictional-entity allow-list, read at runtime from
    sample-universe/universe.md — never hardcoded here. Fail-loud if missing."""
    if not universe_path.exists():
        raise RuntimeError(
            f"sample-universe/universe.md not found at {universe_path} — required for the "
            "fiction-detection check (fail-loud, per corpus-conformance-methodology.md § Validation pattern)."
        )
    text = universe_path.read_text(encoding="utf-8")
    entities: set[str] = set()
    for m in re.finditer(r"\*\*([^*]+)\*\*", text):
        entities.add(m.group(1).strip().lower())
    for m in re.finditer(r"`([^`]+)`", text):
        entities.add(m.group(1).strip().lower())
    return entities


def check_fiction(target: Path, text: str, universe_entities: set[str]) -> list[dict]:
    # Scoped to prose (.md) — dogfooding this check against qa.py's own source
    # showed it flagging ordinary Python identifiers (ArgumentParser, RuntimeError)
    # as "unlisted fiction." The real failure corpus (abstraction-rework-proposal.md)
    # was entirely markdown worked-examples; source code has no equivalent problem.
    if target.suffix.lower() != ".md":
        return []
    # Vendored third-party quarries (top-level reference/) are pristine foreign
    # material — grading their example vocabulary against OUR sample universe is
    # a category error, same rationale as the gate's tests/fixtures exemption.
    if "reference" in target.parts:
        return []
    rel = str(target)
    candidates = set(CAMEL_RE.findall(text)) | {m.strip() for m in SUFFIX_PHRASE_RE.findall(text)}
    unknown = sorted(
        c for c in candidates
        if c not in _KNOWN_VOCAB and c.strip().lower() not in universe_entities
    )
    if not unknown:
        return []
    return [make_finding(
        "WARNING", "unlisted-fiction-entity", rel,
        f"Proper-noun entities not in sample-universe/universe.md: {', '.join(unknown)}",
        "Draw example vocabulary from sample-universe/universe.md, or propose an extension per "
        "its own citation discipline (corpus-conformance-methodology.md § The invention protocol).",
    )]


# ---------------------------------------------------------------------------
# Check 6 — cross-file fiction continuity
# ---------------------------------------------------------------------------

ENTITY_DATE_RE = re.compile(
    r"\b((?:[A-Z][a-zA-Z]*\s){1,2}(?:Council|Sync|Suite|Squad|Division|Platform|Committee|Board))"
    r"\s+(\d{4}-\d{2}-\d{2})"
)


def check_fiction_continuity(file_texts: dict[str, str]) -> list[dict]:
    """Cross-file check: a fictional recurring-event entity (name + date) must
    be cited under the same name everywhere it appears in the target set.

    Real classified failure that motivated this (grow-by-regression, per
    corpus-conformance-methodology.md's Validation pattern): a Wiki
    publication PII sweep found a real meeting name still attached to a date
    its canonical fictional replacement was already using elsewhere in the
    same corpus — the same-date, different-name mismatch was the tell that a
    rename hadn't fully propagated.

    Groups mentions by date, then within a date groups by the entity
    phrase's last two words (its stable suffix, e.g. "Triad Sync") so
    "Canopy Triad Sync" and "Grove Triad Sync" are recognized as competing
    names for the same dated event, not unrelated entities."""
    occurrences: dict[str, list[tuple[str, str]]] = {}  # date -> [(name, file)]
    for rel, text in file_texts.items():
        for m in ENTITY_DATE_RE.finditer(text):
            name, date = m.group(1).strip(), m.group(2)
            occurrences.setdefault(date, []).append((name, rel))

    findings: list[dict] = []
    for date, mentions in occurrences.items():
        by_suffix: dict[str, set[str]] = {}
        files_for_name: dict[str, set[str]] = {}
        for name, rel in mentions:
            words = name.split()
            suffix = " ".join(words[-2:]) if len(words) >= 2 else name
            by_suffix.setdefault(suffix, set()).add(name)
            files_for_name.setdefault(name, set()).add(rel)
        for names in by_suffix.values():
            if len(names) < 2:
                continue
            involved_files = sorted({f for n in names for f in files_for_name[n]})
            findings.append(make_finding(
                "HIGH", "fiction-continuity-mismatch", "; ".join(involved_files),
                f"Same-date ({date}) entity cited under conflicting names: "
                f"{', '.join(sorted(names))}",
                "Reconcile to one name across every citing file — a same-date, "
                "different-name mismatch is usually an incomplete rename, "
                "sometimes a real name that never got swapped for its fictional "
                "stand-in.",
            ))
    return findings


# ---------------------------------------------------------------------------
# Per-file runner + CLI
# ---------------------------------------------------------------------------

def qa_file(
    target: Path,
    *,
    cls: str | None,
    exemplars: list[Path],
    repo_root: Path,
    roster_names: list[str],
    universe_entities: set[str],
    text: str | None = None,
) -> list[dict]:
    if text is None:
        text = target.read_text(encoding="utf-8")
    findings: list[dict] = []
    findings += check_size_vs_median(target, cls, exemplars)
    findings += check_forbidden_patterns(target, text, roster_names)
    findings += check_self_narration(target, text)
    findings += check_citation_integrity(target, text, repo_root)
    findings += check_fiction(target, text, universe_entities)
    return findings


def format_text(result: dict) -> str:
    lines = [f"Corpus-conformance QA — {result['scanned']} artifact(s) checked", ""]
    findings = result["findings"]
    if not findings:
        lines.append("No findings. All artifacts conform.")
    else:
        for sev in SEVERITY_ORDER:
            group = [f for f in findings if f["severity"] == sev]
            if not group:
                continue
            lines.append("=" * 60)
            lines.append(f"{sev} ({len(group)})")
            lines.append("=" * 60)
            for f in group:
                lines.append(f"  [{f['check']}] {f['file']}")
                lines.append(f"    {f['detail']}")
                if f.get("suggestion"):
                    lines.append(f"    -> {f['suggestion']}")
            lines.append("")
    s = result["summary"]
    lines.append("=" * 60)
    lines.append("Summary")
    lines.append("=" * 60)
    lines.append(
        f"  HIGH={s['HIGH']}  MEDIUM={s['MEDIUM']}  WARNING={s['WARNING']}  INFO={s['INFO']}  "
        f"clean={s['clean']}/{result['scanned']}"
    )
    return "\n".join(lines)


def main() -> int:
    parser = argparse.ArgumentParser(description="Corpus-conformance mechanical QA pass.")
    parser.add_argument(
        "targets", nargs="+", metavar="PATH",
        help="One or more artifact files (or directories, walked recursively for *.md) to check.",
    )
    parser.add_argument("--json", action="store_true", help="Emit findings as JSON to stdout.")
    parser.add_argument(
        "--class", dest="cls", choices=["skill-md", "playbook", "readme"], default=None,
        help="Override class auto-detection (applies to every target in this invocation).",
    )
    parser.add_argument(
        "--exemplars", nargs="+", default=None,
        help="Override the class exemplar file set used by the size-vs-median check.",
    )
    parser.add_argument(
        "--repo-root", default=None,
        help="Repo root for citation-integrity resolution (default: nearest .git per target).",
    )
    parser.add_argument(
        "--vault-root", default=os.environ.get("VAULT_ROOT"),
        required="VAULT_ROOT" not in os.environ,
        help="Vault root for tag-taxonomy-rosters.md lookup. Set VAULT_ROOT env var or pass explicitly.",
    )
    parser.add_argument(
        "--universe", default=str(SAMPLE_UNIVERSE_DEFAULT),
        help="Path to sample-universe/universe.md (default: sibling skill in this repo).",
    )
    parser.add_argument(
        "--git-tracked-only", action="store_true",
        help="When a target is a directory, scope to `git ls-files` (tracked *.md only) "
             "instead of walking the full tree. Recommended default for repo-level "
             "targets (see SKILL.md) — an untracked scratch/Evals/ dir otherwise gets "
             "swept into the scan.",
    )
    args = parser.parse_args()

    vault_root = Path(args.vault_root).expanduser().resolve()
    universe_path = Path(args.universe).expanduser().resolve()

    try:
        universe_entities = load_universe_entities(universe_path)
    except RuntimeError as e:
        print(f"ERROR: {e}", file=sys.stderr)
        return 2

    try:
        roster_names = load_roster_names(vault_root)
    except RuntimeError as e:
        print(f"ERROR: {e}", file=sys.stderr)
        return 2

    targets: list[Path] = []
    for t in args.targets:
        p = Path(t).expanduser().resolve()
        if not p.exists():
            print(f"ERROR: target does not exist: {p}", file=sys.stderr)
            return 2
        if p.is_dir():
            if args.git_tracked_only:
                try:
                    targets.extend(git_tracked_md_files(p))
                except RuntimeError as e:
                    print(f"ERROR: {e}", file=sys.stderr)
                    return 2
            else:
                targets.extend(sorted(p.rglob("*.md")))
        else:
            targets.append(p)

    override_exemplars = [Path(e).expanduser().resolve() for e in args.exemplars] if args.exemplars else None
    override_repo_root = Path(args.repo_root).expanduser().resolve() if args.repo_root else None

    all_findings: list[dict] = []
    file_texts: dict[str, str] = {}
    try:
        for target in targets:
            cls = args.cls or detect_class(target)
            repo_root = override_repo_root or find_repo_root(target)
            if override_exemplars is not None:
                exemplars = override_exemplars
            else:
                exemplars = repo_config_exemplars(repo_root, cls) or default_exemplars(cls)
            text = target.read_text(encoding="utf-8")
            file_texts[str(target)] = text
            all_findings.extend(qa_file(
                target,
                cls=cls,
                exemplars=exemplars,
                repo_root=repo_root,
                roster_names=roster_names,
                universe_entities=universe_entities,
                text=text,
            ))
        all_findings.extend(check_fiction_continuity(file_texts))
    except Exception as e:  # noqa: BLE001 — top-level fail-loud reporter: any error must print and exit nonzero, never pass silently
        import traceback
        print(f"ERROR during QA run: {e}", file=sys.stderr)
        traceback.print_exc(file=sys.stderr)
        return 1

    summary = {s: 0 for s in SEVERITY_ORDER}
    files_with_findings: set[str] = set()
    for f in all_findings:
        summary[f["severity"]] += 1
        files_with_findings.add(f["file"])
    result = {
        "scanned": len(targets),
        "findings": all_findings,
        "summary": {**summary, "clean": len(targets) - len(files_with_findings)},
    }

    if args.json:
        print(json.dumps(result, indent=2))
    else:
        print(format_text(result))
    return 0


if __name__ == "__main__":
    sys.exit(main())
