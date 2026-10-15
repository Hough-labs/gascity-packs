#!/usr/bin/env bash
# polecat-submit.sh push-gate|reassign
#
# The deterministic shell of mol-polecat-work's submit-and-exit step, run as one
# script so the polecat makes a short call and does not retype it (gcp-nc8wg).
# "push-gate" is the step's section 3: the auto_push / no-push-rail gate, the
# base-branch precondition, the push and its verification. "reassign" is its
# section 6: the refinery handoff. Both bodies are the shell the step used to
# carry, moved as written: every halt still closes the running step bead and
# acks the drain itself, and still exits with the code it always did.
# Sections 0, 1, 2, 2b, 4, 5, 7 and 8 stay in the formula step, because the
# model reads and fills them.
#
# Inputs, set by the formula step in the environment of this call (an empty
# value is allowed only where it says so; an unset one stops the script):
#   push-gate: PS_CONVOY_ID PS_BASE_BRANCH PS_BINDING_PREFIX
#   reassign:  PS_CONVOY_ID PS_BINDING_PREFIX
#   PS_CONVOY_ID and PS_BASE_BRANCH must not be empty. PS_BINDING_PREFIX may be:
#   it is the import binding prefix, empty when the pack is not bound.
# Env also read: GC_RIG
#
# The ids the old fences inherited from earlier fences of the step are derived
# here, the way sections 0 and 1 derive them, so a fresh shell is enough:
#   WORK_BEAD_ID   the convoy's only child (gc convoy status PS_CONVOY_ID)
#   CURRENT_BRANCH git branch --show-current, push-gate only
# A convoy that does not name exactly one work bead stops the call before any
# bead is written and without a drain, so the call can simply be run again.

if [ "$#" -ne 1 ] || { [ "$1" != push-gate ] && [ "$1" != reassign ]; }; then
    echo "SUBMIT_USAGE polecat-submit.sh push-gate|reassign"
    exit 2
fi
: "${PS_CONVOY_ID:?not set or empty (the formula step sets it)}"
: "${PS_BINDING_PREFIX?not set (the formula step sets it; an empty value is allowed)}"
if [ "$1" = push-gate ]; then
    : "${PS_BASE_BRANCH:?not set or empty (the formula step sets it)}"
fi
CONVOY_STATUS=$(gc convoy status "$PS_CONVOY_ID" --json)
WORK_BEAD_ID=$(printf '%s' "$CONVOY_STATUS" | jq -r 'if (.children | length) == 1 then .children[0].id else empty end')
if [ -z "$WORK_BEAD_ID" ]; then
    echo "STOP: convoy $PS_CONVOY_ID does not name exactly one work bead; nothing was changed. Run this call again."
    exit 1
fi
if [ "$1" = push-gate ]; then
CURRENT_BRANCH=$(git branch --show-current)
# --- push-gate:begin ---
WORK_JSON=$(gc bd show "$WORK_BEAD_ID" --json)
BRANCH=$(git branch --show-current)

# The metadata probe — NORMALISED, and fail CLOSED on a payload it cannot read.
#
# jq's has() ERRORS on a string, printing nothing to stdout, so the old probe
# turned a string-shaped metadata payload into "" — and "" is not "false", so
# outcome (a), the EXPLICIT opt-out, silently stopped firing and control
# reached git push. A fail-OPEN on the one outcome nobody expects to be
# conditional, and it inverted the incentive the whole no-push-rail arc has
# been pushing: a bead that recorded its rail properly AS METADATA, and said
# nothing in prose, is exactly the bead with no prose for (b) to match on.
# Reproduced against this gate's own shipped text, 2026-09-05: explicit
# auto_push=false + string-shaped metadata -> PUSH.
#
# MEASURED 2026-09-05 across all 7 active ledgers (control, sb, sb-app,
# gas-city, flinders, arnotts, detmold) through this gate's own probe shape
# (gc bd show <id> --json | jq of .[0].metadata | type): every one serves an
# OBJECT when metadata is present and NULL when it is absent. No ledger serves
# a string today, so this is a latent trap rather than a live hole — but the
# shape is not a guarantee this gate owns: metadata is whatever the ledger
# binding serialises, it varied by rig when the detector this arc grew out of
# was written (that detector normalises object / string / null for exactly this
# reason), and nothing pins it. The normalisation is lifted here now rather
# than on the day it bites.
#
#   object -> read it.
#   null   -> the bead carries no metadata. A legitimate live shape on every
#             rig and the MAJORITY of beads (308 of the 410 open/in_progress
#             beads across the six queryable ledgers), so it must fall through
#             to (b) and never halt.
#   string -> a JSON-encoded object. Parse it, then read it.
#   anything else, a string that does not parse to an object, an auto_push
#             value outside the closed vocabulary, or a probe that fails
#             outright -> UNREADABLE, handled at (a0) below. The vocabulary is
#             closed on purpose: the key is hand-written by humans, and reading
#             `False` or `no` as "any other value -> explicit consent" fails
#             open on the beads that tried hardest to say no. Note this is
#             the OPPOSITE default to the (b) prose scan's empty INPUT case:
#             there, nothing said is a legitimate "no rail"; here, nothing read
#             is a failure to retrieve a decision that may well exist.
AUTO_PUSH=""
META_UNREADABLE=""
if [ -z "$WORK_JSON" ]; then
  META_UNREADABLE=1
elif ! AUTO_PUSH=$(printf '%s' "$WORK_JSON" | jq -r '
      if (type != "array") or (length == 0) or ((.[0] | type) != "object")
      then error("no bead record in the payload")
      else (.[0].metadata
            | if   type == "object" then .
              elif type == "null"   then {}
              elif type == "string" then (fromjson? // "unparseable")
              else "not-an-object" end)
           | if type != "object" then error("metadata is not an object")
             elif has("auto_push") then (.auto_push | tostring | ascii_downcase
                   | if   . == "false" or . == "no"  or . == "0" then "false"
                     elif . == "true"  or . == "yes" or . == "1" then "true"
                     elif . == "null" then ""
                     else error("auto_push value is outside the vocabulary")
                     end)
             else "" end
      end' 2>/dev/null); then
  META_UNREADABLE=1
fi

# (a0) The payload could not be read. Absent metadata is not consent, and
# UNREADABLE metadata is not absent metadata — it is a bead whose recorded
# decision the gate failed to retrieve. Reading the prose instead would be
# guessing, so halt and hand it to a human.
if [ -n "$META_UNREADABLE" ]; then
  echo "metadata unreadable: halting at branch-ready (fail closed) and escalating."
  # --append-notes, NEVER --notes — same rule as the other two halts (gci-3f5u).
  gc bd update "$WORK_BEAD_ID" \
    --status=open --assignee="" \
    --set-metadata branch="$BRANCH" \
    --set-metadata target="$PS_BASE_BRANCH" \
    --set-metadata branch_ready=true \
    --set-metadata halt_reason=metadata_unreadable \
    --set-metadata gc.routed_to="" \
    --append-notes "Branch ready: the push gate could not read this bead's push decision — the ledger read returned no bead record, the metadata came in a shape the probe cannot decode, or auto_push carried a value outside the vocabulary (false/no/0 to halt, true/yes/1 to push). A decision that cannot be read cannot be shown to lack auto_push=false, so the gate halted instead of pushing. Re-record the push decision in the vocabulary, then re-sling."
  gc mail send "${GC_RIG:+$GC_RIG/}${PS_BINDING_PREFIX}witness" \
    -s "HELP: push-gate metadata unreadable on $WORK_BEAD_ID [HIGH]" \
    -m "Halted at branch-ready instead of pushing.

Bead:   $WORK_BEAD_ID
Branch: $BRANCH (local only — NOT pushed)
Reason: the ledger read returned no readable bead record, served the metadata
        in a shape the gate cannot decode (expected an object, a JSON string,
        or null), or carried an auto_push value outside the vocabulary
        (false/no/0 halt, true/yes/1 push, case-folded). The gate cannot tell
        'halt' from 'go', so it halted.

Resolve: check the ledger is healthy, then record the decision as metadata —
  gc bd update $WORK_BEAD_ID --set-metadata auto_push=false   # confirm the halt
  gc bd update $WORK_BEAD_ID --set-metadata auto_push=true    # authorise the push
and re-sling. Use --set-metadata so branch and gc.routed_to survive."
  STEP_BEAD_ID=$(gc hook current --id-only) || exit 1  # drain-ack gives back every claim this session still holds, so close this step first
  STEP_BEAD=$(gc bd show "$STEP_BEAD_ID" --json) || exit 1
  printf '%s' "$STEP_BEAD" | jq -e '(if type == "array" then .[0] else . end) | .status == "in_progress" and ((.metadata["gc.step_ref"] // "") | endswith(".submit-and-exit"))' >/dev/null || { echo "submit-and-exit: current claim $STEP_BEAD_ID is not this in-progress step; not acknowledging drain" >&2; exit 1; }
  gc bd update "$STEP_BEAD_ID" --set-metadata gc.outcome=fail --set-metadata gc.failure_class=hard --set-metadata gc.failure_reason=metadata_unreadable --status=closed || exit 1
  gc runtime drain-ack
  exit 0
fi

# (a) Explicit opt-out. Never read the prose — the metadata already decided.
if [ "$AUTO_PUSH" = "false" ]; then
  echo "auto_push=false: halting at branch-ready (no push, no refinery handoff)"
  # --append-notes, NEVER --notes. --notes REPLACES the entire notes field, so a
  # halt note written with it destroys whatever the requester left on the bead.
  gc bd update "$WORK_BEAD_ID" \
    --status=open --assignee="" \
    --set-metadata branch="$BRANCH" \
    --set-metadata target="$PS_BASE_BRANCH" \
    --set-metadata branch_ready=true \
    --set-metadata halt_reason=auto_push_false \
    --set-metadata gc.routed_to="" \
    --append-notes "Branch ready: auto_push=false (no push, no refinery handoff)"
  STEP_BEAD_ID=$(gc hook current --id-only) || exit 1  # drain-ack gives back every claim this session still holds, so close this step first
  STEP_BEAD=$(gc bd show "$STEP_BEAD_ID" --json) || exit 1
  printf '%s' "$STEP_BEAD" | jq -e '(if type == "array" then .[0] else . end) | .status == "in_progress" and ((.metadata["gc.step_ref"] // "") | endswith(".submit-and-exit"))' >/dev/null || { echo "submit-and-exit: current claim $STEP_BEAD_ID is not this in-progress step; not acknowledging drain" >&2; exit 1; }
  gc bd update "$STEP_BEAD_ID" --set-metadata gc.outcome=fail --set-metadata gc.failure_class=hard --set-metadata gc.failure_reason=auto_push_false --status=closed || exit 1
  gc runtime drain-ack
  exit 0
fi

# (b) No decision recorded. Scan DESCRIPTION + NOTES for a no-push rail.
# Lines about pushing *to main* are a DIFFERENT rail — one every polecat
# already obeys, since it pushes a feature branch and never main — so the
# PHRASE that states it is stripped out and the REMAINDER is matched. Without
# that every bead quoting the standing "polecats do not push to main" rule
# would halt, and a gate that cries wolf gets routed around.
#
# Strip the PHRASE, not the LINE. A line-granular exclusion took any real rail
# that shared a line with a push-to-main mention down with it, and its target
# list included bare `origin` — the remote this gate is about to push to — so
# "do not push to origin" was read as the standing rule. MEASURED 2026-09-08
# against this gate's own shipped patterns: 7 real rail wordings scored zero
# hits and the gate PUSHED, among them "never push to origin — the customer
# tenant is frozen" and "Polecats do not push to main. HALT branch-ready for
# this bead." Narrowing the destination alone closes only 5 of those 7; the
# other 2 need the strip, because rail and quote share one line. All 15
# rail-detection rows keep their verdicts under the strip.
#
# The destination must end on a word boundary, or "never push to
# origin/main-line-customer" loses its rail to the `origin/main` prefix. `/` is
# in the protected class for the same reason `-` and `_` are: "never push to
# main/customer" names a branch UNDER main, not main, and no English sentence
# continues "main/…". `.` cannot join them — "Polecats never push to main. Open
# a PR." would keep its quote and cry wolf — so the dotted-branch case stays in
# the residual below. The text is downcased first because the strip has to catch
# "Do Not Push To Main" and sed's case-insensitive flag is GNU-only; the match
# grep is already -i, so downcasing upstream costs nothing.
#
# KNOWN RESIDUAL, two shapes, both measured 2026-09-09 and both ended by
# recording the rail as auto_push=false:
#   1. A rail whose ONLY signal sits inside the stripped phrase still reads as
#      the standing rule — "never push to main or anywhere else" pushes. So does
#      the dotted-branch form "never push to main.customer, it is frozen", which
#      is the same shape: `.` is unprotectable without sentence semantics.
#      Separating these needs sentence semantics, not a regex, and the cheap cure
#      (keep the line whenever the strip would remove every signal) halts every
#      bead that quotes the standing rule, which is the cry-wolf failure this
#      filter exists to prevent.
#   2. A NORMATIVE sentence about some other system's pushing — "Establish why
#      the sync should not push twice" — halts, because the match arms below
#      cannot tell a requirement about the subject under repair from a rail about
#      this branch. Over-halting is the recoverable direction (a human records
#      auto_push and re-slings) where a missed rail is not, so this is left as a
#      halt rather than narrowed.
#
# Comments are deliberately out of scope: they are discussion, not standing
# instructions, and they self-match on any bead that merely talks about
# no-push rails.
if [ -z "$AUTO_PUSH" ]; then
  # Extract, downcase and strip in CHECKED stages. grep -c prints a count
  # whenever it runs, so a failure INSIDE one long pipe arrives at the match
  # grep as an empty stream and scores 0 — a push. Each stage that can fail is
  # its own command and any failure sets RAIL_HIT=1: an undetermined rail is
  # treated as an asserted one. ${RAIL_HIT:-1} then covers the last stage,
  # where an empty result can only mean grep itself never ran.
  RAIL_HIT=""
  if ! PROSE=$(printf '%s' "$WORK_JSON" | jq -r '(.[0].description // ""), (.[0].notes // "")' 2>/dev/null); then
    RAIL_HIT=1
  elif ! LOWER=$(printf '%s' "$PROSE" | tr '[:upper:]' '[:lower:]'); then
    RAIL_HIT=1
  elif ! SCAN=$(printf '%s' "$LOWER" | sed -E 's#push(ing|es)?[[:space:]]+(directly[[:space:]]+)?to[[:space:]]+(origin/)?(main|master|trunk)([^-[:alnum:]_/]|$)# #g'); then
    RAIL_HIT=1
  else
    # The match arms mirror the vocabulary this gate blesses elsewhere, or the
    # gate fails open on the prose channel for words it accepts in metadata.
    # `must not push`/`should not push` carry the same ([^e]|$) guard as
    # `never push` for consistency, though a modal cannot take the -es/-ed form
    # that guard exists for, so on those two arms it only catches ungrammatical
    # prose. The value arm takes the FULL closed vocabulary — `no` and `0` are
    # the same word as `false` at :450-455, and reading them as consent here
    # while halting on them there is the mismatch this gate is about.
    RAIL_HIT=$(printf '%s' "$SCAN" | grep -Eic 'no[- ]push([^e]|$)|do not push|don.t push|never push([^e]|$)|(must|should) not push([^e]|$)|(mayor|operator|human) publishes|halt[- ]*(at[- ]+)?branch[- ]ready|branch[- ]ready[- ]+halt|auto_push[[:space:]]*=[[:space:]]*(false|no|0)')
  fi
  if [ "${RAIL_HIT:-1}" -gt 0 ]; then
    echo "NO-PUSH RAIL IN PROSE + auto_push ABSENT — halting at branch-ready (fail closed) and escalating."
    # --append-notes, NEVER --notes. This halt cites a rail that is frequently
    # written in the very notes a bare --notes would replace, so replacing them
    # would delete the evidence the halt note tells the reader to go and read.
    gc bd update "$WORK_BEAD_ID" \
      --status=open --assignee="" \
      --set-metadata branch="$BRANCH" \
      --set-metadata target="$PS_BASE_BRANCH" \
      --set-metadata branch_ready=true \
      --set-metadata halt_reason=no_push_rail_unresolved \
      --set-metadata gc.routed_to="" \
      --append-notes "Branch ready: DESCRIPTION/NOTES assert a no-push rail but the bead carries no auto_push metadata, so the rail is unenforceable. Halted instead of guessing. Whoever owns the rail: set auto_push=false to confirm the halt, or auto_push=true to authorise the push, then re-sling."
    gc mail send "${GC_RIG:+$GC_RIG/}${PS_BINDING_PREFIX}witness" \
      -s "HELP: no-push rail unresolved on $WORK_BEAD_ID [HIGH]" \
      -m "Halted at branch-ready instead of pushing.

Bead:   $WORK_BEAD_ID
Branch: $BRANCH (local only — NOT pushed)
Reason: DESCRIPTION/NOTES assert a no-push rail, but metadata.auto_push is
        absent. The push gate cannot tell 'halt' from 'go', so it halted.

Resolve: read the rail, then record the decision as metadata —
  gc bd update $WORK_BEAD_ID --set-metadata auto_push=false   # confirm the halt
  gc bd update $WORK_BEAD_ID --set-metadata auto_push=true    # authorise the push
and re-sling. Use --set-metadata so branch and gc.routed_to survive."
    STEP_BEAD_ID=$(gc hook current --id-only) || exit 1  # drain-ack gives back every claim this session still holds, so close this step first
    STEP_BEAD=$(gc bd show "$STEP_BEAD_ID" --json) || exit 1
    printf '%s' "$STEP_BEAD" | jq -e '(if type == "array" then .[0] else . end) | .status == "in_progress" and ((.metadata["gc.step_ref"] // "") | endswith(".submit-and-exit"))' >/dev/null || { echo "submit-and-exit: current claim $STEP_BEAD_ID is not this in-progress step; not acknowledging drain" >&2; exit 1; }
    gc bd update "$STEP_BEAD_ID" --set-metadata gc.outcome=fail --set-metadata gc.failure_class=hard --set-metadata gc.failure_reason=no_push_rail_unresolved --status=closed || exit 1
    gc runtime drain-ack
    exit 0
  fi
fi

# (c) Normal path.
# Refinery hand-off precondition. mol-refinery-patrol resolves the merge
# target through origin (rebase, ancestry check, merge worktree), so a base
# that exists only in this clone cannot be resolved there — and the refinery
# reads the resulting invalid-upstream error as a merge conflict: it deletes
# the workflow, reopens the bead, stamps a rejection reason computed from the
# same unresolvable ref, and bounces the work to a polecat that hits the same
# wall. Hand over only a target the refinery can actually resolve.
git fetch --prune origin >/dev/null 2>&1 || true
if ! git show-ref --verify --quiet "refs/remotes/origin/${PS_BASE_BRANCH}"; then
  echo "base branch ${PS_BASE_BRANCH} is local-only: halting at branch-ready (no push, no refinery handoff)"
  BRANCH=$(git branch --show-current)
  gc bd update "$WORK_BEAD_ID" \
    --status=open --assignee="" \
    --set-metadata branch="$BRANCH" \
    --set-metadata target="$PS_BASE_BRANCH" \
    --set-metadata branch_ready=true \
    --set-metadata halt_reason=base_branch_local_only \
    --set-metadata gc.routed_to="" \
    --append-notes "Branch ready: base branch ${PS_BASE_BRANCH} does not exist on origin, so the refinery cannot merge it. Push the base branch, then re-run submit-and-exit."
  gc mail send "${GC_RIG:+$GC_RIG/}${PS_BINDING_PREFIX}witness" -s "polecat halted: base_branch_local_only ($WORK_BEAD_ID)" -m "Work is committed on branch $BRANCH, but base branch ${PS_BASE_BRANCH} does not exist on origin, so the refinery cannot merge it. Push the base branch, then re-run submit-and-exit for $WORK_BEAD_ID."
  STEP_BEAD_ID=$(gc hook current --id-only) || exit 1  # drain-ack gives back every claim this session still holds, so close this step first
  STEP_BEAD=$(gc bd show "$STEP_BEAD_ID" --json) || exit 1
  printf '%s' "$STEP_BEAD" | jq -e '(if type == "array" then .[0] else . end) | .status == "in_progress" and ((.metadata["gc.step_ref"] // "") | endswith(".submit-and-exit"))' >/dev/null || { echo "submit-and-exit: current claim $STEP_BEAD_ID is not this in-progress step; not acknowledging drain" >&2; exit 1; }
  gc bd update "$STEP_BEAD_ID" --set-metadata gc.outcome=fail --set-metadata gc.failure_class=hard --set-metadata gc.failure_reason=base_branch_local_only --status=closed || exit 1
  gc runtime drain-ack
  exit 0
fi
git push origin HEAD
PUSH_EXIT=$?
if [ $PUSH_EXIT -ne 0 ]; then
    echo "PUSH FAILED (exit $PUSH_EXIT)"
    echo "Branch '$CURRENT_BRANCH' was NOT pushed to origin."
    echo "Aborting handoff — bead stays with polecat."
    echo ""
    echo "Diagnose the push failure (network, auth, force-needed?) and re-run submit-and-exit."
    STEP_BEAD_ID=$(gc hook current --id-only) || exit 1  # drain-ack gives back every claim this session still holds, so close this step first
    STEP_BEAD=$(gc bd show "$STEP_BEAD_ID" --json) || exit 1
    printf '%s' "$STEP_BEAD" | jq -e '(if type == "array" then .[0] else . end) | .status == "in_progress" and ((.metadata["gc.step_ref"] // "") | endswith(".submit-and-exit"))' >/dev/null || { echo "submit-and-exit: current claim $STEP_BEAD_ID is not this in-progress step; not acknowledging drain" >&2; exit 1; }
    gc bd update "$STEP_BEAD_ID" --set-metadata gc.outcome=fail --set-metadata gc.failure_class=hard --set-metadata gc.failure_reason=push_failed --status=closed || exit 1
    gc runtime drain-ack
    exit 1
fi
# Verify the ref is reachable on origin before trusting the push succeeded.
REMOTE_REF=$(git ls-remote origin "refs/heads/$CURRENT_BRANCH" 2>/dev/null | awk '{print $1}')
LOCAL_HEAD=$(git rev-parse HEAD)
if [ -z "$REMOTE_REF" ]; then
    echo "PUSH VERIFICATION FAILED"
    echo "  git push exited 0 but 'git ls-remote' returned no ref for '$CURRENT_BRANCH' on origin."
    echo "  Branch is local-only. Aborting handoff."
    STEP_BEAD_ID=$(gc hook current --id-only) || exit 1  # drain-ack gives back every claim this session still holds, so close this step first
    STEP_BEAD=$(gc bd show "$STEP_BEAD_ID" --json) || exit 1
    printf '%s' "$STEP_BEAD" | jq -e '(if type == "array" then .[0] else . end) | .status == "in_progress" and ((.metadata["gc.step_ref"] // "") | endswith(".submit-and-exit"))' >/dev/null || { echo "submit-and-exit: current claim $STEP_BEAD_ID is not this in-progress step; not acknowledging drain" >&2; exit 1; }
    gc bd update "$STEP_BEAD_ID" --set-metadata gc.outcome=fail --set-metadata gc.failure_class=hard --set-metadata gc.failure_reason=push_verify_failed --status=closed || exit 1
    gc runtime drain-ack
    exit 1
fi
if [ "$REMOTE_REF" != "$LOCAL_HEAD" ]; then
    echo "PUSH VERIFICATION FAILED"
    echo "  origin/$CURRENT_BRANCH = $REMOTE_REF"
    echo "  local HEAD             = $LOCAL_HEAD"
    echo "  Branch tip on origin does not match local HEAD. Aborting handoff."
    STEP_BEAD_ID=$(gc hook current --id-only) || exit 1  # drain-ack gives back every claim this session still holds, so close this step first
    STEP_BEAD=$(gc bd show "$STEP_BEAD_ID" --json) || exit 1
    printf '%s' "$STEP_BEAD" | jq -e '(if type == "array" then .[0] else . end) | .status == "in_progress" and ((.metadata["gc.step_ref"] // "") | endswith(".submit-and-exit"))' >/dev/null || { echo "submit-and-exit: current claim $STEP_BEAD_ID is not this in-progress step; not acknowledging drain" >&2; exit 1; }
    gc bd update "$STEP_BEAD_ID" --set-metadata gc.outcome=fail --set-metadata gc.failure_class=hard --set-metadata gc.failure_reason=push_verify_failed --status=closed || exit 1
    gc runtime drain-ack
    exit 1
fi
# --- push-gate:end ---
else
# --- reassign:begin ---
REFINERY_TARGET="${GC_RIG:+$GC_RIG/}${PS_BINDING_PREFIX}refinery"
# NEVER clear gc.routed_to when it reads `human`. That value is an operator
# escalation — the refinery writes it when it REFUSES to land a bead (an
# existing PR it cannot use, a false completion). Reassigning to the refinery
# there does not resume the work, it silently undoes the escalation
# (gcp-rz8a). The branch is already pushed and recorded, so halting here loses
# nothing: the human owns the next move.
ROUTED_TO=$(gc bd show "$WORK_BEAD_ID" --json 2>/dev/null | jq -r '.[0].metadata."gc.routed_to" // empty')
if [ "$ROUTED_TO" = "human" ]; then
    echo "HANDOFF HALTED: $WORK_BEAD_ID is routed to human — an operator escalation."
    echo "Branch is pushed and metadata.target is set; leaving assignee and gc.routed_to untouched."
    gc bd note "$WORK_BEAD_ID" --stdin <<'HUMAN_HALT'
Polecat submit-and-exit halted at the refinery handoff: gc.routed_to=human.
Branch is pushed and metadata.target is recorded. Assignee and routing left as
the escalation set them; a human decides whether this goes to the refinery.
HUMAN_HALT
    STEP_BEAD_ID=$(gc hook current --id-only) || exit 1  # drain-ack gives back every claim this session still holds, so close this step first
    STEP_BEAD=$(gc bd show "$STEP_BEAD_ID" --json) || exit 1
    printf '%s' "$STEP_BEAD" | jq -e '(if type == "array" then .[0] else . end) | .status == "in_progress" and ((.metadata["gc.step_ref"] // "") | endswith(".submit-and-exit"))' >/dev/null || { echo "submit-and-exit: current claim $STEP_BEAD_ID is not this in-progress step; not acknowledging drain" >&2; exit 1; }
    gc bd update "$STEP_BEAD_ID" --set-metadata gc.outcome=fail --set-metadata gc.failure_class=hard --set-metadata gc.failure_reason=routed_to_human --status=closed || exit 1
    gc runtime drain-ack
    exit 0
fi
# --- handoff-stamp:begin ---
# Stamp the handoff in THIS write, never a later one: once the assignee names
# the refinery, find-work can take the bead, and it orders each priority band
# by first_submitted_at (gcp-et7g). first_submitted_at is written once and kept
# across rejections, so a resubmitted bead keeps its place in line;
# last_submitted_at moves on every handoff and is for observability only.
# Only a read that returned this bead proves the key is absent. An unreadable
# bead gets no first stamp, so a transient read failure cannot overwrite an
# original stamp and send a resubmit to the back of its band.
HANDOFF_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)
HANDOFF_STAMP=(--set-metadata last_submitted_at="$HANDOFF_AT")
STAMP_JSON=$(gc bd show "$WORK_BEAD_ID" --json 2>/dev/null)
if [ "$(printf '%s' "$STAMP_JSON" | jq -r '.[0].id // empty' 2>/dev/null)" = "$WORK_BEAD_ID" ] &&
   [ -z "$(printf '%s' "$STAMP_JSON" | jq -r '.[0].metadata.first_submitted_at // empty' 2>/dev/null)" ]; then
    HANDOFF_STAMP+=(--set-metadata first_submitted_at="$HANDOFF_AT")
fi
# A refused write is not a handoff. Stop before steps 7 and 8: they would drain
# the session with the branch pushed and the refinery never told.
if ! gc bd update "$WORK_BEAD_ID" --status=open --assignee="$REFINERY_TARGET" --set-metadata gc.routed_to="" \
    "${HANDOFF_STAMP[@]}"; then
    echo "HANDOFF_FAILED $WORK_BEAD_ID was NOT handed to $REFINERY_TARGET: the update was refused."
    echo "  The branch is pushed and metadata.target is recorded, but the refinery will not see this bead."
    echo "  Do NOT run steps 7 and 8 and do NOT drain-ack: this session still holds the handoff."
    echo "  See who holds it (gc bd show $WORK_BEAD_ID --json | jq '.[0] | {status, assignee}'),"
    echo "  then mail the witness a HELP escalation with that output."
    exit 1
fi
# --- handoff-stamp:end ---
# The handoff is the assignee write; `--status=open` is bookkeeping that has
# been observed not to stick (gcp-s14g). Read it back and correct it once, so
# the bead does not sit in_progress with nobody working it. This is best-effort
# on purpose: the refinery's find-work scans open,in_progress precisely so a
# status that refuses to settle cannot hide the bead again. Never abort the
# handoff over it — the branch is already pushed.
HANDOFF_STATUS=$(gc bd show "$WORK_BEAD_ID" --json 2>/dev/null | jq -r '.[0].status // empty')
if [ "$HANDOFF_STATUS" != "open" ]; then
    gc bd update "$WORK_BEAD_ID" --status=open >/dev/null 2>&1
    HANDOFF_STATUS=$(gc bd show "$WORK_BEAD_ID" --json 2>/dev/null | jq -r '.[0].status // empty')
    [ "$HANDOFF_STATUS" = "open" ] ||
        echo "WARN $WORK_BEAD_ID handed off to $REFINERY_TARGET with status=${HANDOFF_STATUS:-unreadable}, not open; the refinery still sees it (find-work scans open,in_progress)."
fi
# --- reassign:end ---
fi
