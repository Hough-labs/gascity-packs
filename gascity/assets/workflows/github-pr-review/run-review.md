
Read the current step bead metadata, get `gc.root_bead_id`, then read workflow
root metadata with `gc bd show <root-bead-id> --json`. Required workflow root
metadata keys are `gc.github.source_bead_id`, `gc.github.repo`,
`gc.github.number`, `gc.github.url`, `gc.github.head_sha`,
`gc.github.snapshot_path`, and `gc.github.review_dir`.

If workflow root metadata has `gc.github.reused_current_output=true`, do not
launch the generic `review` formula. Instead validate the reused
`gc.github.review_report_path` with
`{{pack_root}}/assets/scripts/github_reports.py review-outcome`, verify it
lives under `gc.github.review_dir`, refresh `gc.github.review_outcome` from the
validator result, close this step with `gc.outcome=pass`, and leave the reused
artifacts untouched. This is the no-op path that makes current-head reuse
effective even though the formula graph still schedules this step.

Create the deterministic generic-review handoff artifacts for this head SHA:

- `SUBJECT_PATH=<gc.github.review_dir>/subject.md`
- `REPORT_PATH=<gc.github.review_dir>/review-report.md`

Write `SUBJECT_PATH` as a Markdown review subject that includes the PR URL
{{github_pr_url}}, repo, PR number, head SHA, snapshot JSON path, and explicit
instructions to review the PR diff/head for correctness, tests, security,
maintainability, and release risk. Keep large payloads in artifact files; the
subject may point to the snapshot instead of embedding it.

Launch the selected targetless code-review methodology formula with explicit
paths. The default is `review`; toolkit adapters may override
`code_review_formula` without changing GitHub snapshot, comment, or finalize
behavior. Compatibility with the requested modes was validated at the snapshot
gate. Pass review_mode {{review_mode}} and interaction_mode
{{interaction_mode}} through when the selected formula accepts them; the PR
adapter itself never mutates code regardless of review mode.

Launch with `--json` and keep the child workflow root id: it is the only handle
on the launched run's outcome, and this step is not allowed to close pass
without it. If workflow root metadata already carries
`gc.github.review_workflow_id`, a previous attempt at this step already
launched the child — resume that id instead of slinging a second review.

```bash
ROOT_BEAD_ID="<root-bead-id>"   # gc.root_bead_id from this step's metadata
REVIEW_LAUNCH_JSON="$(gc sling gc.run-operator {{code_review_formula}} --formula --json \
  --var context_path="{{context_path}}" \
  --var subject_path="$SUBJECT_PATH" \
  --var report_path="$REPORT_PATH" \
  --var interaction_mode="{{interaction_mode}}" \
  --var review_mode="{{review_mode}}")"
REVIEW_WORKFLOW_ID="$(printf '%s' "$REVIEW_LAUNCH_JSON" | jq -r '.workflow_id // .molecule_id // empty')"
[ -n "$REVIEW_WORKFLOW_ID" ] || { echo "sling returned no workflow root id" >&2; exit 1; }
gc bd update "$ROOT_BEAD_ID" --set-metadata gc.github.review_workflow_id="$REVIEW_WORKFLOW_ID"
```

If the selected formula does not declare the mode vars, omit the two mode
`--var` arguments rather than failing the launch. If the launch returns no
workflow root id, close this step with `gc.outcome=fail` and
`gc.failure_class=hard`: an unobservable child is indistinguishable from a
failed one, and this step fails closed on both.

## Outcome gate

The launched workflow's own terminal outcome is the success criterion for this
step — not the presence of a file. graph.v2 computes that outcome for you: when
the child's `workflow-finalize` runs, the orchestrator aggregates its steps into
one pass/fail and closes the child workflow ROOT with it (formula-spec-v2
section 3.5). Read it:

```bash
{{pack_root}}/assets/scripts/workflow_outcome.py review-gate \
  --workflow-root "$REVIEW_WORKFLOW_ID" \
  --report "$REPORT_PATH"
```

The gate exits 0 only when BOTH hold: the child workflow terminated
`gc.outcome=pass`, AND `REPORT_PATH` validates as a review verdict report. It
reports `outcome=incomplete` while the child is still running — re-run the gate
to poll, and do not close this step while it says `incomplete`. Anything else —
`fail`, `unknown`, an unreadable root, a member step closed
`gc.outcome=fail` — is a non-pass and blocks this step.

A review verdict of `fail` is NOT a workflow failure. A child that ran to
completion and reported `fail/minor`, `fail/major`, or `fail/blocker` passes
this gate; that verdict is the review's output and maps to
`comment`/`request_changes`/`block` downstream. The gate separates "the review
did not run" from "the review found problems", and only the former stops the
adapter.

On a passing gate, persist the review handoff and result on workflow root
metadata and close this step with `gc.outcome=pass`:

```
gc bd update <root-bead-id> --set-metadata gc.github.review_subject_path="$SUBJECT_PATH" --set-metadata gc.github.review_report_path="$REPORT_PATH" --set-metadata gc.github.review_workflow_id="$REVIEW_WORKFLOW_ID" --set-metadata gc.github.review_child_outcome=pass --set-metadata gc.github.review_outcome=<approve|comment|request_changes|block>
```

On a non-pass gate, record what the child actually did and fail this step —
`gc bd update <root-bead-id> --set-metadata gc.github.review_child_outcome=<fail|incomplete|unknown>`,
then close this step with `gc.outcome=fail`, `gc.failure_class=hard`, and the
gate's `detail` string as the reason. Do not stamp `gc.github.review_outcome`.
This step carries `gc.on_fail=abort_scope`, so that close is what stops
`render-comment`, `human-gate-comment`, and `post-comment` from running: a run
whose review failed must not post a verdict to the pull request.

Never route around this gate. Do not hand-author, patch, backfill, or otherwise
repair `REPORT_PATH` so the validator passes, do not substitute a report from a
different head SHA, and do not close this step pass on the grounds that a
conformant file happens to exist. A bridging artifact written to satisfy the
validator turns a failed review into a posted verdict, which is the exact
failure this gate exists to prevent. If the gate cannot pass, the correct
outcome is a failed step.

The adapter does not check out a mutation worktree, push commits, amend
contributor branches, submit formal GitHub review events, or create follow-up
PRs.
