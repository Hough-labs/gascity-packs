#!/usr/bin/env bash
# polecat-resume-verify.sh — the polecat's first action on a restart: re-check
# that THIS session still holds the step it was running (gcp-wmcj9).
#
# Usage:  bash polecat-resume-verify.sh
#
# It takes no argument and carries no template value: the check needs nothing
# the prompt renders. Extra arguments are ignored.
#
# Env read: BEADS_ACTOR GC_SESSION_NAME GC_SESSION_ID GC_AGENT GC_ALIAS GC_BEAD_ID
#   GC_BEAD_ID is the convoy the molecule was poured on. gc does not export it
#   into a session shell, so it is usually empty and the convoy is then not
#   checked.
#
# Outcome contract: it always exits 0 and prints exactly one of
#   RESUME_VERIFIED <step> molecule=<root> assignee=<assignee>
#                         this session holds the step; continue on it
#   OWNERSHIP_LOST ...    another session holds the step, or it went back to
#                         the pool; drain-acked
#   RESUME_INDETERMINATE ...
#                         no readable claim, a closed step, or a step poured
#                         on another convoy; drain-acked, re-claim
# It only reads: no bead is written.
#
# Everything from the GUARD_BEGIN line to the end of the file is the fence that
# used to be typed into the polecat prompt; tests extract the guard from here,
# so keep its sentinels in place.
# GUARD_BEGIN resume-reverify
EXPECTED_ASSIGNEE="${BEADS_ACTOR:-${GC_SESSION_NAME:-${GC_SESSION_ID:-${GC_AGENT:-}}}}"
# The claim block's identity set, restated because each block is its own shell.
claim_assignee_is_ours() {
  for _own in "${BEADS_ACTOR:-}" "${GC_ALIAS:-}" "${GC_SESSION_ID:-}" "${GC_SESSION_NAME:-}" "${GC_AGENT:-}"; do
    if [ -n "$_own" ] && [ "$1" = "$_own" ]; then
      return 0
    fi
  done
  return 1
}
# `gc hook --claim` stamps each claim onto this session's own bead, and a
# restart keeps that bead, so the stamp still names the step after a restart.
STEP_ID=""
STEP_JSON=""
RESUME_TRY=0
while [ "$RESUME_TRY" -lt 3 ]; do
  RESUME_TRY=$((RESUME_TRY + 1))
  STEP_ID=$(gc hook current --id-only 2>/dev/null)
  if [ -n "$STEP_ID" ]; then
    STEP_JSON=$(gc bd show "$STEP_ID" --json 2>/dev/null)
    if [ "$(printf '%s' "$STEP_JSON" | jq -r '.[0].id // empty' 2>/dev/null)" = "$STEP_ID" ]; then
      break
    fi
  fi
  STEP_JSON=""
  if [ "$RESUME_TRY" -lt 3 ]; then
    sleep "$RESUME_TRY"
  fi
done
if [ -z "$STEP_JSON" ]; then
  echo "RESUME_INDETERMINATE no readable step claim for this session (step=${STEP_ID:-none}); re-claim instead of guessing."
  gc runtime drain-ack
  exit 0
fi
STEP_STATUS=$(printf '%s' "$STEP_JSON" | jq -r '.[0].status // empty')
STEP_ASSIGNEE=$(printf '%s' "$STEP_JSON" | jq -r '.[0].assignee // empty')
STEP_ROOT=$(printf '%s' "$STEP_JSON" | jq -r '.[0].metadata."gc.root_bead_id" // empty')
if [ "$STEP_STATUS" = "closed" ]; then
  echo "RESUME_INDETERMINATE step $STEP_ID is already closed, so this session holds no live step; re-claim instead of guessing."
  gc runtime drain-ack
  exit 0
fi
if [ "$STEP_STATUS" != "in_progress" ] || ! claim_assignee_is_ours "$STEP_ASSIGNEE"; then
  echo "OWNERSHIP_LOST $STEP_ID assignee=$STEP_ASSIGNEE status=$STEP_STATUS, not $EXPECTED_ASSIGNEE. Stopping."
  gc runtime drain-ack
  exit 0
fi
if [ -n "${GC_BEAD_ID:-}" ]; then
  STEP_CONVOY=""
  if [ -n "$STEP_ROOT" ]; then
    STEP_CONVOY=$(gc bd show "$STEP_ROOT" --json 2>/dev/null |
      jq -r '.[0].metadata."gc.input_convoy_id" // .[0].metadata."gc.var.convoy_id" // empty' 2>/dev/null)
  fi
  if [ "$STEP_CONVOY" != "$GC_BEAD_ID" ]; then
    echo "RESUME_INDETERMINATE step $STEP_ID is in molecule ${STEP_ROOT:-none} (convoy ${STEP_CONVOY:-unknown}), not convoy $GC_BEAD_ID; re-claim instead of guessing."
    gc runtime drain-ack
    exit 0
  fi
fi
echo "RESUME_VERIFIED $STEP_ID molecule=${STEP_ROOT:-none} assignee=$STEP_ASSIGNEE"
# GUARD_END resume-reverify
