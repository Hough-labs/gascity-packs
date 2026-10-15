#!/usr/bin/env bash
# Executable reproduction of gcp-o1nij: the polecat prompt's resume re-verify
# drained every healthy resumed session.
#
# The old block started from `$GC_BEAD_ID`, which gc exports only to
# convergence condition scripts and never into a session shell, so
# `gc convoy status ""` failed and the block printed RESUME_INDETERMINATE. Where
# GC_BEAD_ID was set it then required the WORK bead's assignee to be this
# session, and since gcp-952j9 nothing assigns the work bead to the polecat, so
# it printed OWNERSHIP_LOST. Either way the session drained.
#
# These tests run the re-verify block out of the polecat prompt against a
# stubbed `gc`. The block now keys on the STEP this session last claimed
# (`gc hook current --id-only`), which gc stamps onto the session's own bead on
# every claim and keeps across `gc runtime request-restart`. It never reads the
# work bead, never reads metadata.polecat_session, and never writes.
#
# No test depends on wall-clock time: `sleep` is a stub that logs its argument.
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
PROMPT="$ROOT/gastown/agents/polecat/prompt.template.md"
CLAIM_SH="$ROOT/gastown/assets/scripts/polecat-claim.sh"

TMPROOT=$(mktemp -d)
trap 'rm -rf "$TMPROOT"' EXIT

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

# extract_guard pulls a guard verbatim out of <file> (the prompt template or the
# claim script), so the code under test is the code that ships. A drifted or
# deleted guard fails here rather than passing against a stale copy.
extract_guard() {
    local name="$1" out="$2" file="$3"
    [[ "$(grep -c "^# GUARD_BEGIN $name\$" "$file")" == 1 ]] ||
        fail "expected exactly one '# GUARD_BEGIN $name' in $file"
    [[ "$(grep -c "^# GUARD_END $name\$" "$file")" == 1 ]] ||
        fail "expected exactly one '# GUARD_END $name' in $file"
    awk -v b="# GUARD_BEGIN $name" -v e="# GUARD_END $name" '$0 == b {f=1} $0 == e {f=0} f' "$file" >"$out"
    [[ -s "$out" ]] || fail "could not extract the $name guard from $file"
    bash -n "$out" || fail "extracted $name guard is not valid shell"
}

# write_gc_stub answers only the reads the block makes and journals every call,
# so a test can assert on what the block did, not just on what it printed.
#   gc hook current --id-only   prints $GC_STUB_CURRENT, or exits 1 when unset
#   gc bd show <id> --json      serves $GC_STUB_BEADS/<id>.json, else an empty list
#   gc convoy status <id>       serves $GC_STUB_BEADS/convoy.json (the OLD block's read)
#   gc runtime drain-ack        journalled only
write_gc_stub() {
    local bin="$1"
    mkdir -p "$bin"
    cat >"$bin/gc" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$GC_STUB_CALLS"
case "${1:-}" in
hook)
    case "${2:-}" in
    current)
        [ -n "${GC_STUB_CURRENT:-}" ] || exit 1
        printf '%s\n' "$GC_STUB_CURRENT"
        ;;
    esac
    ;;
bd)
    case "${2:-}" in
    show)
        if [ -f "$GC_STUB_BEADS/${3:-}.json" ]; then
            cat "$GC_STUB_BEADS/${3:-}.json"
        else
            printf '[]'
        fi
        ;;
    esac
    ;;
convoy)
    case "${2:-}" in
    status)
        [ -f "$GC_STUB_BEADS/convoy.json" ] && cat "$GC_STUB_BEADS/convoy.json"
        ;;
    esac
    ;;
runtime) ;;
esac
exit 0
SH
    chmod +x "$bin/gc"
    # The block backs off between reads. The stub logs the argument and returns
    # at once, so the back-off schedule is asserted without waiting for it.
    cat >"$bin/sleep" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$1" >>"$GC_STUB_SLEEPS"
SH
    chmod +x "$bin/sleep"
}

new_case() {
    local dir
    dir=$(mktemp -d "$TMPROOT/case.XXXXXX")
    mkdir -p "$dir/bin" "$dir/beads"
    write_gc_stub "$dir/bin"
    extract_guard resume-reverify "$dir/guard.sh" "$PROMPT"
    : >"$dir/calls.log"
    : >"$dir/sleeps.log"
    printf '%s' "$dir"
}

# step_json writes the step bead: step_json <dir> <id> <status> <assignee> [root]
step_json() {
    local dir="$1" id="$2" status="$3" assignee="$4" root="${5-gcp-root}"
    local owner="" root_meta=""
    [[ -z "$assignee" ]] || owner="\"assignee\":\"$assignee\","
    [[ -z "$root" ]] || root_meta="\"gc.root_bead_id\":\"$root\","
    cat >"$dir/beads/$id.json" <<JSON
[{"id":"$id","status":"$status",${owner}"metadata":{${root_meta}"gc.step_ref":"mol-polecat-work.implement"}}]
JSON
}

# root_json writes the molecule root: root_json <dir> <id> <metadata-key> <convoy>
root_json() {
    local dir="$1" id="$2" key="$3" convoy="$4"
    cat >"$dir/beads/$id.json" <<JSON
[{"id":"$id","status":"open","metadata":{"$key":"$convoy"}}]
JSON
}

# run_reverify executes the block with the session's identity bound, then echoes
# RESUME_PROCEEDED. A drain exits before that marker, so its absence is the
# assertion that the polecat never reached the work. The identity variables are
# reset so the test runner's own cannot leak in: BEADS_ACTOR is the session
# under test and SELF_IDS may add its other spellings as assignments. GC_BEAD_ID
# is bound only when the case passes one, as it is unset in a real session shell.
run_reverify() {
    local dir="$1" me="$2" current="${3-}" convoy="${4-}"
    {
        echo 'unset BEADS_ACTOR GC_ALIAS GC_SESSION_ID GC_SESSION_NAME GC_AGENT GC_BEAD_ID'
        echo "BEADS_ACTOR=\"$me\""
        echo "${SELF_IDS:-}"
        [[ -z "$convoy" ]] || echo "GC_BEAD_ID=\"$convoy\""
        cat "$dir/guard.sh"
        echo 'echo RESUME_PROCEEDED'
    } >"$dir/harness.sh"

    GC_STUB_CALLS="$dir/calls.log" GC_STUB_SLEEPS="$dir/sleeps.log" GC_STUB_BEADS="$dir/beads" \
        GC_STUB_CURRENT="$current" PATH="$dir/bin:$PATH" bash "$dir/harness.sh"
}

drained() { grep -F 'runtime drain-ack' "$1/calls.log" >/dev/null; }

test_resumed_session_holding_its_step_proceeds() {
    local dir out
    dir=$(new_case)
    step_json "$dir" gcp-step in_progress gastown__polecat-gc-psfm

    # GC_BEAD_ID is unset, as it is in every real session shell.
    out=$(run_reverify "$dir" gastown__polecat-gc-psfm gcp-step)

    grep -F 'RESUME_VERIFIED gcp-step molecule=gcp-root assignee=gastown__polecat-gc-psfm' <<<"$out" >/dev/null ||
        fail "a healthy resumed session was not verified: $out"
    grep -F 'RESUME_PROCEEDED' <<<"$out" >/dev/null ||
        fail "a verified session did not continue: $out"
    ! drained "$dir" || fail "a healthy resumed session was drained"
    ! grep -F 'convoy status' "$dir/calls.log" >/dev/null ||
        fail "the re-verify asked for a convoy it has no id for: $(cat "$dir/calls.log")"
}

# The WORK bead is unclaimed for the whole run, so nothing the block concludes
# may depend on it: not its assignee, not whether it can be found.
test_resume_proceeds_with_the_work_bead_unassigned() {
    local dir out
    dir=$(new_case)
    step_json "$dir" gcp-step in_progress winnow/gastown.nux
    root_json "$dir" gcp-root gc.input_convoy_id gcp-convoy
    cat >"$dir/beads/gcp-work.json" <<'JSON'
[{"id":"gcp-work","status":"open","metadata":{"polecat_session":"gastown__polecat-gc-old"}}]
JSON
    cat >"$dir/beads/convoy.json" <<'JSON'
{"children":[{"id":"gcp-work","status":"open"}]}
JSON

    # GC_BEAD_ID is set here, so the block also checks the molecule's convoy.
    out=$(run_reverify "$dir" winnow/gastown.nux gcp-step gcp-convoy)

    grep -F 'RESUME_VERIFIED gcp-step' <<<"$out" >/dev/null ||
        fail "an unassigned work bead stopped a healthy resume: $out"
    ! grep -F 'OWNERSHIP_LOST' <<<"$out" >/dev/null ||
        fail "the re-verify judged the session by the work bead: $out"
    ! grep -F 'gcp-work' "$dir/calls.log" >/dev/null ||
        fail "the re-verify read the work bead: $(cat "$dir/calls.log")"
    ! grep -F 'convoy status' "$dir/calls.log" >/dev/null ||
        fail "the re-verify derived the work bead from the convoy: $(cat "$dir/calls.log")"
}

# One session, several spellings: gc 1.4.x claims under the runtime session
# name, a gc 1.5.0 namepool polecat acts under its alias. The identity set is
# the same one the claim block uses, so a step recorded under another spelling
# of THIS session is still ours.
test_step_held_under_another_spelling_of_this_session_proceeds() {
    local dir out
    dir=$(new_case)
    step_json "$dir" gcp-step in_progress gastown__polecat-gc-psfm

    out=$(SELF_IDS="GC_ALIAS=winnow/gastown.nux GC_SESSION_ID=gc-psfm GC_SESSION_NAME=gastown__polecat-gc-psfm GC_AGENT=winnow/gastown.nux" \
        run_reverify "$dir" winnow/gastown.nux gcp-step)

    grep -F 'RESUME_VERIFIED gcp-step' <<<"$out" >/dev/null ||
        fail "a step held under this session's runtime name was lost: $out"
    ! drained "$dir" || fail "the session was drained over a spelling of its own identity"

    # Each of the five names counts, and a name that is not ours does not.
    dir=$(new_case)
    step_json "$dir" gcp-step in_progress gc-psfm
    out=$(SELF_IDS="GC_SESSION_ID=gc-psfm" run_reverify "$dir" winnow/gastown.nux gcp-step)
    grep -F 'RESUME_VERIFIED gcp-step' <<<"$out" >/dev/null ||
        fail "a step held under this session's bead id was lost: $out"
    dir=$(new_case)
    step_json "$dir" gcp-step in_progress winnow/gastown.furiosa
    out=$(SELF_IDS="GC_AGENT=winnow/gastown.nux" run_reverify "$dir" winnow/gastown.nux gcp-step)
    grep -F 'OWNERSHIP_LOST gcp-step' <<<"$out" >/dev/null ||
        fail "a step held by another session was verified: $out"
}

test_step_taken_by_another_session_is_ownership_lost() {
    local dir out
    dir=$(new_case)
    step_json "$dir" gcp-step in_progress gastown__polecat-gc-8a4d

    out=$(run_reverify "$dir" gastown__polecat-gc-psfm gcp-step)

    grep -F 'OWNERSHIP_LOST gcp-step assignee=gastown__polecat-gc-8a4d status=in_progress' <<<"$out" >/dev/null ||
        fail "a step taken by another session was not reported lost: $out"
    ! grep -F 'RESUME_PROCEEDED' <<<"$out" >/dev/null ||
        fail "the session kept working a step another session holds"
    drained "$dir" || fail "a session that lost its step did not drain"
}

# A release puts the step back in the pool: status open, assignee cleared. The
# stamp still names it, but this session no longer holds it.
test_released_step_is_ownership_lost() {
    local dir out
    dir=$(new_case)
    step_json "$dir" gcp-step open ""

    out=$(run_reverify "$dir" gastown__polecat-gc-psfm gcp-step)

    grep -F 'OWNERSHIP_LOST gcp-step assignee= status=open' <<<"$out" >/dev/null ||
        fail "a released step was not reported lost: $out"
    ! grep -F 'RESUME_PROCEEDED' <<<"$out" >/dev/null ||
        fail "the session kept working a step that went back to the pool"
    drained "$dir" || fail "a session holding a released step did not drain"
}

# No stamped claim: three reads, with the back-off between them but not after
# the last, then drain. The sleep log is the schedule.
test_no_current_claim_is_indeterminate() {
    local dir out sleeps
    dir=$(new_case)

    out=$(run_reverify "$dir" gastown__polecat-gc-psfm "")

    grep -F 'RESUME_INDETERMINATE no readable step claim for this session (step=none)' <<<"$out" >/dev/null ||
        fail "a session with no current claim was not indeterminate: $out"
    ! grep -F 'RESUME_PROCEEDED' <<<"$out" >/dev/null ||
        fail "a session with no current claim kept going"
    drained "$dir" || fail "a session with no current claim did not drain"
    sleeps=$(paste -sd, - <"$dir/sleeps.log")
    [[ "$sleeps" == "1,2" ]] ||
        fail "expected the back-off to read exactly 1,2, got '$sleeps'"
}

test_unreadable_step_is_indeterminate() {
    local dir out sleeps
    dir=$(new_case)
    # The stamp names a step, but the read comes back empty every time.

    out=$(run_reverify "$dir" gastown__polecat-gc-psfm gcp-step)

    grep -F 'RESUME_INDETERMINATE no readable step claim for this session (step=gcp-step)' <<<"$out" >/dev/null ||
        fail "an unreadable step was not indeterminate: $out"
    ! grep -F 'OWNERSHIP_LOST' <<<"$out" >/dev/null ||
        fail "an unreadable step was reported as lost: $out"
    drained "$dir" || fail "a session with an unreadable step did not drain"
    sleeps=$(paste -sd, - <"$dir/sleeps.log")
    [[ "$sleeps" == "1,2" ]] ||
        fail "expected the back-off to read exactly 1,2, got '$sleeps'"
}

# A closed step took nothing from this session: the molecule moved on, or the
# step was closed under it. It holds no live step, which is not a loss.
test_closed_step_is_indeterminate_not_lost() {
    local dir out
    dir=$(new_case)
    step_json "$dir" gcp-step closed gastown__polecat-gc-psfm

    out=$(run_reverify "$dir" gastown__polecat-gc-psfm gcp-step)

    grep -F 'RESUME_INDETERMINATE step gcp-step is already closed' <<<"$out" >/dev/null ||
        fail "a closed step was not indeterminate: $out"
    ! grep -F 'OWNERSHIP_LOST' <<<"$out" >/dev/null ||
        fail "a closed step was reported as lost: $out"
    drained "$dir" || fail "a session holding a closed step did not drain"
}

test_step_in_another_convoy_is_indeterminate() {
    local dir out
    dir=$(new_case)
    step_json "$dir" gcp-step in_progress gastown__polecat-gc-psfm
    root_json "$dir" gcp-root gc.input_convoy_id gcp-convoy-b

    out=$(run_reverify "$dir" gastown__polecat-gc-psfm gcp-step gcp-convoy-a)

    grep -F 'RESUME_INDETERMINATE step gcp-step is in molecule gcp-root (convoy gcp-convoy-b), not convoy gcp-convoy-a' <<<"$out" >/dev/null ||
        fail "a step poured on another convoy was not indeterminate: $out"
    ! grep -F 'RESUME_PROCEEDED' <<<"$out" >/dev/null ||
        fail "the session kept working a step from another convoy"
    drained "$dir" || fail "a session holding another convoy's step did not drain"

    # The convoy may be recorded under gc.var.convoy_id instead.
    dir=$(new_case)
    step_json "$dir" gcp-step in_progress gastown__polecat-gc-psfm
    root_json "$dir" gcp-root gc.var.convoy_id gcp-convoy-a
    out=$(run_reverify "$dir" gastown__polecat-gc-psfm gcp-step gcp-convoy-a)
    grep -F 'RESUME_VERIFIED gcp-step' <<<"$out" >/dev/null ||
        fail "a convoy recorded as gc.var.convoy_id was not matched: $out"

    # An unreadable molecule root cannot confirm the convoy, so it does not pass.
    dir=$(new_case)
    step_json "$dir" gcp-step in_progress gastown__polecat-gc-psfm
    out=$(run_reverify "$dir" gastown__polecat-gc-psfm gcp-step gcp-convoy-a)
    grep -F 'RESUME_INDETERMINATE step gcp-step is in molecule gcp-root (convoy unknown)' <<<"$out" >/dev/null ||
        fail "an unreadable molecule root was taken as a match: $out"

    # With GC_BEAD_ID unset the convoy is not checked, and the root is not read.
    dir=$(new_case)
    step_json "$dir" gcp-step in_progress gastown__polecat-gc-psfm
    out=$(run_reverify "$dir" gastown__polecat-gc-psfm gcp-step)
    ! grep -F 'show gcp-root' "$dir/calls.log" >/dev/null ||
        fail "the molecule root was read with no GC_BEAD_ID to compare it to: $(cat "$dir/calls.log")"
}

# The block only reads. Every outcome is run, and none may touch a bead.
test_reverify_writes_nothing() {
    local dir
    for scenario in proceed lost released none unreadable closed other_convoy; do
        dir=$(new_case)
        case "$scenario" in
        proceed) step_json "$dir" gcp-step in_progress me; run_reverify "$dir" me gcp-step >/dev/null ;;
        lost) step_json "$dir" gcp-step in_progress someone-else; run_reverify "$dir" me gcp-step >/dev/null ;;
        released) step_json "$dir" gcp-step open ""; run_reverify "$dir" me gcp-step >/dev/null ;;
        none) run_reverify "$dir" me "" >/dev/null ;;
        unreadable) run_reverify "$dir" me gcp-step >/dev/null ;;
        closed) step_json "$dir" gcp-step closed me; run_reverify "$dir" me gcp-step >/dev/null ;;
        other_convoy)
            step_json "$dir" gcp-step in_progress me
            root_json "$dir" gcp-root gc.input_convoy_id gcp-convoy-b
            run_reverify "$dir" me gcp-step gcp-convoy-a >/dev/null
            ;;
        esac
        [[ -s "$dir/calls.log" ]] || fail "$scenario: the block made no gc calls, so the check proves nothing"
        ! grep -E '^bd (update|close|create|note)( |$)' "$dir/calls.log" >/dev/null ||
            fail "$scenario: the re-verify wrote to a bead: $(cat "$dir/calls.log")"
        ! grep -E '(^| )(update|close|create|note)( |$)' "$dir/calls.log" >/dev/null ||
            fail "$scenario: the re-verify made a write call: $(cat "$dir/calls.log")"
    done
}

# The re-verify restates claim_assignee_is_ours because each prompt block runs
# as its own shell and cannot share the claim block's copy. Two copies drift, so
# pin them byte-identical: a name added to one and not the other would make the
# claim and the resume disagree about whose step this is.
test_identity_set_matches_the_live_owner_guard() {
    local dir claim_fn resume_fn
    dir=$(new_case)
    extract_guard live-owner "$dir/live-owner.sh" "$CLAIM_SH"
    claim_fn="$dir/claim-fn.sh"
    resume_fn="$dir/resume-fn.sh"
    awk '/^claim_assignee_is_ours\(\) \{$/ {f=1} f {print} f && /^}$/ {exit}' "$dir/live-owner.sh" >"$claim_fn"
    awk '/^claim_assignee_is_ours\(\) \{$/ {f=1} f {print} f && /^}$/ {exit}' "$dir/guard.sh" >"$resume_fn"
    [[ -s "$claim_fn" ]] || fail "could not extract claim_assignee_is_ours from polecat-claim.sh"
    [[ -s "$resume_fn" ]] || fail "could not extract claim_assignee_is_ours from the resume-reverify block"
    [[ "$(grep -c 'GC_ALIAS' "$claim_fn")" -ge 1 ]] ||
        fail "the extracted polecat-claim.sh copy does not hold the identity set"
    diff "$claim_fn" "$resume_fn" ||
        fail "claim_assignee_is_ours differs between polecat-claim.sh and the resume-reverify block"
}

test_resumed_session_holding_its_step_proceeds
test_resume_proceeds_with_the_work_bead_unassigned
test_step_held_under_another_spelling_of_this_session_proceeds
test_step_taken_by_another_session_is_ownership_lost
test_released_step_is_ownership_lost
test_no_current_claim_is_indeterminate
test_unreadable_step_is_indeterminate
test_closed_step_is_indeterminate_not_lost
test_step_in_another_convoy_is_indeterminate
test_reverify_writes_nothing
test_identity_set_matches_the_live_owner_guard

echo "polecat resume re-verify tests passed"
