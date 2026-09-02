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
# The `bd show` arm reproduces real bd's THREE observable behaviours for a
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
    local tmp rig bin home beads sessions logdir calls
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

    add_bead_worktree "$rig" "$home" wt-one
    add_bead_worktree "$rig" "$home" wt-two
    add_bead_worktree "$rig" "$home" wt-three
    add_bead_worktree "$rig" "$home" wt-four

    cat >"$beads" <<'JSON'
[
  {"id":"wt-one","status":"closed","metadata":{"polecat_session":"deadsess"}},
  {"id":"wt-two","status":"closed","metadata":{"polecat_session":"deadsess"}},
  {"id":"wt-three","status":"open","metadata":{"polecat_session":"deadsess"}},
  {"id":"wt-four","status":"closed","metadata":{"polecat_session":"deadsess"}}
]
JSON
    printf '{"sessions":[]}' >"$sessions"

    GC_RIG=rig LOG_DIR="$logdir" GC_BEADS_JSON="$beads" GC_SESSIONS_JSON="$sessions" \
        GC_BD_CALLS="$calls" PATH="$bin:$PATH" bash "$SCRIPT" "$rig" --no-dry-run \
        >"$tmp/out.txt" 2>&1 || fail "reaper exited non-zero: $(cat "$tmp/out.txt")"

    local n
    n=$(wc -c <"$calls" | tr -d ' ')
    [[ "$n" == "1" ]] ||
        fail "bead status was read in $n calls for 4 worktrees; it must be one bulk query"

    [[ ! -e "$home/worktrees/wt-one" && ! -e "$home/worktrees/wt-two" && ! -e "$home/worktrees/wt-four" ]] ||
        fail "the bulk read lost a closed bead: a worktree that should have been reaped survived"
    [[ -e "$home/worktrees/wt-three" ]] ||
        fail "the bulk read mixed up bead identities: an open bead's worktree was reaped"

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
    started=$SECONDS
    GC_RIG=rig LOG_DIR="$logdir" GC_BEADS_JSON="$beads" GC_SESSIONS_JSON="$sessions" \
        GC_BD_DELAY=20 GC_REAP_BUDGET_SECONDS=2 PATH="$bin:$PATH" bash "$SCRIPT" "$rig" --no-dry-run \
        >"$tmp/slow.txt" 2>&1 || fail "a slow bead store made the reaper exit non-zero: $(cat "$tmp/slow.txt")"
    elapsed=$((SECONDS - started))

    [[ "$elapsed" -lt 10 ]] ||
        fail "the reaper waited ${elapsed}s on a 2s budget; a slow read is not bounded"
    [[ -e "$home/worktrees/wt-alpha" ]] ||
        fail "a worktree was reaped on a bead read that never answered"
    grep -F '"event":"worktree_bead_query_failed"' "$logdir/polecat-worktree-reap.log" >/dev/null ||
        fail "the timed-out bead query was not recorded"

    # Case 2: the budget runs out mid-loop. Remaining candidates are deferred
    # to the next cycle and the run still exits clean.
    started=$SECONDS
    GC_RIG=rig LOG_DIR="$logdir" GC_BEADS_JSON="$beads" GC_SESSIONS_JSON="$sessions" \
        GC_SESSION_DELAY=20 PATH="$bin:$PATH" bash "$SCRIPT" "$rig" --no-dry-run --budget 3 \
        >"$tmp/mid.txt" 2>&1 || fail "an exhausted budget made the reaper exit non-zero: $(cat "$tmp/mid.txt")"
    elapsed=$((SECONDS - started))

    [[ "$elapsed" -lt 15 ]] ||
        fail "the reaper waited ${elapsed}s on a 3s budget; the roster read is not bounded"
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
    rm -f "$log"
    GC_RIG=rig LOG_DIR="$logdir" GC_BEADS_JSON="$beads" GC_SESSIONS_JSON="$sessions" \
        GC_BD_DELAY=20 GC_REAP_BUDGET_SECONDS=2 PATH="$bin:$PATH" \
        bash "$SCRIPT" "$rig" --no-dry-run >"$tmp/slowbd.txt" 2>&1 ||
        fail "reaper exited non-zero on a slow bead store: $(cat "$tmp/slowbd.txt")"

    [[ "$(reason_for "$log" worktree_bead_query_failed)" == "bead_query_timed_out" ]] ||
        fail "a bead read that overran was not reported as a timeout"
    [[ "$(detail_for "$log" worktree_bead_query_failed)" == *"did not answer within"* ]] ||
        fail "the bead-read timeout does not say how long it was given: $(detail_for "$log" worktree_bead_query_failed)"
    [[ "$(detail_for "$log" worktree_bead_query_failed)" != *"no usable JSON"* ]] ||
        fail "a timed-out bead read still claims the store returned unusable JSON"

    # Case 3: the roster read overran. Same rule — it names the bound it hit, so
    # a reader checks the budget before suspecting the session roster.
    rm -f "$log"
    GC_RIG=rig LOG_DIR="$logdir" GC_BEADS_JSON="$beads" GC_SESSIONS_JSON="$sessions" \
        GC_SESSION_DELAY=20 GC_REAP_BUDGET_SECONDS=3 PATH="$bin:$PATH" \
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

echo "polecat worktree reap tests passed"
