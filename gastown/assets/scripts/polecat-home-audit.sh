#!/usr/bin/env bash
# polecat-home-audit.sh — find polecat AGENT-HOME worktrees no live session owns.
#
# The blind spot this closes (gcp-actg, reported as gascity-o963):
#   A polecat has TWO kinds of worktree. The per-bead one at
#   <home>/worktrees/<bead-id> is found through its bead, and
#   polecat-worktree-reap.sh reaps it once that bead closes. The persistent
#   agent HOME at <city>/.gc/worktrees/<rig>/polecats/<agent> has no bead at
#   all — so every existing guard, all of which key on a bead, is structurally
#   blind to it:
#     - polecat-worktree-reap.sh    excludes homes by construction (its gate 1
#                                   requires a `worktrees/` parent segment).
#     - recover-orphaned-beads      keys on a bead whose metadata.work_dir
#                                   leads to the worktree.
#     - the work_dir scan           same key, same blindness.
#   Only a roster-vs-disk diff can see a home, and nothing performed one.
#
# Why it matters even though a stranded home loses nothing: home paths are
# deterministic per namepool slot. Respawn the same slot and the new polecat
# inherits somebody else's abandoned checkout — and a non-empty
# `git status --porcelain` is exactly what fails submit-and-exit's clean-state
# check. Two instances so far, in two different homes (gascity-vst on nux, and
# the gascity furiosa home this bead was filed from: 61 dirty paths, detached
# HEAD, no session in any state).
#
# Deliberately keyed on NOTHING from the bead store. This script issues zero
# `gc bd` calls: the candidate set comes from `git worktree list`, and
# ownership from the session roster. Keying a home guard on bead fields is the
# shared root of this whole family of blind spots (gascity-18kz, gcp-4k6o), so
# reintroducing it here would rebuild the bug the script exists to fix.
#
# THE TRAP — a home with no session is NOT automatically disposable:
#   When this was filed, `gascity/gastown.rictus` was alive and working inside
#   the DEAD `gascity/gastown.furiosa` home's subtree, at
#   .../polecats/gastown.furiosa/worktrees/gascity-g7nf. A naive
#   "home + no session -> remove" sweep deletes a live polecat's working tree
#   out from under it. So a home with ANY per-bead child on disk is deferred,
#   whoever owns that child. Resolving each child's owner would mean reading
#   the child's bead — the exact bead-keying this script refuses — and the
#   conservative rule needs no such read: children belong to
#   polecat-worktree-reap.sh, and once it has cleared them the home becomes
#   eligible on a later cycle. Deferring costs a cycle; guessing costs a
#   working tree.
#
#   That deferral suppresses the TEARDOWN and nothing else (gcp-fzjo). The
#   lost-work reports are evaluated for every home before the child gate is
#   reached, because a home with children is the home most likely to be dirty
#   and the one whose dirt persists longest — the child gate re-fires every
#   cycle for as long as the per-bead worktrees live, so ordering it first hid
#   the dirt for that whole span.
#
# Gates — ALL must hold before a home is removed:
#   1. Path shape is a polecat agent home: .../polecats/<agent>, i.e. the
#      parent directory is literally `polecats`. That excludes the per-bead
#      worktrees (parent `worktrees`), the rig root, and every non-polecat
#      agent's worktree. The candidate sets of this script and the per-bead
#      reaper are disjoint by construction.
#   2. The session roster holds no LIVE session for this home — matched on the
#      session's own `work_dir`, and on `<rig>/<agent>` derived from the path.
#      The roster is the only ownership key here, so a read that fails, times
#      out or does not parse ends the whole run with nothing removed: an
#      unreadable roster is not an empty one, and reading it as empty is how a
#      sweep concludes that nobody owns anything and clears every home on the
#      rig. That is mol-witness-patrol's absent-confirm discipline (gcp-g98) —
#      a confirmation read that fails is not proof of absence.
#   3. `git status --porcelain` is empty AND `git rev-list HEAD --not --remotes`
#      is empty. Unlike the per-bead reaper, this script DOES gate on
#      unpublished commits: that reaper can skip the check because a closed
#      bead is the refinery's own proof the work landed, and a home has no bead
#      to close. The furiosa home was on a DETACHED HEAD holding two commits
#      that belonged to no branch; establishing they were superseded took
#      reading content at origin, which a sweep must not attempt on its own.
#      So unbranched commits are REPORTED, never silently removed.
#   4. The home holds no per-bead child worktrees — THE TRAP above.
#
#   Gate 3 is a REPORT and gate 4 is a REMOVAL decision, so they are evaluated
#   in that order and neither short-circuits the other: a home can log both
#   `home_dirty_kept` and `home_children_kept` in one cycle, and is skipped
#   once. Gate 4 first was the bug in gcp-fzjo — it silenced gate 3 entirely
#   for any home with a child.
#
# Staged rollout: REAL REMOVAL IS OPT-IN, matching the per-bead reaper and the
# city's posture for the native gascity reaper. Without --no-dry-run this
# reports what it WOULD remove and removes nothing. Flip it only after the
# logged would-remove set has been reviewed across several patrol cycles.
#
# NOT a pre_start, and it must not become one. It is invoked from
# mol-witness-patrol's `audit-polecat-homes` step. `pre_start` is bounded by
# [session] setup_timeout (10s) and SIGKILLed on overrun, which fails the whole
# session start and, after six failures in an hour, latches the supervisor
# circuit breaker so the agent never returns (gcp-ntbf on the witness,
# gcp-oo0v on the deacon). The witness already spends most of that budget on
# polecat-worktree-reap.sh. A periodic sweep belongs in a patrol cycle, which
# is also where it gets a budget generous enough to walk every home in one go.
# It still enforces its own wall clock: a patrol step that hangs stalls a
# patrol, and partial work here is free because the sweep is idempotent.
#
# Output: one JSON line per decision appended to LOG_FILE, plus a human
# summary on stdout. Same log schema as polecat-worktree-reap.log — `ts` is
# stamped at the event, `run_started` groups lines into cycles,
# `budget_remaining` shows whether a decision was the clock's, and `reason` is
# the machine-readable WHY, separating "the command ran and failed" from "the
# command never ran".
#
# Env / args:
#   $1 | GC_RIG_ROOT   rig repo root (default: `git rev-parse --show-toplevel`)
#   --rig <name>       rig name, recorded on every log line. Defaults to $GC_RIG.
#   LOG_DIR            where to write the log. Defaults to the city runtime log
#                      directory; NEVER defaults inside the rig repo, which
#                      would litter the canonical checkout with untracked files.
#   --dry-run          report what would be removed, remove nothing (the default)
#   --no-dry-run       opt in to real removal
#   --budget <secs> | GC_HOME_AUDIT_BUDGET_SECONDS
#                      wall-clock budget for the whole run (default 20s).
#
# Usage:
#   GC_RIG=helm polecat-home-audit.sh                       # report only
#   polecat-home-audit.sh /path/to/rig --rig helm --no-dry-run

set -euo pipefail

# Dry run is the default; real removal must be asked for. See the staged
# rollout note in the header.
DRY_RUN=1
RIG_ROOT=""
RIG_NAME="${GC_RIG:-}"
# A patrol step, not a pre_start, so this is not held to setup_timeout — but a
# sweep that can hang stalls a patrol cycle, so it still spends one wall clock.
BUDGET_SECONDS="${GC_HOME_AUDIT_BUDGET_SECONDS:-20}"

while [ "$#" -gt 0 ]; do
    case "$1" in
        --dry-run) DRY_RUN=1 ;;
        --no-dry-run) DRY_RUN=0 ;;
        --rig)
            shift
            [ "$#" -gt 0 ] || { echo "polecat-home-audit: --rig needs a value" >&2; exit 2; }
            RIG_NAME="$1"
            ;;
        --budget)
            shift
            [ "$#" -gt 0 ] || { echo "polecat-home-audit: --budget needs a value" >&2; exit 2; }
            BUDGET_SECONDS="$1"
            ;;
        -*) echo "polecat-home-audit: unknown flag $1" >&2; exit 2 ;;
        *) RIG_ROOT="$1" ;;
    esac
    shift
done

case "$BUDGET_SECONDS" in
    '' | *[!0-9]* | 0)
        echo "polecat-home-audit: budget must be a positive whole number of seconds" >&2
        exit 2
        ;;
esac

if [ -z "$RIG_ROOT" ]; then
    RIG_ROOT="${GC_RIG_ROOT:-}"
fi
if [ -z "$RIG_ROOT" ]; then
    RIG_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || true)
fi
if [ -z "$RIG_ROOT" ] || [ ! -d "$RIG_ROOT" ]; then
    echo "polecat-home-audit: rig root not found (pass it as \$1 or set GC_RIG_ROOT)" >&2
    exit 2
fi

# Log destination, in descending order of confidence. The rig repo is
# deliberately absent from this list: a sweep that cleans up around the
# canonical checkout must never leave untracked files inside it.
if [ -n "${LOG_DIR:-}" ]; then
    :
elif [ -n "${GC_CITY_RUNTIME_DIR:-}" ]; then
    LOG_DIR="$GC_CITY_RUNTIME_DIR/logs"
elif [ -n "${GC_CITY:-}" ]; then
    LOG_DIR="$GC_CITY/.gc/runtime/logs"
else
    LOG_DIR="${TMPDIR:-/tmp}/gc-polecat-home-audit"
fi
LOG_FILE="$LOG_DIR/polecat-home-audit.log"
# Housekeeping must never take a patrol down with it: every failure below
# degrades to a clean exit 0.
if ! mkdir -p "$LOG_DIR" 2>/dev/null || ! touch "$LOG_FILE" 2>/dev/null; then
    echo "polecat-home-audit: cannot write $LOG_FILE; skipping this run" >&2
    exit 0
fi

RUN_STARTED=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
START_EPOCH=$(date +%s)

# Seconds left in this run's budget, floored at 0. Every external command is
# bounded by this, so no single hung call can outlive the budget either.
budget_left() {
    local left=$((BUDGET_SECONDS - ($(date +%s) - START_EPOCH)))
    if [ "$left" -lt 0 ]; then
        left=0
    fi
    printf '%s\n' "$left"
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
# The fallback matters: coreutils `timeout` is not on a stock macOS, and it
# actually kills rather than merely giving up on waiting.
#
# NOTE FOR CALLERS: a 124 from here means one of two very different things —
# the command ran and overran, or the budget was already spent so it NEVER RAN.
# Pass the limit you gave and the code you got to classify_outcome and report
# what it says. Do not describe a 124 as a failure of the command.
run_bounded() {
    local limit="$1"
    shift
    if [ "$limit" -le 0 ]; then
        return 124
    fi
    if [ -n "$TIMEOUT_BIN" ]; then
        local rc=0
        "$TIMEOUT_BIN" "$limit" "$@" || rc=$?
        return "$rc"
    fi
    local pid waited=0 rc=0
    "$@" &
    pid=$!
    while kill -0 "$pid" 2>/dev/null; do
        if [ "$waited" -ge "$limit" ]; then
            kill -TERM "$pid" 2>/dev/null || true
            sleep 1
            kill -KILL "$pid" 2>/dev/null || true
            wait "$pid" 2>/dev/null || true
            return 124
        fi
        sleep 1
        waited=$((waited + 1))
    done
    wait "$pid" || rc=$?
    return "$rc"
}

# classify_outcome <limit-given> <exit-code> — name what actually happened to a
# bounded call: `skipped` (the budget was already spent, so the command never
# ran), `timeout` (it ran and was killed at the limit), `failed` (it ran and
# exited non-zero), `ok`.
#
# The limit is an argument rather than global state because several call sites
# capture stdout in a command substitution, and anything run_bounded set about
# itself would die with that subshell.
classify_outcome() {
    if [ "$1" -le 0 ]; then
        printf 'skipped\n'
    elif [ "$2" -eq 124 ]; then
        printf 'timeout\n'
    elif [ "$2" -ne 0 ]; then
        printf 'failed\n'
    else
        printf 'ok\n'
    fi
}

record() {
    # record <event> <agent> <worktree> <detail> [reason]
    #
    # `ts` is stamped HERE, at the moment of the event, not at the run's start:
    # a log where every line carries the start stamp cannot show that a cycle
    # spent its whole budget, or in what order. `budget_remaining` is read at
    # record time, so a line reporting 0 is self-evidently the clock's doing.
    #
    # The subject of a line is the AGENT whose home it is, not a bead — this
    # script never learns a bead id, and inventing one would misdirect anybody
    # who grepped the log for it.
    jq -cn \
        --arg ts "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" \
        --arg run_started "$RUN_STARTED" \
        --arg event "$1" \
        --arg rig "$RIG_NAME" \
        --arg agent "$2" \
        --arg worktree "$3" \
        --arg detail "$4" \
        --arg reason "${5:-}" \
        --argjson budget_remaining "$(budget_left)" \
        --argjson dry_run "$DRY_RUN" \
        '{ts:$ts, run_started:$run_started, event:$event, rig:$rig, agent:$agent,
          worktree:$worktree, detail:$detail, reason:$reason,
          budget_remaining:$budget_remaining, dry_run:($dry_run == 1)}' \
        >>"$LOG_FILE"
    echo "$1 $2 $3${4:+ ($4)}"
}

# Clear metadata for worktrees already removed from disk so the candidate list
# reflects reality rather than stale administrative entries.
run_bounded "$(budget_left)" git -C "$RIG_ROOT" worktree prune >/dev/null 2>&1 || true

WT_LIST_LIMIT=$(budget_left)
WT_LIST_RC=0
WT_LIST=$(run_bounded "$WT_LIST_LIMIT" git -C "$RIG_ROOT" worktree list --porcelain 2>/dev/null) || WT_LIST_RC=$?
WT_LIST_OUTCOME=$(classify_outcome "$WT_LIST_LIMIT" "$WT_LIST_RC")
if [ "$WT_LIST_OUTCOME" != ok ]; then
    # "no polecat homes under $RIG_ROOT" is a claim about the rig. A run that
    # never got the list is not entitled to make it.
    case "$WT_LIST_OUTCOME" in
        skipped)
            record home_budget_truncated "" "" \
                "the ${BUDGET_SECONDS}s budget was spent before the worktree list was read; no candidate was enumerated" \
                budget_spent_before_worktree_list
            echo "polecat-home-audit: budget spent before enumerating worktrees; examined=0 (log: $LOG_FILE)"
            ;;
        timeout)
            record home_worktree_list_failed "" "" \
                "git worktree list did not answer within the ${WT_LIST_LIMIT}s left of the ${BUDGET_SECONDS}s budget" \
                worktree_list_timed_out
            echo "polecat-home-audit: worktree list did not answer within ${WT_LIST_LIMIT}s; examined=0 (log: $LOG_FILE)"
            ;;
        *)
            record home_worktree_list_failed "" "" \
                "git worktree list exited $WT_LIST_RC in $RIG_ROOT" \
                worktree_list_failed
            echo "polecat-home-audit: worktree list failed (exit $WT_LIST_RC); examined=0 (log: $LOG_FILE)"
            ;;
    esac
    exit 0
fi

CANDIDATES=$(printf '%s\n' "$WT_LIST" \
    | sed -n 's/^worktree //p' \
    | while IFS= read -r wt; do
        # Gate 1: polecat AGENT HOME shape. The parent directory must be
        # literally `polecats`, which admits `.../polecats/<agent>` and nothing
        # else — not the per-bead worktrees one level deeper (parent
        # `worktrees`, and polecat-worktree-reap.sh's business), not the rig
        # root, not another agent's worktree.
        case "$wt" in
            */polecats/*) ;;
            *) continue ;;
        esac
        [ "$(basename "$(dirname "$wt")")" = "polecats" ] || continue
        printf '%s\n' "$wt"
    done || true)

if [ -z "$CANDIDATES" ]; then
    echo "polecat-home-audit: no polecat agent homes under $RIG_ROOT"
    exit 0
fi

TOTAL=$(printf '%s\n' "$CANDIDATES" | grep -c . || true)

SESSIONS_FILE=$(mktemp)
trap 'rm -f "$SESSIONS_FILE"' EXIT

# The session roster is the ONLY ownership key here, so it is fetched up front
# rather than lazily: unlike the per-bead reaper, which can decide most
# candidates on bead status alone, every candidate in this sweep needs it.
#
# A roster read that FAILS is not proof the owning session is gone. The state
# starts at `unconfirmed` and is promoted only on a read that exited 0, wrote a
# non-empty file, AND parsed as the expected shape; every failure path then
# falls through to skip-this-home with no route to a removal. That is
# mol-witness-patrol's absent-confirm discipline (gcp-g98): a confirmation read
# that fails is not proof of absence.
ROSTER_STATE="unconfirmed"
ROSTER_REASON="roster_read_failed"

ROSTER_LIMIT=$(budget_left)
ROSTER_RC=0
run_bounded "$ROSTER_LIMIT" gc session list --state=all --json >"$SESSIONS_FILE" 2>/dev/null || ROSTER_RC=$?
case "$(classify_outcome "$ROSTER_LIMIT" "$ROSTER_RC")" in
    skipped) ROSTER_REASON="budget_spent_before_roster_read" ;;
    timeout) ROSTER_REASON="roster_read_timed_out" ;;
    failed) ROSTER_REASON="roster_read_failed" ;;
    *)
        # `gc session list --json` returns an OBJECT ({sessions:[...]}), not a
        # top-level array, and its fields are lowercase snake_case — the same
        # schema facts mol-witness-patrol's liveness map depends on.
        if [ -s "$SESSIONS_FILE" ] && jq -e '(.sessions | type) == "array"' "$SESSIONS_FILE" >/dev/null 2>&1; then
            ROSTER_STATE="readable"
            ROSTER_REASON=""
        else
            ROSTER_REASON="roster_unparseable"
        fi
        ;;
esac

if [ "$ROSTER_STATE" != readable ]; then
    # The roster is the ONLY ownership key here, so a run without it cannot
    # decide a single candidate — the same shape the per-bead reaper takes when
    # its one bulk bead read comes back unusable. Report it once, at run level,
    # and stop: a per-candidate line would repeat one fact $TOTAL times and
    # still say nothing more. Reported, never inferred — an unreadable roster
    # is not an empty one, and treating it as empty is how a sweep concludes
    # that nobody owns anything and removes every home on the rig.
    case "$ROSTER_REASON" in
        budget_spent_before_roster_read)
            record home_budget_truncated "" "" \
                "the ${BUDGET_SECONDS}s budget was spent before the session roster was read; 0 of $TOTAL candidate(s) examined, $TOTAL deferred" \
                "$ROSTER_REASON"
            echo "polecat-home-audit: budget spent before the roster read; examined=0 deferred=$TOTAL of $TOTAL (log: $LOG_FILE)"
            ;;
        roster_read_timed_out)
            record home_roster_unreadable "" "" \
                "gc session list did not answer within the ${ROSTER_LIMIT}s left of the ${BUDGET_SECONDS}s budget; a read cut short is not proof of absence" \
                "$ROSTER_REASON"
            echo "polecat-home-audit: roster read timed out after ${ROSTER_LIMIT}s of the ${BUDGET_SECONDS}s budget; examined=0 of $TOTAL (log: $LOG_FILE)"
            ;;
        *)
            record home_roster_unreadable "" "" \
                "session roster unreadable ($ROSTER_REASON); a failed read is not proof of absence" \
                "$ROSTER_REASON"
            echo "polecat-home-audit: roster unreadable ($ROSTER_REASON); examined=0 of $TOTAL (log: $LOG_FILE)"
            ;;
    esac
    exit 0
fi

# Prints the liveness verdict for a home:
#   live        — a session that is not closed occupies this home
#   absent      — the roster was read and holds no live occupant
#   unconfirmed — this home's query did not answer; NOT proof of absence
#
# Two keys, because either alone has a hole. `work_dir` is the session's own
# statement of which directory it occupies and is exact — the live roster
# records `/…/.gc/worktrees/<rig>/polecats/<agent>` verbatim. The
# `<rig>/<agent>` name derived from the path covers a session recorded with a
# different work_dir shape (a resumed session, a provider that rewrote it).
# Matching either way is deliberately generous: an extra match defers a home,
# and deferring is the safe direction.
session_state() {
    local home="$1" name="$2" verdict
    if ! verdict=$(jq -r --arg home "$home" --arg name "$name" '
        (.sessions // [])
        | map(select(.closed != true))
        | map(select(
            ((.work_dir // "") == $home)
            or ((.name // "") == $name) or ((.alias // "") == $name)
            or ((.agent_name // "") == $name) or ((.title // "") == $name)))
        | if length > 0 then "live" else "absent" end
    ' "$SESSIONS_FILE" 2>/dev/null); then
        printf 'unconfirmed\n'
        return
    fi
    case "$verdict" in
        live | absent) printf '%s\n' "$verdict" ;;
        *) printf 'unconfirmed\n' ;;
    esac
}

REMOVED=0
SKIPPED=0
EXAMINED=0
BUDGET_SPENT=0
# Set when a home was skipped because a check was never attempted — the run's
# own clock, not the subsystem the skipped check would have talked to.
TRUNCATED=0

while IFS= read -r WT; do
    [ -n "$WT" ] || continue

    # Yield rather than stall the patrol. What is left unexamined stays a
    # candidate for the next cycle; the sweep is idempotent.
    if [ "$(budget_left)" -le 0 ]; then
        BUDGET_SPENT=1
        record home_budget_exhausted "" "" \
            "${BUDGET_SECONDS}s budget spent after $EXAMINED of $TOTAL candidate(s): removed=$REMOVED skipped=$SKIPPED deferred=$((TOTAL - EXAMINED))" \
            budget_exhausted
        break
    fi
    EXAMINED=$((EXAMINED + 1))

    # .../worktrees/<rig>/polecats/<agent> — the agent is the leaf and the rig
    # segment is two levels up. Derived from the path rather than from $RIG_NAME
    # so the roster key is the one the session actually records, which is the
    # city's rig name even when this run was given a different --rig label.
    AGENT=$(basename "$WT")
    RIG_SEGMENT=$(basename "$(dirname "$(dirname "$WT")")")
    ROSTER_NAME="$RIG_SEGMENT/$AGENT"

    # Gate 2: a live session owns its home. Nothing else about it matters, and
    # nothing is logged — a polecat occupying its own home is the ordinary
    # state of a healthy rig, so a line per live agent per cycle would bury the
    # findings this log exists for.
    case "$(session_state "$WT" "$ROSTER_NAME")" in
        live)
            SKIPPED=$((SKIPPED + 1))
            continue
            ;;
        unconfirmed)
            # The roster parsed, so this is a query that did not answer for
            # this one home. Unreachable in practice, and kept anyway: the
            # alternative to a skip here is treating a broken query as proof
            # that nobody owns the home.
            record home_owner_unconfirmed "$AGENT" "$WT" \
                "the session roster parsed but the liveness query for this home did not answer; not proof of absence" \
                roster_query_failed
            SKIPPED=$((SKIPPED + 1))
            continue
            ;;
    esac

    # A home can be undisposable for two INDEPENDENT reasons — it holds lost
    # work, or it hosts per-bead children — and the two verdicts must not
    # compete for the one skip. KEEP records "not removable this cycle"; every
    # gate that sets it has already recorded its own verdict, and the single
    # skip after the gates counts the home once.
    KEEP=0

    # Gate 3a: never discard uncommitted work. Ignored files are build
    # artifacts and are excluded by `git status --porcelain`; untracked
    # non-ignored files are reported and block removal so the witness can
    # salvage them. This is the check a respawned namepool slot fails on.
    STATUS_LIMIT=$(budget_left)
    STATUS_RC=0
    DIRTY=$(run_bounded "$STATUS_LIMIT" git -C "$WT" status --porcelain 2>/dev/null) || STATUS_RC=$?
    STATUS_OUTCOME=$(classify_outcome "$STATUS_LIMIT" "$STATUS_RC")
    if [ "$STATUS_OUTCOME" != ok ]; then
        # A worktree git cannot read is not one to delete on a guess — and
        # neither is one git was never asked about. Different incidents,
        # different owners, so different events.
        case "$STATUS_OUTCOME" in
            skipped)
                TRUNCATED=1
                record home_budget_truncated "$AGENT" "$WT" \
                    "the ${BUDGET_SECONDS}s budget was spent before git status ran; the home was never inspected, at candidate $EXAMINED of $TOTAL" \
                    budget_spent_before_git_status
                ;;
            timeout)
                record home_status_unreadable "$AGENT" "$WT" \
                    "git status did not answer within the ${STATUS_LIMIT}s left of the ${BUDGET_SECONDS}s budget" \
                    git_status_timed_out
                ;;
            *)
                record home_status_unreadable "$AGENT" "$WT" \
                    "git status exited $STATUS_RC in the home worktree" \
                    git_status_failed
                ;;
        esac
        SKIPPED=$((SKIPPED + 1))
        continue
    fi
    if [ -n "$DIRTY" ]; then
        record home_dirty_kept "$AGENT" "$WT" \
            "$(printf '%s\n' "$DIRTY" | wc -l | tr -d ' ') uncommitted path(s)" \
            uncommitted_work
        KEEP=1
    fi

    # Gate 3b: commits reachable from HEAD but from no remote-tracking ref.
    # The per-bead reaper deliberately does NOT make this check, because a
    # rebase-merging refinery rewrites hashes and a closed bead is its own
    # proof the work landed. A home has no bead, so nothing else here can say
    # the commits are safe — and the furiosa home was on a detached HEAD
    # holding two of them. Establishing they were superseded took reading
    # content at origin, which a sweep must not attempt on its own, so this
    # reports and defers to the witness.
    #
    # A rig with stale remote-tracking refs over-reports, which defers a home.
    # That is the safe direction and needs no fetch — a sweep that reached the
    # network would be an unbounded call in a bounded step.
    HEAD_REF=$(git -C "$WT" symbolic-ref -q --short HEAD 2>/dev/null || true)
    UNPUSHED_LIMIT=$(budget_left)
    UNPUSHED_RC=0
    UNPUSHED=$(run_bounded "$UNPUSHED_LIMIT" git -C "$WT" rev-list --count HEAD --not --remotes 2>/dev/null) || UNPUSHED_RC=$?
    UNPUSHED_OUTCOME=$(classify_outcome "$UNPUSHED_LIMIT" "$UNPUSHED_RC")
    if [ "$UNPUSHED_OUTCOME" != ok ]; then
        case "$UNPUSHED_OUTCOME" in
            skipped)
                TRUNCATED=1
                record home_budget_truncated "$AGENT" "$WT" \
                    "the ${BUDGET_SECONDS}s budget was spent before the unpublished-commit check ran, at candidate $EXAMINED of $TOTAL" \
                    budget_spent_before_commit_check
                ;;
            timeout)
                record home_commits_unreadable "$AGENT" "$WT" \
                    "git rev-list did not answer within the ${UNPUSHED_LIMIT}s left of the ${BUDGET_SECONDS}s budget" \
                    rev_list_timed_out
                ;;
            *)
                record home_commits_unreadable "$AGENT" "$WT" \
                    "git rev-list exited $UNPUSHED_RC in the home worktree" \
                    rev_list_failed
                ;;
        esac
        SKIPPED=$((SKIPPED + 1))
        continue
    fi
    if [ "${UNPUSHED:-0}" != 0 ]; then
        record home_unpublished_commits_kept "$AGENT" "$WT" \
            "$UNPUSHED commit(s) on ${HEAD_REF:-a detached HEAD} reach no remote; whether they are superseded needs a content check at origin, which this sweep does not make" \
            unpublished_commits
        KEEP=1
    fi

    # Gate 4: THE TRAP. A home whose subtree holds per-bead worktrees is not
    # disposable no matter who owns the home itself — when this was filed, a
    # LIVE polecat from another namepool slot was working inside a dead home's
    # `worktrees/`. Any child at all defers, because establishing that a child
    # is dead means reading its bead, and bead-keyed guards are what this
    # script exists to stop relying on. The per-bead reaper owns children; once
    # it has cleared them the home becomes eligible.
    #
    # This gate governs TEARDOWN ONLY, which is why it runs after the reports
    # above rather than before them (gcp-fzjo). It used to come first and skip
    # the rest of the loop, which coupled lost-work reporting to unrelated
    # per-bead state: a home with any child was never reached by 3a/3b, so its
    # dirt stayed invisible for as long as the children lived — and the reaper
    # correctly keeps a child whose bead is still open, which can be a long
    # time. The two facts are not mutually exclusive: gastown.nux emitted
    # `home_dirty_kept` on 2026-08-27 and 08-28, then went silent the moment
    # children appeared, with the same uncommitted path still on disk.
    CHILD_COUNT=0
    if [ -d "$WT/worktrees" ]; then
        for child in "$WT"/worktrees/*; do
            [ -e "$child" ] || continue
            CHILD_COUNT=$((CHILD_COUNT + 1))
        done
    fi
    if [ "$CHILD_COUNT" -gt 0 ]; then
        record home_children_kept "$AGENT" "$WT" \
            "$CHILD_COUNT per-bead worktree(s) live under this home; teardown of the home would take them with it" \
            has_child_worktrees
        KEEP=1
    fi

    if [ "$KEEP" -eq 1 ]; then
        SKIPPED=$((SKIPPED + 1))
        continue
    fi

    if [ "$DRY_RUN" -eq 1 ]; then
        record home_removal_pending "$AGENT" "$WT" "dry run"
        REMOVED=$((REMOVED + 1))
        continue
    fi

    if ! run_bounded "$(budget_left)" git -C "$RIG_ROOT" worktree remove --force "$WT" >/dev/null 2>&1; then
        # Fallback for a worktree git refuses to administer (moved, partially
        # deleted). Removing the directory then pruning restores consistency.
        rm -rf "$WT"
    fi
    run_bounded "$(budget_left)" git -C "$RIG_ROOT" worktree prune >/dev/null 2>&1 || true

    if [ -e "$WT" ]; then
        record home_removal_failed "$AGENT" "$WT" "directory still present after removal"
        SKIPPED=$((SKIPPED + 1))
        continue
    fi

    record home_removed "$AGENT" "$WT" "no live session, no child worktrees, nothing unpublished"
    REMOVED=$((REMOVED + 1))
done <<EOF
$CANDIDATES
EOF

# The stdout summary is what a patrol reads first, so it must not imply a clean
# cycle when the clock cut one short — including when the truncation landed on
# the LAST candidate and the loop head therefore never fired.
BUDGET_NOTE=""
if [ "$BUDGET_SPENT" -eq 1 ] || [ "$TRUNCATED" -eq 1 ]; then
    BUDGET_NOTE=" — budget spent: examined=$EXAMINED of $TOTAL, $((TOTAL - EXAMINED)) candidate(s) deferred to the next cycle"
fi

if [ "$DRY_RUN" -eq 1 ]; then
    echo "polecat-home-audit: would remove=$REMOVED skipped=$SKIPPED of $TOTAL (dry run — nothing removed; pass --no-dry-run to remove; log: $LOG_FILE)$BUDGET_NOTE"
else
    echo "polecat-home-audit: removed=$REMOVED skipped=$SKIPPED of $TOTAL (log: $LOG_FILE)$BUDGET_NOTE"
fi
