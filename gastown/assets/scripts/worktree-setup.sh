#!/bin/sh
# worktree-setup.sh — idempotent git worktree creation for Gas City agents.
#
# Usage: worktree-setup.sh <rig-root> <target-dir> <agent-name> [--sync]
#
# Ensures the target directory is a git worktree of the rig repo. For
# backward compatibility, the older <repo-dir> <agent-name> <city-root>
# signature still works and resolves the target under
# <city-root>/.gc/worktrees/<rig>/<agent-name>.
#
# Called from pre_start in pack configs. Runs before the session is created
# so the agent starts IN the worktree directory.
#
# BOUNDED: pre_start is killed at [session] setup_timeout (10s by default) and
# a killed pre_start fails the WHOLE session start; six of those in an hour
# latch the supervisor circuit breaker open and the rig loses that agent
# entirely (gcp-ntbf on the witness, gcp-oo0v on the deacon). This script
# therefore holds its NETWORK calls — the only ones that can block for an
# unbounded time — to a wall-clock budget inside that limit
# (6s; GC_WORKTREE_SETUP_BUDGET_SECONDS), and gives up on the sync rather than
# on the session. A stale worktree is recoverable on the next cycle; a start
# that never completes is not. Raise the budget only alongside setup_timeout.
#
# The local git plumbing below (worktree add, prune, submodule init) is
# deliberately NOT budgeted: it is disk-bound, it is the reason this script
# exists, and an agent whose worktree was not created has nothing to start in.
# Only the calls that talk to a remote get a deadline.
#
#   GC_WORKTREE_SETUP_BUDGET_SECONDS
#                      wall-clock budget shared by every network call in this
#                      run (default 6s). Must stay well inside the caller's
#                      [session] setup_timeout.

set -eu

# Well inside gascity's 10s default [session] setup_timeout — see BOUNDED above.
SYNC_BUDGET_SECONDS="${GC_WORKTREE_SETUP_BUDGET_SECONDS:-6}"
case "$SYNC_BUDGET_SECONDS" in
    '' | *[!0-9]* | 0)
        echo "worktree-setup: budget must be a positive whole number of seconds" >&2
        exit 2
        ;;
esac

BUDGET_START=$(date +%s)

# Seconds left in this run's network budget, floored at 0. Every remote-facing
# command is bounded by this, so no single hung fetch can outlive the budget.
budget_left() {
    _bl_left=$((SYNC_BUDGET_SECONDS - ($(date +%s) - BUDGET_START)))
    [ "$_bl_left" -ge 0 ] || _bl_left=0
    printf '%s\n' "$_bl_left"
}

TIMEOUT_BIN=""
if command -v timeout >/dev/null 2>&1; then
    TIMEOUT_BIN=timeout
elif command -v gtimeout >/dev/null 2>&1; then
    TIMEOUT_BIN=gtimeout
fi

# run_bounded <seconds> <cmd...> — run a command under a hard time limit,
# returning 124 if it does not finish in time (matching timeout(1)).
#
# The fallback matters: coreutils `timeout` is not on a stock macOS, and a
# pre_start that cannot bound its own children is precisely the failure this
# bound exists to prevent. So the fallback actually kills rather than merely
# giving up on waiting. Interrupting a fetch or a rebase this way is strictly
# gentler than the status quo, where gc SIGKILLs the whole process group at
# setup_timeout with no signal the child can act on at all.
run_bounded() {
    _rb_limit="$1"
    shift
    [ "$_rb_limit" -gt 0 ] || return 124
    if [ -n "$TIMEOUT_BIN" ]; then
        _rb_rc=0
        "$TIMEOUT_BIN" "$_rb_limit" "$@" || _rb_rc=$?
        return "$_rb_rc"
    fi
    "$@" &
    _rb_pid=$!
    _rb_waited=0
    while kill -0 "$_rb_pid" 2>/dev/null; do
        if [ "$_rb_waited" -ge "$_rb_limit" ]; then
            kill -TERM "$_rb_pid" 2>/dev/null || true
            sleep 1
            kill -KILL "$_rb_pid" 2>/dev/null || true
            wait "$_rb_pid" 2>/dev/null || true
            return 124
        fi
        sleep 1
        _rb_waited=$((_rb_waited + 1))
    done
    _rb_rc=0
    wait "$_rb_pid" || _rb_rc=$?
    return "$_rb_rc"
}

RIG_ROOT="${1:?usage: worktree-setup.sh <rig-root> <target-dir> <agent-name> [--sync]}"
ARG2="${2:?missing target-dir}"
ARG3="${3:?missing agent-name}"

is_path_like() {
    # Legacy mode passes the city path as arg 3. Agent names are validated
    # elsewhere and are not expected to look like filesystem paths.
    case "$1" in
        */*|.*|*:*|*\\*) return 0 ;;
        *) return 1 ;;
    esac
}

if is_path_like "$ARG3"; then
    AGENT="$ARG2"
    CITY="$ARG3"
    RIG=$(basename "$RIG_ROOT")
    WT="$CITY/.gc/worktrees/$RIG/$AGENT"
    SYNC="${4:-}"
else
    WT="$ARG2"
    AGENT="$ARG3"
    SYNC="${4:-}"
fi

branch_name() {
    # Namescape worktree branches by target path so multiple cities or rigs
    # can share one underlying repo without colliding on global refs like
    # gc-refinery or gc-polecat-1.
    HASH=$(printf '%s' "$WT" | git -C "$RIG_ROOT" hash-object --stdin | cut -c1-12)
    printf 'gc-%s-%s' "$AGENT" "$HASH"
}

git_common_dir() {
    COMMON_REPO=$1
    COMMON_DIR=$(git -C "$COMMON_REPO" rev-parse \
        --path-format=absolute --git-common-dir 2>/dev/null) || return 1
    (CDPATH= cd -- "$COMMON_DIR" 2>/dev/null && pwd -P)
}

validate_existing_worktree() {
    WT_REAL=$(CDPATH= cd -- "$WT" 2>/dev/null && pwd -P) || return 1
    WT_TOP=$(git -C "$WT_REAL" rev-parse --show-toplevel 2>/dev/null) ||
        return 1
    WT_TOP=$(CDPATH= cd -- "$WT_TOP" 2>/dev/null && pwd -P) || return 1
    [ "$WT_TOP" = "$WT_REAL" ] || return 1
    WT_COMMON=$(git_common_dir "$WT_REAL") || return 1
    RIG_COMMON=$(git_common_dir "$RIG_ROOT") || return 1
    [ "$WT_COMMON" = "$RIG_COMMON" ]
}

sync_worktree() {
    [ "$SYNC" = "--sync" ] || return 0

    WT_STATUS=$(git -C "$WT" status --porcelain --untracked-files=all) || {
        echo "worktree-setup: could not inspect provider worktree status at $WT; refusing sync" >&2
        return 1
    }
    if [ -n "$WT_STATUS" ]; then
        echo "worktree-setup: refusing to sync dirty provider worktree at $WT" >&2
        return 1
    fi
    if ! git -C "$WT" remote get-url origin >/dev/null 2>&1; then
        echo "worktree-setup: refusing to sync provider worktree without origin at $WT" >&2
        return 1
    fi

    DEFAULT_REF=$(git -C "$RIG_ROOT" symbolic-ref \
        refs/remotes/origin/HEAD 2>/dev/null || true)
    if [ -z "$DEFAULT_REF" ]; then
        # Remote-facing: shares this run's network budget (see BOUNDED above).
        if ! run_bounded "$(budget_left)" git -C "$RIG_ROOT" remote set-head origin --auto >/dev/null 2>&1; then
            echo "worktree-setup: could not discover origin/HEAD for $RIG_ROOT" >&2
            return 1
        fi
        DEFAULT_REF=$(git -C "$RIG_ROOT" symbolic-ref \
            refs/remotes/origin/HEAD 2>/dev/null || true)
    fi
    if [ -z "$DEFAULT_REF" ]; then
        echo "worktree-setup: origin/HEAD is not configured for $RIG_ROOT" >&2
        return 1
    fi
    DEFAULT_BRANCH=${DEFAULT_REF#refs/remotes/origin/}
    [ -n "$DEFAULT_BRANCH" ] || {
        echo "worktree-setup: could not resolve origin default branch for $RIG_ROOT" >&2
        return 1
    }
    # Remote-facing: bounded like every other network call here. A fetch that
    # runs out of budget refuses the sync exactly as a failed one does.
    if ! run_bounded "$(budget_left)" git -C "$RIG_ROOT" fetch origin "$DEFAULT_BRANCH"; then
        echo "worktree-setup: could not refresh origin/$DEFAULT_BRANCH within the network budget" >&2
        return 1
    fi
    if ! git -C "$RIG_ROOT" rev-parse --verify \
        "$DEFAULT_REF^{commit}" >/dev/null 2>&1; then
        echo "worktree-setup: fetched default ref is not a commit: $DEFAULT_REF" >&2
        return 1
    fi

    STABLE_BRANCH=$(branch_name)
    if ! git -C "$RIG_ROOT" check-ref-format \
        "refs/heads/$STABLE_BRANCH" >/dev/null 2>&1; then
        echo "worktree-setup: unsafe stable provider branch: $STABLE_BRANCH" >&2
        return 1
    fi

    CURRENT_HEAD=$(git -C "$WT" rev-parse --verify HEAD^{commit}) || {
        echo "worktree-setup: provider worktree has no valid HEAD: $WT" >&2
        return 1
    }
    CURRENT_BRANCH=$(git -C "$WT" symbolic-ref --quiet --short HEAD 2>/dev/null || true)
    if [ -z "$CURRENT_BRANCH" ]; then
        REACHABLE_REF=$(git -C "$RIG_ROOT" for-each-ref \
            --format='%(refname)' --contains "$CURRENT_HEAD" \
            refs/heads refs/remotes | head -n 1)
        if [ -z "$REACHABLE_REF" ]; then
            echo "worktree-setup: detached provider HEAD $CURRENT_HEAD is not ref-reachable; preserving it and refusing sync" >&2
            return 1
        fi
    fi

    if git -C "$RIG_ROOT" show-ref --verify --quiet \
        "refs/heads/$STABLE_BRANCH"; then
        if ! GIT_GRAFT_FILE=/dev/null \
            git --no-replace-objects -C "$RIG_ROOT" merge-base \
                --is-ancestor "refs/heads/$STABLE_BRANCH" "$DEFAULT_REF" \
                2>/dev/null; then
            echo "worktree-setup: stable provider branch $STABLE_BRANCH has unique or diverged work; preserving it and refusing sync" >&2
            return 1
        fi
        if [ "$CURRENT_BRANCH" != "$STABLE_BRANCH" ]; then
            if ! git -C "$WT" checkout "$STABLE_BRANCH"; then
                echo "worktree-setup: could not switch $WT to $STABLE_BRANCH; current HEAD was preserved" >&2
                return 1
            fi
        fi
    else
        if ! git -C "$WT" checkout -b "$STABLE_BRANCH" "$DEFAULT_REF"; then
            echo "worktree-setup: could not create stable branch $STABLE_BRANCH at $WT; current HEAD was preserved" >&2
            return 1
        fi
    fi

    if ! git -C "$WT" merge --ff-only "$DEFAULT_REF"; then
        echo "worktree-setup: could not fast-forward $STABLE_BRANCH to $DEFAULT_REF" >&2
        return 1
    fi
}

install_local_excludes() {
    # Keep runtime ignores in repository-local Git metadata instead of mutating
    # either the tracked .gitignore or the user's global excludes file.
    # --git-path resolves the exclude file Git actually consults for this
    # worktree, including linked-worktree layouts.
    EXCLUDE=$(git -C "$WT" rev-parse --git-path info/exclude)
    case "$EXCLUDE" in
        /*) ;;
        *) EXCLUDE="$WT/$EXCLUDE" ;;
    esac
    mkdir -p "$(dirname "$EXCLUDE")"
    touch "$EXCLUDE"

    MARKER="# Gas City worktree infrastructure (local excludes)"
    if ! grep -qF "$MARKER" "$EXCLUDE" 2>/dev/null; then
        if [ -s "$EXCLUDE" ] && [ "$(tail -c 1 "$EXCLUDE" 2>/dev/null || true)" != "" ]; then
            printf '\n' >> "$EXCLUDE"
        fi
        printf '%s\n' "$MARKER" >> "$EXCLUDE"
    fi

    append_exclude() {
        PATTERN="$1"
        grep -qxF "$PATTERN" "$EXCLUDE" 2>/dev/null || printf '%s\n' "$PATTERN" >> "$EXCLUDE"
    }

    append_exclude ".beads/redirect"
    append_exclude ".beads/hooks/"
    append_exclude ".beads/formulas/"
    append_exclude ".logs/"
    append_exclude ".gc/"
    append_exclude "worktrees/"
    append_exclude "__pycache__/"
    append_exclude ".claude/"
    append_exclude ".codex/"
    append_exclude ".agents/skills/"
    append_exclude ".gemini/"
    append_exclude ".opencode/"
    append_exclude ".github/hooks/"
    append_exclude ".github/copilot-instructions.md"
    append_exclude "state.json"
}

# Idempotent: skip if worktree already exists.
if [ -d "$WT/.git" ] || [ -f "$WT/.git" ]; then
    if ! validate_existing_worktree; then
        echo "worktree-setup: refusing existing path that is not a worktree of $RIG_ROOT: $WT" >&2
        exit 1
    fi
    install_local_excludes
    sync_worktree || exit 1
    exit 0
fi

mkdir -p "$(dirname "$WT")"

STAGE=""

merge_stage_entry() (
    SRC="$1"
    DST="$2"

    if [ -d "$SRC" ]; then
        mkdir -p "$DST"
        for ENTRY in "$SRC"/.[!.]* "$SRC"/..?* "$SRC"/*; do
            [ -e "$ENTRY" ] || continue
            merge_stage_entry "$ENTRY" "$DST/$(basename "$ENTRY")"
        done
        rmdir "$SRC" 2>/dev/null || true
        exit 0
    fi

    if [ -e "$DST" ]; then
        exit 0
    fi
    mv "$SRC" "$DST"
)

restore_stage() {
    [ -n "$STAGE" ] || return 0
    mkdir -p "$WT"
    for ENTRY in "$STAGE"/.[!.]* "$STAGE"/..?* "$STAGE"/*; do
        [ -e "$ENTRY" ] || continue
        merge_stage_entry "$ENTRY" "$WT/$(basename "$ENTRY")"
    done
    rmdir "$STAGE" 2>/dev/null || true
    STAGE=""
}

if [ -d "$WT" ] && [ "$(find "$WT" -mindepth 1 -maxdepth 1 | head -n 1)" ]; then
    STAGE=$(mktemp -d "$(dirname "$WT")/.gascity-worktree-stage.XXXXXX")
    find "$WT" -mindepth 1 -maxdepth 1 -exec mv {} "$STAGE"/ \;
    trap 'restore_stage' EXIT HUP INT TERM
fi

rmdir "$WT" 2>/dev/null || true
# Clear stale metadata from removed worktrees before branch/worktree lookup.
git -C "$RIG_ROOT" worktree prune >/dev/null 2>&1 || true

BRANCH=$(branch_name)

# Determine the upstream default branch ref and refresh it so the agent's
# persistent worktree branch is always created from the remote tip, not
# from whatever happened to be checked out locally. Without this fetch +
# explicit start-point, the worktree branch inherits a stale local default
# branch — across many beads, this causes the agent's local default branch
# to drift behind origin's, and feature branches cut from it carry
# already-merged commits that the refinery rebase rejects as spurious
# duplicates with mismatched hashes.
DEFAULT_REF=$(git -C "$RIG_ROOT" symbolic-ref refs/remotes/origin/HEAD 2>/dev/null || true)
if [ -n "$DEFAULT_REF" ]; then
    DEFAULT_BRANCH=${DEFAULT_REF#refs/remotes/origin/}
    run_bounded "$(budget_left)" git -C "$RIG_ROOT" fetch origin "$DEFAULT_BRANCH" >/dev/null 2>&1 || true
fi

if git -C "$RIG_ROOT" show-ref --verify --quiet "refs/heads/$BRANCH"; then
    if ! GIT_LFS_SKIP_SMUDGE=1 git -C "$RIG_ROOT" worktree add "$WT" "$BRANCH"; then
        echo "worktree-setup: failed to create worktree at $WT from $RIG_ROOT (branch $BRANCH)" >&2
        restore_stage
        exit 1
    fi
else
    if [ -n "$DEFAULT_REF" ]; then
        if ! GIT_LFS_SKIP_SMUDGE=1 git -C "$RIG_ROOT" \
            worktree add "$WT" -b "$BRANCH" "$DEFAULT_REF"; then
            echo "worktree-setup: failed to create worktree at $WT from $RIG_ROOT (branch $BRANCH)" >&2
            restore_stage
            exit 1
        fi
    else
        # Fallback: no origin/HEAD configured (detached, or no remote default
        # set). Create from current HEAD as before.
        if ! GIT_LFS_SKIP_SMUDGE=1 git -C "$RIG_ROOT" \
            worktree add "$WT" -b "$BRANCH"; then
            echo "worktree-setup: failed to create worktree at $WT from $RIG_ROOT (branch $BRANCH)" >&2
            restore_stage
            exit 1
        fi
    fi
fi

if [ -n "$STAGE" ]; then
    for ENTRY in "$STAGE"/.[!.]* "$STAGE"/..?* "$STAGE"/*; do
        [ -e "$ENTRY" ] || continue
        merge_stage_entry "$ENTRY" "$WT/$(basename "$ENTRY")"
    done
    rm -rf "$STAGE"
    STAGE=""
fi
trap - EXIT HUP INT TERM

# Bead redirect for filesystem beads.
mkdir -p "$WT/.beads"
echo "$RIG_ROOT/.beads" > "$WT/.beads/redirect"

# Submodule init (best-effort).
git -C "$WT" submodule init 2>/dev/null || true

install_local_excludes

# Optional sync.
sync_worktree

exit 0
