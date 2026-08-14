#!/usr/bin/env bash
# polecat-worktree-reap.sh — reap per-bead polecat worktrees once their bead closes.
#
# The leak this closes:
#   mol-polecat-work's workspace-setup creates ONE worktree per work bead at
#   <polecat-home>/worktrees/<bead-id> and records it in metadata.work_dir.
#   mol-witness-patrol's orphan recovery removes those worktrees only for
#   ORPHANED (still in_progress) beads. The happy path — refinery merges,
#   closes the bead, polecat drains — had no teardown owner, so every
#   completed bead left its worktree on disk forever.
#
# Ownership: the witness. It is the only agent alive at the right moment for
# both merge strategies:
#   - direct: the refinery merges, closes the bead, and exits; the polecat is
#             already gone, so neither can do the teardown.
#   - mr/pr:  the refinery closes the bead when the PR is created, but the
#             polecat stays available for FIX_NEEDED rework. The session
#             liveness gate below defers the reap until that polecat drains.
#
# Safety gates — ALL must hold before a worktree is removed:
#   1. Path shape is a per-bead polecat worktree: .../polecats/<agent>/worktrees/<bead-id>.
#      A polecat's persistent agent-home worktree has no `worktrees/` parent
#      segment, so it is never a candidate.
#   2. The bead is `closed`. The refinery closes only after a verified merge or
#      a verified PR handoff, so the committed work is canonical elsewhere.
#   3. `git status --porcelain` is empty — nothing uncommitted would be lost.
#      Ignored files are build artifacts and do not block; untracked
#      non-ignored files do.
#   4. The session roster confirms no live session owns the bead
#      (metadata.polecat_session). A roster read that fails or does not parse
#      is `unconfirmed`, not `absent`, and skips the reap.
#
# COST MODEL — why this script is shaped the way it is (gcp-ntbf):
#   It runs as the witness pre_start, which gascity bounds by [session]
#   setup_timeout (10s by default) and SIGKILLs on overrun. A killed pre_start
#   fails the whole session start, and after six such failures in an hour the
#   supervisor's circuit breaker latches OPEN and stops respawning entirely —
#   winnow's witness was dead for 26h that way, with no health monitor on the
#   city's busiest rig. Housekeeping must be structurally incapable of
#   preventing the witness from starting, so:
#     - Bead status for EVERY candidate is fetched in ONE bulk `gc bd show`.
#       The per-worktree `gc bd show` this replaced cost ~5.4s per call against
#       an external Dolt, which is ~7 minutes across winnow's 81 candidates —
#       not slow, impossible. Candidate sets only grow (the reaper is staged at
#       dry-run and the native gascity reaper is a documented macOS no-op,
#       gc-zxxy), so a per-item round trip is a cliff every rig walks toward.
#     - The script enforces its OWN wall-clock budget, well inside the caller's,
#       and every external command is bounded by the time remaining in it. When
#       the budget expires the script reports what it examined and exits 0. A
#       reaper that runs out of time must YIELD THE START, not lose a race with
#       SIGKILL. Reaping fewer worktrees per cycle is free; the work is
#       idempotent and the next cycle resumes it.
#
# Staged rollout: REAL REMOVAL IS OPT-IN. The script dry-runs unless it is
# given --no-dry-run, and the witness pre_start wiring deliberately does not
# pass it. The city holds the native gascity reaper to the same staged rollout
# (city.toml, auto_reap_closed_bead_worktrees_dry_run) until gc-zxxy is
# answered; a second reaper must not go live while the first is held inert.
# Flip it by adding --no-dry-run to the pre_start in agents/witness/agent.toml
# once the logged would-reap set has been reviewed across several cycles.
#
# Deliberately NOT gated on "every commit is on a remote": a rebase-merging
# refinery rewrites commit hashes and then deletes the merged branch, so a
# genuinely merged worktree always looks like it holds unpublished commits.
# Bead closure is the refinery's own proof that the work landed.
#
# Output: one JSON line per decision appended to LOG_FILE, plus a human
# summary on stdout. Idempotent and safe to re-run: a reaped worktree stops
# being a candidate, so the work set shrinks to nothing.
#
# Env / args:
#   $1 | GC_RIG_ROOT   rig repo root (default: `git rev-parse --show-toplevel`)
#   --rig <name>       rig name — scopes `gc bd`. Defaults to $GC_RIG. Needed
#                      because pre_start runs before the session environment
#                      exists, so $GC_RIG cannot be assumed there.
#   LOG_DIR            where to write the log. Defaults to the city runtime log
#                      directory; NEVER defaults inside the rig repo, which
#                      would litter the canonical checkout with untracked files.
#   --dry-run          report what would be reaped, remove nothing (the default)
#   --no-dry-run       opt in to real removal
#   --budget <secs> | GC_REAP_BUDGET_SECONDS
#                      wall-clock budget for the whole run (default 8s). Must
#                      stay well inside the caller's [session] setup_timeout;
#                      raise it only alongside a matching setup_timeout bump.
#
# Usage:
#   GC_RIG=helm polecat-worktree-reap.sh                    # dry run
#   polecat-worktree-reap.sh /path/to/rig --rig helm --no-dry-run

set -euo pipefail

# Dry run is the default; real removal must be asked for. See the staged
# rollout note in the header.
DRY_RUN=1
RIG_ROOT=""
RIG_NAME="${GC_RIG:-}"
# Well inside gascity's 10s default [session] setup_timeout — see COST MODEL.
BUDGET_SECONDS="${GC_REAP_BUDGET_SECONDS:-8}"

while [ "$#" -gt 0 ]; do
    case "$1" in
        --dry-run) DRY_RUN=1 ;;
        --no-dry-run) DRY_RUN=0 ;;
        --rig)
            shift
            [ "$#" -gt 0 ] || { echo "polecat-worktree-reap: --rig needs a value" >&2; exit 2; }
            RIG_NAME="$1"
            ;;
        --budget)
            shift
            [ "$#" -gt 0 ] || { echo "polecat-worktree-reap: --budget needs a value" >&2; exit 2; }
            BUDGET_SECONDS="$1"
            ;;
        -*) echo "polecat-worktree-reap: unknown flag $1" >&2; exit 2 ;;
        *) RIG_ROOT="$1" ;;
    esac
    shift
done

case "$BUDGET_SECONDS" in
    '' | *[!0-9]* | 0)
        echo "polecat-worktree-reap: budget must be a positive whole number of seconds" >&2
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
    echo "polecat-worktree-reap: rig root not found (pass it as \$1 or set GC_RIG_ROOT)" >&2
    exit 2
fi

# Log destination, in descending order of confidence. The rig repo is
# deliberately absent from this list: the reaper must never leave untracked
# files in the canonical checkout it is cleaning up around.
if [ -n "${LOG_DIR:-}" ]; then
    :
elif [ -n "${GC_CITY_RUNTIME_DIR:-}" ]; then
    LOG_DIR="$GC_CITY_RUNTIME_DIR/logs"
elif [ -n "${GC_CITY:-}" ]; then
    LOG_DIR="$GC_CITY/.gc/runtime/logs"
else
    LOG_DIR="${TMPDIR:-/tmp}/gc-polecat-worktree-reap"
fi
LOG_FILE="$LOG_DIR/polecat-worktree-reap.log"
# Housekeeping must never block the witness from starting: this script runs as
# the witness pre_start, so every failure below degrades to a clean exit 0.
if ! mkdir -p "$LOG_DIR" 2>/dev/null || ! touch "$LOG_FILE" 2>/dev/null; then
    echo "polecat-worktree-reap: cannot write $LOG_FILE; skipping this run" >&2
    exit 0
fi

TS=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
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
# The fallback matters: coreutils `timeout` is not on a stock macOS, and a
# pre_start that cannot bound its own children is precisely the failure this
# script exists to prevent. So the fallback actually kills rather than merely
# giving up on waiting.
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

# `gc bd` is rig-scoped when a rig name is known; keep the unscoped form working
# so the script is still runnable by hand from inside a rig repo. Held as an
# argv array rather than a function because run_bounded/timeout runs a real
# command, not a shell function.
if [ -n "$RIG_NAME" ]; then
    GC_BD=(gc bd --rig "$RIG_NAME")
else
    GC_BD=(gc bd)
fi

record() {
    # record <event> <bead> <worktree> <detail>
    jq -cn \
        --arg ts "$TS" \
        --arg event "$1" \
        --arg rig "$RIG_NAME" \
        --arg bead "$2" \
        --arg worktree "$3" \
        --arg detail "$4" \
        --argjson dry_run "$DRY_RUN" \
        '{ts:$ts, event:$event, rig:$rig, bead:$bead, worktree:$worktree, detail:$detail, dry_run:($dry_run == 1)}' \
        >>"$LOG_FILE"
    echo "$1 $2 $3${4:+ ($4)}"
}

# Clear metadata for worktrees already removed from disk so the candidate list
# reflects reality rather than stale administrative entries.
run_bounded "$(budget_left)" git -C "$RIG_ROOT" worktree prune >/dev/null 2>&1 || true

WT_LIST=$(run_bounded "$(budget_left)" git -C "$RIG_ROOT" worktree list --porcelain 2>/dev/null || true)
CANDIDATES=$(printf '%s\n' "$WT_LIST" \
    | sed -n 's/^worktree //p' \
    | while IFS= read -r wt; do
        # Gate 1: per-bead polecat worktree shape. The parent directory must be
        # literally `worktrees` and the path must sit under a `polecats` tree —
        # that excludes the polecat's own persistent agent-home worktree, the
        # rig root, and the refinery's temporary merge worktree.
        case "$wt" in
            */polecats/*/worktrees/*) ;;
            *) continue ;;
        esac
        [ "$(basename "$(dirname "$wt")")" = "worktrees" ] || continue
        # The leaf is the bead id. Anything else is not ours to remove.
        case "$(basename "$wt")" in
            *[!a-zA-Z0-9-]* | '' | -* | *-) continue ;;
        esac
        printf '%s\n' "$wt"
    done || true)

if [ -z "$CANDIDATES" ]; then
    echo "polecat-worktree-reap: no per-bead polecat worktrees under $RIG_ROOT"
    exit 0
fi

TOTAL=$(printf '%s\n' "$CANDIDATES" | grep -c . || true)

# ONE bead read for the whole candidate set. `gc bd show` takes many ids and
# answers in a single round trip, so the cost of this step is flat in the
# number of worktrees instead of linear in it — the entire point of gcp-ntbf.
#
# Unknown ids are reported on stderr and simply omitted from the array, so a
# stale worktree does not poison the batch. Results are keyed back by the id
# the store ECHOED, not by the id we asked for: the lookup fuzzy-matches, and
# a fuzzy hit would otherwise let one worktree inherit a different bead's status.
# An id with no exact echo lands in the same "unreadable" bucket as before.
BEAD_IDS_ARGV=()
while IFS= read -r bead_id; do
    if [ -n "$bead_id" ]; then
        BEAD_IDS_ARGV+=("$bead_id")
    fi
done <<EOF
$(printf '%s\n' "$CANDIDATES" | while IFS= read -r wt; do
    if [ -n "$wt" ]; then basename "$wt"; fi
done | sort -u)
EOF

# Straight to a file, never to a variable: bead descriptions run to kilobytes
# apiece, and handing dozens of them to jq as an --argjson would put the whole
# payload in argv, where a large candidate set trips ARG_MAX. That failure is
# silent — jq never runs, the join comes back empty, and the summary reports a
# clean cycle that examined nothing.
BEADS_FILE=$(mktemp)
SESSIONS_FILE=$(mktemp)
trap 'rm -f "$BEADS_FILE" "$SESSIONS_FILE"' EXIT

run_bounded "$(budget_left)" "${GC_BD[@]}" show "${BEAD_IDS_ARGV[@]}" --json \
    >"$BEADS_FILE" 2>/dev/null || true

if ! jq -e 'type == "array"' "$BEADS_FILE" >/dev/null 2>&1; then
    # No usable answer for ANY bead — the store is unreachable, too slow, or
    # spoke a shape we do not recognise. An unreadable bead is not proof the
    # work is done, so nothing is a candidate for removal this cycle.
    record worktree_bead_query_failed "" "" \
        "bulk gc bd show returned no usable JSON for ${#BEAD_IDS_ARGV[@]} bead(s)"
    echo "polecat-worktree-reap: bead query failed or timed out; reaped=0 skipped=$TOTAL (log: $LOG_FILE)"
    exit 0
fi

# Join the candidate paths to their bead facts once, in jq, so the loop below
# does no per-worktree querying at all: <status>US<owner>US<worktree>, where US
# is the ASCII unit separator. Deliberately not @tsv: tab is an IFS WHITESPACE
# character, so `read` silently collapses the empty leading fields an unreadable
# bead produces and shifts the path into $STATUS. US is neither whitespace nor
# legal in a bead id or a path, so every field survives, empty or not.
DECISIONS=$(printf '%s\n' "$CANDIDATES" | jq -R -r -s --slurpfile bead_docs "$BEADS_FILE" '
    ( ($bead_docs[0] // [])
      | map(select(type == "object"))
      | map({ key:   (.id // "" | tostring),
              value: { status: (.status // "" | tostring),
                       owner:  (.metadata.polecat_session? // "" | tostring) } })
      | from_entries ) as $by
    | split("\n")
    | map(select(length > 0))
    | .[]
    | . as $wt
    | ($by[($wt | split("/") | last)] // { status: "", owner: "" }) as $bead
    | [ $bead.status, $bead.owner, $wt ] | join("\u001f")
' 2>/dev/null || true)

# Session roster, fetched at most once and only when a closed bead actually
# needs it — on a rig whose candidates are all still open it is pure cost.
# `gc session list --json` returns an OBJECT ({sessions:[...]}), not a
# top-level array, and its fields are lowercase snake_case — same schema facts
# mol-witness-patrol's liveness map depends on.
#
# A roster read that FAILS is not proof the owning session is gone. Seed the
# roster state to `unconfirmed` and promote it only on a read that exited 0,
# wrote a non-empty file, AND parsed as the expected shape; every failure path
# then falls through to skip-this-worktree with no route to a removal. This is
# mol-witness-patrol's absent-confirm discipline (gcp-g98) applied to the same
# subsystem: a confirmation read that fails is not proof of absence. A read cut
# short by the budget is one more way to land in `unconfirmed`.
ROSTER_STATE="unconfirmed"
ROSTER_FETCHED=0

ensure_roster() {
    if [ "$ROSTER_FETCHED" -eq 1 ]; then
        return
    fi
    ROSTER_FETCHED=1
    if run_bounded "$(budget_left)" gc session list --state=all --json >"$SESSIONS_FILE" 2>/dev/null &&
        [ -s "$SESSIONS_FILE" ] &&
        jq -e '(.sessions | type) == "array"' "$SESSIONS_FILE" >/dev/null 2>&1; then
        ROSTER_STATE="readable"
    fi
}

# Prints the liveness verdict for a bead's owning session:
#   live        — a matching session exists and is not closed
#   absent      — the roster was read and holds no live match
#   unconfirmed — the roster could not be read or parsed; NOT proof of absence
session_state() {
    local owner="$1" verdict
    if [ "$ROSTER_STATE" != "readable" ]; then
        printf 'unconfirmed\n'
        return
    fi
    if [ -z "$owner" ]; then
        # No owner stamped on the bead, so there is no session to confirm and
        # the gate does not apply. Beads predating the polecat_session stamp
        # take this path; the other three gates still bind.
        printf 'absent\n'
        return
    fi
    if ! verdict=$(jq -r --arg id "$owner" '
        (.sessions // [])
        | map(select(
            (.id // "") == $id or (.name // "") == $id or
            (.session_name // "") == $id or (.alias // "") == $id or
            (.agent_name // "") == $id))
        | if any(.closed != true) then "live" else "absent" end
    ' "$SESSIONS_FILE" 2>/dev/null); then
        printf 'unconfirmed\n'
        return
    fi
    case "$verdict" in
        live | absent) printf '%s\n' "$verdict" ;;
        *) printf 'unconfirmed\n' ;;
    esac
}

REAPED=0
SKIPPED=0
EXAMINED=0
BUDGET_SPENT=0

while IFS=$'\037' read -r STATUS OWNER WT; do
    [ -n "$WT" ] || continue

    # Yield the start rather than lose a race with SIGKILL. What is left
    # unexamined stays a candidate for the next cycle; the work is idempotent.
    if [ "$(budget_left)" -le 0 ]; then
        BUDGET_SPENT=1
        record worktree_budget_exhausted "" "" \
            "${BUDGET_SECONDS}s budget spent after $EXAMINED of $TOTAL candidate(s); yielding the witness start"
        break
    fi
    EXAMINED=$((EXAMINED + 1))

    BEAD=$(basename "$WT")

    if [ -z "$STATUS" ]; then
        # An unreadable bead is not proof the work is done. Leave the worktree
        # alone; a later cycle retries once bd is readable again.
        record worktree_bead_unreadable "$BEAD" "$WT" "bulk gc bd show returned no status"
        SKIPPED=$((SKIPPED + 1))
        continue
    fi

    # Gate 2: only closed beads. in_progress/open worktrees belong to a live
    # polecat, or to the orphan-recovery path in mol-witness-patrol.
    if [ "$STATUS" != "closed" ]; then
        SKIPPED=$((SKIPPED + 1))
        continue
    fi

    # Gate 4: a polecat still reworking a FIX_NEEDED PR keeps its worktree even
    # though the bead is already closed by the PR handoff. A roster we could not
    # read tells us nothing about that polecat, so it skips too.
    ensure_roster
    case "$(session_state "$OWNER")" in
        live)
            record worktree_owner_live "$BEAD" "$WT" "session $OWNER still live"
            SKIPPED=$((SKIPPED + 1))
            continue
            ;;
        unconfirmed)
            record worktree_owner_unconfirmed "$BEAD" "$WT" \
                "session roster unreadable; a failed read is not proof of absence"
            SKIPPED=$((SKIPPED + 1))
            continue
            ;;
    esac

    # Gate 3: never discard uncommitted work. Ignored files are artifacts and
    # are excluded by `git status --porcelain`; untracked non-ignored files are
    # reported and block the reap so the witness can salvage them.
    if ! DIRTY=$(run_bounded "$(budget_left)" git -C "$WT" status --porcelain 2>/dev/null); then
        # A worktree git cannot even read — or cannot read in the time left —
        # is not one to delete on a guess.
        record worktree_status_unreadable "$BEAD" "$WT" "git status failed in the worktree"
        SKIPPED=$((SKIPPED + 1))
        continue
    fi
    if [ -n "$DIRTY" ]; then
        record worktree_dirty_kept "$BEAD" "$WT" \
            "$(printf '%s\n' "$DIRTY" | wc -l | tr -d ' ') uncommitted path(s)"
        SKIPPED=$((SKIPPED + 1))
        continue
    fi

    if [ "$DRY_RUN" -eq 1 ]; then
        record worktree_reap_pending "$BEAD" "$WT" "dry run"
        REAPED=$((REAPED + 1))
        continue
    fi

    if ! run_bounded "$(budget_left)" git -C "$RIG_ROOT" worktree remove --force "$WT" >/dev/null 2>&1; then
        # Fallback for a worktree git refuses to administer (moved, partially
        # deleted). Removing the directory then pruning restores consistency.
        rm -rf "$WT"
    fi
    run_bounded "$(budget_left)" git -C "$RIG_ROOT" worktree prune >/dev/null 2>&1 || true

    if [ -e "$WT" ]; then
        record worktree_reap_failed "$BEAD" "$WT" "directory still present after removal"
        SKIPPED=$((SKIPPED + 1))
        continue
    fi

    record worktree_reaped "$BEAD" "$WT" "bead closed"
    REAPED=$((REAPED + 1))
done <<EOF
$DECISIONS
EOF

BUDGET_NOTE=""
if [ "$BUDGET_SPENT" -eq 1 ]; then
    BUDGET_NOTE=" — budget spent, $((TOTAL - EXAMINED)) candidate(s) deferred to the next cycle"
fi

if [ "$DRY_RUN" -eq 1 ]; then
    echo "polecat-worktree-reap: would reap=$REAPED skipped=$SKIPPED of $TOTAL (dry run — nothing removed; pass --no-dry-run to reap; log: $LOG_FILE)$BUDGET_NOTE"
else
    echo "polecat-worktree-reap: reaped=$REAPED skipped=$SKIPPED of $TOTAL (log: $LOG_FILE)$BUDGET_NOTE"
fi
