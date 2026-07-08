#!/usr/bin/env python3
"""
Test suite for qa.py — runs the corpus-conformance mechanical pass over
fixture files and asserts expected findings by check ID and severity.

Pattern mirrors lint-knowledge/tests/run_tests.py: subprocess the script,
parse its --json output, assert on check IDs / severities per fixture.

Usage:
    python3 tests/run_tests.py
    python3 tests/run_tests.py -v   (verbose)
"""

import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

TESTS_DIR = Path(__file__).parent.resolve()
FIXTURES_DIR = TESTS_DIR / "fixtures"
QA_PY = TESTS_DIR.parent / "qa.py"

VAULT_DIR = FIXTURES_DIR / "vault"
TARGETS_DIR = FIXTURES_DIR / "targets"
README_EXEMPLARS = sorted((FIXTURES_DIR / "exemplars" / "readme").glob("*.md"))


def run_qa(targets: list[str], extra_args: list[str] | None = None) -> dict:
    """Run qa.py with --json against the fixture vault-root and return parsed JSON."""
    cmd = [
        sys.executable, str(QA_PY),
        *targets,
        "--json",
        "--vault-root", str(VAULT_DIR),
    ]
    if extra_args:
        cmd.extend(extra_args)
    result = subprocess.run(cmd, capture_output=True, text=True)
    if result.returncode not in (0, 1):
        raise RuntimeError(
            f"qa.py exited {result.returncode}\nstdout: {result.stdout}\nstderr: {result.stderr}"
        )
    try:
        return json.loads(result.stdout)
    except json.JSONDecodeError as e:
        raise RuntimeError(
            f"Failed to parse JSON output: {e}\nstdout: {result.stdout}\nstderr: {result.stderr}"
        )


def findings_for_file(findings: list[dict], filename: str) -> list[dict]:
    return [f for f in findings if filename in f["file"]]


def check_ids(findings: list[dict]) -> list[str]:
    return [f["check"] for f in findings]


class TestSizeVsMedianOversized(unittest.TestCase):
    """The 209-line README fixture (real failure shape: the audit's own
    159-line-README precedent) must trip HIGH oversized-vs-exemplar-median
    against the 3-file, 30-line-median README exemplar set."""

    def setUp(self):
        target = TARGETS_DIR / "oversized" / "README.md"
        self.data = run_qa(
            [str(target)],
            ["--exemplars", *[str(p) for p in README_EXEMPLARS]],
        )

    def test_oversized_flagged(self):
        f = findings_for_file(self.data["findings"], "oversized/README.md")
        checks = check_ids(f)
        self.assertIn("oversized-vs-exemplar-median", checks)

    def test_severity_high(self):
        f = [x for x in findings_for_file(self.data["findings"], "oversized/README.md")
             if x["check"] == "oversized-vs-exemplar-median"]
        self.assertTrue(f, "No oversized-vs-exemplar-median finding")
        self.assertEqual(f[0]["severity"], "HIGH")


class TestSizeVsMedianCleanReadme(unittest.TestCase):
    """The clean README fixture against the same exemplar set should NOT trip
    the size check (well under 1.5x median)."""

    def setUp(self):
        target = TARGETS_DIR / "clean" / "README.md"
        self.data = run_qa(
            [str(target)],
            ["--exemplars", *[str(p) for p in README_EXEMPLARS]],
        )

    def test_zero_findings(self):
        f = findings_for_file(self.data["findings"], "clean/README.md")
        self.assertEqual(f, [], f"Expected zero findings for clean/README.md, got: {f}")


class TestTicketIdLeak(unittest.TestCase):
    """ticket-leak/SKILL.md mentions LEX-302 in the body — must trip HIGH
    ticket-id-leak."""

    def setUp(self):
        self.data = run_qa([str(TARGETS_DIR / "ticket-leak" / "SKILL.md")])

    def test_ticket_id_leak_flagged(self):
        f = findings_for_file(self.data["findings"], "ticket-leak/SKILL.md")
        checks = check_ids(f)
        self.assertIn("ticket-id-leak", checks)

    def test_severity_high(self):
        f = [x for x in findings_for_file(self.data["findings"], "ticket-leak/SKILL.md")
             if x["check"] == "ticket-id-leak"]
        self.assertEqual(f[0]["severity"], "HIGH")
        self.assertIn("LEX-302", f[0]["detail"])


class TestVaultPathLeak(unittest.TestCase):
    """vault-path-leak/SKILL.md carries a literal /Users/.../Vaults/Notes path
    instead of the {workspace_root} placeholder form."""

    def setUp(self):
        self.data = run_qa([str(TARGETS_DIR / "vault-path-leak" / "SKILL.md")])

    def test_vault_path_leak_flagged(self):
        f = findings_for_file(self.data["findings"], "vault-path-leak/SKILL.md")
        checks = check_ids(f)
        self.assertIn("vault-path-leak", checks)

    def test_severity_high(self):
        f = [x for x in findings_for_file(self.data["findings"], "vault-path-leak/SKILL.md")
             if x["check"] == "vault-path-leak"]
        self.assertEqual(f[0]["severity"], "HIGH")


class TestSelfNarration(unittest.TestCase):
    """self-narration/README.md carries a provenance parenthetical, a
    Co-Authored-By trailer, and a validation-status narrative — all three
    self-narration sub-patterns in one fixture."""

    def setUp(self):
        self.data = run_qa([str(TARGETS_DIR / "self-narration" / "README.md")])

    def test_self_narration_flagged(self):
        f = findings_for_file(self.data["findings"], "self-narration/README.md")
        checks = check_ids(f)
        self.assertIn("self-narration", checks)

    def test_severity_warning(self):
        f = [x for x in findings_for_file(self.data["findings"], "self-narration/README.md")
             if x["check"] == "self-narration"]
        self.assertEqual(f[0]["severity"], "WARNING")
        detail = f[0]["detail"]
        self.assertIn("provenance parenthetical", detail)
        self.assertIn("generator self-naming", detail)
        self.assertIn("validation-status narrative", detail)


class TestFictionDetection(unittest.TestCase):
    """fiction/SKILL.md mixes canonical CacheTrack (sample-universe) with an
    invented, uncited 'CacheVault Council' — only the latter should flag."""

    def setUp(self):
        self.data = run_qa([str(TARGETS_DIR / "fiction" / "SKILL.md")])

    def test_unlisted_fiction_flagged(self):
        f = findings_for_file(self.data["findings"], "fiction/SKILL.md")
        checks = check_ids(f)
        self.assertIn("unlisted-fiction-entity", checks)

    def test_severity_warning_and_content(self):
        f = [x for x in findings_for_file(self.data["findings"], "fiction/SKILL.md")
             if x["check"] == "unlisted-fiction-entity"]
        self.assertEqual(f[0]["severity"], "WARNING")
        detail = f[0]["detail"]
        self.assertIn("CacheVault", detail)
        self.assertNotIn("CacheTrack,", detail)  # canonical entity must not be listed as unknown


class TestBrokenCitation(unittest.TestCase):
    """broken-citation/SKILL.md cites a file that doesn't exist, and (as a
    negative control) a self-citation to its own SKILL.md that does resolve."""

    def setUp(self):
        self.data = run_qa([str(TARGETS_DIR / "broken-citation" / "SKILL.md")])

    def test_broken_citation_flagged(self):
        f = findings_for_file(self.data["findings"], "broken-citation/SKILL.md")
        broken = [x for x in f if x["check"] == "broken-citation"]
        self.assertTrue(broken, "Expected a broken-citation finding")
        self.assertIn("definitely-does-not-exist-fixture.md", broken[0]["detail"])

    def test_severity_medium(self):
        f = [x for x in findings_for_file(self.data["findings"], "broken-citation/SKILL.md")
             if x["check"] == "broken-citation"]
        self.assertEqual(f[0]["severity"], "MEDIUM")

    def test_self_citation_not_flagged_broken(self):
        f = findings_for_file(self.data["findings"], "broken-citation/SKILL.md")
        broken_details = [x["detail"] for x in f if x["check"] == "broken-citation"]
        self.assertFalse(
            any("`SKILL.md`" in d and "definitely" not in d for d in broken_details),
            "Self-citation to SKILL.md should resolve, not be flagged as broken",
        )


class TestCleanSkillPass(unittest.TestCase):
    """clean/SKILL.md should produce no HIGH/MEDIUM/WARNING findings — only
    the class-map default-exemplar size check may emit an (allowed) INFO."""

    def setUp(self):
        self.data = run_qa([str(TARGETS_DIR / "clean" / "SKILL.md")])

    def test_no_high_plus_findings(self):
        f = findings_for_file(self.data["findings"], "clean/SKILL.md")
        high_plus = [x for x in f if x["severity"] in ("HIGH", "MEDIUM", "WARNING")]
        self.assertEqual(
            high_plus, [],
            f"Expected no HIGH/MEDIUM/WARNING findings for clean/SKILL.md, got: {high_plus}",
        )


class TestMissingRosterFailsLoud(unittest.TestCase):
    """A vault-root with no tag-taxonomy-rosters.md must abort the whole run
    (non-zero exit, clear stderr) rather than silently skip the roster check —
    per corpus-conformance-methodology.md's fail-loud discipline."""

    def test_fails_loud_on_missing_roster(self):
        cmd = [
            sys.executable, str(QA_PY),
            str(TARGETS_DIR / "clean" / "SKILL.md"),
            "--json",
            "--vault-root", str(FIXTURES_DIR),  # no Wiki/spec/ under here
        ]
        result = subprocess.run(cmd, capture_output=True, text=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("tag-taxonomy-rosters.md", result.stderr)


class TestMissingUniverseFailsLoud(unittest.TestCase):
    """A --universe path that doesn't exist must abort the whole run — same
    fail-loud discipline as the roster file."""

    def test_fails_loud_on_missing_universe(self):
        cmd = [
            sys.executable, str(QA_PY),
            str(TARGETS_DIR / "clean" / "SKILL.md"),
            "--json",
            "--vault-root", str(VAULT_DIR),
            "--universe", str(FIXTURES_DIR / "no-such-universe.md"),
        ]
        result = subprocess.run(cmd, capture_output=True, text=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("universe.md", result.stderr)


class TestGitTrackedOnlyScoping(unittest.TestCase):
    """--git-tracked-only must scope a directory target to `git ls-files`
    (tracked *.md only) instead of walking the full tree. Real failure this
    guards: a house-qa run against a real repo target picks up its untracked
    scratch/eval content unless scoped. Builds a throwaway git repo at
    test-run time (not a static fixture) so the check exercises real
    `git ls-files` behavior without an embedded-repo footgun in this repo's
    own tree."""

    def setUp(self):
        self._tmpdir = tempfile.TemporaryDirectory()
        self.addCleanup(self._tmpdir.cleanup)
        self.repo = Path(self._tmpdir.name)

        def git(*args):
            subprocess.run(["git", "-C", str(self.repo), *args], check=True, capture_output=True)

        git("init", "-q")
        git("config", "user.email", "test@example.com")
        git("config", "user.name", "Test")

        (self.repo / "tracked-file.md").write_text(
            "# Tracked fixture\n\nOrdinary prose with nothing to flag.\n"
        )
        git("add", "tracked-file.md")
        git("commit", "-q", "-m", "initial")

        # Never `git add`ed — untracked, and carries a real finding.
        (self.repo / "untracked-file.md").write_text(
            "# Untracked fixture\n\nReferences LEX-999 which must never ship.\n"
        )

    def test_git_tracked_only_excludes_untracked_file(self):
        data = run_qa([str(self.repo)], ["--git-tracked-only"])
        self.assertEqual(data["scanned"], 1)
        ticket_findings = [f for f in data["findings"] if f["check"] == "ticket-id-leak"]
        self.assertEqual(ticket_findings, [])

    def test_default_walk_includes_untracked_file(self):
        data = run_qa([str(self.repo)])
        self.assertEqual(data["scanned"], 2)
        ticket_findings = [f for f in data["findings"] if f["check"] == "ticket-id-leak"]
        self.assertTrue(ticket_findings, "Expected the untracked file's LEX-999 to be flagged")


class TestFencedCitationSkipped(unittest.TestCase):
    """fenced-citation/SKILL.md quotes in-scenario illustrative filenames
    inside a <thinking> worked-example trace and inside a fenced code block —
    neither is a real citation and neither should flag broken-citation. A
    citation outside both (the negative control) must still flag."""

    def setUp(self):
        self.data = run_qa([str(TARGETS_DIR / "fenced-citation" / "SKILL.md")])

    def test_thinking_block_filename_not_flagged(self):
        f = findings_for_file(self.data["findings"], "fenced-citation/SKILL.md")
        broken_details = [x["detail"] for x in f if x["check"] == "broken-citation"]
        self.assertFalse(
            any("meeting-canopy-triad-sync-cachetrack.md" in d for d in broken_details),
            "Filename inside a <thinking> trace should not be flagged as a broken citation",
        )

    def test_fenced_code_block_filename_not_flagged(self):
        f = findings_for_file(self.data["findings"], "fenced-citation/SKILL.md")
        broken_details = [x["detail"] for x in f if x["check"] == "broken-citation"]
        self.assertFalse(
            any("meeting-canopy-triad-sync-gms.md" in d for d in broken_details),
            "Filename inside a fenced code block should not be flagged as a broken citation",
        )

    def test_negative_control_still_flagged(self):
        f = findings_for_file(self.data["findings"], "fenced-citation/SKILL.md")
        broken_details = [x["detail"] for x in f if x["check"] == "broken-citation"]
        self.assertTrue(
            any("definitely-does-not-exist-fixture.md" in d for d in broken_details),
            "A real broken citation outside any block must still be flagged",
        )


class TestFictionContinuityMismatch(unittest.TestCase):
    """file-a.md and file-b.md cite the same dated recurring-event entity
    ("...Triad Sync 2026-05-28") under two different names — the Canopy/AG
    shape from the real classified failure, reproduced with fictional stand-
    ins (Canopy vs. Grove) rather than the real leaked name. Both files must
    be scanned together in one invocation for the cross-file check to fire."""

    def setUp(self):
        self.data = run_qa([
            str(TARGETS_DIR / "fiction-continuity" / "file-a.md"),
            str(TARGETS_DIR / "fiction-continuity" / "file-b.md"),
        ])

    def test_mismatch_flagged(self):
        mismatches = [f for f in self.data["findings"] if f["check"] == "fiction-continuity-mismatch"]
        self.assertTrue(mismatches, "Expected a fiction-continuity-mismatch finding")

    def test_severity_high_and_both_names_named(self):
        mismatches = [f for f in self.data["findings"] if f["check"] == "fiction-continuity-mismatch"]
        self.assertEqual(mismatches[0]["severity"], "HIGH")
        detail = mismatches[0]["detail"]
        self.assertIn("Canopy Triad Sync", detail)
        self.assertIn("Grove Triad Sync", detail)
        self.assertIn("2026-05-28", detail)

    def test_single_file_invocation_no_mismatch(self):
        """A lone file citing one name for the date has nothing to conflict
        with — the check must not fire on a single-file scan."""
        data = run_qa([str(TARGETS_DIR / "fiction-continuity" / "file-a.md")])
        mismatches = [f for f in data["findings"] if f["check"] == "fiction-continuity-mismatch"]
        self.assertEqual(mismatches, [])


class TestPlaceholderInTableNotCitation(unittest.TestCase):
    """placeholder-in-table/SKILL.md declares [idea-name] (argument-hint +
    usage line) and cites `idea-name.md` in an arguments table — the citation
    check must treat that as the argument form with an extension, while still
    flagging the file's genuinely missing source."""

    def setUp(self):
        self.data = run_qa([str(TARGETS_DIR / "placeholder-in-table" / "SKILL.md")])
        self.broken = [
            x for x in findings_for_file(self.data["findings"], "placeholder-in-table/SKILL.md")
            if x["check"] == "broken-citation"
        ]

    def test_placeholder_not_flagged(self):
        self.assertFalse(
            any("idea-name.md" in x["detail"] for x in self.broken),
            "Argument-form placeholder was flagged as a broken citation",
        )

    def test_real_broken_citation_still_flagged(self):
        self.assertTrue(
            any("genuinely-missing-source.md" in x["detail"] for x in self.broken),
            "Placeholder discrimination masked the real broken citation",
        )

    def test_exactly_one_broken_citation(self):
        self.assertEqual(len(self.broken), 1)


class TestRepoLocalExemplarConfig(unittest.TestCase):
    """exemplar-config-repo/ carries .house-qa.json mapping skill-md to its
    own long-form corpus. With --repo-root at the fixture repo, the 430-line
    target grades clean against its own class median; without the config the
    same target is oversized vs the built-in skill-md exemplars — proving the
    config, not coincidence, produced the clean verdict."""

    REPO = FIXTURES_DIR / "exemplar-config-repo"
    TARGET = REPO / "skills" / "target" / "SKILL.md"

    def test_config_resolves_own_corpus_clean(self):
        data = run_qa([str(self.TARGET)], ["--repo-root", str(self.REPO)])
        oversized = [f for f in data["findings"] if f["check"] == "oversized-vs-exemplar-median"]
        self.assertEqual(oversized, [])

    def test_without_config_grades_against_builtins(self):
        data = run_qa([str(self.TARGET)])
        oversized = [f for f in data["findings"] if f["check"] == "oversized-vs-exemplar-median"]
        self.assertTrue(oversized, "Control: built-in exemplars should flag the long target")

    def test_cli_exemplars_override_config(self):
        data = run_qa(
            [str(self.TARGET)],
            ["--repo-root", str(self.REPO), "--exemplars", *[str(p) for p in README_EXEMPLARS]],
        )
        oversized = [f for f in data["findings"] if f["check"] == "oversized-vs-exemplar-median"]
        self.assertTrue(oversized, "CLI --exemplars must take precedence over repo-local config")


if __name__ == "__main__":
    unittest.main(verbosity=2)
