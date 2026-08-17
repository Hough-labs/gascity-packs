#!/usr/bin/env python3
"""Read the terminal outcome of a launched graph.v2 workflow.

A step that launches a child workflow with `gc sling ... --formula` gets back a
workflow root bead id and nothing else. The child's success or failure is not
implied by the artifacts it leaves on disk: a review workflow can die with its
report never written, or with a stale report from an earlier head SHA still
sitting in the artifact directory. Inferring "the child passed" from "the file
exists and parses" is how a failed gate walks a run to a pass.

graph.v2 already computes the answer. When `workflow-finalize` becomes Ready the
orchestrator aggregates its blockers into one pass/fail and closes the workflow
ROOT with that outcome (formula-spec-v2 section 3.5, "Workflow finalize"). This
module reads that engine-computed verdict instead of guessing, and it fails
closed: an unreadable, still-open, or unstamped root is never reported as a pass.

Commands:

  root-outcome <root-bead-id>
      Resolve one launched workflow's terminal outcome.

  review-gate --workflow-root <id> --report <path>
      The github-pr-review `run-review` gate: the child workflow must have
      terminated pass AND the verdict report must validate. A review report
      whose own verdict is `fail` is a review FINDING, not a workflow failure —
      it still passes this gate and maps to comment/request_changes/block.
"""

from __future__ import annotations

import argparse
import json
import subprocess
import sys
from collections.abc import Callable, Sequence
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

import github_reports
import validate_verdict_report

# Engine metadata keys (internal/beads/beadmeta). Kept as literals because this
# script talks to `gc bd` over JSON, not to the Go package.
OUTCOME_KEY = "gc.outcome"
ROOT_BEAD_ID_KEY = "gc.root_bead_id"
ATTEMPT_KEY = "gc.attempt"
FAILURE_CLASS_KEY = "gc.failure_class"
FAILURE_CLASS_TRANSIENT = "transient"

OUTCOME_PASS = "pass"
OUTCOME_FAIL = "fail"
OUTCOME_INCOMPLETE = "incomplete"
OUTCOME_UNKNOWN = "unknown"

Runner = Callable[[Sequence[str]], str]


class WorkflowOutcomeError(Exception):
    pass


CLI_ERROR_TYPES = (
    OSError,
    UnicodeDecodeError,
    WorkflowOutcomeError,
    github_reports.ValidationError,
    validate_verdict_report.ValidationError,
)


@dataclass(frozen=True)
class WorkflowResult:
    root_bead_id: str
    outcome: str
    root_status: str
    failed_members: list[str] = field(default_factory=list)
    open_members: list[str] = field(default_factory=list)
    detail: str = ""

    @property
    def passed(self) -> bool:
        return self.outcome == OUTCOME_PASS

    def as_dict(self) -> dict[str, Any]:
        return {
            "ok": self.passed,
            "root_bead_id": self.root_bead_id,
            "outcome": self.outcome,
            "root_status": self.root_status,
            "failed_members": self.failed_members,
            "open_members": self.open_members,
            "detail": self.detail,
        }


def default_runner(cmd: Sequence[str]) -> str:
    proc = subprocess.run(list(cmd), text=True, capture_output=True, check=False)
    if proc.returncode != 0:
        detail = proc.stderr.strip() or proc.stdout.strip() or f"exited {proc.returncode}"
        raise WorkflowOutcomeError(f"command failed: {' '.join(cmd)}: {detail}")
    return proc.stdout


def metadata_of(bead: dict[str, Any]) -> dict[str, str]:
    raw = bead.get("metadata") or {}
    if not isinstance(raw, dict):
        return {}
    return {str(key): str(value) for key, value in raw.items() if value is not None}


def parse_bead_list(text: str, *, source: str) -> list[dict[str, Any]]:
    stripped = text.strip()
    if not stripped:
        return []
    try:
        data = json.loads(stripped)
    except json.JSONDecodeError as exc:
        raise WorkflowOutcomeError(f"{source} returned invalid JSON: {exc}") from exc
    if isinstance(data, dict):
        data = [data]
    if not isinstance(data, list):
        raise WorkflowOutcomeError(f"{source} returned JSON that is not a bead list")
    beads: list[dict[str, Any]] = []
    for entry in data:
        if not isinstance(entry, dict):
            raise WorkflowOutcomeError(f"{source} returned a non-object bead entry")
        beads.append(entry)
    return beads


def load_root(runner: Runner, root_bead_id: str) -> dict[str, Any]:
    beads = parse_bead_list(runner(["gc", "bd", "show", root_bead_id, "--json"]), source="gc bd show")
    if not beads:
        raise WorkflowOutcomeError(f"workflow root {root_bead_id} not found")
    return beads[0]


def load_members(runner: Runner, root_bead_id: str) -> list[dict[str, Any]]:
    beads = parse_bead_list(
        runner(
            [
                "gc",
                "bd",
                "list",
                "--all",
                "--json",
                "--limit",
                "0",
                "--metadata-field",
                f"{ROOT_BEAD_ID_KEY}={root_bead_id}",
            ]
        ),
        source="gc bd list",
    )
    return [bead for bead in beads if bead.get("id") != root_bead_id]


def is_superseded_attempt(meta: dict[str, str]) -> bool:
    """Attempt beads are exempt, mirroring the engine's retry firewall.

    `internal/dispatch/runtime.go:terminalAbortScopeFailure` ignores beads that
    carry `gc.attempt`: a failed attempt that a later attempt replaced must not
    outvote the logical step's own final disposition.
    """
    return meta.get(ATTEMPT_KEY, "").strip() != ""


def is_terminal_member_failure(bead: dict[str, Any]) -> bool:
    if str(bead.get("status", "")).strip() != "closed":
        return False
    meta = metadata_of(bead)
    if meta.get(OUTCOME_KEY, "").strip() != OUTCOME_FAIL:
        return False
    if is_superseded_attempt(meta):
        return False
    return meta.get(FAILURE_CLASS_KEY, "").strip() != FAILURE_CLASS_TRANSIENT


def resolve_workflow_outcome(runner: Runner, root_bead_id: str) -> WorkflowResult:
    root_bead_id = root_bead_id.strip()
    if not root_bead_id:
        raise WorkflowOutcomeError("workflow root bead id must not be empty")
    root = load_root(runner, root_bead_id)
    members = load_members(runner, root_bead_id)

    root_status = str(root.get("status", "")).strip()
    failed = sorted(str(bead.get("id", "")) for bead in members if is_terminal_member_failure(bead))
    still_open = sorted(
        str(bead.get("id", "")) for bead in members if str(bead.get("status", "")).strip() != "closed"
    )

    # A failed member is terminal evidence on its own. Reporting it before the
    # open-member check keeps a workflow whose finalize never ran from being
    # reported as merely "incomplete" when it has already definitively failed.
    if failed:
        return WorkflowResult(
            root_bead_id=root_bead_id,
            outcome=OUTCOME_FAIL,
            root_status=root_status,
            failed_members=failed,
            open_members=still_open,
            detail=f"workflow member(s) closed {OUTCOME_KEY}={OUTCOME_FAIL}: {', '.join(failed)}",
        )

    if root_status != "closed":
        return WorkflowResult(
            root_bead_id=root_bead_id,
            outcome=OUTCOME_INCOMPLETE,
            root_status=root_status,
            open_members=still_open,
            detail=f"workflow root is {root_status or 'unreadable'}; the workflow has not terminated yet",
        )

    stamped = metadata_of(root).get(OUTCOME_KEY, "").strip()
    if not stamped:
        return WorkflowResult(
            root_bead_id=root_bead_id,
            outcome=OUTCOME_UNKNOWN,
            root_status=root_status,
            open_members=still_open,
            detail=f"workflow root closed without {OUTCOME_KEY}; treating as not passed",
        )
    return WorkflowResult(
        root_bead_id=root_bead_id,
        outcome=stamped,
        root_status=root_status,
        open_members=still_open,
        detail=f"workflow root closed {OUTCOME_KEY}={stamped}",
    )


def review_gate(runner: Runner, root_bead_id: str, report_path: Path) -> dict[str, Any]:
    """Gate `run-review`: the child workflow terminated pass AND the report validates.

    The two conditions are independent and both are required. The workflow
    outcome answers "did the review actually run to completion"; the report
    answers "is there a verdict this adapter can map to a PR comment". Neither
    substitutes for the other, which is the whole point: artifact existence is
    not evidence that the workflow succeeded.
    """
    result = resolve_workflow_outcome(runner, root_bead_id)
    payload = result.as_dict()
    payload["report_path"] = str(report_path)
    if not result.passed:
        payload["ok"] = False
        payload["review_outcome"] = ""
        return payload

    report = validate_verdict_report.validate_report_text(
        report_path.read_text(encoding="utf-8"), expected_kind="review"
    )
    # A `fail` verdict here is a review finding, not a workflow failure: it maps
    # to comment/request_changes/block and the adapter still posts it.
    payload["review_outcome"] = github_reports.review_outcome(report.verdict, report.severity)
    payload["report_verdict"] = report.verdict
    payload["report_severity"] = report.severity
    payload["ok"] = True
    return payload


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Read terminal outcomes of launched graph.v2 workflows")
    subparsers = parser.add_subparsers(dest="command", required=True)

    root_parser = subparsers.add_parser("root-outcome")
    root_parser.add_argument("root_bead_id")

    gate_parser = subparsers.add_parser("review-gate")
    gate_parser.add_argument("--workflow-root", required=True)
    gate_parser.add_argument("--report", type=Path, required=True)
    return parser.parse_args(argv)


def main(argv: list[str] | None = None, runner: Runner | None = None) -> int:
    args = parse_args(argv if argv is not None else sys.argv[1:])
    run = runner or default_runner
    try:
        if args.command == "root-outcome":
            output = resolve_workflow_outcome(run, args.root_bead_id).as_dict()
        elif args.command == "review-gate":
            output = review_gate(run, args.workflow_root, args.report)
        else:  # pragma: no cover
            raise WorkflowOutcomeError(f"unsupported command {args.command}")
    except CLI_ERROR_TYPES as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 1
    print(json.dumps(output, sort_keys=True))
    return 0 if output.get("ok") else 1


if __name__ == "__main__":
    raise SystemExit(main())
