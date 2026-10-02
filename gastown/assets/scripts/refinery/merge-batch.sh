#!/usr/bin/env bash
# merge-batch.sh — choose, stack and land a batch of beads for the refinery's
# direct lane (gcp-l8td D1; D1.1 added select and stack, D1.2 land, D1.2b serial).
#
# One patrol iteration may land several assigned beads behind a single gate run.
# The AGENT decides how long the batch is and what a red means; this checked-in
# script does the mechanics, so the agent never hand-renders a batch lane. It is
# a sibling of merge-push.sh and sources it in source-only mode for
# resolve_config, resolve_merge_strategy, resolve_approval_required and the
# merge-state helpers. Nothing here copies them, so a batch member is eligible
# by the single-bead lane's own rules and the two cannot drift.
#
# Batching only ever SHORTENS to the single-bead lane. No batch failure may block
# or reject the head bead: a select or stack error leaves a batch of one, which
# the merge-push lane then runs exactly as it does without batching.
#
# Usage:
#   merge-batch.sh select --head <id> [--max <K>] [config flags]
#   merge-batch.sh stack  --head <id> [--members <id,id,...>] [config flags]
#   merge-batch.sh land   --head <id> [config flags]
#   merge-batch.sh serial --head <id> [config flags]
# Config flags are merge-push.sh's (--rig, --target-default, --binding-prefix,
# --require-approval, --review-agent, --delete-merged-branches, --gh), and the
# config resolves the way merge-push.sh resolves it, including the fail-closed
# approval switch. Run inside the refinery's clone.
#
# select  Print the batch's member ids, one per line, head first, and exit 0.
#         The members are a PREFIX of the refinery's assignee scan in
#         find-work's order (priority, then first_submitted_at // created_at),
#         cut at the first ineligible bead and at K. The head is printed even
#         when it is itself ineligible: a batch of one is the single-bead lane.
#         K is forced to 1 when the approval gate resolves ON, and an unreadable
#         config resolves it ON. A member is eligible when its strategy is
#         direct, its target is the head's, metadata.fork_sha is present, it has
#         no existing_pr, and it has no merge_batch_serial equal to its current
#         origin/<branch> tip. --max defaults to 1. Any failure after the head is
#         known prints the head alone and exits 0; exit 1 is a usage or config
#         error.
#
# stack   Extend `temp`, the already-rebased head, with members 2..k in order.
#         Each member's commits are rebased onto the current `temp`. The member
#         ids come from --members, else from the manifest's members (written by
#         the agent after select), else the head alone. A head whose rebase
#         collapsed (no real change against the target) stays a batch of 1:
#         merge-push.sh --work's merge-state gate decides it, and land never maps
#         it to another member's commit. The first member that
#         conflicts, is ineligible, or collapses to no change ends the batch
#         there: it and every later member are dropped, keep no new metadata and
#         stay assigned. One exception: a member that collapses AND passes
#         branch_already_landed is closed as already merged by the existing
#         helper, and stacking continues past it. Any internal error resets
#         `temp` to the head tip recorded at entry, writes a one-member manifest,
#         prints WARN and still exits 0.
#         Writes the manifest `$(git rev-parse --git-dir)/refinery-batch.json`:
#           {"head": "<id>", "target": "<branch>", "base": "<head tip sha>",
#            "members": [{"id", "branch", "tip", "commits", "patch_id"}, ...]}
#         in batch order, members[0] the head. tip is the member's stacked tip,
#         commits the count it adds to the stack, patch_id the patch-id of the
#         tip commit. `land` (gcp-l8td.9) reads exactly these fields.
#         Needs `temp` rebased onto origin/<target>, as the patrol's rebase step
#         leaves it. Exit 1 only for a usage or config error, or no `temp`.
#
# land    Land the stacked batch with ONE fast-forward push and close each member
#         against ITS OWN landed commit. It reads the manifest stack wrote and
#         runs merge-push.sh's merge_ff_push on `temp`, so the retry loop and the
#         statuses are the lane's: 0 landed, 2 hard stop, 3 the re-rebase
#         conflicted, 5 no-op, 6 retries exhausted, 7 the remote refused. Any of
#         2/3/5/6/7 from the push writes no bead, and leaves temp and the manifest
#         where they are. Status 4 cannot arise: land stops with 2 when the
#         approval gate is on, because a batch of more than one never rode it.
#         After a landing, member i's commit is found in the LANDED stack, not in
#         the manifest, because a retry re-rebases temp and so rewrites every
#         sha: with L the landed tip and offset_i the commit count of the members
#         behind member i, member i's tip is L~offset_i, and it is trusted only
#         when its patch-id equals the one stack recorded. A member that fails
#         that check, or whose bead write or close fails, is LEFT OPEN with its
#         branch kept, never given the batch tip or another member's commit, and
#         never rolled back: the merge-state gate closes it as already merged on
#         a later patrol. Status 0 when every member closed, 2 when one is left
#         open. The manifest is removed after a landing, and temp is cleaned up
#         only on 0.
#         Every land exit, guards included, ends its stdout with
#           merge-batch: RESULT <status> landed=<ids> left-open=<ids>
#         (comma-separated ids, empty when none). Exit 1 is a usage, config or
#         manifest error: no --head, an unknown flag, a missing or unparseable
#         manifest, one for another head, one with fewer than two members (a
#         batch of one is merge-push.sh --work's), or a member with no commits.
#
# serial  Stamp a red batch so its members go serial. For each member, in batch
#         order, it fetches origin/<branch>, records that sha as
#         merge_batch_serial (which select reads, so the member is not batched
#         again until its branch moves) and writes one note. A fetch, rev-parse or
#         stamp failure leaves the member in failed=; a note failure is a WARN.
#         It never writes rejection_reason, assignee or status and never closes a
#         bead, and it does not consult the approval gate. Then, whatever
#         happened per member, it removes the manifest and cleans up `temp`.
#         Takes the manifest checks land does. Status 0 when every member is
#         stamped, 2 when any failed. Every serial exit, guards included, ends its
#         stdout with
#           merge-batch: RESULT <status> serial=<ids> failed=<ids>
#         and exit 1 is a usage, config or manifest error.
#
# Warnings go to stderr. select's stdout is the member ids and nothing else.
#
# No `set -e`, `set -u` or `set -o pipefail`, for the reason merge-push.sh gives:
# every command that matters is checked on its own exit status.

MERGE_BATCH_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

# Used when --max is not given: batching off.
MERGE_BATCH_DEFAULT_MAX=1

# Read by merge-push.sh, not here, and deliberately not exported: a child that
# ran merge-push.sh would otherwise stop before main.
# shellcheck disable=SC2034
MERGE_PUSH_SOURCE_ONLY=1
# shellcheck source=/dev/null
. "$MERGE_BATCH_DIR/merge-push.sh" || {
  echo "merge-batch: cannot source merge-push.sh from $MERGE_BATCH_DIR" >&2
  exit 1
}

# The scratch branch a member is rebased on before temp advances to it.
MERGE_BATCH_SCRATCH=batch-member

batch_usage() {
  echo "usage: merge-batch.sh select --head <id> [--max <K>] [config flags]"
  echo "       merge-batch.sh stack  --head <id> [--members <id,id,...>] [config flags]"
  echo "       merge-batch.sh land   --head <id> [config flags]"
  echo "       merge-batch.sh serial --head <id> [config flags]"
}

mb_warn() {
  echo "merge-batch: WARN $*" >&2
}

# mb_load_bead <id> — read the bead into MB_JSON. Returns 1 when it cannot be
# read, which is not the same thing as the bead being ineligible.
mb_load_bead() {
  MB_JSON=$(gc bd show "$1" --json 2>/dev/null) || return 1
  printf '%s' "$MB_JSON" | jq -e '.[0].id // empty' >/dev/null 2>&1 || return 1
  return 0
}

mb_meta() {
  printf '%s' "$MB_JSON" | jq -r --arg k "$1" '.[0].metadata[$k] // empty'
}

mb_target() {
  printf '%s' "$MB_JSON" | jq -r --arg d "$CFG_TARGET_DEFAULT" '.[0].metadata.target // $d'
}

# mb_check_member <id> <head-target> — is <id> eligible to ride in the head's
# batch? Returns 0 when it is, with MB_BRANCH, MB_TARGET and MB_FORK set. Returns
# 1 when it is not and sets MB_WHY; MB_READ_FAILED=1 says the bead store could
# not be read, which stack treats as an internal error rather than ineligibility.
mb_check_member() {
  mc_id="$1"
  mc_head_target="$2"
  MB_WHY=""
  MB_READ_FAILED=0
  if ! mb_load_bead "$mc_id"; then
    MB_READ_FAILED=1
    MB_WHY="cannot read bead $mc_id"
    return 1
  fi
  MB_BRANCH=$(mb_meta branch)
  MB_TARGET=$(mb_target)
  MB_FORK=$(mb_meta fork_sha)
  mc_existing_pr=$(mb_meta existing_pr)
  mc_serial=$(mb_meta merge_batch_serial)

  mc_strategy=$(resolve_merge_strategy "$mc_id" 2>/dev/null)
  if [ "$mc_strategy" != direct ]; then
    MB_WHY="$mc_id has merge_strategy '${mc_strategy:-<unreadable>}', not direct"
    return 1
  fi
  if [ -n "$mc_existing_pr" ]; then
    MB_WHY="$mc_id has an existing_pr"
    return 1
  fi
  if [ -z "$MB_BRANCH" ]; then
    MB_WHY="$mc_id has no metadata.branch"
    return 1
  fi
  if [ "$MB_TARGET" != "$mc_head_target" ]; then
    MB_WHY="$mc_id targets '$MB_TARGET', the head targets '$mc_head_target'"
    return 1
  fi
  if [ -z "$MB_FORK" ]; then
    MB_WHY="$mc_id has no metadata.fork_sha"
    return 1
  fi
  if ! git fetch -q origin "+refs/heads/${MB_BRANCH}:refs/remotes/origin/${MB_BRANCH}" >/dev/null 2>&1; then
    MB_WHY="$mc_id: branch $MB_BRANCH could not be fetched from origin"
    return 1
  fi
  if [ -n "$mc_serial" ] && [ "$mc_serial" = "$(git rev-parse --verify -q "origin/$MB_BRANCH" 2>/dev/null)" ]; then
    MB_WHY="$mc_id already went red in a batch at its current tip (merge_batch_serial)"
    return 1
  fi
  return 0
}

# --- select -----------------------------------------------------------------

cmd_select() {
  sel_head=""
  sel_max="$MERGE_BATCH_DEFAULT_MAX"
  sel_pass=()
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --head)
        [ "$#" -ge 2 ] || { echo "merge-batch: --head needs a value." >&2; batch_usage >&2; return 1; }
        sel_head="$2"
        shift 2
        ;;
      --max)
        [ "$#" -ge 2 ] || { echo "merge-batch: --max needs a value." >&2; batch_usage >&2; return 1; }
        sel_max="$2"
        shift 2
        ;;
      *)
        sel_pass+=("$1")
        shift
        ;;
    esac
  done
  if [ -z "$sel_head" ]; then
    echo "merge-batch: select needs --head <id>." >&2
    batch_usage >&2
    return 1
  fi
  case "$sel_max" in
    ''|*[!0-9]*|0)
      echo "merge-batch: --max must be a positive integer, got '$sel_max'." >&2
      return 1
      ;;
  esac
  # resolve_config reports on stdout; select's stdout is the ids alone.
  resolve_config --work "$sel_head" ${sel_pass[@]+"${sel_pass[@]}"} >&2 || return 1
  resolve_approval_required
  if [ "$APPROVAL_REQUIRED" -eq 1 ]; then
    echo "merge-batch: the approval gate is on; a batch of 1." >&2
    sel_max=1
  fi

  # The head is always the first line, whatever happens after it.
  printf '%s\n' "$sel_head"
  [ "$sel_max" -gt 1 ] || return 0

  if [ -z "${GC_AGENT:-}" ]; then
    mb_warn "GC_AGENT is not set, so the assignee scan cannot run; a batch of 1."
    return 0
  fi
  if ! mb_load_bead "$sel_head"; then
    mb_warn "cannot read head bead $sel_head; a batch of 1."
    return 0
  fi
  sel_head_target=$(mb_target)
  # The head rides the batch's direct lane too, so it must pass the member rules
  # itself: a head that would hand off as a pull request is a batch of one.
  if ! mb_check_member "$sel_head" "$sel_head_target"; then
    echo "merge-batch: the head is not batchable: $MB_WHY; a batch of 1." >&2
    return 0
  fi

  sel_rig=()
  [ -z "${CFG_RIG:-}" ] || sel_rig=(--rig="$CFG_RIG")
  # find-work's assignee scan, in find-work's sort, never --limit=1: the batch is
  # a prefix of this queue.
  if ! sel_list=$(gc bd list ${sel_rig[@]+"${sel_rig[@]}"} --assignee="$GC_AGENT" --status=open,in_progress \
    --exclude-type=epic --has-metadata-key=branch --limit=0 --json); then
    mb_warn "the assignee scan failed; a batch of 1."
    return 0
  fi
  if ! sel_ids=$(printf '%s' "$sel_list" |
    jq -r 'sort_by(.priority, (.metadata.first_submitted_at // .created_at)) | .[].id'); then
    mb_warn "the assignee scan was not parseable; a batch of 1."
    return 0
  fi
  sel_first=$(printf '%s\n' "$sel_ids" | sed -n 1p)
  if [ "$sel_first" != "$sel_head" ]; then
    mb_warn "head $sel_head does not lead the assignee queue (first is '${sel_first:-<empty>}'); a batch of 1."
    return 0
  fi

  sel_count=1
  # A for loop, not a read loop: the git and gc calls inside would otherwise
  # inherit the loop's stdin and could swallow the ids still to come. Bead ids
  # carry no whitespace.
  for sel_id in $sel_ids; do
    [ "$sel_id" != "$sel_head" ] || continue
    [ "$sel_count" -lt "$sel_max" ] || break
    if ! mb_check_member "$sel_id" "$sel_head_target"; then
      echo "merge-batch: select stops before $sel_id: $MB_WHY" >&2
      break
    fi
    printf '%s\n' "$sel_id"
    sel_count=$((sel_count + 1))
  done
  return 0
}

# --- stack ------------------------------------------------------------------

# sb_patch_id <rev> — the stable patch-id of one commit.
sb_patch_id() {
  git show "$1" 2>/dev/null | git patch-id --stable 2>/dev/null | cut -d' ' -f1
}

# sb_entry_json <id> <branch> <tip> <commits> <patch-id>
sb_entry_json() {
  jq -nc --arg id "$1" --arg branch "$2" --arg tip "$3" --argjson commits "$4" --arg patch "$5" \
    '{id: $id, branch: $branch, tip: $tip, commits: $commits, patch_id: $patch}'
}

# sb_write_manifest <members-json-array>
sb_write_manifest() {
  swm_tmp="${SB_MANIFEST}.tmp"
  if jq -n --arg head "$SB_HEAD" --arg target "$SB_TARGET" --arg base "$SB_ENTRY" --argjson members "$1" \
    '{head: $head, target: $target, base: $base, members: $members}' >"$swm_tmp" &&
    mv -f "$swm_tmp" "$SB_MANIFEST"; then
    return 0
  fi
  mb_warn "could not write $SB_MANIFEST."
  return 1
}

# sb_drop_scratch — return to temp and delete the scratch branch. Returns 1 when
# temp cannot be checked out.
sb_drop_scratch() {
  git checkout -q temp >/dev/null 2>&1 || return 1
  git branch -D "$MERGE_BATCH_SCRATCH" >/dev/null 2>&1 || true
  return 0
}

# sb_degrade <reason> — the degrade-to-single principle: put temp back on the
# head tip recorded at entry, write a one-member manifest, and carry on. Exits 0
# even when a step of the reset fails, because the caller's alternative is the
# single-bead lane and that must still be reachable.
sb_degrade() {
  mb_warn "$1; falling back to a batch of 1."
  git rebase --abort >/dev/null 2>&1 || true
  git checkout -q -f temp >/dev/null 2>&1 || mb_warn "could not check temp out while degrading."
  git reset -q --hard "$SB_ENTRY" >/dev/null 2>&1 || mb_warn "could not reset temp to $SB_ENTRY while degrading."
  git branch -D "$MERGE_BATCH_SCRATCH" >/dev/null 2>&1 || true
  sb_write_manifest "[$SB_HEAD_ENTRY]" || true
  echo "merge-batch: STACK 1 of ${SB_WANTED:-1} head=$SB_HEAD (degraded)"
  return 0
}

# sb_stack_member <id> — stack one member onto temp. Returns:
#   0  stacked: temp advanced and the member is in SB_MEMBERS_JSON
#   3  collapsed and already landed: closed as already merged, not in the batch
#   1  the batch ends here; SB_WHY says why
#   2  an internal error; SB_WHY says what, and the caller degrades
sb_stack_member() {
  sm_id="$1"
  if ! mb_check_member "$sm_id" "$SB_TARGET"; then
    SB_WHY="$MB_WHY"
    [ "$MB_READ_FAILED" -eq 0 ] || return 2
    return 1
  fi
  sm_branch="$MB_BRANCH"
  sm_fork="$MB_FORK"

  if ! git checkout -q -B "$MERGE_BATCH_SCRATCH" "origin/$sm_branch" >/dev/null 2>&1; then
    SB_WHY="could not check out origin/$sm_branch for $sm_id"
    return 2
  fi
  if ! git rebase -q temp >/dev/null 2>&1; then
    sm_unmerged=$(git ls-files -u 2>/dev/null)
    git rebase --abort >/dev/null 2>&1 || true
    if ! sb_drop_scratch; then
      SB_WHY="could not return to temp after the rebase of $sm_id failed"
      return 2
    fi
    if [ -n "$sm_unmerged" ]; then
      SB_WHY="$sm_id conflicts with the batch stacked so far"
      return 1
    fi
    SB_WHY="the rebase of $sm_id failed without a conflict"
    return 2
  fi
  if ! sm_tip=$(git rev-parse --verify -q HEAD) ||
    ! sm_count=$(git rev-list --count "temp..$sm_tip" 2>/dev/null); then
    SB_WHY="could not read the rebased tip of $sm_id"
    return 2
  fi

  if [ "$sm_count" -eq 0 ] || git diff --quiet temp "$sm_tip" 2>/dev/null; then
    if ! sb_drop_scratch; then
      SB_WHY="could not return to temp after $sm_id collapsed"
      return 2
    fi
    # The helpers read WORK, BRANCH and TARGET; they are this member's.
    # shellcheck disable=SC2034
    WORK="$sm_id"
    BRANCH="$sm_branch"
    TARGET="$SB_TARGET"
    branch_already_landed "origin/$TARGET" "origin/$BRANCH" "$sm_fork"
    sm_landed=$?
    if [ "$sm_landed" -ne 0 ]; then
      SB_WHY="$sm_id collapses to no change and is not already landed on $TARGET (branch_already_landed status $sm_landed)"
      return 1
    fi
    sm_sha=$(upstream_equivalent_sha "origin/$TARGET" "origin/$BRANCH") ||
      sm_sha=$(git rev-parse "origin/$TARGET")
    # The helper's stdout tells the agent to skip the merge script, which is the
    # lane's advice and not a batch's, so it is held back and summarised here.
    if ! sm_out=$(close_already_merged "$sm_sha" rebase_patch_id "every commit on origin/$BRANCH since $sm_fork is already upstream in origin/$TARGET by patch-id, and its rebase is empty"); then
      SB_WHY="$sm_id is already merged but closing it failed: $(printf '%s' "$sm_out" | tr '\n' ' ')"
      return 1
    fi
    echo "merge-batch: $sm_id is already merged to $TARGET at $(git rev-parse --short "$sm_sha" 2>/dev/null); closed it and stacked past it."
    if [ "$CFG_DELETE_MERGED_BRANCHES" = "true" ]; then
      git push -q origin --delete "$BRANCH" >/dev/null 2>&1 ||
        mb_warn "could not delete the merged branch $BRANCH on origin."
    fi
    return 3
  fi

  if ! sb_drop_scratch; then
    SB_WHY="could not return to temp to advance it to $sm_id"
    return 2
  fi
  if ! git merge -q --ff-only "$sm_tip" >/dev/null 2>&1; then
    SB_WHY="temp would not fast-forward to the stacked tip of $sm_id"
    return 2
  fi
  sm_patch=$(sb_patch_id "$sm_tip")
  if ! sm_entry=$(sb_entry_json "$sm_id" "$sm_branch" "$sm_tip" "$sm_count" "$sm_patch"); then
    SB_WHY="could not record $sm_id in the manifest"
    return 2
  fi
  if ! SB_MEMBERS_JSON=$(printf '%s' "$SB_MEMBERS_JSON" | jq -c --argjson m "$sm_entry" '. + [$m]'); then
    SB_WHY="could not record $sm_id in the manifest"
    return 2
  fi
  return 0
}

cmd_stack() {
  stk_head=""
  stk_members=""
  stk_pass=()
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --head)
        [ "$#" -ge 2 ] || { echo "merge-batch: --head needs a value." >&2; batch_usage >&2; return 1; }
        stk_head="$2"
        shift 2
        ;;
      --members)
        [ "$#" -ge 2 ] || { echo "merge-batch: --members needs a value." >&2; batch_usage >&2; return 1; }
        stk_members="$2"
        shift 2
        ;;
      *)
        stk_pass+=("$1")
        shift
        ;;
    esac
  done
  if [ -z "$stk_head" ]; then
    echo "merge-batch: stack needs --head <id>." >&2
    batch_usage >&2
    return 1
  fi
  resolve_config --work "$stk_head" ${stk_pass[@]+"${stk_pass[@]}"} >&2 || return 1
  resolve_approval_required

  if ! SB_ENTRY=$(git rev-parse --verify -q refs/heads/temp); then
    echo "merge-batch: there is no temp branch to stack onto." >&2
    return 1
  fi
  if ! SB_GIT_DIR=$(git rev-parse --git-dir 2>/dev/null); then
    echo "merge-batch: not inside a git repository." >&2
    return 1
  fi
  SB_MANIFEST="$SB_GIT_DIR/refinery-batch.json"
  SB_HEAD="$stk_head"
  SB_TARGET=""
  SB_WANTED=1
  SB_HEAD_ENTRY=$(sb_entry_json "$SB_HEAD" "" "$SB_ENTRY" 0 "")

  # The members the agent settled on, head first.
  if [ -n "$stk_members" ]; then
    stk_ids=$(printf '%s' "$stk_members" | tr ',' '\n')
    stk_first=$(printf '%s\n' "$stk_ids" | sed -n 1p)
    if [ "$stk_first" != "$SB_HEAD" ]; then
      echo "merge-batch: --members must start with the head $SB_HEAD, got '$stk_first'." >&2
      return 1
    fi
  elif [ -f "$SB_MANIFEST" ] && [ "$(jq -r '.head // empty' "$SB_MANIFEST" 2>/dev/null)" = "$SB_HEAD" ]; then
    stk_ids=$(jq -r '.members[]?.id' "$SB_MANIFEST" 2>/dev/null)
  else
    stk_ids="$SB_HEAD"
  fi
  [ -n "$stk_ids" ] || stk_ids="$SB_HEAD"
  SB_WANTED=$(printf '%s\n' "$stk_ids" | grep -c .)

  if ! git checkout -q temp >/dev/null 2>&1; then
    sb_degrade "could not check temp out"
    return 0
  fi
  if ! mb_load_bead "$SB_HEAD"; then
    sb_degrade "cannot read head bead $SB_HEAD"
    return 0
  fi
  SB_HEAD_BRANCH=$(mb_meta branch)
  SB_TARGET=$(mb_target)
  if [ -z "$SB_TARGET" ] || [ "$SB_TARGET" = null ]; then
    sb_degrade "head bead $SB_HEAD has no target"
    return 0
  fi
  stk_head_commits=$(git rev-list --count "origin/$SB_TARGET..$SB_ENTRY" 2>/dev/null) || stk_head_commits=0
  if ! SB_HEAD_ENTRY=$(sb_entry_json "$SB_HEAD" "$SB_HEAD_BRANCH" "$SB_ENTRY" "$stk_head_commits" "$(sb_patch_id "$SB_ENTRY")"); then
    sb_degrade "could not build the head's manifest entry"
    return 0
  fi
  SB_MEMBERS_JSON="[$SB_HEAD_ENTRY]"

  stk_batchable=1
  if [ "$APPROVAL_REQUIRED" -eq 1 ]; then
    echo "merge-batch: the approval gate is on; a batch of 1."
    stk_batchable=0
  elif ! mb_check_member "$SB_HEAD" "$SB_TARGET"; then
    if [ "$MB_READ_FAILED" -eq 1 ]; then
      sb_degrade "$MB_WHY"
      return 0
    fi
    echo "merge-batch: the head is not batchable: $MB_WHY; a batch of 1."
    stk_batchable=0
  fi
  if [ "$stk_batchable" -eq 1 ]; then
    # A head whose rebase collapsed (its work already landed, or it produced
    # nothing) has no commit of its own. Batched, land would map it to another
    # member's commit and close it merged on that sha (M1), so it stays a batch
    # of 1 and merge-push.sh --work's merge-state gate decides it.
    branch_has_real_change "origin/$SB_TARGET" "$SB_ENTRY"
    stk_real=$?
    case "$stk_real" in
      0) ;;
      1)
        echo "merge-batch: the head's rebase is empty; merge-push.sh --work's merge-state gate decides it; a batch of 1."
        stk_batchable=0
        ;;
      *)
        sb_degrade "could not tell whether the head carries a change"
        return 0
        ;;
    esac
  fi
  if [ "$stk_batchable" -eq 1 ]; then
    # A for loop, not a read loop, for the reason select gives.
    for stk_id in $stk_ids; do
      [ "$stk_id" != "$SB_HEAD" ] || continue
      SB_WHY=""
      sb_stack_member "$stk_id"
      stk_rc=$?
      case "$stk_rc" in
        0) echo "merge-batch: stacked $stk_id." ;;
        3) ;;
        1)
          echo "merge-batch: stack ends before $stk_id: $SB_WHY"
          break
          ;;
        *)
          sb_degrade "$SB_WHY"
          return 0
          ;;
      esac
    done
  fi

  git checkout -q temp >/dev/null 2>&1 || {
    sb_degrade "could not end on temp"
    return 0
  }
  if ! sb_write_manifest "$SB_MEMBERS_JSON"; then
    sb_degrade "could not write the manifest"
    return 0
  fi
  stk_final=$(printf '%s' "$SB_MEMBERS_JSON" | jq -r '[.[].id] | join(" ")')
  stk_size=$(printf '%s' "$SB_MEMBERS_JSON" | jq -r 'length')
  echo "merge-batch: STACK $stk_size of $SB_WANTED head=$SB_HEAD members=$stk_final tip=$(git rev-parse temp)"
  return 0
}

# --- land -------------------------------------------------------------------

# lb_member <index> <field> — one field of the manifest's member at <index>.
lb_member() {
  printf '%s' "$LB_JSON" | jq -r --argjson i "$1" --arg f "$2" '.members[$i][$f] | tostring'
}

# lb_append_landed / lb_append_left_open <id> — the lists the RESULT line prints.
lb_append_landed() {
  LB_LANDED="${LB_LANDED:+$LB_LANDED,}$1"
}

lb_append_left_open() {
  LB_LEFT_OPEN="${LB_LEFT_OPEN:+$LB_LEFT_OPEN,}$1"
}

# lb_record <id> <sha> <pos> — write one landed member's result and close it.
# Returns 1 when either call fails; the caller leaves the member open.
lb_record() {
  lr_id="$1"
  lr_sha="$2"
  lr_pos="$3"
  lr_short=$(git rev-parse --short "$lr_sha" 2>/dev/null) || return 1
  if gc bd update "$lr_id" \
    --set-metadata merge_result=merged \
    --set-metadata merged_sha="$lr_sha" \
    --set-metadata merged_target="$LB_TARGET" \
    --set-metadata merge_batch="$LB_HEAD@$LB_LANDED_SHORT" \
    --set-metadata merge_batch_size="$LB_SIZE" \
    --set-metadata merge_batch_pos="$lr_pos" \
    --unset-metadata rejection_reason &&
    gc bd close "$lr_id" --reason "Merged to $LB_TARGET at $lr_short (batch $lr_pos/$LB_SIZE, $LB_HEAD@$LB_LANDED_SHORT)"; then
    return 0
  fi
  return 1
}

# lb_land_members — after a verified landing, map each member to its own commit
# in the landed stack and record it. Sets LB_LANDED and LB_LEFT_OPEN. Returns 0
# when every member closed and 2 when one was left open.
lb_land_members() {
  lm_landed_sha="$MERGED_SHA"
  LB_LANDED_SHORT=$(git rev-parse --short "$lm_landed_sha" 2>/dev/null) || LB_LANDED_SHORT="$lm_landed_sha"
  # A for loop, not a read loop, for the reason select gives.
  for lm_idx in $(seq 0 $((LB_SIZE - 1))); do
    lm_id=$(lb_member "$lm_idx" id)
    lm_branch=$(lb_member "$lm_idx" branch)
    lm_pos=$((lm_idx + 1))
    lm_offset=$(printf '%s' "$LB_JSON" | jq -r --argjson i "$lm_idx" '[.members[$i + 1:][].commits] | add // 0')
    # The member's own commit in the landed stack. Never L itself, the
    # manifest's tip or another member's commit (M1).
    if ! lm_sha=$(git rev-parse --verify -q "$lm_landed_sha~$lm_offset^{commit}" 2>/dev/null); then
      mb_warn "$lm_id: no commit $lm_offset behind the landed tip $LB_LANDED_SHORT; leaving it open."
      lb_append_left_open "$lm_id"
      continue
    fi
    lm_patch=$(sb_patch_id "$lm_sha")
    if [ -z "$lm_patch" ] || [ "$lm_patch" != "$(lb_member "$lm_idx" patch_id)" ]; then
      mb_warn "$lm_id: the commit $lm_offset behind the landed tip is not its patch (the patch-id differs from the stacked one); leaving it open."
      lb_append_left_open "$lm_id"
      continue
    fi
    if ! lb_record "$lm_id" "$lm_sha" "$lm_pos"; then
      mb_warn "$lm_id landed at $lm_sha but recording it failed; leaving it open for the merge-state gate."
      lb_append_left_open "$lm_id"
      continue
    fi
    lb_append_landed "$lm_id"
    if [ "$CFG_DELETE_MERGED_BRANCHES" = "true" ]; then
      git push -q origin --delete "$lm_branch" >/dev/null 2>&1 ||
        mb_warn "could not delete the merged branch $lm_branch on origin."
    fi
  done
  [ -z "$LB_LEFT_OPEN" ] && return 0
  return 2
}

# lb_read_manifest <head> <cmd> — read and check the manifest stack wrote, for
# land and serial alike. Sets LB_MANIFEST, LB_JSON and LB_SIZE. Returns 1, with
# the reason on stderr, when it is missing, unparseable, for another head, holds
# fewer than two members, or has a bad field. A member with no commits is a bad
# field: it has no commit of its own to record, and stack never writes one into a
# batch of more than one.
lb_read_manifest() {
  rm_head="$1"
  rm_cmd="$2"
  if ! rm_git_dir=$(git rev-parse --git-dir 2>/dev/null); then
    echo "merge-batch: not inside a git repository." >&2
    return 1
  fi
  LB_MANIFEST="$rm_git_dir/refinery-batch.json"
  if [ ! -f "$LB_MANIFEST" ]; then
    echo "merge-batch: there is no manifest at $LB_MANIFEST; run stack first." >&2
    return 1
  fi
  if ! LB_JSON=$(jq -c . "$LB_MANIFEST" 2>/dev/null) || [ -z "$LB_JSON" ]; then
    echo "merge-batch: the manifest $LB_MANIFEST is not parseable." >&2
    return 1
  fi
  if [ "$(printf '%s' "$LB_JSON" | jq -r '.head // empty' 2>/dev/null)" != "$rm_head" ]; then
    echo "merge-batch: the manifest is not for head $rm_head." >&2
    return 1
  fi
  LB_SIZE=$(printf '%s' "$LB_JSON" | jq -r '.members | if type == "array" then length else 0 end' 2>/dev/null)
  case "$LB_SIZE" in
    '' | *[!0-9]*) LB_SIZE=0 ;;
  esac
  if [ "$LB_SIZE" -lt 2 ]; then
    echo "merge-batch: the manifest holds $LB_SIZE member(s); a batch of one is merge-push.sh --work's ($rm_cmd)." >&2
    return 1
  fi
  if ! printf '%s' "$LB_JSON" | jq -e '
    (.target | type == "string" and length > 0) and
    all(.members[];
      (.id | type == "string" and length > 0) and
      (.branch | type == "string" and length > 0) and
      (.tip | type == "string" and length > 0) and
      (.patch_id | type == "string" and length > 0) and
      (.commits | type == "number" and . >= 1 and . == floor))' >/dev/null 2>&1; then
    echo "merge-batch: the manifest is missing a target or a member field, or a member has no commits." >&2
    return 1
  fi
  return 0
}

# lb_land <args...> — the body of land. Returns the status; cmd_land prints it.
lb_land() {
  lnd_head=""
  lnd_pass=()
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --head)
        [ "$#" -ge 2 ] || { echo "merge-batch: --head needs a value." >&2; batch_usage >&2; return 1; }
        lnd_head="$2"
        shift 2
        ;;
      *)
        lnd_pass+=("$1")
        shift
        ;;
    esac
  done
  if [ -z "$lnd_head" ]; then
    echo "merge-batch: land needs --head <id>." >&2
    batch_usage >&2
    return 1
  fi
  if ! resolve_config --work "$lnd_head" ${lnd_pass[@]+"${lnd_pass[@]}"} >&2; then
    batch_usage >&2
    return 1
  fi
  resolve_approval_required

  lb_read_manifest "$lnd_head" land || return 1

  # From here a guard is a hard stop (2): the manifest is well-formed, so what
  # fails is the state around it. Nothing is pushed or written.
  if [ "$APPROVAL_REQUIRED" -eq 1 ]; then
    echo "merge-batch: the approval gate is on (or unreadable); a batch of more than one never rode it. Nothing landed." >&2
    return 2
  fi
  LB_HEAD="$lnd_head"
  LB_TARGET=$(printf '%s' "$LB_JSON" | jq -r '.target')
  lnd_last_tip=$(lb_member $((LB_SIZE - 1)) tip)
  lnd_temp=$(git rev-parse --verify -q refs/heads/temp 2>/dev/null)
  if [ "$lnd_temp" != "$lnd_last_tip" ]; then
    echo "merge-batch: temp is at '${lnd_temp:-<none>}', not the manifest's last tip $lnd_last_tip; the manifest is stale. Nothing landed." >&2
    return 2
  fi

  # merge_ff_push reads TARGET, BRANCH (messages only) and APPROVAL_REQUIRED, and
  # is not copied here: the batch lands exactly as the single-bead lane does.
  TARGET="$LB_TARGET"
  BRANCH=$(lb_member 0 branch)
  APPROVAL_REQUIRED=0
  merge_ff_push
  lnd_push=$?
  if [ "$lnd_push" -ne 0 ]; then
    echo "merge-batch: merge_ff_push did not land the batch on $TARGET (status $lnd_push). No member was written; temp and the manifest are left in place."
    return "$lnd_push"
  fi

  lb_land_members
  lnd_rc=$?
  # The manifest describes a stack that now exists only on the target.
  rm -f "$LB_MANIFEST"
  if [ "$lnd_rc" -eq 0 ]; then
    cleanup_temp
  else
    echo "merge-batch: the batch landed on $TARGET at $MERGED_SHORT, but left open: $LB_LEFT_OPEN. The next patrol's merge-state gate closes each as already merged."
  fi
  return "$lnd_rc"
}

cmd_land() {
  LB_LANDED=""
  LB_LEFT_OPEN=""
  lb_land "$@"
  cl_rc=$?
  echo "merge-batch: RESULT $cl_rc landed=$LB_LANDED left-open=$LB_LEFT_OPEN"
  return "$cl_rc"
}

# --- serial -----------------------------------------------------------------

# sr_append_serial / sr_append_failed <id> — the lists the RESULT line prints.
sr_append_serial() {
  SR_SERIAL="${SR_SERIAL:+$SR_SERIAL,}$1"
}

sr_append_failed() {
  SR_FAILED="${SR_FAILED:+$SR_FAILED,}$1"
}

# sr_stamp <id> <branch> <short> — stamp one member of a red batch: record the
# origin/<branch> sha mb_check_member compares, then leave a note. Returns 1 when
# the fetch, the rev-parse or the stamp fails. A note that fails is a WARN: the
# stamp is the mechanism and the note is forensics.
sr_stamp() {
  ss_id="$1"
  ss_branch="$2"
  ss_short="$3"
  if ! git fetch -q origin "+refs/heads/${ss_branch}:refs/remotes/origin/${ss_branch}" >/dev/null 2>&1; then
    mb_warn "$ss_id: branch $ss_branch could not be fetched from origin; not stamped."
    return 1
  fi
  if ! ss_sha=$(git rev-parse --verify -q "origin/$ss_branch" 2>/dev/null) || [ -z "$ss_sha" ]; then
    mb_warn "$ss_id: origin/$ss_branch could not be resolved; not stamped."
    return 1
  fi
  if ! gc bd update "$ss_id" --set-metadata merge_batch_serial="$ss_sha"; then
    mb_warn "$ss_id: recording merge_batch_serial failed; not stamped."
    return 1
  fi
  if ! printf 'merge-batch: batch red at %s; the members go serial. %s carries merge_batch_serial=%s, so select leaves it out of a batch until its branch moves.\n' \
    "$ss_short" "$ss_id" "$ss_sha" | gc bd note "$ss_id" --stdin >/dev/null; then
    mb_warn "$ss_id: stamped, but the note could not be written."
  fi
  return 0
}

# sr_serial <args...> — the body of serial. Returns the status; cmd_serial prints it.
sr_serial() {
  ser_head=""
  ser_pass=()
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --head)
        [ "$#" -ge 2 ] || { echo "merge-batch: --head needs a value." >&2; batch_usage >&2; return 1; }
        ser_head="$2"
        shift 2
        ;;
      *)
        ser_pass+=("$1")
        shift
        ;;
    esac
  done
  if [ -z "$ser_head" ]; then
    echo "merge-batch: serial needs --head <id>." >&2
    batch_usage >&2
    return 1
  fi
  if ! resolve_config --work "$ser_head" ${ser_pass[@]+"${ser_pass[@]}"} >&2; then
    batch_usage >&2
    return 1
  fi
  lb_read_manifest "$ser_head" serial || return 1

  ser_target=$(printf '%s' "$LB_JSON" | jq -r '.target')
  ser_last_tip=$(lb_member $((LB_SIZE - 1)) tip)
  ser_short=$(git rev-parse --short "$ser_last_tip" 2>/dev/null) || ser_short="$ser_last_tip"
  # A for loop, not a read loop, for the reason select gives.
  for ser_idx in $(seq 0 $((LB_SIZE - 1))); do
    ser_id=$(lb_member "$ser_idx" id)
    if sr_stamp "$ser_id" "$(lb_member "$ser_idx" branch)" "$ser_short"; then
      sr_append_serial "$ser_id"
    else
      sr_append_failed "$ser_id"
    fi
  done

  # Whatever happened per member, the stack is spent: the members go through the
  # single-bead lane now, each from its own branch.
  rm -f "$LB_MANIFEST"
  # cleanup_temp reads TARGET.
  # shellcheck disable=SC2034
  TARGET="$ser_target"
  cleanup_temp
  [ -z "$SR_FAILED" ] && return 0
  return 2
}

cmd_serial() {
  SR_SERIAL=""
  SR_FAILED=""
  sr_serial "$@"
  cs_rc=$?
  echo "merge-batch: RESULT $cs_rc serial=$SR_SERIAL failed=$SR_FAILED"
  return "$cs_rc"
}

main_batch() {
  case "${1:-}" in
    select) shift; cmd_select "$@" ;;
    stack) shift; cmd_stack "$@" ;;
    land) shift; cmd_land "$@" ;;
    serial) shift; cmd_serial "$@" ;;
    *)
      batch_usage >&2
      return 1
      ;;
  esac
}

main_batch "$@"
exit $?
