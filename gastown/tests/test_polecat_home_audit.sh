#!/usr/bin/env bash
# Guards polecat-home-audit.sh — the roster-keyed sweep for polecat AGENT-HOME
# worktrees, the one shape every bead-keyed guard is structurally blind to
# (gcp-actg).
#
# The test that matters most here is the TRAP: when this was filed, a live
# polecat from one namepool slot was working inside a DEAD polecat's home
# subtree. A "home + no session -> remove" sweep deletes that live working tree.
# `test_a_home_with_child_worktrees_is_never_removed` is that case; do not
# relax it into a bead lookup, because bead-keying is the blindness this whole
# script exists to stop relying on.
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
SCRIPT="$ROOT/gastown/assets/scripts/polecat-home-audit.sh"

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

# macOS `mktemp -d` hands back a path under /var, which is a symlink to
# /private/var — and `git worktree list` reports the RESOLVED form. Tests that
# compare a worktree path against one the test itself composed (the work_dir
# ownership key) would then fail on the symlink rather than on the behaviour.
# Canonicalise once, here, so every test reasons about the same path git does.
make_tmp() {
    local d
    d=$(mktemp -d)
    (cd "$d" && pwd -P)
}

write_gc_stub() {
    # Serves the ONE read this script performs. It must never grow a `bd` arm:
    # if a change makes the script read beads, the assertion in
    # test_the_sweep_reads_no_beads catches it here.
    #
    # Test hooks:
    #   GC_SESSION_DELAY seconds to stall the roster read (budget tests)
    #   GC_SESSION_FAIL  non-empty: the roster read exits 1
    #   GC_CALLS         append the first argv word per call, so a test can
    #                    assert which gc subcommands were used
    local bin="$1"
    mkdir -p "$bin"
    cat >"$bin/gc" <<'SH'
#!/usr/bin/env sh
if [ -n "${GC_CALLS:-}" ]; then printf '%s\n' "$1" >>"$GC_CALLS"; fi
case "$1" in
    session)
        if [ -n "${GC_SESSION_DELAY:-}" ]; then sleep "$GC_SESSION_DELAY"; fi
        if [ -n "${GC_SESSION_FAIL:-}" ]; then
            echo "simulated roster failure" >&2
            exit 1
        fi
        cat "$GC_SESSIONS_JSON"
        ;;
    *)
        printf '[]'
        ;;
esac
SH
    chmod +x "$bin/gc"
}

write_git_stub() {
    # Wraps the real git so this script's OWN git calls can be made slow or
    # made to fail — the only way to drive the not-attempted / timed-out /
    # failed classification from outside, and that three-way distinction is
    # exactly what the log schema promises a reader.
    #
    # Test hooks:
    #   GIT_PRUNE_DELAY     seconds to stall `git ... worktree prune`
    #   GIT_STATUS_DELAY    seconds to stall `git ... status`
    #   GIT_STATUS_FAIL     non-empty: `git ... status` exits 128
    #   GIT_REVLIST_FAIL    non-empty: `git ... rev-list` exits 128
    local bin="$1" real
    real=$(command -v git)
    mkdir -p "$bin"
    cat >"$bin/git" <<SH
#!/usr/bin/env sh
case " \$* " in
    *" worktree prune "*)
        if [ -n "\${GIT_PRUNE_DELAY:-}" ]; then sleep "\$GIT_PRUNE_DELAY"; fi
        ;;
    *" status "*)
        if [ -n "\${GIT_STATUS_DELAY:-}" ]; then sleep "\$GIT_STATUS_DELAY"; fi
        if [ -n "\${GIT_STATUS_FAIL:-}" ]; then
            echo "fatal: simulated git status failure" >&2
            exit 128
        fi
        ;;
    *" rev-list "*)
        if [ -n "\${GIT_REVLIST_FAIL:-}" ]; then
            echo "fatal: simulated rev-list failure" >&2
            exit 128
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

# A rig repo plus a bare "origin" it can publish to, so the unpublished-commit
# gate has a real remote-tracking ref to reason about rather than the
# everything-is-unpublished degenerate case a remoteless repo produces.
setup_rig() {
    local rig="$1" origin="$2"
    git init -q --bare "$origin"
    mkdir -p "$rig"
    git -C "$rig" init -q
    git -C "$rig" config user.email home@test
    git -C "$rig" config user.name home
    echo seed >"$rig/seed.txt"
    git -C "$rig" add seed.txt
    git -C "$rig" commit -qm seed
    git -C "$rig" remote add origin "$origin"
    git -C "$rig" push -q origin HEAD:refs/heads/main
    git -C "$rig" fetch -q origin
}

# add_home <rig> <homes-root> <agent> — a polecat agent home, checked out at a
# commit the remote already has so it is disposable by default. Individual
# tests then dirty exactly the one property they are about.
add_home() {
    git -C "$1" worktree add -q "$2/$3" --detach origin/main
}

test_removes_only_unowned_childless_clean_published_homes() {
    local tmp rig origin bin homes sessions logdir log
    tmp=$(make_tmp)
    rig="$tmp/rig"
    origin="$tmp/origin.git"
    bin="$tmp/bin"
    homes="$tmp/city/.gc/worktrees/rig/polecats"
    sessions="$tmp/sessions.json"
    logdir="$tmp/logs"
    mkdir -p "$logdir"

    setup_rig "$rig" "$origin"
    write_gc_stub "$bin"

    add_home "$rig" "$homes" dead      # every gate passes — the only removal
    add_home "$rig" "$homes" live      # a running session owns it
    add_home "$rig" "$homes" dirty     # uncommitted work on disk
    add_home "$rig" "$homes" unpushed  # commits that reach no remote
    add_home "$rig" "$homes" parent    # holds a per-bead child — THE TRAP

    echo scratch >"$homes/dirty/seed.txt"

    git -C "$homes/unpushed" commit -q --allow-empty -m "work that never left"

    # A per-bead worktree under the `parent` home. Its own owner is irrelevant:
    # removing the home takes the child with it either way.
    git -C "$rig" worktree add -q "$homes/parent/worktrees/wt-child" --detach origin/main

    # The refinery's worktree sits beside the polecats tree, not inside it.
    # Nothing about it is a polecat home and the sweep must not claim it.
    git -C "$rig" worktree add -q "$tmp/city/.gc/worktrees/rig/refinery" --detach origin/main

    cat >"$sessions" <<'JSON'
{"sessions":[
  {"id":"gc-live","name":"rig/live","alias":"rig/live","agent_name":"rig/live","state":"active","closed":false},
  {"id":"gc-gone","name":"rig/dead","alias":"rig/dead","agent_name":"rig/dead","state":"closed","closed":true}
]}
JSON

    GC_RIG=rig LOG_DIR="$logdir" GC_SESSIONS_JSON="$sessions" PATH="$bin:$PATH" \
        bash "$SCRIPT" "$rig" --no-dry-run >"$tmp/out.txt" 2>&1 ||
        fail "audit exited non-zero: $(cat "$tmp/out.txt")"

    [[ ! -e "$homes/dead" ]] ||
        fail "an unowned, childless, clean, fully-published home was not removed"
    [[ -e "$homes/live/seed.txt" ]] ||
        fail "a home owned by a live session was removed out from under it"
    [[ -e "$homes/dirty/seed.txt" ]] ||
        fail "a home with uncommitted work was removed; work would be lost"
    [[ -e "$homes/unpushed/seed.txt" ]] ||
        fail "a home holding commits that reach no remote was removed"
    [[ -e "$homes/parent/worktrees/wt-child/seed.txt" ]] ||
        fail "THE TRAP: a live polecat's per-bead worktree was deleted with its host home"
    [[ -e "$tmp/city/.gc/worktrees/rig/refinery/seed.txt" ]] ||
        fail "a non-polecat agent worktree was removed; only polecat homes are candidates"
    [[ -e "$rig/seed.txt" ]] ||
        fail "the rig root worktree was touched"

    log="$logdir/polecat-home-audit.log"
    [[ -f "$log" ]] || fail "audit wrote no log"
    grep -F '"event":"home_removed"' "$log" >/dev/null ||
        fail "the removal was not recorded in the log"
    grep -F '"agent":"dead"' "$log" >/dev/null ||
        fail "the removed home's agent was not named in the log"
    grep -F '"event":"home_dirty_kept"' "$log" >/dev/null ||
        fail "a dirty home kept was not reported for salvage"
    grep -F '"event":"home_unpublished_commits_kept"' "$log" >/dev/null ||
        fail "a home holding unpublished commits was not reported"
    grep -F '"event":"home_children_kept"' "$log" >/dev/null ||
        fail "a home deferred for its child worktrees was not reported"
    ! grep -F '"agent":"live"' "$log" >/dev/null ||
        fail "a live polecat in its own home is the healthy case and must not be logged as an incident"

    # Git's administrative view must agree with the filesystem.
    ! git -C "$rig" worktree list --porcelain | grep -F "$homes/dead" >/dev/null ||
        fail "the removed home is still registered with git"

    rm -rf "$tmp"
}

test_a_home_with_child_worktrees_is_never_removed() {
    # THE TRAP, isolated. gcp-actg was filed while gascity/gastown.rictus was
    # alive inside the dead gascity/gastown.furiosa home's subtree. The home
    # passes every other gate here — no session, clean, nothing unpublished —
    # and must STILL be deferred, on the child alone.
    local tmp rig origin bin homes sessions logdir log
    tmp=$(make_tmp)
    rig="$tmp/rig"
    origin="$tmp/origin.git"
    bin="$tmp/bin"
    homes="$tmp/city/.gc/worktrees/rig/polecats"
    sessions="$tmp/sessions.json"
    logdir="$tmp/logs"
    mkdir -p "$logdir"

    setup_rig "$rig" "$origin"
    write_gc_stub "$bin"
    add_home "$rig" "$homes" furiosa
    git -C "$rig" worktree add -q "$homes/furiosa/worktrees/rig-g7nf" --detach origin/main

    # The roster knows a live rictus, but rictus's OWN work_dir is its OWN
    # home — nothing in the roster associates it with the furiosa subtree it is
    # actually working in. That is precisely why the guard cannot be a liveness
    # lookup on the home's owner, and must be the child's mere existence.
    cat >"$sessions" <<'JSON'
{"sessions":[
  {"id":"gc-rictus","name":"rig/rictus","alias":"rig/rictus","agent_name":"rig/rictus","state":"active","closed":false}
]}
JSON

    GC_RIG=rig LOG_DIR="$logdir" GC_SESSIONS_JSON="$sessions" PATH="$bin:$PATH" \
        bash "$SCRIPT" "$rig" --no-dry-run >"$tmp/out.txt" 2>&1 ||
        fail "audit exited non-zero: $(cat "$tmp/out.txt")"

    [[ -e "$homes/furiosa/worktrees/rig-g7nf/seed.txt" ]] ||
        fail "THE TRAP: a live polecat's working tree was deleted with the dead home hosting it"
    [[ -e "$homes/furiosa" ]] ||
        fail "a home hosting per-bead worktrees was removed"

    log="$logdir/polecat-home-audit.log"
    [[ "$(reason_for "$log" home_children_kept)" == "has_child_worktrees" ]] ||
        fail "the child-worktree deferral was not reported as one"

    rm -rf "$tmp"
}

test_the_home_is_matched_by_its_own_work_dir_too() {
    # A session whose name does not follow <rig>/<agent> still states which
    # directory it occupies. Ownership must be honoured on that key alone, or a
    # renamed or resumed agent loses its home mid-session.
    local tmp rig origin bin homes sessions logdir
    tmp=$(make_tmp)
    rig="$tmp/rig"
    origin="$tmp/origin.git"
    bin="$tmp/bin"
    homes="$tmp/city/.gc/worktrees/rig/polecats"
    sessions="$tmp/sessions.json"
    logdir="$tmp/logs"
    mkdir -p "$logdir"

    setup_rig "$rig" "$origin"
    write_gc_stub "$bin"
    add_home "$rig" "$homes" nux

    cat >"$sessions" <<JSON
{"sessions":[
  {"id":"gc-odd","name":"something-else-entirely","state":"active","closed":false,
   "work_dir":"$homes/nux"}
]}
JSON

    GC_RIG=rig LOG_DIR="$logdir" GC_SESSIONS_JSON="$sessions" PATH="$bin:$PATH" \
        bash "$SCRIPT" "$rig" --no-dry-run >"$tmp/out.txt" 2>&1 ||
        fail "audit exited non-zero: $(cat "$tmp/out.txt")"

    [[ -e "$homes/nux/seed.txt" ]] ||
        fail "a home was removed from under a live session that named it as its work_dir"

    rm -rf "$tmp"
}

test_real_removal_is_opt_in() {
    # Staged rollout, same posture as polecat-worktree-reap.sh and the native
    # gascity reaper: the patrol step passes no --no-dry-run. If this
    # regresses, home removal goes live on the first pin bump with no
    # observation window.
    local tmp rig origin bin homes sessions logdir log
    tmp=$(make_tmp)
    rig="$tmp/rig"
    origin="$tmp/origin.git"
    bin="$tmp/bin"
    homes="$tmp/city/.gc/worktrees/rig/polecats"
    sessions="$tmp/sessions.json"
    logdir="$tmp/logs"
    mkdir -p "$logdir"

    setup_rig "$rig" "$origin"
    write_gc_stub "$bin"
    add_home "$rig" "$homes" dead
    echo '{"sessions":[]}' >"$sessions"

    GC_RIG=rig LOG_DIR="$logdir" GC_SESSIONS_JSON="$sessions" PATH="$bin:$PATH" \
        bash "$SCRIPT" "$rig" >"$tmp/out.txt" 2>&1 ||
        fail "audit exited non-zero: $(cat "$tmp/out.txt")"

    [[ -e "$homes/dead/seed.txt" ]] ||
        fail "the bare invocation removed a home; real removal must be opt-in"
    grep -F 'dry run' "$tmp/out.txt" >/dev/null ||
        fail "the default run did not say it was a dry run: $(cat "$tmp/out.txt")"

    log="$logdir/polecat-home-audit.log"
    grep -F '"event":"home_removal_pending"' "$log" >/dev/null ||
        fail "the would-remove set was not logged for review"
    grep -F '"dry_run":true' "$log" >/dev/null ||
        fail "log lines do not record that the run was a dry run"

    # Idempotent: a second dry run reaches the same verdict and still removes
    # nothing, so a patrol can run it every cycle.
    GC_RIG=rig LOG_DIR="$logdir" GC_SESSIONS_JSON="$sessions" PATH="$bin:$PATH" \
        bash "$SCRIPT" "$rig" >"$tmp/again.txt" 2>&1 ||
        fail "second dry run exited non-zero: $(cat "$tmp/again.txt")"
    [[ -e "$homes/dead/seed.txt" ]] || fail "the second dry run removed a home"
    [[ "$(tail -n 1 "$tmp/out.txt")" == "$(tail -n 1 "$tmp/again.txt")" ]] ||
        fail "dry runs are not idempotent: '$(tail -n 1 "$tmp/out.txt")' vs '$(tail -n 1 "$tmp/again.txt")'"

    rm -rf "$tmp"
}

test_an_unreadable_session_roster_removes_nothing() {
    # The absent-confirm rule (gcp-g98): a confirmation read that FAILS is not
    # proof of absence. Without this the first Dolt or supervisor hiccup turns
    # the whole sweep into "no session owns anything, remove everything".
    local tmp rig origin bin homes sessions logdir log
    tmp=$(make_tmp)
    rig="$tmp/rig"
    origin="$tmp/origin.git"
    bin="$tmp/bin"
    homes="$tmp/city/.gc/worktrees/rig/polecats"
    sessions="$tmp/sessions.json"
    logdir="$tmp/logs"
    mkdir -p "$logdir"

    setup_rig "$rig" "$origin"
    write_gc_stub "$bin"
    add_home "$rig" "$homes" dead
    echo '{"sessions":[]}' >"$sessions"
    log="$logdir/polecat-home-audit.log"

    # Case 1: the roster read errors.
    GC_RIG=rig LOG_DIR="$logdir" GC_SESSIONS_JSON="$sessions" GC_SESSION_FAIL=1 \
        PATH="$bin:$PATH" bash "$SCRIPT" "$rig" --no-dry-run >"$tmp/failed.txt" 2>&1 ||
        fail "audit exited non-zero on a failing roster read: $(cat "$tmp/failed.txt")"
    [[ -e "$homes/dead/seed.txt" ]] ||
        fail "a home was removed while the session roster was unreadable"
    [[ "$(reason_for "$log" home_roster_unreadable)" == "roster_read_failed" ]] ||
        fail "a failed roster read was not reported as one"

    # Case 2: the roster answers with a shape we do not recognise. Same
    # verdict — an unparseable answer is not an empty roster.
    rm -f "$log"
    printf '[]' >"$sessions"
    GC_RIG=rig LOG_DIR="$logdir" GC_SESSIONS_JSON="$sessions" PATH="$bin:$PATH" \
        bash "$SCRIPT" "$rig" --no-dry-run >"$tmp/shape.txt" 2>&1 ||
        fail "audit exited non-zero on an unparseable roster: $(cat "$tmp/shape.txt")"
    [[ -e "$homes/dead/seed.txt" ]] ||
        fail "a home was removed on a roster whose shape was not understood"
    [[ "$(reason_for "$log" home_roster_unreadable)" == "roster_unparseable" ]] ||
        fail "an unparseable roster was not distinguished from a failed read"

    rm -rf "$tmp"
}

test_unpublished_commits_are_reported_not_removed() {
    # The furiosa case verbatim: a home on a DETACHED HEAD carrying commits
    # that belong to no branch. Whether they are superseded took reading
    # content at origin — a check a sweep must not make — so the only correct
    # action is to report and defer. The detail must say "detached HEAD",
    # because that is the fact that tells a reader why the commits are hard to
    # find at all.
    local tmp rig origin bin homes sessions logdir log
    tmp=$(make_tmp)
    rig="$tmp/rig"
    origin="$tmp/origin.git"
    bin="$tmp/bin"
    homes="$tmp/city/.gc/worktrees/rig/polecats"
    sessions="$tmp/sessions.json"
    logdir="$tmp/logs"
    mkdir -p "$logdir"

    setup_rig "$rig" "$origin"
    write_gc_stub "$bin"
    add_home "$rig" "$homes" furiosa
    git -C "$homes/furiosa" commit -q --allow-empty -m "belongs to no branch"
    echo '{"sessions":[]}' >"$sessions"

    GC_RIG=rig LOG_DIR="$logdir" GC_SESSIONS_JSON="$sessions" PATH="$bin:$PATH" \
        bash "$SCRIPT" "$rig" --no-dry-run >"$tmp/out.txt" 2>&1 ||
        fail "audit exited non-zero: $(cat "$tmp/out.txt")"

    [[ -e "$homes/furiosa/seed.txt" ]] ||
        fail "a home holding unbranched commits was removed rather than reported"

    log="$logdir/polecat-home-audit.log"
    [[ "$(reason_for "$log" home_unpublished_commits_kept)" == "unpublished_commits" ]] ||
        fail "unpublished commits were not reported with a machine-readable reason"
    [[ "$(detail_for "$log" home_unpublished_commits_kept)" == *"detached HEAD"* ]] ||
        fail "the report does not say the commits sit on a detached HEAD: $(detail_for "$log" home_unpublished_commits_kept)"

    rm -rf "$tmp"
}

test_the_sweep_reads_no_beads() {
    # Keying a home guard on bead fields is the shared root of this family of
    # blind spots (gascity-18kz, gcp-4k6o, gcp-actg): a home HAS no bead, so a
    # bead lookup can only ever come back empty and be misread as "nothing to
    # own". A `gc bd` call appearing here means the fix has been undone.
    local tmp rig origin bin homes sessions logdir calls
    tmp=$(make_tmp)
    rig="$tmp/rig"
    origin="$tmp/origin.git"
    bin="$tmp/bin"
    homes="$tmp/city/.gc/worktrees/rig/polecats"
    sessions="$tmp/sessions.json"
    logdir="$tmp/logs"
    calls="$tmp/calls.txt"
    mkdir -p "$logdir"

    setup_rig "$rig" "$origin"
    write_gc_stub "$bin"
    add_home "$rig" "$homes" dead
    add_home "$rig" "$homes" other
    echo '{"sessions":[]}' >"$sessions"

    GC_RIG=rig LOG_DIR="$logdir" GC_SESSIONS_JSON="$sessions" GC_CALLS="$calls" \
        PATH="$bin:$PATH" bash "$SCRIPT" "$rig" --no-dry-run >"$tmp/out.txt" 2>&1 ||
        fail "audit exited non-zero: $(cat "$tmp/out.txt")"

    ! grep -qx bd "$calls" ||
        fail "the home sweep read the bead store; ownership must come from the session roster alone"
    [[ "$(grep -cx session "$calls")" == "1" ]] ||
        fail "the session roster was read $(grep -cx session "$calls") times; it must be fetched once per run"

    rm -rf "$tmp"
}

test_budget_expiry_defers_rather_than_hangs() {
    # A patrol step that never returns stalls the patrol. The sweep spends one
    # shared wall clock and reports what it did not reach, rather than running
    # until something else kills it.
    local tmp rig origin bin homes sessions logdir log started ended
    tmp=$(make_tmp)
    rig="$tmp/rig"
    origin="$tmp/origin.git"
    bin="$tmp/bin"
    homes="$tmp/city/.gc/worktrees/rig/polecats"
    sessions="$tmp/sessions.json"
    logdir="$tmp/logs"
    mkdir -p "$logdir"

    setup_rig "$rig" "$origin"
    write_gc_stub "$bin"
    write_git_stub "$bin"
    add_home "$rig" "$homes" one
    add_home "$rig" "$homes" two
    echo '{"sessions":[]}' >"$sessions"

    started=$(date +%s)
    GC_RIG=rig LOG_DIR="$logdir" GC_SESSIONS_JSON="$sessions" \
        GIT_STATUS_DELAY=30 GC_HOME_AUDIT_BUDGET_SECONDS=4 PATH="$bin:$PATH" \
        bash "$SCRIPT" "$rig" --no-dry-run >"$tmp/out.txt" 2>&1 ||
        fail "audit exited non-zero when its budget expired: $(cat "$tmp/out.txt")"
    ended=$(date +%s)

    (( ended - started < 25 )) ||
        fail "the audit ran $((ended - started))s on a 4s budget; the bound is not enforced"
    [[ -e "$homes/one/seed.txt" && -e "$homes/two/seed.txt" ]] ||
        fail "a home was removed without its status ever being read"
    grep -F 'budget spent' "$tmp/out.txt" >/dev/null ||
        fail "a truncated cycle reported as a clean one: $(cat "$tmp/out.txt")"

    log="$logdir/polecat-home-audit.log"
    grep -F '"event":"home_status_unreadable"' "$log" >/dev/null ||
        fail "the home whose git status was cut short was not reported"
    [[ "$(reason_for "$log" home_status_unreadable)" == "git_status_timed_out" ]] ||
        fail "a git status cut short by the budget was reported as a failure of the checkout"

    rm -rf "$tmp"
}

test_a_check_that_never_ran_is_not_reported_as_a_failure() {
    # `home_budget_truncated` is the never-attempted case and names nothing
    # external; every other event means a command actually ran. Blurring the
    # two is what sent readers at a healthy Dolt server twice in one night
    # (gcp-mqu9, in the sibling reaper) — the same distinction has to hold here.
    local tmp rig origin bin homes sessions logdir log
    tmp=$(make_tmp)
    rig="$tmp/rig"
    origin="$tmp/origin.git"
    bin="$tmp/bin"
    homes="$tmp/city/.gc/worktrees/rig/polecats"
    sessions="$tmp/sessions.json"
    logdir="$tmp/logs"
    mkdir -p "$logdir"

    setup_rig "$rig" "$origin"
    write_gc_stub "$bin"
    write_git_stub "$bin"
    add_home "$rig" "$homes" one
    echo '{"sessions":[]}' >"$sessions"
    log="$logdir/polecat-home-audit.log"

    # Case 1: the roster read RAN and was cut off at the budget. The reason
    # must name the read, and the detail must point at the seconds it was
    # given — otherwise a short budget reads as a broken supervisor.
    GC_RIG=rig LOG_DIR="$logdir" GC_SESSIONS_JSON="$sessions" \
        GC_SESSION_DELAY=20 GC_HOME_AUDIT_BUDGET_SECONDS=3 PATH="$bin:$PATH" \
        bash "$SCRIPT" "$rig" --no-dry-run >"$tmp/slow.txt" 2>&1 ||
        fail "audit exited non-zero on a slow roster read: $(cat "$tmp/slow.txt")"

    [[ -e "$homes/one/seed.txt" ]] ||
        fail "a home was removed after a roster read that never completed"
    [[ "$(reason_for "$log" home_roster_unreadable)" == "roster_read_timed_out" ]] ||
        fail "a roster read cut short by the budget was not named as such"
    [[ "$(detail_for "$log" home_roster_unreadable)" == *"budget"* ]] ||
        fail "the roster timeout does not point at the budget it hit: $(detail_for "$log" home_roster_unreadable)"

    # Case 2: the budget was already gone when the worktree list came due, so
    # NOTHING was enumerated. Nothing external failed here, and the log must
    # not imply that git or the roster did — it is the clock's line alone.
    rm -f "$log"
    GC_RIG=rig LOG_DIR="$logdir" GC_SESSIONS_JSON="$sessions" \
        GIT_PRUNE_DELAY=20 GC_HOME_AUDIT_BUDGET_SECONDS=3 PATH="$bin:$PATH" \
        bash "$SCRIPT" "$rig" --no-dry-run >"$tmp/starved.txt" 2>&1 ||
        fail "audit exited non-zero when its budget was spent up front: $(cat "$tmp/starved.txt")"

    [[ -e "$homes/one/seed.txt" ]] || fail "a home was removed without being enumerated"
    [[ "$(reason_for "$log" home_budget_truncated)" == "budget_spent_before_worktree_list" ]] ||
        fail "a check that never ran was not reported as never having run"
    ! grep -F '"event":"home_roster_unreadable"' "$log" >/dev/null ||
        fail "a run that never asked the roster anything blamed the roster"
    ! grep -F '"event":"home_worktree_list_failed"' "$log" >/dev/null ||
        fail "a worktree list that was never attempted was reported as a failure of git"

    rm -rf "$tmp"
}

test_git_failures_are_distinguished_from_a_short_budget() {
    # Same honesty rule on the other two git calls: a checkout git could not
    # read is a real incident with a real owner, and must not wear the same
    # reason as a clock that ran out.
    local tmp rig origin bin homes sessions logdir log
    tmp=$(make_tmp)
    rig="$tmp/rig"
    origin="$tmp/origin.git"
    bin="$tmp/bin"
    homes="$tmp/city/.gc/worktrees/rig/polecats"
    sessions="$tmp/sessions.json"
    logdir="$tmp/logs"
    mkdir -p "$logdir"

    setup_rig "$rig" "$origin"
    write_gc_stub "$bin"
    write_git_stub "$bin"
    add_home "$rig" "$homes" one
    echo '{"sessions":[]}' >"$sessions"
    log="$logdir/polecat-home-audit.log"

    GC_RIG=rig LOG_DIR="$logdir" GC_SESSIONS_JSON="$sessions" GIT_STATUS_FAIL=1 \
        PATH="$bin:$PATH" bash "$SCRIPT" "$rig" --no-dry-run >"$tmp/status.txt" 2>&1 ||
        fail "audit exited non-zero on a failing git status: $(cat "$tmp/status.txt")"
    [[ "$(reason_for "$log" home_status_unreadable)" == "git_status_failed" ]] ||
        fail "a genuine git status failure was not reported as one"
    [[ "$(detail_for "$log" home_status_unreadable)" == *"exited 128"* ]] ||
        fail "the git status failure does not name the exit code"
    [[ -e "$homes/one/seed.txt" ]] || fail "a home whose git status failed was removed"

    rm -f "$log"
    GC_RIG=rig LOG_DIR="$logdir" GC_SESSIONS_JSON="$sessions" GIT_REVLIST_FAIL=1 \
        PATH="$bin:$PATH" bash "$SCRIPT" "$rig" --no-dry-run >"$tmp/revlist.txt" 2>&1 ||
        fail "audit exited non-zero on a failing rev-list: $(cat "$tmp/revlist.txt")"
    [[ "$(reason_for "$log" home_commits_unreadable)" == "rev_list_failed" ]] ||
        fail "a genuine rev-list failure was not reported as one"
    [[ -e "$homes/one/seed.txt" ]] ||
        fail "a home was removed without ever establishing its commits were published"

    rm -rf "$tmp"
}

test_every_line_is_stamped_at_the_event_not_at_the_run() {
    # A log where every line carries the run's start stamp cannot show that a
    # cycle spent its whole budget, or in what order decisions fell.
    local tmp rig origin bin homes sessions logdir log stamps
    tmp=$(make_tmp)
    rig="$tmp/rig"
    origin="$tmp/origin.git"
    bin="$tmp/bin"
    homes="$tmp/city/.gc/worktrees/rig/polecats"
    sessions="$tmp/sessions.json"
    logdir="$tmp/logs"
    mkdir -p "$logdir"

    setup_rig "$rig" "$origin"
    write_gc_stub "$bin"
    write_git_stub "$bin"
    add_home "$rig" "$homes" one
    add_home "$rig" "$homes" two
    echo scratch >"$homes/one/seed.txt"
    echo scratch >"$homes/two/seed.txt"
    echo '{"sessions":[]}' >"$sessions"

    GC_RIG=rig LOG_DIR="$logdir" GC_SESSIONS_JSON="$sessions" \
        GIT_STATUS_DELAY=2 GC_HOME_AUDIT_BUDGET_SECONDS=20 PATH="$bin:$PATH" \
        bash "$SCRIPT" "$rig" --no-dry-run >"$tmp/out.txt" 2>&1 ||
        fail "audit exited non-zero: $(cat "$tmp/out.txt")"

    log="$logdir/polecat-home-audit.log"
    stamps=$(jq -r 'select(.event == "home_dirty_kept") | .ts' "$log" | sort -u | wc -l | tr -d ' ')
    [[ "$stamps" -gt 1 ]] ||
        fail "two decisions seconds apart share one timestamp; ts is the run's start, not the event's"
    jq -e 'select(.event == "home_dirty_kept") | .run_started != null and .run_started != ""' "$log" >/dev/null ||
        fail "lines carry no run_started, so they cannot be grouped into cycles"

    rm -rf "$tmp"
}

test_removes_only_unowned_childless_clean_published_homes
test_a_home_with_child_worktrees_is_never_removed
test_the_home_is_matched_by_its_own_work_dir_too
test_real_removal_is_opt_in
test_an_unreadable_session_roster_removes_nothing
test_unpublished_commits_are_reported_not_removed
test_the_sweep_reads_no_beads
test_budget_expiry_defers_rather_than_hangs
test_a_check_that_never_ran_is_not_reported_as_a_failure
test_git_failures_are_distinguished_from_a_short_budget
test_every_line_is_stamped_at_the_event_not_at_the_run

echo "polecat home audit tests passed"
