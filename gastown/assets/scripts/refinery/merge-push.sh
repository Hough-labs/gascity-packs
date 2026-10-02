#!/usr/bin/env bash
# merge-push.sh — mol-refinery-patrol's merge-push lane (direct, mr, local) as
# one process.
#
# The refinery used to run this lane as 14 fenced blocks of the formula's
# merge-push step, stitched together and hand-rendered in the agent's own shell
# on every patrol. That cost about 30% of refinery tool calls and produced two
# silent render defects (gcp-l8td). Here one process owns all the shared state
# and every config value is resolved, never rendered (gcp-l8td.3, B1).
#
# The helpers and lane text are the merge-push step's blocks taken through
# tomllib, the renderer's own un-escape, with only these edits: every template
# variable became its resolved CFG_* value; every gh call goes through "$GH";
# every place that ended the agent's shell returns a status instead; the
# approval gate is found as this script's sibling; and the lane glue the step's
# prose described became lane_direct, lane_mr and lane_local. Messages keep
# their wording. gastown/tests/test_refinery_merge_lanes.sh runs every lane
# case through both this script and the formula, with identical assertions.
#
# Usage:
#   merge-push.sh --work <id> [--rig R] [--target-default B] [--binding-prefix P]
#                 [--require-approval V] [--review-agent A]
#                 [--delete-merged-branches V] [--gh BIN]
#
# Run it inside the refinery's clone, with `temp` rebased onto the target, as
# the patrol's rebase step leaves it.
#
# Config, highest precedence first: the flag; the rig's FormulaVars (a key that
# is PRESENT wins even when empty); a value derived from the session; the
# embedded default.
#   require_merge_approval  --require-approval        default false
#   review_agent            --review-agent            default ""
#   delete_merged_branches  --delete-merged-branches  default true
#   target_branch           --target-default          derived: the rig's
#                           DefaultBranch. Used only when the bead has no
#                           metadata.target.
#   binding_prefix          --binding-prefix          derived: $GC_AGENT without
#                           its "<rig>/" prefix and "refinery" suffix
#   rig                     --rig                     derived: $GC_RIG
# FormulaVars come from `gc config show --json`, or from the file named by
# MERGE_PUSH_CONFIG_JSON (a test seam; unset in production). They are never
# read from `gc bd formula show ... .vars`, which reports formula DEFAULTS
# whatever the rig sets, so it would silently disarm a re-armed approval gate.
# If the config cannot be read, or has no entry for the rig, require_merge_approval
# resolves ON (fail closed): an unreadable switch is not permission to skip review.
#
# GH="${REFINERY_GH:-gh}", overridden by --gh.
#
# Output: `merge-push: LANE <direct|mr|local>` once the lane is chosen. The LAST
# line is always `merge-push: RESULT <status> <summary>`.
#
# Exit status. The merge-push step owns patrol-loop control for every status;
# this script never ends the agent's session and never pours or burns a wisp.
#    0  the work bead is closed: landed (direct, or mr after approval), handed
#       off as a pull request (mr, approval off), or closed as already merged
#    1  usage or config error; nothing touched
#    2  hard stop; do not mutate bead state. Also returned when a merge landed
#       but recording it on the bead failed: the next patrol's merge-state gate
#       closes it as already merged.
#    3  the re-rebase onto the moved target conflicted
#    4  parked awaiting review (the gate refused, or the approved head no longer
#       fast-forwards the target)
#    5  the ff-merge was a no-op; nothing landed
#    6  retries exhausted; the target moved under every attempt
#    7  the remote refused the push while the target stood still
#    8  false completion halted: the bead is blocked and mayor + witness nudged
#    9  invalid existing_pr blocked: the bead is blocked and the mayor mailed
#   11  merge_strategy=local is unsupported: the mayor was mailed
#
# MERGE_PUSH_SOURCE_ONLY=1 defines every function and returns before main, so
# tests can source this file and call the helpers directly.
#
# No `set -e`, `set -u` or `set -o pipefail`: the helpers were written for, and
# characterized under, a plain bash shell, and every command that matters is
# checked on its own exit status.

# Canonicalized now, before anything changes directory, so the sibling gate
# path below stays right wherever the lane runs.
MERGE_PUSH_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
GH="${REFINERY_GH:-gh}"

# Must equal mol-refinery-patrol.toml's [vars.<name>].default; the lane suite
# pins that.
MERGE_PUSH_DEFAULT_REQUIRE_MERGE_APPROVAL=false
MERGE_PUSH_DEFAULT_REVIEW_AGENT=""
MERGE_PUSH_DEFAULT_DELETE_MERGED_BRANCHES=true

usage() {
  echo "usage: merge-push.sh --work <id> [--rig R] [--target-default B] [--binding-prefix P]"
  echo "                     [--require-approval V] [--review-agent A]"
  echo "                     [--delete-merged-branches V] [--gh BIN]"
}

# rc_formula_var <name> — print the rig's FormulaVars value for <name>. Returns
# 1 when the config was not read or the key is absent; a present key returns 0
# even when its value is empty.
rc_formula_var() {
  [ "$rc_config_ok" -eq 1 ] || return 1
  printf '%s' "$rc_rig_json" | jq -e --arg k "$1" '(.FormulaVars // {}) | has($k)' >/dev/null 2>&1 || return 1
  printf '%s' "$rc_rig_json" | jq -r --arg k "$1" '.FormulaVars[$k] | if type == "string" then . else tostring end'
}

# resolve_config [flags] — parse the CLI and resolve every CFG_* value, before
# any git or bead action. Returns 1 on a usage or config error.
resolve_config() {
  CFG_WORK=""
  rc_rig="" rc_rig_set=0
  rc_target="" rc_target_set=0
  rc_prefix="" rc_prefix_set=0
  rc_approval="" rc_approval_set=0
  rc_review="" rc_review_set=0
  rc_delete="" rc_delete_set=0
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --work|--rig|--target-default|--binding-prefix|--require-approval|--review-agent|--delete-merged-branches|--gh)
        if [ "$#" -lt 2 ]; then
          echo "merge-push: $1 needs a value." >&2
          usage >&2
          return 1
        fi
        case "$1" in
          --work) CFG_WORK="$2" ;;
          --rig) rc_rig="$2" rc_rig_set=1 ;;
          --target-default) rc_target="$2" rc_target_set=1 ;;
          --binding-prefix) rc_prefix="$2" rc_prefix_set=1 ;;
          --require-approval) rc_approval="$2" rc_approval_set=1 ;;
          --review-agent) rc_review="$2" rc_review_set=1 ;;
          --delete-merged-branches) rc_delete="$2" rc_delete_set=1 ;;
          --gh) GH="$2" ;;
        esac
        shift 2
        ;;
      *)
        echo "merge-push: unknown argument: $1" >&2
        usage >&2
        return 1
        ;;
    esac
  done
  if [ -z "$CFG_WORK" ]; then
    echo "merge-push: --work <id> is required." >&2
    usage >&2
    return 1
  fi

  if [ "$rc_rig_set" -eq 1 ]; then
    CFG_RIG="$rc_rig"
  else
    CFG_RIG="${GC_RIG:-}"
  fi
  if [ -z "$CFG_RIG" ]; then
    echo "merge-push: no rig: pass --rig or run with GC_RIG set." >&2
    return 1
  fi

  rc_config_ok=0
  rc_config_why=""
  rc_rig_json=""
  if [ -n "${MERGE_PUSH_CONFIG_JSON:-}" ]; then
    rc_json=$(cat "$MERGE_PUSH_CONFIG_JSON" 2>/dev/null) || rc_config_why="could not read $MERGE_PUSH_CONFIG_JSON"
  else
    rc_json=$(gc config show --json 2>/dev/null) || rc_config_why="gc config show --json failed"
  fi
  if [ -z "$rc_config_why" ]; then
    if ! rc_rig_json=$(printf '%s' "$rc_json" | jq -c --arg r "$CFG_RIG" '[.config.Rigs[]? | select(.Name == $r)] | .[0] // empty' 2>/dev/null); then
      rc_config_why="the city config is not parseable JSON"
    elif [ -z "$rc_rig_json" ]; then
      rc_config_why="the city config has no Rigs entry named $CFG_RIG"
    else
      rc_config_ok=1
    fi
  fi

  if [ "$rc_approval_set" -eq 1 ]; then
    CFG_REQUIRE_MERGE_APPROVAL="$rc_approval"
  elif rc_value=$(rc_formula_var require_merge_approval); then
    CFG_REQUIRE_MERGE_APPROVAL="$rc_value"
  elif [ "$rc_config_ok" -ne 1 ]; then
    CFG_REQUIRE_MERGE_APPROVAL=true
    echo "merge-push: cannot read rig config for $CFG_RIG ($rc_config_why); require_merge_approval resolves ON (fail closed). An unreadable switch is not permission to skip review."
  else
    CFG_REQUIRE_MERGE_APPROVAL="$MERGE_PUSH_DEFAULT_REQUIRE_MERGE_APPROVAL"
  fi

  if [ "$rc_review_set" -eq 1 ]; then
    CFG_REVIEW_AGENT="$rc_review"
  elif rc_value=$(rc_formula_var review_agent); then
    CFG_REVIEW_AGENT="$rc_value"
  else
    CFG_REVIEW_AGENT="$MERGE_PUSH_DEFAULT_REVIEW_AGENT"
  fi

  if [ "$rc_delete_set" -eq 1 ]; then
    CFG_DELETE_MERGED_BRANCHES="$rc_delete"
  elif rc_value=$(rc_formula_var delete_merged_branches); then
    CFG_DELETE_MERGED_BRANCHES="$rc_value"
  else
    CFG_DELETE_MERGED_BRANCHES="$MERGE_PUSH_DEFAULT_DELETE_MERGED_BRANCHES"
  fi

  # No embedded default. Left empty when nothing supplies it: that is an error
  # only for a bead without metadata.target, and main reports it there.
  if [ "$rc_target_set" -eq 1 ]; then
    CFG_TARGET_DEFAULT="$rc_target"
  elif rc_value=$(rc_formula_var target_branch); then
    CFG_TARGET_DEFAULT="$rc_value"
  elif [ "$rc_config_ok" -eq 1 ]; then
    CFG_TARGET_DEFAULT=$(printf '%s' "$rc_rig_json" | jq -r '.DefaultBranch // empty')
  else
    CFG_TARGET_DEFAULT=""
  fi

  if [ "$rc_prefix_set" -eq 1 ]; then
    CFG_BINDING_PREFIX="$rc_prefix"
  elif rc_value=$(rc_formula_var binding_prefix); then
    CFG_BINDING_PREFIX="$rc_value"
  else
    # testrig/gastown.refinery -> "gastown."; testrig/refinery -> "".
    case "${GC_AGENT:-}" in
      "$CFG_RIG"/*refinery)
        CFG_BINDING_PREFIX="${GC_AGENT#"$CFG_RIG"/}"
        CFG_BINDING_PREFIX="${CFG_BINDING_PREFIX%refinery}"
        ;;
      *)
        echo "merge-push: cannot derive binding_prefix: GC_AGENT='${GC_AGENT:-}' is not '$CFG_RIG/<prefix>refinery'. Pass --binding-prefix." >&2
        return 1
        ;;
    esac
  fi

  echo "merge-push: config rig=$CFG_RIG target_default=${CFG_TARGET_DEFAULT:-<none>} require_merge_approval=$CFG_REQUIRE_MERGE_APPROVAL review_agent=$CFG_REVIEW_AGENT delete_merged_branches=$CFG_DELETE_MERGED_BRANCHES binding_prefix=$CFG_BINDING_PREFIX gh=$GH"
  return 0
}

result_summary() {
  case "$1" in
    0) echo "work bead closed" ;;
    1) echo "usage or config error; nothing touched" ;;
    2) echo "hard stop; do not mutate bead state" ;;
    3) echo "re-rebase onto the moved target conflicted" ;;
    4) echo "parked awaiting review" ;;
    5) echo "ff-merge was a no-op; nothing landed" ;;
    6) echo "retries exhausted; the target moved under every attempt" ;;
    7) echo "push refused while the target stood still" ;;
    8) echo "false completion halted; mayor and witness nudged" ;;
    9) echo "invalid existing_pr blocked; mayor mailed" ;;
    11) echo "merge_strategy=local unsupported; mayor mailed" ;;
    *) echo "unexpected status" ;;
  esac
}

# --- approval gate ----------------------------------------------------------

# merge-approval-gate.sh ships beside this script in the same pack tree
# (assets/scripts/checks/ next to assets/scripts/refinery/). The sibling path is
# therefore present whenever this script is, and version-coherent with it by
# construction: a script from pin X can never reach a gate from pin Y. That is
# what the formula's `gc formula list` lookup existed to guarantee (gcp-amo);
# the sibling path gets it without a gc call.
resolve_approval_gate() {
  rag_dir=$(cd "$MERGE_PUSH_DIR/../checks" 2>/dev/null && pwd) || return 1
  if [ -f "$rag_dir/merge-approval-gate.sh" ]; then
    printf '%s\n' "$rag_dir/merge-approval-gate.sh"
    return 0
  fi
  return 1
}

run_approval_gate() {
  # $1 = the commit the refinery is about to land. Passing it closes the gap
  # where the local rebased tip has drifted from the reviewed PR head.
  ag_sha="${1:-}"
  set -- --bead "$WORK" --required "$CFG_REQUIRE_MERGE_APPROVAL"
  if [ -n "$ag_sha" ]; then
    set -- "$@" --merge-sha "$ag_sha"
  fi
  bash "$APPROVAL_GATE" "$@"
}

# Reviewer addressing. review_agent is written unqualified in the rig's
# formula_vars (`specialists.iris`, `gastown.mayor`) and the rig prefix used to
# be pasted on unconditionally. That is right for a rig-scoped reviewer and
# wrong for a town-level one: gascity-packs names `gastown.mayor`, whose only
# session address is the bare name, so every park nudged
# `gascity-packs/gastown.mayor`, got "session not found", and — fire-and-forget,
# with no retry and no marker — never told the reviewer anything. On a rig whose
# whole point is a review gate, that turns "reviewed merges" into "merges that
# wait forever" (gcp-a22).
#
# So resolve rather than assume. A bare name is tried rig-scoped first and then
# town-level: the rig attempt stays first so a rig-local reviewer is never
# shadowed by a town agent that happens to share its name. An address the
# operator already qualified (`otherrig/agent`) is taken verbatim, and a leading
# `/` forces town-level and skips the rig attempt.
nudge_review_agent() {
  # $1 = message. Echoes the address that accepted it, or — on return 1 — a
  # flattened diagnostic naming every scope that refused.
  nra_msg="$1"
  nra_addr="$CFG_REVIEW_AGENT"
  case "$nra_addr" in
    /*) set -- "${nra_addr#/}" ;;
    */*) set -- "$nra_addr" ;;
    *)
      if [ -n "${GC_RIG:-}" ]; then
        set -- "$GC_RIG/$nra_addr" "$nra_addr"
      else
        set -- "$nra_addr"
      fi
      ;;
  esac
  nra_errors=""
  for nra_try in "$@"; do
    if nra_out=$(gc session nudge "$nra_try" "$nra_msg" 2>&1); then
      printf '%s' "$nra_try"
      return 0
    fi
    nra_errors="${nra_errors:+$nra_errors; }$nra_try: $(printf '%s' "$nra_out" | tr '
' ' ')"
  done
  printf '%s' "$nra_errors"
  return 1
}

park_awaiting_review() {
  # A refused merge is not a failure and not an incident: the branch is fine,
  # the reviewer simply has not approved THIS commit. Leave the bead open and
  # assigned to the refinery with the refusal recorded, nudge the reviewer if
  # the rig named one, and let the next patrol iteration re-check. Never
  # close, never escalate, never retry the merge in this iteration.
  # The gate reports on stderr and can emit more than one line; metadata is a
  # single-line store, so flatten before writing.
  ag_reason=$(printf '%s' "$1" | tr '
' ' ')
  if ! gc bd update "$WORK" --set-metadata merge_approval_state=awaiting_review --set-metadata merge_approval_gate_reason="$ag_reason"; then
    echo "WARN could not record the gate refusal on $WORK; the bead stays open and unmerged regardless."
  fi
  if [ -n "$CFG_REVIEW_AGENT" ]; then
    # The nudge is the only thing that tells the reviewer this bead is waiting,
    # so its outcome goes into durable state either way — a failure visible only
    # in a patrol transcript is exactly how gcp-a22 stayed invisible. One field,
    # rewritten on every park, so a later delivery cannot leave a stale failure
    # standing behind it.
    if ag_nudge=$(nudge_review_agent "REVIEW NEEDED: $WORK — ${PR_URL:-$BRANCH} awaiting merge approval. Record a verdict with record-merge-approval.sh (--pr + --sha of the live head)."); then
      gc bd update "$WORK" --set-metadata merge_approval_nudge="delivered: $ag_nudge" ||
        echo "WARN could not record the review nudge delivery on $WORK."
    else
      echo "WARN review nudge for $WORK reached no reviewer session: $ag_nudge"
      gc bd update "$WORK" --set-metadata merge_approval_nudge="failed: $ag_nudge" ||
        echo "WARN could not record the review nudge failure on $WORK; it is visible only in this transcript."
    fi
  fi
  echo "APPROVAL GATE REFUSED: $WORK — $1"
  echo "Bead left open and assigned to the refinery; skip the merge and run patrol-summary + next-iteration."
}
# --- existing_pr escalation -------------------------------------------------

block_existing_pr() {
  reason="$1"
  gc bd update $WORK --assignee="" --set-metadata merge_result=blocked --set-metadata gc.routed_to=human --set-metadata blocked_reason="$reason"
  gc mail send mayor/ -s "ESCALATION: invalid existing_pr for $WORK" -m "$reason
Work bead: $WORK
Existing PR: $EXISTING_PR
Branch: $BRANCH
Target: $TARGET"
  # Patrol-loop control (pour the next wisp, assign it, burn this one) belongs
  # to the merge-push step, not to this script: status 9 tells it to run
  # next-iteration's pour/assign/burn (gcp-l8td.3 § Exit status contract).
  echo "$reason"
  echo "STOP. Existing PR metadata needs human correction."
  return 9
}
# --- merge-state helpers ----------------------------------------------------

branch_has_real_change() {
  # Shared false-completion predicate (0-diff/0-commit guard). Does
  # <branch-ref> introduce a real change vs its merge-base with
  # <target-ref>? Diff is authoritative — commit-count alone is a weaker
  # proxy because a branch can carry commits that net-zero — so we use
  # `git diff --quiet` and ALSO require >=1 commit beyond the base.
  #   exit 0 = real change (safe to merge / open PR)
  #   exit 1 = empty: no diff, or no commits, vs base (REFUSE close-as-merged)
  #   exit 2 = base/diff could not be computed: merge-base failed OR `git diff`
  #           itself errored (exit >1). Fail closed — a tool error is a suspect,
  #           not a licence to merge — so the caller halts, never improvises.
  bhrc_target="$1"
  bhrc_branch="$2"
  bhrc_base=$(git merge-base "$bhrc_target" "$bhrc_branch" 2>/dev/null) || return 2
  git diff --quiet "$bhrc_base" "$bhrc_branch"
  case "$?" in
    0) return 1 ;;  # no diff -> empty -> refuse
    1) : ;;         # diff present -> fall through to the commit-count check
    *) return 2 ;;  # git diff errored -> suspect -> refuse (fail closed)
  esac
  [ "$(git rev-list --count "$bhrc_base..$bhrc_branch" 2>/dev/null || echo 0)" -ge 1 ] || return 1
  return 0
}

branch_already_landed() {
  # Rebase-aware already-merged predicate: has <branch-ref> already landed on
  # <target-ref>, judged by CONTENT rather than by reachability?
  #
  # Ancestor-ness is a SUFFICIENT condition for already-merged, never a
  # necessary one. This lane lands work by rebasing `temp` onto the target and
  # ff-merging, which REWRITES every commit — so after a successful merge
  # `origin/$BRANCH` is not an ancestor of `origin/$TARGET`; its pre-rebase sha
  # is nowhere on the target. The ancestor arm can therefore essentially never
  # fire here, which made a crash between `git push` and `gc bd close` fall
  # through to the 0-diff guard: the rebase correctly drops the already-applied
  # commit, the guard correctly sees 0 commits / 0 diff, and a genuinely merged
  # bead got halted to a human as a false completion (winnow-zgr2y.6, refiled
  # gcp-a4e7). Patch-id equality is the axis that survives the rewrite.
  #   exit 0 = every commit introduced since <fork-sha> is already upstream by
  #            patch-id -> already merged, safe to close
  #   exit 1 = NOT already merged. Either the branch still carries a commit the
  #            target does not have, or it introduced nothing of its own — the
  #            starved 0-commit polecat, and gcp-duy's branch that was merely
  #            rebased/reset onto newer target so its "commits since fork" are
  #            other beads'. Both belong to the false-completion guard.
  #   exit 2 = cannot evaluate: no fork_sha recorded, the fork commit is not in
  #            this repo, or a git invocation errored. Fail closed and let the
  #            false-completion guard decide, exactly as a missing fork_sha
  #            already does on the ancestor arm.
  bal_target="$1"
  bal_branch="$2"
  bal_fork="$3"
  [ -n "$bal_fork" ] || return 2
  git rev-parse --verify --quiet "$bal_fork^{commit}" >/dev/null 2>&1 || return 2
  # The branch must have introduced something OF ITS OWN since the fork point.
  # Both halves are load-bearing: a non-empty diff against the fork rules out
  # the starved 0-commit polecat, and requiring commits the target does not
  # already contain rules out the rebased zero-change branch whose counted
  # commits arrived via the rebase (gcp-duy's false positive — do not let this
  # arm reintroduce it on the content axis).
  git diff --quiet "$bal_fork" "$bal_branch" 2>/dev/null
  case "$?" in
    0) return 1 ;;  # nothing since the fork -> nothing of its own was merged
    1) : ;;         # real change since the fork -> keep checking
    *) return 2 ;;  # git diff errored -> suspect -> fail closed
  esac
  [ "$(git rev-list --count "$bal_branch" --not "$bal_target" 2>/dev/null || echo 0)" -ge 1 ] || return 1
  # `git cherry <target> <branch> <fork>` marks each commit since the fork '-'
  # when an equivalent patch is already upstream and '+' when it is not. All
  # '-' with no '+' is the rebasing rig's already-merged fingerprint.
  bal_cherry=$(git cherry "$bal_target" "$bal_branch" "$bal_fork" 2>/dev/null) || return 2
  [ -n "$bal_cherry" ] || return 1
  printf '%s
' "$bal_cherry" | grep -q '^+' && return 1
  return 0
}

upstream_equivalent_sha() {
  # Name the commit ON <target-ref> that carries <branch-ref>'s work, so a
  # rebase-aware close writes a `merged_sha` that is actually reachable from
  # the target — the field's whole purpose as the breadcrumb tying a closed
  # bead to its merge commit. The pre-rebase branch tip is NOT on the target
  # after a rewrite, so it cannot serve here.
  #
  # Scans the bounded range merge-base(target, branch)..target, which on a
  # crash-after-push is the merge that just landed plus whatever raced it.
  #   stdout = the matching target commit; exit 0
  #   exit 1 = no match in the scanned range; the caller falls back rather than
  #            inventing a sha.
  ues_target="$1"
  ues_branch="$2"
  ues_id=$(git show "$ues_branch" 2>/dev/null | git patch-id --stable 2>/dev/null | cut -d' ' -f1)
  [ -n "$ues_id" ] || return 1
  ues_base=$(git merge-base "$ues_target" "$ues_branch" 2>/dev/null) || return 1
  for ues_commit in $(git rev-list --max-count=500 "$ues_base..$ues_target" 2>/dev/null); do
    if [ "$(git show "$ues_commit" 2>/dev/null | git patch-id --stable 2>/dev/null | cut -d' ' -f1)" = "$ues_id" ]; then
      printf '%s
' "$ues_commit"
      return 0
    fi
  done
  return 1
}

halt_false_completion() {
  # branch_has_real_change tripped: a close-as-merged would assert "work was
  # merged" for a branch that merges to a no-op, which is definitionally
  # false. Halt-and-escalate (NEVER silent retry): leave the bead blocked
  # with a structured note, hand to human, nudge mayor + witness, then stop.
  # This surfaces the transient cause (e.g. session starvation -> 0-commit
  # polecat) instead of masking it.
  fc_branch="$1"
  fc_base="$2"
  gc bd update $WORK --status=blocked --assignee="" --set-metadata merge_result=refused_false_completion --set-metadata gc.routed_to=human --set-metadata false_completion_suspected="branch $fc_branch no verified change vs $fc_base; refused merge-close"
  gc session nudge mayor "FALSE-COMPLETION HALT: $WORK — branch $fc_branch no verified change vs $fc_base; refused close-as-merged. Bead left blocked; NEVER silent retry."
  gc session nudge "${GC_RIG:+$GC_RIG/}${CFG_BINDING_PREFIX}witness" "FALSE-COMPLETION HALT: $WORK — branch $fc_branch no verified change vs $fc_base; refused close-as-merged."
  echo "REFUSED close-as-merged: $WORK branch $fc_branch introduces no real change vs $fc_base."
  echo "STOP. Bead left blocked + escalated to mayor/witness. NEVER silent retry."
  return 8
}

close_already_merged() {
  # Shared already-merged close, used by BOTH arms of the merge-state gate (the
  # ancestor short-circuit and the rebase-aware content check) so the two can
  # never drift on what a merged close records.
  #   $1 = merged_sha — a commit on $TARGET that carries this bead's work
  #   $2 = already_merged_via — how it was established: ancestor | rebase_patch_id
  #   $3 = human-readable evidence for the close reason and the log line
  # Both the metadata write and the close must land. A partial write would
  # report merged with the bead still open, so on failure this STOPS and a
  # later patrol retries instead.
  cam_sha="$1"
  cam_via="$2"
  cam_evidence="$3"
  cam_short=$(git rev-parse --short "$cam_sha" 2>/dev/null || printf '%s' "$cam_sha")
  if gc bd update "$WORK" --set-metadata merge_result=already_merged --set-metadata merged_sha="$cam_sha" --set-metadata merged_target="$TARGET" --set-metadata already_merged_via="$cam_via" --set-metadata merged_source_sha="$(git rev-parse "origin/$BRANCH" 2>/dev/null || printf '%s' unknown)" --unset-metadata rejection_reason && gc bd close "$WORK" --reason "Already merged to $TARGET at $cam_short ($cam_evidence; closed instead of halting)"; then
    echo "ALREADY_MERGED: $cam_evidence — closed $WORK as merged at $cam_short. Skip the merge script; run Cleanup, then patrol-summary + next-iteration."
    return 0
  fi
  # The update/close did not land (transient API failure). Do NOT report
  # merged with the bead still open; STOP so a later patrol retries.
  echo "ALREADY_MERGED close failed for $WORK; bead still open. STOP; a later patrol will retry."
  return 2
}
# --- GitHub helpers ---------------------------------------------------------

pr_lookup_missing() {
  case "$1" in
    *"Could not resolve to a PullRequest"*|*"could not resolve to a PullRequest"*|*"no pull requests found"*|*"Not Found"*|*"not found"*|*"404"*) return 0 ;;
    *) return 1 ;;
  esac
}

pr_lookup_repo_mismatch() {
  case "$1" in
    *" belongs to repo "*", want "*) return 0 ;;
    *) return 1 ;;
  esac
}

resolve_github_token() {
  TOKEN="${GH_TOKEN:-${GITHUB_TOKEN:-${GIT_TOKEN:-}}}"
  if [ -n "$TOKEN" ]; then
    printf '%s
' "$TOKEN"
    return
  fi
  printf 'protocol=https
host=github.com

' | GIT_TERMINAL_PROMPT=0 git credential fill 2>/dev/null | sed -n 's/^password=//p' | head -n 1
}

init_github_rest() {
  if [ -n "${API:-}" ] && [ -n "${TOKEN:-}" ]; then
    return 0
  fi
  if [ -n "$ORIGIN_REPO_ERROR" ]; then
    echo "$ORIGIN_REPO_ERROR" >&2
    return 1
  fi
  TOKEN=$(resolve_github_token)
  if [ -z "$TOKEN" ]; then
    echo "GitHub PR mode requires gh or a GitHub token available from env/git credential fill." >&2
    return 1
  fi
  case "$ORIGIN_REPO" in
    */*)
      OWNER=${ORIGIN_REPO%%/*}
      REPO=${ORIGIN_REPO#*/}
      ;;
    *)
      echo "Could not resolve standard github.com origin repository for REST fallback." >&2
      return 1
      ;;
  esac
  API="https://api.github.com/repos/$OWNER/$REPO"
}

curl_gh_api() {
  err_file="$1"
  shift
  curl -fsS -H "Accept: application/vnd.github+json" -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" -H "X-GitHub-Api-Version: 2022-11-28" "$@" 2>"$err_file"
}

lookup_pr_info() {
  ref="$1"
  err_file="$2"
  # An unscoped lookup is what let this lane read the wrong repository in the
  # first place. Without a resolved origin there is nothing safe to scope to,
  # so refuse rather than fall back to gh's base-repo guess.
  if [ -z "$ORIGIN_REPO" ]; then
    {
      [ -n "$ORIGIN_REPO_ERROR" ] && echo "$ORIGIN_REPO_ERROR"
      echo "Could not resolve the origin repository; refusing an unscoped pull request lookup for $ref."
    } >"$err_file"
    return 1
  fi
  if command -v "$GH" >/dev/null 2>&1; then
    "$GH" pr view --repo "$ORIGIN_REPO" --json url,number,state,headRefName,baseRefName,headRepositoryOwner,headRepository -- "$ref" 2>"$err_file"
    return $?
  fi
  if ! init_github_rest 2>"$err_file"; then
    return 1
  fi
  PR_REF_REPO=$(printf '%s
' "$ref" | sed -nE 's#^[Hh][Tt][Tt][Pp][Ss]://github.com/([^/]+/[^/]+)/pull/[0-9]+/?$#\1#p' | head -n 1)
  if [ -n "$PR_REF_REPO" ] && [ "$PR_REF_REPO" != "$ORIGIN_REPO" ]; then
    echo "Pull request $ref belongs to repo $PR_REF_REPO, want $ORIGIN_REPO." >"$err_file"
    return 1
  fi
  PR_NUMBER=$(printf '%s
' "$ref" | sed -nE 's#^[Hh][Tt][Tt][Pp][Ss]://github.com/[^/]+/[^/]+/pull/([0-9]+)/?$#\1#p; s|^#([0-9]+)$|\1|p; s|^([0-9]+)$|\1|p' | head -n 1)
  if [ -z "$PR_NUMBER" ]; then
    PR_MATCHES=$(curl_gh_api "$err_file" --get "$API/pulls" --data-urlencode "state=open" --data-urlencode "head=$OWNER:$ref" --data-urlencode "base=$TARGET") || return 1
    PR_NUMBER=$(printf '%s
' "$PR_MATCHES" | jq -r '.[0].number // empty')
  fi
  if [ -z "$PR_NUMBER" ]; then
    echo "Pull request $ref was not found." >"$err_file"
    return 1
  fi
  PR_RAW=$(curl_gh_api "$err_file" "$API/pulls/$PR_NUMBER") || return 1
  printf '%s
' "$PR_RAW" | jq '{url:.html_url, number, state:(.state | ascii_upcase), headRefName:.head.ref, baseRefName:.base.ref, headRepositoryOwner:{login:.head.repo.owner.login}, headRepository:{name:.head.repo.name}}'
}

# --- merge_ff_push ----------------------------------------------------------

# Land `temp` on $TARGET and prove it landed. Reads BRANCH, TARGET,
# APPROVAL_REQUIRED; sets TEMP_SHA, MERGED_SHA, MERGED_SHORT on success.
#
# Exit status:
#   0 = landed and verified (MERGED_SHA is $TEMP_SHA, reachable on the target)
#   2 = hard stop; do not mutate bead state
#   3 = the re-rebase onto the new tip conflicted
#   4 = approval-gated and the branch must move; park awaiting review
#   5 = no-op: origin/$TARGET already contains temp; nothing to land here
#   6 = retries exhausted while losing the race (measured: the target moved
#       under every attempt)
#   7 = the remote REFUSED the push while $TARGET stood still — a push-gate
#       veto, a receive hook, or permissions. Not a race; retrying cannot help.
merge_ff_push_cleanup_wt() {
  if [ -n "${mfp_wt:-}" ]; then
    git worktree remove --force "$mfp_wt" >/dev/null 2>&1 || true
  fi
  if [ -n "${mfp_parent:-}" ]; then
    rmdir "$mfp_parent" 2>/dev/null || echo "WARN left temp dir $mfp_parent: git worktree remove did not empty it."
  fi
  mfp_wt=""
  mfp_parent=""
}

merge_ff_push() {
  mfp_wt=""
  mfp_parent=""
  mfp_max=3
  mfp_attempt=0
  # Wait budget for the merge push, and for nothing else in this patrol. The
  # rig's pre-push gate (scripts/gate-slot-run) reads PUSH_GATE_MAX_WAIT_SECONDS
  # and defaults it to 0 — a NON-BLOCKING slot acquire that vetoes the push
  # outright whenever the lane is busy. The refinery IS a queue: waiting for a
  # slot is what it is for, and a measured 28.2-minute queue (gc-wisp-wt5u) is
  # cheaper than a refused merge. Overridable per rig, exported per push.
  # A budget long enough to outlive the remote's idle timeout is a DIFFERENT
  # failure — the push dies mid-flight rather than being refused — so if raising
  # this starts producing torn pushes instead of merges, that interaction is
  # what to look at, not the refusal status below.
  mfp_push_wait="${REFINERY_PUSH_GATE_MAX_WAIT_SECONDS:-3000}"

  while [ "$mfp_attempt" -lt "$mfp_max" ]; do
    mfp_attempt=$((mfp_attempt + 1))

    if ! git fetch origin "+refs/heads/${TARGET}:refs/remotes/origin/${TARGET}"; then
      echo "merge-ff-push: fetch of $TARGET failed on attempt $mfp_attempt; cannot establish the pre-merge tip."
      return 2
    fi
    # BEFORE_SHA is resolved once and then used as the worktree base, so the
    # advance check below compares against the commit the merge was really
    # performed on rather than re-reading a ref that may have moved since.
    if ! BEFORE_SHA=$(git rev-parse "origin/$TARGET"); then
      echo "merge-ff-push: could not resolve origin/$TARGET."
      return 2
    fi
    if ! TEMP_SHA=$(git rev-parse temp); then
      echo "merge-ff-push: could not resolve the rebased temp branch."
      return 2
    fi

    if ! mfp_parent=$(mktemp -d "${TMPDIR:-/tmp}/gascity-refinery-merge.XXXXXX"); then
      echo "merge-ff-push: could not create a scratch directory for the merge worktree."
      return 2
    fi
    mfp_wt="$mfp_parent/target"
    if ! git worktree add --detach "$mfp_wt" "$BEFORE_SHA" >/dev/null 2>&1; then
      echo "merge-ff-push: could not create the merge worktree at $BEFORE_SHA."
      merge_ff_push_cleanup_wt
      return 2
    fi

    # Explicit status check. Do NOT reintroduce a `set -e` dependency here:
    # this is the branch that reported a false merge when set -e did not
    # propagate through the execution harness.
    git -C "$mfp_wt" merge --ff-only "$TEMP_SHA"
    mfp_merge_status=$?
    if [ "$mfp_merge_status" -ne 0 ]; then
      merge_ff_push_cleanup_wt
      echo "merge-ff-push: ff-merge of $TEMP_SHA onto $BEFORE_SHA failed (status $mfp_merge_status) — origin/$TARGET moved under this patrol."
      if [ "${APPROVAL_REQUIRED:-0}" -eq 1 ]; then
        echo "merge-ff-push: approval is keyed to the current head; refusing to re-rebase it. Park for review."
        return 4
      fi
      if [ "$mfp_attempt" -ge "$mfp_max" ]; then
        break
      fi
      if ! git checkout temp >/dev/null 2>&1; then
        echo "merge-ff-push: could not check out temp to re-rebase it."
        return 2
      fi
      if ! git rebase "$BEFORE_SHA"; then
        git rebase --abort >/dev/null 2>&1 || true
        echo "merge-ff-push: re-rebase of temp onto $BEFORE_SHA conflicted; aborted. STOP — a later patrol re-runs the rebase step, which rejects the branch back to the pool."
        return 3
      fi
      echo "merge-ff-push: re-rebased temp onto $BEFORE_SHA; retrying (attempt $mfp_attempt of $mfp_max used)."
      continue
    fi

    MERGED_SHA=$(git -C "$mfp_wt" rev-parse HEAD)
    MERGED_SHORT=$(git -C "$mfp_wt" rev-parse --short HEAD)

    # An "Already up to date" ff-merge leaves HEAD at the target tip. Reporting
    # that as merged is precisely the target-tip-for-branch-tip mislabel; the
    # already-merged gate resolves this case from origin/$BRANCH instead.
    if [ "$MERGED_SHA" = "$BEFORE_SHA" ]; then
      merge_ff_push_cleanup_wt
      echo "merge-ff-push: ff-merge was a no-op — origin/$TARGET ($BEFORE_SHA) already contains temp. Nothing to land; not recording a merge."
      return 5
    fi
    # ff-only either fast-forwards HEAD to TEMP_SHA or leaves it alone, so this
    # cannot fire. Asserted anyway: it is the invariant that keeps merged_sha
    # the commit that carried the bead.
    if [ "$MERGED_SHA" != "$TEMP_SHA" ]; then
      merge_ff_push_cleanup_wt
      echo "merge-ff-push: ff-merge left HEAD at $MERGED_SHA, not the branch tip $TEMP_SHA. Refusing to record a merge."
      return 2
    fi

    PUSH_GATE_MAX_WAIT_SECONDS="$mfp_push_wait" git -C "$mfp_wt" push origin "HEAD:$TARGET"
    mfp_push_status=$?
    merge_ff_push_cleanup_wt
    if [ "$mfp_push_status" -ne 0 ]; then
      # MEASURE the cause; do not assert it. A rejection is either "the target
      # advanced under us" — retryable, re-rebase and go again — or "the remote
      # refused this push" (gate veto, receive hook, permissions), which no
      # number of retries can fix and which every retry pays for in gate load:
      # each attempt relaunches the pre-push hook and queues for another slot.
      # The verification below already draws exactly this comparison against the
      # freshly fetched tip; the rejection path never learned it, so every veto
      # was reported as movement and then retried three times (gcp-ileo).
      if ! git fetch origin "+refs/heads/${TARGET}:refs/remotes/origin/${TARGET}"; then
        echo "merge-ff-push: push to $TARGET was rejected (status $mfp_push_status) and the follow-up fetch failed, so the cause cannot be measured. STOP. Do not mutate bead state."
        return 2
      fi
      if ! mfp_reject_sha=$(git rev-parse "origin/$TARGET"); then
        echo "merge-ff-push: push to $TARGET was rejected (status $mfp_push_status) and origin/$TARGET could not be resolved, so the cause cannot be measured. STOP. Do not mutate bead state."
        return 2
      fi
      if [ "$mfp_reject_sha" = "$BEFORE_SHA" ]; then
        echo "merge-ff-push: push to $TARGET was rejected (status $mfp_push_status) and origin/$TARGET is STILL $BEFORE_SHA — the target did not move, so the remote refused this push (push-gate veto, receive hook, or permissions). This is not a race; retrying re-runs the pre-push gate and cannot succeed. STOP. Do not mutate bead state."
        return 7
      fi
      echo "merge-ff-push: push to $TARGET was rejected (status $mfp_push_status); origin/$TARGET moved $BEFORE_SHA -> $mfp_reject_sha, so the target really did advance between the fetch and the push."
      if [ "${APPROVAL_REQUIRED:-0}" -eq 1 ]; then
        echo "merge-ff-push: approval is keyed to the current head; refusing to re-rebase it. Park for review."
        return 4
      fi
      if [ "$mfp_attempt" -ge "$mfp_max" ]; then
        break
      fi
      continue
    fi

    # Re-fetch and verify against the FRESH tip. The pre-push snapshot proves
    # nothing: a no-op push also exits 0.
    if ! git fetch origin "+refs/heads/${TARGET}:refs/remotes/origin/${TARGET}"; then
      echo "merge-ff-push: post-push fetch of $TARGET failed; the merge cannot be verified. STOP. Do not mutate bead state."
      return 2
    fi
    if ! AFTER_SHA=$(git rev-parse "origin/$TARGET"); then
      echo "merge-ff-push: could not resolve origin/$TARGET after the push; the merge cannot be verified."
      return 2
    fi
    if [ "$AFTER_SHA" = "$BEFORE_SHA" ]; then
      echo "merge-ff-push: origin/$TARGET did not advance — still $BEFORE_SHA after a push that exited 0. STOP. Do not mutate bead state."
      return 2
    fi
    if ! git merge-base --is-ancestor "$TEMP_SHA" "$AFTER_SHA"; then
      echo "merge-ff-push: origin/$TARGET advanced to $AFTER_SHA but $TEMP_SHA is not reachable from it — the target moved for some other reason. STOP. Do not mutate bead state."
      return 2
    fi

    echo "merge-ff-push: landed $BRANCH on $TARGET at $MERGED_SHA (target advanced $BEFORE_SHA -> $AFTER_SHA)."
    return 0
  done

  # Only reachable after an attempt MEASURED the target moving — either the
  # ff-merge failed because origin/$TARGET had advanced, or the push was
  # rejected and the re-read tip differed from the one merged onto. A veto
  # against a stationary target returns 7 above and never reaches here, so this
  # message no longer steers the reader toward retrying harder (gcp-ileo).
  echo "merge-ff-push: could not land $BRANCH on $TARGET in $mfp_max attempts; the target moved under every attempt. STOP. Do not mutate bead state."
  return 6
}
# --- lanes ------------------------------------------------------------------
#
# The lane bodies below are the step's blocks at the column they were written
# at. They are not re-indented because several hold multi-line strings (mail
# bodies, printf formats) whose content indentation would change.

# "1. Merge, push, verify, and close work bead": land `temp` and close the
# bead. Shared by the direct lane and 4b (approved). Cleanup is the caller's.
direct_close() {
merge_ff_push
MERGE_LAND_STATUS=$?
case "$MERGE_LAND_STATUS" in
  0)
    if gc bd update "$WORK" --set-metadata merge_result=merged --set-metadata merged_sha="$MERGED_SHA" --set-metadata merged_target="$TARGET" --unset-metadata rejection_reason && gc bd close "$WORK" --reason "Merged to $TARGET at $MERGED_SHORT"; then
      MP_SUMMARY="merged to $TARGET at $MERGED_SHORT"
      return 0
    fi
    echo "merge-ff-push landed $BRANCH on $TARGET at $MERGED_SHORT, but recording the merge on $WORK failed; the bead is still open. STOP. The next patrol's merge-state gate closes it as already merged."
    return 2
    ;;
  4)
    park_awaiting_review "the approved head no longer fast-forwards $TARGET; the branch must be re-rebased and re-reviewed before it can land"
    return 4
    ;;
  *)
    echo "merge-ff-push did not land $BRANCH on $TARGET (status $MERGE_LAND_STATUS). STOP. Do not mutate bead state."
    return "$MERGE_LAND_STATUS"
    ;;
esac
}

# Both lanes' cleanup of `temp`: step off it onto the target's tip and delete it.
# The checkout DETACHES onto origin/$TARGET rather than checking out $TARGET,
# because git refuses to check a branch out while another worktree has it, and
# the target is routinely checked out in the rig's main worktree. The mr lane
# used a plain `git checkout "$TARGET"` until gcp-l8td.6, and failed exactly
# there: HEAD stayed on `temp`, which then could not be deleted either.
cleanup_temp() {
git checkout --detach "origin/$TARGET" >/dev/null 2>&1 || true
git branch -d temp || git branch -D temp || true
}

# The direct lane's "2. Cleanup", including the branch delete the step gave in
# prose: If delete_merged_branches = "true": `git push origin --delete $BRANCH`
direct_cleanup() {
cleanup_temp
if [ "$CFG_DELETE_MERGED_BRANCHES" = "true" ]; then
  git push origin --delete "$BRANCH"
fi
}

# The already-merged close is a real completion: skip the merge and run
# 2. Cleanup, the tail the step's prose gives it. $1 is close_already_merged's
# status: 0 closed, 2 could not close.
after_already_merged_close() {
  if [ "$1" -eq 0 ]; then
    MP_SUMMARY="closed as already merged to $TARGET"
    direct_cleanup
  fi
  return "$1"
}

# resolve_origin_repo — set ORIGIN_REPO to the repository this clone pushes to,
# or leave it empty with ORIGIN_REPO_ERROR saying why.
resolve_origin_repo() {
# The repository that matters here is the one this worktree PUSHES to: origin.
# `gh repo view` answers with gh's own base-repo heuristic, which on a fork that
# also carries an `upstream` remote resolves to the PARENT — so a fork-based rig
# would create and look up its pull requests in a repo its branches were never
# pushed to (gastownhall/gascity-packs#... — the mr lane could not see PR #1 on
# the fork). Parse origin directly; gh is a fallback only for remotes this
# parser cannot read (GitHub Enterprise hosts, ssh config aliases).
ORIGIN_REPO=""
ORIGIN_REPO_ERROR=""
ORIGIN_URL=$(git remote get-url origin 2>/dev/null || true)
case "$ORIGIN_URL" in
  git@github.com:*|https://github.com/*|ssh://git@github.com/*)
    ORIGIN_REPO=$(printf '%s
' "$ORIGIN_URL" | sed -E 's#^ssh://git@github.com/##; s#^git@github.com:##; s#^https://github.com/##; s#\.git$##')
    ;;
esac
if [ -z "$ORIGIN_REPO" ]; then
  if command -v "$GH" >/dev/null 2>&1; then
    if ! ORIGIN_REPO=$("$GH" repo view --json nameWithOwner -q '.nameWithOwner' 2>&1); then
      ORIGIN_REPO_ERROR="gh repo view failed while resolving origin repository: $ORIGIN_REPO"
      ORIGIN_REPO=""
    fi
  elif [ -z "$ORIGIN_URL" ]; then
    ORIGIN_REPO_ERROR="Could not read the origin remote (git remote get-url origin failed); cannot resolve the repository for pull-request handoff."
  else
    ORIGIN_REPO_ERROR="GitHub REST fallback supports only github.com origin remotes; install gh for $ORIGIN_URL."
  fi
fi
}

# MERGE_STRATEGY = direct: "0. Merge-state gate", then the merge, then cleanup.
lane_direct() {
FORK_SHA=$(gc bd show "$WORK" --json | jq -r '.[0].metadata.fork_sha // empty')
if ! git fetch origin "+refs/heads/${BRANCH}:refs/remotes/origin/${BRANCH}" "+refs/heads/${TARGET}:refs/remotes/origin/${TARGET}"; then
  echo "git fetch failed; cannot evaluate merge state. STOP. Do not mutate bead state."
  return 2
fi
git merge-base --is-ancestor "origin/$BRANCH" "origin/$TARGET"
ANCESTOR_STATUS=$?
case "$ANCESTOR_STATUS" in
  0)
    REAL_COMMITS=0
    if [ -n "$FORK_SHA" ]; then
      REAL_COMMITS=$(git rev-list --count "$FORK_SHA..origin/$BRANCH" 2>/dev/null || echo 0)
    fi
    if [ -n "$FORK_SHA" ] && [ "$REAL_COMMITS" -ge 1 ]; then
      close_already_merged "$(git rev-parse "origin/$BRANCH")" ancestor "origin/$BRANCH is an ancestor of origin/$TARGET with $REAL_COMMITS commit(s) since fork"
      after_already_merged_close $?
      return $?
    fi
    # Ancestor but no recorded real commits: a 0-commit branch. Fall through to
    # the false-completion guard, which refuses to close it as merged.
    ;;
  1) : ;;  # not an ancestor -> a normal merge candidate; fall through
  *)
    echo "git merge-base --is-ancestor errored (status $ANCESTOR_STATUS); cannot evaluate already-merged. STOP. Do not mutate bead state."
    return 2
    ;;
esac

branch_has_real_change "origin/$TARGET" temp
BHRC_STATUS=$?
case "$BHRC_STATUS" in
  0) : ;;  # verified real change -> continue to the merge script below
  1)
    # The rebase collapsed `temp` to nothing. Two opposite states look
    # identical from here, and the branch's own fork point is what separates
    # them: work that already landed (the rebase reports its commits as
    # previously applied) versus a polecat that produced nothing. Ask the
    # content-based predicate before halting — on this rebasing lane the
    # ancestor arm above cannot fire, so this is the ONLY arm that can catch a
    # crash between `git push` and `gc bd close`.
    branch_already_landed "origin/$TARGET" "origin/$BRANCH" "$FORK_SHA"
    BAL_STATUS=$?
    if [ "$BAL_STATUS" -eq 0 ]; then
      # merged_sha must name a commit ON the target; the pre-rebase branch tip
      # is not one after the rewrite. Fall back to the verified target tip only
      # if the carrying commit cannot be localized — never to the branch tip.
      ALREADY_SHA=$(upstream_equivalent_sha "origin/$TARGET" "origin/$BRANCH") ||
        ALREADY_SHA=$(git rev-parse "origin/$TARGET")
      close_already_merged "$ALREADY_SHA" rebase_patch_id "every commit on origin/$BRANCH since $FORK_SHA is already upstream in origin/$TARGET by patch-id, and its rebase is empty"
      after_already_merged_close $?
      return $?
    fi
    # Not already landed (status 1), or not evaluable (status 2): a branch that
    # merges to a no-op and has no evidence of having landed is a false
    # completion. Halt.
    halt_false_completion "$BRANCH" "$(git merge-base "origin/$TARGET" temp 2>/dev/null || printf '%s' "origin/$TARGET")"
    return $?
    ;;
  *)
    echo "branch_has_real_change could not evaluate temp vs origin/$TARGET (tool error, status $BHRC_STATUS). STOP. Do not mutate bead state."
    return 2
    ;;
esac
direct_close
LAND_STATUS=$?
case "$LAND_STATUS" in
  0|4) direct_cleanup ;;
esac
return "$LAND_STATUS"
}

# MERGE_STRATEGY = mr: refuse a 0-diff branch, push it, publish and verify the
# pull request, record it, then hand off (4a) or gate the merge (4b).
lane_mr() {
branch_has_real_change "origin/$TARGET" temp
BHRC_STATUS=$?
case "$BHRC_STATUS" in
  0) : ;;  # verified real change -> continue to publish the PR
  1)
    halt_false_completion "$BRANCH" "$(git merge-base "origin/$TARGET" temp 2>/dev/null || printf '%s' "origin/$TARGET")"
    return $?
    ;;
  *)
    echo "branch_has_real_change could not evaluate temp vs origin/$TARGET (tool error, status $BHRC_STATUS). STOP. Do not mutate bead state."
    return 2
    ;;
esac
git checkout temp
if ! git push origin HEAD:$BRANCH --force-with-lease; then
  echo "git push --force-with-lease of $BRANCH failed: the existing PR branch moved after your fetch. STOP, fetch the latest branch, rebase your temp branch again, and retry with --force-with-lease. Do not use plain --force."
  return 2
fi
WORK_JSON=$(gc bd show $WORK --json)
EXISTING_PR=$(printf '%s' "$WORK_JSON" | jq -r '.[0].metadata.existing_pr // empty')
ISSUE_TITLE=$(printf '%s' "$WORK_JSON" | jq -r '.[0].title')
ISSUE_DESC=$(printf '%s' "$WORK_JSON" | jq -r '.[0].description // empty')
ISSUE_NOTES=$(printf '%s' "$WORK_JSON" | jq -r '.[0].notes // empty')
ISSUE_TYPE=$(printf '%s' "$WORK_JSON" | jq -r '.[0].issue_type // "task"')
ISSUE_PRIORITY=$(printf '%s' "$WORK_JSON" | jq -r '.[0].priority // empty')

PR_BODY_FILE=$(mktemp)
{
  echo "## Summary"
  echo
  if [ -n "$ISSUE_DESC" ]; then
    printf '%s
' "$ISSUE_DESC"
  else
    printf 'Refinery handoff for `%s` (no bead description recorded).
' "$WORK"
  fi
  if [ -n "$ISSUE_NOTES" ]; then
    echo
    echo "## Implementation notes"
    echo
    printf '%s
' "$ISSUE_NOTES"
  fi
  echo
  echo "## Refinery handoff"
  echo
  printf -- '- Issue: `%s` (%s%s)
' "$WORK" "$ISSUE_TYPE" "${ISSUE_PRIORITY:+, P$ISSUE_PRIORITY}"
  printf -- '- Source branch: `%s`
' "$BRANCH"
  printf -- '- Target: `%s`
' "$TARGET"
  printf -- '- Rebased on `%s` via Gastown Refinery.
' "$TARGET"
} > "$PR_BODY_FILE"

if [ -n "$EXISTING_PR" ]; then
  PR_REF="$EXISTING_PR"
else
  if command -v "$GH" >/dev/null 2>&1; then
    PR_URL=$("$GH" pr create --repo "$ORIGIN_REPO" --base "$TARGET" --head "$BRANCH" --title "$ISSUE_TITLE ($WORK)" --body-file "$PR_BODY_FILE" 2>/dev/null || true)

    if [ -z "$PR_URL" ]; then
      PR_URL=$("$GH" pr view "$BRANCH" --repo "$ORIGIN_REPO" --json url -q '.url')
    fi
  else
    PR_ERR=$(mktemp)
    if ! init_github_rest 2>"$PR_ERR"; then
      cat "$PR_ERR"
      rm -f "$PR_ERR"
      return 2
    fi
    EXISTING=$(curl_gh_api "$PR_ERR" --get "$API/pulls" --data-urlencode "state=open" --data-urlencode "head=$OWNER:$BRANCH" --data-urlencode "base=$TARGET")
    PR_STATUS=$?
    PR_ERROR=$(cat "$PR_ERR")
    if [ "$PR_STATUS" -ne 0 ]; then
      echo "GitHub API request failed while checking for an existing PR for $BRANCH."
      [ -n "$PR_ERROR" ] && echo "$PR_ERROR"
      rm -f "$PR_ERR"
      return 2
    fi
    PR_NUMBER=$(printf '%s
' "$EXISTING" | jq -r '.[0].number // empty')
    if [ -z "$PR_NUMBER" ]; then
      CREATE_PAYLOAD=$(jq -n --arg title "$ISSUE_TITLE ($WORK)" --arg head "$BRANCH" --arg base "$TARGET" --rawfile body "$PR_BODY_FILE" '{title:$title, head:$head, base:$base, body:$body}')
      CREATED=$(curl_gh_api "$PR_ERR" -X POST "$API/pulls" -d "$CREATE_PAYLOAD")
      PR_STATUS=$?
      PR_ERROR=$(cat "$PR_ERR")
      if [ "$PR_STATUS" -ne 0 ]; then
        echo "GitHub API request failed while creating a PR for $BRANCH."
        [ -n "$PR_ERROR" ] && echo "$PR_ERROR"
        rm -f "$PR_ERR"
        return 2
      fi
      PR_NUMBER=$(printf '%s
' "$CREATED" | jq -r '.number // empty')
      if [ -z "$PR_NUMBER" ]; then
        echo "GitHub API response did not include a pull request number."
        rm -f "$PR_ERR"
        return 2
      fi
    fi
    PR_RAW=$(curl_gh_api "$PR_ERR" "$API/pulls/$PR_NUMBER")
    PR_STATUS=$?
    PR_ERROR=$(cat "$PR_ERR")
    rm -f "$PR_ERR"
    if [ "$PR_STATUS" -ne 0 ]; then
      echo "GitHub API request failed while reading PR $PR_NUMBER."
      [ -n "$PR_ERROR" ] && echo "$PR_ERROR"
      return 2
    fi
    PR_URL=$(printf '%s
' "$PR_RAW" | jq -r '.html_url // empty')
  fi
  PR_REF="$BRANCH"
fi

rm -f "$PR_BODY_FILE"
PR_ERR=$(mktemp)
PR_INFO=$(lookup_pr_info "$PR_REF" "$PR_ERR")
PR_STATUS=$?
PR_ERROR=$(cat "$PR_ERR")
rm -f "$PR_ERR"
if [ "$PR_STATUS" -ne 0 ] || [ -z "$PR_INFO" ]; then
  if [ -n "$EXISTING_PR" ] && pr_lookup_missing "$PR_ERROR"; then
    block_existing_pr "Existing PR $EXISTING_PR was not found or is not accessible."
    return $?
  fi
  echo "Pull request $PR_REF was not found."
  [ -n "$PR_ERROR" ] && echo "$PR_ERROR"
  return 2
fi
PR_URL=$(printf '%s
' "$PR_INFO" | jq -r '.url')
PR_NUMBER=$(printf '%s
' "$PR_INFO" | jq -r '.number')
PR_STATE=$(printf '%s
' "$PR_INFO" | jq -r '.state')
PR_HEAD=$(printf '%s
' "$PR_INFO" | jq -r '.headRefName')
PR_BASE=$(printf '%s
' "$PR_INFO" | jq -r '.baseRefName')
PR_REPO=$(printf '%s
' "$PR_URL" | sed -E 's#^https://github.com/([^/]+/[^/]+)/pull/[0-9]+$#\1#')
PR_HEAD_REPO=$(printf '%s
' "$PR_INFO" | jq -r '.headRepositoryOwner.login + "/" + .headRepository.name')
echo "$PR_URL $PR_NUMBER $PR_STATE $PR_HEAD $PR_BASE $PR_REPO $PR_HEAD_REPO"
if [ "$PR_STATE" != "OPEN" ]; then
  if [ -n "$EXISTING_PR" ]; then
    block_existing_pr "Existing PR $EXISTING_PR is $PR_STATE, want OPEN."
    return $?
  fi
  echo "Pull request $PR_REF is $PR_STATE, want OPEN."
  return 2
fi
if [ "$PR_HEAD" != "$BRANCH" ]; then
  if [ -n "$EXISTING_PR" ]; then
    block_existing_pr "Existing PR $EXISTING_PR targets branch $PR_HEAD, want $BRANCH."
    return $?
  fi
  echo "Pull request $PR_REF targets branch $PR_HEAD, want $BRANCH."
  return 2
fi
if [ "$PR_BASE" != "$TARGET" ]; then
  if [ -n "$EXISTING_PR" ]; then
    block_existing_pr "Existing PR $EXISTING_PR targets base $PR_BASE, want $TARGET."
    return $?
  fi
  echo "Pull request $PR_REF targets base $PR_BASE, want $TARGET."
  return 2
fi
if [ "$PR_REPO" != "$ORIGIN_REPO" ]; then
  if [ -n "$EXISTING_PR" ]; then
    block_existing_pr "Existing PR $EXISTING_PR belongs to repo $PR_REPO, want $ORIGIN_REPO."
    return $?
  fi
  echo "Pull request $PR_REF belongs to repo $PR_REPO, want $ORIGIN_REPO."
  return 2
fi
if [ "$PR_HEAD_REPO" != "$ORIGIN_REPO" ]; then
  if [ -n "$EXISTING_PR" ]; then
    block_existing_pr "Existing PR $EXISTING_PR head repo $PR_HEAD_REPO, want $ORIGIN_REPO."
    return $?
  fi
  echo "Pull request $PR_REF head repo $PR_HEAD_REPO, want $ORIGIN_REPO."
  return 2
fi
# The step's "If this command fails or prints empty output: STOP."
if [ -z "$PR_URL" ] || [ "$PR_URL" = null ] || [ -z "$PR_NUMBER" ] || [ "$PR_NUMBER" = null ]; then
  echo "Pull request $PR_REF verified without a URL or number. STOP. Debug and retry. Do NOT continue."
  return 2
fi

gc bd update $WORK --set-metadata pr_url="$PR_URL" --set-metadata pr_number="$PR_NUMBER" --set-metadata merged_target="$TARGET" --unset-metadata rejection_reason
if [ "$APPROVAL_REQUIRED" -eq 0 ]; then
  # 4a. Approval gate off: PR publication is the terminal handoff.
if gc bd update $WORK --set-metadata merge_result=pull_request && gc bd close $WORK --reason "Pull request ready: $PR_URL"; then
  MP_SUMMARY="pull request ready: $PR_URL"
else
  echo "Could not record the pull request handoff on $WORK; the bead is still open. STOP. Debug and retry."
  return 2
fi
  cleanup_temp
  return 0
fi

# 4b. Approval gate on: refused parks the bead; approved lands it with the
# direct path's merge.
APPROVAL_GATE_OUTPUT=$(run_approval_gate "$(git rev-parse temp)" 2>&1)
APPROVAL_GATE_STATUS=$?
echo "$APPROVAL_GATE_OUTPUT"
if [ "$APPROVAL_GATE_STATUS" -ne 0 ]; then
  park_awaiting_review "$APPROVAL_GATE_OUTPUT"
  cleanup_temp
  return 4
fi
gc bd update "$WORK" --set-metadata merge_approval_state=approved --unset-metadata merge_approval_gate_reason
direct_close
LAND_STATUS=$?
case "$LAND_STATUS" in
  0|4) cleanup_temp ;;
esac
return "$LAND_STATUS"
}

# MERGE_STRATEGY = local: unsupported. Escalate and leave everything as it is.
lane_local() {
gc mail send mayor/ -s "ESCALATION: unsupported merge_strategy=local" -m "Work bead: $WORK
Branch: $BRANCH
Target: $TARGET
The Gastown example refinery supports direct and mr/pr merge strategies only."
return 11
}

# resolve_merge_strategy <bead-id> — print the strategy the lane would run for
# the bead before the approval gate is considered: its metadata.merge_strategy
# (default direct), with pr read as mr, and an existing_pr forcing mr. The
# forcing notice goes to stderr so stdout is the strategy alone. merge-batch.sh
# calls this for each batch candidate, so a member is eligible by the lane's own
# rule and the two cannot drift (gcp-l8td.8).
resolve_merge_strategy() {
  rms_json=$(gc bd show "$1" --json) || return 1
  rms_strategy=$(printf '%s' "$rms_json" | jq -r '.[0].metadata.merge_strategy // "direct"')
  rms_existing_pr=$(printf '%s' "$rms_json" | jq -r '.[0].metadata.existing_pr // empty')
  if [ "$rms_strategy" = "pr" ]; then
    rms_strategy="mr"
  fi
  if [ -n "$rms_existing_pr" ] && [ "$rms_strategy" = "direct" ]; then
    echo "metadata.existing_pr requires pull-request handoff; using merge_strategy=mr." >&2
    rms_strategy="mr"
  fi
  printf '%s\n' "$rms_strategy"
}

# resolve_approval_required — set APPROVAL_REQUIRED (0 or 1) from
# CFG_REQUIRE_MERGE_APPROVAL. Approval gate opt-in: only the recognized off
# values disable it; anything unrecognized (a typo in the rig's formula_vars)
# turns it ON, because the failure mode of a mis-read switch must be "review
# required", never "review silently skipped".
resolve_approval_required() {
  case "$(printf '%s' "$CFG_REQUIRE_MERGE_APPROVAL" | tr '[:upper:]' '[:lower:]')" in
    ''|false|0|no|off) APPROVAL_REQUIRED=0 ;;
    *) APPROVAL_REQUIRED=1 ;;
  esac
}

main() {
resolve_config "$@" || return 1
WORK="$CFG_WORK"

BRANCH=$(gc bd show $WORK --json | jq -r '.[0].metadata.branch')
TARGET=$(gc bd show $WORK --json | jq -r --arg target_default "$CFG_TARGET_DEFAULT" '.[0].metadata.target // $target_default')
EXISTING_PR=$(gc bd show $WORK --json | jq -r '.[0].metadata.existing_pr // empty')
if [ -z "$TARGET" ] || [ "$TARGET" = null ]; then
  echo "merge-push: $WORK has no metadata.target and no target default resolved (--target-default, the rig's target_branch, or its DefaultBranch)."
  return 1
fi

resolve_origin_repo
MERGE_STRATEGY=$(resolve_merge_strategy "$WORK")
resolve_approval_required
if [ "$APPROVAL_REQUIRED" -eq 1 ] && [ "$MERGE_STRATEGY" = "direct" ]; then
  # A reviewed merge needs something to review. Without this promotion the
  # gate would refuse every direct-mode bead forever (fail-closed, but
  # permanently deadlocked) because no PR would ever exist to approve.
  echo "require_merge_approval is on; a reviewed merge needs a pull request — using merge_strategy=mr."
  MERGE_STRATEGY="mr"
fi
case "$MERGE_STRATEGY" in
  direct|mr|local) echo "merge-push: LANE $MERGE_STRATEGY" ;;
  *)
    echo "merge-push: unsupported merge_strategy=$MERGE_STRATEGY on $WORK. STOP. Do not mutate bead state."
    return 2
    ;;
esac

APPROVAL_GATE=""
if [ "$APPROVAL_REQUIRED" -eq 1 ]; then
  APPROVAL_GATE=$(resolve_approval_gate)
  if [ -z "$APPROVAL_GATE" ]; then
    echo "require_merge_approval is on but merge-approval-gate.sh was not found. STOP. Do not mutate bead state."
    echo "An unreadable gate is not an approval."
    return 2
  fi
fi
if [ "$MERGE_STRATEGY" = "mr" ] && [ -n "$EXISTING_PR" ]; then
  if [ -z "$BRANCH" ] || [ "$BRANCH" = "null" ]; then
    block_existing_pr "metadata.existing_pr is set but metadata.branch is missing."
    return $?
  fi

  if [ -z "$ORIGIN_REPO" ]; then
    [ -n "$ORIGIN_REPO_ERROR" ] && echo "$ORIGIN_REPO_ERROR"
    echo "Could not resolve origin repository for existing PR validation. STOP. Debug and retry without mutating bead state."
    return 2
  fi

  EXISTING_PR_ERR=$(mktemp)
  EXISTING_PR_INFO=$(lookup_pr_info "$EXISTING_PR" "$EXISTING_PR_ERR")
  EXISTING_PR_STATUS=$?
  EXISTING_PR_ERROR=$(cat "$EXISTING_PR_ERR")
  rm -f "$EXISTING_PR_ERR"
  if [ "$EXISTING_PR_STATUS" -ne 0 ] || [ -z "$EXISTING_PR_INFO" ]; then
    if pr_lookup_repo_mismatch "$EXISTING_PR_ERROR"; then
      block_existing_pr "Existing PR $EXISTING_PR is not in $ORIGIN_REPO. $EXISTING_PR_ERROR"
      return $?
    fi
    if pr_lookup_missing "$EXISTING_PR_ERROR"; then
      block_existing_pr "Existing PR $EXISTING_PR was not found or is not accessible."
      return $?
    fi
    echo "Could not resolve existing PR $EXISTING_PR. STOP. Debug and retry without mutating bead state."
    [ -n "$EXISTING_PR_ERROR" ] && echo "$EXISTING_PR_ERROR"
    return 2
  fi

  EXISTING_PR_STATE=$(printf '%s
' "$EXISTING_PR_INFO" | jq -r '.state')
  EXISTING_PR_HEAD=$(printf '%s
' "$EXISTING_PR_INFO" | jq -r '.headRefName')
  EXISTING_PR_BASE=$(printf '%s
' "$EXISTING_PR_INFO" | jq -r '.baseRefName')
  EXISTING_PR_URL=$(printf '%s
' "$EXISTING_PR_INFO" | jq -r '.url')
  EXISTING_PR_REPO=$(printf '%s
' "$EXISTING_PR_URL" | sed -E 's#^https://github.com/([^/]+/[^/]+)/pull/[0-9]+$#\1#')
  EXISTING_PR_HEAD_REPO=$(printf '%s
' "$EXISTING_PR_INFO" | jq -r '.headRepositoryOwner.login + "/" + .headRepository.name')

  if [ "$EXISTING_PR_STATE" != "OPEN" ]; then
    block_existing_pr "Existing PR $EXISTING_PR is $EXISTING_PR_STATE, want OPEN."
    return $?
  fi
  if [ "$EXISTING_PR_HEAD" != "$BRANCH" ]; then
    block_existing_pr "Existing PR $EXISTING_PR targets branch $EXISTING_PR_HEAD, want $BRANCH."
    return $?
  fi
  if [ "$EXISTING_PR_BASE" != "$TARGET" ]; then
    block_existing_pr "Existing PR $EXISTING_PR targets base $EXISTING_PR_BASE, want $TARGET."
    return $?
  fi
  if [ "$EXISTING_PR_REPO" != "$ORIGIN_REPO" ]; then
    block_existing_pr "Existing PR $EXISTING_PR belongs to repo $EXISTING_PR_REPO, want $ORIGIN_REPO."
    return $?
  fi
  if [ "$EXISTING_PR_HEAD_REPO" != "$ORIGIN_REPO" ]; then
    block_existing_pr "Existing PR $EXISTING_PR head repo $EXISTING_PR_HEAD_REPO, want $ORIGIN_REPO."
    return $?
  fi
fi

if [ "$MERGE_STRATEGY" = "mr" ] && [ -z "$ORIGIN_REPO" ]; then
  [ -n "$ORIGIN_REPO_ERROR" ] && echo "$ORIGIN_REPO_ERROR"
  echo "Could not resolve origin repository for pull-request handoff. STOP. Debug and retry without mutating bead state."
  return 2
fi
case "$MERGE_STRATEGY" in
  direct) lane_direct ;;
  mr) lane_mr ;;
  local) lane_local ;;
esac
}

if [ "${MERGE_PUSH_SOURCE_ONLY:-}" = 1 ]; then
  return 0 2>/dev/null || exit 0
fi

MP_SUMMARY=""
main "$@"
MP_STATUS=$?
echo "merge-push: RESULT $MP_STATUS ${CFG_WORK:-<no work>}: ${MP_SUMMARY:-$(result_summary "$MP_STATUS")}"
exit "$MP_STATUS"
