{{ define "approval-fallacy-crew" }}
## No Approval Step

When work is done, finish the cycle. Do not summarize and wait for permission.

- Commit and push your work.
- Continue with the next task, or send handoff context and exit:
  `gc mail send -s "HANDOFF: <brief>" -m "<context>" && gc runtime drain-ack && exit`
- Do not ask "should I commit this?"
- Do not sit idle after finishing.
{{ end }}

{{ define "approval-fallacy-polecat" }}
## No Idle Polecats

When implementation and checks are done, hand off immediately through the
formula. There is no approval wait. An idle polecat blocks the refinery and
wastes the pool slot.

### The Done Sequence Lives in the Formula

The `mol-polecat-work` `submit-and-exit` step is the single source of truth for
handoff — branch-shape gate, push + push-verify, metadata, refinery
reassignment, wake/nudge, and drain. **Run that step.**

**Do NOT run submit-and-exit twice** — running the done sequence twice is a bug.
Do not trust memory for this; check mechanically. Derive the work bead from your
convoy exactly as the formula's workspace-setup step does — never pass a bare or
guessed id to `bd`, which fuzzy-matches and can reassign the wrong bead.
`$GC_BEAD_ID` is the convoy the molecule was poured on, and when it is not
exported the block below recovers the convoy from the step bead you are holding.
Only positive evidence — the work bead closed, or handed to somebody else —
means submit-and-exit already reassigned it. Otherwise run it:

```bash
EXPECTED_ASSIGNEE="${BEADS_ACTOR:-${GC_SESSION_NAME:-${GC_SESSION_ID:-${GC_AGENT:-}}}}"
# `$GC_BEAD_ID` is not always exported — it was empty in gcp-rz8a's session, so
# this guard could not run at all. Recover the convoy from the molecule root of
# the step bead this session is holding rather than skipping the check.
CONVOY_ID="${GC_BEAD_ID:-}"
if [ -z "$CONVOY_ID" ]; then
  ROOT_BEAD_ID=$(gc bd list --assignee="$EXPECTED_ASSIGNEE" --status=in_progress \
    --has-metadata-key gc.step_ref --include-infra --limit=0 --json 2>/dev/null |
    jq -r '[.[] | .metadata."gc.root_bead_id" // empty] | .[0] // empty' 2>/dev/null)
  if [ -n "$ROOT_BEAD_ID" ]; then
    CONVOY_ID=$(gc bd show "$ROOT_BEAD_ID" --json 2>/dev/null |
      jq -r '.[0].metadata."gc.input_convoy_id" // .[0].metadata."gc.var.convoy_id" // empty' 2>/dev/null)
  fi
fi
# Read the convoy + work bead with retry — same unreadable-is-not-terminal
# discipline as the claim block. An unreadable state (empty JSON, a convoy blip,
# or 0/>=2 children so WORK_BEAD_ID is empty) is NOT proof that submit-and-exit
# already ran.
WORK_BEAD_ID=""
WORK_STATUS=""
WORK_ASSIGNEE=""
READ_OK=0
READ_TRY=0
while [ "$READ_TRY" -lt 3 ]; do
  READ_TRY=$((READ_TRY + 1))
  CONVOY_STATUS=$(gc convoy status "$CONVOY_ID" --json 2>/dev/null)
  WORK_BEAD_ID=$(printf '%s' "$CONVOY_STATUS" | jq -r 'if (.children | length) == 1 then .children[0].id else empty end' 2>/dev/null)
  if [ -n "$WORK_BEAD_ID" ]; then
    WORK_JSON=$(gc bd show "$WORK_BEAD_ID" --json 2>/dev/null)
    SHOW_CODE=$?
    WORK_STATUS=$(printf '%s' "$WORK_JSON" | jq -r '.[0].status // empty' 2>/dev/null)
    WORK_ASSIGNEE=$(printf '%s' "$WORK_JSON" | jq -r '.[0].assignee // empty' 2>/dev/null)
    if [ "$SHOW_CODE" -eq 0 ] && [ -n "$WORK_STATUS" ]; then
      READ_OK=1
      break
    fi
  fi
  sleep 1
done
# Only POSITIVE evidence counts: the bead is closed, or it is assigned to
# somebody who is not this session (the refinery). "Not in_progress for me" is
# NOT evidence — a molecule's work bead is never assigned to the polecat
# session in the first place, so that test reports already-submitted on work
# that has not been submitted at all, and drains with the branch unpushed.
if [ "$READ_OK" -eq 1 ] && { [ "$WORK_STATUS" = "closed" ] ||
     { [ -n "$WORK_ASSIGNEE" ] && [ "$WORK_ASSIGNEE" != "$EXPECTED_ASSIGNEE" ]; }; }; then
  echo "ALREADY_SUBMITTED $WORK_BEAD_ID status=$WORK_STATUS assignee=$WORK_ASSIGNEE — draining."
  gc runtime drain-ack
  exit
fi
# No positive evidence, or unreadable after retries: DO NOT assume
# already-submitted — fall through and run submit-and-exit. A stranded
# in_progress bead with an unpushed branch is the worse outcome.
```

The `auto_push=false` opt-out (mol-pr-from-issue's halt-at-branch-ready) is
handled inside submit-and-exit itself: when set, it halts at branch-ready (no
push, no refinery handoff); otherwise it pushes and reassigns to the refinery.

Polecats do not push to main, close beads, create MR beads, or wait around. If
work appears already merged, still let submit-and-exit reassign it to the
refinery — only the refinery verifies patch identity and closes beads.
{{ end }}
