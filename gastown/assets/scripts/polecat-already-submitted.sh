#!/usr/bin/env bash
# polecat-already-submitted.sh — has submit-and-exit already run? (gcp-wmcj9)
#
# Usage:  bash polecat-already-submitted.sh <binding-prefix>
#
# <binding-prefix> is the pack's binding prefix with its trailing dot
# ("gastown."), or "" for an unbound pack. It is required even when empty: a
# missing one would name the wrong refinery, and the check below would then never
# recognise a handoff the refinery holds.
#
# Env read: BEADS_ACTOR GC_SESSION_NAME GC_SESSION_ID GC_AGENT GC_RIG GC_BEAD_ID
#
# Outcome contract: it drains only on POSITIVE evidence, and otherwise stays
# silent so the caller goes on to run submit-and-exit.
#   ALREADY_SUBMITTED <work-bead> status=<s> assignee=<a> ...
#                         the work bead is closed or held by the refinery;
#                         drain-acked, and the exit status is drain-ack's
#   (no output, exit 0)   no positive evidence, or unreadable after the retries:
#                         run submit-and-exit
#   SUBMITTED_GUARD_USAGE ...
#                         wrong argument count; exit 2, nothing read, no drain
# It only reads: no bead is written.
#
# Everything between the already-submitted:begin and already-submitted:end
# markers is the fence that used to be typed into the polecat prompt, once in
# the "No Idle Polecats" fragment and once under FINAL REMINDER. Both now call
# this script.
if [ "$#" -ne 1 ]; then
  echo "SUBMITTED_GUARD_USAGE polecat-already-submitted.sh takes exactly one argument, the binding prefix (got $#)"
  exit 2
fi
BINDING_PREFIX="$1"

# --- already-submitted:begin ---
EXPECTED_ASSIGNEE="${BEADS_ACTOR:-${GC_SESSION_NAME:-${GC_SESSION_ID:-${GC_AGENT:-}}}}"
# The handoff submit-and-exit performs is `assignee = REFINERY_TARGET`, so that
# exact value is what counts as proof it ran. Same expression the formula writes.
REFINERY_TARGET="${GC_RIG:+$GC_RIG/}${BINDING_PREFIX}refinery"
# `$GC_BEAD_ID` is not always exported — it was empty in gcp-rz8a's session, so
# this guard could not run at all. Recover the convoy from the molecule root of
# the step bead this session is holding rather than skipping the check. The
# status filter is `open,in_progress`: a claimed step bead carries this
# session's assignee, but its status depends on what claimed it — gc 1.4.x's
# `gc hook --claim` leaves it `open`, gc 1.5.0's promotes it to `in_progress`,
# and a `--claim` update always does. Either status alone can match nothing, and
# then the recovery silently yields no convoy.
CONVOY_ID="${GC_BEAD_ID:-}"
if [ -z "$CONVOY_ID" ]; then
  ROOT_BEAD_ID=$(gc bd list --assignee="$EXPECTED_ASSIGNEE" --status=open,in_progress \
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
# Only POSITIVE evidence counts: the bead is closed, or it is held by the
# REFINERY — the one assignee submit-and-exit's handoff actually produces. Every
# weaker test has been observed draining a session with the branch unpushed.
# "Not in_progress for me" is not evidence: the polecat never claims the work
# bead (only the refinery handoff writes its status and assignee), so what it
# reads says nothing about this session. Nor is a bare "assigned to
# somebody else", which is equally true of a resumed molecule finding the bead
# still held by its own PREVIOUS session (a restarted session usually claims
# under a new identity) and
# of any third party a bead can be parked on — an operator moving it to a crew
# seat, a reviewer taking it. Name the refinery rather than enumerate the
# identities that are not it.
if [ "$READ_OK" -eq 1 ] && { [ "$WORK_STATUS" = "closed" ] ||
     [ "$WORK_ASSIGNEE" = "$REFINERY_TARGET" ]; }; then
  echo "ALREADY_SUBMITTED $WORK_BEAD_ID status=$WORK_STATUS assignee=$WORK_ASSIGNEE — submit-and-exit already ran; draining."
  gc runtime drain-ack
  exit
fi
# No positive evidence, or unreadable after retries: DO NOT assume
# already-submitted — fall through and run submit-and-exit. A stranded
# in_progress bead with an unpushed branch is the worse outcome.
# --- already-submitted:end ---
