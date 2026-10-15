#!/usr/bin/env bash
# Tests for gastown/assets/scripts/polecat-claim.sh, the polecat's first action.
#
# The claim used to be a heredoc in the polecat prompt that every session
# retyped (gcp-zzb0). It now ships as a script, and these tests run the real
# script against a stubbed `gc` and a stubbed `sleep`. Each test_case_<name>
# builds one claim setup and asserts the outcome token, the whole of stdout and
# the exact `gc`/`sleep` call log, so a changed retry count, backoff, restamp
# target or nudge target fails here. The setups mirror the identity harness the
# script was proven against when the heredoc moved: the script and the old
# heredoc produced the same stdout, exit code and call log for each of them.
#
# No test depends on wall-clock time: `sleep` is a stub that logs its argument
# and returns at once, and stdin is /dev/null.
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
CLAIM_SH="$ROOT/gastown/assets/scripts/polecat-claim.sh"

TMPROOT=$(mktemp -d)
trap 'rm -rf "$TMPROOT"' EXIT

# fail names the test that called it, so a red run says which case broke.
fail() {
    local fn name=""
    for fn in "${FUNCNAME[@]}"; do
        case "$fn" in test_*) name=$fn; break ;; esac
    done
    echo "FAIL${name:+ $name}: $*" >&2
    exit 1
}

ME=gastown__polecat-gc-psfm
SHOW_OK='[{"id":"w-1","status":"in_progress","assignee":"'$ME'","metadata":{"gc.step_ref":"mol-polecat-work.implement","gc.root_bead_id":"w-root"}}]'
# A mol-polecat-work ROOT carries gc.kind=workflow and gc.step_id but neither
# gc.step_ref nor gc.root_bead_id (gcp-x8jue), so it is its own molecule.
SHOW_ROOT='[{"id":"w-1","status":"in_progress","assignee":"'$ME'","metadata":{"gc.kind":"workflow","gc.step_id":"mol-polecat-work"}}]'
SESS='{"sessions":[{"id":"gc-8a4d","name":"winnow/gastown.furiosa","session_name":"gastown__polecat-gc-8a4d","alias":"winnow/gastown.furiosa","template":"winnow/gastown.polecat","closed":false},{"id":"gc-ref1","session_name":"winnow--gastown__refinery","alias":"winnow/gastown.refinery","name":"winnow/gastown.refinery","template":"winnow/gastown.refinery","closed":false},{"id":"gc-crw1","session_name":"winnow--specialists__thomas","alias":"winnow/specialists.thomas","name":"winnow/specialists.thomas","template":"winnow/specialists.spec","closed":false},{"id":"gc-nt","session_name":"nt-sess","alias":"winnow/x.nt","name":"winnow/x.nt","closed":false},{"id":"gc-dead","session_name":"dead-sess","alias":"winnow/gastown.dead","name":"winnow/gastown.dead","template":"winnow/gastown.polecat","closed":true}]}'

# write_stubs answers only the reads and writes the claim makes and journals
# every call to $FX/calls.log, so a test can assert on what the claim did, not
# just on what it printed. Each read serves $FX/<name>, or $FX/<name>.<N> for the
# Nth call, with $FX/<name>[.<N>].code as the exit status. gc bd update serves
# only an exit status, from $FX/update.<N>.code.
write_stubs() {
    local bin="$1"
    mkdir -p "$bin"
    cat >"$bin/gc" <<'SH'
#!/usr/bin/env bash
printf 'gc %s\n' "$*" >>"$FX/calls.log"
next() { # <name>: serve name.N for the Nth call, falling back to name
    local n c
    n=$(($(cat "$FX/$1.n" 2>/dev/null || echo 0) + 1))
    echo "$n" >"$FX/$1.n"
    if [ -e "$FX/$1.$n" ]; then cat "$FX/$1.$n"; else cat "$FX/$1" 2>/dev/null; fi
    c="$FX/$1.$n.code"
    [ -e "$c" ] || c="$FX/$1.code"
    return "$(cat "$c" 2>/dev/null || echo 0)"
}
case "$1:$2" in
    hook:--claim) next hook; exit $? ;;
    bd:show) next show; exit $? ;;
    bd:list) next list; exit $? ;;
    session:list) next sessions; exit $? ;;
    bd:update)
        n=$(($(cat "$FX/update.n" 2>/dev/null || echo 0) + 1))
        echo "$n" >"$FX/update.n"
        c="$FX/update.$n.code"
        exit "$(cat "$c" 2>/dev/null || echo 0)"
        ;;
    *) exit 0 ;;
esac
SH
    cat >"$bin/sleep" <<'SH'
#!/usr/bin/env bash
printf 'sleep %s\n' "$*" >>"$FX/calls.log"
SH
    chmod +x "$bin/gc" "$bin/sleep"
}

new_case() {
    local dir
    dir=$(mktemp -d "$TMPROOT/case.XXXXXX")
    write_stubs "$dir/bin"
    : >"$dir/calls.log"
    printf '%s' "$dir"
}

# run_claim <dir> [args...] runs the script as the polecat does, under a clean
# identity (GC_RIG=winnow, BEADS_ACTOR=$ME) that a case may override through
# $dir/env. With no args it passes the binding prefix "gastown.". It must exit 0.
run_claim() {
    local dir="$1" rc=0
    shift
    [ "$#" -gt 0 ] || set -- "gastown."
    (
        export FX="$dir" PATH="$dir/bin:$PATH"
        unset BEADS_ACTOR GC_ALIAS GC_SESSION_ID GC_SESSION_NAME GC_AGENT GC_RIG
        export GC_RIG=winnow BEADS_ACTOR=$ME
        # shellcheck disable=SC1091
        [ -f "$dir/env" ] && . "$dir/env"
        bash "$CLAIM_SH" "$@" </dev/null >"$dir/out" 2>"$dir/err"
    ) || rc=$?
    [ "$rc" -eq 0 ] || fail "the claim exited $rc, but it always exits 0: $(cat "$dir/out" "$dir/err")"
}

assert_stdout() {
    local dir="$1"
    cat >"$dir/want.out"
    diff -u "$dir/want.out" "$dir/out" || fail "stdout differs from the heredoc's (diff above)"
}

assert_calls() {
    local dir="$1"
    cat >"$dir/want.calls"
    diff -u "$dir/want.calls" "$dir/calls.log" || fail "the gc/sleep call log differs from the heredoc's (diff above)"
}

# ok_hook <dir> [reason] has gc hook --claim hand back w-1 in the shape gc
# writes on success: action "work", with the reason saying which tier found it.
ok_hook() {
    printf '{"action":"work","bead_id":"w-1","reason":"%s"}' "${2-claimed}" >"$1/hook"
}

# sib <assignee> prints the molecule's step list: an older sibling held by
# <assignee> and the claimed step itself, with a LATER stamp.
sib() {
    printf '[{"id":"w-sib","assignee":"%s","updated_at":"2026-09-07T20:30:00Z"},{"id":"w-1","assignee":"%s","updated_at":"2026-09-07T20:40:00Z"}]' "$1" "$ME"
}

# rsib <assignee> prints the steps of a root's molecule: one step held by
# <assignee>. The root itself is not among them.
rsib() {
    printf '[{"id":"w-step","assignee":"%s","updated_at":"2026-09-07T20:30:00Z"}]' "$1"
}

setup_noid() { echo 'unset BEADS_ACTOR' >"$1/env"; }
setup_drain() { echo '{"action":"drain"}' >"$1/hook"; }
setup_empty() { echo '{}' >"$1/hook"; }
setup_garbage() { echo 'not json' >"$1/hook"; }
setup_nonobject() { echo '[]' >"$1/hook"; }
setup_blank() { : >"$1/hook"; }
setup_garbageflaky() {
    echo 'not json' >"$1/hook.1"
    ok_hook "$1"
    echo "$SHOW_OK" >"$1/show"
    sib "$ME" >"$1/list"
}
setup_hookfail() {
    : >"$1/hook"
    echo 1 >"$1/hook.code"
}
setup_hookflaky() {
    : >"$1/hook.1"
    echo 1 >"$1/hook.1.code"
    ok_hook "$1"
    echo "$SHOW_OK" >"$1/show"
    echo '{"sessions":[]}' >"$1/sessions"
    sib "$ME" >"$1/list"
}
setup_unread() {
    ok_hook "$1"
    echo '[]' >"$1/show"
}
setup_showflaky() {
    ok_hook "$1"
    echo '[]' >"$1/show.1"
    echo "$SHOW_OK" >"$1/show"
    sib "$ME" >"$1/list"
}
setup_mismatch() {
    ok_hook "$1"
    echo '[{"id":"w-1","status":"in_progress","assignee":"someone"}]' >"$1/show"
}
setup_unassigned() {
    ok_hook "$1"
    echo '[{"id":"w-1","status":"in_progress"}]' >"$1/show"
}
setup_notinprog() {
    ok_hook "$1"
    echo '[{"id":"w-1","status":"open","assignee":"'$ME'"}]' >"$1/show"
}
setup_nonstep() {
    ok_hook "$1"
    echo '[{"id":"w-1","status":"in_progress","assignee":"'$ME'","metadata":{"x":"y"}}]' >"$1/show"
}
setup_ready() {
    ok_hook "$1" ready_assignment
    echo "$SHOW_OK" >"$1/show"
}
setup_unknownrsn() {
    ok_hook "$1" weird
    echo "$SHOW_OK" >"$1/show"
    sib gastown__polecat-gc-8a4d >"$1/list"
    echo "$SESS" >"$1/sessions"
}
setup_existing() {
    ok_hook "$1" existing_assignment
    echo "$SHOW_OK" >"$1/show"
    sib gastown__polecat-gc-8a4d >"$1/list"
    echo "$SESS" >"$1/sessions"
}
setup_rootlive() {
    ok_hook "$1"
    echo "$SHOW_ROOT" >"$1/show"
    rsib gastown__polecat-gc-8a4d >"$1/list"
    echo "$SESS" >"$1/sessions"
}
setup_roottag() {
    ok_hook "$1"
    echo '[{"id":"w-1","status":"in_progress","assignee":"'$ME'","metadata":{"gc.kind":"workflow","gc.step_id":"mol-polecat-work","polecat_session":"gastown__polecat-gc-8a4d"}}]' >"$1/show"
    echo "$SESS" >"$1/sessions"
}
setup_rootdead() {
    ok_hook "$1"
    echo "$SHOW_ROOT" >"$1/show"
    rsib winnow/gastown.dead >"$1/list"
    echo "$SESS" >"$1/sessions"
}
setup_rootfresh() {
    ok_hook "$1"
    echo "$SHOW_ROOT" >"$1/show"
    echo '[]' >"$1/list"
}
setup_rootexisting() {
    ok_hook "$1" existing_assignment
    echo "$SHOW_ROOT" >"$1/show"
    rsib gastown__polecat-gc-8a4d >"$1/list"
    echo "$SESS" >"$1/sessions"
}
setup_noowner() {
    ok_hook "$1"
    echo "$SHOW_OK" >"$1/show"
    echo '[]' >"$1/list"
}
setup_self() {
    ok_hook "$1"
    echo "$SHOW_OK" >"$1/show"
    sib "$ME" >"$1/list"
}
setup_alias() {
    ok_hook "$1"
    echo "$SHOW_OK" >"$1/show"
    sib winnow/gastown.nux >"$1/list"
    echo 'export GC_ALIAS=winnow/gastown.nux' >"$1/env"
}
setup_livepole() {
    ok_hook "$1"
    echo "$SHOW_OK" >"$1/show"
    sib winnow/gastown.furiosa >"$1/list"
    echo "$SESS" >"$1/sessions"
}
setup_tagowner() {
    ok_hook "$1"
    echo '[{"id":"w-1","status":"in_progress","assignee":"'$ME'","metadata":{"gc.step_ref":"s","gc.root_bead_id":"w-root","polecat_session":"gastown__polecat-gc-8a4d"}}]' >"$1/show"
    echo "$SESS" >"$1/sessions"
}
setup_liveref() {
    ok_hook "$1"
    echo "$SHOW_OK" >"$1/show"
    sib winnow/gastown.refinery >"$1/list"
    echo "$SESS" >"$1/sessions"
}
setup_livecrew() {
    ok_hook "$1"
    echo "$SHOW_OK" >"$1/show"
    sib winnow/specialists.thomas >"$1/list"
    echo "$SESS" >"$1/sessions"
}
setup_notpl() {
    ok_hook "$1"
    echo "$SHOW_OK" >"$1/show"
    sib winnow/x.nt >"$1/list"
    echo "$SESS" >"$1/sessions"
}
setup_dead() {
    ok_hook "$1"
    echo "$SHOW_OK" >"$1/show"
    sib winnow/gastown.dead >"$1/list"
    echo "$SESS" >"$1/sessions"
}
setup_sessunread() {
    ok_hook "$1"
    echo "$SHOW_OK" >"$1/show"
    sib winnow/gastown.furiosa >"$1/list"
    echo 'nope' >"$1/sessions"
}
setup_restorefail() {
    setup_livepole "$1"
    echo 1 >"$1/update.1.code"
}
setup_stampfail() {
    setup_self "$1"
    echo 1 >"$1/update.1.code"
}
setup_norig() {
    setup_unread "$1"
    echo 'export GC_RIG=' >"$1/env"
}

test_missing_prefix_argument_is_rejected() {
    local dir
    dir=$(new_case)
    echo '{"action":"claimed","bead_id":"w-1"}' >"$dir/hook"
    run_claim "$dir" "gastown." "extra"
    assert_stdout "$dir" <<'EOF'
CLAIM_REJECTED polecat-claim.sh takes exactly one argument, the binding prefix (got 2)
EOF
    assert_calls "$dir" <<'EOF'
gc runtime drain-ack
EOF
    # No argument at all: the same rejection, and the claim never reaches gc.
    dir=$(new_case)
    echo '{"action":"claimed","bead_id":"w-1"}' >"$dir/hook"
    (
        export FX="$dir" PATH="$dir/bin:$PATH" BEADS_ACTOR=$ME GC_RIG=winnow
        bash "$CLAIM_SH" </dev/null >"$dir/out" 2>"$dir/err"
    ) || fail "the claim exited non-zero with no argument: $(cat "$dir/out" "$dir/err")"
    assert_stdout "$dir" <<'EOF'
CLAIM_REJECTED polecat-claim.sh takes exactly one argument, the binding prefix (got 0)
EOF
    assert_calls "$dir" <<'EOF'
gc runtime drain-ack
EOF
}

test_case_noid() {
    local dir
    dir=$(new_case)
    setup_noid "$dir"
    run_claim "$dir"
    assert_stdout "$dir" <<'EOF'
CLAIM_REJECTED no session identity in env; cannot verify ownership
EOF
    assert_calls "$dir" <<'EOF'
gc runtime drain-ack
EOF
}

test_case_drain() {
    local dir
    dir=$(new_case)
    setup_drain "$dir"
    run_claim "$dir"
    assert_stdout "$dir" <<'EOF'
NO_ROUTED_WORK
EOF
    assert_calls "$dir" <<'EOF'
gc hook --claim --json
gc runtime drain-ack
EOF
}

test_case_empty() {
    local dir
    dir=$(new_case)
    setup_empty "$dir"
    run_claim "$dir"
    assert_stdout "$dir" <<'EOF'
NO_ROUTED_WORK
EOF
    assert_calls "$dir" <<'EOF'
gc hook --claim --json
gc runtime drain-ack
EOF
}

# Stdout at exit 0 that is not one JSON object is a truncated or corrupted
# result, not "no work": it is retried like a failed call, and only a run of
# them ends in CLAIM_REJECTED.
test_case_garbage() {
    local dir
    dir=$(new_case)
    setup_garbage "$dir"
    run_claim "$dir"
    assert_stdout "$dir" <<'EOF'
CLAIM_RETRY hook call failed (code=0): malformed claim result
CLAIM_RETRY hook call failed (code=0): malformed claim result
CLAIM_RETRY hook call failed (code=0): malformed claim result
CLAIM_REJECTED gc hook --claim returned no workable bead after retries
EOF
    assert_calls "$dir" <<'EOF'
gc hook --claim --json
sleep 2
gc hook --claim --json
sleep 2
gc hook --claim --json
sleep 2
gc runtime drain-ack
EOF
}

test_case_nonobject() {
    local dir
    dir=$(new_case)
    setup_nonobject "$dir"
    run_claim "$dir"
    assert_stdout "$dir" <<'EOF'
CLAIM_RETRY hook call failed (code=0): malformed claim result
CLAIM_RETRY hook call failed (code=0): malformed claim result
CLAIM_RETRY hook call failed (code=0): malformed claim result
CLAIM_REJECTED gc hook --claim returned no workable bead after retries
EOF
    assert_calls "$dir" <<'EOF'
gc hook --claim --json
sleep 2
gc hook --claim --json
sleep 2
gc hook --claim --json
sleep 2
gc runtime drain-ack
EOF
}

test_case_garbageflaky() {
    local dir
    dir=$(new_case)
    setup_garbageflaky "$dir"
    run_claim "$dir"
    assert_stdout "$dir" <<'EOF'
CLAIM_RETRY hook call failed (code=0): malformed claim result
CLAIMED_BEAD_ID=w-1
{
  "gc.step_ref": "mol-polecat-work.implement",
  "gc.root_bead_id": "w-root"
}
EOF
    assert_calls "$dir" <<'EOF'
gc hook --claim --json
sleep 2
gc hook --claim --json
gc bd show w-1 --json
gc bd list --metadata-field gc.root_bead_id=w-root --all --limit=0 --json
gc bd update w-1 --set-metadata polecat_session=gastown__polecat-gc-psfm
EOF
}

# Empty stdout at exit 0 is a clean "no work", unlike a truncated object.
test_case_blank() {
    local dir
    dir=$(new_case)
    setup_blank "$dir"
    run_claim "$dir"
    assert_stdout "$dir" <<'EOF'
NO_ROUTED_WORK
EOF
    assert_calls "$dir" <<'EOF'
gc hook --claim --json
gc runtime drain-ack
EOF
}

test_case_hookfail() {
    local dir
    dir=$(new_case)
    setup_hookfail "$dir"
    run_claim "$dir"
    assert_stdout "$dir" <<'EOF'
CLAIM_RETRY hook call failed (code=1): malformed claim result
CLAIM_RETRY hook call failed (code=1): malformed claim result
CLAIM_RETRY hook call failed (code=1): malformed claim result
CLAIM_REJECTED gc hook --claim returned no workable bead after retries
EOF
    assert_calls "$dir" <<'EOF'
gc hook --claim --json
sleep 2
gc hook --claim --json
sleep 2
gc hook --claim --json
sleep 2
gc runtime drain-ack
EOF
}

test_case_hookflaky() {
    local dir
    dir=$(new_case)
    setup_hookflaky "$dir"
    run_claim "$dir"
    assert_stdout "$dir" <<'EOF'
CLAIM_RETRY hook call failed (code=1): malformed claim result
CLAIMED_BEAD_ID=w-1
{
  "gc.step_ref": "mol-polecat-work.implement",
  "gc.root_bead_id": "w-root"
}
EOF
    assert_calls "$dir" <<'EOF'
gc hook --claim --json
sleep 2
gc hook --claim --json
gc bd show w-1 --json
gc bd list --metadata-field gc.root_bead_id=w-root --all --limit=0 --json
gc bd update w-1 --set-metadata polecat_session=gastown__polecat-gc-psfm
EOF
}

test_case_unread() {
    local dir
    dir=$(new_case)
    setup_unread "$dir"
    run_claim "$dir"
    assert_stdout "$dir" <<'EOF'
CLAIM_RELEASED w-1 unreadable after retries; returning it to the pool
EOF
    assert_calls "$dir" <<'EOF'
gc hook --claim --json
gc bd show w-1 --json
sleep 1
gc bd show w-1 --json
sleep 2
gc bd show w-1 --json
sleep 3
gc bd show w-1 --json
sleep 4
gc bd show w-1 --json
sleep 5
gc bd update w-1 --status=open --assignee= --set-metadata gc.routed_to=winnow/gastown.polecat
gc runtime drain-ack
EOF
}

test_case_showflaky() {
    local dir
    dir=$(new_case)
    setup_showflaky "$dir"
    run_claim "$dir"
    assert_stdout "$dir" <<'EOF'
CLAIMED_BEAD_ID=w-1
{
  "gc.step_ref": "mol-polecat-work.implement",
  "gc.root_bead_id": "w-root"
}
EOF
    assert_calls "$dir" <<'EOF'
gc hook --claim --json
gc bd show w-1 --json
sleep 1
gc bd show w-1 --json
gc bd list --metadata-field gc.root_bead_id=w-root --all --limit=0 --json
gc bd update w-1 --set-metadata polecat_session=gastown__polecat-gc-psfm
EOF
}

test_case_mismatch() {
    local dir
    dir=$(new_case)
    setup_mismatch "$dir"
    run_claim "$dir"
    assert_stdout "$dir" <<'EOF'
CLAIM_REJECTED w-1 assignee=someone status=in_progress (expected gastown__polecat-gc-psfm / in_progress)
EOF
    assert_calls "$dir" <<'EOF'
gc hook --claim --json
gc bd show w-1 --json
gc runtime drain-ack
EOF
}

test_case_unassigned() {
    local dir
    dir=$(new_case)
    setup_unassigned "$dir"
    run_claim "$dir"
    assert_stdout "$dir" <<'EOF'
CLAIM_REJECTED w-1 assignee= status=in_progress (expected gastown__polecat-gc-psfm / in_progress)
EOF
    assert_calls "$dir" <<'EOF'
gc hook --claim --json
gc bd show w-1 --json
gc runtime drain-ack
EOF
}

test_case_notinprog() {
    local dir
    dir=$(new_case)
    setup_notinprog "$dir"
    run_claim "$dir"
    assert_stdout "$dir" <<'EOF'
CLAIM_REJECTED w-1 assignee=gastown__polecat-gc-psfm status=open (expected gastown__polecat-gc-psfm / in_progress)
EOF
    assert_calls "$dir" <<'EOF'
gc hook --claim --json
gc bd show w-1 --json
gc runtime drain-ack
EOF
}

test_case_nonstep() {
    local dir
    dir=$(new_case)
    setup_nonstep "$dir"
    run_claim "$dir"
    assert_stdout "$dir" <<'EOF'
CLAIMED_BEAD_ID=w-1
{
  "x": "y"
}
EOF
    assert_calls "$dir" <<'EOF'
gc hook --claim --json
gc bd show w-1 --json
gc bd update w-1 --set-metadata polecat_session=gastown__polecat-gc-psfm
EOF
}

test_case_ready() {
    local dir
    dir=$(new_case)
    setup_ready "$dir"
    run_claim "$dir"
    assert_stdout "$dir" <<'EOF'
CLAIMED_BEAD_ID=w-1
{
  "gc.step_ref": "mol-polecat-work.implement",
  "gc.root_bead_id": "w-root"
}
EOF
    assert_calls "$dir" <<'EOF'
gc hook --claim --json
gc bd show w-1 --json
gc bd update w-1 --set-metadata polecat_session=gastown__polecat-gc-psfm
EOF
}

test_case_unknownrsn() {
    local dir
    dir=$(new_case)
    # The guard skips exactly existing_assignment and ready_assignment. A reason
    # this script has never seen is checked like `claimed`, so a live polecat
    # holder declines it (gcp-4b7ji).
    setup_unknownrsn "$dir"
    run_claim "$dir"
    assert_stdout "$dir" <<'EOF'
CLAIM_DECLINED_LIVE_OWNER w-1
  molecule w-root was last held by gastown__polecat-gc-8a4d, and this session is gastown__polecat-gc-psfm.
  that owner is live (session gc-8a4d). This is a duplicate pour onto an in-flight molecule.
  Restoring the step to its owner and draining. No code, branch, or worktree touched.
EOF
    assert_calls "$dir" <<'EOF'
gc hook --claim --json
gc bd show w-1 --json
gc bd list --metadata-field gc.root_bead_id=w-root --all --limit=0 --json
gc session list --json
gc bd update w-1 --assignee=gastown__polecat-gc-8a4d --set-metadata gc.session_name=gastown__polecat-gc-8a4d --set-metadata polecat_session=gastown__polecat-gc-8a4d --set-metadata gc.session_id=gc-8a4d
gc session nudge winnow/gastown.witness DUPLICATE_POUR declined: step w-1 poured onto gastown__polecat-gc-psfm while molecule w-root was last held by gastown__polecat-gc-8a4d. Step restored to its owner.
gc runtime drain-ack
EOF
}

# existing_assignment means the bead carried our identity before the hook ran,
# and a release clears the assignee, so the guard does not read the molecule even
# though a live holder is on it.
test_case_existing() {
    local dir
    dir=$(new_case)
    setup_existing "$dir"
    run_claim "$dir"
    assert_stdout "$dir" <<'EOF'
CLAIMED_BEAD_ID=w-1
{
  "gc.step_ref": "mol-polecat-work.implement",
  "gc.root_bead_id": "w-root"
}
EOF
    assert_calls "$dir" <<'EOF'
gc hook --claim --json
gc bd show w-1 --json
gc bd update w-1 --set-metadata polecat_session=gastown__polecat-gc-psfm
EOF
}

# A molecule ROOT is its own molecule (gcp-x8jue): the pool offers one once no
# step is ready, and claiming it must not stomp a live session holding the steps.
test_case_rootlive() {
    local dir
    dir=$(new_case)
    setup_rootlive "$dir"
    run_claim "$dir"
    assert_stdout "$dir" <<'EOF'
CLAIM_DECLINED_LIVE_OWNER w-1
  molecule w-1 was last held by gastown__polecat-gc-8a4d, and this session is gastown__polecat-gc-psfm.
  that owner is live (session gc-8a4d). This is a duplicate pour onto an in-flight molecule.
  Restoring the step to its owner and draining. No code, branch, or worktree touched.
EOF
    assert_calls "$dir" <<'EOF'
gc hook --claim --json
gc bd show w-1 --json
gc bd list --metadata-field gc.root_bead_id=w-1 --all --limit=0 --json
gc session list --json
gc bd update w-1 --assignee=gastown__polecat-gc-8a4d --set-metadata gc.session_name=gastown__polecat-gc-8a4d --set-metadata polecat_session=gastown__polecat-gc-8a4d --set-metadata gc.session_id=gc-8a4d
gc session nudge winnow/gastown.witness DUPLICATE_POUR declined: step w-1 poured onto gastown__polecat-gc-psfm while molecule w-1 was last held by gastown__polecat-gc-8a4d. Step restored to its owner.
gc runtime drain-ack
EOF
}

test_case_roottag() {
    local dir
    dir=$(new_case)
    setup_roottag "$dir"
    run_claim "$dir"
    assert_stdout "$dir" <<'EOF'
CLAIM_DECLINED_LIVE_OWNER w-1
  molecule w-1 was last held by gastown__polecat-gc-8a4d, and this session is gastown__polecat-gc-psfm.
  that owner is live (session gc-8a4d). This is a duplicate pour onto an in-flight molecule.
  Restoring the step to its owner and draining. No code, branch, or worktree touched.
EOF
    assert_calls "$dir" <<'EOF'
gc hook --claim --json
gc bd show w-1 --json
gc session list --json
gc bd update w-1 --assignee=gastown__polecat-gc-8a4d --set-metadata gc.session_name=gastown__polecat-gc-8a4d --set-metadata polecat_session=gastown__polecat-gc-8a4d --set-metadata gc.session_id=gc-8a4d
gc session nudge winnow/gastown.witness DUPLICATE_POUR declined: step w-1 poured onto gastown__polecat-gc-psfm while molecule w-1 was last held by gastown__polecat-gc-8a4d. Step restored to its owner.
gc runtime drain-ack
EOF
}

test_case_rootdead() {
    local dir
    dir=$(new_case)
    setup_rootdead "$dir"
    run_claim "$dir"
    assert_stdout "$dir" <<'EOF'
WARN molecule w-1 was last held by winnow/gastown.dead, but no live session holds that identity — treating this as a resume and proceeding.
CLAIMED_BEAD_ID=w-1
{
  "gc.kind": "workflow",
  "gc.step_id": "mol-polecat-work"
}
EOF
    assert_calls "$dir" <<'EOF'
gc hook --claim --json
gc bd show w-1 --json
gc bd list --metadata-field gc.root_bead_id=w-1 --all --limit=0 --json
gc session list --json
gc bd update w-1 --set-metadata polecat_session=gastown__polecat-gc-psfm
EOF
}

test_case_rootfresh() {
    local dir
    dir=$(new_case)
    setup_rootfresh "$dir"
    run_claim "$dir"
    assert_stdout "$dir" <<'EOF'
WARN live-owner guard could not resolve an owner for this molecule; proceeding unguarded
CLAIMED_BEAD_ID=w-1
{
  "gc.kind": "workflow",
  "gc.step_id": "mol-polecat-work"
}
EOF
    assert_calls "$dir" <<'EOF'
gc hook --claim --json
gc bd show w-1 --json
gc bd list --metadata-field gc.root_bead_id=w-1 --all --limit=0 --json
gc bd update w-1 --set-metadata polecat_session=gastown__polecat-gc-psfm
EOF
}

test_case_rootexisting() {
    local dir
    dir=$(new_case)
    setup_rootexisting "$dir"
    run_claim "$dir"
    assert_stdout "$dir" <<'EOF'
CLAIMED_BEAD_ID=w-1
{
  "gc.kind": "workflow",
  "gc.step_id": "mol-polecat-work"
}
EOF
    assert_calls "$dir" <<'EOF'
gc hook --claim --json
gc bd show w-1 --json
gc bd update w-1 --set-metadata polecat_session=gastown__polecat-gc-psfm
EOF
}

test_case_noowner() {
    local dir
    dir=$(new_case)
    setup_noowner "$dir"
    run_claim "$dir"
    assert_stdout "$dir" <<'EOF'
WARN live-owner guard could not resolve an owner for this molecule; proceeding unguarded
CLAIMED_BEAD_ID=w-1
{
  "gc.step_ref": "mol-polecat-work.implement",
  "gc.root_bead_id": "w-root"
}
EOF
    assert_calls "$dir" <<'EOF'
gc hook --claim --json
gc bd show w-1 --json
gc bd list --metadata-field gc.root_bead_id=w-root --all --limit=0 --json
gc bd update w-1 --set-metadata polecat_session=gastown__polecat-gc-psfm
EOF
}

test_case_self() {
    local dir
    dir=$(new_case)
    setup_self "$dir"
    run_claim "$dir"
    assert_stdout "$dir" <<'EOF'
CLAIMED_BEAD_ID=w-1
{
  "gc.step_ref": "mol-polecat-work.implement",
  "gc.root_bead_id": "w-root"
}
EOF
    assert_calls "$dir" <<'EOF'
gc hook --claim --json
gc bd show w-1 --json
gc bd list --metadata-field gc.root_bead_id=w-root --all --limit=0 --json
gc bd update w-1 --set-metadata polecat_session=gastown__polecat-gc-psfm
EOF
}

test_case_alias() {
    local dir
    dir=$(new_case)
    setup_alias "$dir"
    run_claim "$dir"
    assert_stdout "$dir" <<'EOF'
WARN molecule w-root was last held by winnow/gastown.nux, another identity of this session (gastown__polecat-gc-psfm); it is ours.
CLAIMED_BEAD_ID=w-1
{
  "gc.step_ref": "mol-polecat-work.implement",
  "gc.root_bead_id": "w-root"
}
EOF
    assert_calls "$dir" <<'EOF'
gc hook --claim --json
gc bd show w-1 --json
gc bd list --metadata-field gc.root_bead_id=w-root --all --limit=0 --json
gc bd update w-1 --set-metadata polecat_session=gastown__polecat-gc-psfm
EOF
}

test_case_livepole() {
    local dir
    dir=$(new_case)
    setup_livepole "$dir"
    run_claim "$dir"
    assert_stdout "$dir" <<'EOF'
CLAIM_DECLINED_LIVE_OWNER w-1
  molecule w-root was last held by winnow/gastown.furiosa, and this session is gastown__polecat-gc-psfm.
  that owner is live (session gc-8a4d). This is a duplicate pour onto an in-flight molecule.
  Restoring the step to its owner and draining. No code, branch, or worktree touched.
EOF
    assert_calls "$dir" <<'EOF'
gc hook --claim --json
gc bd show w-1 --json
gc bd list --metadata-field gc.root_bead_id=w-root --all --limit=0 --json
gc session list --json
gc bd update w-1 --assignee=winnow/gastown.furiosa --set-metadata gc.session_name=gastown__polecat-gc-8a4d --set-metadata polecat_session=winnow/gastown.furiosa --set-metadata gc.session_id=gc-8a4d
gc session nudge winnow/gastown.witness DUPLICATE_POUR declined: step w-1 poured onto gastown__polecat-gc-psfm while molecule w-root was last held by winnow/gastown.furiosa. Step restored to its owner.
gc runtime drain-ack
EOF
}

test_case_tagowner() {
    local dir
    dir=$(new_case)
    setup_tagowner "$dir"
    run_claim "$dir"
    assert_stdout "$dir" <<'EOF'
CLAIM_DECLINED_LIVE_OWNER w-1
  molecule w-root was last held by gastown__polecat-gc-8a4d, and this session is gastown__polecat-gc-psfm.
  that owner is live (session gc-8a4d). This is a duplicate pour onto an in-flight molecule.
  Restoring the step to its owner and draining. No code, branch, or worktree touched.
EOF
    assert_calls "$dir" <<'EOF'
gc hook --claim --json
gc bd show w-1 --json
gc session list --json
gc bd update w-1 --assignee=gastown__polecat-gc-8a4d --set-metadata gc.session_name=gastown__polecat-gc-8a4d --set-metadata polecat_session=gastown__polecat-gc-8a4d --set-metadata gc.session_id=gc-8a4d
gc session nudge winnow/gastown.witness DUPLICATE_POUR declined: step w-1 poured onto gastown__polecat-gc-psfm while molecule w-root was last held by gastown__polecat-gc-8a4d. Step restored to its owner.
gc runtime drain-ack
EOF
}

test_case_liveref() {
    local dir
    dir=$(new_case)
    setup_liveref "$dir"
    run_claim "$dir"
    assert_stdout "$dir" <<'EOF'
CLAIM_DECLINED_LIVE_OWNER w-1
  molecule w-root was last held by winnow/gastown.refinery, and this session is gastown__polecat-gc-psfm.
  that owner is live (session gc-ref1). This is a duplicate pour onto an in-flight molecule.
  Restoring the step to its owner and draining. No code, branch, or worktree touched.
EOF
    assert_calls "$dir" <<'EOF'
gc hook --claim --json
gc bd show w-1 --json
gc bd list --metadata-field gc.root_bead_id=w-root --all --limit=0 --json
gc session list --json
gc bd update w-1 --assignee=winnow/gastown.refinery --set-metadata gc.session_name=winnow--gastown__refinery --set-metadata polecat_session=winnow/gastown.refinery --set-metadata gc.session_id=gc-ref1
gc session nudge winnow/gastown.witness DUPLICATE_POUR declined: step w-1 poured onto gastown__polecat-gc-psfm while molecule w-root was last held by winnow/gastown.refinery. Step restored to its owner.
gc runtime drain-ack
EOF
}

test_case_livecrew() {
    local dir
    dir=$(new_case)
    setup_livecrew "$dir"
    run_claim "$dir"
    assert_stdout "$dir" <<'EOF'
WARN molecule w-root was last held by winnow/specialists.thomas, a live winnow/specialists.spec session: that is the slinger, not a worker; proceeding.
CLAIMED_BEAD_ID=w-1
{
  "gc.step_ref": "mol-polecat-work.implement",
  "gc.root_bead_id": "w-root"
}
EOF
    assert_calls "$dir" <<'EOF'
gc hook --claim --json
gc bd show w-1 --json
gc bd list --metadata-field gc.root_bead_id=w-root --all --limit=0 --json
gc session list --json
gc bd update w-1 --set-metadata polecat_session=gastown__polecat-gc-psfm
EOF
}

test_case_notpl() {
    local dir
    dir=$(new_case)
    setup_notpl "$dir"
    run_claim "$dir"
    assert_stdout "$dir" <<'EOF'
CLAIM_DECLINED_LIVE_OWNER w-1
  molecule w-root was last held by winnow/x.nt, and this session is gastown__polecat-gc-psfm.
  that owner is live (session gc-nt). This is a duplicate pour onto an in-flight molecule.
  Restoring the step to its owner and draining. No code, branch, or worktree touched.
EOF
    assert_calls "$dir" <<'EOF'
gc hook --claim --json
gc bd show w-1 --json
gc bd list --metadata-field gc.root_bead_id=w-root --all --limit=0 --json
gc session list --json
gc bd update w-1 --assignee=winnow/x.nt --set-metadata gc.session_name=nt-sess --set-metadata polecat_session=winnow/x.nt --set-metadata gc.session_id=gc-nt
gc session nudge winnow/gastown.witness DUPLICATE_POUR declined: step w-1 poured onto gastown__polecat-gc-psfm while molecule w-root was last held by winnow/x.nt. Step restored to its owner.
gc runtime drain-ack
EOF
}

test_case_dead() {
    local dir
    dir=$(new_case)
    setup_dead "$dir"
    run_claim "$dir"
    assert_stdout "$dir" <<'EOF'
WARN molecule w-root was last held by winnow/gastown.dead, but no live session holds that identity — treating this as a resume and proceeding.
CLAIMED_BEAD_ID=w-1
{
  "gc.step_ref": "mol-polecat-work.implement",
  "gc.root_bead_id": "w-root"
}
EOF
    assert_calls "$dir" <<'EOF'
gc hook --claim --json
gc bd show w-1 --json
gc bd list --metadata-field gc.root_bead_id=w-root --all --limit=0 --json
gc session list --json
gc bd update w-1 --set-metadata polecat_session=gastown__polecat-gc-psfm
EOF
}

test_case_sessunread() {
    local dir
    dir=$(new_case)
    setup_sessunread "$dir"
    run_claim "$dir"
    assert_stdout "$dir" <<'EOF'
CLAIM_DECLINED_LIVE_OWNER w-1
  molecule w-root was last held by winnow/gastown.furiosa, and this session is gastown__polecat-gc-psfm.
  session liveness was UNREADABLE after retries — declining rather than assuming the owner is gone.
  Restoring the step to its owner and draining. No code, branch, or worktree touched.
EOF
    assert_calls "$dir" <<'EOF'
gc hook --claim --json
gc bd show w-1 --json
gc bd list --metadata-field gc.root_bead_id=w-root --all --limit=0 --json
gc session list --json
sleep 1
gc session list --json
sleep 2
gc session list --json
sleep 3
gc bd update w-1 --assignee=winnow/gastown.furiosa --set-metadata gc.session_name= --set-metadata polecat_session=winnow/gastown.furiosa --set-metadata gc.session_id=
gc session nudge winnow/gastown.witness DUPLICATE_POUR declined: step w-1 poured onto gastown__polecat-gc-psfm while molecule w-root was last held by winnow/gastown.furiosa. Step restored to its owner.
gc runtime drain-ack
EOF
}

test_case_restorefail() {
    local dir
    dir=$(new_case)
    setup_restorefail "$dir"
    run_claim "$dir"
    assert_stdout "$dir" <<'EOF'
CLAIM_DECLINED_LIVE_OWNER w-1
  molecule w-root was last held by winnow/gastown.furiosa, and this session is gastown__polecat-gc-psfm.
  that owner is live (session gc-8a4d). This is a duplicate pour onto an in-flight molecule.
  Restoring the step to its owner and draining. No code, branch, or worktree touched.
WARN could not restore w-1 to winnow/gastown.furiosa — the step is left claimed by a session that will not run it; escalate to the witness
EOF
    assert_calls "$dir" <<'EOF'
gc hook --claim --json
gc bd show w-1 --json
gc bd list --metadata-field gc.root_bead_id=w-root --all --limit=0 --json
gc session list --json
gc bd update w-1 --assignee=winnow/gastown.furiosa --set-metadata gc.session_name=gastown__polecat-gc-8a4d --set-metadata polecat_session=winnow/gastown.furiosa --set-metadata gc.session_id=gc-8a4d
gc session nudge winnow/gastown.witness DUPLICATE_POUR declined: step w-1 poured onto gastown__polecat-gc-psfm while molecule w-root was last held by winnow/gastown.furiosa. Step restored to its owner.
gc runtime drain-ack
EOF
}

test_case_stampfail() {
    local dir
    dir=$(new_case)
    setup_stampfail "$dir"
    run_claim "$dir"
    assert_stdout "$dir" <<'EOF'
WARN metadata stamp failed for w-1; churn-watcher/resume lose session keying (proceeding — the claim is valid)
CLAIMED_BEAD_ID=w-1
{
  "gc.step_ref": "mol-polecat-work.implement",
  "gc.root_bead_id": "w-root"
}
EOF
    assert_calls "$dir" <<'EOF'
gc hook --claim --json
gc bd show w-1 --json
gc bd list --metadata-field gc.root_bead_id=w-root --all --limit=0 --json
gc bd update w-1 --set-metadata polecat_session=gastown__polecat-gc-psfm
EOF
}

test_case_norig() {
    local dir
    dir=$(new_case)
    setup_norig "$dir"
    run_claim "$dir"
    assert_stdout "$dir" <<'EOF'
CLAIM_RELEASED w-1 unreadable after retries; returning it to the pool
EOF
    assert_calls "$dir" <<'EOF'
gc hook --claim --json
gc bd show w-1 --json
sleep 1
gc bd show w-1 --json
sleep 2
gc bd show w-1 --json
sleep 3
gc bd show w-1 --json
sleep 4
gc bd show w-1 --json
sleep 5
gc bd update w-1 --status=open --assignee= --set-metadata gc.routed_to=gastown.polecat
gc runtime drain-ack
EOF
}

test_missing_prefix_argument_is_rejected
test_case_noid
test_case_drain
test_case_empty
test_case_garbage
test_case_nonobject
test_case_garbageflaky
test_case_blank
test_case_hookfail
test_case_hookflaky
test_case_unread
test_case_showflaky
test_case_mismatch
test_case_unassigned
test_case_notinprog
test_case_nonstep
test_case_ready
test_case_unknownrsn
test_case_existing
test_case_rootlive
test_case_roottag
test_case_rootdead
test_case_rootfresh
test_case_rootexisting
test_case_noowner
test_case_self
test_case_alias
test_case_livepole
test_case_tagowner
test_case_liveref
test_case_livecrew
test_case_notpl
test_case_dead
test_case_sessunread
test_case_restorefail
test_case_stampfail
test_case_norig
echo "polecat claim tests passed"
