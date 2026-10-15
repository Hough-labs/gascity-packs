#!/usr/bin/env bash
# polecat-claim.sh — the polecat's first action: claim the hooked work bead.
#
# Usage:  bash polecat-claim.sh <binding-prefix>
#
# <binding-prefix> is the pack's binding prefix with its trailing dot
# ("gastown."), or "" for an unbound pack. It is required even when empty: a
# missing one would restamp gc.routed_to and nudge the witness under the wrong
# name, and would misread a live polecat owner as a slinger.
#
# Env read: BEADS_ACTOR GC_SESSION_NAME GC_SESSION_ID GC_AGENT GC_ALIAS GC_RIG
#
# Outcome contract: it always exits 0 and prints exactly one of
#   NO_ROUTED_WORK              nothing to claim; drain-acked
#   CLAIM_REJECTED ...          no identity, no workable bead, or not ours; drain-acked
#   CLAIM_RELEASED <id> ...     bead unreadable; returned to the pool, drain-acked
#   CLAIM_DECLINED_LIVE_OWNER   duplicate pour onto a live owner; step restored, drain-acked
#   CLAIMED_BEAD_ID=<id>        followed by the bead's metadata JSON
#
# Everything between the claim:begin and claim:end markers is the claim that
# used to be typed into the polecat prompt as a heredoc; tests extract the
# guard from here, so keep its sentinels in place.
if [ "$#" -ne 1 ]; then
  echo "CLAIM_REJECTED polecat-claim.sh takes exactly one argument, the binding prefix (got $#)"
  gc runtime drain-ack
  exit 0
fi
BINDING_PREFIX="$1"

# --- claim:begin ---
set +e
EXPECTED_ASSIGNEE="${BEADS_ACTOR:-${GC_SESSION_NAME:-${GC_SESSION_ID:-${GC_AGENT:-}}}}"
if [ -z "$EXPECTED_ASSIGNEE" ]; then
  echo "CLAIM_REJECTED no session identity in env; cannot verify ownership"
  gc runtime drain-ack
  exit 0
fi

# Claim with retry. A hook-call failure (non-zero exit, malformed JSON) is a
# transient CLI/daemon fault — NOT "no work" — so retry it before giving up.
# Only action==drain, or a clean empty result, is genuine NO_ROUTED_WORK.
WORK_ID=""
CLAIM_TRY=0
while [ "$CLAIM_TRY" -lt 3 ]; do
  CLAIM_TRY=$((CLAIM_TRY + 1))
  CLAIM_ERR="$(mktemp)"
  CLAIM_JSON="$(gc hook --claim --json 2>"$CLAIM_ERR")"
  CLAIM_CODE=$?
  CLAIM_ERR_TEXT="$(sed -n '1p' "$CLAIM_ERR")"
  rm -f "$CLAIM_ERR"
  ACTION="$(printf '%s' "$CLAIM_JSON" | jq -r '.action // empty' 2>/dev/null)"
  WORK_ID="$(printf '%s' "$CLAIM_JSON" | jq -r '.bead_id // empty' 2>/dev/null)"
  # `claimed` means this bead was open and UNASSIGNED and we took it out of the
  # pool. `existing_assignment` / `ready_assignment` mean it already carried our
  # identity. The live-owner guard below only has to run in the first case.
  CLAIM_REASON="$(printf '%s' "$CLAIM_JSON" | jq -r '.reason // empty' 2>/dev/null)"
  if [ "$ACTION" = "drain" ]; then
    echo "NO_ROUTED_WORK"
    gc runtime drain-ack
    exit 0
  fi
  if [ "$CLAIM_CODE" -eq 0 ] && [ -n "$WORK_ID" ]; then
    break
  fi
  if [ "$CLAIM_CODE" -eq 0 ] && [ -z "$ACTION" ] && [ -z "$WORK_ID" ]; then
    echo "NO_ROUTED_WORK"
    gc runtime drain-ack
    exit 0
  fi
  echo "CLAIM_RETRY hook call failed (code=$CLAIM_CODE): ${CLAIM_ERR_TEXT:-malformed claim result}"
  WORK_ID=""
  sleep 2
done
if [ -z "$WORK_ID" ]; then
  echo "CLAIM_REJECTED gc hook --claim returned no workable bead after retries"
  gc runtime drain-ack
  exit 0
fi

# Post-claim ownership verification. The bead MUST be yours and in_progress
# before you touch any code. A polecat NEVER works a bead it did not claim this
# session. Distinguish a READ FAILURE (gc bd show non-zero / empty JSON —
# transient) from a genuine MISMATCH (non-empty assignee that differs, or
# status not in_progress). Retry the read before deciding; only a genuine
# mismatch is CLAIM_REJECTED.
#
# The read-success test keys on the bead ECHOING ITS OWN ID, never on a
# non-empty assignee: `gc bd show` omits `assignee` entirely when it is null, so
# requiring it conflated "read fine, genuinely unassigned" with "read failed"
# and sent a perfectly readable unassigned bead down the CLAIM_RELEASED path
# instead of the CLAIM_REJECTED one it belongs in (winnow-2fj8u). An id plus a
# status is the envelope actually arriving; the assignee is then free to be
# empty and be judged on its merits below.
#
# Five tries with a rising backoff, not three at 1s: `gc` pays seconds of fixed
# startup before any subcommand reaches Dolt, and this box has been observed at
# load 44.91 while a polecat claimed. A budget that small turns ordinary
# contention into a spurious release.
STATUS=""
ASSIGNEE=""
SHOW_JSON=""
SHOW_ID=""
SHOW_OK=0
SHOW_TRY=0
while [ "$SHOW_TRY" -lt 5 ]; do
  SHOW_TRY=$((SHOW_TRY + 1))
  SHOW_JSON="$(gc bd show "$WORK_ID" --json 2>/dev/null)"
  SHOW_CODE=$?
  SHOW_ID="$(printf '%s' "$SHOW_JSON" | jq -r '.[0].id // empty' 2>/dev/null)"
  STATUS="$(printf '%s' "$SHOW_JSON" | jq -r '.[0].status // empty' 2>/dev/null)"
  ASSIGNEE="$(printf '%s' "$SHOW_JSON" | jq -r '.[0].assignee // empty' 2>/dev/null)"
  if [ "$SHOW_CODE" -eq 0 ] && [ -n "$SHOW_ID" ] && [ -n "$STATUS" ]; then
    SHOW_OK=1
    break
  fi
  sleep "$SHOW_TRY"
done
if [ "$SHOW_OK" -ne 1 ]; then
  # Never leave a claimed bead stranded in_progress on an unreadable state:
  # release it so it re-enters the pool instead of being lost. Restate the
  # routing on the way out — an open, unassigned bead with no gc.routed_to is
  # not pooled, it is orphaned: nothing spawns for it and it looks healthy.
  # The claim falls through to assigned work too, so this can be a bead that
  # never carried pool routing; routing it here is strictly better than
  # dropping it.
  echo "CLAIM_RELEASED $WORK_ID unreadable after retries; returning it to the pool"
  gc bd update "$WORK_ID" --status=open --assignee="" \
    --set-metadata gc.routed_to="${GC_RIG:+$GC_RIG/}${BINDING_PREFIX}polecat"
  gc runtime drain-ack
  exit 0
fi
if [ "$ASSIGNEE" != "$EXPECTED_ASSIGNEE" ] || [ "$STATUS" != "in_progress" ]; then
  echo "CLAIM_REJECTED $WORK_ID assignee=$ASSIGNEE status=$STATUS (expected $EXPECTED_ASSIGNEE / in_progress)"
  gc runtime drain-ack
  exit 0
fi

STEP_REF="$(printf '%s' "$SHOW_JSON" | jq -r '.[0].metadata."gc.step_ref" // empty' 2>/dev/null)"

# GUARD_BEGIN live-owner
# A clean claim is NOT proof the work is free. A formula STEP bead can be put
# back in the pool while the session working it is alive and mid-task: gc's
# ReleaseIfCurrent swaps status/assignee to open/'' in one Dolt transaction
# ("gc: release bead <id> if current") and writes NO bd event, so the release is
# invisible to every audit surface and the bead simply reappears as ordinary
# unclaimed pool work. Observed on winnow-iaroy, released twice — 20:11:56Z and
# 20:33:37Z on 2026-09-07 — while gastown__polecat-gc-8a4d held it and was
# state=active, mid-sweep on a multi-minute evaluation. The pool then poured
# gastown__polecat-gc-psfm onto it. Nothing in the machinery refused; the
# duplicate declined by judgement, and had it not, it would have stomped a live
# worktree. This block is that judgement made mechanical (gcp-mjjg).
#
# What makes the check possible is that the release only touches the step's
# status and assignee (ReleaseIfCurrent). The step's own `polecat_session`
# survives it, and so does every sibling step's assignee, so the molecule keeps
# a durable record of its last holder. Ask that. The WORK bead is never read:
# the polecat does not claim it, and a crew seat's name on it is the slinger's,
# not a holder's (gcp-952j9).
#
# "Is the owner us?" is a test against the session's whole identity SET, not
# the one spelling EXPECTED_ASSIGNEE picks: the same session is its alias, its
# bead id and its runtime session name, and which one a claim was recorded
# under depends on the gc that wrote it. Upstream #360 (9f98ea4e) made this
# exact correction to the gascity pack's claim (claim_assignee_is_ours,
# gascity/commands/claim/run.sh); this is that function.
claim_assignee_is_ours() {
  for _own in "${BEADS_ACTOR:-}" "${GC_ALIAS:-}" "${GC_SESSION_ID:-}" "${GC_SESSION_NAME:-}" "${GC_AGENT:-}"; do
    if [ -n "$_own" ] && [ "$1" = "$_own" ]; then
      return 0
    fi
  done
  return 1
}

# Only a `claimed` reason can be a duplicate pour. `existing_assignment` and
# `ready_assignment` mean the bead already carried this session's identity
# before the hook ran, and the release clears the assignee — so a released bead
# can never reach us by those tiers. Skipping them keeps three `gc` round-trips
# off the ordinary step-to-step path, where a molecule's own preassigned steps
# come back as `ready_assignment` every time. An unknown reason still checks.
if [ -n "$STEP_REF" ] && { [ -z "$CLAIM_REASON" ] || [ "$CLAIM_REASON" = "claimed" ]; }; then
  # The molecule's last holder. Source 1 is the claimed step's own
  # `polecat_session`, which gc's release and our hook claim both leave alone.
  # Source 2 is required because mid-run steps are claimed with a bare
  # `gc hook --claim` and carry no `polecat_session`: the most recently updated
  # sibling step that still names an assignee stands in for it.
  GUARD_ROOT="$(printf '%s' "$SHOW_JSON" | jq -r '.[0].metadata."gc.root_bead_id" // empty' 2>/dev/null)"
  GUARD_OWNER="$(printf '%s' "$SHOW_JSON" | jq -r '.[0].metadata.polecat_session // empty' 2>/dev/null)"
  if [ -z "$GUARD_OWNER" ] && [ -n "$GUARD_ROOT" ]; then
    GUARD_OWNER="$(gc bd list --metadata-field "gc.root_bead_id=$GUARD_ROOT" --all --limit=0 --json 2>/dev/null |
      jq -r --arg me "$WORK_ID" '[.[] | select(.id != $me and (.assignee // "") != "")]
        | sort_by(.updated_at // "") | last | .assignee // empty' 2>/dev/null)"
  fi
  if [ -z "$GUARD_OWNER" ]; then
    # An unresolvable or unowned molecule is not evidence of a duplicate pour.
    # Proceed exactly as this block did before the guard existed.
    echo "WARN live-owner guard could not resolve an owner for this molecule; proceeding unguarded"
  elif [ "$GUARD_OWNER" != "$EXPECTED_ASSIGNEE" ]; then
    if claim_assignee_is_ours "$GUARD_OWNER"; then
      # Another spelling of THIS session: gc 1.4.3 claimed under the runtime
      # session_name, a gc 1.5.0 namepool polecat acts under its alias. Its
      # live row is us, so probing liveness would decline our own molecule.
      echo "WARN molecule $GUARD_ROOT was last held by $GUARD_OWNER, another identity of this session ($EXPECTED_ASSIGNEE); it is ours."
    else
      # Someone else's name is on the molecule. Only a LIVE someone blocks: a
      # restarted session usually claims under a new identity, so a DEAD prior
      # holder is the ordinary resume case and must not stall
      # the engine.
      # `gc session list` omits closed sessions by default, so a hit there is
      # the liveness answer. asleep and draining count as alive — both still own
      # their work and get woken back onto it.
      GUARD_ALIVE=""
      GUARD_OWNER_SN=""
      GUARD_OWNER_TPL=""
      GUARD_LIST_OK=0
      GUARD_TRY=0
      while [ "$GUARD_TRY" -lt 3 ]; do
        GUARD_TRY=$((GUARD_TRY + 1))
        GUARD_LIST="$(gc session list --json 2>/dev/null)"
        if printf '%s' "$GUARD_LIST" | jq -e 'has("sessions")' >/dev/null 2>&1; then
          GUARD_LIST_OK=1
          GUARD_ROW="$(printf '%s' "$GUARD_LIST" | jq -c --arg o "$GUARD_OWNER" \
            '[.sessions[] | select(.closed != true)
              | select(.session_name == $o or .id == $o or .name == $o or .alias == $o)]
             | .[0] // empty' 2>/dev/null)"
          GUARD_ALIVE="$(printf '%s' "$GUARD_ROW" | jq -r '.id // empty' 2>/dev/null)"
          GUARD_OWNER_SN="$(printf '%s' "$GUARD_ROW" | jq -r '.session_name // empty' 2>/dev/null)"
          GUARD_OWNER_TPL="$(printf '%s' "$GUARD_ROW" | jq -r '.template // empty' 2>/dev/null)"
          break
        fi
        sleep "$GUARD_TRY"
      done
      # Only a live WORKER blocks. A crew, specialist or mayor seat is always
      # live and never runs polecat steps: when one is the molecule's last holder
      # it is the slinger, and declining would hand the step to a seat that will
      # not run it and strand the molecule (gcp-qjkp). A worker is a live row
      # whose template is EXACTLY the polecat or the refinery. A row with no
      # template cannot be classified, so it is treated like a worker: that is
      # the fail-closed behaviour from before the template check existed.
      GUARD_DECLINE=0
      if [ "$GUARD_LIST_OK" -ne 1 ]; then
        GUARD_DECLINE=1
      elif [ -n "$GUARD_ALIVE" ]; then
        case "$GUARD_OWNER_TPL" in
          ""|"${GC_RIG:+$GC_RIG/}${BINDING_PREFIX}polecat"|"${GC_RIG:+$GC_RIG/}${BINDING_PREFIX}refinery")
            GUARD_DECLINE=1 ;;
        esac
      fi
      if [ "$GUARD_DECLINE" -eq 1 ]; then
        # A live worker, or liveness unreadable. Unreadable is NOT evidence the owner is
        # gone, and the two mistakes are not symmetric: declining costs one pool
        # slot and the bead stays claimable, proceeding stomps a live worktree
        # and corrupts whatever the owner is mid-write on. Fail closed.
        echo "CLAIM_DECLINED_LIVE_OWNER $WORK_ID"
        echo "  molecule $GUARD_ROOT was last held by $GUARD_OWNER, and this session is $EXPECTED_ASSIGNEE."
        if [ "$GUARD_LIST_OK" -ne 1 ]; then
          echo "  session liveness was UNREADABLE after retries — declining rather than assuming the owner is gone."
        else
          echo "  that owner is live (session $GUARD_ALIVE). This is a duplicate pour onto an in-flight molecule."
        fi
        echo "  Restoring the step to its owner and draining. No code, branch, or worktree touched."
        # The hook stamped OUR gc.session_id/gc.session_name onto the step
        # during the claim. Put the owner's back. Both come from the live row:
        # GUARD_OWNER is an assignee, which under gc 1.5.0 is an alias or a
        # session bead id, not the runtime session name or id gc reads from
        # these keys. When either value cannot be read, clear the key rather
        # than leave ours standing — a wrong binding is worse than an absent
        # one, and the owner's next write restores it.
        gc bd update "$WORK_ID" --assignee="$GUARD_OWNER" \
          --set-metadata gc.session_name="$GUARD_OWNER_SN" \
          --set-metadata polecat_session="$GUARD_OWNER" \
          --set-metadata gc.session_id="$GUARD_ALIVE" \
          || echo "WARN could not restore $WORK_ID to $GUARD_OWNER — the step is left claimed by a session that will not run it; escalate to the witness"
        gc session nudge "${GC_RIG:+$GC_RIG/}${BINDING_PREFIX}witness" \
          "DUPLICATE_POUR declined: step $WORK_ID poured onto $EXPECTED_ASSIGNEE while molecule $GUARD_ROOT was last held by $GUARD_OWNER. Step restored to its owner." \
          >/dev/null 2>&1 || true
        gc runtime drain-ack
        exit 0
      fi
      if [ -n "$GUARD_ALIVE" ]; then
        echo "WARN molecule $GUARD_ROOT was last held by $GUARD_OWNER, a live $GUARD_OWNER_TPL session: that is the slinger, not a worker; proceeding."
      else
        echo "WARN molecule $GUARD_ROOT was last held by $GUARD_OWNER, but no live session holds that identity — treating this as a resume and proceeding."
      fi
    fi
  fi
fi
# GUARD_END live-owner

# Ownership confirmed.
# Stamp a stable session identity so the churn-watcher and the live-owner guard
# can key on metadata.polecat_session.
gc bd update "$WORK_ID" --set-metadata polecat_session="$EXPECTED_ASSIGNEE" \
  || echo "WARN metadata stamp failed for $WORK_ID; churn-watcher/resume lose session keying (proceeding — the claim is valid)"

printf 'CLAIMED_BEAD_ID=%s\n' "$WORK_ID"
printf '%s' "$SHOW_JSON" | jq '.[0].metadata'
# --- claim:end ---
