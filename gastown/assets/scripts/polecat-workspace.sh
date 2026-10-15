#!/usr/bin/env bash
# polecat-workspace.sh — the deterministic shell of mol-polecat-work's
# workspace-setup step, run as one script so the polecat makes a short call and
# does not retype it (gcp-xeael).
#
# SOURCE IT, do not execute it:
#
#   . polecat-workspace.sh base-resolve <work-bead-id> <base-branch> <binding-prefix>
#   . polecat-workspace.sh worktree     <work-bead-id> <base-ref>
#   . polecat-workspace.sh new-branch   <work-bead-id> <base-ref> <base-branch>
#
# The fences it replaces ran in the polecat's own shell and left three things
# there that later fences read: the working directory (worktree ends with a cd
# into the task worktree), BASE_REF (base-resolve sets it; the rejection-rebase
# fence and new-branch read it), and the shell variables each body assigns. A
# child process cannot hand any of that back, so this file is sourced and every
# line below runs in the caller's shell exactly as the inline fence did: an
# `exit 1` ends the caller's call, as it always did. Executed instead of
# sourced, it stops with WORKSPACE_USAGE before it touches anything.
#
#   base-resolve  workspace-setup section 1: resolve what the base branch means in
#                 this clone (remote first, then local, else STOP), set BASE_REF
#                 and record it as metadata.base_ref.
#   worktree      section 2: load the task keys and roots, validate, then reuse,
#                 adopt or create the per-bead artifact worktree, record
#                 metadata.artifact_dir and cd into it.
#   new-branch    section 3 "If no branch": record polecat/<work-bead-id> on a
#                 clean detached checkout, or stop. The resume-an-existing-branch
#                 and rejection-rebase fences stay in the step: the model acts on
#                 them.
#
# Inputs are the positional arguments above. The formula step passes the shell's
# own WORK_BEAD_ID (set by section 1) and BASE_REF (set by base-resolve), and
# fills <base-branch> and <binding-prefix> from the rig. An EMPTY <work-bead-id>
# or <base-ref> leaves the caller's variable exactly as it was, so a call made
# without them meets the guards the fences always had: worktree rejects an
# unsafe id and checks BASE_REF where it first needs it, new-branch checks it on
# entry.
# Env also read: GC_CITY_PATH GC_RIG GC_RIG_ROOT (worktree), GC_RIG (base-resolve).
#
# Variables left in the caller's shell are the ones the fences always left: the
# mode's own assignments plus WORK_BEAD_ID and BASE_REF. The WS_* parameters are
# removed again before the file returns, and the file returns the status of the
# mode's last command, as the fence did. (On an `exit` path the shell is gone, so
# nothing is left to see.)

if ! (return 0 2>/dev/null); then
    echo "WORKSPACE_USAGE polecat-workspace.sh is sourced, not executed: . polecat-workspace.sh base-resolve|worktree|new-branch ..."
    exit 2
fi
WS_MODE="${1:-}"
case "$WS_MODE:$#" in
    base-resolve:4 | worktree:3 | new-branch:4) ;;
    *)
        echo "WORKSPACE_USAGE . polecat-workspace.sh base-resolve <work-bead-id> <base-branch> <binding-prefix> | worktree <work-bead-id> <base-ref> | new-branch <work-bead-id> <base-ref> <base-branch>"
        exit 2
        ;;
esac
# An empty argument leaves the caller's variable exactly as it was (unset stays
# unset), so a call made without the id or the ref behaves as the fence did.
[ -z "$2" ] || WORK_BEAD_ID="$2"
case "$WS_MODE" in
    base-resolve) WS_BASE_BRANCH="$3"; WS_BINDING_PREFIX="$4" ;;
    worktree) [ -z "$3" ] || BASE_REF="$3" ;;
    new-branch) [ -z "$3" ] || BASE_REF="$3"; WS_BASE_BRANCH="$4" ;;
esac
case "$WS_MODE" in
base-resolve)
# --- base-resolve:begin ---
# GUARD_BEGIN base-resolve
BASE_REMOTE="refs/remotes/origin/${WS_BASE_BRANCH}"
BASE_LOCAL="refs/heads/${WS_BASE_BRANCH}"
WITNESS_TARGET="${GC_RIG:+$GC_RIG/}${WS_BINDING_PREFIX}witness"
if git show-ref --verify --quiet "$BASE_REMOTE"; then
    if git show-ref --verify --quiet "$BASE_LOCAL" && ! git merge-base --is-ancestor "$BASE_LOCAL" "$BASE_REMOTE"; then
        LOCAL_ONLY=$(git rev-list --count "$BASE_LOCAL" --not --remotes) || LOCAL_ONLY=err
        if [ "$LOCAL_ONLY" != "0" ]; then
            echo "STOP: local ${WS_BASE_BRANCH} has local-only commits that are not on origin or any other remote branch."
            echo "Reconcile or push ${WS_BASE_BRANCH} first; do not branch from a stale base."
            gc bd update "$WORK_BEAD_ID" --set-metadata halt_reason=base_branch_diverged
            gc mail send "$WITNESS_TARGET" -s "polecat halted: base_branch_diverged ($WORK_BEAD_ID)" -m "Local ${WS_BASE_BRANCH} has local-only commits (count: $LOCAL_ONLY) that are not an ancestor of the copy on origin and are on no remote branch; $WORK_BEAD_ID cannot pick a fork point. Reconcile the branch."
            gc runtime drain-ack
            exit 1
        fi
        echo "note: local ${WS_BASE_BRANCH} is stale (0 commits off-remote); branching from origin"
    fi
    BASE_REF="$BASE_REMOTE"    # preferred: freshly fetched, no local drift
elif git show-ref --verify --quiet "$BASE_LOCAL"; then
    BASE_REF="$BASE_LOCAL"     # local-only base (unpushed integration branch)
    echo "note: base branch ${WS_BASE_BRANCH} is local-only — it does not exist on origin"
else
    echo "STOP: base branch ${WS_BASE_BRANCH} exists neither on origin nor locally."
    echo "Fix the rig/bead base configuration; do not substitute a different base."
    gc bd update "$WORK_BEAD_ID" --set-metadata halt_reason=base_branch_missing
    gc mail send "$WITNESS_TARGET" -s "polecat halted: base_branch_missing ($WORK_BEAD_ID)" -m "Base branch ${WS_BASE_BRANCH} exists neither on origin nor locally in this clone. $WORK_BEAD_ID cannot start until the rig/bead base configuration is fixed."
    gc runtime drain-ack
    exit 1
fi
gc bd update "$WORK_BEAD_ID" --set-metadata base_ref="$BASE_REF"
# GUARD_END base-resolve
# --- base-resolve:end ---
;;
worktree)
# --- worktree:begin ---
BEAD_JSON=$(gc bd show "$WORK_BEAD_ID" --json) || {
  echo "Could not read work bead metadata for $WORK_BEAD_ID." >&2
  gc runtime drain-ack
  exit 1
}
BEAD_META=$(printf '%s' "$BEAD_JSON" | jq -ce '
  if type == "array" and length == 1 and (.[0] | type) == "object" and
     ((.[0].metadata // {}) | type) == "object"
  then .[0].metadata // {}
  else error("expected exactly one work bead object")
  end
') || {
  echo "Invalid work bead response for $WORK_BEAD_ID; refusing to create or adopt an artifact." >&2
  gc runtime drain-ack
  exit 1
}
ARTIFACT_DIR=$(printf '%s' "$BEAD_META" | jq -r '.artifact_dir // empty')
LEGACY_WORK_DIR=$(printf '%s' "$BEAD_META" | jq -r '.work_dir // empty')
if [ -z "${GC_CITY_PATH:-}" ] || [ -z "${GC_RIG:-}" ] ||
   [ -z "${GC_RIG_ROOT:-}" ]; then
  echo "GC_CITY_PATH, GC_RIG, and GC_RIG_ROOT are required for task worktrees." >&2
  gc runtime drain-ack
  exit 1
fi
case "$WORK_BEAD_ID" in
  ""|"."|".."|*[!A-Za-z0-9._-]*)
    echo "Unsafe work bead id for artifact path: $WORK_BEAD_ID" >&2
    gc runtime drain-ack
    exit 1
    ;;
esac
case "$GC_RIG" in
  ""|"."|".."|*[!A-Za-z0-9._-]*)
    echo "Unsafe rig name for artifact path: $GC_RIG" >&2
    gc runtime drain-ack
    exit 1
    ;;
esac
CITY_ROOT=$(CDPATH= cd -- "$GC_CITY_PATH" 2>/dev/null && pwd -P) || {
  echo "City root is missing: $GC_CITY_PATH" >&2
  gc runtime drain-ack
  exit 1
}
RIG_ROOT=$(CDPATH= cd -- "$GC_RIG_ROOT" 2>/dev/null && pwd -P) || {
  echo "Rig root is missing: $GC_RIG_ROOT" >&2
  gc runtime drain-ack
  exit 1
}

# BEGIN ARTIFACT_WORKTREE_VALIDATOR
artifact_git_common_dir() {
  local repo_dir=$1 common_dir
  common_dir=$(git -C "$repo_dir" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) ||
    return 1
  (CDPATH= cd -- "$common_dir" 2>/dev/null && pwd -P)
}

validate_artifact_worktree() {
  local candidate=$1 city_root=$2 rig_name=$3 rig_root=$4 bead_id=$5
  local policy=${6:-existing}
  local candidate_real candidate_top candidate_common rig_common
  local rig_namespace rig_namespace_real canonical_path
  local worktrees_parent provider_home provider_root provider_name

  [ -n "$candidate" ] && [ -d "$candidate" ] || return 1
  candidate_real=$(CDPATH= cd -- "$candidate" 2>/dev/null && pwd -P) || return 1

  # Only the exact bead-scoped .../worktrees/<bead-id> shape is reusable.
  [ "$(basename -- "$candidate_real")" = "$bead_id" ] || return 1
  [ "$(basename -- "$(dirname -- "$candidate_real")")" = "worktrees" ] || return 1

  # Same-repository is not an ownership boundary: multiple cities and rigs can
  # share one Git common dir. Require this city's exact canonical path or the
  # one historical provider-nested layout that Gastown actually created.
  rig_namespace="$city_root/.gc/worktrees/$rig_name"
  rig_namespace_real=$(CDPATH= cd -- "$rig_namespace" 2>/dev/null && pwd -P) ||
    return 1
  [ "$rig_namespace_real" = "$rig_namespace" ] || return 1
  canonical_path="$rig_namespace_real/artifacts/worktrees/$bead_id"
  if [ "$candidate_real" = "$canonical_path" ]; then
    [ "$policy" != legacy-only ] || return 1
  else
    [ "$policy" != canonical-only ] || return 1
    worktrees_parent=$(dirname -- "$candidate_real")
    provider_home=$(dirname -- "$worktrees_parent")
    provider_root=$(dirname -- "$provider_home")
    provider_name=$(basename -- "$provider_home")
    [ "$provider_root" = "$rig_namespace_real/polecats" ] || return 1
    case "$provider_name" in
      ""|"."|".."|*[!A-Za-z0-9._-]*) return 1 ;;
    esac
  fi

  # Reject a plain subdirectory of a worktree and worktrees from another repo.
  candidate_top=$(git -C "$candidate_real" rev-parse --show-toplevel 2>/dev/null) ||
    return 1
  candidate_top=$(CDPATH= cd -- "$candidate_top" 2>/dev/null && pwd -P) || return 1
  [ "$candidate_top" = "$candidate_real" ] || return 1
  candidate_common=$(artifact_git_common_dir "$candidate_real") || return 1
  rig_common=$(artifact_git_common_dir "$rig_root") || return 1
  [ "$candidate_common" = "$rig_common" ] || return 1

  printf '%s\n' "$candidate_real"
}
# END ARTIFACT_WORKTREE_VALIDATOR

WORKTREE=
if [ -n "$ARTIFACT_DIR" ]; then
  if WORKTREE=$(validate_artifact_worktree \
      "$ARTIFACT_DIR" "$CITY_ROOT" "$GC_RIG" "$RIG_ROOT" \
      "$WORK_BEAD_ID" existing); then
    echo "Reusing artifact_dir=$WORKTREE"
  else
    echo "Canonical artifact_dir is missing or unsafe: $ARTIFACT_DIR" >&2
    echo "STOP. Preserve it for manual recovery; only an absent canonical key may fall back or create." >&2
    gc runtime drain-ack
    exit 1
  fi
elif [ -n "$LEGACY_WORK_DIR" ]; then
  if WORKTREE=$(validate_artifact_worktree \
      "$LEGACY_WORK_DIR" "$CITY_ROOT" "$GC_RIG" "$RIG_ROOT" \
      "$WORK_BEAD_ID" legacy-only); then
    echo "Adopting validated in-place legacy work_dir=$WORKTREE as artifact_dir."
    echo "It remains provider-nested until terminal cleanup; new artifacts are always canonical."
  else
    echo "Ignoring unsafe legacy work_dir=$LEGACY_WORK_DIR; creating a new per-bead worktree." >&2
  fi
fi

if [ -z "$WORKTREE" ]; then
  ARTIFACT_HOME="$CITY_ROOT/.gc/worktrees/$GC_RIG/artifacts"
  if [ -L "$ARTIFACT_HOME" ] ||
     { [ -e "$ARTIFACT_HOME" ] && [ ! -d "$ARTIFACT_HOME" ]; }; then
    echo "Task artifact root is redirected or is not a directory: $ARTIFACT_HOME" >&2
    gc runtime drain-ack
    exit 1
  fi
  mkdir -p -- "$ARTIFACT_HOME"
  ARTIFACT_HOME_REAL=$(CDPATH= cd -- "$ARTIFACT_HOME" 2>/dev/null && pwd -P) || {
    echo "Cannot resolve task artifact root." >&2
    gc runtime drain-ack
    exit 1
  }
  if [ "$ARTIFACT_HOME_REAL" != "$ARTIFACT_HOME" ]; then
    echo "Task artifact root is redirected outside the city/rig namespace." >&2
    gc runtime drain-ack
    exit 1
  fi
  WORKTREE_PARENT="$ARTIFACT_HOME/worktrees"
  if [ -L "$WORKTREE_PARENT" ] ||
     { [ -e "$WORKTREE_PARENT" ] && [ ! -d "$WORKTREE_PARENT" ]; }; then
    echo "Task worktree parent is redirected or is not a directory: $WORKTREE_PARENT" >&2
    gc runtime drain-ack
    exit 1
  fi
  mkdir -p -- "$WORKTREE_PARENT"
  WORKTREE_PARENT=$(CDPATH= cd -- "$WORKTREE_PARENT" 2>/dev/null && pwd -P) || {
    echo "Cannot resolve task worktree parent under the city artifact root." >&2
    gc runtime drain-ack
    exit 1
  }
  if [ "$WORKTREE_PARENT" != "$ARTIFACT_HOME/worktrees" ]; then
    echo "Task worktree parent is redirected outside the city artifact root." >&2
    gc runtime drain-ack
    exit 1
  fi
  WORKTREE_PATH="$WORKTREE_PARENT/$WORK_BEAD_ID"

  if [ -e "$WORKTREE_PATH" ]; then
    # Recover the narrow crash window after git worktree add but before the
    # metadata write. Never reuse an unrelated directory at this path.
    if WORKTREE=$(validate_artifact_worktree \
        "$WORKTREE_PATH" "$CITY_ROOT" "$GC_RIG" "$RIG_ROOT" \
        "$WORK_BEAD_ID" canonical-only); then
      echo "Recovering existing validated per-bead worktree=$WORKTREE"
    else
      echo "Canonical artifact path already exists but is not this bead's validated worktree: $WORKTREE_PATH" >&2
      echo "STOP. Preserve and resolve the collision manually; do not create an alternate artifact." >&2
      gc runtime drain-ack
      exit 1
    fi
  fi

  if [ -z "$WORKTREE" ]; then
    git -C "$RIG_ROOT" worktree prune
    : "${BASE_REF:?base ref not resolved — run step 1 first}"
    git -C "$RIG_ROOT" worktree add "$WORKTREE_PATH" --detach "$BASE_REF"
    WORKTREE=$(validate_artifact_worktree \
      "$WORKTREE_PATH" "$CITY_ROOT" "$GC_RIG" "$RIG_ROOT" \
      "$WORK_BEAD_ID" canonical-only) || {
        echo "New task worktree failed validation: $WORKTREE_PATH" >&2
        gc runtime drain-ack
        exit 1
      }
  fi
fi

# Record the canonical key immediately, then retire any legacy task key.
gc bd update "$WORK_BEAD_ID" \
  --set-metadata artifact_dir="$WORKTREE" \
  --unset-metadata work_dir || {
    echo "Could not record artifact_dir; refusing to enter an untracked task worktree." >&2
    gc runtime drain-ack
    exit 1
  }
cd -- "$WORKTREE" || {
  echo "Validated task worktree disappeared: $WORKTREE" >&2
  gc runtime drain-ack
  exit 1
}
# --- worktree:end ---
;;
new-branch)
# --- new-branch:begin ---
: "${BASE_REF:?base ref not resolved — run step 1 first}"
EXPECTED_BRANCH="polecat/$WORK_BEAD_ID"
CURRENT_BRANCH=$(git branch --show-current)
if [ "$CURRENT_BRANCH" = "$EXPECTED_BRANCH" ]; then
  BRANCH="$EXPECTED_BRANCH"
  FORK_SHA=$(git merge-base "$BRANCH" "$BASE_REF") || {
    echo "Cannot derive fork point for recovered branch $BRANCH." >&2
    gc runtime drain-ack
    exit 1
  }
  gc bd update "$WORK_BEAD_ID" \
    --set-metadata branch="$BRANCH" \
    --set-metadata fork_sha="$FORK_SHA" || {
      echo "Could not record recovered branch metadata." >&2
      gc runtime drain-ack
      exit 1
    }
elif [ -n "$CURRENT_BRANCH" ] ||
     [ -n "$(git status --porcelain)" ] ||
     git show-ref --verify --quiet "refs/heads/$EXPECTED_BRANCH" ||
     git show-ref --verify --quiet "refs/remotes/origin/$EXPECTED_BRANCH" ||
     ! git merge-base --is-ancestor HEAD "$BASE_REF"; then
  echo "artifact_dir contains branch/work not recorded in metadata.branch." >&2
  echo "STOP. Recover and record it manually; do not reset or delete refs." >&2
  gc runtime drain-ack
  exit 1
else
  # A clean detached checkout at or behind the base has no unique work.
  if [ "$BASE_REF" = "refs/heads/${WS_BASE_BRANCH}" ]; then
    :  # local-only base: nothing on origin to refresh
  elif ! git fetch origin ${WS_BASE_BRANCH} >/dev/null 2>&1; then
    # Step 1 already resolved this base on origin, so a failure here is
    # either transient or the base disappearing mid-run. Ask origin rather
    # than silently branching from a stale remote-tracking ref.
    if git ls-remote --exit-code --heads origin "refs/heads/${WS_BASE_BRANCH}" >/dev/null 2>&1; then
      echo "warning: could not refresh ${WS_BASE_BRANCH}; using the ref fetched in step 1"
    else
      echo "STOP: ${WS_BASE_BRANCH} no longer resolves on origin (deleted, renamed, or unreachable)." >&2
      echo "Re-run workspace-setup to re-resolve the base; do not branch from a stale ref." >&2
      gc runtime drain-ack
      exit 1
    fi
  fi
  BRANCH="$EXPECTED_BRANCH"
  git checkout -b "$BRANCH" "$BASE_REF" || {
    echo "Could not create $BRANCH from $BASE_REF." >&2
    gc runtime drain-ack
    exit 1
  }
  gc bd update "$WORK_BEAD_ID" \
    --set-metadata branch="$BRANCH" \
    --set-metadata fork_sha="$(git rev-parse "$BASE_REF")" || {
      echo "Could not record new branch metadata." >&2
      gc runtime drain-ack
      exit 1
    }
fi
# --- new-branch:end ---
;;
esac
# Return the mode's own status with no WS_ variable left behind. `return` takes
# its status from WS_RC, so the eval expands it before it unsets it.
WS_RC=$?
unset WS_MODE WS_BASE_BRANCH WS_BINDING_PREFIX
eval "unset WS_RC; return $WS_RC"
