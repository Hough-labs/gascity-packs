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
#   1. Path shape is a per-bead worktree: <agent-home>/worktrees/<bead-id>.
#      An agent's persistent home worktree has no `worktrees/` parent segment,
#      so it is never a candidate. The LANE TREE the home sits in — `polecats`,
#      `views`, whatever gascity names next — is deliberately NOT part of the
#      test; see THE LANE-TREE BLIND SPOT below.
#   2. The bead is `closed`. The refinery closes only after a verified merge or
#      a verified PR handoff, so the committed work is canonical elsewhere.
#   3. `git status --porcelain` is empty — nothing uncommitted would be lost.
#      Ignored files are build artifacts and do not block; untracked
#      non-ignored files do.
#   4. The session roster confirms no live session owns the bead
#      (metadata.polecat_session). A roster read that fails or does not parse
#      is `unconfirmed`, not `absent`, and skips the reap.
#
# THE OTHER REMOVAL AUTHORITY — a path with no bead at all (gcp-0u14):
#   Not every leaf under `worktrees/` is a bead id. `g7nf-base` was hand-made
#   by an agent, and `gc bd show` answers "no issue found matching" for it
#   forever. Treating that as a transient store failure retried it every cycle
#   for as long as the directory existed, and an unreapable child pins its
#   parent polecat home open just as long. So the two conditions are separated
#   on bd's OWN error class, never on a regex guess at id shape:
#     - bd could not answer (error, timeout, fuzzy hit, id absent from a batch
#       bd said nothing about) -> TRANSIENT. Skip, retry next cycle. Unchanged.
#     - bd answered "no issue found matching <id>" -> PERMANENT. Decide once,
#       on the worktree's own evidence, and log `worktree_no_such_bead`.
#   Gates 2 and 4 need a bead and cannot bind on that path, so it must clear
#   gate 3 plus:
#   5. HEAD is reachable from a remote-tracking ref (`git branch --remotes
#      --contains`) — the content exists somewhere other than this directory.
#      CONFIRMED failure is a FINDING (`worktree_unpublished_kept`), not a
#      retry: the condition never resolves itself, so the witness is told once.
#      A probe that could not run (budget spent, timed out, git errored) is
#      NOT that failure — it is `worktree_publication_unconfirmed` (or a
#      `worktree_budget_truncated` when the clock is what stopped it), kept and
#      re-checked, because an unknown reported as a definite negative sends the
#      witness to salvage already-merged commits (gcp-9ql4).
#
# THE LANE-TREE BLIND SPOT — why gate 1 does not name a tree (gcp-elv3):
#   Gate 1 used to require a `*/polecats/*/worktrees/*` segment on top of the
#   `worktrees/` parent check. gascity does not put every agent home under
#   `polecats/`: a rig running view lanes gets a second tree at
#   `<rig>/views/<view-home>/worktrees/<bead-id>`, whose per-bead worktrees are
#   byte-identical in shape and differ only in the tree name. The glob dropped
#   every one of them BEFORE the bulk bead read and before any `record`, so
#   winnow's 16 view worktrees never produced a single log line — `/views/`
#   appears in 0 of 1293 reap-log entries across all rigs and all time, while
#   `/polecats/` accounts for all 1293. That is the same pre-emission silence
#   that made gcp-ac59 a P1: a view worktree holding genuinely unpublished work
#   emits no `worktree_unpublished_kept` and no `worktree_dirty_kept` either,
#   so the failure mode is undetectable rather than absent.
#
#   The fix is to test the SHAPE and not the tree name. A second `views`
#   literal would only move the blind spot to whatever lane gascity names next,
#   and the tree name is not evidence about the worktree in the first place —
#   `<home>/worktrees/<bead-id>` already says everything the gate needs. What
#   the literal WAS carrying incidentally is the main-worktree exclusion, so
#   that is now named outright rather than left to a path accident.
#
# THE BIASED CUTOFF — why enumeration rotates (gcp-schs):
#   The budget below is a wall clock, and the candidate loop `break`s when it
#   expires. Enumeration is deterministic and sorted, so an unrotated loop drops
#   the SAME sorted tail every single run — never a rotating or random slice.
#   That is not a fairness nicety, it corrupts the evidence the staged rollout
#   is promoted on: the criterion for adding --no-dry-run is a reviewed
#   would-reap set, and under a fixed cutoff the reviewed set can be clean
#   across any number of cycles while part of the candidate set has never been
#   examined once. Those unexamined worktrees are exactly what a live reaper,
#   running with a fresh budget, reaches first.
#
#   Two invariants were on the table (see the bead): rotate the enumeration so
#   the cutoff is unbiased over time, or require a `deferred=0` cycle before the
#   flip is considered evidenced. This script takes BOTH halves of the same
#   idea, because each is weak alone — rotation makes coverage eventually
#   complete but gives an operator nothing to check, and a `deferred=0`
#   requirement is unreachable on a busy rig if every cycle re-walks the same
#   prefix. So:
#     - The start ROTATES. A truncated cycle persists the last candidate it
#       decided, and the next cycle resumes after it, wrapping at the end. The
#       remainder deferred is a moving window, not a fixed tail.
#     - A cycle that examines every candidate says so, once, as
#       `worktree_scan_complete` with `deferred=0`. That line is the thing
#       mol-witness-patrol's promotion criterion is now written against, and
#       rotation is what keeps it reachable.
#   A budget-limited cycle stays non-fatal and still reports `deferred=N`
#   honestly — none of this changes what the reaper removes, only which
#   candidates it looks at first and what the log lets a reader conclude.
#
# THE INTERRUPTED REMOVAL — why the reap renames before it deletes (gcp-mves):
#   This script runs as a pre_start, and a pre_start is SIGKILLed at [session]
#   setup_timeout. That kill cannot be caught, deferred, or bounded from inside
#   the script: run_bounded bounds the CHILDREN, never the process itself.
#
#   `git worktree remove` is not atomic. It drops the worktree's `.git` file and
#   git's admin entry FIRST, then unlinks the tree. A kill in that window leaves
#   a directory that is present on disk, has no `.git`, has no entry in
#   `git worktree list`, and produced NO LOG LINE — the reap report is
#   downstream of the kill. Gate 1 enumerates from `git worktree list`, so the
#   reaper can never see that directory again: the failure is silent AND
#   self-concealing, and the residue accumulates forever. winnow's first armed
#   run stripped 40 worktrees that way and reported none of them (winnow-h0n2o).
#
#   So removal RENAMES FIRST, and every interruption point leaves a state that
#   is either untouched or self-identifying:
#     1. `mv <wt> <wt>.reaping` — a sibling rename inside the same directory, so
#        it is a same-filesystem rename(2) and therefore atomic.
#     2. `git worktree prune` — the admin entry now points at a path that is
#        gone, so prune drops it cleanly.
#     3. `rm -rf <wt>.reaping`.
#   A kill before step 1 leaves the worktree fully intact and still enumerable
#   next cycle. A kill at or after step 1 leaves a `.reaping` directory the next
#   cycle finds and finishes. The SUFFIX is the marker: residue is never
#   inferred from an mtime, which cannot tell a stripped tree from a slow one.
#
# RESIDUE — the second enumeration source (gcp-mves):
#   `git worktree list` structurally cannot enumerate a directory with no admin
#   entry, which is both the shape above and the ~23 directories winnow's armed
#   run already left behind. So the candidate set is the UNION of the admin list
#   and a walk of the rig's own worktree tree, which picks up two shapes:
#     - `*.reaping`, left by an interrupted removal;
#     - a per-bead directory with no `.git` inside and no admin entry — the
#       legacy stripped shape, unmarked because nothing was there to mark it.
#   The walk needs no `find`: every scan root is an `<agent-home>/worktrees`
#   directory the admin list already names, because an agent's own home worktree
#   stays registered even when every one of its per-bead children is gone.
#
#   Residue is not a fast path — it takes the same gates. Gates 1, 2 and 4 apply
#   unchanged. Gate 3 cannot, and this is the trap: `git -C <stripped-dir>
#   status` does NOT fail. With no `.git` of its own git walks UP and answers
#   about the AGENT HOME instead (measured: `?? worktrees/`), so a naive gate
#   would read a verdict about a directory it never looked at. The ceiling is
#   therefore pinned at the candidate's own parent and the reported toplevel
#   must be the candidate itself. Residue git CAN still administer then takes
#   the ordinary clean-tree gate; residue it cannot is recorded as unevaluable
#   and stands on gates 2 and 4. Residue with NO BEAD is kept outright: gate 5
#   carries that path and needs a `git rev-parse HEAD` the directory cannot
#   answer either, so no evidence would be left at all.
#
# THE POINT OF USE — why the gates are re-checked before the rename (gcp-mves):
#   Everything the removal stands on is established earlier in the run: the bead
#   status comes from one bulk read at the top, the roster from a read after it,
#   and the clean-tree check from before gate 5. The rig is live while all of
#   that ages, and a bead can be reopened and a polecat slung onto it inside the
#   seconds a cycle lasts. So the gates that can change underneath the removal
#   are re-checked immediately before the rename, and anything that cannot be
#   RE-CONFIRMED is a refusal rather than a removal.
#
#   This does not reintroduce the N+1 the COST MODEL below removed. `git status`
#   is per-worktree and local, exactly as it already was; the bead and roster
#   re-reads are ONE bulk pair for the whole cycle, taken lazily at the first
#   removal and reused by the rest.
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
# once the log carries a `worktree_scan_complete` cycle (deferred=0 — the
# reviewed set really was the whole candidate set) and no live worktree appeared
# in the would-reap set of that cycle or the ones since. A count of clean
# cycles is NOT the criterion; see THE BIASED CUTOFF below.
#
# The CLOSED-BEAD path is deliberately NOT gated on "every commit is on a
# remote": a rebase-merging refinery rewrites commit hashes and then deletes the
# merged branch, so a genuinely merged worktree always looks like it holds
# unpublished commits. Bead closure is the refinery's own proof that the work
# landed. Gate 5 is not a reversal of that — it binds only on the no-such-bead
# path, which has no closure to stand on and would otherwise have no evidence
# at all.
#
# Output: one JSON line per decision appended to LOG_FILE, plus a human
# summary on stdout. Idempotent and safe to re-run: a reaped worktree stops
# being a candidate, so the work set shrinks to nothing.
#
# LOG SCHEMA — the log is forensics, so every line must be readable on its own
# (gcp-mqu9):
#   ts                 when THIS event happened. Not the run's start time: a
#                      log where every line carries the start stamp cannot show
#                      that a cycle spent eight seconds, or in what order.
#   run_started        the run's start stamp, kept as its own field so lines
#                      can still be grouped into cycles.
#   budget_remaining   seconds left in the run's budget when the line was
#                      written. 0 means the decision was the clock's, not the
#                      subsystem's.
#   reason             machine-readable WHY, because an event name alone cannot
#                      separate "the command ran and failed" from "the command
#                      never ran". Both used to be reported with the same
#                      wording, which sent readers to a healthy Dolt server
#                      twice in one night. `worktree_budget_truncated` is the
#                      never-attempted case and names nothing external.
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
# Where the previous cycle stopped, so this one resumes there instead of
# re-walking the same prefix. See THE BIASED CUTOFF above. One cursor per rig:
# several rigs share the city log directory, and a shared file would have each
# rig rotating the others' enumeration.
CURSOR_SLUG=$(printf '%s' "${RIG_NAME:-_}" | tr -c 'A-Za-z0-9._-' '_')
CURSOR_FILE="$LOG_DIR/polecat-worktree-reap.$CURSOR_SLUG.cursor"
# Housekeeping must never block the witness from starting: this script runs as
# the witness pre_start, so every failure below degrades to a clean exit 0.
if ! mkdir -p "$LOG_DIR" 2>/dev/null || ! touch "$LOG_FILE" 2>/dev/null; then
    echo "polecat-worktree-reap: cannot write $LOG_FILE; skipping this run" >&2
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
# The fallback matters: coreutils `timeout` is not on a stock macOS, and a
# pre_start that cannot bound its own children is precisely the failure this
# script exists to prevent. So the fallback actually kills rather than merely
# giving up on waiting.
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

# `gc bd` is rig-scoped when a rig name is known; keep the unscoped form working
# so the script is still runnable by hand from inside a rig repo. Held as an
# argv array rather than a function because run_bounded/timeout runs a real
# command, not a shell function.
if [ -n "$RIG_NAME" ]; then
    GC_BD=(gc bd --rig "$RIG_NAME")
else
    GC_BD=(gc bd)
fi

# classify_outcome <limit-given> <exit-code> — name what actually happened to a
# bounded call: `skipped` (the budget was already spent, so the command never
# ran), `timeout` (it ran and was killed at the limit), `failed` (it ran and
# exited non-zero), `ok`.
#
# The limit is an argument rather than global state because the git-status call
# site captures stdout in a command substitution, and anything run_bounded set
# about itself would die with that subshell. Passing both halves of the verdict
# down works from any call site.
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

# per_bead_shape <path> — true when <path> has the per-bead worktree shape
# `<worktrees-root>/<rig>/<lane-tree>/<agent-home>/worktrees/<bead-id>`.
#
# ONE definition, used by gate 1 and by the residue walk both. The residue walk
# exists precisely because git's admin list cannot see a half-removed worktree,
# and a second copy of this predicate is how the two enumeration sources would
# drift into disagreeing about what a candidate even is.
#
# The `worktrees` parent excludes an agent's own persistent home. The home shape
# excludes the refinery's merge worktree, which keeps its per-bead directories
# one level higher, at `<rig>/refinery/worktrees/`. That depth is a pack
# invariant, not an observation: the two work_dir templates that produce these
# paths are declared in this same pack — `.gc/worktrees/{{.Rig}}/polecats/
# {{.AgentBase}}` for an agent home and `.gc/worktrees/{{.Rig}}/refinery` for
# the refinery. The LANE TREE name is deliberately not tested: naming it is what
# hid every view worktree from this gate, and naming a second one would only
# move the blind spot (see THE LANE-TREE BLIND SPOT above).
#
# Plain parameter expansion rather than a basename/dirname pipeline: this runs
# for every registered worktree on the rig, and the run has a wall clock to keep.
per_bead_shape() {
    local wt=$1 wt_parent agent_home lane_tree rig_dir worktrees_root
    wt_parent=${wt%/*}                 # <agent-home>/worktrees
    agent_home=${wt_parent%/*}         # <agent-home>
    lane_tree=${agent_home%/*}         # <city>/.gc/worktrees/<rig>/<tree>
    rig_dir=${lane_tree%/*}            # <city>/.gc/worktrees/<rig>
    worktrees_root=${rig_dir%/*}       # <city>/.gc/worktrees
    [ "${wt_parent##*/}" = worktrees ] || return 1
    [ "${lane_tree##*/}" != worktrees ] || return 1
    [ "${worktrees_root##*/}" = worktrees ] || return 1
    return 0
}

# agent_home_shape <path> — true when <path> is an agent's own persistent home
# worktree, `<worktrees-root>/<rig>/<lane-tree>/<agent>`.
#
# A home is never a candidate. It is here because it is the handle on where its
# per-bead children live: a home stays registered with git even when every one
# of those children has been stripped out of the admin list, which is what makes
# the residue walk possible at all.
agent_home_shape() {
    local home=$1 lane_tree rig_dir worktrees_root
    lane_tree=${home%/*}               # <city>/.gc/worktrees/<rig>/<tree>
    rig_dir=${lane_tree%/*}            # <city>/.gc/worktrees/<rig>
    worktrees_root=${rig_dir%/*}       # <city>/.gc/worktrees
    [ "${worktrees_root##*/}" = worktrees ] || return 1
    [ "${lane_tree##*/}" != worktrees ] || return 1
    return 0
}

# THE BEAD ID A CANDIDATE PATH NAMES is `${wt##*/}` with any `.reaping` suffix
# stripped — this script's own marker (see THE INTERRUPTED REMOVAL), so marked
# residue answers to the same bead as the worktree it was. Written inline at each
# call site rather than as a helper: parameter expansion costs nothing, while a
# helper would put a subshell fork on a path that runs once per worktree on the
# rig, inside a wall clock measured in seconds.

# bead_leaf_ok <id> — true when a candidate's leaf could be a bead id. Anything
# else is not ours to remove.
#
# The dot is IN the class because a sub-bead id carries one (`feryn-derh.1`),
# and a whitelist without it dropped every split bead's worktree here — before
# the bulk read, before any `record`, so no event was emitted at all and the log
# read as a complete clean pass (gcp-ac59). That silence is the reason this was
# a P1: it hid the data-at-risk case too, since a dotted worktree holding
# stranded work could never surface as `worktree_dirty_kept` either. On winnow
# it was half the eligible set. Admitting the dot must not admit traversal, so
# `.` / `..` / any embedded `..` are still refused — the leading- and
# trailing-dot guards mirror the `-*` / `*-` ones, since a bead id begins and
# ends with neither separator.
bead_leaf_ok() {
    case "$1" in
        *[!a-zA-Z0-9.-]* | '' | -* | *- | .* | *. | *..*) return 1 ;;
    esac
    return 0
}

record() {
    # record <event> <bead> <worktree> <detail> [reason]
    #
    # `ts` is stamped HERE, at the moment of the event. It used to be the run's
    # start time on every line, which is the difference between a log you can
    # reconstruct a slow cycle from and one where an eight-second run and an
    # instant one are indistinguishable.
    #
    # `reason` is the machine-readable half of the same honesty rule the detail
    # text follows: it must name what actually happened, never a cause the run
    # did not observe. `budget_remaining` is read at record time, so a line
    # reporting 0 is self-evidently the clock's doing.
    jq -cn \
        --arg ts "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" \
        --arg run_started "$RUN_STARTED" \
        --arg event "$1" \
        --arg rig "$RIG_NAME" \
        --arg bead "$2" \
        --arg worktree "$3" \
        --arg detail "$4" \
        --arg reason "${5:-}" \
        --argjson budget_remaining "$(budget_left)" \
        --argjson dry_run "$DRY_RUN" \
        '{ts:$ts, run_started:$run_started, event:$event, rig:$rig, bead:$bead,
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
    # "no per-bead polecat worktrees under $RIG_ROOT" is a claim about the rig.
    # A run that never got the list is not entitled to make it — and this path
    # used to make it anyway, while logging nothing at all: the quietest way
    # this script could report a fact it had not observed.
    case "$WT_LIST_OUTCOME" in
        skipped)
            record worktree_budget_truncated "" "" \
                "the ${BUDGET_SECONDS}s budget was spent before the worktree list was read; no candidate was enumerated" \
                budget_spent_before_worktree_list
            echo "polecat-worktree-reap: budget spent before enumerating worktrees; examined=0 (log: $LOG_FILE)"
            ;;
        timeout)
            record worktree_list_failed "" "" \
                "git worktree list did not answer within the ${WT_LIST_LIMIT}s left of the ${BUDGET_SECONDS}s budget" \
                worktree_list_timed_out
            echo "polecat-worktree-reap: worktree list did not answer within ${WT_LIST_LIMIT}s; examined=0 (log: $LOG_FILE)"
            ;;
        *)
            record worktree_list_failed "" "" \
                "git worktree list exited $WT_LIST_RC in $RIG_ROOT" \
                worktree_list_failed
            echo "polecat-worktree-reap: worktree list failed (exit $WT_LIST_RC); examined=0 (log: $LOG_FILE)"
            ;;
    esac
    exit 0
fi

# git lists the MAIN worktree first, and it is the canonical checkout — never a
# candidate, whatever it is called. Gate 1 used to exclude it incidentally, via
# a `polecats` segment no rig root carries; keyed on shape alone, a rig rooted
# at `<anything>/worktrees/<name>` would match the per-bead shape exactly and, if
# clean and published, clear every remaining gate. Name the exclusion instead.
MAIN_WT=$(printf '%s\n' "$WT_LIST" | sed -n 's/^worktree //p' | head -1)

# Two enumeration sources, unioned. The admin list is the first; the walk of the
# rig's own worktree tree below is the second, and it exists because the admin
# list structurally cannot see a half-removed worktree (see RESIDUE above).
# These files are cleaned up by the trap that the bead-read block installs
# further down, which lists every temp file this script makes.
REGISTERED_FILE=$(mktemp)
RESIDUE_FILE=$(mktemp)
SCAN_ROOTS_FILE=$(mktemp)
# Named here, made below, so the trap covers it even if the walk never runs.
DISK_ENTRIES_FILE=""
trap 'rm -f "$REGISTERED_FILE" "$RESIDUE_FILE" "$SCAN_ROOTS_FILE" "$DISK_ENTRIES_FILE"' EXIT

# Gate 1: per-bead worktree shape — `<agent-home>/worktrees/<bead-id>`, where the
# home is itself `<lane-tree>/<agent>` two levels under the rig's worktree root.
# That is the same home shape polecat-home-audit.sh gates on, so the two scripts
# split the tree between them with one definition rather than two.
#
# An agent HOME is never a candidate, but it is kept as a SCAN ROOT: it is the
# handle on the directory its per-bead children live in, and it stays registered
# with git even when every one of those children has been stripped out of the
# admin list.
while IFS= read -r wt; do
    [ -n "$wt" ] || continue
    [ "$wt" != "$MAIN_WT" ] || continue
    [ "$wt" != "$RIG_ROOT" ] || continue
    if agent_home_shape "$wt"; then
        printf '%s\n' "$wt/worktrees" >>"$SCAN_ROOTS_FILE"
        continue
    fi
    per_bead_shape "$wt" || continue
    printf '%s\n' "${wt%/*}" >>"$SCAN_ROOTS_FILE"
    leaf=${wt##*/}
    bead_leaf_ok "${leaf%.reaping}" || continue
    printf '%s\n' "$wt" >>"$REGISTERED_FILE"
done <<EOF
$(printf '%s\n' "$WT_LIST" | sed -n 's/^worktree //p')
EOF

# ── THE SECOND ENUMERATION SOURCE — residue (gcp-mves) ────────────────────────
# A `git worktree remove` killed mid-flight, and every one of the ~23 directories
# winnow's armed run already left behind, is present on disk with no admin entry
# at all. Gate 1 above can never enumerate one, so it would accumulate silently
# forever. Walk the same worktree directories the admin list named and pick up
# anything on disk that is not in it.
#
# The test is ABSENCE FROM THE ADMIN LIST, not a shape inside the directory.
# Two shapes have to be recovered and neither can be keyed on:
#   - `*.reaping`, left by an interrupted removal — self-identifying;
#   - the legacy stripped shape, a directory with no `.git` at all, carrying no
#     marker because nothing was left running to write one.
# Keying on those two would leave a third — a worktree git can still administer
# but has forgotten — unowned by every guard for the same reason the first two
# were. Everything enumerated here takes the same gates, so widening what is
# LOOKED AT does not widen what is removed.
#
# A glob, never `find`: this walk has to fit inside the same 8s budget as the
# rest of the run, and a wide traversal is both slow and a TCC prompt away from
# blocking the witness start on macOS.
if [ -s "$SCAN_ROOTS_FILE" ]; then
    LC_ALL=C sort -u "$SCAN_ROOTS_FILE" -o "$SCAN_ROOTS_FILE" 2>/dev/null || true
    LC_ALL=C sort -u "$REGISTERED_FILE" -o "$REGISTERED_FILE" 2>/dev/null || true
    DISK_ENTRIES_FILE=$(mktemp)
    while IFS= read -r scan_root; do
        [ -n "$scan_root" ] && [ -d "$scan_root" ] || continue
        for entry in "$scan_root"/*; do
            [ -d "$entry" ] || continue
            # The main-worktree exclusion is named on THIS source too. Gate 1
            # above drops it before it can contribute a scan root, but a scan
            # root contributed by some OTHER registered worktree can still
            # contain it — and a rig rooted at `<home>/worktrees/<name>` matches
            # the per-bead shape exactly. Leaving the exclusion to that path
            # accident is what the header refuses to do.
            [ "$entry" != "$MAIN_WT" ] || continue
            [ "$entry" != "$RIG_ROOT" ] || continue
            per_bead_shape "$entry" || continue
            leaf=${entry##*/}
            bead_leaf_ok "${leaf%.reaping}" || continue
            printf '%s\n' "$entry"
        done
    done <"$SCAN_ROOTS_FILE" | LC_ALL=C sort -u >"$DISK_ENTRIES_FILE"
    # The set difference in ONE process. A membership test per entry would put a
    # fork on every worktree on the rig, which is the shape of cost this script
    # spends its whole design avoiding.
    if [ -s "$REGISTERED_FILE" ]; then
        LC_ALL=C grep -Fxv -f "$REGISTERED_FILE" "$DISK_ENTRIES_FILE" \
            >"$RESIDUE_FILE" 2>/dev/null || true
    else
        # An empty pattern file is not portably "match nothing" — some greps
        # read it as matching everything, which would invert the difference and
        # hide every residue path. Nothing is registered here, so every entry on
        # disk is residue by definition; say that outright.
        cat "$DISK_ENTRIES_FILE" >"$RESIDUE_FILE" 2>/dev/null || true
    fi
    rm -f "$DISK_ENTRIES_FILE"
fi

CANDIDATES=$(cat "$REGISTERED_FILE" "$RESIDUE_FILE" 2>/dev/null | LC_ALL=C sort -u || true)

if [ -z "$CANDIDATES" ]; then
    echo "polecat-worktree-reap: no per-bead polecat worktrees under $RIG_ROOT"
    exit 0
fi

TOTAL=$(printf '%s\n' "$CANDIDATES" | grep -c . || true)

# ── ROTATE THE START, so the cutoff does not always fall in the same place ────
# (gcp-schs; see THE BIASED CUTOFF in the header.) The enumeration above is
# sorted, and the loop below breaks out of it when the budget expires — so
# without this, the candidates that get dropped are always the same sorted tail,
# and a would-reap set reviewed across any number of cycles can still have never
# contained them.
#
# The cursor is the last candidate the previous cycle actually DECIDED, and this
# one starts at the first candidate after it, wrapping at the end. That makes
# coverage a round-robin rather than a re-walk: consecutive truncated cycles
# advance through the whole set instead of re-examining the head of it. A
# candidate that no longer exists is fine — the comparison is ordering, not
# membership, so the successor is still well defined. LC_ALL=C matches the sort
# above, so "after" means the same thing in both places.
#
# Every failure here degrades to "no rotation", never to an error: an unreadable
# cursor loses the fairness, an aborted run loses the witness.
CURSOR_START=""
if [ -r "$CURSOR_FILE" ]; then
    CURSOR_START=$(head -n 1 "$CURSOR_FILE" 2>/dev/null || true)
fi
if [ -n "$CURSOR_START" ]; then
    ROTATED=$(printf '%s\n' "$CANDIDATES" | LC_ALL=C awk -v cursor="$CURSOR_START" '
        { lines[NR] = $0; if (start == 0 && ($0 "") > (cursor "")) start = NR }
        END {
            if (start == 0) start = 1
            for (i = start; i <= NR; i++) print lines[i]
            for (i = 1; i < start; i++) print lines[i]
        }' 2>/dev/null || true)
    if [ -n "$ROTATED" ] &&
        [ "$(printf '%s\n' "$ROTATED" | grep -c . || true)" -eq "$TOTAL" ]; then
        CANDIDATES="$ROTATED"
    fi
fi
SCAN_START=$(printf '%s\n' "$CANDIDATES" | head -n 1)

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
    if [ -n "$wt" ]; then
        wt=${wt##*/}
        printf '%s\n' "${wt%.reaping}"
    fi
done | sort -u)
EOF

# Straight to a file, never to a variable: bead descriptions run to kilobytes
# apiece, and handing dozens of them to jq as an --argjson would put the whole
# payload in argv, where a large candidate set trips ARG_MAX. That failure is
# silent — jq never runs, the join comes back empty, and the summary reports a
# clean cycle that examined nothing.
BEADS_FILE=$(mktemp)
SESSIONS_FILE=$(mktemp)
# bd's stderr is EVIDENCE, not noise. It is the only place the store says which
# of the ids it was handed do not exist, and that verdict is what separates a
# path this run should decide about once from one it should retry next cycle
# (gcp-0u14). Discarding it to /dev/null is what made every missing bead look
# transient.
BEAD_ERR_FILE=$(mktemp)
NOT_FOUND_FILE=$(mktemp)
# The bead facts re-read at the point of use, before the first removal of the
# cycle. A second file rather than an overwrite of BEADS_FILE: the gate pass and
# the re-check are different observations, taken at different moments, and
# collapsing them would leave nothing to compare a reopened bead against.
RECHECK_BEADS_FILE=$(mktemp)
: >"$NOT_FOUND_FILE"
# Replaces the enumeration trap above with one that names every temp file.
trap 'rm -f "$BEADS_FILE" "$SESSIONS_FILE" "$BEAD_ERR_FILE" "$NOT_FOUND_FILE" \
    "$RECHECK_BEADS_FILE" "$REGISTERED_FILE" "$RESIDUE_FILE" "$SCAN_ROOTS_FILE" \
    "$DISK_ENTRIES_FILE"' EXIT

BEAD_QUERY_LIMIT=$(budget_left)
BEAD_QUERY_RC=0
run_bounded "$BEAD_QUERY_LIMIT" "${GC_BD[@]}" show "${BEAD_IDS_ARGV[@]}" --json \
    >"$BEADS_FILE" 2>"$BEAD_ERR_FILE" || BEAD_QUERY_RC=$?
BEAD_QUERY_OUTCOME=$(classify_outcome "$BEAD_QUERY_LIMIT" "$BEAD_QUERY_RC")

# The ids bd itself declared absent, keyed on bd's OWN error class rather than
# on a regex guess at what a bead id looks like. bd writes one line per missing
# id:
#
#     Error fetching g7nf-base: no issue found matching "g7nf-base"
#
# Anything else on stderr — a store error, a timeout notice, a warning — leaves
# the id out of this set and therefore transient, which is the conservative
# direction: the worst case is one more retry, not a removal on a guess.
#
# Only honoured when bd RAN TO COMPLETION. `ok` is the mixed batch (some ids
# resolved, exit 0); `failed` is the all-missing batch, where bd exits 1 and
# prints an error OBJECT instead of an array. A `timeout` or `skipped` outcome
# means the process was killed or never started, so its partial stderr is not a
# verdict about anything and every id stays transient.
case "$BEAD_QUERY_OUTCOME" in
    ok | failed)
        sed -n 's/.*no issue found matching "\([^"]*\)".*/\1/p' "$BEAD_ERR_FILE" \
            | sort -u >"$NOT_FOUND_FILE" || : >"$NOT_FOUND_FILE"
        ;;
esac

# bead_is_absent <id> — bd answered and said this id resolves to no bead. A
# PERMANENT condition: the id will not start existing later, so retrying it
# every cycle forever is the bug (gcp-0u14).
bead_is_absent() {
    [ -s "$NOT_FOUND_FILE" ] && grep -Fxq -- "$1" "$NOT_FOUND_FILE"
}

if ! jq -e 'type == "array"' "$BEADS_FILE" >/dev/null 2>&1 &&
    [ "$BEAD_QUERY_OUTCOME" = failed ] &&
    [ "$(wc -l <"$NOT_FOUND_FILE" | tr -d ' ')" -eq "${#BEAD_IDS_ARGV[@]}" ]; then
    # Every id in the batch came back "no issue found matching". bd exits 1 and
    # prints an error OBJECT rather than an array in that case, which the
    # array check below reads as a dead store — so a rig whose ONLY candidate
    # is a no-such-bead path used to abort the whole cycle as
    # `worktree_bead_query_failed`, pointing the reader at a Dolt server that
    # was answering perfectly. It answered; the answer was "none of these
    # exist". Normalise to an empty array and let the per-candidate gates
    # decide, exactly as they would in a mixed batch.
    printf '[]' >"$BEADS_FILE"
fi

if ! jq -e 'type == "array"' "$BEADS_FILE" >/dev/null 2>&1; then
    # No usable answer for ANY bead. An unreadable bead is not proof the work
    # is done, so nothing is a candidate for removal this cycle — but WHY there
    # is no answer decides who should look at it, so say which of the three it
    # was instead of blaming the store for all of them.
    case "$BEAD_QUERY_OUTCOME" in
        skipped)
            record worktree_budget_truncated "" "" \
                "the ${BUDGET_SECONDS}s budget was spent before the bead read was issued; 0 of $TOTAL candidate(s) examined, $TOTAL deferred" \
                budget_spent_before_bead_query
            echo "polecat-worktree-reap: budget spent before the bead read; examined=0 deferred=$TOTAL of $TOTAL (log: $LOG_FILE)"
            ;;
        timeout)
            record worktree_bead_query_failed "" "" \
                "bulk gc bd show for ${#BEAD_IDS_ARGV[@]} bead(s) did not answer within the ${BEAD_QUERY_LIMIT}s left of the ${BUDGET_SECONDS}s budget" \
                bead_query_timed_out
            echo "polecat-worktree-reap: bead read timed out after ${BEAD_QUERY_LIMIT}s of the ${BUDGET_SECONDS}s budget; reaped=0 skipped=$TOTAL (log: $LOG_FILE)"
            ;;
        *)
            record worktree_bead_query_failed "" "" \
                "bulk gc bd show for ${#BEAD_IDS_ARGV[@]} bead(s) exited $BEAD_QUERY_RC and returned no usable JSON" \
                bead_query_failed
            echo "polecat-worktree-reap: bead read failed (exit $BEAD_QUERY_RC); reaped=0 skipped=$TOTAL (log: $LOG_FILE)"
            ;;
    esac
    exit 0
fi

# Join the candidate paths to their bead facts once, in jq, so the loop below
# does no per-worktree querying at all: <status>US<owner>US<kind>US<worktree>, US
# is the ASCII unit separator. Deliberately not @tsv: tab is an IFS WHITESPACE
# character, so `read` silently collapses the empty leading fields an unreadable
# bead produces and shifts the path into $STATUS. US is neither whitespace nor
# legal in a bead id or a path, so every field survives, empty or not.
#
# The `kind` field carries which ENUMERATION SOURCE found the path, so the loop
# never has to ask per candidate. A membership test in the loop would be one fork
# per worktree on the rig — the cost shape this script exists to avoid.
DECISIONS=$(printf '%s\n' "$CANDIDATES" | jq -R -r -s \
    --slurpfile bead_docs "$BEADS_FILE" --rawfile residue_paths "$RESIDUE_FILE" '
    ( ($bead_docs[0] // [])
      | map(select(type == "object"))
      | map({ key:   (.id // "" | tostring),
              value: { status: (.status // "" | tostring),
                       owner:  (.metadata.polecat_session? // "" | tostring) } })
      | from_entries ) as $by
    | ($residue_paths | split("\n") | map(select(length > 0))) as $residue
    | split("\n")
    | map(select(length > 0))
    | .[]
    | . as $wt
    | ($by[($wt | split("/") | last | sub("\\.reaping$"; ""))] // { status: "", owner: "" }) as $bead
    | (if ($residue | index($wt)) then "residue" else "registered" end) as $kind
    | [ $bead.status, $bead.owner, $kind, $wt ] | join("\u001f")
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
# Why the roster is unconfirmed, carried alongside the verdict so the log can
# say whether anyone actually asked the session roster anything this cycle.
ROSTER_REASON="roster_read_failed"
# Seconds the roster read was actually given, so a timeout can report the bound
# it hit rather than implying the roster is broken.
ROSTER_LIMIT=0
ROSTER_FETCHED=0

ensure_roster() {
    if [ "$ROSTER_FETCHED" -eq 1 ]; then
        return
    fi
    ROSTER_FETCHED=1
    local limit rc=0
    limit=$(budget_left)
    run_bounded "$limit" gc session list --state=all --json >"$SESSIONS_FILE" 2>/dev/null || rc=$?
    case "$(classify_outcome "$limit" "$rc")" in
        skipped)
            ROSTER_REASON="budget_spent_before_roster_read"
            return
            ;;
        timeout)
            ROSTER_REASON="roster_read_timed_out"
            ROSTER_LIMIT="$limit"
            return
            ;;
        failed)
            ROSTER_REASON="roster_read_failed"
            return
            ;;
    esac
    if [ -s "$SESSIONS_FILE" ] && jq -e '(.sessions | type) == "array"' "$SESSIONS_FILE" >/dev/null 2>&1; then
        ROSTER_STATE="readable"
        ROSTER_REASON=""
    else
        ROSTER_REASON="roster_unparseable"
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

# ── THE POINT OF USE — facts renewed for the removal phase (gcp-mves) ────────
# Taken ONCE per cycle, lazily at the first removal, and reused by every removal
# after it. One bulk bead read and one roster read for the whole candidate set,
# never one pair per worktree: the N+1 that cost winnow its witness for 26h
# (gcp-ntbf) must not come back through the re-check.
#
# `unconfirmed` until BOTH actually answer, and while it stays that way every
# removal this cycle is refused. A re-check that could not be taken is not a
# re-check that passed.
RECHECK_STATE="unconfirmed"
RECHECK_REASON="recheck_not_taken"
RECHECK_TAKEN=0

refresh_removal_snapshot() {
    if [ "$RECHECK_TAKEN" -eq 1 ]; then
        return
    fi
    RECHECK_TAKEN=1
    local limit rc=0
    limit=$(budget_left)
    run_bounded "$limit" "${GC_BD[@]}" show "${BEAD_IDS_ARGV[@]}" --json \
        >"$RECHECK_BEADS_FILE" 2>/dev/null || rc=$?
    case "$(classify_outcome "$limit" "$rc")" in
        skipped)
            RECHECK_REASON="budget_spent_before_recheck_bead_read"
            return
            ;;
        timeout)
            RECHECK_REASON="recheck_bead_read_timed_out"
            return
            ;;
    esac
    if ! jq -e 'type == "array"' "$RECHECK_BEADS_FILE" >/dev/null 2>&1; then
        if [ "$rc" -ne 0 ]; then
            RECHECK_REASON="recheck_bead_read_failed"
        else
            RECHECK_REASON="recheck_bead_read_unparseable"
        fi
        return
    fi
    # The roster is renewed too. Gate 4's whole job is to defer a reap while a
    # polecat is still reworking, and the window this re-check exists to close
    # is exactly the one where a bead reopens and a polecat is slung onto it.
    ROSTER_FETCHED=0
    ROSTER_STATE="unconfirmed"
    ROSTER_REASON="roster_read_failed"
    ensure_roster
    if [ "$ROSTER_STATE" != readable ]; then
        RECHECK_REASON="$ROSTER_REASON"
        return
    fi
    RECHECK_STATE="readable"
    RECHECK_REASON=""
}

# The rig's own git directory, as GIT resolves it. Read from git rather than
# composed as "$RIG_ROOT/.git" so it is comparable with what a candidate reports:
# on macOS a $TMPDIR path and its resolved /private form are the same directory
# and never compare equal as strings. Used to refuse a residue directory that is
# administrable but belongs to some OTHER repository — its bead id would be this
# rig's, and its content would not.
RIG_GIT_DIR=""
RIG_GIT_DIR_FETCHED=0

ensure_rig_git_dir() {
    if [ "$RIG_GIT_DIR_FETCHED" -eq 1 ]; then
        return
    fi
    RIG_GIT_DIR_FETCHED=1
    local limit rc=0 out
    limit=$(budget_left)
    # `--path-format=absolute` is not decoration: run from a repo root, a bare
    # `--git-common-dir` answers the relative `.git`, which compares equal to
    # nothing a candidate ever reports.
    out=$(run_bounded "$limit" git -C "$RIG_ROOT" rev-parse \
        --path-format=absolute --git-common-dir 2>/dev/null) || rc=$?
    if [ "$(classify_outcome "$limit" "$rc")" = ok ]; then
        RIG_GIT_DIR="$out"
    fi
}

# revalidate_gates <bead> <worktree> <administrable> <no-such-bead>
#
# Re-check, immediately before the destructive call, the gates that can have
# changed since they were evaluated: the tree can go dirty, the bead can be
# reopened, and a polecat can be slung onto it. Everything above was established
# earlier in the run — the bead status by one bulk read at the top, the roster by
# a read after it, the clean-tree check by gate 3 — and the rig is live the whole
# time. This was the one destructive call in the script with no re-validation at
# the point of use (gcp-mves).
#
# Anything that cannot be RE-CONFIRMED is a refusal: the run is not entitled to
# remove on evidence it could not renew. Records its own refusal, and returns 1
# for the caller to skip on.
revalidate_gates() {
    local bead=$1 wt=$2 administrable=$3 no_bead=$4
    local limit rc dirty status owner

    if [ "$administrable" -eq 1 ]; then
        limit=$(budget_left)
        rc=0
        dirty=$(run_bounded "$limit" git -C "$wt" status --porcelain 2>/dev/null) || rc=$?
        if [ "$(classify_outcome "$limit" "$rc")" != ok ]; then
            record worktree_revalidation_unconfirmed "$bead" "$wt" \
                "git status could not be re-read immediately before the removal; a gate that cannot be re-confirmed is a refusal, not a removal" \
                revalidation_status_unreadable
            return 1
        fi
        if [ -n "$dirty" ]; then
            record worktree_dirty_kept "$bead" "$wt" \
                "the worktree went dirty between the gate check and the removal: $(printf '%s\n' "$dirty" | wc -l | tr -d ' ') uncommitted path(s)" \
                dirty_at_point_of_use
            return 1
        fi
    fi

    # The no-such-bead path has no bead to re-read and no owner to confirm — its
    # gates are 3 above and 5, and gate 5's evidence was taken from this same
    # worktree moments ago.
    if [ "$no_bead" -eq 1 ]; then
        return 0
    fi

    refresh_removal_snapshot
    if [ "$RECHECK_STATE" != readable ]; then
        record worktree_revalidation_unconfirmed "$bead" "$wt" \
            "the bead status and session roster could not be renewed before the removal ($RECHECK_REASON); the gates were last confirmed earlier in this run, so the worktree is kept and re-checked next cycle" \
            "$RECHECK_REASON"
        return 1
    fi

    # Keyed on the id the store ECHOED, exactly as the bulk join is: a fuzzy hit
    # must not let one worktree inherit another bead's status here either.
    status=$(jq -r --arg id "$bead" '
        [ .[] | select(type == "object") | select((.id // "" | tostring) == $id) ]
        | .[0].status // "" | tostring
    ' "$RECHECK_BEADS_FILE" 2>/dev/null || true)
    if [ "$status" != closed ]; then
        record worktree_bead_reopened "$bead" "$wt" \
            "the bead was closed when this cycle enumerated it and reads ${status:-unreadable} now; the closure is what authorises the reap, so it is not removed" \
            bead_changed_at_point_of_use
        return 1
    fi

    owner=$(jq -r --arg id "$bead" '
        [ .[] | select(type == "object") | select((.id // "" | tostring) == $id) ]
        | .[0].metadata.polecat_session? // "" | tostring
    ' "$RECHECK_BEADS_FILE" 2>/dev/null || true)
    case "$(session_state "$owner")" in
        absent) ;;
        live)
            record worktree_owner_live "$bead" "$wt" \
                "session $owner became live between the gate check and the removal" \
                owner_live_at_point_of_use
            return 1
            ;;
        *)
            record worktree_owner_unconfirmed "$bead" "$wt" \
                "the session roster could not confirm the owner immediately before the removal; a read that did not answer is not proof of absence" \
                revalidation_owner_unconfirmed
            return 1
            ;;
    esac
    return 0
}

REAPED=0
SKIPPED=0
EXAMINED=0
BUDGET_SPENT=0
# Set when a candidate was skipped because a check was never attempted — the
# run's own clock, not the subsystem the skipped check would have talked to.
TRUNCATED=0
# The last candidate this cycle reached a DECISION about — where the next cycle
# resumes. A truncated candidate was never inspected, so it must not advance
# this: leaving it behind the cursor is what keeps it in the next cycle's window.
DECIDED_LAST=""
DECIDED_PREV=""

while IFS=$'\037' read -r STATUS OWNER KIND WT; do
    [ -n "$WT" ] || continue

    # Yield the start rather than lose a race with SIGKILL. What is left
    # unexamined stays a candidate for the next cycle; the work is idempotent —
    # and the next cycle resumes AFTER the last decision below rather than at
    # the head of the list, so the deferred remainder is not the same worktrees
    # every run (gcp-schs).
    if [ "$(budget_left)" -le 0 ]; then
        BUDGET_SPENT=1
        RESUME_LABEL="${DECIDED_LAST##*/}"
        [ -n "$RESUME_LABEL" ] || RESUME_LABEL="nothing (no candidate was decided)"
        record worktree_budget_exhausted "" "" \
            "${BUDGET_SECONDS}s budget spent after $EXAMINED of $TOTAL candidate(s): reaped=$REAPED skipped=$SKIPPED deferred=$((TOTAL - EXAMINED)); yielding the witness start. This cycle's window began at ${SCAN_START##*/}; the next resumes after $RESUME_LABEL, so the deferred remainder rotates instead of always being the same sorted tail" \
            budget_exhausted
        break
    fi
    EXAMINED=$((EXAMINED + 1))
    DECIDED_PREV="$DECIDED_LAST"
    DECIDED_LAST="$WT"

    BEAD=${WT##*/}
    BEAD=${BEAD%.reaping}
    # Why this worktree is disposable, if it turns out to be. The two paths
    # reach the same removal through different evidence, and `worktree_reaped`
    # must not report the closed-bead one for a path that never had a bead.
    REAP_DETAIL="bead closed"
    NO_SUCH_BEAD=0
    # Residue — a directory the admin list cannot see, found by the disk walk
    # above. It takes the same gates; only gate 3 is evaluated differently,
    # because git may have no view of it to answer with (see RESIDUE).
    IS_RESIDUE=0
    if [ "$KIND" = residue ]; then
        IS_RESIDUE=1
        REAP_DETAIL="residue of an interrupted removal; bead closed"
    fi

    if [ -z "$STATUS" ]; then
        if ! bead_is_absent "$BEAD"; then
            # bd could not answer FOR THIS ID — a store error, a fuzzy hit that
            # echoed a different id, a read cut short. Transient: an unreadable
            # bead is not proof the work is done. Leave the worktree alone; a
            # later cycle retries once bd is readable again.
            record worktree_bead_unreadable "$BEAD" "$WT" \
                "the bulk gc bd show answered, but echoed no row for this bead id" \
                bead_absent_from_batch
            SKIPPED=$((SKIPPED + 1))
            continue
        fi
        if [ "$IS_RESIDUE" -eq 1 ]; then
            # The no-such-bead path is carried entirely by gate 5, and gate 5
            # needs a `git rev-parse HEAD` that residue cannot answer: git has
            # no view of it. With no bead closure to authorise the reap and no
            # way to ask whether the content exists anywhere else, there is no
            # evidence at all — so keep it, and say exactly that rather than
            # implying a probe was made.
            record worktree_residue_no_bead_kept "$BEAD" "$WT" \
                "no bead authorises this reap and the directory has no git view to run the publication probe against, so nothing could be established about it; kept for the witness" \
                residue_no_bead_unverifiable
            SKIPPED=$((SKIPPED + 1))
            continue
        fi
        # bd answered, and the answer was that this id resolves to no bead —
        # `g7nf-base`, a hand-made scratch worktree under `worktrees/`, is the
        # shape. That is PERMANENT: treating it as a transient store failure
        # retried it every cycle forever, and an unreapable child pins its
        # parent polecat home open just as permanently (gcp-0u14). Decide once.
        NO_SUCH_BEAD=1
        record worktree_no_such_bead "$BEAD" "$WT" \
            "gc bd reports no issue matching this id, so no bead closure will ever authorise the reap; deciding on the worktree's own evidence instead of retrying" \
            no_such_bead
        # Gate 2 needs a bead status and gate 4 needs a bead's polecat_session,
        # so neither can bind here. Gate 3 (clean tree) and gate 5 (content
        # published) below carry the whole safety burden for this path.
    else
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
                case "$ROSTER_REASON" in
                    budget_spent_before_roster_read)
                        # Nobody asked the roster anything. Saying it was unreadable
                        # would point at a subsystem this run never touched.
                        TRUNCATED=1
                        # Never inspected, so it must stay in the next cycle's
                        # window: hold the resume cursor at the last candidate
                        # that actually got a decision.
                        DECIDED_LAST="$DECIDED_PREV"
                        record worktree_budget_truncated "$BEAD" "$WT" \
                            "the ${BUDGET_SECONDS}s budget was spent before the session roster was read; liveness unchecked at candidate $EXAMINED of $TOTAL" \
                            "$ROSTER_REASON"
                        ;;
                    roster_read_timed_out)
                        record worktree_owner_unconfirmed "$BEAD" "$WT" \
                            "gc session list did not answer within the ${ROSTER_LIMIT}s left of the ${BUDGET_SECONDS}s budget; a read cut short is not proof of absence" \
                            "$ROSTER_REASON"
                        ;;
                    *)
                        record worktree_owner_unconfirmed "$BEAD" "$WT" \
                            "session roster unreadable ($ROSTER_REASON); a failed read is not proof of absence" \
                            "$ROSTER_REASON"
                        ;;
                esac
                SKIPPED=$((SKIPPED + 1))
                continue
                ;;
        esac
    fi

    # Gate 3: never discard uncommitted work. Ignored files are artifacts and
    # are excluded by `git status --porcelain`; untracked non-ignored files are
    # reported and block the reap so the witness can salvage them.
    #
    # A REGISTERED candidate is by definition one git can answer about. Residue
    # may not be, and the failure mode is not an error: `git -C <stripped-dir>
    # status` does NOT fail, it walks UP and answers about the AGENT HOME
    # instead (measured: `?? worktrees/`). Taking that as gate 3 would be a
    # verdict about a directory this run never looked at — the same
    # read-something-else-as-the-answer collapse that `worktree_owner_absent`
    # and `worktree_publication_unconfirmed` exist to prevent elsewhere. So
    # residue is asked FIRST whether it is administrable, with the ceiling
    # pinned at its own parent, and only a directory that reports ITSELF as the
    # worktree root goes on to the ordinary clean-tree gate.
    ADMINISTRABLE=1
    if [ "$IS_RESIDUE" -eq 1 ]; then
        ADMINISTRABLE=0
        TOP_LIMIT=$(budget_left)
        TOP_RC=0
        WT_TOP=$(run_bounded "$TOP_LIMIT" \
            env "GIT_CEILING_DIRECTORIES=${WT%/*}" \
            git -C "$WT" rev-parse --path-format=absolute \
                --show-toplevel --git-common-dir 2>/dev/null) || TOP_RC=$?
        if [ "$(classify_outcome "$TOP_LIMIT" "$TOP_RC")" = ok ]; then
            WT_TOP_PATH=$(printf '%s\n' "$WT_TOP" | sed -n 1p)
            WT_COMMON_DIR=$(printf '%s\n' "$WT_TOP" | sed -n 2p)
            ensure_rig_git_dir
            # Its own root, and THIS rig's repository. A directory that answers
            # about something else — the agent home it sits in, or another
            # repository entirely — has not told us anything about itself.
            if [ -n "$WT_TOP_PATH" ] && [ "$WT_TOP_PATH" = "$WT" ] &&
                [ -n "$RIG_GIT_DIR" ] && [ "$WT_COMMON_DIR" = "$RIG_GIT_DIR" ]; then
                ADMINISTRABLE=1
            fi
        fi
    fi

    if [ "$ADMINISTRABLE" -eq 0 ]; then
        # Gate 3 is not skipped here, it is UNEVALUABLE, and the log says which.
        # What authorises the removal instead is gate 2 — the refinery closes a
        # bead only after a verified merge or PR handoff — plus the shape: this
        # directory is what an authorised removal that was killed mid-flight
        # leaves behind, and a residue path with no closed bead never reaches
        # this point at all.
        record worktree_residue_git_view_absent "$BEAD" "$WT" \
            "git has no view of this directory, so no git status can answer about it; the reap stands on the bead's closure and the owning session's absence, which are the gates that could still be evaluated" \
            residue_git_view_absent
    else
        STATUS_LIMIT=$(budget_left)
        STATUS_RC=0
        DIRTY=$(run_bounded "$STATUS_LIMIT" git -C "$WT" status --porcelain 2>/dev/null) || STATUS_RC=$?
        STATUS_OUTCOME=$(classify_outcome "$STATUS_LIMIT" "$STATUS_RC")
        if [ "$STATUS_OUTCOME" != ok ]; then
            # A worktree git cannot read is not one to delete on a guess — and
            # neither is one git was never asked about. Those are different
            # incidents with different owners, so they get different events.
            case "$STATUS_OUTCOME" in
                skipped)
                    TRUNCATED=1
                    # Never inspected — same reasoning as the roster truncation
                    # above: do not let the resume cursor step past it.
                    DECIDED_LAST="$DECIDED_PREV"
                    record worktree_budget_truncated "$BEAD" "$WT" \
                        "the ${BUDGET_SECONDS}s budget was spent before git status ran; the worktree was never inspected, at candidate $EXAMINED of $TOTAL" \
                        budget_spent_before_git_status
                    ;;
                timeout)
                    record worktree_status_unreadable "$BEAD" "$WT" \
                        "git status did not answer within the ${STATUS_LIMIT}s left of the ${BUDGET_SECONDS}s budget" \
                        git_status_timed_out
                    ;;
                *)
                    record worktree_status_unreadable "$BEAD" "$WT" \
                        "git status exited $STATUS_RC in the worktree" \
                        git_status_failed
                    ;;
            esac
            SKIPPED=$((SKIPPED + 1))
            continue
        fi
        if [ -n "$DIRTY" ]; then
            record worktree_dirty_kept "$BEAD" "$WT" \
                "$(printf '%s\n' "$DIRTY" | wc -l | tr -d ' ') uncommitted path(s)"
            SKIPPED=$((SKIPPED + 1))
            continue
        fi
    fi

    # Gate 5: for a no-such-bead path ONLY, the committed content must already
    # be published. The header explains why the closed-bead path is deliberately
    # not gated on this — a rebase-merging refinery rewrites hashes, so bead
    # closure is the better proof and this test would reject genuinely merged
    # work. But a path with no bead HAS no closure to stand on, and something
    # has to. So the gate binds exactly where the other evidence is missing.
    #
    # "Published" is `git branch --remotes --contains`: HEAD reachable from any
    # remote-tracking ref in the rig. That is what made g7nf-base a leak rather
    # than lost work. A path that fails it is a FINDING, not a retry — the whole
    # point of gcp-0u14 is that this condition never resolves itself, so the
    # witness is told once and the worktree is kept.
    if [ "$NO_SUCH_BEAD" -eq 1 ]; then
        # The probe has THREE answers, not two, and only one of them is
        # evidence. `ok` with empty output is the confirmed negative that
        # justifies the finding; `skipped`/`timeout`/`failed` mean nobody found
        # out. Folding the unknowns into the same empty string made a probe that
        # NEVER RAN report "the commits here exist nowhere else" and dispatch
        # the witness to salvage already-merged work (gcp-9ql4) — the same
        # indeterminate-read-as-definite-negative collapse gcp-5ddt hardened in
        # mol-witness-patrol. So carry the state explicitly.
        PUBLISHED=unconfirmed
        PUBLISHED_REASON=""
        PUBLISHED_DETAIL=""
        CONTAINS=""

        HEAD_LIMIT=$(budget_left)
        HEAD_RC=0
        WT_HEAD=$(run_bounded "$HEAD_LIMIT" git -C "$WT" rev-parse HEAD 2>/dev/null) || HEAD_RC=$?
        case "$(classify_outcome "$HEAD_LIMIT" "$HEAD_RC")" in
            ok)
                # Answered, but with nothing: there is no commit to look for, so
                # the publication question was never actually put to git either.
                if [ -z "$WT_HEAD" ]; then
                    PUBLISHED_REASON=publication_probe_failed
                    PUBLISHED_DETAIL="git rev-parse HEAD answered with no commit, so nothing could be looked for on a remote"
                fi
                ;;
            skipped)
                PUBLISHED_REASON=budget_spent_before_publication_probe
                PUBLISHED_DETAIL="the ${BUDGET_SECONDS}s budget was spent before HEAD was read; the publication probe never ran, at candidate $EXAMINED of $TOTAL"
                ;;
            timeout)
                PUBLISHED_REASON=publication_probe_timed_out
                PUBLISHED_DETAIL="git rev-parse HEAD did not answer within the ${HEAD_LIMIT}s left of the ${BUDGET_SECONDS}s budget"
                ;;
            *)
                PUBLISHED_REASON=publication_probe_failed
                PUBLISHED_DETAIL="git rev-parse HEAD exited $HEAD_RC in the worktree"
                ;;
        esac

        if [ -z "$PUBLISHED_REASON" ]; then
            CONTAINS_LIMIT=$(budget_left)
            CONTAINS_RC=0
            CONTAINS=$(run_bounded "$CONTAINS_LIMIT" \
                git -C "$RIG_ROOT" branch --remotes --contains "$WT_HEAD" 2>/dev/null) ||
                CONTAINS_RC=$?
            case "$(classify_outcome "$CONTAINS_LIMIT" "$CONTAINS_RC")" in
                ok)
                    # The only two states this run is entitled to assert.
                    if [ -n "$CONTAINS" ]; then
                        PUBLISHED=yes
                    else
                        PUBLISHED=no
                    fi
                    ;;
                skipped)
                    CONTAINS=""
                    PUBLISHED_REASON=budget_spent_before_publication_check
                    PUBLISHED_DETAIL="the ${BUDGET_SECONDS}s budget was spent before the remote-tracking refs were searched; the publication probe never ran, at candidate $EXAMINED of $TOTAL"
                    ;;
                timeout)
                    # A killed command can still have written a partial list, so
                    # the capture is discarded rather than read as an answer.
                    CONTAINS=""
                    PUBLISHED_REASON=publication_probe_timed_out
                    PUBLISHED_DETAIL="git branch --remotes --contains did not answer within the ${CONTAINS_LIMIT}s left of the ${BUDGET_SECONDS}s budget"
                    ;;
                *)
                    CONTAINS=""
                    PUBLISHED_REASON=publication_probe_failed
                    PUBLISHED_DETAIL="git branch --remotes --contains exited $CONTAINS_RC in $RIG_ROOT"
                    ;;
            esac
        fi

        if [ "$PUBLISHED" = unconfirmed ]; then
            case "$PUBLISHED_REASON" in
                budget_spent_before_*)
                    # Nobody asked git anything. Reporting it as a publication
                    # finding would point the witness at a probe this run never
                    # made — the same mistake the roster and git-status
                    # truncations above exist to avoid.
                    TRUNCATED=1
                    # Never decided, so it must stay inside the next cycle's
                    # window: hold the cursor at the last candidate that was.
                    DECIDED_LAST="$DECIDED_PREV"
                    record worktree_budget_truncated "$BEAD" "$WT" \
                        "$PUBLISHED_DETAIL" "$PUBLISHED_REASON"
                    ;;
                *)
                    record worktree_publication_unconfirmed "$BEAD" "$WT" \
                        "$PUBLISHED_DETAIL; a probe that did not answer is not proof the commits exist nowhere else, so the worktree is kept and re-checked next cycle" \
                        "$PUBLISHED_REASON"
                    ;;
            esac
            SKIPPED=$((SKIPPED + 1))
            continue
        fi
        if [ "$PUBLISHED" = no ]; then
            record worktree_unpublished_kept "$BEAD" "$WT" \
                "no bead authorises this reap and HEAD is on no remote-tracking branch, so the commits here exist nowhere else; kept for the witness to salvage" \
                no_such_bead_content_unpublished
            SKIPPED=$((SKIPPED + 1))
            continue
        fi
        REAP_DETAIL="no such bead; HEAD published on $(printf '%s\n' "$CONTAINS" |
            tr -d ' ' | paste -sd, -)"
    fi

    if [ "$DRY_RUN" -eq 1 ]; then
        record worktree_reap_pending "$BEAD" "$WT" "dry run — $REAP_DETAIL"
        REAPED=$((REAPED + 1))
        continue
    fi

    # ── Re-validate at the POINT OF USE, then remove (gcp-mves) ──────────────
    if ! revalidate_gates "$BEAD" "$WT" "$ADMINISTRABLE" "$NO_SUCH_BEAD"; then
        SKIPPED=$((SKIPPED + 1))
        continue
    fi

    # RENAME, PRUNE, DELETE — never `git worktree remove`. That call drops the
    # worktree's `.git` file and git's admin entry BEFORE unlinking the tree, and
    # this script cannot survive the SIGKILL its caller delivers at [session]
    # setup_timeout, so a kill inside that window leaves a directory no
    # enumeration can ever find again and no log line to say so. See THE
    # INTERRUPTED REMOVAL in the header. Every step below leaves a state that is
    # either untouched or self-identifying.
    REAPING="$WT"
    case "$WT" in
        *.reaping)
            # Already marked by an interrupted cycle. The rename is behind us;
            # finishing the job is all that is left.
            ;;
        *)
            if [ -e "$WT.reaping" ]; then
                # A marker for THIS worktree, left by an interrupted cycle.
                # Nothing but this script writes the suffix, so it is condemned
                # by construction — and leaving it would make the rename below
                # nest the tree INSIDE it rather than replace it.
                rm -rf "$WT.reaping"
            fi
            REAPING="$WT.reaping"
            # A sibling rename inside the same directory: same filesystem, so
            # rename(2), so atomic. There is no interruption point between "the
            # worktree is intact" and "the residue is marked".
            if ! mv "$WT" "$REAPING" 2>/dev/null; then
                record worktree_reap_failed "$BEAD" "$WT" \
                    "the worktree could not be renamed to $REAPING, so nothing was removed" \
                    reap_rename_failed
                SKIPPED=$((SKIPPED + 1))
                continue
            fi
            ;;
    esac
    # The admin entry now points at a path that is gone, so prune drops it
    # cleanly. Non-fatal: a prune that does not run leaves a `prunable` entry
    # the next cycle's opening prune clears, and the marked directory is removed
    # below either way.
    run_bounded "$(budget_left)" git -C "$RIG_ROOT" worktree prune >/dev/null 2>&1 || true
    rm -rf "$REAPING"

    if [ -e "$REAPING" ] || [ -e "$WT" ]; then
        record worktree_reap_failed "$BEAD" "$WT" "directory still present after removal" \
            reap_incomplete
        SKIPPED=$((SKIPPED + 1))
        continue
    fi

    record worktree_reaped "$BEAD" "$WT" "$REAP_DETAIL"
    REAPED=$((REAPED + 1))
done <<EOF
$DECISIONS
EOF

# ── COVERAGE, so the promotion criterion has something to stand on (gcp-schs) ─
# The flip to --no-dry-run is evidenced by a REVIEWED SET, and until now the log
# said nothing at all about a cycle that reviewed everything: only truncated
# cycles emitted a count line, so "several clean cycles" could not be told apart
# from "several clean PREFIXES". Say it outright, once per cycle, and keep the
# resume cursor honest about which of the two this was.
if [ "$BUDGET_SPENT" -eq 0 ] && [ "$TRUNCATED" -eq 0 ] && [ "$EXAMINED" -eq "$TOTAL" ]; then
    record worktree_scan_complete "" "" \
        "examined all $TOTAL candidate(s) in one cycle: reaped=$REAPED skipped=$SKIPPED deferred=0; the reviewed set for this cycle IS the candidate set" \
        scan_complete
    # A full pass has no remainder to resume from, and leaving the cursor at the
    # tail would pin every following cycle to this same starting point — the
    # bias again, one rotation along. Start the next one at the head.
    rm -f "$CURSOR_FILE" 2>/dev/null || true
elif [ -n "$DECIDED_LAST" ]; then
    printf '%s\n' "$DECIDED_LAST" >"$CURSOR_FILE" 2>/dev/null || true
fi
# A partial cycle that decided NOTHING leaves the previous cursor alone: it has
# no resume point of its own, and overwriting with an empty one would send the
# next cycle back to the head of the list — the bias, restored for free.

# The stdout summary is what a patrol reads first, so it must not imply a clean
# cycle when the clock cut one short — including when the truncation landed on
# the LAST candidate and the loop head therefore never fired.
BUDGET_NOTE=""
if [ "$BUDGET_SPENT" -eq 1 ] || [ "$TRUNCATED" -eq 1 ]; then
    BUDGET_NOTE=" — budget spent: examined=$EXAMINED of $TOTAL, $((TOTAL - EXAMINED)) candidate(s) deferred to the next cycle"
fi

if [ "$DRY_RUN" -eq 1 ]; then
    echo "polecat-worktree-reap: would reap=$REAPED skipped=$SKIPPED of $TOTAL (dry run — nothing removed; pass --no-dry-run to reap; log: $LOG_FILE)$BUDGET_NOTE"
else
    echo "polecat-worktree-reap: reaped=$REAPED skipped=$SKIPPED of $TOTAL (log: $LOG_FILE)$BUDGET_NOTE"
fi
