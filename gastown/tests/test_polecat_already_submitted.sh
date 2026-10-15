#!/usr/bin/env bash
# Tests for gastown/assets/scripts/polecat-already-submitted.sh, the polecat's
# "did submit-and-exit already run?" check.
#
# The check was a 70-line fence the model retyped, once in the "No Idle
# Polecats" fragment and once under FINAL REMINDER (gcp-wmcj9). It ships as one
# script both call. Until then nothing ran it: the suites only grepped its text.
# These tests run the real script against a stubbed `gc` and a stubbed `sleep`,
# and assert the whole of stdout, the exit status and the exact call log, so a
# changed retry count, refinery name or evidence test fails here. The last two
# tests run the call the prompt and the fragment carry, lifted out of them.
#
# No test depends on wall-clock time: `sleep` is a stub that logs its argument
# and returns at once, and stdin is /dev/null.
#
# Every case sets its environment inside a subshell on purpose, so nothing leaks
# from one case into the next.
# shellcheck disable=SC2030,SC2031
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
SUBMITTED_SH="$ROOT/gastown/assets/scripts/polecat-already-submitted.sh"
PROMPT="$ROOT/gastown/agents/polecat/prompt.template.md"
FRAGMENT="$ROOT/gastown/template-fragments/approval-fallacy.template.md"

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
REFINERY=winnow/gastown.refinery
ONE_CHILD='{"children":[{"id":"w-1"}]}'

# write_stubs answers only the reads the check makes and journals every call to
# $FX/calls.log. Each read serves $FX/<name>, or $FX/<name>.<N> for the Nth call,
# with $FX/<name>[.<N>].code as the exit status. gc runtime drain-ack serves only
# an exit status, from $FX/drain.code.
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
    convoy:status) next convoy; exit $? ;;
    bd:show) next "show-$3"; exit $? ;;
    bd:list) next list; exit $? ;;
    runtime:drain-ack) exit "$(cat "$FX/drain.code" 2>/dev/null || echo 0)" ;;
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

# run_guard <dir> [args...] runs the script as the polecat does, under a clean
# identity (GC_RIG=winnow, BEADS_ACTOR=$ME, GC_BEAD_ID=gcp-convoy) that a case
# may override through $dir/env. With no args it passes the prefix "gastown.";
# the single arg --none passes no argument at all. The exit status lands in
# $dir/rc, the output in $dir/out.
run_guard() {
    local dir="$1" rc=0
    shift
    [ "$#" -gt 0 ] || set -- "gastown."
    [ "$*" != "--none" ] || set --
    (
        export FX="$dir" PATH="$dir/bin:$PATH"
        unset BEADS_ACTOR GC_ALIAS GC_SESSION_ID GC_SESSION_NAME GC_AGENT GC_RIG GC_BEAD_ID
        export GC_RIG=winnow BEADS_ACTOR=$ME GC_BEAD_ID=gcp-convoy
        # shellcheck disable=SC1091
        [ -f "$dir/env" ] && . "$dir/env"
        bash "$SUBMITTED_SH" "$@" </dev/null >"$dir/out" 2>"$dir/err"
    ) || rc=$?
    echo "$rc" >"$dir/rc"
}

assert_rc() { [ "$(cat "$1/rc")" = "$2" ] || fail "want exit $2, got $(cat "$1/rc"): $(cat "$1/out" "$1/err")"; }

assert_stdout() {
    local dir="$1"
    cat >"$dir/want.out"
    diff -u "$dir/want.out" "$dir/out" || fail "stdout differs (diff above)"
}

assert_calls() {
    local dir="$1"
    cat >"$dir/want.calls"
    diff -u "$dir/want.calls" "$dir/calls.log" || fail "the gc/sleep call log differs (diff above)"
}

# work <dir> <status> [assignee] writes the work bead the check reads.
work() {
    local dir="$1" status="$2" assignee="${3-}" owner=""
    [ -z "$assignee" ] || owner=',"assignee":"'$assignee'"'
    printf '[{"id":"w-1","status":"%s"%s}]' "$status" "$owner" >"$dir/show-w-1"
    printf '%s' "$ONE_CHILD" >"$dir/convoy"
}

# The three calls of a clean read: the convoy, the work bead, then the drain.
READ_CALLS='gc convoy status gcp-convoy --json
gc bd show w-1 --json'

test_a_closed_work_bead_is_already_submitted() {
    local dir
    dir=$(new_case)
    work "$dir" closed
    run_guard "$dir"
    assert_rc "$dir" 0
    assert_stdout "$dir" <<'EOF'
ALREADY_SUBMITTED w-1 status=closed assignee= — submit-and-exit already ran; draining.
EOF
    assert_calls "$dir" <<EOF
$READ_CALLS
gc runtime drain-ack
EOF
}

test_a_work_bead_held_by_the_refinery_is_already_submitted() {
    local dir
    dir=$(new_case)
    work "$dir" open "$REFINERY"
    run_guard "$dir"
    assert_rc "$dir" 0
    assert_stdout "$dir" <<EOF
ALREADY_SUBMITTED w-1 status=open assignee=$REFINERY — submit-and-exit already ran; draining.
EOF
    assert_calls "$dir" <<EOF
$READ_CALLS
gc runtime drain-ack
EOF
}

# The refinery is named from the rig and the binding prefix, the way the
# handoff writes it. An unbound pack has no prefix, so its refinery is
# winnow/refinery; the same bead is not a handoff under a bound prefix.
test_the_refinery_is_named_from_the_rig_and_the_binding_prefix() {
    local dir
    dir=$(new_case)
    work "$dir" open winnow/refinery
    run_guard "$dir" ""
    assert_rc "$dir" 0
    grep -F 'ALREADY_SUBMITTED w-1 status=open assignee=winnow/refinery' "$dir/out" >/dev/null ||
        fail "an unbound pack's refinery was not recognised: $(cat "$dir/out")"

    dir=$(new_case)
    work "$dir" open winnow/refinery
    run_guard "$dir" "gastown."
    assert_rc "$dir" 0
    [ ! -s "$dir/out" ] || fail "a bead held by another refinery name counted as handed off: $(cat "$dir/out")"
    ! grep -F 'drain-ack' "$dir/calls.log" >/dev/null || fail "drained on the wrong refinery name"

    # With no rig the target carries no rig part.
    dir=$(new_case)
    work "$dir" open gastown.refinery
    echo 'unset GC_RIG' >"$dir/env"
    run_guard "$dir"
    grep -F 'ALREADY_SUBMITTED w-1 status=open assignee=gastown.refinery' "$dir/out" >/dev/null ||
        fail "a rig-less refinery was not recognised: $(cat "$dir/out")"
}

# gcp-0pa4: a third party holding the bead (a crew seat, a reviewer, this
# session's own previous identity) is not evidence the handoff ran. Neither is
# an unassigned bead, nor an in_progress one: the polecat never claims it.
test_no_positive_evidence_goes_on_to_submit_and_exit() {
    local dir state
    for state in "in_progress winnow/specialists.thomas" "in_progress $ME" "open " "in_progress "; do
        dir=$(new_case)
        # shellcheck disable=SC2086
        work "$dir" $state
        run_guard "$dir"
        assert_rc "$dir" 0
        [ ! -s "$dir/out" ] || fail "'$state' printed something: $(cat "$dir/out")"
        assert_calls "$dir" <<EOF
$READ_CALLS
EOF
    done
}

# Unreadable is not terminal and is not proof either: three reads, a back-off
# after each, then on to submit-and-exit with nothing printed and no drain.
test_an_unreadable_state_is_retried_and_then_not_taken_as_proof() {
    local dir
    dir=$(new_case)
    run_guard "$dir"
    assert_rc "$dir" 0
    [ ! -s "$dir/out" ] || fail "an unreadable convoy printed something: $(cat "$dir/out")"
    assert_calls "$dir" <<'EOF'
gc convoy status gcp-convoy --json
sleep 1
gc convoy status gcp-convoy --json
sleep 1
gc convoy status gcp-convoy --json
sleep 1
EOF

    # A bead the read fails on is unreadable even when its text says refinery.
    dir=$(new_case)
    work "$dir" open "$REFINERY"
    echo 1 >"$dir/show-w-1.code"
    run_guard "$dir"
    assert_rc "$dir" 0
    [ ! -s "$dir/out" ] || fail "a failed read of the work bead counted as evidence: $(cat "$dir/out")"
    ! grep -F 'drain-ack' "$dir/calls.log" >/dev/null || fail "drained on a failed read"

    # Two children do not name one work bead.
    dir=$(new_case)
    work "$dir" closed
    printf '{"children":[{"id":"w-1"},{"id":"w-2"}]}' >"$dir/convoy"
    run_guard "$dir"
    [ ! -s "$dir/out" ] || fail "an ambiguous convoy printed something: $(cat "$dir/out")"
    ! grep -F 'gc bd show' "$dir/calls.log" >/dev/null || fail "read a work bead out of an ambiguous convoy"
}

test_a_read_that_recovers_on_retry_is_taken() {
    local dir
    dir=$(new_case)
    work "$dir" closed
    : >"$dir/convoy.1"
    run_guard "$dir"
    assert_rc "$dir" 0
    assert_stdout "$dir" <<'EOF'
ALREADY_SUBMITTED w-1 status=closed assignee= — submit-and-exit already ran; draining.
EOF
    assert_calls "$dir" <<EOF
gc convoy status gcp-convoy --json
sleep 1
$READ_CALLS
gc runtime drain-ack
EOF
}

# $GC_BEAD_ID is not always exported. The convoy is then recovered from the step
# bead this session holds, found with BOTH statuses a claimed step can carry.
test_the_convoy_is_recovered_from_the_held_step_when_gc_bead_id_is_unset() {
    local dir key
    for key in gc.input_convoy_id gc.var.convoy_id; do
        dir=$(new_case)
        work "$dir" closed
        echo 'unset GC_BEAD_ID' >"$dir/env"
        printf '[{"id":"w-step","metadata":{"gc.step_ref":"s","gc.root_bead_id":"w-root"}}]' >"$dir/list"
        printf '[{"id":"w-root","metadata":{"%s":"gcp-convoy"}}]' "$key" >"$dir/show-w-root"
        run_guard "$dir"
        assert_rc "$dir" 0
        grep -F 'ALREADY_SUBMITTED w-1 status=closed' "$dir/out" >/dev/null ||
            fail "$key: the convoy was not recovered: $(cat "$dir/out")"
        assert_calls "$dir" <<EOF
gc bd list --assignee=$ME --status=open,in_progress --has-metadata-key gc.step_ref --include-infra --limit=0 --json
gc bd show w-root --json
$READ_CALLS
gc runtime drain-ack
EOF
    done
}

# The exit after the drain is a bare `exit`, so the script ends with the status
# of `gc runtime drain-ack`.
test_the_exit_status_is_the_drain_acks() {
    local dir
    dir=$(new_case)
    work "$dir" closed
    echo 3 >"$dir/drain.code"
    run_guard "$dir"
    assert_rc "$dir" 3
    grep -F 'ALREADY_SUBMITTED w-1' "$dir/out" >/dev/null || fail "no ALREADY_SUBMITTED line: $(cat "$dir/out")"
}

# The prefix is required even when empty. A wrong argument count stops the call
# with exit 2 before anything is read, and does not drain: no evidence is not a
# reason to drain a session with its branch unpushed.
test_the_binding_prefix_argument_is_required() {
    local dir args
    for args in "--none" "a b"; do
        dir=$(new_case)
        work "$dir" closed
        # shellcheck disable=SC2086
        run_guard "$dir" $args
        assert_rc "$dir" 2
        grep -F 'SUBMITTED_GUARD_USAGE polecat-already-submitted.sh takes exactly one argument' "$dir/out" >/dev/null ||
            fail "no usage line for args '$args': $(cat "$dir/out")"
        [ ! -s "$dir/calls.log" ] || fail "a bad call read or drained: $(cat "$dir/calls.log")"
    done
}

# stub_of <file> <var> <configdir> lifts the call a caller carries (from
# <var>= to the closing fi) and binds its template values. A changed stub in the
# prompt or the fragment is the one run here.
stub_of() {
    awk -v v="^$2=" '$0 ~ v {f=1} f {print} f && /^fi$/ {exit}' "$1" |
        sed -e "s#{{ .ConfigDir }}#$3#" -e 's#{{ .BindingPrefix }}#gastown.#'
}

test_the_prompt_and_the_fragment_run_the_script() {
    local dir file
    for file in "$PROMPT" "$FRAGMENT"; do
        dir=$(new_case)
        work "$dir" closed
        stub_of "$file" SUBMITTED_SH "$ROOT/gastown" >"$dir/stub.sh"
        [ -s "$dir/stub.sh" ] || fail "could not lift the call out of $(basename "$file")"
        (
            export FX="$dir" PATH="$dir/bin:$PATH"
            unset BEADS_ACTOR GC_ALIAS GC_SESSION_ID GC_SESSION_NAME GC_AGENT GC_RIG GC_BEAD_ID
            export GC_RIG=winnow BEADS_ACTOR=$ME GC_BEAD_ID=gcp-convoy
            bash "$dir/stub.sh" </dev/null >"$dir/out" 2>"$dir/err"
        ) || fail "$(basename "$file"): the call exited non-zero: $(cat "$dir/out" "$dir/err")"
        grep -F 'ALREADY_SUBMITTED w-1 status=closed' "$dir/out" >/dev/null ||
            fail "$(basename "$file"): the call did not reach the script under the real pack dir: $(cat "$dir/out")"
        grep -F 'gc runtime drain-ack' "$dir/calls.log" >/dev/null ||
            fail "$(basename "$file"): a closed work bead did not drain"
    done
}

# With {{ .ConfigDir }} rendering to a directory that lacks the script (a gc
# older than v1.5.0 renders ""), the call says so and does NOT drain: no
# evidence the handoff ran means run submit-and-exit, whose own step 0 guard is
# the second brake against a double submit.
test_a_missing_script_says_so_and_does_not_drain() {
    local dir file
    for file in "$PROMPT" "$FRAGMENT"; do
        dir=$(new_case)
        stub_of "$file" SUBMITTED_SH "$dir/no-such-pack" >"$dir/stub.sh"
        (
            export FX="$dir" PATH="$dir/bin:$PATH"
            bash "$dir/stub.sh" </dev/null >"$dir/out" 2>"$dir/err"
        ) || fail "$(basename "$file"): a missing script must not fail the call: $(cat "$dir/out" "$dir/err")"
        [ "$(cat "$dir/out")" = "SUBMITTED_GUARD_MISSING already-submitted script not found at '$dir/no-such-pack/assets/scripts/polecat-already-submitted.sh'; no evidence the handoff ran, so run submit-and-exit." ] ||
            fail "$(basename "$file"): wrong output for a missing script: $(cat "$dir/out")"
        [ ! -s "$dir/calls.log" ] || fail "$(basename "$file"): a missing script ran gc: $(cat "$dir/calls.log")"
    done
}

test_a_closed_work_bead_is_already_submitted
test_a_work_bead_held_by_the_refinery_is_already_submitted
test_the_refinery_is_named_from_the_rig_and_the_binding_prefix
test_no_positive_evidence_goes_on_to_submit_and_exit
test_an_unreadable_state_is_retried_and_then_not_taken_as_proof
test_a_read_that_recovers_on_retry_is_taken
test_the_convoy_is_recovered_from_the_held_step_when_gc_bead_id_is_unset
test_the_exit_status_is_the_drain_acks
test_the_binding_prefix_argument_is_required
test_the_prompt_and_the_fragment_run_the_script
test_a_missing_script_says_so_and_does_not_drain

echo "polecat already-submitted guard tests passed"
