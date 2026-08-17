
Read workflow root metadata and write final run metadata containing source bead
id, head SHA, review subject path, review report path, rendered comment path,
GitHub comment id/url, mapped outcome, launch input URL {{github_pr_url}},
artifact root {{artifact_root}}, context path {{context_path}}, post mode
{{post_mode}}, and whether this run reused prior head-SHA output.

This step hangs off the `review-scope` body, not off `post-comment`, so it also
runs when the scope ABORTED — a review workflow that did not succeed, or a human
gate that rejected the comment. On that path the fields above are legitimately
absent: there is no rendered comment, no GitHub comment id, and no mapped
outcome, because nothing was posted. Record them as absent and record why,
reading `gc.github.review_child_outcome` and the scope body's propagated
diagnostics. Do NOT invent, backfill, or carry forward a value from an earlier
head SHA to make the record look complete — the whole point of the abort is that
this run produced no verdict.

Close this step `gc.outcome=pass` whenever it successfully recorded the result,
including for an aborted run: this step's own job is to write the record, and
the failed scope member is what makes the workflow root resolve to fail. Close
`gc.outcome=fail` only when the record itself could not be written.
