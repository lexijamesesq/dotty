#!/usr/bin/env python3
"""
Test suite for lint.py — runs the mechanical lint pass over fixture files
and asserts expected findings by check ID and severity.

Usage:
    python3 tests/run_tests.py
    python3 tests/run_tests.py -v   (verbose)
"""

import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

# Resolve paths relative to this test file
TESTS_DIR = Path(__file__).parent.resolve()
FIXTURES_DIR = TESTS_DIR / "fixtures"
VAULT_DIR = FIXTURES_DIR / "vault"
LINT_PY = TESTS_DIR.parent / "lint.py"

ALPHA_KNOWLEDGE = VAULT_DIR / "Projects" / "alpha" / "Knowledge"
WIKI_KNOWLEDGE = VAULT_DIR / "Wiki" / "Knowledge"


def run_lint(scope_paths: list[str], extra_args: list[str] | None = None) -> dict:
    """Run lint.py with --json --no-manifest and return parsed JSON output."""
    cmd = [
        sys.executable, str(LINT_PY),
        *scope_paths,
        "--json",
        "--no-manifest",
        "--vault-root", str(VAULT_DIR),
    ]
    if extra_args:
        cmd.extend(extra_args)

    result = subprocess.run(cmd, capture_output=True, text=True)
    if result.returncode not in (0, 1):
        raise RuntimeError(
            f"lint.py exited {result.returncode}\nstdout: {result.stdout}\nstderr: {result.stderr}"
        )
    try:
        return json.loads(result.stdout)
    except json.JSONDecodeError as e:
        raise RuntimeError(
            f"Failed to parse JSON output: {e}\nstdout: {result.stdout}\nstderr: {result.stderr}"
        )


def findings_for_file(findings: list[dict], filename: str) -> list[dict]:
    """Return findings for files whose path contains the given filename."""
    return [f for f in findings if filename in f["file"]]


def check_ids_for_file(findings: list[dict], filename: str) -> list[str]:
    return [f["check"] for f in findings_for_file(findings, filename)]


def severities_for_file(findings: list[dict], filename: str) -> list[str]:
    return [f["severity"] for f in findings_for_file(findings, filename)]


class TestCleanFile(unittest.TestCase):
    """clean-file.md should produce zero findings."""

    def setUp(self):
        self.data = run_lint([str(ALPHA_KNOWLEDGE / "clean-file.md")])

    def test_no_findings(self):
        findings = findings_for_file(self.data["findings"], "clean-file.md")
        # May have unverified (INFO) but should have no HIGH/MEDIUM/WARNING
        high_plus = [f for f in findings if f["severity"] in ("HIGH", "MEDIUM", "WARNING")]
        self.assertEqual(
            high_plus, [],
            f"Expected no HIGH/MEDIUM/WARNING findings for clean-file.md, got: {high_plus}"
        )


class TestMissingUpdated(unittest.TestCase):
    """missing-updated.md should have HIGH missing-updated."""

    def setUp(self):
        self.data = run_lint([str(ALPHA_KNOWLEDGE / "missing-updated.md")])

    def test_missing_updated(self):
        checks = check_ids_for_file(self.data["findings"], "missing-updated.md")
        self.assertIn("missing-updated", checks)

    def test_severity_high(self):
        f = [x for x in findings_for_file(self.data["findings"], "missing-updated.md")
             if x["check"] == "missing-updated"]
        self.assertTrue(f, "No missing-updated finding")
        self.assertEqual(f[0]["severity"], "HIGH")


class TestTwoTypeTags(unittest.TestCase):
    """two-type-tags.md should have HIGH multiple-type-tags."""

    def setUp(self):
        self.data = run_lint([str(ALPHA_KNOWLEDGE / "two-type-tags.md")])

    def test_multiple_type_tags(self):
        checks = check_ids_for_file(self.data["findings"], "two-type-tags.md")
        self.assertIn("multiple-type-tags", checks)

    def test_severity_high(self):
        f = [x for x in findings_for_file(self.data["findings"], "two-type-tags.md")
             if x["check"] == "multiple-type-tags"]
        self.assertEqual(f[0]["severity"], "HIGH")


class TestUnknownType(unittest.TestCase):
    """unknown-type.md should have HIGH unknown-type-tag."""

    def setUp(self):
        self.data = run_lint([str(ALPHA_KNOWLEDGE / "unknown-type.md")])

    def test_unknown_type_tag(self):
        checks = check_ids_for_file(self.data["findings"], "unknown-type.md")
        self.assertIn("unknown-type-tag", checks)

    def test_severity_high(self):
        f = [x for x in findings_for_file(self.data["findings"], "unknown-type.md")
             if x["check"] == "unknown-type-tag"]
        self.assertEqual(f[0]["severity"], "HIGH")


class TestNoH1(unittest.TestCase):
    """no-h1.md should have HIGH missing-h1."""

    def setUp(self):
        self.data = run_lint([str(ALPHA_KNOWLEDGE / "no-h1.md")])

    def test_missing_h1(self):
        checks = check_ids_for_file(self.data["findings"], "no-h1.md")
        self.assertIn("missing-h1", checks)

    def test_severity_high(self):
        f = [x for x in findings_for_file(self.data["findings"], "no-h1.md")
             if x["check"] == "missing-h1"]
        self.assertEqual(f[0]["severity"], "HIGH")


class TestTwoH1s(unittest.TestCase):
    """two-h1s.md should have HIGH multiple-h1."""

    def setUp(self):
        self.data = run_lint([str(ALPHA_KNOWLEDGE / "two-h1s.md")])

    def test_multiple_h1(self):
        checks = check_ids_for_file(self.data["findings"], "two-h1s.md")
        self.assertIn("multiple-h1", checks)

    def test_severity_high(self):
        f = [x for x in findings_for_file(self.data["findings"], "two-h1s.md")
             if x["check"] == "multiple-h1"]
        self.assertEqual(f[0]["severity"], "HIGH")


class TestBrokenWikilink(unittest.TestCase):
    """broken-wikilink.md should have HIGH broken-wikilink for [[does-not-exist]]."""

    def setUp(self):
        self.data = run_lint([str(ALPHA_KNOWLEDGE / "broken-wikilink.md")])

    def test_broken_wikilink_found(self):
        findings = findings_for_file(self.data["findings"], "broken-wikilink.md")
        broken = [f for f in findings if f["check"] == "broken-wikilink"]
        self.assertTrue(broken, "Expected a broken-wikilink finding")

    def test_broken_wikilink_detail(self):
        findings = findings_for_file(self.data["findings"], "broken-wikilink.md")
        broken = [f for f in findings if f["check"] == "broken-wikilink"]
        self.assertTrue(any("does-not-exist" in f["detail"] for f in broken))

    def test_valid_wikilink_not_flagged(self):
        # [[clean-file]] exists in the same folder — should not be flagged
        findings = findings_for_file(self.data["findings"], "broken-wikilink.md")
        broken = [f for f in findings if f["check"] == "broken-wikilink"]
        # Should have exactly one broken link (does-not-exist), not clean-file
        targets = [f["detail"] for f in broken]
        self.assertFalse(any("clean-file" in t for t in targets))

    def test_severity_medium(self):
        # broken-wikilink is MEDIUM, not HIGH: vault entropy, not an envelope
        # violation (lint-surface.md › Structural integrity).
        findings = findings_for_file(self.data["findings"], "broken-wikilink.md")
        broken = [f for f in findings if f["check"] == "broken-wikilink"]
        self.assertEqual(broken[0]["severity"], "MEDIUM")


class TestLegacyPeopleTag(unittest.TestCase):
    """legacy-people-tag.md should have MEDIUM legacy-people-tag."""

    def setUp(self):
        self.data = run_lint([str(ALPHA_KNOWLEDGE / "legacy-people-tag.md")])

    def test_legacy_people_tag(self):
        checks = check_ids_for_file(self.data["findings"], "legacy-people-tag.md")
        self.assertIn("legacy-people-tag", checks)

    def test_severity_medium(self):
        f = [x for x in findings_for_file(self.data["findings"], "legacy-people-tag.md")
             if x["check"] == "legacy-people-tag"]
        self.assertEqual(f[0]["severity"], "MEDIUM")


class TestStatusMismatch(unittest.TestCase):
    """status-mismatch.md should have HIGH status-coherence."""

    def setUp(self):
        self.data = run_lint([str(ALPHA_KNOWLEDGE / "status-mismatch.md")])

    def test_status_coherence(self):
        checks = check_ids_for_file(self.data["findings"], "status-mismatch.md")
        self.assertIn("status-coherence", checks)

    def test_severity_high(self):
        f = [x for x in findings_for_file(self.data["findings"], "status-mismatch.md")
             if x["check"] == "status-coherence"]
        self.assertEqual(f[0]["severity"], "HIGH")


class TestStaleFile(unittest.TestCase):
    """stale-file.md should have WARNING stale."""

    def setUp(self):
        self.data = run_lint([str(ALPHA_KNOWLEDGE / "stale-file.md")])

    def test_stale_finding(self):
        checks = check_ids_for_file(self.data["findings"], "stale-file.md")
        self.assertIn("stale", checks)

    def test_severity_warning(self):
        f = [x for x in findings_for_file(self.data["findings"], "stale-file.md")
             if x["check"] == "stale"]
        self.assertEqual(f[0]["severity"], "WARNING")


class TestMissingSources(unittest.TestCase):
    """missing-sources.md (type/knowledge, no sources) should have HIGH missing-sources."""

    def setUp(self):
        self.data = run_lint([str(ALPHA_KNOWLEDGE / "missing-sources.md")])

    def test_missing_sources(self):
        checks = check_ids_for_file(self.data["findings"], "missing-sources.md")
        self.assertIn("missing-sources", checks)

    def test_severity_high(self):
        f = [x for x in findings_for_file(self.data["findings"], "missing-sources.md")
             if x["check"] == "missing-sources"]
        self.assertEqual(f[0]["severity"], "HIGH")


class TestWikiNoTopic(unittest.TestCase):
    """wiki-no-topic.md should have HIGH missing-topic-wiki-knowledge."""

    def setUp(self):
        self.data = run_lint([str(WIKI_KNOWLEDGE / "wiki-no-topic.md")])

    def test_missing_topic(self):
        checks = check_ids_for_file(self.data["findings"], "wiki-no-topic.md")
        self.assertIn("missing-topic-wiki-knowledge", checks)

    def test_severity_high(self):
        f = [x for x in findings_for_file(self.data["findings"], "wiki-no-topic.md")
             if x["check"] == "missing-topic-wiki-knowledge"]
        self.assertEqual(f[0]["severity"], "HIGH")


class TestWikiWrongScope(unittest.TestCase):
    """wiki-wrong-scope.md should have HIGH scope-destination-mismatch."""

    def setUp(self):
        self.data = run_lint([str(WIKI_KNOWLEDGE / "wiki-wrong-scope.md")])

    def test_scope_mismatch(self):
        checks = check_ids_for_file(self.data["findings"], "wiki-wrong-scope.md")
        self.assertIn("scope-destination-mismatch", checks)

    def test_severity_high(self):
        f = [x for x in findings_for_file(self.data["findings"], "wiki-wrong-scope.md")
             if x["check"] == "scope-destination-mismatch"]
        self.assertEqual(f[0]["severity"], "HIGH")


class TestManifestDelta(unittest.TestCase):
    """Two successive runs over the same files with a manifest should produce empty delta."""

    def test_empty_delta_on_second_run(self):
        with tempfile.TemporaryDirectory() as state_dir:
            scope = [str(ALPHA_KNOWLEDGE / "clean-file.md")]
            extra = ["--state-dir", state_dir, "--vault-root", str(VAULT_DIR)]

            cmd_base = [sys.executable, str(LINT_PY)] + scope + ["--json"] + extra

            # First run
            r1 = subprocess.run(cmd_base, capture_output=True, text=True)
            self.assertEqual(r1.returncode, 0, f"First run failed: {r1.stderr}")
            d1 = json.loads(r1.stdout)

            # Second run — nothing changed
            r2 = subprocess.run(cmd_base, capture_output=True, text=True)
            self.assertEqual(r2.returncode, 0, f"Second run failed: {r2.stderr}")
            d2 = json.loads(r2.stdout)

            # Delta should be empty on second run
            delta = d2["delta"]
            self.assertEqual(delta["changed"], [], f"Expected no changed files, got {delta['changed']}")
            self.assertEqual(delta["new"], [], f"Expected no new files, got {delta['new']}")


class TestExitCodeSuccess(unittest.TestCase):
    """Script should exit 0 even when findings exist."""

    def test_exit_zero_with_findings(self):
        cmd = [
            sys.executable, str(LINT_PY),
            str(ALPHA_KNOWLEDGE / "missing-updated.md"),
            "--no-manifest",
            "--vault-root", str(VAULT_DIR),
        ]
        result = subprocess.run(cmd, capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, f"Expected exit 0, got {result.returncode}")


class TestJSONOutputSchema(unittest.TestCase):
    """JSON output must include required top-level keys."""

    def setUp(self):
        self.data = run_lint([str(ALPHA_KNOWLEDGE)])

    def test_required_keys(self):
        for key in ("scope", "scanned", "delta", "findings", "summary"):
            self.assertIn(key, self.data, f"Missing key: {key}")

    def test_summary_keys(self):
        for key in ("HIGH", "MEDIUM", "WARNING", "INFO", "clean"):
            self.assertIn(key, self.data["summary"], f"Missing summary key: {key}")

    def test_finding_schema(self):
        for f in self.data["findings"]:
            self.assertIn("severity", f)
            self.assertIn("check", f)
            self.assertIn("file", f)
            self.assertIn("detail", f)
            self.assertIn(f["severity"], ("HIGH", "MEDIUM", "WARNING", "INFO"))


class TestFullScopeRun(unittest.TestCase):
    """Run over the full fixture vault and verify key findings appear."""

    def setUp(self):
        self.data = run_lint([str(VAULT_DIR / "Projects"), str(VAULT_DIR / "Wiki")])
        self.findings = self.data["findings"]
        self.check_ids = [f["check"] for f in self.findings]

    def test_scanned_multiple_files(self):
        self.assertGreater(self.data["scanned"], 5)

    def test_summary_has_high(self):
        self.assertGreater(self.data["summary"]["HIGH"], 0)

    def test_all_fixture_checks_present(self):
        expected_checks = {
            "missing-updated",
            "multiple-type-tags",
            "unknown-type-tag",
            "missing-h1",
            "multiple-h1",
            "broken-wikilink",
            "legacy-people-tag",
            "status-coherence",
            "stale",
            "missing-sources",
            "missing-topic-wiki-knowledge",
            "scope-destination-mismatch",
        }
        for check in expected_checks:
            self.assertIn(check, self.check_ids, f"Expected check '{check}' not found in findings")


# ---------------------------------------------------------------------------
# Fix G — new fixture tests
# ---------------------------------------------------------------------------

SYSTEM_DIR = VAULT_DIR / "System"
WIKI_CONTEXTS = VAULT_DIR / "Wiki" / "Contexts"


class TestExemptionTierDashboard(unittest.TestCase):
    """type/dashboard is Invariant-core-only: gets H1/status/updated/scope checks, NOT per-type.
    Regression guard for fix G1 (critic gap G1)."""

    def setUp(self):
        self.data = run_lint([str(ALPHA_KNOWLEDGE / "dashboard-type.md")])
        self.findings = findings_for_file(self.data["findings"], "dashboard-type.md")
        self.checks = [f["check"] for f in self.findings]

    def test_no_missing_sources(self):
        """Invariant-core-only: should NOT get missing-sources (per-type check)."""
        self.assertNotIn("missing-sources", self.checks,
            "type/dashboard must NOT get missing-sources (per-type check is skipped)")

    def test_no_missing_topic(self):
        """Invariant-core-only: should NOT get missing-topic-wiki-knowledge."""
        self.assertNotIn("missing-topic-wiki-knowledge", self.checks,
            "type/dashboard must NOT get topic/ per-type check")

    def test_no_structural_violation(self):
        """A well-formed dashboard file produces no HIGH structural findings."""
        high = [f for f in self.findings if f["severity"] == "HIGH"]
        self.assertEqual(high, [], f"type/dashboard should have no HIGH findings, got {high}")


class TestExemptionTierClaudeProject(unittest.TestCase):
    """type/claude-project is Structure-not-imposed: ONLY tag-validity checks apply.
    Must NOT be flagged for missing status/, updated, H1, or scope tag.
    Regression guard for fix G1 (critic gap G1)."""

    def setUp(self):
        self.data = run_lint([str(SYSTEM_DIR / "claude-project-type.md")])
        self.findings = findings_for_file(self.data["findings"], "claude-project-type.md")
        self.checks = [f["check"] for f in self.findings]

    def test_no_missing_status_tag(self):
        self.assertNotIn("missing-status-tag", self.checks,
            "type/claude-project is Structure-not-imposed: must NOT get missing-status-tag")

    def test_no_missing_updated(self):
        self.assertNotIn("missing-updated", self.checks,
            "type/claude-project is Structure-not-imposed: must NOT get missing-updated")

    def test_no_missing_h1(self):
        self.assertNotIn("missing-h1", self.checks,
            "type/claude-project is Structure-not-imposed: must NOT get missing-h1")

    def test_no_missing_scope_tag(self):
        self.assertNotIn("missing-scope-tag", self.checks,
            "type/claude-project is Structure-not-imposed: must NOT get missing-scope-tag")

    def test_no_structural_findings_at_all(self):
        """No findings at all — the file carries valid tags."""
        self.assertEqual(self.findings, [],
            f"type/claude-project should produce zero findings, got {self.findings}")


class TestExemptionTierSummary(unittest.TestCase):
    """type/summary is Structure-not-imposed: ONLY tag-validity checks apply.
    Regression guard for fix G1 (critic gap G1)."""

    def setUp(self):
        self.data = run_lint([str(SYSTEM_DIR / "summary-type.md")])
        self.findings = findings_for_file(self.data["findings"], "summary-type.md")
        self.checks = [f["check"] for f in self.findings]

    def test_no_missing_status_tag(self):
        self.assertNotIn("missing-status-tag", self.checks,
            "type/summary is Structure-not-imposed: must NOT get missing-status-tag")

    def test_no_missing_updated(self):
        self.assertNotIn("missing-updated", self.checks,
            "type/summary is Structure-not-imposed: must NOT get missing-updated")

    def test_no_missing_scope_tag(self):
        self.assertNotIn("missing-scope-tag", self.checks,
            "type/summary is Structure-not-imposed: must NOT get missing-scope-tag")

    def test_no_structural_findings(self):
        self.assertEqual(self.findings, [],
            f"type/summary should produce zero findings, got {self.findings}")


class TestProjectPointerStubDrift(unittest.TestCase):
    """type/project-pointer with project/nonexistent should get HIGH stub-drift."""

    def setUp(self):
        self.data = run_lint([str(WIKI_CONTEXTS / "stub-drift-pointer.md")])
        self.findings = findings_for_file(self.data["findings"], "stub-drift-pointer.md")
        self.checks = [f["check"] for f in self.findings]

    def test_stub_drift_found(self):
        self.assertIn("stub-drift", self.checks, "Expected stub-drift finding")

    def test_stub_drift_severity(self):
        f = [x for x in self.findings if x["check"] == "stub-drift"]
        self.assertTrue(f)
        self.assertEqual(f[0]["severity"], "HIGH")


class TestProjectPointerMissingRequired(unittest.TestCase):
    """type/project-pointer missing project/ and topic/ should get HIGH findings."""

    def setUp(self):
        self.data = run_lint([str(WIKI_CONTEXTS / "pointer-missing-required.md")])
        self.findings = findings_for_file(self.data["findings"], "pointer-missing-required.md")
        self.checks = [f["check"] for f in self.findings]

    def test_missing_project_tag(self):
        self.assertIn("missing-project-tag", self.checks,
            "type/project-pointer without project/ must get missing-project-tag")

    def test_missing_topic_tag(self):
        self.assertIn("missing-topic-tag", self.checks,
            "type/project-pointer without topic/ must get missing-topic-tag (unconditional)")

    def test_severities_high(self):
        for check in ("missing-project-tag", "missing-topic-tag"):
            f = [x for x in self.findings if x["check"] == check]
            self.assertTrue(f, f"No finding for {check}")
            self.assertEqual(f[0]["severity"], "HIGH", f"{check} should be HIGH")


class TestCrossProjectBarePath(unittest.TestCase):
    """Cross-project bare path reference should get MEDIUM cross-project-bare-path."""

    def setUp(self):
        self.data = run_lint([str(ALPHA_KNOWLEDGE / "cross-project-bare-path.md")])
        self.findings = findings_for_file(self.data["findings"], "cross-project-bare-path.md")
        self.checks = [f["check"] for f in self.findings]

    def test_cross_project_bare_path(self):
        self.assertIn("cross-project-bare-path", self.checks)

    def test_severity_medium(self):
        f = [x for x in self.findings if x["check"] == "cross-project-bare-path"]
        self.assertEqual(f[0]["severity"], "MEDIUM")


class TestOrphanIndexEntry(unittest.TestCase):
    """index.md with an entry pointing to nonexistent file should get MEDIUM orphan-index-entry."""

    def setUp(self):
        self.data = run_lint([str(ALPHA_KNOWLEDGE)])
        self.checks = [f["check"] for f in self.data["findings"]]

    def test_orphan_index_entry(self):
        self.assertIn("orphan-index-entry", self.checks,
            "index.md with bad entry must produce orphan-index-entry")


class TestMissingIndexEntry(unittest.TestCase):
    """Project-hosted file not in index.md should get MEDIUM missing-index-entry."""

    def setUp(self):
        self.data = run_lint([str(ALPHA_KNOWLEDGE / "not-in-index.md")])
        self.findings = findings_for_file(self.data["findings"], "not-in-index.md")
        self.checks = [f["check"] for f in self.findings]

    def test_missing_index_entry(self):
        self.assertIn("missing-index-entry", self.checks)

    def test_severity_medium(self):
        f = [x for x in self.findings if x["check"] == "missing-index-entry"]
        self.assertEqual(f[0]["severity"], "MEDIUM")


class TestDepthLimitViolation(unittest.TestCase):
    """Tag with depth > max should get HIGH tag-depth-exceeded."""

    def setUp(self):
        self.data = run_lint([str(ALPHA_KNOWLEDGE / "depth-limit-violation.md")])
        self.findings = findings_for_file(self.data["findings"], "depth-limit-violation.md")
        self.checks = [f["check"] for f in self.findings]

    def test_tag_depth_exceeded(self):
        self.assertIn("tag-depth-exceeded", self.checks)

    def test_severity_high(self):
        f = [x for x in self.findings if x["check"] == "tag-depth-exceeded"]
        self.assertEqual(f[0]["severity"], "HIGH")


class TestLegacyPhaseTag(unittest.TestCase):
    """Legacy phase/* tag should get MEDIUM legacy-phase-tag."""

    def setUp(self):
        self.data = run_lint([str(ALPHA_KNOWLEDGE / "legacy-phase-tag.md")])
        self.findings = findings_for_file(self.data["findings"], "legacy-phase-tag.md")
        self.checks = [f["check"] for f in self.findings]

    def test_legacy_phase_tag(self):
        self.assertIn("legacy-phase-tag", self.checks)

    def test_severity_medium(self):
        f = [x for x in self.findings if x["check"] == "legacy-phase-tag"]
        self.assertEqual(f[0]["severity"], "MEDIUM")


class TestMissingScopeTag(unittest.TestCase):
    """File without project/ or area/ should get HIGH missing-scope-tag."""

    def setUp(self):
        self.data = run_lint([str(ALPHA_KNOWLEDGE / "missing-scope-tag.md")])
        self.findings = findings_for_file(self.data["findings"], "missing-scope-tag.md")
        self.checks = [f["check"] for f in self.findings]

    def test_missing_scope_tag(self):
        self.assertIn("missing-scope-tag", self.checks)

    def test_severity_high(self):
        f = [x for x in self.findings if x["check"] == "missing-scope-tag"]
        self.assertEqual(f[0]["severity"], "HIGH")


class TestMissingStatusTag(unittest.TestCase):
    """Governed file without status/ should get HIGH missing-status-tag."""

    def setUp(self):
        self.data = run_lint([str(ALPHA_KNOWLEDGE / "missing-status-tag.md")])
        self.findings = findings_for_file(self.data["findings"], "missing-status-tag.md")
        self.checks = [f["check"] for f in self.findings]

    def test_missing_status_tag(self):
        self.assertIn("missing-status-tag", self.checks)

    def test_severity_high(self):
        f = [x for x in self.findings if x["check"] == "missing-status-tag"]
        self.assertEqual(f[0]["severity"], "HIGH")


class TestMultipleStatusTags(unittest.TestCase):
    """File with two status/ tags should get HIGH multiple-status-tags."""

    def setUp(self):
        self.data = run_lint([str(ALPHA_KNOWLEDGE / "multiple-status-tags.md")])
        self.findings = findings_for_file(self.data["findings"], "multiple-status-tags.md")
        self.checks = [f["check"] for f in self.findings]

    def test_multiple_status_tags(self):
        self.assertIn("multiple-status-tags", self.checks)

    def test_severity_high(self):
        f = [x for x in self.findings if x["check"] == "multiple-status-tags"]
        self.assertEqual(f[0]["severity"], "HIGH")


class TestContextPageCoverageGap(unittest.TestCase):
    """Wiki Knowledge file with area/finance but no finance-context.md should get WARNING missing-context-page."""

    def setUp(self):
        wiki_dir = VAULT_DIR / "Wiki"
        self.data = run_lint([str(wiki_dir)])
        self.checks = [f["check"] for f in self.data["findings"]]

    def test_missing_context_page(self):
        self.assertIn("missing-context-page", self.checks,
            "area/finance has Wiki/Knowledge files but no Contexts/finance-context.md")


class TestTopicConsolidationCandidates(unittest.TestCase):
    """Similar topic tags (topic/workout / topic/workouts) should surface as consolidation candidates."""

    def setUp(self):
        wiki_dir = VAULT_DIR / "Wiki"
        self.data = run_lint([str(wiki_dir)])
        self.candidates = [f for f in self.data["findings"] if f["check"] == "topic-consolidation-candidate"]

    def test_consolidation_candidate_found(self):
        self.assertGreater(len(self.candidates), 0,
            "topic/workout and topic/workouts should be topic-consolidation-candidate")

    def test_severity_info(self):
        self.assertEqual(self.candidates[0]["severity"], "INFO")


class TestStaleSuspectsMissingTarget(unittest.TestCase):
    """stale_suspects pointing to nonexistent file should get WARNING stale-suspects-missing-target."""

    def setUp(self):
        self.data = run_lint([str(WIKI_KNOWLEDGE / "stale-suspects-missing.md")])
        self.findings = findings_for_file(self.data["findings"], "stale-suspects-missing.md")
        self.checks = [f["check"] for f in self.findings]

    def test_stale_suspects_missing_target(self):
        self.assertIn("stale-suspects-missing-target", self.checks)

    def test_severity_warning(self):
        f = [x for x in self.findings if x["check"] == "stale-suspects-missing-target"]
        self.assertEqual(f[0]["severity"], "WARNING")


class TestDeprecatedTypeRaw(unittest.TestCase):
    """type/raw is deprecated: should get MEDIUM deprecated-type (NOT HIGH unknown-type-tag).
    Fix C: derived from contract, not hardcoded."""

    def setUp(self):
        self.data = run_lint([str(ALPHA_KNOWLEDGE / "deprecated-type-raw.md")])
        self.findings = findings_for_file(self.data["findings"], "deprecated-type-raw.md")
        self.checks = [f["check"] for f in self.findings]

    def test_deprecated_type_check(self):
        self.assertIn("deprecated-type", self.checks,
            "type/raw should produce deprecated-type finding")

    def test_severity_medium(self):
        f = [x for x in self.findings if x["check"] == "deprecated-type"]
        self.assertTrue(f)
        self.assertEqual(f[0]["severity"], "MEDIUM",
            "deprecated-type must be MEDIUM, not HIGH")

    def test_not_unknown_type_tag(self):
        self.assertNotIn("unknown-type-tag", self.checks,
            "Deprecated type should NOT produce unknown-type-tag (that's for truly unknown types)")


class TestFormatTextOutput(unittest.TestCase):
    """--format text output path runs and produces non-empty output."""

    def test_format_text_produces_output(self):
        cmd = [
            sys.executable, str(LINT_PY),
            str(ALPHA_KNOWLEDGE / "clean-file.md"),
            "--format", "text",
            "--no-manifest",
            "--vault-root", str(VAULT_DIR),
        ]
        result = subprocess.run(cmd, capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, f"format text failed: {result.stderr}")
        self.assertIn("Lint report", result.stdout, "Expected 'Lint report' header in text output")
        self.assertGreater(len(result.stdout), 0, "Text output should be non-empty")


class TestNoManifestDeltaNull(unittest.TestCase):
    """--no-manifest run should yield delta with null/empty fields."""

    def test_no_manifest_delta_null(self):
        data = run_lint([str(ALPHA_KNOWLEDGE / "clean-file.md")])
        delta = data.get("delta", {})
        # Per spec: delta fields are null when no-manifest
        self.assertIsNone(delta.get("changed"),
            "delta.changed should be null with --no-manifest")
        self.assertIsNone(delta.get("new"),
            "delta.new should be null with --no-manifest")
        self.assertIsNone(delta.get("deleted"),
            "delta.deleted should be null with --no-manifest")


class TestTighteningField(unittest.TestCase):
    """Findings from [tightening] checks should carry tightening: true (fix F)."""

    def test_missing_status_tag_has_tightening_field(self):
        data = run_lint([str(ALPHA_KNOWLEDGE / "missing-status-tag.md")])
        findings = findings_for_file(data["findings"], "missing-status-tag.md")
        status_findings = [f for f in findings if f["check"] == "missing-status-tag"]
        self.assertTrue(status_findings, "No missing-status-tag finding found")
        f = status_findings[0]
        self.assertTrue(f.get("tightening"),
            "missing-status-tag is a [tightening] check and must carry tightening: true")

    def test_missing_h1_has_tightening_field(self):
        data = run_lint([str(ALPHA_KNOWLEDGE / "no-h1.md")])
        findings = findings_for_file(data["findings"], "no-h1.md")
        h1_findings = [f for f in findings if f["check"] == "missing-h1"]
        self.assertTrue(h1_findings, "No missing-h1 finding found")
        f = h1_findings[0]
        self.assertTrue(f.get("tightening"),
            "missing-h1 is a [tightening] check and must carry tightening: true")

    def test_non_tightening_finding_no_tightening_field(self):
        data = run_lint([str(ALPHA_KNOWLEDGE / "broken-wikilink.md")])
        findings = findings_for_file(data["findings"], "broken-wikilink.md")
        broken = [f for f in findings if f["check"] == "broken-wikilink"]
        self.assertTrue(broken, "No broken-wikilink finding")
        f = broken[0]
        # Non-tightening check should not have tightening: true
        self.assertFalse(f.get("tightening", False),
            "broken-wikilink is NOT a tightening check and must not carry tightening: true")


class TestEmptyParseGuardBrokenContract(unittest.TestCase):
    """Script must fail loud (non-zero exit) when structural-contract.md's Scope
    Boundaries section is malformed (missing the Location Gate or Exemption tiers
    table)."""

    def test_missing_exemption_tiers_fails_loud(self):
        import tempfile, os, shutil
        with tempfile.TemporaryDirectory() as tmpdir:
            # Copy fixture vault into temp dir
            tmp_vault = Path(tmpdir) / "vault"
            shutil.copytree(str(VAULT_DIR), str(tmp_vault))
            # Write a structural-contract.md that lacks the Exemption tiers table
            broken_sc = tmp_vault / "Wiki" / "spec" / "structural-contract.md"
            broken_sc.write_text(
                "# Structural Contract\n\n## Invariant Core\n\n"
                "| Element | Requirement |\n|---|---|\n"
                "| `type/` tag | Exactly one |\n\n"
                "## Per-Type Additions\n\n"
                "| `type/` | Also requires | `sources` |\n|---|---|---|\n"
                "| `type/knowledge` | `topic/` — Wiki-hosted only | Required |\n\n"
                "## Destination Modifiers\n\n"
                "| Aspect | Wiki-hosted | Project-hosted |\n|---|---|---|\n"
                "| Scope tag | `area/<hierarchy>` | `project/<name>` |\n\n"
                "## Scope Boundaries\n\nNo exemption tiers table here.\n\n"
                "## Freshness\n\n| Field | Meaning | Requirement |\n|---|---|---|\n"
                "| `updated` | File last touched | Required |\n",
                encoding="utf-8"
            )
            cmd = [
                sys.executable, str(LINT_PY),
                str(tmp_vault / "Projects" / "alpha" / "Knowledge" / "clean-file.md"),
                "--json", "--no-manifest",
                "--vault-root", str(tmp_vault),
            ]
            result = subprocess.run(cmd, capture_output=True, text=True)
            self.assertNotEqual(result.returncode, 0,
                "Script should exit non-zero when the Scope Boundaries tables are missing from structural-contract.md")
            # The parser checks Location Gate first, then Exemption tiers — a
            # Scope Boundaries section missing both must name at least one.
            self.assertTrue(
                "Exemption tiers" in result.stderr or "Location Gate" in result.stderr,
                "Error message should name the missing Scope Boundaries table")


ALPHA_SUBKNOWLEDGE = VAULT_DIR / "Projects" / "alpha" / "Knowledge" / "SubKnowledge"
SYSTEM_DIR_FOR_IDX = VAULT_DIR / "System"


class TestFolderQualifiedWikilinkResolution(unittest.TestCase):
    """Folder-qualified wikilinks like [[SubKnowledge/subfolder-note]] must resolve
    if the file exists anywhere in the vault, not just via exact full-path match.

    Regression guard for the path-qualified suffix-resolution fix.
    """

    def test_valid_folder_qualified_link_not_flagged(self):
        """[[SubKnowledge/subfolder-note]] exists at .../SubKnowledge/subfolder-note.md;
        must NOT produce broken-wikilink."""
        data = run_lint([str(ALPHA_KNOWLEDGE / "folder-qualified-valid.md")])
        findings = findings_for_file(data["findings"], "folder-qualified-valid.md")
        broken = [f for f in findings if f["check"] == "broken-wikilink"]
        self.assertEqual(broken, [],
            f"[[SubKnowledge/subfolder-note]] exists and must not be flagged broken; got {broken}")

    def test_broken_folder_qualified_link_is_flagged(self):
        """[[SubKnowledge/no-such-note]] does not exist anywhere; must produce broken-wikilink MEDIUM."""
        data = run_lint([str(ALPHA_KNOWLEDGE / "folder-qualified-broken.md")])
        findings = findings_for_file(data["findings"], "folder-qualified-broken.md")
        broken = [f for f in findings if f["check"] == "broken-wikilink"]
        self.assertTrue(broken,
            "[[SubKnowledge/no-such-note]] does not exist and must be flagged broken")
        self.assertTrue(any("no-such-note" in f["detail"] for f in broken),
            "broken-wikilink detail must mention no-such-note")
        self.assertEqual(broken[0]["severity"], "MEDIUM",
            "broken-wikilink must be MEDIUM severity (vault entropy, not an envelope violation)")

    def test_segment_boundary_bare_name_not_resolved_by_longer_stem(self):
        """[[note]] must NOT match subfolder-note.md — segment boundary means exact stem
        equality for bare names; 'note' is a string-suffix but not a segment-suffix."""
        data = run_lint([str(ALPHA_KNOWLEDGE / "segment-boundary.md")])
        findings = findings_for_file(data["findings"], "segment-boundary.md")
        broken = [f for f in findings if f["check"] == "broken-wikilink"]
        self.assertTrue(broken,
            "[[note]] must be flagged broken — 'subfolder-note' stem != 'note'")
        self.assertTrue(any("note" in f["detail"] for f in broken),
            "broken-wikilink detail must mention the target 'note'")


class TestFolderQualifiedIndexEntry(unittest.TestCase):
    """index.md entries using folder-qualified paths like [[SubKnowledge/subfolder-note]]
    must resolve correctly and must NOT produce orphan-index-entry.

    Regression guard for the orphan-index-entry false-positive fix.
    """

    def test_valid_folder_qualified_index_entry_not_orphaned(self):
        """[[SubKnowledge/subfolder-note]] in index.md must NOT produce orphan-index-entry
        because the file exists at Projects/alpha/Knowledge/SubKnowledge/subfolder-note.md."""
        data = run_lint([str(SYSTEM_DIR_FOR_IDX / "subknowledge-index.md")])
        findings = data["findings"]
        orphans = [f for f in findings if f["check"] == "orphan-index-entry"]
        self.assertEqual(orphans, [],
            f"Folder-qualified index entry [[SubKnowledge/subfolder-note]] must not be "
            f"orphaned (file exists); got {orphans}")


class TestBrokenWikilinkRenameCandidateDetection(unittest.TestCase):
    """Before reporting a wikilink target as missing, search the vault-wide
    file inventory for a moved/renamed candidate (exact basename elsewhere,
    or stem match ignoring a '-vN' version suffix) and downgrade to a WARNING
    judgment call instead of asserting absence. Also: the existence check
    must consult files of any extension, not just .md notes, so an existing
    non-md attachment produces no finding at all.

    Regression guard for the production-triage false-positive fixes: (1)
    broken-link check declaring renamed/moved docs missing with no
    rename/basename pass, (2) the link resolver only indexing *.md.
    """

    def setUp(self):
        self.data = run_lint([str(ALPHA_KNOWLEDGE / "rename-candidate-detection.md")])
        self.findings = findings_for_file(self.data["findings"], "rename-candidate-detection.md")
        self.broken = [f for f in self.findings if f["check"] == "broken-wikilink"]

    def test_moved_to_sibling_folder_downgrades_to_warning(self):
        """[[Retired/moved-target-note]] doesn't resolve under Retired/, but
        moved-target-note.md exists elsewhere in the vault (CurrentFolder/) --
        must downgrade to WARNING with a moved/renamed-candidate detail, not a
        flat MEDIUM missing-target finding."""
        hits = [f for f in self.broken if "moved-target-note" in f["detail"]]
        self.assertTrue(hits, "Expected a broken-wikilink finding referencing moved-target-note")
        self.assertEqual(hits[0]["severity"], "WARNING",
            "Renamed/moved candidate must downgrade to WARNING, not MEDIUM")
        self.assertIn("moved/renamed candidate", hits[0]["detail"])
        self.assertIn("CurrentFolder/moved-target-note.md", hits[0]["detail"],
            "Detail must name the actual candidate path")

    def test_version_suffix_stem_match_downgrades_to_warning(self):
        """[[versioned-doc]] has no exact stem match, but versioned-doc-v2.md
        does once the '-vN' suffix is stripped for comparison -- must also
        downgrade to WARNING."""
        hits = [f for f in self.broken if "versioned-doc" in f["detail"]]
        self.assertTrue(hits, "Expected a broken-wikilink finding referencing versioned-doc")
        self.assertEqual(hits[0]["severity"], "WARNING")
        self.assertIn("moved/renamed candidate", hits[0]["detail"])
        self.assertIn("versioned-doc-v2.md", hits[0]["detail"])

    def test_existing_pdf_attachment_produces_no_finding(self):
        """[[Attachments/report.pdf]] exists on disk -- the link resolver must
        consult files of any extension, not just .md, so this produces NO
        finding at all (not even a downgraded one)."""
        hits = [f for f in self.findings if "report.pdf" in f["detail"]]
        self.assertEqual(hits, [], f"Existing PDF attachment must produce no finding at all; got {hits}")

    def test_genuinely_missing_target_still_fires_medium(self):
        """[[totally-fabricated-nonexistent-xyz]] matches no file under any
        name or version-stripped stem -- must still fire the original MEDIUM
        broken-wikilink finding (no false downgrade)."""
        hits = [f for f in self.broken if "totally-fabricated-nonexistent-xyz" in f["detail"]]
        self.assertTrue(hits, "Expected a broken-wikilink finding for the genuinely missing target")
        self.assertEqual(hits[0]["severity"], "MEDIUM",
            "Genuinely missing target must stay MEDIUM, not downgrade")
        self.assertNotIn("moved/renamed candidate", hits[0]["detail"])


# ---------------------------------------------------------------------------
# Code-context stripping — regression tests for the strip_code_context fix
# ---------------------------------------------------------------------------

class TestCodeContextBashBlock(unittest.TestCase):
    """Fenced bash block with [[ ]] conditionals and # comment lines must NOT produce
    broken-wikilink or multiple-h1 / missing-h1.  Regression guard for the
    strip_code_context fix."""

    def setUp(self):
        self.data = run_lint([str(ALPHA_KNOWLEDGE / "code-context-bash-block.md")])
        self.findings = findings_for_file(self.data["findings"], "code-context-bash-block.md")
        self.checks = [f["check"] for f in self.findings]

    def test_no_broken_wikilink_from_bash_conditionals(self):
        """[[ -d "$X" ]] and [[ "$TOOL" == "Grep" && -d "$Y" ]] inside fenced block
        must NOT be extracted as wikilink targets."""
        broken = [f for f in self.findings if f["check"] == "broken-wikilink"]
        self.assertEqual(broken, [],
            f"bash [[ ]] conditionals in fenced block must not produce broken-wikilink; got {broken}")

    def test_no_false_multiple_h1_from_shell_comments(self):
        """# shell comment lines inside fenced block must NOT be counted as H1 headings."""
        multi = [f for f in self.findings if f["check"] == "multiple-h1"]
        self.assertEqual(multi, [],
            f"# comment lines in fenced block must not produce multiple-h1; got {multi}")

    def test_no_false_missing_h1(self):
        """The real # heading in prose must still be found (no missing-h1 false negative)."""
        self.assertNotIn("missing-h1", self.checks,
            "The real prose H1 must be detected; must not produce missing-h1")


class TestCodeContextInlinePlaceholder(unittest.TestCase):
    """`[[placeholder]]` inside an inline code span must NOT produce broken-wikilink.
    Regression guard for the strip_code_context inline-code fix."""

    def setUp(self):
        self.data = run_lint([str(ALPHA_KNOWLEDGE / "code-context-inline-placeholder.md")])
        self.findings = findings_for_file(self.data["findings"], "code-context-inline-placeholder.md")
        self.checks = [f["check"] for f in self.findings]

    def test_no_broken_wikilink_from_inline_code(self):
        """`[[wikilink]]` and `[[placeholder]]` inside backtick spans must NOT fire broken-wikilink."""
        broken = [f for f in self.findings if f["check"] == "broken-wikilink"]
        # The only wikilink in prose is [[clean-file]] which exists; should be no broken links
        self.assertEqual(broken, [],
            f"[[placeholder]] in inline code must not produce broken-wikilink; got {broken}")


class TestProseBrokenWikilinkStillFires(unittest.TestCase):
    """A genuine [[really-missing-note]] in prose (not code) must STILL fire broken-wikilink
    HIGH after code-context stripping.  No false negatives."""

    def setUp(self):
        self.data = run_lint([str(ALPHA_KNOWLEDGE / "prose-broken-wikilink.md")])
        self.findings = findings_for_file(self.data["findings"], "prose-broken-wikilink.md")

    def test_broken_wikilink_fires(self):
        """[[really-missing-note]] in prose must produce broken-wikilink."""
        broken = [f for f in self.findings if f["check"] == "broken-wikilink"]
        self.assertTrue(broken,
            "Genuine broken wikilink in prose must still produce broken-wikilink after fix")

    def test_broken_wikilink_targets_correct_note(self):
        broken = [f for f in self.findings if f["check"] == "broken-wikilink"]
        self.assertTrue(any("really-missing-note" in f["detail"] for f in broken),
            "broken-wikilink detail must mention really-missing-note")

    def test_severity_medium(self):
        # broken-wikilink is MEDIUM: vault entropy, not an envelope violation.
        broken = [f for f in self.findings if f["check"] == "broken-wikilink"]
        self.assertTrue(broken)
        self.assertEqual(broken[0]["severity"], "MEDIUM")


class TestProseMultipleH1StillFires(unittest.TestCase):
    """A genuine second # Heading in prose (not code) must STILL fire multiple-h1 HIGH
    after code-context stripping.  No false negatives."""

    def setUp(self):
        self.data = run_lint([str(ALPHA_KNOWLEDGE / "prose-multiple-h1.md")])
        self.findings = findings_for_file(self.data["findings"], "prose-multiple-h1.md")

    def test_multiple_h1_fires(self):
        """Two real H1 headings in prose must produce multiple-h1."""
        multi = [f for f in self.findings if f["check"] == "multiple-h1"]
        self.assertTrue(multi,
            "Genuine multiple H1 in prose must still produce multiple-h1 after fix")

    def test_severity_high(self):
        multi = [f for f in self.findings if f["check"] == "multiple-h1"]
        self.assertTrue(multi)
        self.assertEqual(multi[0]["severity"], "HIGH")


class TestCodeContextBarePathInCode(unittest.TestCase):
    """Projects/beta/... inside a fenced code block must NOT produce cross-project-bare-path.
    Regression guard for the strip_code_context bare-path fix."""

    def setUp(self):
        self.data = run_lint([str(ALPHA_KNOWLEDGE / "code-context-bare-path-in-code.md")])
        self.findings = findings_for_file(self.data["findings"], "code-context-bare-path-in-code.md")
        self.checks = [f["check"] for f in self.findings]

    def test_no_cross_project_bare_path_in_code(self):
        """Projects/beta/ path inside fenced code block must NOT fire cross-project-bare-path."""
        bare = [f for f in self.findings if f["check"] == "cross-project-bare-path"]
        self.assertEqual(bare, [],
            f"Projects/beta/ in fenced code block must not produce cross-project-bare-path; got {bare}")


class TestProseBarepathStillFires(unittest.TestCase):
    """Projects/beta/... in prose (not in code) must STILL fire cross-project-bare-path.
    No false negatives."""

    def setUp(self):
        self.data = run_lint([str(ALPHA_KNOWLEDGE / "prose-bare-path.md")])
        self.findings = findings_for_file(self.data["findings"], "prose-bare-path.md")

    def test_cross_project_bare_path_fires(self):
        """Projects/beta/ in prose must still produce cross-project-bare-path after fix."""
        bare = [f for f in self.findings if f["check"] == "cross-project-bare-path"]
        self.assertTrue(bare,
            "Genuine cross-project bare path in prose must still produce cross-project-bare-path after fix")

    def test_severity_medium(self):
        bare = [f for f in self.findings if f["check"] == "cross-project-bare-path"]
        self.assertTrue(bare)
        self.assertEqual(bare[0]["severity"], "MEDIUM")


class TestEmbedNotFlaggedAsWikilink(unittest.TestCase):
    """![[...]] embeds must NOT be flagged broken-wikilink, but a genuine
    [[link]] in the same file MUST still be scanned. Regression guard for the
    embed false-positive -- the 3rd broken-wikilink false-positive class."""

    def setUp(self):
        self.data = run_lint([str(ALPHA_KNOWLEDGE / "embed-attachment.md")])
        self.findings = findings_for_file(self.data["findings"], "embed-attachment.md")

    def test_embeds_not_flagged(self):
        """![[example-diagram.webp]] and ![[another-note]] must not fire broken-wikilink."""
        broken = [f for f in self.findings if f["check"] == "broken-wikilink"]
        targets = [f["detail"] for f in broken]
        self.assertFalse(
            any("example-diagram" in d or "another-note" in d for d in targets),
            f"![[...]] embeds must not produce broken-wikilink; got {targets}")

    def test_genuine_link_still_fires(self):
        """The genuine [[truly-absent-xyz]] link in the same file MUST still fire --
        the embed exclusion must not suppress real links."""
        broken = [f for f in self.findings if f["check"] == "broken-wikilink"]
        self.assertTrue(
            any("truly-absent-xyz" in f["detail"] for f in broken),
            "Genuine broken [[link]] must still fire after the embed exclusion")


# ---------------------------------------------------------------------------
# Scope boundary — Location Gate + Type Gate (the right-sizing deliverable)
#
# Each fixture below sits in an UNGOVERNED location (or carries an out-of-scope
# type/) and is DELIBERATELY malformed — two type/ tags, no H1 (or two H1s),
# no status/, no updated, unknown namespace, broken wikilinks. If the Location
# Gate / Type Gate excludes it correctly, lint produces ZERO findings for it.
# If a future edit re-includes the location, these tests catch a flood of
# findings. Without these, the central right-sizing deliverable is untested.
# ---------------------------------------------------------------------------

class TestLocationGateWikiData(unittest.TestCase):
    """Wiki/Data/** is domain content — ungoverned. A deliberately broken file
    there must produce zero findings."""

    def setUp(self):
        self.data = run_lint([str(VAULT_DIR / "Wiki" / "Data")])
        self.findings = findings_for_file(self.data["findings"], "ungoverned-data-record.md")

    def test_zero_findings(self):
        self.assertEqual(
            self.findings, [],
            f"Wiki/Data file is ungoverned by the Location Gate — expected zero "
            f"findings, got {[f['check'] for f in self.findings]}")


class TestLocationGateProjectScratch(unittest.TestCase):
    """Projects/<name>/Research/** is raw operational scratch — ungoverned."""

    def setUp(self):
        self.data = run_lint([str(VAULT_DIR / "Projects" / "alpha" / "Research")])
        self.findings = findings_for_file(self.data["findings"], "ungoverned-scratch.md")

    def test_zero_findings(self):
        self.assertEqual(
            self.findings, [],
            f"Projects/alpha/Research file is ungoverned — expected zero findings, "
            f"got {[f['check'] for f in self.findings]}")


class TestLocationGateArchivedSegment(unittest.TestCase):
    """An Archived/ path segment inside a governed Knowledge/ tree excludes the
    file — the archive universal exclusion overrides a governed location."""

    def setUp(self):
        self.data = run_lint([str(ALPHA_KNOWLEDGE)])
        self.findings = findings_for_file(self.data["findings"], "ungoverned-archived.md")

    def test_zero_findings(self):
        self.assertEqual(
            self.findings, [],
            f"File under Archived/ is excluded — expected zero findings, got "
            f"{[f['check'] for f in self.findings]}")


class TestLocationGateArchiveFilename(unittest.TestCase):
    """A *-archive.md file in a governed Knowledge/ folder is excluded by the
    archive-name universal exclusion."""

    def setUp(self):
        self.data = run_lint([str(ALPHA_KNOWLEDGE)])
        self.findings = findings_for_file(self.data["findings"], "legacy-decisions-archive.md")

    def test_zero_findings(self):
        self.assertEqual(
            self.findings, [],
            f"*-archive.md file is excluded — expected zero findings, got "
            f"{[f['check'] for f in self.findings]}")


class TestTypeGateOutOfScopeType(unittest.TestCase):
    """A file in a governed location (Wiki/Knowledge) carrying an out-of-scope
    type/ (type/data) is excluded by the Type Gate — zero findings."""

    def setUp(self):
        self.data = run_lint([str(WIKI_KNOWLEDGE)])
        self.findings = findings_for_file(self.data["findings"], "out-of-scope-type-data.md")

    def test_zero_findings(self):
        self.assertEqual(
            self.findings, [],
            f"type/data file is out of scope per the Type Gate — expected zero "
            f"findings, got {[f['check'] for f in self.findings]}")


class TestGovernedFileStillFlagged(unittest.TestCase):
    """Control: a deliberately broken file in a GOVERNED location must still be
    flagged — the scope boundary must not silence genuine knowledge-layer
    defects. Guards against an over-broad exclusion."""

    def setUp(self):
        self.data = run_lint([str(ALPHA_KNOWLEDGE)])
        self.findings = findings_for_file(self.data["findings"], "missing-status-tag.md")

    def test_governed_defect_still_fires(self):
        checks = [f["check"] for f in self.findings]
        self.assertIn(
            "missing-status-tag", checks,
            "A governed-location file with a real defect must still be flagged — "
            "the Location Gate must not over-exclude")


# ---------------------------------------------------------------------------
# tag-taxonomy-rosters.md split — person/ and area/work/ instance vocab moved
# out of tag-taxonomy.md into a separate rosters file (PII exclusion). These
# guard: (1) vocabulary still resolves correctly from the rosters file, and
# (2) the illustrative/synthetic examples left behind in tag-taxonomy.md's
# prose are never mistaken for real vocabulary.
# ---------------------------------------------------------------------------

class TestRosterResolvedPerson(unittest.TestCase):
    """person/alice-test IS in tag-taxonomy-rosters.md's roster — zero
    unrecognized-person-tag findings. Proves person/ vocab resolves from the
    rosters file, not tag-taxonomy.md."""

    def setUp(self):
        self.data = run_lint([str(ALPHA_KNOWLEDGE / "roster-resolved-person.md")])
        self.checks = check_ids_for_file(self.data["findings"], "roster-resolved-person.md")

    def test_no_unrecognized_person_tag(self):
        self.assertNotIn("unrecognized-person-tag", self.checks)


class TestTaxonomySyntheticExampleNotVocab(unittest.TestCase):
    """person/sample-placeholder appears verbatim in tag-taxonomy.md's person/
    section (marked there as an illustrative, not-real-vocabulary example) but
    is NOT in tag-taxonomy-rosters.md's roster — must still be flagged."""

    def setUp(self):
        self.data = run_lint([str(ALPHA_KNOWLEDGE / "taxonomy-synthetic-example-not-vocab.md")])
        self.findings = findings_for_file(self.data["findings"], "taxonomy-synthetic-example-not-vocab.md")
        self.checks = [f["check"] for f in self.findings]

    def test_unrecognized_person_tag(self):
        self.assertIn("unrecognized-person-tag", self.checks)

    def test_severity_warning(self):
        f = [x for x in self.findings if x["check"] == "unrecognized-person-tag"]
        self.assertEqual(f[0]["severity"], "WARNING")


class TestRosterResolvedAreaTopLevel(unittest.TestCase):
    """area/career IS in tag-taxonomy-rosters.md's area top-levels roster —
    zero unrecognized-area-tag findings. Proves area/ top-level vocab
    resolves from the rosters file, not tag-taxonomy.md's illustrative
    prose."""

    def setUp(self):
        self.data = run_lint([str(ALPHA_KNOWLEDGE / "roster-resolved-area-toplevel.md")])
        self.checks = check_ids_for_file(self.data["findings"], "roster-resolved-area-toplevel.md")

    def test_no_unrecognized_area_tag(self):
        self.assertNotIn("unrecognized-area-tag", self.checks)


class TestTaxonomySyntheticAreaExampleNotVocab(unittest.TestCase):
    """area/sample-hobby appears verbatim in tag-taxonomy.md's area/ section
    (marked there as illustrative, not real vocabulary) but is NOT in
    tag-taxonomy-rosters.md's area top-levels roster — must still be
    flagged."""

    def setUp(self):
        self.data = run_lint([str(ALPHA_KNOWLEDGE / "taxonomy-synthetic-area-example-not-vocab.md")])
        self.findings = findings_for_file(self.data["findings"], "taxonomy-synthetic-area-example-not-vocab.md")
        self.checks = [f["check"] for f in self.findings]

    def test_unrecognized_area_tag(self):
        self.assertIn("unrecognized-area-tag", self.checks)

    def test_severity_warning(self):
        f = [x for x in self.findings if x["check"] == "unrecognized-area-tag"]
        self.assertEqual(f[0]["severity"], "WARNING")


class TestRosterResolvedEmployer(unittest.TestCase):
    """area/work/acme — Acme IS in tag-taxonomy-rosters.md's employer roster —
    zero unrecognized-employer-tag findings."""

    def setUp(self):
        self.data = run_lint([str(ALPHA_KNOWLEDGE / "roster-resolved-employer.md")])
        self.checks = check_ids_for_file(self.data["findings"], "roster-resolved-employer.md")

    def test_no_unrecognized_employer_tag(self):
        self.assertNotIn("unrecognized-employer-tag", self.checks)


class TestUnrecognizedEmployer(unittest.TestCase):
    """area/work/unknownco — `work` top-level is recognized but `unknownco` is
    not in tag-taxonomy-rosters.md's employer roster — must be flagged."""

    def setUp(self):
        self.data = run_lint([str(ALPHA_KNOWLEDGE / "unrecognized-employer.md")])
        self.findings = findings_for_file(self.data["findings"], "unrecognized-employer.md")
        self.checks = [f["check"] for f in self.findings]

    def test_unrecognized_employer_tag(self):
        self.assertIn("unrecognized-employer-tag", self.checks)

    def test_severity_warning(self):
        f = [x for x in self.findings if x["check"] == "unrecognized-employer-tag"]
        self.assertEqual(f[0]["severity"], "WARNING")


if __name__ == "__main__":
    # Print a brief header
    print(f"Running lint.py tests")
    print(f"  lint.py: {LINT_PY}")
    print(f"  vault:   {VAULT_DIR}")
    print()
    unittest.main(verbosity=2)
