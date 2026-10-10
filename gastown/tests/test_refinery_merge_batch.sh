#!/usr/bin/env bash
# Black-box proof of merge-batch.sh `select`, `stack`, `land` and `serial` against
# real git repositories (gcp-l8td.8, D1.1; gcp-l8td.9, D1.2; gcp-l8td.11, D1.2b).
#
# merge-batch.sh chooses and stacks a batch of beads for the refinery's direct
# lane. It is inert until the formula calls it (gcp-l8td.10), so these cases are
# its whole proof: each one asserts what the script DID, which is the member ids
# it printed, the manifest it wrote, the commits `temp` ended on, the commits it
# landed on the target, and the bead writes it made or declined to make. None asserts how the script is written,
# except the invariant case, whose subject is the script's text.
#
# The rig is real git: a bare origin, a polecat clone that pushed one branch per
# bead, and the refinery's clone with `temp` rebased onto the target, which is
# what the patrol's `rebase` step leaves behind. Only gc is stubbed. The stub is
# modeled on test_refinery_merge_lanes.sh's, but holds a fixture DIRECTORY with
# one JSON file per bead, so a batch of beads can be read, listed and written:
#   gc bd list        every fixture bead, unsorted, so select's own sort is what
#                     the cases test; the stub insists on the query's flags
#   gc bd show <id>   that bead's file; fails for the ids in GC_STUB_FAIL_SHOW
#   gc bd update <id> --set-metadata, --unset-metadata, --assignee, --status;
#                     fails for the ids in GC_STUB_FAIL_UPDATE
#   gc bd note <id> --stdin   appends stdin to $GC_STUB_BEADS/<id>.notes
#   gc bd close <id>  status closed and the close reason; fails for the ids in
#                     GC_STUB_FAIL_CLOSE
# Every call is journalled to $T/gc.log. A call the model does not know fails
# loudly (exit 64) and fails the case.
#
# Each script run is under `env -i`, so no agent-session GC_* variable can leak
# in. SCRIPT may point at another copy of merge-batch.sh; it finds merge-push.sh
# beside itself, so stage a copy as a pack tree.
#
# The suite fails unless all 22 cases ran.
set -uo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
PACK_DIR="$ROOT/gastown"
SCRIPT="${SCRIPT:-$PACK_DIR/assets/scripts/refinery/merge-batch.sh}"
PUSH_SCRIPT="$(dirname "$SCRIPT")/merge-push.sh"
EXPECTED_CASES=22

AGENT=testrig/gastown.refinery
TARGET_NAME=integration
FAILURES=0
PASS_CASES=0
CASE=""

fail() {
    echo "FAIL[$CASE]: $*" >&2
    FAILURES=$((FAILURES + 1))
}

assert_eq() {
    # assert_eq <what> <want> <got>
    [ "$2" = "$3" ] || fail "$1: want '$2', got '$3'"
}

# --- stubs ------------------------------------------------------------------

write_gc_stub() {
    cat >"$1/gc" <<'STUB'
#!/usr/bin/env bash
ARGS=("$@")
printf 'gc %s\n' "$*" >>"$GC_STUB_LOG"
unexpected() {
    printf 'gc %s\n' "${ARGS[*]}" >>"$STUB_UNEXPECTED"
    echo "stub gc: unexpected invocation: gc ${ARGS[*]}" >&2
    exit 64
}
edit_bead() {
    local file="$1" tmp
    shift
    tmp=$(mktemp) || exit 70
    jq "$@" "$file" >"$tmp" && mv -f "$tmp" "$file"
}
case "${1:-}" in
bd)
    case "${2:-}" in
    list)
        # The assignee scan find-work runs: this agent's, in-flight, beads with a
        # branch, unlimited. Anything else is a query the model does not know.
        assignee="" limit="" json="" status="" branch_key=""
        shift 2
        while [ "$#" -gt 0 ]; do
            case "$1" in
            --assignee=*) assignee="${1#*=}" ;;
            --limit=*) limit="${1#*=}" ;;
            --status=*) status="${1#*=}" ;;
            --has-metadata-key=*) branch_key="${1#*=}" ;;
            --rig=* | --exclude-type=*) : ;;
            --json) json=1 ;;
            *) unexpected ;;
            esac
            shift
        done
        { [ "$assignee" = "$GC_STUB_AGENT" ] && [ "$limit" = 0 ] && [ -n "$json" ] &&
            [ "$status" = open,in_progress ] && [ "$branch_key" = branch ]; } || unexpected
        jq -s 'map(.[0])' "$GC_STUB_BEADS"/*.json
        ;;
    show)
        { [ "$#" -eq 4 ] && [ "$4" = --json ]; } || unexpected
        case " ${GC_STUB_FAIL_SHOW:-} " in
        *" $3 "*)
            echo "stub gc: gc bd show $3 failed on request" >&2
            exit 1
            ;;
        esac
        [ -f "$GC_STUB_BEADS/$3.json" ] || {
            echo "stub gc: no such bead: $3" >&2
            exit 1
        }
        cat "$GC_STUB_BEADS/$3.json"
        ;;
    update)
        id="${3:-}"
        file="$GC_STUB_BEADS/$id.json"
        [ -f "$file" ] || unexpected
        case " ${GC_STUB_FAIL_UPDATE:-} " in
        *" $id "*)
            echo "stub gc: gc bd update $id failed on request" >&2
            exit 1
            ;;
        esac
        shift 3
        while [ "$#" -gt 0 ]; do
            case "$1" in
            --assignee=*) edit_bead "$file" --arg v "${1#*=}" '.[0].assignee = $v' ;;
            --status=*) edit_bead "$file" --arg v "${1#*=}" '.[0].status = $v' ;;
            --set-metadata)
                edit_bead "$file" --arg k "${2%%=*}" --arg v "${2#*=}" '.[0].metadata[$k] = $v'
                shift
                ;;
            --unset-metadata)
                edit_bead "$file" --arg k "$2" 'del(.[0].metadata[$k])'
                shift
                ;;
            *) unexpected ;;
            esac
            shift
        done
        ;;
    note)
        # gc bd note <id> --stdin: the note text is appended to <id>.notes.
        { [ "$#" -eq 4 ] && [ "$4" = --stdin ] && [ -f "$GC_STUB_BEADS/${3:-}.json" ]; } || unexpected
        cat >>"$GC_STUB_BEADS/$3.notes"
        ;;
    close)
        case " ${GC_STUB_FAIL_CLOSE:-} " in
        *" ${3:-} "*)
            echo "stub gc: gc bd close ${3:-} failed on request" >&2
            exit 1
            ;;
        esac
        file="$GC_STUB_BEADS/${3:-}.json"
        { [ "$#" -eq 5 ] && [ "$4" = --reason ] && [ -f "$file" ]; } || unexpected
        edit_bead "$file" --arg r "$5" '.[0].status = "closed" | .[0].close_reason = $r'
        ;;
    *) unexpected ;;
    esac
    ;;
gastown)
    # gc gastown task-artifact-cleanup <id>: the pack command a lane runs after
    # a verified close (upstream's task-artifact lifecycle). Journalled only;
    # its own suite owns its behaviour.
    { [ "${2:-}" = task-artifact-cleanup ] && [ "$#" -eq 3 ]; } || unexpected
    ;;
*) unexpected ;;
esac
exit 0
STUB
    chmod +x "$1/gc"
}

# --- rig --------------------------------------------------------------------

git_q() { git "$@" >/dev/null 2>&1; }

new_case() {
    CASE="$1"
    CASE_START_FAILURES=$FAILURES
    T=$(mktemp -d "${TMPDIR:-/tmp}/merge-batch.XXXXXX")
    ORIGIN="$T/origin.git"
    SEED="$T/seed"
    POLECAT="$T/polecat"
    REFINERY="$T/refinery"
    BEADS="$T/beads"
    mkdir -p "$T/home" "$T/tmp" "$T/bin" "$BEADS"
    cat >"$T/home/.gitconfig" <<'CFG'
[init]
	defaultBranch = integration
[user]
	name = refinery
	email = refinery@example.invalid
[advice]
	detachedHead = false
[protocol "file"]
	allow = always
[commit]
	gpgsign = false
CFG
    export HOME="$T/home"
    export GIT_CONFIG_GLOBAL="$T/home/.gitconfig"
    export GIT_CONFIG_NOSYSTEM=1
    export GIT_AUTHOR_NAME=refinery GIT_AUTHOR_EMAIL=refinery@example.invalid
    export GIT_COMMITTER_NAME=refinery GIT_COMMITTER_EMAIL=refinery@example.invalid
    write_gc_stub "$T/bin"
    : >"$T/gc.log"
    : >"$T/unexpected"
    : >"$T/out"
    : >"$T/err"
    FAIL_SHOW=""
    FAIL_CLOSE=""
    FAIL_UPDATE=""
    EXTRA_ENV=()
    CONFIG_JSON="$T/config.json"
    write_config
}

end_case() {
    [ ! -s "$T/unexpected" ] || fail "unmodelled stub call(s): $(tr '\n' ';' <"$T/unexpected")"
    if [ "$FAILURES" -ne "$CASE_START_FAILURES" ]; then
        {
            echo "--- $CASE: last run (status $(last_rc 2>/dev/null)) stdout ---"
            cat "$T/out"
            echo "--- $CASE: last run stderr ---"
            cat "$T/err"
            echo "--- $CASE: gc calls ---"
            cat "$T/gc.log"
        } >&2
    fi
    trash "$T" 2>/dev/null || rm -rf "$T"
    PASS_CASES=$((PASS_CASES + 1))
}

# write_config [require_merge_approval=value] — the city config the script reads
# through MERGE_PUSH_CONFIG_JSON.
write_config() {
    local vars='{}' kv
    for kv in "$@"; do
        vars=$(jq -c --arg k "${kv%%=*}" --arg v "${kv#*=}" '. + {($k): $v}' <<<"$vars")
    done
    jq -n --argjson vars "$vars" \
        '{config: {Rigs: [{Name: "testrig", DefaultBranch: "integration", FormulaVars: $vars}]}}' >"$CONFIG_JSON"
}

# init_rig — a bare origin holding the baseline, and the clone polecats work in.
init_rig() {
    git_q init --bare "$ORIGIN"
    git_q init "$SEED"
    printf 'alpha\nbeta\ngamma\n' >"$SEED/shared.txt"
    echo baseline >"$SEED/README.md"
    git_q -C "$SEED" add -A
    git_q -C "$SEED" commit -m "chore: baseline"
    git_q -C "$SEED" remote add origin "$ORIGIN"
    git_q -C "$SEED" push origin HEAD:integration
    FORK_SHA=$(git -C "$SEED" rev-parse HEAD)
    git_q clone "$ORIGIN" "$POLECAT"
}

# add_branch <bead-id> <file> <content> [commits] — polecat/<bead-id> forks from
# the baseline and adds <file>, once per commit, then is pushed.
add_branch() {
    local id="$1" file="$2" content="$3" n="${4:-1}" i
    git_q -C "$POLECAT" checkout -B "polecat/$id" "$FORK_SHA"
    for i in $(seq 1 "$n"); do
        printf '%s (commit %s)\n' "$content" "$i" >"$POLECAT/$file"
        git_q -C "$POLECAT" add "$file"
        git_q -C "$POLECAT" commit -m "feat: $id change $i"
    done
    git_q -C "$POLECAT" push -f origin "polecat/$id"
}

# edit_shared <bead-id> <text> — polecat/<bead-id> rewrites line 1 of shared.txt.
edit_shared() {
    local id="$1"
    git_q -C "$POLECAT" checkout -B "polecat/$id" "$FORK_SHA"
    printf '%s\nbeta\ngamma\n' "$2" >"$POLECAT/shared.txt"
    git_q -C "$POLECAT" add shared.txt
    git_q -C "$POLECAT" commit -m "feat: $id edits the shared line"
    git_q -C "$POLECAT" push -f origin "polecat/$id"
}

# move_target <file> — another bead's work lands on the target, so the head's
# rebase is a real rewrite and not a no-op.
move_target() {
    git_q -C "$SEED" pull origin integration
    echo "someone else" >"$SEED/$1"
    git_q -C "$SEED" add "$1"
    git_q -C "$SEED" commit -m "feat: a concurrent bead"
    git_q -C "$SEED" push origin HEAD:integration
}

# land_by_patch_id <bead-id> — the bead's branch tip is cherry-picked onto the
# target: the same patch under a new sha, which is how a rebasing lane lands.
land_by_patch_id() {
    git_q -C "$SEED" pull origin integration
    git_q -C "$SEED" fetch origin "+refs/heads/polecat/$1:refs/remotes/origin/polecat/$1"
    git_q -C "$SEED" cherry-pick "origin/polecat/$1"
    git_q -C "$SEED" push origin HEAD:integration
}

# finish_rig <head-id> — the refinery's clone with `temp` rebased onto the target,
# as the rebase step leaves it. Sets ENTRY_SHA, the head tip the script records.
finish_rig() {
    git_q clone "$ORIGIN" "$REFINERY"
    git_q -C "$REFINERY" checkout -b temp "origin/polecat/$1"
    git_q -C "$REFINERY" rebase origin/integration ||
        fail "harness bug: the head's rebase did not apply cleanly"
    ENTRY_SHA=$(git -C "$REFINERY" rev-parse --verify -q temp)
    [ -n "$ENTRY_SHA" ] || fail "harness bug: finish_rig left no temp branch"
}

# write_bead <id> <priority> <created_at> [key=value ...] — a bead as `gc bd show`
# returns it, assigned to the refinery, with the polecat's branch metadata.
write_bead() {
    local id="$1" prio="$2" created="$3" kv tmp
    shift 3
    jq -n --arg id "$id" --argjson prio "$prio" --arg created "$created" --arg agent "$AGENT" \
        --arg branch "polecat/$id" --arg target "$TARGET_NAME" --arg fork "$FORK_SHA" \
        '[{id: $id, title: ("Bead " + $id), priority: $prio, created_at: $created,
           issue_type: "task", status: "in_progress", assignee: $agent,
           metadata: {branch: $branch, target: $target, fork_sha: $fork}}]' >"$BEADS/$id.json"
    for kv in "$@"; do
        set_meta "$id" "${kv%%=*}" "${kv#*=}"
    done
}

set_meta() {
    local tmp
    tmp=$(mktemp)
    jq --arg k "$2" --arg v "$3" '.[0].metadata[$k] = $v' "$BEADS/$1.json" >"$tmp" && mv -f "$tmp" "$BEADS/$1.json"
}

unset_meta() {
    local tmp
    tmp=$(mktemp)
    jq --arg k "$2" 'del(.[0].metadata[$k])' "$BEADS/$1.json" >"$tmp" && mv -f "$tmp" "$BEADS/$1.json"
}

bead_meta() { jq -r --arg k "$2" '.[0].metadata[$k] // "<unset>"' "$BEADS/$1.json"; }
bead_field() { jq -r --arg k "$2" '.[0][$k] // "<unset>"' "$BEADS/$1.json"; }
bead_sum() { cksum <"$BEADS/$1.json"; }

# --- running the script -----------------------------------------------------

# run_batch <args...> — run merge-batch.sh inside the refinery clone, as the
# patrol does. Sets RC, and leaves stdout in $T/out and stderr in $T/err. The
# cd fails closed: a script run anywhere else would fetch and push the origin of
# whatever checkout the suite started in.
run_batch() {
    (
        cd "$REFINERY" || exit 90
        env -i \
            PATH="$T/bin:$PATH" HOME="$T/home" TMPDIR="$T/tmp" \
            GIT_CONFIG_GLOBAL="$T/home/.gitconfig" GIT_CONFIG_NOSYSTEM=1 \
            GIT_AUTHOR_NAME=refinery GIT_AUTHOR_EMAIL=refinery@example.invalid \
            GIT_COMMITTER_NAME=refinery GIT_COMMITTER_EMAIL=refinery@example.invalid \
            GC_RIG=testrig GC_AGENT="$AGENT" MERGE_PUSH_CONFIG_JSON="$CONFIG_JSON" \
            GC_STUB_LOG="$T/gc.log" GC_STUB_BEADS="$BEADS" GC_STUB_AGENT="$AGENT" \
            GC_STUB_FAIL_SHOW="$FAIL_SHOW" GC_STUB_FAIL_CLOSE="$FAIL_CLOSE" \
            GC_STUB_FAIL_UPDATE="$FAIL_UPDATE" \
            STUB_UNEXPECTED="$T/unexpected" \
            ${EXTRA_ENV[@]+"${EXTRA_ENV[@]}"} \
            "$BASH" "$SCRIPT" "$@"
    ) >"$T/out" 2>"$T/err"
    RC=$?
    # `selected` runs this in a command substitution, where RC would be lost.
    echo "$RC" >"$T/rc"
}

# run_push <args...> — run merge-push.sh, the single-bead lane, in the refinery
# clone under run_batch's env: the recovery a left-open member relies on. --gh
# names a binary that does not exist, so the lane never reaches for a real gh.
run_push() {
    (
        cd "$REFINERY" || exit 90
        env -i \
            PATH="$T/bin:$PATH" HOME="$T/home" TMPDIR="$T/tmp" \
            GIT_CONFIG_GLOBAL="$T/home/.gitconfig" GIT_CONFIG_NOSYSTEM=1 \
            GIT_AUTHOR_NAME=refinery GIT_AUTHOR_EMAIL=refinery@example.invalid \
            GIT_COMMITTER_NAME=refinery GIT_COMMITTER_EMAIL=refinery@example.invalid \
            GC_RIG=testrig GC_AGENT="$AGENT" MERGE_PUSH_CONFIG_JSON="$CONFIG_JSON" \
            GC_STUB_LOG="$T/gc.log" GC_STUB_BEADS="$BEADS" GC_STUB_AGENT="$AGENT" \
            GC_STUB_FAIL_SHOW="$FAIL_SHOW" GC_STUB_FAIL_CLOSE="$FAIL_CLOSE" \
            GC_STUB_FAIL_UPDATE="$FAIL_UPDATE" \
            STUB_UNEXPECTED="$T/unexpected" \
            "$BASH" "$PUSH_SCRIPT" --gh "$T/bin/no-gh" "$@"
    ) >"$T/out" 2>"$T/err"
    RC=$?
    echo "$RC" >"$T/rc"
}

last_rc() { cat "$T/rc"; }

# selected <args...> — run `select` and print the ids it chose on stdout,
# space-separated. It runs in a command substitution, so read the exit status
# with last_rc.
selected() {
    run_batch select "$@"
    tr '\n' ' ' <"$T/out" | sed 's/ $//'
}

manifest_path() { echo "$(git -C "$REFINERY" rev-parse --absolute-git-dir)/refinery-batch.json"; }
mf() { jq -r "$1" "$(manifest_path)"; }
temp_sha() { git -C "$REFINERY" rev-parse --verify -q temp; }
patch_id_of() { git -C "$REFINERY" show "$1" | git patch-id --stable | cut -d' ' -f1; }
current_branch() { git -C "$REFINERY" branch --show-current; }
db_writes() { grep -cE '^gc bd (update|close) ' "$T/gc.log"; }

# assert_stack_clean_up — the tidy-up every stack run owes: temp checked out, no
# scratch branch left behind, no rebase in flight.
assert_tidy() {
    assert_eq "the clone ends on temp" temp "$(current_branch)"
    git -C "$REFINERY" rev-parse --verify -q batch-member >/dev/null 2>&1 &&
        fail "the scratch branch batch-member was left behind"
    [ ! -d "$(git -C "$REFINERY" rev-parse --absolute-git-dir)/rebase-merge" ] ||
        fail "a rebase was left in flight"
}

# --- cases --------------------------------------------------------------------

# The queue the select cases share: five beads whose priorities and creation
# times disagree with their ids, one with a first_submitted_at that beats its
# creation time. The stub lists them by file name, so only the sort puts them in
# order: b2, b4, b3, b1, b5.
case_select_order() {
    new_case select-order
    init_rig
    local i
    for i in 1 2 3 4 5; do add_branch "gcp-b$i" "f$i.txt" "bead $i"; done
    finish_rig gcp-b2
    write_bead gcp-b1 2 2026-10-02T03:00:00Z
    write_bead gcp-b2 1 2026-10-02T05:00:00Z first_submitted_at=2026-10-02T01:00:00Z
    write_bead gcp-b3 2 2026-10-02T01:00:00Z
    write_bead gcp-b4 1 2026-10-02T02:00:00Z
    write_bead gcp-b5 3 2026-10-02T00:30:00Z

    assert_eq "K=3 prints the first three in find-work's order, head first" \
        "gcp-b2 gcp-b4 gcp-b3" "$(selected --head gcp-b2 --max 3)"
    assert_eq "select exits 0" 0 "$(last_rc)"
    assert_eq "K=5 prints the whole queue in order" \
        "gcp-b2 gcp-b4 gcp-b3 gcp-b1 gcp-b5" "$(selected --head gcp-b2 --max 5)"
    assert_eq "K=1 prints the head alone" gcp-b2 "$(selected --head gcp-b2 --max 1)"
    assert_eq "no --max means a batch of 1" gcp-b2 "$(selected --head gcp-b2)"
    # The query is find-work's assignee scan, scoped to the rig and never
    # limited to one: the batch is a prefix of this queue.
    grep -q -- "--assignee=$AGENT" "$T/gc.log" || fail "select did not scan the refinery's assigned beads"
    grep -q -- "--rig=testrig" "$T/gc.log" || fail "select did not scope its scan to the rig"
    grep -q -- "--limit=1" "$T/gc.log" && fail "select limited its scan to one bead"
    assert_eq "select wrote no bead" 0 "$(db_writes)"
    # A head that does not lead the queue is not a prefix: a batch of 1.
    assert_eq "a head that does not lead the queue is a batch of 1" \
        gcp-b4 "$(selected --head gcp-b4 --max 3)"
    end_case
}

# Four beads in one queue order (q1..q4). Each variant spoils q2 in one way, or
# q3 in another, and select must stop in front of the spoiled bead.
case_select_truncation() {
    new_case select-truncation
    init_rig
    local i
    for i in 1 2 3 4; do add_branch "gcp-q$i" "f$i.txt" "bead $i"; done
    finish_rig gcp-q1
    reset_queue() {
        for i in 1 2 3 4; do write_bead "gcp-q$i" 1 "2026-10-02T0$i:00:00Z"; done
    }
    all="gcp-q1 gcp-q2 gcp-q3 gcp-q4"
    sel() { selected --head gcp-q1 --max 4; }

    reset_queue
    assert_eq "baseline: an eligible queue batches whole" "$all" "$(sel)"

    reset_queue
    set_meta gcp-q2 merge_strategy mr
    assert_eq "q2 with merge_strategy=mr ends the batch at the head" gcp-q1 "$(sel)"

    reset_queue
    set_meta gcp-q2 merge_strategy pr
    assert_eq "q2 with merge_strategy=pr (read as mr) ends the batch at the head" gcp-q1 "$(sel)"

    reset_queue
    set_meta gcp-q2 existing_pr https://github.com/acme/widgets/pull/9
    assert_eq "q2 with an existing_pr ends the batch at the head" gcp-q1 "$(sel)"

    reset_queue
    unset_meta gcp-q2 fork_sha
    assert_eq "q2 without fork_sha ends the batch at the head" gcp-q1 "$(sel)"

    reset_queue
    set_meta gcp-q2 target release
    assert_eq "q2 targeting another branch ends the batch at the head" gcp-q1 "$(sel)"

    reset_queue
    set_meta gcp-q2 merge_batch_serial "$(git -C "$REFINERY" rev-parse origin/polecat/gcp-q2)"
    assert_eq "q2 whose merge_batch_serial is its branch tip ends the batch at the head" gcp-q1 "$(sel)"

    reset_queue
    set_meta gcp-q2 merge_batch_serial "$FORK_SHA"
    assert_eq "q2 whose merge_batch_serial is an OLD sha (the branch moved) is included" "$all" "$(sel)"

    reset_queue
    set_meta gcp-q3 merge_strategy mr
    assert_eq "an ineligible q3 keeps q2 and drops q3 and everything behind it" "gcp-q1 gcp-q2" "$(sel)"

    reset_queue
    set_meta gcp-q1 merge_strategy mr
    assert_eq "an ineligible HEAD is still printed: a batch of one is the single-bead lane" \
        gcp-q1 "$(selected --head gcp-q1 --max 4 --require-approval false)"

    # A member whose branch cannot be fetched cannot be shown eligible.
    reset_queue
    git_q -C "$REFINERY" push origin --delete polecat/gcp-q3
    assert_eq "a member whose branch is gone from origin ends the batch" "gcp-q1 gcp-q2" "$(sel)"
    assert_eq "select writes no bead" 0 "$(db_writes)"
    end_case
}

case_select_approval() {
    new_case select-approval
    init_rig
    local i
    for i in 1 2 3 4; do add_branch "gcp-q$i" "f$i.txt" "bead $i"; done
    finish_rig gcp-q1
    for i in 1 2 3 4; do write_bead "gcp-q$i" 1 "2026-10-02T0$i:00:00Z"; done
    all="gcp-q1 gcp-q2 gcp-q3 gcp-q4"

    write_config require_merge_approval=false
    assert_eq "baseline: approval off batches whole" "$all" "$(selected --head gcp-q1 --max 4)"

    write_config require_merge_approval=true
    assert_eq "require_merge_approval=true prints the head only" gcp-q1 "$(selected --head gcp-q1 --max 4)"
    assert_eq "approval on is not an error" 0 "$(last_rc)"

    write_config require_merge_approval=sometimes
    assert_eq "an unrecognized approval value counts as ON" gcp-q1 "$(selected --head gcp-q1 --max 4)"

    write_config
    EXTRA_ENV=(MERGE_PUSH_CONFIG_JSON="$T/missing-config.json")
    assert_eq "an unreadable config (a missing file) prints the head only" gcp-q1 "$(selected --head gcp-q1 --max 4)"
    assert_eq "an unreadable config is not an error" 0 "$(last_rc)"
    grep -q 'fail closed' "$T/err" || fail "select did not say the unreadable config resolved approval ON"
    EXTRA_ENV=()

    printf 'not json' >"$T/garbled.json"
    EXTRA_ENV=(MERGE_PUSH_CONFIG_JSON="$T/garbled.json")
    assert_eq "an unparseable config prints the head only" gcp-q1 "$(selected --head gcp-q1 --max 4)"
    EXTRA_ENV=()
    end_case
}

case_stack_clean() {
    new_case stack-clean
    init_rig
    add_branch gcp-m1 f1.txt "member one"
    add_branch gcp-m2 f2.txt "member two" 2
    add_branch gcp-m3 f3.txt "member three"
    move_target elsewhere.txt
    finish_rig gcp-m1
    write_bead gcp-m1 1 2026-10-02T01:00:00Z
    write_bead gcp-m2 1 2026-10-02T02:00:00Z
    write_bead gcp-m3 1 2026-10-02T03:00:00Z
    local before_m2 before_m3
    before_m2=$(bead_sum gcp-m2)
    before_m3=$(bead_sum gcp-m3)

    run_batch stack --head gcp-m1 --members gcp-m1,gcp-m2,gcp-m3
    assert_eq "stack exits 0" 0 "$(last_rc)"
    assert_eq "the manifest lists the three members in batch order" \
        "gcp-m1 gcp-m2 gcp-m3" "$(mf '[.members[].id] | join(" ")')"
    assert_eq "the manifest names the head" gcp-m1 "$(mf .head)"
    assert_eq "the manifest names the target" integration "$(mf .target)"
    assert_eq "the manifest's base is the head tip recorded at entry" "$ENTRY_SHA" "$(mf .base)"
    assert_eq "the head's recorded tip is the head tip" "$ENTRY_SHA" "$(mf '.members[0].tip')"
    assert_eq "commit counts are 1, 2, 1" "1 2 1" "$(mf '[.members[].commits] | join(" ")')"
    assert_eq "the manifest records each member's branch" \
        "polecat/gcp-m1 polecat/gcp-m2 polecat/gcp-m3" "$(mf '[.members[].branch] | join(" ")')"
    assert_eq "temp ends on the last member's recorded tip" "$(mf '.members[2].tip')" "$(temp_sha)"
    local i
    for i in 1 2 3; do
        git -C "$REFINERY" cat-file -e "temp:f$i.txt" 2>/dev/null || fail "temp's tree lacks member $i's change (f$i.txt)"
        assert_eq "member $i's recorded patch-id is its branch tip commit's" \
            "$(patch_id_of "origin/polecat/gcp-m$i")" "$(mf ".members[$((i - 1))].patch_id")"
        git -C "$REFINERY" merge-base --is-ancestor "$(mf ".members[$((i - 1))].tip")" temp ||
            fail "member $i's recorded tip is not reachable from temp"
    done
    git -C "$REFINERY" cat-file -e "temp:elsewhere.txt" 2>/dev/null || fail "temp lost the target's own commit"
    assert_eq "stack wrote no bead" 0 "$(db_writes)"
    assert_eq "member 2's bead is untouched" "$before_m2" "$(bead_sum gcp-m2)"
    assert_eq "member 3's bead is untouched" "$before_m3" "$(bead_sum gcp-m3)"
    assert_tidy

    # The members may come from the manifest instead of a flag: the agent writes
    # the list it settled on, and stack reads it back.
    git_q -C "$REFINERY" reset --hard "$ENTRY_SHA"
    jq -n '{head: "gcp-m1", members: [{id: "gcp-m1"}, {id: "gcp-m2"}]}' >"$(manifest_path)"
    run_batch stack --head gcp-m1
    assert_eq "stack from a manifest exits 0" 0 "$(last_rc)"
    assert_eq "stack from a manifest stacks the members it names" \
        "gcp-m1 gcp-m2" "$(mf '[.members[].id] | join(" ")')"
    git -C "$REFINERY" cat-file -e "temp:f3.txt" 2>/dev/null && fail "member 3 was stacked though the manifest did not name it"
    # A manifest left by another head is not this batch's.
    git_q -C "$REFINERY" reset --hard "$ENTRY_SHA"
    jq -n '{head: "gcp-other", members: [{id: "gcp-other"}, {id: "gcp-m2"}]}' >"$(manifest_path)"
    run_batch stack --head gcp-m1
    assert_eq "a stale manifest for another head leaves a batch of 1" gcp-m1 "$(mf '[.members[].id] | join(" ")')"
    assert_eq "stack with no members at all leaves temp on the head" "$ENTRY_SHA" "$(temp_sha)"
    # The head must lead an explicit list.
    run_batch stack --head gcp-m1 --members gcp-m2,gcp-m1
    assert_eq "a member list that does not start with the head is a usage error" 1 "$(last_rc)"
    end_case
}

case_stack_conflict() {
    new_case stack-conflict
    init_rig
    edit_shared gcp-c1 "from the first member"
    edit_shared gcp-c2 "from the second member"
    add_branch gcp-c3 f3.txt "member three"
    finish_rig gcp-c1
    write_bead gcp-c1 1 2026-10-02T01:00:00Z
    write_bead gcp-c2 1 2026-10-02T02:00:00Z
    write_bead gcp-c3 1 2026-10-02T03:00:00Z
    local before_c2 before_c3
    before_c2=$(bead_sum gcp-c2)
    before_c3=$(bead_sum gcp-c3)

    run_batch stack --head gcp-c1 --members gcp-c1,gcp-c2,gcp-c3
    assert_eq "stack exits 0 when a member conflicts with an earlier one" 0 "$(last_rc)"
    assert_eq "the manifest holds the head alone" gcp-c1 "$(mf '[.members[].id] | join(" ")')"
    assert_eq "temp is member 1's tip" "$ENTRY_SHA" "$(temp_sha)"
    assert_eq "member 1's recorded tip is the head tip" "$ENTRY_SHA" "$(mf '.members[0].tip')"
    git -C "$REFINERY" cat-file -e "temp:f3.txt" 2>/dev/null && fail "member 3 was stacked behind the conflicting member"
    assert_eq "the conflicting member's bead is byte-identical" "$before_c2" "$(bead_sum gcp-c2)"
    assert_eq "the member behind it is byte-identical" "$before_c3" "$(bead_sum gcp-c3)"
    assert_eq "the conflicting member is not rejected: no bead write at all" 0 "$(db_writes)"
    grep -q 'gcp-c2' "$T/out" || fail "stack did not say where the batch ended"
    assert_tidy
    end_case
}

case_stack_already_landed() {
    new_case stack-already-landed
    init_rig
    add_branch gcp-l1 f1.txt "member one"
    add_branch gcp-l2 f2.txt "member two"
    add_branch gcp-l3 f3.txt "member three"
    move_target elsewhere.txt
    land_by_patch_id gcp-l2
    finish_rig gcp-l1
    write_bead gcp-l1 1 2026-10-02T01:00:00Z
    write_bead gcp-l2 1 2026-10-02T02:00:00Z rejection_reason="an earlier attempt was rejected"
    write_bead gcp-l3 1 2026-10-02T03:00:00Z
    local before_l1 before_l3 l2_patch
    l2_patch=$(patch_id_of origin/polecat/gcp-l2)
    before_l1=$(bead_sum gcp-l1)
    before_l3=$(bead_sum gcp-l3)

    run_batch stack --head gcp-l1 --members gcp-l1,gcp-l2,gcp-l3
    assert_eq "stack exits 0" 0 "$(last_rc)"
    assert_eq "the manifest skips the member that already landed" \
        "gcp-l1 gcp-l3" "$(mf '[.members[].id] | join(" ")')"
    assert_eq "the already-landed member is closed" closed "$(bead_field gcp-l2 status)"
    assert_eq "its merge_result is already_merged" already_merged "$(bead_meta gcp-l2 merge_result)"
    assert_eq "it records how that was established" rebase_patch_id "$(bead_meta gcp-l2 already_merged_via)"
    assert_eq "it records the target" integration "$(bead_meta gcp-l2 merged_target)"
    assert_eq "its stale rejection_reason is cleared" "<unset>" "$(bead_meta gcp-l2 rejection_reason)"
    local merged
    merged=$(bead_meta gcp-l2 merged_sha)
    git -C "$REFINERY" merge-base --is-ancestor "$merged" origin/integration 2>/dev/null ||
        fail "merged_sha $merged is not on origin/integration"
    assert_eq "merged_sha is the target commit that carries the member's patch" \
        "$l2_patch" "$(patch_id_of "$merged")"
    case "$(bead_field gcp-l2 close_reason)" in
    "Already merged to integration at "*) ;;
    *) fail "unexpected close reason: $(bead_field gcp-l2 close_reason)" ;;
    esac
    [ -z "$(git -C "$REFINERY" ls-remote origin refs/heads/polecat/gcp-l2)" ] ||
        fail "the merged member's branch was not deleted (delete_merged_branches defaults on)"
    assert_eq "the head's bead is untouched" "$before_l1" "$(bead_sum gcp-l1)"
    assert_eq "the stacked member's bead is untouched" "$before_l3" "$(bead_sum gcp-l3)"
    git -C "$REFINERY" cat-file -e "temp:f3.txt" 2>/dev/null || fail "stacking did not continue past the closed member"
    assert_eq "temp ends on the last stacked member's tip" "$(mf '.members[1].tip')" "$(temp_sha)"
    assert_eq "the closed member took no place in the commit counts" "1 1" "$(mf '[.members[].commits] | join(" ")')"
    # The agent is told nothing about skipping the merge script: that advice is
    # the single-bead lane's.
    grep -q 'Skip the merge script' "$T/out" && fail "stack leaked the lane's 'skip the merge script' advice"
    assert_tidy
    end_case
}

# A head whose rebase collapsed has no commit of its own. Batched, land would map
# it to another member's commit and close it merged on that sha (M1), so stack
# leaves a batch of 1 and the single-bead lane's merge-state gate decides it.
case_stack_collapsed_head() {
    new_case stack-collapsed-head
    init_rig
    add_branch gcp-h1 f1.txt "head"
    add_branch gcp-h2 f2.txt "member two"
    add_branch gcp-h3 f3.txt "member three"
    move_target elsewhere.txt
    land_by_patch_id gcp-h1
    finish_rig gcp-h1
    write_bead gcp-h1 1 2026-10-02T01:00:00Z
    write_bead gcp-h2 1 2026-10-02T02:00:00Z
    write_bead gcp-h3 1 2026-10-02T03:00:00Z
    local before_temp writes
    before_temp=$(temp_sha)
    assert_eq "harness: the head's rebase collapsed onto the target" \
        "$(git -C "$REFINERY" rev-parse origin/integration)" "$before_temp"
    writes=$(db_writes)

    run_batch stack --head gcp-h1 --members gcp-h1,gcp-h2,gcp-h3
    assert_eq "stack exits 0" 0 "$(last_rc)"
    assert_eq "the manifest holds the head alone" gcp-h1 "$(mf '[.members[].id] | join(",")')"
    assert_eq "temp is where it was" "$before_temp" "$(temp_sha)"
    assert_eq "stack wrote no bead" "$writes" "$(db_writes)"
    grep -q "the head's rebase is empty" "$T/out" || fail "stack did not say the head's rebase is empty"
    assert_tidy

    # The single-bead lane's merge-state gate now decides the head.
    run_push --work gcp-h1
    assert_eq "merge-push.sh --work exits 0" 0 "$(last_rc)"
    assert_eq "the head is closed" closed "$(bead_field gcp-h1 status)"
    assert_eq "its merge_result is already_merged" already_merged "$(bead_meta gcp-h1 merge_result)"
    assert_eq "it records how that was established" rebase_patch_id "$(bead_meta gcp-h1 already_merged_via)"
    end_case
}

case_stack_degrade() {
    new_case stack-degrade
    init_rig
    add_branch gcp-d1 f1.txt "member one"
    add_branch gcp-d2 f2.txt "member two"
    add_branch gcp-d3 f3.txt "member three"
    move_target elsewhere.txt
    finish_rig gcp-d1
    write_bead gcp-d1 1 2026-10-02T01:00:00Z
    write_bead gcp-d2 1 2026-10-02T02:00:00Z
    write_bead gcp-d3 1 2026-10-02T03:00:00Z
    FAIL_SHOW=gcp-d3

    run_batch stack --head gcp-d1 --members gcp-d1,gcp-d2,gcp-d3
    assert_eq "stack exits 0 on an internal error" 0 "$(last_rc)"
    assert_eq "the manifest holds the head alone" gcp-d1 "$(mf '[.members[].id] | join(" ")')"
    assert_eq "temp is reset to the head tip recorded at entry" "$ENTRY_SHA" "$(temp_sha)"
    git -C "$REFINERY" cat-file -e "temp:f2.txt" 2>/dev/null && fail "member 2 is still stacked after the degrade"
    grep -q 'WARN' "$T/err" || fail "stack did not print WARN"
    assert_eq "the degraded manifest names the head's tip" "$ENTRY_SHA" "$(mf '.members[0].tip')"
    assert_eq "the working tree is clean" "" "$(git -C "$REFINERY" status --porcelain)"
    assert_eq "stack wrote no bead" 0 "$(db_writes)"
    assert_tidy
    end_case
}

case_invariants() {
    new_case invariants
    init_rig
    add_branch gcp-i1 f1.txt "member one"
    finish_rig gcp-i1
    local count
    count=$(grep -c '{{' "$SCRIPT")
    assert_eq "the script carries no template placeholder" 0 "$count"
    grep -q 'drain-ack' "$SCRIPT" && fail "the script contains drain-ack: patrol-loop control is the step's, not the script's"
    grep -Eq 'bd +mol +wisp' "$SCRIPT" && fail "the script pours a wisp: patrol-loop control is the step's"
    grep -Eq 'bd +mol +burn' "$SCRIPT" && fail "the script burns a wisp: patrol-loop control is the step's"

    run_batch
    assert_eq "no subcommand exits 1" 1 "$(last_rc)"
    grep -q '^usage: merge-batch.sh' "$T/err" || fail "no subcommand printed no usage line"
    run_batch frobnicate
    assert_eq "an unknown subcommand exits 1" 1 "$(last_rc)"
    grep -q '^usage: merge-batch.sh' "$T/err" || fail "an unknown subcommand printed no usage line"
    assert_eq "an unknown subcommand prints nothing on stdout" "" "$(cat "$T/out")"
    run_batch select
    assert_eq "select without --head exits 1" 1 "$(last_rc)"
    run_batch select --head gcp-i1 --max zero
    assert_eq "select with a non-integer --max exits 1" 1 "$(last_rc)"
    run_batch stack
    assert_eq "stack without --head exits 1" 1 "$(last_rc)"
    assert_eq "usage errors touch no bead" 0 "$(db_writes)"

    # Approval ON: stack leaves a batch of one however many members it was given.
    write_bead gcp-i1 1 2026-10-02T01:00:00Z
    write_config require_merge_approval=true
    run_batch stack --head gcp-i1 --members gcp-i1,gcp-i2
    assert_eq "stack with approval on exits 0" 0 "$(last_rc)"
    assert_eq "stack with approval on holds the head alone" gcp-i1 "$(mf '[.members[].id] | join(" ")')"

    # A head that would not ride the direct lane is a batch of one, too.
    write_config
    set_meta gcp-i1 merge_strategy mr
    run_batch stack --head gcp-i1 --members gcp-i1,gcp-i2
    assert_eq "stack with an mr head exits 0" 0 "$(last_rc)"
    assert_eq "stack with an mr head holds the head alone" gcp-i1 "$(mf '[.members[].id] | join(" ")')"
    end_case
}

# --- land ---------------------------------------------------------------------

# stack_three [commits-of-member-2] — the batch every land case starts from:
# three beads on disjoint files (gcp-h1 the head, gcp-h2, gcp-h3), `temp` rebased
# onto the target, and the batch stacked by the suite's own `stack`. Leaves the
# manifest saved at $T/manifest.before, since land removes the real one.
stack_three() {
    init_rig
    add_branch gcp-h1 f1.txt "head"
    add_branch gcp-h2 f2.txt "member two" "${1:-1}"
    add_branch gcp-h3 f3.txt "member three"
    finish_rig gcp-h1
    write_bead gcp-h1 1 2026-10-02T01:00:00Z
    write_bead gcp-h2 1 2026-10-02T02:00:00Z
    write_bead gcp-h3 1 2026-10-02T03:00:00Z
    run_batch stack --head gcp-h1 --members gcp-h1,gcp-h2,gcp-h3
    [ "$(last_rc)" = 0 ] && [ "$(mf '.members | length')" = 3 ] ||
        fail "harness bug: stack did not build a batch of three"
    cp -f "$(manifest_path)" "$T/manifest.before"
}

# saved <jq filter> — read the manifest as stack wrote it, before land.
saved() { jq -r "$1" "$T/manifest.before"; }

origin_tip() { git --git-dir="$ORIGIN" rev-parse refs/heads/integration; }
last_line() { tail -n 1 "$T/out"; }
branch_on_origin() { git --git-dir="$ORIGIN" rev-parse --verify -q "refs/heads/polecat/$1" 2>/dev/null; }

# assert_no_temp <what> — land dropped `temp`. Upstream #374 made the rebase
# step's `git checkout -b temp` exit-checked, so a temp that outlives land makes
# every later patrol STOP at the rebase step and drain.
assert_no_temp() {
    git -C "$REFINERY" rev-parse --verify --quiet refs/heads/temp >/dev/null 2>&1 &&
        fail "$1: refs/heads/temp was left behind; the next patrol's rebase step STOPs on it"
    return 0
}

# snapshot_beads — the three beads' bytes, to prove a land run wrote none.
snapshot_beads() { echo "$(bead_sum gcp-h1)|$(bead_sum gcp-h2)|$(bead_sum gcp-h3)"; }

# assert_landed_member <index 0-2> <offset> — member <index+1> closed on its own
# commit, <offset> commits behind the landed tip.
assert_landed_member() {
    local idx="$1" off="$2" id sha want_short
    id="gcp-h$((idx + 1))"
    sha=$(bead_meta "$id" merged_sha)
    assert_eq "$id is closed" closed "$(bead_field "$id" status)"
    assert_eq "$id's merged_sha is its own commit, $off behind the landed tip" \
        "$(git -C "$REFINERY" rev-parse "origin/integration~$off")" "$sha"
    assert_eq "$id's merged_sha carries the patch stack recorded for it" \
        "$(saved ".members[$idx].patch_id")" "$(patch_id_of "$sha")"
    assert_eq "$id records the target" integration "$(bead_meta "$id" merged_target)"
    assert_eq "$id records merge_result" merged "$(bead_meta "$id" merge_result)"
    assert_eq "$id records its position" "$((idx + 1))" "$(bead_meta "$id" merge_batch_pos)"
    assert_eq "$id records the batch size" 3 "$(bead_meta "$id" merge_batch_size)"
    assert_eq "$id records the batch" \
        "gcp-h1@$(git -C "$REFINERY" rev-parse --short "$(saved '.members[2].tip')")" "$(bead_meta "$id" merge_batch)"
    want_short=$(git -C "$REFINERY" rev-parse --short "$sha")
    case "$(bead_field "$id" close_reason)" in
    "Merged to integration at $want_short"*) ;;
    *) fail "$id: unexpected close reason: $(bead_field "$id" close_reason)" ;;
    esac
}

case_land_green() {
    new_case land-green
    stack_three 2
    set_meta gcp-h3 rejection_reason "an earlier attempt was rejected"
    local tip i
    tip=$(saved '.members[2].tip')

    run_batch land --head gcp-h1
    assert_eq "land exits 0" 0 "$(last_rc)"
    assert_eq "origin/integration is the manifest's last tip" "$tip" "$(origin_tip)"
    assert_landed_member 0 3
    assert_landed_member 1 1
    assert_landed_member 2 0
    assert_eq "the three merged_sha values are distinct" 3 \
        "$(for i in 1 2 3; do bead_meta "gcp-h$i" merged_sha; done | sort -u | wc -l | tr -d ' ')"
    [ "$(bead_meta gcp-h1 merged_sha)" != "$tip" ] || fail "member 1 was given the batch tip as its merged_sha"
    assert_eq "member 3's rejection_reason is unset" "<unset>" "$(bead_meta gcp-h3 rejection_reason)"
    for i in 1 2 3; do
        [ -z "$(branch_on_origin "gcp-h$i")" ] || fail "origin/polecat/gcp-h$i was not deleted"
    done
    git -C "$REFINERY" rev-parse --verify -q refs/heads/temp >/dev/null 2>&1 && fail "the temp branch was left behind"
    [ ! -f "$(manifest_path)" ] || fail "the manifest was left behind"
    assert_eq "the last stdout line is the RESULT line" \
        "merge-batch: RESULT 0 landed=gcp-h1,gcp-h2,gcp-h3 left-open=" "$(last_line)"
    end_case
}

case_land_target_moved_once() {
    new_case land-target-moved-once
    stack_three
    move_target elsewhere.txt
    local i sha
    run_batch land --head gcp-h1
    assert_eq "land exits 0 after one re-rebase" 0 "$(last_rc)"
    for i in 0 1 2; do
        sha=$(bead_meta "gcp-h$((i + 1))" merged_sha)
        assert_eq "member $((i + 1))'s merged_sha has its stacked patch-id" \
            "$(saved ".members[$i].patch_id")" "$(patch_id_of "$sha")"
        [ "$sha" != "$(saved ".members[$i].tip")" ] ||
            fail "member $((i + 1))'s merged_sha is its pre-move tip: the landed stack was not re-read"
        git -C "$REFINERY" merge-base --is-ancestor "$sha" origin/integration ||
            fail "member $((i + 1))'s merged_sha is not on origin/integration"
        assert_eq "member $((i + 1)) is closed" closed "$(bead_field "gcp-h$((i + 1))" status)"
    done
    git -C "$REFINERY" cat-file -e "origin/integration:elsewhere.txt" 2>/dev/null ||
        fail "origin/integration lost the commit that moved in"
    end_case
}

case_land_retries_exhausted() {
    new_case land-retries-exhausted
    stack_three
    # One racing commit per push attempt, built BEFORE the hook is armed, each a
    # fast-forward of the last. The hook moves integration to the next one and
    # refuses the push (test_refinery_merge_push.sh's racing-target shape).
    local racer="$T/racer" n
    git_q clone "$ORIGIN" "$racer"
    : >"$T/chain"
    for n in 1 2 3; do
        echo "bump $n" >>"$racer/overlay.txt"
        git_q -C "$racer" add overlay.txt
        git_q -C "$racer" commit -m "chore: racing bump $n"
        git -C "$racer" rev-parse HEAD >>"$T/chain"
    done
    git_q -C "$racer" push origin HEAD:refs/heads/racing
    cat >"$ORIGIN/hooks/pre-receive" <<HOOK
#!/bin/sh
unset GIT_QUARANTINE_PATH GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES
n=\$(wc -l <"$T/push-attempts" 2>/dev/null || echo 0)
n=\$((n + 1))
echo x >>"$T/push-attempts"
racing=\$(sed -n "\${n}p" "$T/chain")
if [ -n "\$racing" ]; then
  git --git-dir="$ORIGIN" update-ref refs/heads/integration "\$racing"
fi
echo "push refused by the test (race \$n)" >&2
exit 1
HOOK
    chmod +x "$ORIGIN/hooks/pre-receive"
    local before writes
    before=$(snapshot_beads)
    writes=$(db_writes)

    run_batch land --head gcp-h1
    assert_eq "land exits 6 when the target moved under every attempt" 6 "$(last_rc)"
    assert_eq "the last stdout line is the RESULT line" "merge-batch: RESULT 6 landed= left-open=" "$(last_line)"
    assert_eq "no member bead was written" "$before" "$(snapshot_beads)"
    assert_eq "no bead call was made" "$writes" "$(db_writes)"
    [ "$(wc -l <"$T/push-attempts" | tr -d ' ')" -gt 1 ] ||
        fail "harness bug: the hook saw fewer than two pushes, so nothing raced"
    assert_no_temp "land status 6"
    end_case
}

case_land_refused() {
    new_case land-refused
    stack_three
    cat >"$ORIGIN/hooks/pre-receive" <<'HOOK'
#!/bin/sh
echo "push refused by the test" >&2
exit 1
HOOK
    chmod +x "$ORIGIN/hooks/pre-receive"
    local before writes tip
    before=$(snapshot_beads)
    writes=$(db_writes)
    tip=$(origin_tip)

    run_batch land --head gcp-h1
    assert_eq "land exits 7 when the remote refuses and the target stood still" 7 "$(last_rc)"
    assert_eq "the last stdout line is the RESULT line" "merge-batch: RESULT 7 landed= left-open=" "$(last_line)"
    assert_eq "origin/integration is unchanged" "$tip" "$(origin_tip)"
    assert_eq "no member bead was written" "$before" "$(snapshot_beads)"
    assert_eq "no bead call was made" "$writes" "$(db_writes)"
    assert_no_temp "land status 7"
    end_case
}

case_land_left_open_recovery() {
    new_case land-left-open-recovery
    stack_three
    FAIL_CLOSE=gcp-h2
    local tip m2_assignee
    tip=$(saved '.members[2].tip')
    m2_assignee=$(bead_field gcp-h2 assignee)

    run_batch land --head gcp-h1
    assert_eq "land exits 2 with a member left open" 2 "$(last_rc)"
    assert_eq "origin/integration is the manifest's last tip" "$tip" "$(origin_tip)"
    assert_landed_member 0 2
    assert_landed_member 2 0
    assert_eq "member 2 is not closed: it keeps the in-flight status" in_progress "$(bead_field gcp-h2 status)"
    assert_eq "member 2's assignee is unchanged" "$m2_assignee" "$(bead_field gcp-h2 assignee)"
    [ -n "$(branch_on_origin gcp-h2)" ] || fail "origin/polecat/gcp-h2 was deleted though member 2 is open"
    assert_eq "the last stdout line is the RESULT line" \
        "merge-batch: RESULT 2 landed=gcp-h1,gcp-h3 left-open=gcp-h2" "$(last_line)"
    assert_no_temp "land status 2 with a member left open"

    # The recovery the single-bead lane gives it: the rebase step rebuilds temp
    # from the branch (every commit is already upstream, so it collapses to
    # nothing), and the merge-state gate closes the bead as already merged.
    FAIL_CLOSE=""
    git_q -C "$REFINERY" fetch origin "+refs/heads/polecat/gcp-h2:refs/remotes/origin/polecat/gcp-h2"
    git_q -C "$REFINERY" checkout -B temp origin/polecat/gcp-h2
    git_q -C "$REFINERY" rebase origin/integration ||
        git_q -C "$REFINERY" rebase --abort
    run_push --work gcp-h2
    assert_eq "merge-push.sh --work exits 0 on the left-open member" 0 "$(last_rc)"
    assert_eq "member 2 is closed" closed "$(bead_field gcp-h2 status)"
    assert_eq "member 2 is already_merged" already_merged "$(bead_meta gcp-h2 merge_result)"
    assert_eq "it records how that was established" rebase_patch_id "$(bead_meta gcp-h2 already_merged_via)"
    assert_eq "its merged_sha carries member 2's stacked patch" \
        "$(saved '.members[1].patch_id')" "$(patch_id_of "$(bead_meta gcp-h2 merged_sha)")"
    end_case
}

case_land_dropped_commit() {
    new_case land-dropped-commit
    stack_three
    # Member 3's patch reaches the target by another route, so land's re-rebase
    # drops member 3's commit and every offset behind the landed tip shifts.
    land_by_patch_id gcp-h3
    local before_h1 before_h2 before_h3 tip i sha
    before_h1=$(bead_sum gcp-h1)
    before_h2=$(bead_sum gcp-h2)
    before_h3=$(bead_sum gcp-h3)
    tip=$(origin_tip)

    run_batch land --head gcp-h1
    assert_eq "land exits 2 when the mapping refuses a member" 2 "$(last_rc)"
    [ "$(origin_tip)" != "$tip" ] || fail "origin/integration did not advance"
    for i in 0 1 2; do
        sha=$(bead_meta "gcp-h$((i + 1))" merged_sha)
        [ "$sha" = "<unset>" ] && continue
        assert_eq "gcp-h$((i + 1))'s merged_sha has its own stacked patch-id" \
            "$(saved ".members[$i].patch_id")" "$(patch_id_of "$sha")"
    done
    assert_eq "member 1 stays untouched" "$before_h1" "$(bead_sum gcp-h1)"
    assert_eq "member 2 stays untouched" "$before_h2" "$(bead_sum gcp-h2)"
    assert_eq "member 3 stays untouched" "$before_h3" "$(bead_sum gcp-h3)"
    assert_eq "the last stdout line names every refused member" \
        "merge-batch: RESULT 2 landed= left-open=gcp-h1,gcp-h2,gcp-h3" "$(last_line)"
    for i in 1 2 3; do
        [ -n "$(branch_on_origin "gcp-h$i")" ] || fail "origin/polecat/gcp-h$i was deleted though the member is open"
    done
    assert_no_temp "land status 2 with every member refused"
    end_case
}

case_land_rerebase_conflict() {
    new_case land-rerebase-conflict
    stack_three
    # Another bead lands a different member 2 file: land's re-rebase onto the
    # moved target cannot apply member 2's commit.
    git_q -C "$SEED" pull origin integration
    echo "someone else's f2" >"$SEED/f2.txt"
    git_q -C "$SEED" add f2.txt
    git_q -C "$SEED" commit -m "feat: a concurrent bead writes f2.txt"
    git_q -C "$SEED" push origin HEAD:integration
    local before writes tip
    before=$(snapshot_beads)
    writes=$(db_writes)
    tip=$(origin_tip)

    run_batch land --head gcp-h1
    assert_eq "land exits 3 when the re-rebase conflicts" 3 "$(last_rc)"
    assert_eq "the last stdout line is the RESULT line" "merge-batch: RESULT 3 landed= left-open=" "$(last_line)"
    assert_eq "origin/integration is unchanged" "$tip" "$(origin_tip)"
    assert_eq "no member bead was written" "$before" "$(snapshot_beads)"
    assert_eq "no bead call was made" "$writes" "$(db_writes)"
    [ ! -d "$(git -C "$REFINERY" rev-parse --absolute-git-dir)/rebase-merge" ] ||
        fail "a rebase was left in flight"
    assert_no_temp "land status 3"
    end_case
}

case_land_noop() {
    new_case land-noop
    stack_three
    # The stacked tip is already the target's: the ff-merge is a no-op.
    git_q -C "$REFINERY" push origin temp:integration
    local before writes
    before=$(snapshot_beads)
    writes=$(db_writes)

    run_batch land --head gcp-h1
    assert_eq "land exits 5 when the target already holds the batch" 5 "$(last_rc)"
    assert_eq "the last stdout line is the RESULT line" "merge-batch: RESULT 5 landed= left-open=" "$(last_line)"
    assert_eq "no member bead was written" "$before" "$(snapshot_beads)"
    assert_eq "no bead call was made" "$writes" "$(db_writes)"
    assert_no_temp "land status 5"
    end_case
}

case_land_guards() {
    new_case land-guards
    stack_three
    local before tip writes
    before=$(snapshot_beads)
    tip=$(origin_tip)
    writes=$(db_writes)

    # guard_holds <what> <want-status> — the guard that just ran wrote nothing.
    # A usage, config or manifest error (1) touches nothing, temp included. A
    # stop after the manifest checks passed (2) drops temp like every other land
    # stop; it is put back on the stacked tip for the guards that follow.
    guard_holds() {
        assert_eq "$1: exit status" "$2" "$(last_rc)"
        assert_eq "$1: the last stdout line is the RESULT line" \
            "merge-batch: RESULT $2 landed= left-open=" "$(last_line)"
        assert_eq "$1: origin/integration is unchanged" "$tip" "$(origin_tip)"
        assert_eq "$1: no bead changed" "$before" "$(snapshot_beads)"
        assert_eq "$1: no bead call was made" "$writes" "$(db_writes)"
        if [ "$2" = 1 ]; then
            assert_eq "$1: temp is where stack left it" "$(saved '.members[2].tip')" "$(temp_sha)"
        else
            assert_no_temp "$1"
            git_q -C "$REFINERY" checkout -B temp "$(saved '.members[2].tip')"
        fi
    }

    run_batch land
    guard_holds "land with no --head" 1
    grep -q '^usage: merge-batch.sh' "$T/err" || fail "land with no --head printed no usage line"

    run_batch land --head gcp-h1 --frobnicate
    guard_holds "land with an unknown flag" 1
    grep -q '^usage: merge-batch.sh' "$T/err" || fail "land with an unknown flag printed no usage line"

    run_batch land --head gcp-other
    guard_holds "a manifest for another head" 1

    jq '.members |= .[:1]' "$T/manifest.before" >"$(manifest_path)"
    run_batch land --head gcp-h1
    guard_holds "a 1-member manifest" 1

    printf 'not json' >"$(manifest_path)"
    run_batch land --head gcp-h1
    guard_holds "an unparseable manifest" 1

    jq '.members[0].commits = 0' "$T/manifest.before" >"$(manifest_path)"
    run_batch land --head gcp-h1
    guard_holds "a member with no commits" 1

    cp -f "$T/manifest.before" "$(manifest_path)"
    write_config require_merge_approval=true
    run_batch land --head gcp-h1
    guard_holds "approval required" 2

    write_config
    EXTRA_ENV=(MERGE_PUSH_CONFIG_JSON="$T/missing-config.json")
    run_batch land --head gcp-h1
    guard_holds "an unreadable config" 2
    EXTRA_ENV=()

    git_q -C "$REFINERY" reset --hard HEAD~1
    run_batch land --head gcp-h1
    guard_holds "temp one commit behind the manifest's last tip" 2
    git_q -C "$REFINERY" reset --hard "$(saved '.members[2].tip')"

    rm -f "$(manifest_path)"
    run_batch land --head gcp-h1
    guard_holds "no manifest" 1
    end_case
}

# serial_stamp_of <id> — what origin holds for the member's branch.
serial_stamp_of() { git --git-dir="$ORIGIN" rev-parse "refs/heads/polecat/$1"; }

# assert_serial_stamped <id> — the member carries the stamp and nothing else of
# serial's: no rejection_reason, and one note naming the batch's last tip.
assert_serial_stamped() {
    assert_eq "$1 carries merge_batch_serial" "$(serial_stamp_of "$1")" "$(bead_meta "$1" merge_batch_serial)"
    assert_eq "$1 has no rejection_reason" "<unset>" "$(bead_meta "$1" rejection_reason)"
    [ -f "$BEADS/$1.notes" ] || { fail "$1 has no note"; return; }
    assert_eq "$1 holds exactly one note" 1 "$(grep -c . "$BEADS/$1.notes")"
    grep -q "batch red at $(git -C "$REFINERY" rev-parse --short "$(saved '.members[2].tip')")" "$BEADS/$1.notes" ||
        fail "$1's note does not name the batch's last tip"
}

case_serial_stamps() {
    new_case serial-stamps
    stack_three
    local i writes status_before assignee_before
    writes=$(db_writes)
    status_before=$(bead_field gcp-h1 status)$(bead_field gcp-h2 status)$(bead_field gcp-h3 status)
    assignee_before=$(bead_field gcp-h1 assignee)$(bead_field gcp-h2 assignee)$(bead_field gcp-h3 assignee)

    run_batch serial --head gcp-h1
    assert_eq "serial exits 0" 0 "$(last_rc)"
    for i in 1 2 3; do assert_serial_stamped "gcp-h$i"; done
    assert_eq "status is unchanged" "$status_before" \
        "$(bead_field gcp-h1 status)$(bead_field gcp-h2 status)$(bead_field gcp-h3 status)"
    assert_eq "assignee is unchanged" "$assignee_before" \
        "$(bead_field gcp-h1 assignee)$(bead_field gcp-h2 assignee)$(bead_field gcp-h3 assignee)"
    assert_eq "serial made exactly three bead writes" $((writes + 3)) "$(db_writes)"
    grep -q '^gc bd close ' "$T/gc.log" && fail "serial closed a bead"
    [ -z "$(temp_sha)" ] || fail "temp was left behind"
    [ ! -e "$(manifest_path)" ] || fail "the manifest was left behind"
    assert_eq "the last stdout line is the RESULT line" \
        "merge-batch: RESULT 0 serial=gcp-h1,gcp-h2,gcp-h3 failed=" "$(last_line)"

    # The stamps suppress batching end to end.
    assert_eq "select now keeps the head alone" gcp-h1 "$(selected --head gcp-h1 --max 3)"
    end_case
}

case_serial_stamp_failure() {
    new_case serial-stamp-failure
    stack_three
    local before_h2
    before_h2=$(bead_sum gcp-h2)
    FAIL_UPDATE=gcp-h2

    run_batch serial --head gcp-h1
    assert_eq "serial exits 2" 2 "$(last_rc)"
    assert_serial_stamped gcp-h1
    assert_serial_stamped gcp-h3
    assert_eq "the failed member is untouched" "$before_h2" "$(bead_sum gcp-h2)"
    [ -z "$(temp_sha)" ] || fail "temp was left behind"
    [ ! -e "$(manifest_path)" ] || fail "the manifest was left behind"
    assert_eq "the last stdout line names the failed member" \
        "merge-batch: RESULT 2 serial=gcp-h1,gcp-h3 failed=gcp-h2" "$(last_line)"
    end_case
}

case_serial_guards() {
    new_case serial-guards
    stack_three
    local before tip writes
    before=$(snapshot_beads)
    tip=$(saved '.members[2].tip')
    writes=$(db_writes)

    # guard_holds <what> — the guard that just ran touched nothing.
    guard_holds() {
        assert_eq "$1: exit status" 1 "$(last_rc)"
        assert_eq "$1: the last stdout line is the RESULT line" \
            "merge-batch: RESULT 1 serial= failed=" "$(last_line)"
        assert_eq "$1: no bead changed" "$before" "$(snapshot_beads)"
        assert_eq "$1: no bead call was made" "$writes" "$(db_writes)"
        assert_eq "$1: no note was written" 0 "$(find "$BEADS" -name '*.notes' | wc -l | tr -d ' ')"
        assert_eq "$1: temp is where stack left it" "$tip" "$(temp_sha)"
    }

    run_batch serial
    guard_holds "serial with no --head"
    grep -q '^usage: merge-batch.sh' "$T/err" || fail "serial with no --head printed no usage line"

    run_batch serial --head gcp-h1 --frobnicate
    guard_holds "serial with an unknown flag"

    run_batch serial --head gcp-other
    guard_holds "a manifest for another head"

    jq '.members |= .[:1]' "$T/manifest.before" >"$(manifest_path)"
    run_batch serial --head gcp-h1
    guard_holds "a 1-member manifest"

    printf 'not json' >"$(manifest_path)"
    run_batch serial --head gcp-h1
    guard_holds "an unparseable manifest"

    rm -f "$(manifest_path)"
    run_batch serial --head gcp-h1
    guard_holds "no manifest"
    end_case
}

# The two functions the batch's eligibility is built on live in merge-push.sh, and
# main calls them, so the lane and the batch cannot decide differently.
case_extraction() {
    new_case extraction
    local declared
    declared=$(MERGE_PUSH_SOURCE_ONLY=1 "$BASH" -c ". '$PUSH_SCRIPT'; declare -F resolve_merge_strategy resolve_approval_required" 2>&1)
    assert_eq "merge-push.sh defines both functions" \
        "resolve_merge_strategy
resolve_approval_required" "$declared"
    local main_body
    main_body=$(sed -n '/^main() {/,/^}/p' "$PUSH_SCRIPT")
    # shellcheck disable=SC2016
    printf '%s\n' "$main_body" | grep -q 'resolve_merge_strategy "\$WORK"' || fail "main does not call resolve_merge_strategy"
    printf '%s\n' "$main_body" | grep -q '^resolve_approval_required' || fail "main does not call resolve_approval_required"
    end_case
}

# --- run ----------------------------------------------------------------------

[ -f "$SCRIPT" ] || { echo "FAIL: no script at $SCRIPT" >&2; exit 1; }
[ -f "$PUSH_SCRIPT" ] || { echo "FAIL: no merge-push.sh beside $SCRIPT" >&2; exit 1; }

case_select_order
case_select_truncation
case_select_approval
case_stack_clean
case_stack_conflict
case_stack_already_landed
case_stack_collapsed_head
case_stack_degrade
case_invariants
case_extraction
case_land_green
case_land_target_moved_once
case_land_retries_exhausted
case_land_refused
case_land_left_open_recovery
case_land_dropped_commit
case_land_rerebase_conflict
case_land_noop
case_land_guards
case_serial_stamps
case_serial_stamp_failure
case_serial_guards

if [ "$PASS_CASES" -ne "$EXPECTED_CASES" ]; then
    echo "FAIL: $PASS_CASES of $EXPECTED_CASES cases ran" >&2
    exit 1
fi
if [ "$FAILURES" -ne 0 ]; then
    echo "FAIL: $FAILURES assertion(s) failed across $PASS_CASES cases" >&2
    exit 1
fi
echo "OK: $PASS_CASES cases passed"
