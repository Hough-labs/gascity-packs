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
#   gc bd --rig <rig> show <bead>... --json   (many ids in ONE call)
#   gc session list --state=all --json
#
# The `gc bd show` arm reproduces real bd's THREE observable behaviours for a
# missing id, because the reaper now decides transient-vs-permanent on bd's own
# error class and a stub that silently omits an id would test a bd that does not
# exist (gcp-0u14):
#   - an id that resolves      -> its row in the stdout array
#   - an id that does not      -> one stderr line, verbatim shape:
#                                 Error fetching <id>: no issue found matching "<id>"
#   - NO id resolves           -> an error OBJECT on stdout, exit 1
#
# Test hooks:
#   GC_BD_CALLS      append one byte per `gc bd show` call, so a test can
#                    assert the read is bulk and not per-worktree
#   GC_BD_DELAY      seconds to stall a bead read (budget tests)
#   GC_BD_STORE_ERROR non-empty: the read fails for a reason that is NOT
#                    "no such bead" — the transient case that must still retry
#   GC_BD_FUZZY      an id bd answers with a DIFFERENT row for (a fuzzy hit):
#                    no exact echo AND no not-found line, so the reaper can see
#                    neither a bead nor a verdict. Transient.
#   GC_SESSION_DELAY seconds to stall a roster read (budget tests)
case "$1" in
    session)
        if [ -n "${GC_SESSION_DELAY:-}" ]; then sleep "$GC_SESSION_DELAY"; fi
        cat "$GC_SESSIONS_JSON"
        ;;
    bd)
        shift
        if [ "$1" = "--rig" ]; then shift 2; fi
        if [ "$1" = "show" ]; then
            shift
            if [ -n "${GC_BD_CALLS:-}" ]; then printf 'x' >>"$GC_BD_CALLS"; fi
            if [ -n "${GC_BD_DELAY:-}" ]; then sleep "$GC_BD_DELAY"; fi
            if [ -n "${GC_BD_STORE_ERROR:-}" ]; then
                echo "Error: dial tcp 127.0.0.1:3307: connect: connection refused" >&2
                exit 1
            fi
            ids=""
            for a in "$@"; do
                case "$a" in
                    -*) continue ;;
                esac
                ids="$ids$a
"
            done
            rows=$(jq -c --arg ids "$ids" '
                ($ids | split("\n") | map(select(length > 0))) as $want
                | [ .[] | select(.id as $i | $want | index($i)) ]
            ' "$GC_BEADS_JSON")
            for a in $ids; do
                if [ "$a" = "${GC_BD_FUZZY:-}" ]; then
                    # Answered, but with somebody else's row. The reaper keys
                    # results by the id bd ECHOED, so this id gets no status.
                    rows=$(printf '%s' "$rows" |
                        jq -c --arg id "$a-other" '. + [{id:$id, status:"closed", metadata:{}}]')
                    continue
                fi
                if ! printf '%s' "$rows" | jq -e --arg id "$a" 'any(.id == $id)' >/dev/null; then
                    echo "Error fetching $a: no issue found matching \"$a\"" >&2
                fi
            done
            if [ "$(printf '%s' "$rows" | jq -r 'length')" = "0" ]; then
                printf '{"error":"no issues found matching the provided IDs","schema_version":1}'
                exit 1
            fi
            printf '%s' "$rows"
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

write_git_stub() {
    # Wraps the real git so the reaper's OWN git calls can be made slow or made
    # to fail. That is the only way to drive the not-attempted / timed-out /
    # failed classification from outside the script, and the distinction between
    # those three is exactly what these tests exist to hold (gcp-mqu9).
    #
    # Test hooks:
    #   GIT_PRUNE_DELAY   seconds to stall `git ... worktree prune`
    #   GIT_STATUS_DELAY  seconds to stall `git ... status`
    #   GIT_STATUS_FAIL   non-empty: `git ... status` exits 128 without running
    #   GIT_REVPARSE_DELAY seconds to stall `git ... rev-parse HEAD` (gate 5)
    #   GIT_REVPARSE_FAIL non-empty: that rev-parse exits 128 without running
    #   GIT_CONTAINS_DELAY seconds to stall `git ... branch --remotes --contains`
    #   GIT_CONTAINS_FAIL non-empty: that branch read exits 129 without running
    #   GIT_PRUNE_COUNT_FILE  one byte appended per `git ... worktree prune`
    #   GIT_LATER_PRUNE_DELAY seconds to stall every prune AFTER the first. The
    #                    reaper prunes once at startup and again between the two
    #                    halves of a removal, so this is the only way to hold the
    #                    process inside the removal window from outside it.
    #   GIT_REMOVE_HALFWAY_STALL seconds to hold `git ... worktree remove` open
    #                    HALF DONE — the `.git` file and the admin entry gone,
    #                    the tree still on disk. That is git's documented order
    #                    and the exact state winnow was left in (gcp-mves); the
    #                    stall models the SIGKILL landing in that window.
    #   GIT_DIRTY_AFTER_STATUS a worktree path to dirty immediately AFTER a
    #                    `git ... status` answers. The first caller sees a clean
    #                    tree and the next sees a dirty one, which is the only
    #                    way to drive a gate going stale between its check and
    #                    the removal it authorised.
    #
    # The gate-5 hooks exist for the same reason the gate-3 ones do: the
    # difference between "the probe ran and found nothing" and "the probe never
    # answered" is only observable from outside the script by making the probe
    # slow or broken (gcp-9ql4).
    local bin="$1" real
    real=$(command -v git)
    mkdir -p "$bin"
    cat >"$bin/git" <<SH
#!/usr/bin/env sh
case " \$* " in
    *" worktree prune "*)
        if [ -n "\${GIT_PRUNE_COUNT_FILE:-}" ]; then printf 'x' >>"\$GIT_PRUNE_COUNT_FILE"; fi
        if [ -n "\${GIT_PRUNE_DELAY:-}" ]; then sleep "\$GIT_PRUNE_DELAY"; fi
        if [ -n "\${GIT_LATER_PRUNE_DELAY:-}" ] && [ -n "\${GIT_PRUNE_COUNT_FILE:-}" ] &&
            [ "\$(wc -c <"\$GIT_PRUNE_COUNT_FILE" | tr -d ' ')" -gt 1 ]; then
            "$real" "\$@"
            sleep "\$GIT_LATER_PRUNE_DELAY"
            exit 0
        fi
        ;;
    *" worktree remove "*)
        if [ -n "\${GIT_REMOVE_HALFWAY_STALL:-}" ]; then
            # git drops the worktree .git file and the admin entry BEFORE it
            # unlinks the tree. Reproduce exactly that half-state, then hold it
            # open so the caller SIGKILL lands inside the window. The removal is
            # never completed: a killed pre_start does not get to finish.
            # (No backticks in here: the heredoc is unquoted so the stub can
            # bake in the real git path, and a backtick would be run at write
            # time rather than written out.)
            target=""
            repo=""
            want_repo=0
            for arg in "\$@"; do
                if [ "\$want_repo" = 1 ]; then repo="\$arg"; want_repo=0; continue; fi
                if [ "\$arg" = "-C" ]; then want_repo=1; continue; fi
                target="\$arg"
            done
            rm -f "\$target/.git"
            "$real" -C "\$repo" worktree prune
            sleep "\$GIT_REMOVE_HALFWAY_STALL"
            exit 0
        fi
        ;;
    *" status "*)
        if [ -n "\${GIT_STATUS_DELAY:-}" ]; then sleep "\$GIT_STATUS_DELAY"; fi
        if [ -n "\${GIT_STATUS_FAIL:-}" ]; then
            echo "fatal: simulated git status failure" >&2
            exit 128
        fi
        if [ -n "\${GIT_DIRTY_AFTER_STATUS:-}" ]; then
            out=\$("$real" "\$@"); rc=\$?
            printf '%s' "\$out"
            echo scratch >"\$GIT_DIRTY_AFTER_STATUS/went-dirty.txt"
            exit "\$rc"
        fi
        ;;
    *" rev-parse HEAD "*)
        if [ -n "\${GIT_REVPARSE_DELAY:-}" ]; then sleep "\$GIT_REVPARSE_DELAY"; fi
        if [ -n "\${GIT_REVPARSE_FAIL:-}" ]; then
            echo "fatal: simulated rev-parse failure" >&2
            exit 128
        fi
        ;;
    *" --remotes --contains "*)
        if [ -n "\${GIT_CONTAINS_DELAY:-}" ]; then sleep "\$GIT_CONTAINS_DELAY"; fi
        if [ -n "\${GIT_CONTAINS_FAIL:-}" ]; then
            echo "fatal: simulated remote-contains failure" >&2
            exit 129
        fi
        ;;
esac
exec "$real" "\$@"
SH
    chmod +x "$bin/git"
}

# reason_for <log> <event> — the `reason` field of the last line carrying <event>.
reason_for() {
    jq -r --arg e "$2" 'select(.event == $e) | .reason' "$1" | tail -n 1
}

# detail_for <log> <event> — the `detail` field of the last line carrying <event>.
detail_for() {
    jq -r --arg e "$2" 'select(.event == $e) | .detail' "$1" | tail -n 1
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


publish_rig() {
    # publish_rig <rig> <bare-remote> — give the rig a remote-tracking ref, so
    # `git branch --remotes --contains` has something to answer with. Gate 5
    # asks "does this content exist anywhere other than this directory", and a
    # bare remote is the only honest way to model that.
    git init -q --bare "$2"
    git -C "$1" remote add origin "$2"
    git -C "$1" push -q origin HEAD:refs/heads/main
    git -C "$1" fetch -q origin
}

strip_worktree() {
    # strip_worktree <rig> <worktree-path> — reproduce the residue an armed reap
    # left on winnow (gcp-mves): the directory stays on disk, its `.git` file is
    # gone, and git's admin entry for it is pruned away. Nothing about the shape
    # is inferred — it is what `git worktree remove` leaves when it is killed
    # after dropping git's view and before unlinking the tree.
    #
    # This is the case `git worktree list` structurally CANNOT enumerate, which
    # is why the reaper needs a second enumeration source that walks the disk.
    rm -f "$2/.git"
    git -C "$1" worktree prune
}

detach_worktree_admin() {
    # detach_worktree_admin <rig> <worktree-path> <admin-name> — unregister a
    # worktree from `git worktree list` while leaving it FULLY ADMINISTRABLE:
    # the admin entry is moved aside (same depth, so its relative `commondir`
    # still resolves) and the worktree's `.git` file is repointed at it.
    #
    # Residue git can still answer about must take the ordinary gates rather
    # than the residue path — a `git status` is available for it, so gate 3
    # binds exactly as it does for a registered worktree.
    mkdir -p "$1/.git/detached"
    mv "$1/.git/worktrees/$3" "$1/.git/detached/$3"
    printf 'gitdir: %s\n' "$1/.git/detached/$3" >"$2/.git"
}

interrupt_a_removal() {
    # interrupt_a_removal <tmp> <rig> <bin> <home> <beads> <sessions> <logdir>
    # — run the reaper live against one reapable worktree and SIGKILL it in the
    # middle of the removal.
    #
    # The kill is the whole of gcp-mves: pre_start is SIGKILLed at [session]
    # setup_timeout, and there is no way for the script to catch it. Both
    # removal sequences are held open so the kill lands inside whichever one the
    # script uses:
    #   GIT_REMOVE_HALFWAY_STALL   the OLD sequence — `git worktree remove` held
    #                              half done, git's view of the tree already
    #                              gone and the tree still on disk.
    #   GIT_LATER_PRUNE_DELAY      the NEW sequence — the prune that sits
    #                              between the rename and the `rm -rf`.
    # The budget is deliberately larger than the outer kill so the script's own
    # run_bounded does not end the stall first: what must end this process is
    # the SIGKILL, exactly as on a real rig.
    local tmp="$1" rig="$2" bin="$3" home="$4" beads="$5" sessions="$6" logdir="$7"

    kill_after 6 env GC_RIG=rig LOG_DIR="$logdir" GC_BEADS_JSON="$beads" \
        GC_SESSIONS_JSON="$sessions" GIT_PRUNE_COUNT_FILE="$tmp/prunes" \
        GIT_LATER_PRUNE_DELAY=60 GIT_REMOVE_HALFWAY_STALL=60 PATH="$bin:$PATH" \
        bash "$SCRIPT" "$rig" --budget 45 --no-dry-run >"$tmp/interrupted.txt" 2>&1
}

kill_after() {
    # kill_after <seconds> <cmd...> — run <cmd> and SIGKILL it after <seconds>.
    # Not `timeout`: coreutils is not on a stock macOS, and the reaper's own
    # run_bounded carries a hand-rolled fallback for exactly that reason, so a
    # test of the reaper must not need it either. SIGKILL specifically — the
    # signal the script cannot catch, which is the premise of the bead.
    local secs="$1"
    shift
    "$@" &
    local pid=$! killer
    (
        sleep "$secs"
        kill -KILL "$pid" 2>/dev/null || true
    ) &
    killer=$!
    wait "$pid" 2>/dev/null || true
    kill "$killer" 2>/dev/null || true
    wait "$killer" 2>/dev/null || true
}

# unmarked_half_removed <scan-root> — print every directory under <scan-root>
# that is simultaneously present on disk, missing a `.git`, and NOT carrying the
# `.reaping` marker. That set must be empty after ANY interrupted run: it is the
# state no gate can enumerate and no log line reports, and buying its absence is
# what this whole bead is for.
unmarked_half_removed() {
    local root="$1" entry
    for entry in "$root"/*; do
        [[ -d "$entry" ]] || continue
        [[ "$entry" != *.reaping ]] || continue
        [[ ! -e "$entry/.git" ]] || continue
        printf '%s\n' "$entry"
    done
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

    # wt-unknown is the TRANSIENT unreadable case, so it must be a lookup bd
    # could not answer rather than one it answered "no such bead" to — those are
    # different verdicts now (gcp-0u14). A fuzzy hit is the real shape of it:
    # bd replies, but with a different id, so this worktree gets no status and
    # no not-found line either.
    GC_RIG=rig LOG_DIR="$logdir" GC_BEADS_JSON="$beads" GC_SESSIONS_JSON="$sessions" \
        GC_BD_FUZZY=wt-unknown \
        PATH="$bin:$PATH" bash "$SCRIPT" "$rig" --no-dry-run >"$tmp/out.txt" 2>&1 ||
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

test_real_removal_is_opt_in() {
    # Staged rollout: the witness pre_start passes no --no-dry-run, so the
    # bare invocation must behave exactly like --dry-run. If this ever
    # regresses, real removal goes live on the first pin bump with no
    # observation window.
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
        PATH="$bin:$PATH" bash "$SCRIPT" "$rig" >"$tmp/out.txt" 2>&1 ||
        fail "default run exited non-zero: $(cat "$tmp/out.txt")"

    [[ -e "$home/worktrees/wt-closed" ]] ||
        fail "the default run removed a worktree; real removal must be opt-in"
    grep -F '"event":"worktree_reap_pending"' "$logdir/polecat-worktree-reap.log" >/dev/null ||
        fail "the default run did not report the pending reap"
    grep -F '"dry_run":true' "$logdir/polecat-worktree-reap.log" >/dev/null ||
        fail "the default run did not record itself as a dry run"

    # And the wiring the witness actually ships must not carry the opt-in.
    ! grep -E '^pre_start = .*--no-dry-run' "$ROOT/gastown/agents/witness/agent.toml" >/dev/null ||
        fail "witness pre_start enables live removal; the rollout must stay staged"

    rm -rf "$tmp"
}

test_unreadable_session_roster_skips_the_reap() {
    # A confirmation read that FAILS is not proof of absence. Both a roster
    # command that errors and one that returns unparseable output must land in
    # `unconfirmed` and skip, never fall through to a removal.
    local tmp rig bin home beads logdir
    tmp=$(mktemp -d)
    rig="$tmp/rig"
    bin="$tmp/bin"
    home="$tmp/city/.gc/worktrees/rig/polecats/nux"
    beads="$tmp/beads.json"
    logdir="$tmp/logs"
    mkdir -p "$logdir"

    setup_rig "$rig"
    write_gc_stub "$bin"
    add_bead_worktree "$rig" "$home" wt-closed

    cat >"$beads" <<'JSON'
[{"id":"wt-closed","status":"closed","metadata":{"polecat_session":"deadsess"}}]
JSON

    # Case 1: the roster command fails outright (missing file -> cat exits 1).
    GC_RIG=rig LOG_DIR="$logdir" GC_BEADS_JSON="$beads" \
        GC_SESSIONS_JSON="$tmp/no-such-roster.json" \
        PATH="$bin:$PATH" bash "$SCRIPT" "$rig" --no-dry-run >"$tmp/fail.txt" 2>&1 ||
        fail "reaper exited non-zero on an unreadable roster: $(cat "$tmp/fail.txt")"

    [[ -e "$home/worktrees/wt-closed" ]] ||
        fail "a failed session-roster read let the reap proceed; gate 4 failed open"
    grep -F '"event":"worktree_owner_unconfirmed"' "$logdir/polecat-worktree-reap.log" >/dev/null ||
        fail "an unconfirmed liveness verdict was not reported"

    # Case 2: the roster is present but not JSON.
    printf 'not json at all' >"$tmp/bad.json"
    GC_RIG=rig LOG_DIR="$logdir" GC_BEADS_JSON="$beads" GC_SESSIONS_JSON="$tmp/bad.json" \
        PATH="$bin:$PATH" bash "$SCRIPT" "$rig" --no-dry-run >"$tmp/bad.txt" 2>&1 ||
        fail "reaper exited non-zero on a malformed roster: $(cat "$tmp/bad.txt")"

    [[ -e "$home/worktrees/wt-closed" ]] ||
        fail "a malformed session roster let the reap proceed; gate 4 failed open"

    # Case 3: the same worktree IS reaped once the roster reads cleanly, so the
    # skip above is the guard working and not the reaper being inert.
    printf '{"sessions":[]}' >"$tmp/good.json"
    GC_RIG=rig LOG_DIR="$logdir" GC_BEADS_JSON="$beads" GC_SESSIONS_JSON="$tmp/good.json" \
        PATH="$bin:$PATH" bash "$SCRIPT" "$rig" --no-dry-run >"$tmp/good.txt" 2>&1 ||
        fail "reaper exited non-zero on a readable roster: $(cat "$tmp/good.txt")"
    [[ ! -e "$home/worktrees/wt-closed" ]] ||
        fail "a readable roster with no live owner should have reaped the worktree"

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
        PATH="$bin:$PATH" bash "$SCRIPT" "$rig" --no-dry-run >/dev/null 2>&1 ||
        fail "reaper exited non-zero on the real run"
    [[ ! -e "$home/worktrees/wt-closed" ]] ||
        fail "the closed worktree survived the real run"

    # Second real run: nothing left to do, still exits clean.
    GC_RIG=rig LOG_DIR="$logdir" GC_BEADS_JSON="$beads" GC_SESSIONS_JSON="$sessions" \
        PATH="$bin:$PATH" bash "$SCRIPT" "$rig" --no-dry-run >"$tmp/again.txt" 2>&1 ||
        fail "re-running the reaper on a clean tree failed: $(cat "$tmp/again.txt")"
    grep -F 'no per-bead polecat worktrees' "$tmp/again.txt" >/dev/null ||
        fail "a second run should find no candidates"

    rm -rf "$tmp"
}

test_bead_status_is_read_in_one_bulk_query() {
    # The N+1 that killed winnow's witness for 26h (gcp-ntbf): one
    # `gc bd show` per candidate worktree, ~5.4s each against an external
    # Dolt, inside a pre_start bounded at 10s. The read must be flat in the
    # number of worktrees, so assert the CALL COUNT, not the wall time —
    # a fast stub would hide a linear read on a slow store.
    #
    # FLAT, not a fixed number. A live cycle now takes two bulk reads: the one
    # that feeds the gates, and one that renews the bead facts at the point of
    # use before the first removal (gcp-mves). Both are for the WHOLE candidate
    # set, taken once per cycle. Pinning the count at 1 would forbid the second
    # read without expressing the invariant, so the fixture is run at two sizes
    # and the counts must match: whatever the reads cost, it must not grow with
    # the rig.
    local four eight
    four=$(bulk_read_calls_for 4)
    eight=$(bulk_read_calls_for 8)

    [[ "$four" == "$eight" ]] ||
        fail "bead reads grew with the candidate set: $four call(s) for 4 worktrees, $eight for 8. The read must be flat in the number of worktrees (gcp-ntbf)"
    (( eight <= 2 )) ||
        fail "a live cycle issued $eight bulk bead reads; it takes at most two — one for the gates, one to renew them at the point of use"
}

bulk_read_calls_for() {
    # bulk_read_calls_for <n> — reap <n> closed worktrees live and echo how many
    # `gc bd show` calls that cost. One open bead is mixed in so the run also
    # proves the join still keys statuses to the right worktree at each size.
    local n="$1" tmp rig bin home beads sessions logdir calls i
    tmp=$(mktemp -d)
    rig="$tmp/rig"
    bin="$tmp/bin"
    home="$tmp/city/.gc/worktrees/rig/polecats/nux"
    beads="$tmp/beads.json"
    sessions="$tmp/sessions.json"
    logdir="$tmp/logs"
    calls="$tmp/bd-calls"
    mkdir -p "$logdir"

    setup_rig "$rig"
    write_gc_stub "$bin"

    local ids=()
    for i in $(seq 1 "$n"); do
        add_bead_worktree "$rig" "$home" "wt-$i"
        ids+=("wt-$i")
    done

    # wt-1 stays open: an open bead's worktree must survive at every size.
    jq -n --args '[ $ARGS.positional[] | {
            id: .,
            status: (if . == "wt-1" then "open" else "closed" end),
            metadata: { polecat_session: "deadsess" }
        } ]' "${ids[@]}" >"$beads"
    printf '{"sessions":[]}' >"$sessions"

    GC_RIG=rig LOG_DIR="$logdir" GC_BEADS_JSON="$beads" GC_SESSIONS_JSON="$sessions" \
        GC_BD_CALLS="$calls" GC_REAP_BUDGET_SECONDS=120 PATH="$bin:$PATH" \
        bash "$SCRIPT" "$rig" --no-dry-run \
        >"$tmp/out.txt" 2>&1 || fail "reaper exited non-zero: $(cat "$tmp/out.txt")"

    for i in $(seq 2 "$n"); do
        [[ ! -e "$home/worktrees/wt-$i" ]] ||
            fail "the bulk read lost a closed bead at size $n: wt-$i survived"
    done
    [[ -e "$home/worktrees/wt-1" ]] ||
        fail "the bulk read mixed up bead identities at size $n: an open bead's worktree was reaped"

    wc -c <"$calls" | tr -d ' '
    rm -rf "$tmp"
}

test_a_large_candidate_set_does_not_overflow_the_join() {
    # The bulk read answers with whole bead records, and bead descriptions run
    # to kilobytes each. Handing that payload to jq as a command-line argument
    # trips ARG_MAX (or Linux's 128KB-per-argument limit) on exactly the rigs
    # that need reaping most — and it fails SILENTLY: jq never runs, the join
    # is empty, and the run reports a clean cycle that examined nothing. So
    # this fixture is deliberately fat rather than merely numerous.
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

    local i ids=()
    for i in $(seq 1 25); do
        add_bead_worktree "$rig" "$home" "wt-bulk-$i"
        ids+=("wt-bulk-$i")
    done

    # ~40KB of description per bead: ~1.6MB across the set, past both limits.
    jq -n --args '[ $ARGS.positional[] | {
            id: .,
            status: "closed",
            metadata: { polecat_session: "deadsess" },
            description: ("x" * 60000)
        } ]' "${ids[@]}" >"$beads"
    printf '{"sessions":[]}' >"$sessions"

    # Dry run, and a budget far larger than this fixture needs: what is under
    # test is whether every candidate reaches a decision, not how many removals
    # fit in a cycle. A real removal pass would hit the budget partway through
    # (by design) and mask the thing being measured.
    GC_RIG=rig LOG_DIR="$logdir" GC_BEADS_JSON="$beads" GC_SESSIONS_JSON="$sessions" \
        GC_REAP_BUDGET_SECONDS=120 PATH="$bin:$PATH" bash "$SCRIPT" "$rig" --dry-run \
        >"$tmp/out.txt" 2>&1 || fail "reaper exited non-zero on a large candidate set: $(cat "$tmp/out.txt")"

    grep -F 'would reap=25 skipped=0 of 25' "$tmp/out.txt" >/dev/null ||
        fail "the bulk join dropped candidates on a large set: $(cat "$tmp/out.txt")"
    local decided
    decided=$(grep -c -F '"event":"worktree_reap_pending"' "$logdir/polecat-worktree-reap.log")
    [[ "$decided" == "25" ]] ||
        fail "only $decided of 25 candidates reached a decision"

    rm -rf "$tmp"
}

test_budget_expiry_yields_the_witness_start() {
    # The invariant the header states and the outage broke: housekeeping must
    # be incapable of preventing the witness from starting. Every slow read is
    # bounded by the run's own budget, and an expired budget exits 0 having
    # done what it could — it never waits to be SIGKILLed by the caller.
    local tmp rig bin home beads sessions logdir started elapsed
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
    add_bead_worktree "$rig" "$home" wt-alpha
    add_bead_worktree "$rig" "$home" wt-beta

    cat >"$beads" <<'JSON'
[
  {"id":"wt-alpha","status":"closed","metadata":{"polecat_session":"deadsess"}},
  {"id":"wt-beta","status":"closed","metadata":{"polecat_session":"deadsess"}}
]
JSON
    printf '{"sessions":[]}' >"$sessions"

    # Case 1: the bead store is slower than the whole budget. The run must cut
    # the read off itself and finish well before the stub would have returned.
    # Budgeted through the env var so this stays a behavioural assertion — a
    # build that simply ignores the budget hangs here and fails on elapsed
    # time, rather than being let off with an unknown-flag error.
    #
    # The budget has to leave room for the run to REACH the bead read, or the
    # verdict is `budget_spent_before_bead_query` — also correct, and not the
    # one under test. Measured best-of-3 from start to first decision with 20
    # candidates: 3s, and identical on the pre-gcp-mves script, so this is the
    # cost of a cycle rather than anything the residue walk added. The stall is
    # 20s, so any budget under it still produces the timeout being asserted.
    started=$SECONDS
    GC_RIG=rig LOG_DIR="$logdir" GC_BEADS_JSON="$beads" GC_SESSIONS_JSON="$sessions" \
        GC_BD_DELAY=20 GC_REAP_BUDGET_SECONDS=6 PATH="$bin:$PATH" bash "$SCRIPT" "$rig" --no-dry-run \
        >"$tmp/slow.txt" 2>&1 || fail "a slow bead store made the reaper exit non-zero: $(cat "$tmp/slow.txt")"
    elapsed=$((SECONDS - started))

    [[ "$elapsed" -lt 10 ]] ||
        fail "the reaper waited ${elapsed}s on a 2s budget; a slow read is not bounded"
    [[ -e "$home/worktrees/wt-alpha" ]] ||
        fail "a worktree was reaped on a bead read that never answered"
    grep -F '"event":"worktree_bead_query_failed"' "$logdir/polecat-worktree-reap.log" >/dev/null ||
        fail "the timed-out bead query was not recorded"

    # Case 2: the budget runs out MID-LOOP. Remaining candidates are deferred
    # to the next cycle and the run still exits clean. Same headroom reasoning:
    # too small a budget is spent before the loop is entered at all, and the run
    # then exits early with a truncation instead of reaching the exhaustion this
    # asserts. With room to reach the loop it is deterministic — the first
    # candidate's roster read is bounded by whatever is left, so it consumes the
    # remainder and the second candidate always finds the budget gone.
    started=$SECONDS
    GC_RIG=rig LOG_DIR="$logdir" GC_BEADS_JSON="$beads" GC_SESSIONS_JSON="$sessions" \
        GC_SESSION_DELAY=20 PATH="$bin:$PATH" bash "$SCRIPT" "$rig" --no-dry-run --budget 6 \
        >"$tmp/mid.txt" 2>&1 || fail "an exhausted budget made the reaper exit non-zero: $(cat "$tmp/mid.txt")"
    elapsed=$((SECONDS - started))

    [[ "$elapsed" -lt 15 ]] ||
        fail "the reaper waited ${elapsed}s on a 6s budget; the roster read is not bounded"
    grep -F '"event":"worktree_budget_exhausted"' "$logdir/polecat-worktree-reap.log" >/dev/null ||
        fail "an exhausted budget was not recorded"
    [[ -e "$home/worktrees/wt-alpha" && -e "$home/worktrees/wt-beta" ]] ||
        fail "a worktree was reaped with an unreadable session roster"
    grep -F 'deferred to the next cycle' "$tmp/mid.txt" >/dev/null ||
        fail "the run did not report the candidates it deferred"

    # And the budget must be a real bound, not a way to disable the reaper:
    # the same worktrees reap normally once the reads are fast again.
    GC_RIG=rig LOG_DIR="$logdir" GC_BEADS_JSON="$beads" GC_SESSIONS_JSON="$sessions" \
        PATH="$bin:$PATH" bash "$SCRIPT" "$rig" --no-dry-run >"$tmp/fast.txt" 2>&1 ||
        fail "reaper exited non-zero on a fast run: $(cat "$tmp/fast.txt")"
    [[ ! -e "$home/worktrees/wt-alpha" && ! -e "$home/worktrees/wt-beta" ]] ||
        fail "the budgeted paths left the reaper inert on a healthy run"

    rm -rf "$tmp"
}

test_every_line_is_stamped_at_the_event_not_at_the_run() {
    # The log is forensics. It used to stamp every line with the RUN's start
    # time, so a cycle that spent its whole budget was indistinguishable from an
    # instant one and the order of a slow cycle's decisions was unrecoverable.
    # `ts` must advance with the events; `run_started` keeps the grouping.
    local tmp rig bin home beads sessions logdir log stamps
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

    # wt-early is decided at the top of the loop, before anything slow runs.
    # wt-late is decided after the roster read, which the stub stalls for 2s.
    add_bead_worktree "$rig" "$home" wt-early
    add_bead_worktree "$rig" "$home" wt-late

    cat >"$beads" <<'JSON'
[{"id":"wt-late","status":"closed","metadata":{"polecat_session":"deadsess"}}]
JSON
    printf '{"sessions":[]}' >"$sessions"

    GC_RIG=rig LOG_DIR="$logdir" GC_BEADS_JSON="$beads" GC_SESSIONS_JSON="$sessions" \
        GC_SESSION_DELAY=2 GC_REAP_BUDGET_SECONDS=30 PATH="$bin:$PATH" \
        bash "$SCRIPT" "$rig" --dry-run >"$tmp/out.txt" 2>&1 ||
        fail "reaper exited non-zero: $(cat "$tmp/out.txt")"

    log="$logdir/polecat-worktree-reap.log"
    stamps=$(jq -r '.ts' "$log" | sort -u | wc -l | tr -d ' ')
    [[ "$stamps" -ge 2 ]] ||
        fail "all $stamps distinct ts value(s) across a run that spent 2s; lines are stamped with the run's start time, not the event's"

    [[ "$(jq -r '.run_started' "$log" | sort -u | wc -l | tr -d ' ')" == "1" ]] ||
        fail "run_started differs within one run; the log can no longer be grouped into cycles"

    # And the budget field must be real, not a constant.
    jq -e 'all(.budget_remaining; . <= 30 and . >= 0)' "$log" >/dev/null ||
        fail "budget_remaining is not a plausible seconds-left reading"

    rm -rf "$tmp"
}

test_budget_truncation_is_not_reported_as_an_external_failure() {
    # The defect: a check the budget never let run was reported with the SAME
    # wording as a check that ran and failed, naming a subsystem this run never
    # spoke to. Twice that sent an investigation at a healthy Dolt server.
    local tmp rig bin home beads sessions logdir log
    tmp=$(mktemp -d)
    rig="$tmp/rig"
    bin="$tmp/bin"
    home="$tmp/city/.gc/worktrees/rig/polecats/nux"
    beads="$tmp/beads.json"
    sessions="$tmp/sessions.json"
    logdir="$tmp/logs"
    log="$logdir/polecat-worktree-reap.log"
    mkdir -p "$logdir"

    setup_rig "$rig"
    write_gc_stub "$bin"
    write_git_stub "$bin"
    add_bead_worktree "$rig" "$home" wt-closed

    cat >"$beads" <<'JSON'
[{"id":"wt-closed","status":"closed","metadata":{"polecat_session":"deadsess"}}]
JSON
    printf '{"sessions":[]}' >"$sessions"

    # Case 1: the budget is gone before the candidate list is even read. The run
    # used to print "no per-bead polecat worktrees under <rig>" — a claim about
    # the rig it had not looked at — and log nothing at all.
    GC_RIG=rig LOG_DIR="$logdir" GC_BEADS_JSON="$beads" GC_SESSIONS_JSON="$sessions" \
        GIT_PRUNE_DELAY=10 GC_REAP_BUDGET_SECONDS=2 PATH="$bin:$PATH" \
        bash "$SCRIPT" "$rig" --no-dry-run >"$tmp/nolist.txt" 2>&1 ||
        fail "reaper exited non-zero when the budget ran out early: $(cat "$tmp/nolist.txt")"

    ! grep -F 'no per-bead polecat worktrees' "$tmp/nolist.txt" >/dev/null ||
        fail "the run claimed the rig has no candidates without ever reading the worktree list"
    [[ "$(reason_for "$log" worktree_budget_truncated)" == "budget_spent_before_worktree_list" ]] ||
        fail "a worktree list the budget never allowed was not recorded as truncation"
    [[ -e "$home/worktrees/wt-closed" ]] ||
        fail "a worktree was reaped on a cycle that enumerated nothing"

    # Case 2: the bead read RAN and overran. That is a real timeout, so it keeps
    # worktree_bead_query_failed — but it must say it timed out and name the
    # seconds it was given, not imply the store answered with garbage.
    #
    # The budget must leave enough room that the CLASSIFICATION decides this,
    # not the machine. A run spends ~1s reaching the bead read (measured), so a
    # 2s budget could land on `skipped` under load — which is a different, also
    # correct, verdict, and not the one under test. Any budget below the 20s
    # stall still produces the timeout, so buy the headroom.
    rm -f "$log"
    GC_RIG=rig LOG_DIR="$logdir" GC_BEADS_JSON="$beads" GC_SESSIONS_JSON="$sessions" \
        GC_BD_DELAY=20 GC_REAP_BUDGET_SECONDS=6 PATH="$bin:$PATH" \
        bash "$SCRIPT" "$rig" --no-dry-run >"$tmp/slowbd.txt" 2>&1 ||
        fail "reaper exited non-zero on a slow bead store: $(cat "$tmp/slowbd.txt")"

    [[ "$(reason_for "$log" worktree_bead_query_failed)" == "bead_query_timed_out" ]] ||
        fail "a bead read that overran was not reported as a timeout"
    [[ "$(detail_for "$log" worktree_bead_query_failed)" == *"did not answer within"* ]] ||
        fail "the bead-read timeout does not say how long it was given: $(detail_for "$log" worktree_bead_query_failed)"
    [[ "$(detail_for "$log" worktree_bead_query_failed)" != *"no usable JSON"* ]] ||
        fail "a timed-out bead read still claims the store returned unusable JSON"

    # Case 3: the roster read overran. Same rule — it names the bound it hit, so
    # a reader checks the budget before suspecting the session roster. Same
    # headroom reasoning as case 2, and the roster read sits later in the run
    # than the bead read, so it needs at least as much.
    rm -f "$log"
    GC_RIG=rig LOG_DIR="$logdir" GC_BEADS_JSON="$beads" GC_SESSIONS_JSON="$sessions" \
        GC_SESSION_DELAY=20 GC_REAP_BUDGET_SECONDS=6 PATH="$bin:$PATH" \
        bash "$SCRIPT" "$rig" --no-dry-run >"$tmp/slowsess.txt" 2>&1 ||
        fail "reaper exited non-zero on a slow session roster: $(cat "$tmp/slowsess.txt")"

    [[ "$(reason_for "$log" worktree_owner_unconfirmed)" == "roster_read_timed_out" ]] ||
        fail "a roster read that overran was not distinguished from one that failed"
    [[ "$(detail_for "$log" worktree_owner_unconfirmed)" == *"budget"* ]] ||
        fail "the roster timeout does not point at the budget it hit"
    [[ -e "$home/worktrees/wt-closed" ]] ||
        fail "a worktree was reaped with liveness unconfirmed"

    # Case 4: the roster command genuinely errors, and separately answers with a
    # shape we do not recognise. Those are the two that DO implicate the roster.
    rm -f "$log"
    GC_RIG=rig LOG_DIR="$logdir" GC_BEADS_JSON="$beads" \
        GC_SESSIONS_JSON="$tmp/no-such-roster.json" PATH="$bin:$PATH" \
        bash "$SCRIPT" "$rig" --no-dry-run >/dev/null 2>&1 ||
        fail "reaper exited non-zero on a failing roster read"
    [[ "$(reason_for "$log" worktree_owner_unconfirmed)" == "roster_read_failed" ]] ||
        fail "a roster command that errored was not reported as a failed read"

    rm -f "$log"
    printf 'not json at all' >"$tmp/bad.json"
    GC_RIG=rig LOG_DIR="$logdir" GC_BEADS_JSON="$beads" GC_SESSIONS_JSON="$tmp/bad.json" \
        PATH="$bin:$PATH" bash "$SCRIPT" "$rig" --no-dry-run >/dev/null 2>&1 ||
        fail "reaper exited non-zero on a malformed roster"
    [[ "$(reason_for "$log" worktree_owner_unconfirmed)" == "roster_unparseable" ]] ||
        fail "a roster that answered with an unknown shape was not distinguished from a failed read"

    rm -rf "$tmp"
}

test_git_status_failure_is_distinguished_from_a_short_budget() {
    # `worktree_status_unreadable` used to say "git status failed in the
    # worktree" whether git status failed, was cut off, or was never run.
    # gcp-3ty was labelled that way and its worktree is perfectly clean.
    local tmp rig bin home beads sessions logdir log
    tmp=$(mktemp -d)
    rig="$tmp/rig"
    bin="$tmp/bin"
    home="$tmp/city/.gc/worktrees/rig/polecats/nux"
    beads="$tmp/beads.json"
    sessions="$tmp/sessions.json"
    logdir="$tmp/logs"
    log="$logdir/polecat-worktree-reap.log"
    mkdir -p "$logdir"

    setup_rig "$rig"
    write_gc_stub "$bin"
    write_git_stub "$bin"
    add_bead_worktree "$rig" "$home" wt-closed

    cat >"$beads" <<'JSON'
[{"id":"wt-closed","status":"closed","metadata":{"polecat_session":"deadsess"}}]
JSON
    printf '{"sessions":[]}' >"$sessions"

    # Case 1: git status really did run and really did fail.
    GC_RIG=rig LOG_DIR="$logdir" GC_BEADS_JSON="$beads" GC_SESSIONS_JSON="$sessions" \
        GIT_STATUS_FAIL=1 GC_REAP_BUDGET_SECONDS=30 PATH="$bin:$PATH" \
        bash "$SCRIPT" "$rig" --no-dry-run >"$tmp/failed.txt" 2>&1 ||
        fail "reaper exited non-zero on a failing git status: $(cat "$tmp/failed.txt")"

    [[ "$(reason_for "$log" worktree_status_unreadable)" == "git_status_failed" ]] ||
        fail "a genuine git status failure was not reported as one"
    [[ "$(detail_for "$log" worktree_status_unreadable)" == *"exited 128"* ]] ||
        fail "the git status failure does not name the exit code: $(detail_for "$log" worktree_status_unreadable)"
    [[ -e "$home/worktrees/wt-closed" ]] ||
        fail "a worktree whose git status failed was reaped"

    # Case 2: git status was cut off by the budget. Same event — it did run —
    # but the reason and detail must send the reader at the clock, not at a
    # checkout that is fine.
    rm -f "$log"
    GC_RIG=rig LOG_DIR="$logdir" GC_BEADS_JSON="$beads" GC_SESSIONS_JSON="$sessions" \
        GIT_STATUS_DELAY=20 GC_REAP_BUDGET_SECONDS=3 PATH="$bin:$PATH" \
        bash "$SCRIPT" "$rig" --no-dry-run >"$tmp/slow.txt" 2>&1 ||
        fail "reaper exited non-zero on a slow git status: $(cat "$tmp/slow.txt")"

    [[ "$(reason_for "$log" worktree_status_unreadable)" == "git_status_timed_out" ]] ||
        fail "a git status cut short by the budget was reported as a failure of the checkout"
    [[ "$(detail_for "$log" worktree_status_unreadable)" == *"budget"* ]] ||
        fail "the git status timeout does not point at the budget it hit"
    [[ -e "$home/worktrees/wt-closed" ]] ||
        fail "a worktree was reaped without its status ever being read"

    rm -rf "$tmp"
}

test_dotted_sub_bead_worktrees_are_enumerated() {
    # A split bead's id carries a dot (`feryn-derh.1`), and the leaf whitelist
    # did not admit one — so every sub-bead worktree was dropped during
    # CANDIDATE ENUMERATION, upstream of the bulk read, of `git status`, and of
    # any `record` call. No event of any kind was emitted, so the log read as a
    # complete clean pass while on winnow half the eligible set was invisible
    # (gcp-ac59). The silence is the defect — it hid the data-at-risk case as
    # well as the routine one — so this pins the reap AND the enumeration.
    local tmp rig bin home beads sessions logdir log
    tmp=$(mktemp -d)
    rig="$tmp/rig"
    bin="$tmp/bin"
    home="$tmp/city/.gc/worktrees/rig/polecats/nux"
    beads="$tmp/beads.json"
    sessions="$tmp/sessions.json"
    logdir="$tmp/logs"
    log="$logdir/polecat-worktree-reap.log"
    mkdir -p "$logdir"

    setup_rig "$rig"
    write_gc_stub "$bin"

    add_bead_worktree "$rig" "$home" wt-plain
    add_bead_worktree "$rig" "$home" wt-split.1
    add_bead_worktree "$rig" "$home" wt-split.10

    # Admitting the dot must not admit path traversal, and a leaf that is not a
    # bead id at all is still not ours to touch.
    add_bead_worktree "$rig" "$home" 'a..b'
    add_bead_worktree "$rig" "$home" '.hidden'

    cat >"$beads" <<'JSON'
[
  {"id":"wt-plain","status":"closed","metadata":{"polecat_session":"deadsess"}},
  {"id":"wt-split.1","status":"closed","metadata":{"polecat_session":"deadsess"}},
  {"id":"wt-split.10","status":"closed","metadata":{"polecat_session":"deadsess"}}
]
JSON
    printf '{"sessions":[]}' >"$sessions"

    GC_RIG=rig LOG_DIR="$logdir" GC_BEADS_JSON="$beads" GC_SESSIONS_JSON="$sessions" \
        PATH="$bin:$PATH" bash "$SCRIPT" "$rig" --no-dry-run >"$tmp/out.txt" 2>&1 ||
        fail "reaper exited non-zero: $(cat "$tmp/out.txt")"

    [[ ! -e "$home/worktrees/wt-split.1" ]] ||
        fail "a dotted sub-bead worktree was not reaped; the leaf whitelist still drops the dot"
    [[ ! -e "$home/worktrees/wt-split.10" ]] ||
        fail "a multi-digit dotted sub-bead worktree was not reaped"
    [[ ! -e "$home/worktrees/wt-plain" ]] ||
        fail "an undotted worktree was not reaped; the whitelist change broke the normal case"

    [[ -e "$home/worktrees/a..b" ]] ||
        fail "a leaf containing .. was reaped; widening the class must not admit traversal"
    [[ -e "$home/worktrees/.hidden" ]] ||
        fail "a dot-prefixed leaf was reaped; a bead id never starts with a separator"

    # Enumeration, not just the outcome: a dropped candidate produces NO event,
    # which is the half of this defect that made the log lie.
    [[ "$(jq -r 'select(.bead == "wt-split.1") | .event' "$log" | tail -n 1)" == "worktree_reaped" ]] ||
        fail "the dotted worktree produced no reap event; it was never enumerated"
    ! grep -F '"bead":"a..b"' "$log" >/dev/null ||
        fail "a traversal-shaped leaf was enumerated as a candidate"
    ! grep -F '"bead":".hidden"' "$log" >/dev/null ||
        fail "a dot-prefixed leaf was enumerated as a candidate"

    rm -rf "$tmp"
}

test_a_permanently_missing_bead_is_decided_not_retried() {
    # `g7nf-base` is a hand-made scratch worktree under `worktrees/`: bd answers
    # "no issue found matching" for it and always will. Treating that as a
    # transient store failure retried it every cycle forever and pinned the
    # parent polecat home open with it (gcp-0u14). It must be DECIDED — on the
    # worktree's own evidence, since no bead closure will ever authorise it.
    local tmp rig bin home beads sessions logdir log
    tmp=$(mktemp -d)
    rig="$tmp/rig"
    bin="$tmp/bin"
    home="$tmp/city/.gc/worktrees/rig/polecats/nux"
    beads="$tmp/beads.json"
    sessions="$tmp/sessions.json"
    logdir="$tmp/logs"
    log="$logdir/polecat-worktree-reap.log"
    mkdir -p "$logdir"

    setup_rig "$rig"
    publish_rig "$rig" "$tmp/remote.git"
    write_gc_stub "$bin"

    add_bead_worktree "$rig" "$home" wt-closed
    add_bead_worktree "$rig" "$home" wt-gone-published
    add_bead_worktree "$rig" "$home" wt-gone-unpublished
    add_bead_worktree "$rig" "$home" wt-gone-dirty

    # Gate 5's failing case: a commit that exists in this directory and nowhere
    # else. Removing it would be the only copy lost.
    echo local >"$home/worktrees/wt-gone-unpublished/local.txt"
    git -C "$home/worktrees/wt-gone-unpublished" add local.txt
    git -C "$home/worktrees/wt-gone-unpublished" commit -qm "unpublished work"

    echo scratch >"$home/worktrees/wt-gone-dirty/seed.txt"

    cat >"$beads" <<'JSON'
[{"id":"wt-closed","status":"closed","metadata":{"polecat_session":"deadsess"}}]
JSON
    printf '{"sessions":[]}' >"$sessions"

    GC_RIG=rig LOG_DIR="$logdir" GC_BEADS_JSON="$beads" GC_SESSIONS_JSON="$sessions" \
        PATH="$bin:$PATH" bash "$SCRIPT" "$rig" --no-dry-run >"$tmp/out.txt" 2>&1 ||
        fail "reaper exited non-zero: $(cat "$tmp/out.txt")"

    # The permanent condition must be NAMED, every time, whatever the gates then
    # decide — the distinct event is what stops this being silent.
    [[ "$(reason_for "$log" worktree_no_such_bead)" == "no_such_bead" ]] ||
        fail "a bead bd reports as absent was not recorded as no_such_bead"
    ! jq -e 'select(.event == "worktree_bead_unreadable") |
             select(.bead | startswith("wt-gone"))' "$log" >/dev/null ||
        fail "a permanently-absent bead was logged as transiently unreadable; it will be retried forever"

    # Clean and published: the content exists elsewhere, so this is a leak.
    [[ ! -e "$home/worktrees/wt-gone-published" ]] ||
        fail "a no-such-bead worktree that is clean and published was not reaped"
    [[ "$(jq -r 'select(.bead == "wt-gone-published" and .event == "worktree_reaped") | .detail' "$log" | tail -n 1)" == *"no such bead"* ]] ||
        fail "the reap of a no-such-bead path was reported as a closed-bead reap"

    # Clean but published nowhere: a FINDING, not a removal and not a retry.
    [[ -e "$home/worktrees/wt-gone-unpublished" ]] ||
        fail "a no-such-bead worktree holding the only copy of its commits was reaped"
    [[ "$(jq -r 'select(.bead == "wt-gone-unpublished") | .event' "$log" | tail -n 1)" == "worktree_unpublished_kept" ]] ||
        fail "an unpublished no-such-bead worktree was not surfaced as a finding"
    [[ "$(reason_for "$log" worktree_unpublished_kept)" == "no_such_bead_content_unpublished" ]] ||
        fail "the unpublished finding does not name why it was kept"

    # Dirty still wins: gate 3 binds on this path exactly as on the other.
    [[ -e "$home/worktrees/wt-gone-dirty" ]] ||
        fail "a no-such-bead worktree with uncommitted work was reaped"
    [[ "$(jq -r 'select(.bead == "wt-gone-dirty") | .event' "$log" | tail -n 1)" == "worktree_dirty_kept" ]] ||
        fail "a dirty no-such-bead worktree was not reported for salvage"

    # And the ordinary closed-bead path is untouched by any of it.
    [[ ! -e "$home/worktrees/wt-closed" ]] ||
        fail "the closed-bead reap regressed"

    # A store that cannot answer AT ALL stays transient — the distinction is
    # bd's error class, never a guess at what a bead id looks like.
    rm -f "$log"
    GC_RIG=rig LOG_DIR="$logdir" GC_BEADS_JSON="$beads" GC_SESSIONS_JSON="$sessions" \
        GC_BD_STORE_ERROR=1 PATH="$bin:$PATH" bash "$SCRIPT" "$rig" --no-dry-run \
        >"$tmp/err.txt" 2>&1 ||
        fail "reaper exited non-zero on a failing store: $(cat "$tmp/err.txt")"

    [[ "$(reason_for "$log" worktree_bead_query_failed)" == "bead_query_failed" ]] ||
        fail "a store that errored for a reason other than no-such-bead was not reported as a store failure"
    ! grep -F '"event":"worktree_no_such_bead"' "$log" >/dev/null ||
        fail "a store error was mistaken for a permanent no-such-bead verdict"
    [[ -e "$home/worktrees/wt-gone-unpublished" ]] ||
        fail "a worktree was reaped while the store was unreadable"

    rm -rf "$tmp"
}

test_an_unanswered_publication_probe_is_not_a_lost_work_finding() {
    # gcp-9ql4. Gate 5 blanked CONTAINS on every non-`ok` outcome, so a probe
    # that timed out, errored, or never ran at all was byte-identical to "the
    # probe ran and found no containing remote ref". The reaper then reported
    # the confirmed-negative wording — "the commits here exist nowhere else;
    # kept for the witness to salvage" — for a question nobody had asked.
    #
    # Acting on that means the witness force-pushing already-merged commits
    # from a detached HEAD, and it permanently pins the worktree against
    # reaping. Confirmed in gascity on 2026-09-06: the SAME worktree, same
    # HEAD, no intervening change, produced `worktree_reap_pending` with
    # "HEAD published on origin/edge-integration,..." at 21:24 and
    # `worktree_unpublished_kept` at 23:39 — the only difference being that
    # the second run reached the probe with the budget spent.
    #
    # The three answers must stay distinct: only `ok` + empty output is the
    # finding. `timeout` and `failed` are driven here; the budget-`skipped`
    # variant shares the same code path and is reported as truncation, and it
    # is not driven from a test for the same reason the other
    # `budget_spent_before_*` reasons are not — it needs the run's clock to
    # cross a second boundary inside a bounded call that still succeeds, which
    # no test can time deterministically.
    local tmp rig bin home beads sessions logdir log
    tmp=$(mktemp -d)
    rig="$tmp/rig"
    bin="$tmp/bin"
    home="$tmp/city/.gc/worktrees/rig/polecats/nux"
    beads="$tmp/beads.json"
    sessions="$tmp/sessions.json"
    logdir="$tmp/logs"
    log="$logdir/polecat-worktree-reap.log"
    mkdir -p "$logdir"

    setup_rig "$rig"
    publish_rig "$rig" "$tmp/remote.git"
    write_gc_stub "$bin"
    write_git_stub "$bin"

    # One no-such-bead candidate whose content IS published. Every run below
    # must therefore either reap it or say it could not tell — and never once
    # claim its commits exist nowhere else.
    add_bead_worktree "$rig" "$home" wt-gone-published

    printf '[]' >"$beads"
    printf '{"sessions":[]}' >"$sessions"

    # Case 1: the remote-contains read errors. The publication state is
    # unknown, so the worktree is kept — but as an UNCONFIRMED probe, not as a
    # finding about the worktree's contents.
    GC_RIG=rig LOG_DIR="$logdir" GC_BEADS_JSON="$beads" GC_SESSIONS_JSON="$sessions" \
        GIT_CONTAINS_FAIL=1 GC_REAP_BUDGET_SECONDS=30 PATH="$bin:$PATH" \
        bash "$SCRIPT" "$rig" --no-dry-run >"$tmp/fail.txt" 2>&1 ||
        fail "reaper exited non-zero on a failing publication probe: $(cat "$tmp/fail.txt")"

    ! grep -F '"event":"worktree_unpublished_kept"' "$log" >/dev/null ||
        fail "a publication probe that ERRORED was reported as proof the commits exist nowhere else"
    [[ "$(reason_for "$log" worktree_publication_unconfirmed)" == "publication_probe_failed" ]] ||
        fail "a failing publication probe was not recorded as unconfirmed"
    [[ -e "$home/worktrees/wt-gone-published" ]] ||
        fail "a worktree was reaped while its publication state was unknown"

    # Case 2: the remote-contains read is cut short by the budget it was given.
    # Same event — it did run — but the detail must point at the budget so a
    # reader does not go looking for a broken checkout.
    rm -f "$log"
    GC_RIG=rig LOG_DIR="$logdir" GC_BEADS_JSON="$beads" GC_SESSIONS_JSON="$sessions" \
        GIT_CONTAINS_DELAY=20 GC_REAP_BUDGET_SECONDS=3 PATH="$bin:$PATH" \
        bash "$SCRIPT" "$rig" --no-dry-run >"$tmp/slow.txt" 2>&1 ||
        fail "reaper exited non-zero on a slow publication probe: $(cat "$tmp/slow.txt")"

    ! grep -F '"event":"worktree_unpublished_kept"' "$log" >/dev/null ||
        fail "a publication probe cut short by the budget was reported as a lost-work finding"
    [[ "$(reason_for "$log" worktree_publication_unconfirmed)" == "publication_probe_timed_out" ]] ||
        fail "a publication probe cut short by the budget was not recorded as a timeout"
    [[ "$(detail_for "$log" worktree_publication_unconfirmed)" == *"budget"* ]] ||
        fail "the publication timeout does not point at the budget it hit"

    # Case 3: the HEAD read itself fails. Gate 5 cannot even start, and that is
    # equally not evidence about where the commits live.
    rm -f "$log"
    GC_RIG=rig LOG_DIR="$logdir" GC_BEADS_JSON="$beads" GC_SESSIONS_JSON="$sessions" \
        GIT_REVPARSE_FAIL=1 GC_REAP_BUDGET_SECONDS=30 PATH="$bin:$PATH" \
        bash "$SCRIPT" "$rig" --no-dry-run >"$tmp/head.txt" 2>&1 ||
        fail "reaper exited non-zero on a failing HEAD read: $(cat "$tmp/head.txt")"

    ! grep -F '"event":"worktree_unpublished_kept"' "$log" >/dev/null ||
        fail "an unreadable HEAD was reported as proof the commits exist nowhere else"
    [[ "$(reason_for "$log" worktree_publication_unconfirmed)" == "publication_probe_failed" ]] ||
        fail "an unreadable HEAD was not recorded as an unconfirmed publication state"
    [[ -e "$home/worktrees/wt-gone-published" ]] ||
        fail "a worktree was reaped while HEAD could not be read"

    # Case 4, the control: with both probes answering, the SAME worktree is
    # reaped as published. Without this the assertions above would also pass on
    # a reaper that had simply stopped reaping.
    rm -f "$log"
    GC_RIG=rig LOG_DIR="$logdir" GC_BEADS_JSON="$beads" GC_SESSIONS_JSON="$sessions" \
        GC_REAP_BUDGET_SECONDS=30 PATH="$bin:$PATH" \
        bash "$SCRIPT" "$rig" --no-dry-run >"$tmp/ok.txt" 2>&1 ||
        fail "reaper exited non-zero on a healthy run: $(cat "$tmp/ok.txt")"

    [[ ! -e "$home/worktrees/wt-gone-published" ]] ||
        fail "a clean, published, no-such-bead worktree was not reaped once both probes answered"
    ! grep -F '"event":"worktree_publication_unconfirmed"' "$log" >/dev/null ||
        fail "a publication probe that answered was still recorded as unconfirmed"

    # Case 5: the confirmed negative still fires. The fix must narrow
    # `worktree_unpublished_kept` to the one state that earns it, not retire it
    # — a worktree holding the only copy of its commits is the reason gate 5
    # exists at all.
    rm -f "$log"
    add_bead_worktree "$rig" "$home" wt-gone-unpublished
    echo local >"$home/worktrees/wt-gone-unpublished/local.txt"
    git -C "$home/worktrees/wt-gone-unpublished" add local.txt
    git -C "$home/worktrees/wt-gone-unpublished" commit -qm "unpublished work"

    GC_RIG=rig LOG_DIR="$logdir" GC_BEADS_JSON="$beads" GC_SESSIONS_JSON="$sessions" \
        GC_REAP_BUDGET_SECONDS=30 PATH="$bin:$PATH" \
        bash "$SCRIPT" "$rig" --no-dry-run >"$tmp/neg.txt" 2>&1 ||
        fail "reaper exited non-zero on the confirmed-negative run: $(cat "$tmp/neg.txt")"

    [[ "$(reason_for "$log" worktree_unpublished_kept)" == "no_such_bead_content_unpublished" ]] ||
        fail "a probe that ran and found no containing remote ref no longer produces the finding"
    [[ -e "$home/worktrees/wt-gone-unpublished" ]] ||
        fail "a worktree holding the only copy of its commits was reaped"

    rm -rf "$tmp"
}

test_an_all_missing_batch_is_not_a_store_failure() {
    # bd exits 1 and prints an error OBJECT — not an array — when NO id in the
    # batch resolves. The array check read that as a dead store, so a rig whose
    # only candidate was a no-such-bead path aborted the whole cycle as
    # `worktree_bead_query_failed` and sent the reader at a Dolt server that was
    # answering perfectly (gcp-0u14).
    local tmp rig bin home beads sessions logdir log
    tmp=$(mktemp -d)
    rig="$tmp/rig"
    bin="$tmp/bin"
    home="$tmp/city/.gc/worktrees/rig/polecats/nux"
    beads="$tmp/beads.json"
    sessions="$tmp/sessions.json"
    logdir="$tmp/logs"
    log="$logdir/polecat-worktree-reap.log"
    mkdir -p "$logdir"

    setup_rig "$rig"
    publish_rig "$rig" "$tmp/remote.git"
    write_gc_stub "$bin"
    add_bead_worktree "$rig" "$home" wt-gone

    printf '[]' >"$beads"
    printf '{"sessions":[]}' >"$sessions"

    GC_RIG=rig LOG_DIR="$logdir" GC_BEADS_JSON="$beads" GC_SESSIONS_JSON="$sessions" \
        PATH="$bin:$PATH" bash "$SCRIPT" "$rig" --no-dry-run >"$tmp/out.txt" 2>&1 ||
        fail "reaper exited non-zero: $(cat "$tmp/out.txt")"

    ! grep -F '"event":"worktree_bead_query_failed"' "$log" >/dev/null ||
        fail "a batch bd answered in full was reported as a store failure"
    grep -F '"event":"worktree_no_such_bead"' "$log" >/dev/null ||
        fail "the sole no-such-bead candidate was never decided"
    [[ ! -e "$home/worktrees/wt-gone" ]] ||
        fail "a clean, published, no-such-bead worktree was not reaped"

    rm -rf "$tmp"
}

test_lane_trees_other_than_polecats_are_enumerated() {
    # gcp-elv3. Gate 1 used to require a `*/polecats/*/worktrees/*` segment, so
    # every per-bead worktree under a rig's `views/` tree — byte-identical in
    # shape, differing only in the tree name — was dropped BEFORE the bulk bead
    # read and before any `record`. winnow ran 16 of them and `/views/` appeared
    # in 0 of 1293 reap-log entries: the same pre-emission silence that made
    # gcp-ac59 a P1, and one a worktree holding unpublished work cannot break.
    #
    # The gate is the SHAPE now, so the tree name must not matter at all — a
    # second `views` literal would only move the blind spot to the next lane
    # gascity names. `nextlane` is here to hold that: it is not a name anything
    # in this repo knows, and it must be reaped exactly like `polecats`.
    local tmp rig bin beads sessions logdir log
    tmp=$(mktemp -d)
    rig="$tmp/rig"
    bin="$tmp/bin"
    beads="$tmp/beads.json"
    sessions="$tmp/sessions.json"
    logdir="$tmp/logs"
    log="$logdir/polecat-worktree-reap.log"
    mkdir -p "$logdir"

    setup_rig "$rig"
    write_gc_stub "$bin"

    local view_home="$tmp/city/.gc/worktrees/rig/views/specialists.prism"
    local next_home="$tmp/city/.gc/worktrees/rig/nextlane/specialists.later"
    local polecat_home="$tmp/city/.gc/worktrees/rig/polecats/nux"
    git -C "$rig" worktree add -q "$view_home" --detach HEAD
    git -C "$rig" worktree add -q "$next_home" --detach HEAD
    git -C "$rig" worktree add -q "$polecat_home" --detach HEAD

    add_bead_worktree "$rig" "$view_home" wt-view
    add_bead_worktree "$rig" "$view_home" wt-view-live
    add_bead_worktree "$rig" "$next_home" wt-next
    add_bead_worktree "$rig" "$polecat_home" wt-polecat

    cat >"$beads" <<'JSON'
[
  {"id":"wt-view","status":"closed","metadata":{"polecat_session":"deadsess"}},
  {"id":"wt-view-live","status":"in_progress","metadata":{"polecat_session":"livesess"}},
  {"id":"wt-next","status":"closed","metadata":{"polecat_session":"deadsess"}},
  {"id":"wt-polecat","status":"closed","metadata":{"polecat_session":"deadsess"}}
]
JSON

    cat >"$sessions" <<'JSON'
{"sessions":[
  {"id":"livesess","name":"livesess","state":"running","closed":false},
  {"id":"deadsess","name":"deadsess","state":"closed","closed":true}
]}
JSON

    GC_RIG=rig LOG_DIR="$logdir" GC_BEADS_JSON="$beads" GC_SESSIONS_JSON="$sessions" \
        PATH="$bin:$PATH" bash "$SCRIPT" "$rig" --no-dry-run >"$tmp/out.txt" 2>&1 ||
        fail "reaper exited non-zero: $(cat "$tmp/out.txt")"

    [[ ! -e "$view_home/worktrees/wt-view" ]] ||
        fail "a closed, clean, unowned VIEW worktree was not reaped; the gate is still keyed on the tree name"
    [[ ! -e "$next_home/worktrees/wt-next" ]] ||
        fail "a per-bead worktree under an unfamiliar lane tree was not reaped; the gate must test the shape, not the name"
    [[ ! -e "$polecat_home/worktrees/wt-polecat" ]] ||
        fail "the polecat case regressed while the lane-tree gate was widened"

    # Widening the gate must not weaken it: the ordinary gates still decide.
    [[ -e "$view_home/worktrees/wt-view-live" ]] ||
        fail "an in_progress view worktree was reaped; only closed beads are disposable"
    [[ -e "$view_home/seed.txt" ]] ||
        fail "the view agent-home worktree was reaped; only per-bead worktrees are candidates"

    # The point of the bead: `/views/` stops being absent from the log. Match
    # on the tree segment, not on a path this test composed — macOS `mktemp -d`
    # hands back a /var path and git records the resolved /private/var form.
    grep -F '/views/specialists.prism/worktrees/wt-view"' "$log" >/dev/null ||
        fail "the view worktree was decided but never recorded; pre-emission silence is the failure this closes"

    rm -rf "$tmp"
}

test_the_budget_cutoff_rotates_instead_of_dropping_the_same_tail() {
    # gcp-schs. Enumeration is deterministic and the budget `break`s out of it,
    # so an unrotated loop drops the SAME sorted tail every run. That is not a
    # fairness nicety: the criterion for flipping the staged rollout to
    # --no-dry-run is a REVIEWED would-reap set, and under a fixed cutoff that
    # set can be clean across any number of cycles while part of the candidate
    # set has never been examined once — and those are exactly the worktrees a
    # live reaper with a fresh budget reaches first.
    #
    # Two things must hold, and they are two halves of one invariant: the window
    # MOVES between truncated cycles, so coverage accumulates; and a cycle that
    # covered everything SAYS SO, so an operator has something to check rather
    # than a count of clean-looking prefixes.
    local tmp rig bin home beads sessions logdir log cursor i covered
    tmp=$(mktemp -d)
    rig="$tmp/rig"
    bin="$tmp/bin"
    home="$tmp/city/.gc/worktrees/rig/polecats/nux"
    beads="$tmp/beads.json"
    sessions="$tmp/sessions.json"
    logdir="$tmp/logs"
    log="$logdir/polecat-worktree-reap.log"
    cursor="$logdir/polecat-worktree-reap.rig.cursor"
    mkdir -p "$logdir"

    setup_rig "$rig"
    write_gc_stub "$bin"
    # Every candidate costs about a second, so a short budget truncates the loop
    # at a predictable depth without depending on how fast the host is.
    write_git_stub "$bin"

    for i in 1 2 3 4 5 6; do
        add_bead_worktree "$rig" "$home" "wt-a$i"
    done

    cat >"$beads" <<'JSON'
[
  {"id":"wt-a1","status":"closed","metadata":{"polecat_session":"deadsess"}},
  {"id":"wt-a2","status":"closed","metadata":{"polecat_session":"deadsess"}},
  {"id":"wt-a3","status":"closed","metadata":{"polecat_session":"deadsess"}},
  {"id":"wt-a4","status":"closed","metadata":{"polecat_session":"deadsess"}},
  {"id":"wt-a5","status":"closed","metadata":{"polecat_session":"deadsess"}},
  {"id":"wt-a6","status":"closed","metadata":{"polecat_session":"deadsess"}}
]
JSON
    printf '{"sessions":[]}' >"$sessions"

    # Dry run throughout: nothing is removed, so the candidate set is identical
    # every cycle and any change in which candidates get examined is the cutoff
    # moving rather than the population shrinking.
    covered=""
    for i in 1 2 3 4 5 6; do
        GC_RIG=rig LOG_DIR="$logdir" GC_BEADS_JSON="$beads" GC_SESSIONS_JSON="$sessions" \
            GIT_STATUS_DELAY=1 PATH="$bin:$PATH" bash "$SCRIPT" "$rig" --budget 3 \
            >"$tmp/cycle$i.txt" 2>&1 ||
            fail "a truncated cycle exited non-zero: $(cat "$tmp/cycle$i.txt")"
        # "Reviewed" is any candidate this cycle actually reached and recorded
        # a decision about — not specifically the would-reap verdict. Which
        # verdict a candidate draws depends on how much budget was left when its
        # turn came; whether its turn came AT ALL is what the rotation decides,
        # and that is the claim under test.
        covered=$(jq -r 'select(.bead != "") | .bead' "$log" |
            LC_ALL=C sort -u | paste -sd, -)
        if [[ "$covered" == "wt-a1,wt-a2,wt-a3,wt-a4,wt-a5,wt-a6" ]]; then
            break
        fi
    done

    grep -F '"event":"worktree_budget_exhausted"' "$log" >/dev/null ||
        fail "no cycle actually exhausted its budget; the fixture proves nothing about the cutoff"
    [[ "$covered" == "wt-a1,wt-a2,wt-a3,wt-a4,wt-a5,wt-a6" ]] ||
        fail "after six truncated cycles the reviewed set was still {$covered}; the cutoff is not rotating and the sorted tail is never examined"

    # The resume cursor is what carries the rotation between runs, and it is
    # per-rig: a shared file would have every rig rotating the others.
    [[ -f "$cursor" ]] ||
        fail "a truncated cycle left no resume cursor; the next cycle would re-walk the same prefix"

    # A truncated cycle must not claim a complete scan — that claim is the whole
    # evidentiary basis for the --no-dry-run flip.
    ! grep -F '"event":"worktree_scan_complete"' "$log" >/dev/null ||
        fail "a budget-limited cycle reported a complete scan"

    # ...and it must still report what it deferred, honestly, as it always did.
    grep -F 'deferred to the next cycle' "$tmp/cycle1.txt" >/dev/null ||
        fail "a truncated cycle stopped reporting its deferred count"

    # Now the other half: a cycle with room to examine everything says so, once,
    # with deferred=0 — and clears the cursor, because leaving it at the tail
    # would pin every following cycle to the same starting point.
    : >"$log"
    GC_RIG=rig LOG_DIR="$logdir" GC_BEADS_JSON="$beads" GC_SESSIONS_JSON="$sessions" \
        PATH="$bin:$PATH" bash "$SCRIPT" "$rig" --budget 60 >"$tmp/full.txt" 2>&1 ||
        fail "a complete cycle exited non-zero: $(cat "$tmp/full.txt")"

    grep -F '"event":"worktree_scan_complete"' "$log" >/dev/null ||
        fail "a cycle that examined every candidate recorded nothing; the promotion criterion has nothing to check"
    [[ "$(reason_for "$log" worktree_scan_complete)" == "scan_complete" ]] ||
        fail "worktree_scan_complete carried reason '$(reason_for "$log" worktree_scan_complete)'"
    [[ "$(detail_for "$log" worktree_scan_complete)" == *"deferred=0"* ]] ||
        fail "the complete-scan line does not state deferred=0: $(detail_for "$log" worktree_scan_complete)"
    [[ ! -f "$cursor" ]] ||
        fail "a complete cycle left a resume cursor behind; the next cycle would start mid-list forever"

    rm -rf "$tmp"
}

test_a_non_agent_worktree_named_like_a_bead_is_not_reaped() {
    # The `polecats` literal gate 1 used to carry also excluded, incidentally,
    # every path that merely LOOKS like `<something>/worktrees/<id>`. Two of
    # those still must not be candidates once the gate is keyed on shape:
    # the refinery, whose per-bead directories sit one level higher at
    # `<rig>/refinery/worktrees/`, and the main worktree itself.
    local tmp rig bin beads sessions logdir
    tmp=$(mktemp -d)
    # The rig root itself is placed at a path with the EXACT per-bead shape —
    # `<root>/worktrees/<rig>/<tree>/<agent>/worktrees/<bead-id>` — and named
    # after a bead bd will call closed, clean and published. Every gate but the
    # main-worktree exclusion passes. `$RIG_ROOT` is not the backstop here:
    # macOS `mktemp -d` hands back a /var path while git reports the resolved
    # /private/var one, so the two do not even compare equal.
    rig="$tmp/city/.gc/worktrees/rig/polecats/nux/worktrees/wt-closed"
    bin="$tmp/bin"
    beads="$tmp/beads.json"
    sessions="$tmp/sessions.json"
    logdir="$tmp/logs"
    mkdir -p "$logdir"

    setup_rig "$rig"
    publish_rig "$rig" "$tmp/remote.git"
    write_gc_stub "$bin"

    local refinery="$tmp/city/.gc/worktrees/rig/refinery"
    add_bead_worktree "$rig" "$refinery" wt-closed

    # And the exclusion must hold on the RESIDUE source too, not only on the
    # admin list (gcp-mves). This rig root SITS INSIDE a `<home>/worktrees/`
    # directory, so registering an ordinary per-bead worktree beside it makes
    # that directory a scan root — and the disk walk then reaches the rig's own
    # main worktree, which matches the per-bead shape exactly, is clean, is
    # published, and whose bead is closed. Every gate would pass. Gate 1 drops
    # the main worktree before it can contribute a scan root, but a scan root
    # contributed by something ELSE still contains it, so the walk has to name
    # the exclusion too or the reaper deletes the canonical checkout.
    local sibling="$tmp/city/.gc/worktrees/rig/polecats/nux/worktrees/wt-sibling"
    git -C "$rig" worktree add -q "$sibling" --detach HEAD

    cat >"$beads" <<'JSON'
[
  {"id":"wt-closed","status":"closed","metadata":{"polecat_session":"deadsess"}},
  {"id":"wt-sibling","status":"closed","metadata":{"polecat_session":"deadsess"}}
]
JSON
    cat >"$sessions" <<'JSON'
{"sessions":[
  {"id":"deadsess","name":"deadsess","state":"closed","closed":true}
]}
JSON

    GC_RIG=rig LOG_DIR="$logdir" GC_BEADS_JSON="$beads" GC_SESSIONS_JSON="$sessions" \
        PATH="$bin:$PATH" bash "$SCRIPT" "$rig" --no-dry-run >"$tmp/out.txt" 2>&1 ||
        fail "reaper exited non-zero: $(cat "$tmp/out.txt")"

    [[ -e "$rig/seed.txt" ]] ||
        fail "the rig's own main worktree was reaped; it is the canonical checkout, never a candidate"
    [[ ! -e "$rig.reaping" ]] ||
        fail "the rig's own main worktree was renamed for removal by the residue walk"
    # The sibling really was reaped, so the cycle reached the removal phase and
    # the exclusion above was actually exercised rather than vacuously true.
    [[ ! -e "$sibling" ]] ||
        fail "the ordinary sibling worktree was not reaped, so this fixture never reached the removal phase"
    [[ -e "$refinery/worktrees/wt-closed" ]] ||
        fail "a non-agent-home per-bead worktree was reaped; the witness owns agent-home worktrees only"

    rm -rf "$tmp"
}

# ── gcp-mves: a kill inside the removal must not orphan a worktree ───────────
# The removal is the one destructive call in this script, it runs as a witness
# pre_start, and a pre_start is SIGKILLed at [session] setup_timeout. The old
# sequence took that kill in the middle of `git worktree remove`, which drops
# the `.git` file and the admin entry BEFORE it unlinks the tree — leaving a
# directory on disk that `git worktree list` can never enumerate again, and no
# log line, because the report is downstream of the kill. winnow lost 40
# worktrees that way (winnow-h0n2o) and reported none of them.

reapable_one_worktree_fixture() {
    # reapable_one_worktree_fixture <tmp> — one closed, clean, unowned per-bead
    # worktree under a registered agent home. Echoes nothing; the caller uses
    # the fixed paths below.
    local tmp="$1"
    local rig="$tmp/rig" bin="$tmp/bin"
    local home="$tmp/city/.gc/worktrees/rig/polecats/nux"

    mkdir -p "$tmp/logs"
    setup_rig "$rig"
    write_gc_stub "$bin"
    write_git_stub "$bin"
    # The home is a registered worktree, as it is on a real rig. It is the
    # handle the residue walk needs once a per-bead entry is gone from git's
    # admin list: an agent home contributes its `worktrees/` directory as a
    # scan root even though it is never a candidate itself.
    git -C "$rig" worktree add -q "$home" --detach HEAD
    add_bead_worktree "$rig" "$home" wt-closed

    cat >"$tmp/beads.json" <<'JSON'
[{"id":"wt-closed","status":"closed","metadata":{"polecat_session":"deadsess"}}]
JSON
    cat >"$tmp/sessions.json" <<'JSON'
{"sessions":[{"id":"deadsess","name":"deadsess","state":"closed","closed":true}]}
JSON
}

test_an_interrupted_removal_is_marked_and_resumable() {
    local tmp rig bin home log
    tmp=$(mktemp -d)
    rig="$tmp/rig"
    bin="$tmp/bin"
    home="$tmp/city/.gc/worktrees/rig/polecats/nux"
    log="$tmp/logs/polecat-worktree-reap.log"

    reapable_one_worktree_fixture "$tmp"
    interrupt_a_removal "$tmp" "$rig" "$bin" "$home" \
        "$tmp/beads.json" "$tmp/sessions.json" "$tmp/logs"

    # The kill landed inside the removal. What survives must SAY SO on its own:
    # the marker is the evidence, never a directory mtime or an inference.
    [[ -d "$home/worktrees/wt-closed.reaping" ]] ||
        fail "an interrupted removal left no \`.reaping\` marker; the surviving state is: $(ls -a "$home/worktrees" | tr '\n' ' ')"
    ! git -C "$rig" worktree list --porcelain | grep -F "worktrees/wt-closed.reaping" >/dev/null ||
        fail "the marked residue is registered with git; the rename must move it out of git's admin view"

    # And the next cycle must FINISH it — that is what resumable means.
    GC_RIG=rig LOG_DIR="$tmp/logs" GC_BEADS_JSON="$tmp/beads.json" \
        GC_SESSIONS_JSON="$tmp/sessions.json" \
        PATH="$bin:$PATH" bash "$SCRIPT" "$rig" --no-dry-run >"$tmp/resume.txt" 2>&1 ||
        fail "the resuming cycle exited non-zero: $(cat "$tmp/resume.txt")"

    [[ ! -e "$home/worktrees/wt-closed.reaping" ]] ||
        fail "the next cycle did not finish the interrupted removal: $(cat "$tmp/resume.txt")"
    [[ ! -e "$home/worktrees/wt-closed" ]] ||
        fail "the original worktree path came back"
    grep -F 'wt-closed.reaping' "$log" >/dev/null ||
        fail "the resumed removal was never recorded; silent recovery is the failure this closes"

    rm -rf "$tmp"
}

test_no_unmarked_half_removed_state_survives_an_interruption() {
    # THE invariant this bead buys. A directory that is present on disk, has no
    # `.git`, and carries no marker is unowned by every guard: gate 1 sources
    # candidates from `git worktree list`, which cannot see it, so it
    # accumulates silently and forever. After ANY interrupted run the set of
    # such directories must be empty.
    local tmp rig bin home orphans
    tmp=$(mktemp -d)
    rig="$tmp/rig"
    bin="$tmp/bin"
    home="$tmp/city/.gc/worktrees/rig/polecats/nux"

    reapable_one_worktree_fixture "$tmp"
    interrupt_a_removal "$tmp" "$rig" "$bin" "$home" \
        "$tmp/beads.json" "$tmp/sessions.json" "$tmp/logs"

    orphans=$(unmarked_half_removed "$home/worktrees")
    [[ -z "$orphans" ]] ||
        fail "an interrupted removal left an unmarked half-removed directory — present, no .git, no marker, and enumerable by nothing: $(printf '%s' "$orphans" | tr '\n' ' ')"

    rm -rf "$tmp"
}

test_legacy_residue_is_enumerated_from_disk() {
    # The ~23 directories winnow's armed run already stripped. They carry no
    # marker and no admin entry, so the ONLY way to find them is to walk the
    # worktree tree on disk — `git worktree list` structurally cannot.
    local tmp rig bin home log residue
    tmp=$(mktemp -d)
    rig="$tmp/rig"
    bin="$tmp/bin"
    home="$tmp/city/.gc/worktrees/rig/polecats/nux"
    log="$tmp/logs/polecat-worktree-reap.log"
    residue="$home/worktrees/wt-closed"

    reapable_one_worktree_fixture "$tmp"
    strip_worktree "$rig" "$residue"

    # Precondition: the fixture really is invisible to the enumeration source
    # the reaper used to have. If this ever stops holding the case is testing
    # nothing.
    ! git -C "$rig" worktree list --porcelain | grep -F "worktrees/wt-closed" >/dev/null ||
        fail "the stripped fixture is still in git's admin list; it does not model the residue"

    # DEFAULT posture first: it must be named in the log and left alone.
    GC_RIG=rig LOG_DIR="$tmp/logs" GC_BEADS_JSON="$tmp/beads.json" \
        GC_SESSIONS_JSON="$tmp/sessions.json" \
        PATH="$bin:$PATH" bash "$SCRIPT" "$rig" >"$tmp/dry.txt" 2>&1 ||
        fail "the dry run exited non-zero: $(cat "$tmp/dry.txt")"

    [[ -d "$residue" ]] ||
        fail "the dry run removed residue; real removal must stay opt-in on this path too"
    grep -F "$(basename "$residue")" "$log" >/dev/null ||
        fail "the dry run did not name the residue path in the log: $(cat "$tmp/dry.txt")"

    # Then the live posture: every gate passes, so it goes.
    GC_RIG=rig LOG_DIR="$tmp/logs" GC_BEADS_JSON="$tmp/beads.json" \
        GC_SESSIONS_JSON="$tmp/sessions.json" \
        PATH="$bin:$PATH" bash "$SCRIPT" "$rig" --no-dry-run >"$tmp/live.txt" 2>&1 ||
        fail "the live run exited non-zero: $(cat "$tmp/live.txt")"

    [[ ! -e "$residue" ]] ||
        fail "residue that cleared every gate was not removed: $(cat "$tmp/live.txt")"
    [[ -e "$home/seed.txt" ]] ||
        fail "the agent home was removed while walking it for residue"

    rm -rf "$tmp"
}

test_residue_still_honours_the_gates() {
    # Widening the enumeration must not weaken the gates. Residue is not a fast
    # path: one case per gate that can still bind on it.
    local tmp rig bin home log
    tmp=$(mktemp -d)
    rig="$tmp/rig"
    bin="$tmp/bin"
    home="$tmp/city/.gc/worktrees/rig/polecats/nux"
    log="$tmp/logs/polecat-worktree-reap.log"

    mkdir -p "$tmp/logs"
    setup_rig "$rig"
    write_gc_stub "$bin"
    write_git_stub "$bin"
    git -C "$rig" worktree add -q "$home" --detach HEAD

    # Gate 2: the owning bead is open again.
    add_bead_worktree "$rig" "$home" wt-open
    strip_worktree "$rig" "$home/worktrees/wt-open"
    # Gate 4: a live session still owns it.
    add_bead_worktree "$rig" "$home" wt-live
    strip_worktree "$rig" "$home/worktrees/wt-live"
    # Gate 3: residue git CAN still administer — unregistered, but with a
    # working `.git`. It gets the ordinary clean-tree gate, and it is dirty.
    add_bead_worktree "$rig" "$home" wt-dirty
    detach_worktree_admin "$rig" "$home/worktrees/wt-dirty" wt-dirty
    echo scratch >"$home/worktrees/wt-dirty/seed.txt"

    cat >"$tmp/beads.json" <<'JSON'
[
  {"id":"wt-open","status":"open","metadata":{"polecat_session":"deadsess"}},
  {"id":"wt-live","status":"closed","metadata":{"polecat_session":"livesess"}},
  {"id":"wt-dirty","status":"closed","metadata":{"polecat_session":"deadsess"}}
]
JSON
    cat >"$tmp/sessions.json" <<'JSON'
{"sessions":[
  {"id":"livesess","name":"livesess","state":"running","closed":false},
  {"id":"deadsess","name":"deadsess","state":"closed","closed":true}
]}
JSON

    GC_RIG=rig LOG_DIR="$tmp/logs" GC_BEADS_JSON="$tmp/beads.json" \
        GC_SESSIONS_JSON="$tmp/sessions.json" \
        PATH="$bin:$PATH" bash "$SCRIPT" "$rig" --no-dry-run >"$tmp/out.txt" 2>&1 ||
        fail "reaper exited non-zero: $(cat "$tmp/out.txt")"

    [[ -d "$home/worktrees/wt-open" ]] ||
        fail "residue whose bead is open again was removed; gate 2 must bind on residue too"
    [[ -d "$home/worktrees/wt-live" ]] ||
        fail "residue still owned by a live session was removed; gate 4 must bind on residue too"
    grep -F '"event":"worktree_owner_live"' "$log" >/dev/null ||
        fail "the live-owner refusal was not recorded for residue"
    [[ -d "$home/worktrees/wt-dirty" ]] ||
        fail "dirty residue was removed; gate 3 must bind wherever git can still answer"
    grep -F '"event":"worktree_dirty_kept"' "$log" >/dev/null ||
        fail "the dirty refusal was not recorded for residue"

    rm -rf "$tmp"
}

test_residue_with_no_bead_is_kept() {
    # The `g7nf-base` shape (gcp-0u14) as RESIDUE: a directory with no bead to
    # authorise the reap and no git view to run the publication gate against.
    # Gate 5 is what carries the no-such-bead path, and it needs a `git
    # rev-parse HEAD` this directory cannot answer — so there is no evidence
    # left at all. Keep it and say so.
    local tmp rig bin home log residue
    tmp=$(mktemp -d)
    rig="$tmp/rig"
    bin="$tmp/bin"
    home="$tmp/city/.gc/worktrees/rig/polecats/nux"
    log="$tmp/logs/polecat-worktree-reap.log"
    residue="$home/worktrees/hand-made"

    mkdir -p "$tmp/logs"
    setup_rig "$rig"
    write_gc_stub "$bin"
    write_git_stub "$bin"
    git -C "$rig" worktree add -q "$home" --detach HEAD
    add_bead_worktree "$rig" "$home" hand-made
    strip_worktree "$rig" "$residue"

    printf '[]' >"$tmp/beads.json"
    printf '{"sessions":[]}' >"$tmp/sessions.json"

    GC_RIG=rig LOG_DIR="$tmp/logs" GC_BEADS_JSON="$tmp/beads.json" \
        GC_SESSIONS_JSON="$tmp/sessions.json" \
        PATH="$bin:$PATH" bash "$SCRIPT" "$rig" --no-dry-run >"$tmp/out.txt" 2>&1 ||
        fail "reaper exited non-zero: $(cat "$tmp/out.txt")"

    [[ -d "$residue" ]] ||
        fail "residue with no bead was removed; nothing authorised it and gate 5 cannot run without a git view"
    grep -F '"worktree":"' "$log" | grep -F 'hand-made' >/dev/null ||
        fail "residue with no bead was decided without being recorded"

    rm -rf "$tmp"
}

test_gates_are_rechecked_at_the_point_of_use() {
    # Ask 3. Everything the removal stands on was established earlier in the
    # run: the bead status came from one bulk read at the top, the roster from
    # a read after it, and the clean-tree check from before gate 5. The rig is
    # live and the run is seconds long, so re-check what can change underneath
    # it immediately before the destructive call.
    #
    # GIT_DIRTY_AFTER_STATUS makes the worktree go dirty the instant gate 3
    # answers clean, which is precisely a gate going stale between its check and
    # the removal it authorised.
    local tmp rig bin home log wt
    tmp=$(mktemp -d)
    rig="$tmp/rig"
    bin="$tmp/bin"
    home="$tmp/city/.gc/worktrees/rig/polecats/nux"
    log="$tmp/logs/polecat-worktree-reap.log"
    wt="$home/worktrees/wt-closed"

    reapable_one_worktree_fixture "$tmp"

    GC_RIG=rig LOG_DIR="$tmp/logs" GC_BEADS_JSON="$tmp/beads.json" \
        GC_SESSIONS_JSON="$tmp/sessions.json" GIT_DIRTY_AFTER_STATUS="$wt" \
        PATH="$bin:$PATH" bash "$SCRIPT" "$rig" --no-dry-run >"$tmp/out.txt" 2>&1 ||
        fail "reaper exited non-zero: $(cat "$tmp/out.txt")"

    [[ -d "$wt" ]] ||
        fail "a worktree that went dirty after the gate check was removed; the gates must be re-checked at the point of use"
    [[ -f "$wt/went-dirty.txt" ]] ||
        fail "the fixture never dirtied the worktree, so nothing was under test"
    grep -F '"event":"worktree_dirty_kept"' "$log" >/dev/null ||
        fail "the point-of-use refusal was not recorded"

    rm -rf "$tmp"
}

test_the_promotion_criterion_says_what_a_dry_run_cannot_show() {
    # Ask 4. The staged-rollout criterion at agents/witness/agent.toml:20-25 was
    # written as sufficient: "review the logged would-reap set across several
    # cycles and confirm no live worktree ever appears in it". winnow's witness
    # satisfied it honestly and still lost 40 worktrees, because the criterion
    # tests WHICH WORKTREES ARE SELECTED and a dry run never calls `git worktree
    # remove` at all — the removal path is outside everything the soak can
    # observe. The next operator must not arm on the same incomplete evidence.
    local toml
    toml="$ROOT/gastown/agents/witness/agent.toml"

    grep -qi 'necessary' "$toml" && grep -qi 'not sufficient' "$toml" ||
        fail "the promotion criterion does not say the soak is necessary and NOT sufficient"
    grep -q 'gcp-mves' "$toml" ||
        fail "the promotion criterion does not name the removal-completion precondition (gcp-mves)"
    grep -q 'gascity-3z7d' "$toml" ||
        fail "the promotion criterion does not name the killed-pre_start precondition (gascity-3z7d)"

    # And the flag itself must still not be wired. Every mention has to be prose.
    local wired
    wired=$(grep -n -- '--no-dry-run' "$toml" | grep -v '^[0-9]*:#' || true)
    [[ -z "$wired" ]] ||
        fail "--no-dry-run appears outside the prose: ${wired//$'\n'/ | }"
}

test_reaps_only_closed_clean_unowned_bead_worktrees
test_real_removal_is_opt_in
test_unreadable_session_roster_skips_the_reap
test_dry_run_removes_nothing_and_rerun_is_idempotent
test_bead_status_is_read_in_one_bulk_query
test_a_large_candidate_set_does_not_overflow_the_join
test_budget_expiry_yields_the_witness_start
test_every_line_is_stamped_at_the_event_not_at_the_run
test_budget_truncation_is_not_reported_as_an_external_failure
test_git_status_failure_is_distinguished_from_a_short_budget
test_dotted_sub_bead_worktrees_are_enumerated
test_a_permanently_missing_bead_is_decided_not_retried
test_an_all_missing_batch_is_not_a_store_failure
test_an_unanswered_publication_probe_is_not_a_lost_work_finding
test_lane_trees_other_than_polecats_are_enumerated
test_a_non_agent_worktree_named_like_a_bead_is_not_reaped
test_the_budget_cutoff_rotates_instead_of_dropping_the_same_tail
test_an_interrupted_removal_is_marked_and_resumable
test_no_unmarked_half_removed_state_survives_an_interruption
test_legacy_residue_is_enumerated_from_disk
test_residue_still_honours_the_gates
test_residue_with_no_bead_is_kept
test_gates_are_rechecked_at_the_point_of_use
test_the_promotion_criterion_says_what_a_dry_run_cannot_show

echo "polecat worktree reap tests passed"
