#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
SCRIPT="$ROOT/gastown/assets/scripts/polecat-worktree-reap.sh"

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

write_gc_stub() {
    local bin="$1"
    mkdir -p "$bin"
    cat >"$bin/gc" <<'SH'
#!/usr/bin/env sh
# Serves the two reads polecat-worktree-reap.sh performs, in both their
# rig-scoped and unscoped forms:
#   gc bd --rig <rig> show <bead> --json
#   gc session list --state=all --json
case "$1" in
    session)
        cat "$GC_SESSIONS_JSON"
        ;;
    bd)
        shift
        if [ "$1" = "--rig" ]; then shift 2; fi
        if [ "$1" = "show" ]; then
            jq -c --arg id "$2" '[.[] | select(.id == $id)]' "$GC_BEADS_JSON"
        else
            printf '[]'
        fi
        ;;
    *)
        printf '[]'
        ;;
esac
SH
    chmod +x "$bin/gc"
}

setup_rig() {
    local rig="$1"
    mkdir -p "$rig"
    git -C "$rig" init -q
    git -C "$rig" config user.email reap@test
    git -C "$rig" config user.name reap
    echo seed >"$rig/seed.txt"
    git -C "$rig" add seed.txt
    git -C "$rig" commit -qm seed
}

add_bead_worktree() {
    # add_bead_worktree <rig> <polecat-home> <bead-id>
    git -C "$1" worktree add -q "$2/worktrees/$3" --detach HEAD
}

test_reaps_only_closed_clean_unowned_bead_worktrees() {
    local tmp rig bin home beads sessions logdir
    tmp=$(mktemp -d)
    rig="$tmp/rig"
    bin="$tmp/bin"
    home="$tmp/city/.gc/worktrees/rig/polecats/nux"
    beads="$tmp/beads.json"
    sessions="$tmp/sessions.json"
    logdir="$tmp/logs"
    mkdir -p "$logdir"

    setup_rig "$rig"
    write_gc_stub "$bin"

    # The polecat's persistent agent-home worktree: no `worktrees/` parent
    # segment, so it must never be considered a candidate.
    git -C "$rig" worktree add -q "$home" --detach HEAD

    add_bead_worktree "$rig" "$home" wt-closed
    add_bead_worktree "$rig" "$home" wt-inprogress
    add_bead_worktree "$rig" "$home" wt-dirty
    add_bead_worktree "$rig" "$home" wt-live
    add_bead_worktree "$rig" "$home" wt-unknown

    # Another agent's per-bead worktree for the SAME closed bead. It is clean,
    # unowned, and named after a closed bead — every gate but the path shape
    # would pass. The witness reaps polecat worktrees only.
    local refinery="$tmp/city/.gc/worktrees/rig/refinery"
    add_bead_worktree "$rig" "$refinery" wt-closed

    echo scratch >"$home/worktrees/wt-dirty/seed.txt"

    cat >"$beads" <<'JSON'
[
  {"id":"wt-closed","status":"closed","metadata":{"polecat_session":"deadsess"}},
  {"id":"wt-inprogress","status":"in_progress","metadata":{"polecat_session":"deadsess"}},
  {"id":"wt-dirty","status":"closed","metadata":{"polecat_session":"deadsess"}},
  {"id":"wt-live","status":"closed","metadata":{"polecat_session":"livesess"}}
]
JSON

    cat >"$sessions" <<'JSON'
{"sessions":[
  {"id":"livesess","name":"livesess","state":"running","closed":false},
  {"id":"deadsess","name":"deadsess","state":"closed","closed":true}
]}
JSON

    GC_RIG=rig LOG_DIR="$logdir" GC_BEADS_JSON="$beads" GC_SESSIONS_JSON="$sessions" \
        PATH="$bin:$PATH" bash "$SCRIPT" "$rig" >"$tmp/out.txt" 2>&1 ||
        fail "reaper exited non-zero: $(cat "$tmp/out.txt")"

    [[ ! -e "$home/worktrees/wt-closed" ]] ||
        fail "a closed, clean, unowned bead worktree was not reaped"
    [[ -e "$home/worktrees/wt-inprogress" ]] ||
        fail "an in_progress bead worktree was reaped; only closed beads are disposable"
    [[ -e "$home/worktrees/wt-dirty" ]] ||
        fail "a worktree with uncommitted changes was reaped; work would be lost"
    [[ -e "$home/worktrees/wt-live" ]] ||
        fail "a worktree still owned by a live polecat session was reaped"
    [[ -e "$home/worktrees/wt-unknown" ]] ||
        fail "a worktree whose bead could not be read was reaped"
    [[ -e "$home/seed.txt" ]] ||
        fail "the polecat agent-home worktree was reaped; only per-bead worktrees are candidates"
    [[ -e "$tmp/city/.gc/worktrees/rig/refinery/worktrees/wt-closed" ]] ||
        fail "a non-polecat agent's per-bead worktree was reaped; the witness owns polecat worktrees only"
    [[ -e "$rig/seed.txt" ]] ||
        fail "the rig root worktree was touched"

    local log="$logdir/polecat-worktree-reap.log"
    [[ -f "$log" ]] || fail "reaper wrote no log"
    grep -F '"event":"worktree_reaped"' "$log" >/dev/null ||
        fail "the reap was not recorded in the log"
    grep -F '"bead":"wt-closed"' "$log" >/dev/null ||
        fail "the reaped bead was not named in the log"
    grep -F '"event":"worktree_dirty_kept"' "$log" >/dev/null ||
        fail "a dirty worktree kept was not reported for salvage"
    grep -F '"event":"worktree_owner_live"' "$log" >/dev/null ||
        fail "a live-owner deferral was not reported"
    grep -F '"event":"worktree_bead_unreadable"' "$log" >/dev/null ||
        fail "an unreadable bead was not reported"
    ! grep -F 'wt-inprogress' "$log" >/dev/null ||
        fail "an in_progress bead should be skipped silently, not logged as an incident"

    # Git's administrative view must agree with the filesystem.
    ! git -C "$rig" worktree list --porcelain | grep -F "$home/worktrees/wt-closed" >/dev/null ||
        fail "the reaped worktree is still registered with git"

    rm -rf "$tmp"
}

test_dry_run_removes_nothing_and_rerun_is_idempotent() {
    local tmp rig bin home beads sessions logdir
    tmp=$(mktemp -d)
    rig="$tmp/rig"
    bin="$tmp/bin"
    home="$tmp/city/.gc/worktrees/rig/polecats/nux"
    beads="$tmp/beads.json"
    sessions="$tmp/sessions.json"
    logdir="$tmp/logs"
    mkdir -p "$logdir"

    setup_rig "$rig"
    write_gc_stub "$bin"
    add_bead_worktree "$rig" "$home" wt-closed

    cat >"$beads" <<'JSON'
[{"id":"wt-closed","status":"closed","metadata":{"polecat_session":"deadsess"}}]
JSON
    printf '{"sessions":[]}' >"$sessions"

    GC_RIG=rig LOG_DIR="$logdir" GC_BEADS_JSON="$beads" GC_SESSIONS_JSON="$sessions" \
        PATH="$bin:$PATH" bash "$SCRIPT" "$rig" --dry-run >"$tmp/dry.txt" 2>&1 ||
        fail "dry run exited non-zero: $(cat "$tmp/dry.txt")"

    [[ -e "$home/worktrees/wt-closed" ]] ||
        fail "--dry-run removed a worktree"
    grep -F '"event":"worktree_reap_pending"' "$logdir/polecat-worktree-reap.log" >/dev/null ||
        fail "--dry-run did not report the pending reap"

    # A missing polecat_session must not read as "owned by a live session".
    GC_RIG=rig LOG_DIR="$logdir" GC_BEADS_JSON="$beads" GC_SESSIONS_JSON="$sessions" \
        PATH="$bin:$PATH" bash "$SCRIPT" "$rig" >/dev/null 2>&1 ||
        fail "reaper exited non-zero on the real run"
    [[ ! -e "$home/worktrees/wt-closed" ]] ||
        fail "the closed worktree survived the real run"

    # Second real run: nothing left to do, still exits clean.
    GC_RIG=rig LOG_DIR="$logdir" GC_BEADS_JSON="$beads" GC_SESSIONS_JSON="$sessions" \
        PATH="$bin:$PATH" bash "$SCRIPT" "$rig" >"$tmp/again.txt" 2>&1 ||
        fail "re-running the reaper on a clean tree failed: $(cat "$tmp/again.txt")"
    grep -F 'no per-bead polecat worktrees' "$tmp/again.txt" >/dev/null ||
        fail "a second run should find no candidates"

    rm -rf "$tmp"
}

test_reaps_only_closed_clean_unowned_bead_worktrees
test_dry_run_removes_nothing_and_rerun_is_idempotent

echo "polecat worktree reap tests passed"
