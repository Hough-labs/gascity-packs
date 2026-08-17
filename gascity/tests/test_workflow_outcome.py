from __future__ import annotations

import io
import json
import pathlib
import sys
import tempfile
import unittest
from contextlib import redirect_stdout

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1] / "assets" / "scripts"))

import workflow_outcome as script

ROOT_ID = "gcp-root1"


def bead(bead_id: str, status: str = "closed", **metadata: str) -> dict:
    return {"id": bead_id, "status": status, "metadata": dict(metadata)}


def fake_runner(root: dict, members: list[dict]):
    """Stand in for `gc bd`, answering the two reads the script makes."""

    calls: list[list[str]] = []

    def run(cmd):
        cmd = list(cmd)
        calls.append(cmd)
        if cmd[:3] == ["gc", "bd", "show"]:
            return json.dumps([root]) if root is not None else "[]"
        if cmd[:3] == ["gc", "bd", "list"]:
            return json.dumps(members)
        raise AssertionError(f"unexpected command: {cmd}")

    run.calls = calls  # type: ignore[attr-defined]
    return run


PASSING_REPORT = """---
schema: gc.verdict-report.v1
kind: review
verdict: pass
severity: none
findings: []
---
No blocking issues found.
"""

FAILING_VERDICT_REPORT = """---
schema: gc.verdict-report.v1
kind: review
verdict: fail
severity: major
findings:
  - id: F1
    severity: major
    title: Missing regression test
    evidence: internal/thing.go:42 has no coverage
    required_fix: Add a table-driven test for the new branch
---
One blocking finding.
"""


class ResolveWorkflowOutcomeTest(unittest.TestCase):
    def test_closed_root_stamped_pass_is_a_pass(self) -> None:
        runner = fake_runner(
            bead(ROOT_ID, "closed", **{"gc.outcome": "pass"}),
            [bead("gcp-step1", "closed", **{"gc.root_bead_id": ROOT_ID, "gc.outcome": "pass"})],
        )
        result = script.resolve_workflow_outcome(runner, ROOT_ID)
        self.assertEqual(result.outcome, "pass")
        self.assertTrue(result.passed)
        self.assertEqual(result.failed_members, [])

    def test_closed_root_stamped_fail_is_not_a_pass(self) -> None:
        runner = fake_runner(bead(ROOT_ID, "closed", **{"gc.outcome": "fail"}), [])
        result = script.resolve_workflow_outcome(runner, ROOT_ID)
        self.assertEqual(result.outcome, "fail")
        self.assertFalse(result.passed)

    def test_failed_member_fails_even_when_root_is_stamped_pass(self) -> None:
        runner = fake_runner(
            bead(ROOT_ID, "closed", **{"gc.outcome": "pass"}),
            [
                bead("gcp-ok", "closed", **{"gc.root_bead_id": ROOT_ID, "gc.outcome": "pass"}),
                bead("gcp-bad", "closed", **{"gc.root_bead_id": ROOT_ID, "gc.outcome": "fail"}),
            ],
        )
        result = script.resolve_workflow_outcome(runner, ROOT_ID)
        self.assertEqual(result.outcome, "fail")
        self.assertEqual(result.failed_members, ["gcp-bad"])

    def test_open_root_is_incomplete_not_pass(self) -> None:
        runner = fake_runner(
            bead(ROOT_ID, "open"),
            [bead("gcp-step1", "in_progress", **{"gc.root_bead_id": ROOT_ID})],
        )
        result = script.resolve_workflow_outcome(runner, ROOT_ID)
        self.assertEqual(result.outcome, "incomplete")
        self.assertFalse(result.passed)
        self.assertEqual(result.open_members, ["gcp-step1"])

    def test_failed_member_outranks_an_unfinalized_root(self) -> None:
        runner = fake_runner(
            bead(ROOT_ID, "open"),
            [
                bead("gcp-bad", "closed", **{"gc.root_bead_id": ROOT_ID, "gc.outcome": "fail"}),
                bead("gcp-next", "open", **{"gc.root_bead_id": ROOT_ID}),
            ],
        )
        result = script.resolve_workflow_outcome(runner, ROOT_ID)
        self.assertEqual(result.outcome, "fail")
        self.assertEqual(result.failed_members, ["gcp-bad"])

    def test_closed_root_without_outcome_is_unknown_not_pass(self) -> None:
        runner = fake_runner(bead(ROOT_ID, "closed"), [])
        result = script.resolve_workflow_outcome(runner, ROOT_ID)
        self.assertEqual(result.outcome, "unknown")
        self.assertFalse(result.passed)

    def test_superseded_retry_attempt_failure_is_ignored(self) -> None:
        runner = fake_runner(
            bead(ROOT_ID, "closed", **{"gc.outcome": "pass"}),
            [
                bead(
                    "gcp-attempt1",
                    "closed",
                    **{
                        "gc.root_bead_id": ROOT_ID,
                        "gc.outcome": "fail",
                        "gc.attempt": "1",
                        "gc.logical_bead_id": "gcp-step1",
                    },
                ),
                bead("gcp-step1", "closed", **{"gc.root_bead_id": ROOT_ID, "gc.outcome": "pass"}),
            ],
        )
        result = script.resolve_workflow_outcome(runner, ROOT_ID)
        self.assertEqual(result.outcome, "pass")

    def test_transient_failure_class_is_ignored(self) -> None:
        runner = fake_runner(
            bead(ROOT_ID, "closed", **{"gc.outcome": "pass"}),
            [
                bead(
                    "gcp-blip",
                    "closed",
                    **{"gc.root_bead_id": ROOT_ID, "gc.outcome": "fail", "gc.failure_class": "transient"},
                )
            ],
        )
        result = script.resolve_workflow_outcome(runner, ROOT_ID)
        self.assertEqual(result.outcome, "pass")

    def test_missing_root_is_an_error(self) -> None:
        runner = fake_runner(None, [])
        with self.assertRaises(script.WorkflowOutcomeError):
            script.resolve_workflow_outcome(runner, ROOT_ID)

    def test_empty_root_id_is_rejected(self) -> None:
        runner = fake_runner(bead(ROOT_ID), [])
        with self.assertRaises(script.WorkflowOutcomeError):
            script.resolve_workflow_outcome(runner, "   ")

    def test_root_lookup_uses_metadata_filtered_list(self) -> None:
        runner = fake_runner(bead(ROOT_ID, "closed", **{"gc.outcome": "pass"}), [])
        script.resolve_workflow_outcome(runner, ROOT_ID)
        list_cmd = next(cmd for cmd in runner.calls if cmd[:3] == ["gc", "bd", "list"])
        self.assertIn("--all", list_cmd)
        self.assertIn(f"gc.root_bead_id={ROOT_ID}", list_cmd)
        # Control beads (check, scope-check, gates) are where a workflow's
        # failure gets recorded, and gc bd list hides them by default.
        for flag in ("--include-templates", "--include-infra", "--include-gates"):
            self.assertIn(flag, list_cmd)


class ReviewGateTest(unittest.TestCase):
    def gate(self, runner, text: str) -> tuple[int, dict]:
        with tempfile.TemporaryDirectory() as tmp:
            report = pathlib.Path(tmp) / "review-report.md"
            report.write_text(text, encoding="utf-8")
            buffer = io.StringIO()
            with redirect_stdout(buffer):
                code = script.main(
                    ["review-gate", "--workflow-root", ROOT_ID, "--report", str(report)],
                    runner=runner,
                )
            payload = json.loads(buffer.getvalue()) if buffer.getvalue().strip() else {}
        return code, payload

    def test_green_control_passing_child_and_passing_report(self) -> None:
        runner = fake_runner(bead(ROOT_ID, "closed", **{"gc.outcome": "pass"}), [])
        code, payload = self.gate(runner, PASSING_REPORT)
        self.assertEqual(code, 0)
        self.assertTrue(payload["ok"])
        self.assertEqual(payload["review_outcome"], "approve")

    def test_review_findings_are_output_not_workflow_failure(self) -> None:
        runner = fake_runner(bead(ROOT_ID, "closed", **{"gc.outcome": "pass"}), [])
        code, payload = self.gate(runner, FAILING_VERDICT_REPORT)
        self.assertEqual(code, 0)
        self.assertTrue(payload["ok"])
        self.assertEqual(payload["review_outcome"], "request_changes")

    def test_failed_child_workflow_blocks_even_with_a_valid_report(self) -> None:
        runner = fake_runner(bead(ROOT_ID, "closed", **{"gc.outcome": "fail"}), [])
        code, payload = self.gate(runner, PASSING_REPORT)
        self.assertEqual(code, 1)
        self.assertFalse(payload["ok"])
        self.assertEqual(payload["outcome"], "fail")
        self.assertEqual(payload["review_outcome"], "")

    def test_unterminated_child_workflow_blocks(self) -> None:
        runner = fake_runner(bead(ROOT_ID, "in_progress"), [])
        code, payload = self.gate(runner, PASSING_REPORT)
        self.assertEqual(code, 1)
        self.assertEqual(payload["outcome"], "incomplete")

    def test_passing_child_with_unparseable_report_blocks(self) -> None:
        runner = fake_runner(bead(ROOT_ID, "closed", **{"gc.outcome": "pass"}), [])
        code, payload = self.gate(runner, "not a verdict report\n")
        self.assertEqual(code, 1)
        self.assertEqual(payload, {})

    def test_root_outcome_command_exits_nonzero_on_failure(self) -> None:
        runner = fake_runner(bead(ROOT_ID, "closed", **{"gc.outcome": "fail"}), [])
        buffer = io.StringIO()
        with redirect_stdout(buffer):
            code = script.main(["root-outcome", ROOT_ID], runner=runner)
        self.assertEqual(code, 1)
        self.assertEqual(json.loads(buffer.getvalue())["outcome"], "fail")


class RunnerParsingTest(unittest.TestCase):
    def test_invalid_json_is_reported(self) -> None:
        with self.assertRaises(script.WorkflowOutcomeError):
            script.parse_bead_list("{not json", source="gc bd show")

    def test_blank_output_is_an_empty_list(self) -> None:
        self.assertEqual(script.parse_bead_list("  \n", source="gc bd list"), [])

    def test_single_object_is_wrapped(self) -> None:
        self.assertEqual(
            script.parse_bead_list('{"id": "x"}', source="gc bd show"),
            [{"id": "x"}],
        )


if __name__ == "__main__":
    unittest.main()
