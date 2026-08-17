Scope latch for the review, render, gate, and post steps of the PR review
adapter. The orchestrator closes this bead; no worker claims it.

Its members declare `gc.on_fail = "abort_scope"`, so a member that closes
`gc.outcome=fail` — a review workflow that did not succeed, a gate the human
rejected — makes the orchestrator skip the remaining open members and close
this body failed, instead of letting readiness alone carry the run on to
posting a verdict.
