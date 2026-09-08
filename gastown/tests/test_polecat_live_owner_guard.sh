#!/usr/bin/env bash
# Executable reproduction of the duplicate pour in gcp-mjjg / winnow-2fj8u.
#
# On 2026-09-07 gc's ReleaseIfCurrent put the in-flight `mol-polecat-work`
# implement step winnow-iaroy back in the pool TWICE (20:11:56Z and 20:33:37Z)
# while gastown__polecat-gc-8a4d held the molecule and was state=active. The
# release writes no bd event, so to the next polecat the bead was
# indistinguishable from ordinary unclaimed work: gastown__polecat-gc-psfm
# claimed it cleanly at 20:37:51Z. Nothing in the machinery refused — the
# duplicate backed off because it happened to notice.
#
# These tests run the live-owner guard out of the polecat prompt's claim block
# against a stubbed `gc` and assert that the refusal is now mechanical: a live
# owner is declined and the step restored, a dead owner is not (that is the
# ordinary post-restart resume, and stalling it would stall the engine).
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
PROMPT="$ROOT/gastown/agents/polecat/prompt.template.md"

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

# extract_guard pulls the guard verbatim out of the prompt template, so the code
# under test is the code that ships. A drifted or deleted guard fails here
# rather than passing against a stale copy.
extract_guard() {
    local out="$1"
    awk '/^# GUARD_BEGIN live-owner$/{f=1} /^# GUARD_END live-owner$/{f=0} f' "$PROMPT" >"$out"
    [[ -s "$out" ]] || fail "could not extract the live-owner guard from $PROMPT"
    grep -F 'CLAIM_DECLINED_LIVE_OWNER' "$out" >/dev/null ||
        fail "extracted guard does not contain the decline path"
    bash -n "$out" || fail "extracted guard is not valid shell"
}

# write_gc_stub answers only the reads and writes the guard makes, and records
# every mutation so a test can assert on what the guard did, not just on what it
# printed.
write_gc_stub() {
    local bin="$1"
    mkdir -p "$bin"
    cat >"$bin/gc" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$GC_CALLS"
case "$1 $2" in
    "bd show") # gc-bd-argv-tail: case label matching the fake gc's argv tail
        case "$3" in
            "$GC_ROOT_BEAD") cat "$GC_ROOT_JSON" ;;
            "$GC_WORK_BEAD") cat "$GC_WORK_JSON" ;;
            *) printf '[]' ;;
        esac
        ;;
    "convoy status") cat "$GC_CONVOY_JSON" ;;
    "session list") cat "$GC_SESSIONS_JSON" ;;
    "bd update") exit "${GC_UPDATE_EXIT:-0}" ;; # gc-bd-argv-tail: case label matching the fake gc's argv tail
    "session nudge") ;;
    "runtime drain-ack") ;;
    *) ;;
esac
SH
    chmod +x "$bin/gc"
}

# run_guard executes the guard with the claim block's inputs already bound, then
# echoes GUARD_PROCEEDED. A decline exits before that marker, so its absence is
# the assertion that the polecat never reached the work.
run_guard() {
    local dir="$1" owner_assignee="$2" me="$3" step_ref="${4-mol-polecat-work.implement}"
    local root_meta="${5-\"gc.root_bead_id\":\"winnow-5azcp\",}"
    local claim_reason="${6-claimed}"

    cat >"$dir/root.json" <<'JSON'
[{"id":"winnow-5azcp","status":"in_progress","metadata":{"gc.input_convoy_id":"winnow-0inqp"}}]
JSON
    cat >"$dir/convoy.json" <<'JSON'
{"children":[{"id":"winnow-pcpn6","status":"in_progress"}]}
JSON
    cat >"$dir/work.json" <<JSON
[{"id":"winnow-pcpn6","status":"in_progress","assignee":"$owner_assignee","metadata":{"gc.session_id":"gc-8a4d"}}]
JSON
    cat >"$dir/guard-harness.sh" <<HARNESS
WORK_ID="winnow-iaroy"
EXPECTED_ASSIGNEE="$me"
STEP_REF="$step_ref"
CLAIM_REASON="$claim_reason"
SHOW_JSON='[{"id":"winnow-iaroy","status":"in_progress","assignee":"$me","metadata":{${root_meta}"gc.step_ref":"$step_ref"}}]'
GC_RIG="winnow"
HARNESS
    cat "$dir/guard.sh" >>"$dir/guard-harness.sh"
    echo 'echo GUARD_PROCEEDED' >>"$dir/guard-harness.sh"

    GC_CALLS="$dir/calls.log" \
        GC_ROOT_BEAD="winnow-5azcp" GC_ROOT_JSON="$dir/root.json" \
        GC_WORK_BEAD="winnow-pcpn6" GC_WORK_JSON="$dir/work.json" \
        GC_CONVOY_JSON="$dir/convoy.json" GC_SESSIONS_JSON="$dir/sessions.json" \
        PATH="$dir/bin:$PATH" bash "$dir/guard-harness.sh"
}

new_case() {
    local dir
    dir=$(mktemp -d)
    mkdir -p "$dir/bin"
    write_gc_stub "$dir/bin"
    extract_guard "$dir/guard.sh"
    : >"$dir/calls.log"
    printf '%s' "$dir"
}

live_sessions() {
    cat >"$1/sessions.json" <<'JSON'
{"sessions":[
  {"id":"gc-8a4d","name":"winnow/gastown.furiosa","session_name":"gastown__polecat-gc-8a4d","alias":"winnow/gastown.furiosa","state":"active","closed":false},
  {"id":"gc-psfm","name":"winnow/gastown.nux","session_name":"gastown__polecat-gc-psfm","alias":"winnow/gastown.nux","state":"active","closed":false}
]}
JSON
}

test_live_owner_is_declined_and_the_step_restored() {
    local dir out
    dir=$(new_case)
    live_sessions "$dir"

    # The incident, exactly: nux/gc-psfm holds a clean claim on the implement
    # step while furiosa/gc-8a4d still holds the work bead and is active.
    out=$(run_guard "$dir" "gastown__polecat-gc-8a4d" "gastown__polecat-gc-psfm")

    grep -F 'CLAIM_DECLINED_LIVE_OWNER winnow-iaroy' <<<"$out" >/dev/null ||
        fail "a duplicate pour onto a LIVE owner was not declined: $out"
    grep -F 'that owner is live (session gc-8a4d)' <<<"$out" >/dev/null ||
        fail "decline did not name the live owning session: $out"
    ! grep -F 'GUARD_PROCEEDED' <<<"$out" >/dev/null ||
        fail "guard declined but still fell through to the work"

    local restore_call
    restore_call='bd update winnow-iaroy --assignee=gastown__polecat-gc-8a4d' # gc-bd-argv-tail: expected argv tail, not an invocation
    grep -F "$restore_call" "$dir/calls.log" >/dev/null ||
        fail "declining polecat did not restore the step to its owner"
    grep -F -- '--set-metadata gc.session_id=gc-8a4d' "$dir/calls.log" >/dev/null ||
        fail "declining polecat did not restore the owner's session binding"
    grep -F 'runtime drain-ack' "$dir/calls.log" >/dev/null ||
        fail "declining polecat did not drain"
    grep -F 'session nudge winnow/{{ .BindingPrefix }}witness' "$dir/calls.log" >/dev/null ||
        fail "declining polecat did not report the duplicate pour to the witness"
}

test_dead_owner_is_a_resume_and_proceeds() {
    local dir out
    dir=$(new_case)
    # gc-8a4d is gone; `gc session list` omits closed sessions, so it is simply
    # absent. A pool restart mints a new identity, so this is the ORDINARY
    # resume and blocking it would stall every restarted molecule.
    cat >"$dir/sessions.json" <<'JSON'
{"sessions":[{"id":"gc-psfm","name":"winnow/gastown.nux","session_name":"gastown__polecat-gc-psfm","state":"active","closed":false}]}
JSON

    out=$(run_guard "$dir" "gastown__polecat-gc-8a4d" "gastown__polecat-gc-psfm")

    grep -F 'GUARD_PROCEEDED' <<<"$out" >/dev/null ||
        fail "a dead prior owner stalled the resume: $out"
    ! grep -F 'CLAIM_DECLINED_LIVE_OWNER' <<<"$out" >/dev/null ||
        fail "a dead prior owner was wrongly treated as a live duplicate: $out"
    ! grep -F -- '--assignee=gastown__polecat-gc-8a4d' "$dir/calls.log" >/dev/null ||
        fail "resume path wrote the dead owner back onto the step"
}

test_closed_session_still_listed_is_not_live() {
    local dir out
    dir=$(new_case)
    # `gc session list --state all` (or a racing close) can surface the owner
    # with closed=true. Present-but-closed is dead, not alive.
    cat >"$dir/sessions.json" <<'JSON'
{"sessions":[{"id":"gc-8a4d","session_name":"gastown__polecat-gc-8a4d","state":"active","closed":true}]}
JSON

    out=$(run_guard "$dir" "gastown__polecat-gc-8a4d" "gastown__polecat-gc-psfm")

    grep -F 'GUARD_PROCEEDED' <<<"$out" >/dev/null ||
        fail "a closed owning session was treated as live: $out"
}

test_own_molecule_proceeds_without_probing_liveness() {
    local dir out
    dir=$(new_case)
    live_sessions "$dir"

    out=$(run_guard "$dir" "gastown__polecat-gc-psfm" "gastown__polecat-gc-psfm")

    grep -F 'GUARD_PROCEEDED' <<<"$out" >/dev/null ||
        fail "the guard blocked a session working its own molecule: $out"
    ! grep -F 'session list' "$dir/calls.log" >/dev/null ||
        fail "the guard probed session liveness for its own molecule"
}

test_unreadable_liveness_fails_closed() {
    local dir out
    dir=$(new_case)
    # A wedged or otherwise unreadable `gc session list`. Unreadable is NOT evidence the
    # owner is gone: declining costs a pool slot, proceeding stomps a live
    # worktree.
    printf 'not json at all' >"$dir/sessions.json"

    out=$(run_guard "$dir" "gastown__polecat-gc-8a4d" "gastown__polecat-gc-psfm")

    grep -F 'CLAIM_DECLINED_LIVE_OWNER' <<<"$out" >/dev/null ||
        fail "unreadable session liveness did not fail closed: $out"
    grep -F 'session liveness was UNREADABLE after retries' <<<"$out" >/dev/null ||
        fail "decline did not distinguish unreadable liveness from a live owner: $out"
    ! grep -F 'GUARD_PROCEEDED' <<<"$out" >/dev/null ||
        fail "guard fell through despite unreadable liveness"
}

test_unresolvable_molecule_proceeds_unguarded() {
    local dir out
    dir=$(new_case)
    live_sessions "$dir"

    # No gc.root_bead_id: the guard cannot reach a work bead. That is not
    # evidence of a duplicate pour, so it must warn and proceed rather than
    # invent a refusal.
    out=$(run_guard "$dir" "gastown__polecat-gc-8a4d" "gastown__polecat-gc-psfm" \
        "mol-polecat-work.implement" "")

    grep -F 'WARN live-owner guard could not resolve an owner' <<<"$out" >/dev/null ||
        fail "an unresolvable molecule did not warn: $out"
    grep -F 'GUARD_PROCEEDED' <<<"$out" >/dev/null ||
        fail "an unresolvable molecule blocked the engine: $out"
}

test_work_bead_claim_skips_the_guard() {
    local dir out
    dir=$(new_case)
    live_sessions "$dir"

    # No gc.step_ref means the hook handed back the WORK bead itself, which
    # post-claim ownership verification has already proved is ours. There is no
    # foreign owner to find, and the convoy walk would be three wasted reads on
    # the hot startup path.
    out=$(run_guard "$dir" "gastown__polecat-gc-8a4d" "gastown__polecat-gc-psfm" "")

    grep -F 'GUARD_PROCEEDED' <<<"$out" >/dev/null ||
        fail "a work-bead claim was blocked by the step guard: $out"
    ! grep -F 'convoy status' "$dir/calls.log" >/dev/null ||
        fail "the guard walked the convoy for a bead carrying no gc.step_ref"
}

test_preassigned_step_skips_the_walk_entirely() {
    local dir out
    dir=$(new_case)
    live_sessions "$dir"

    # `ready_assignment` means the step already carried this session's identity
    # before the hook ran. A release CLEARS the assignee, so a released bead can
    # never arrive by that tier — there is nothing for the guard to find, and a
    # molecule's own preassigned steps come back this way at every step
    # boundary. Three gc round-trips on that path would be pure startup tax.
    out=$(run_guard "$dir" "gastown__polecat-gc-8a4d" "gastown__polecat-gc-psfm" \
        "mol-polecat-work.implement" '"gc.root_bead_id":"winnow-5azcp",' "ready_assignment")

    grep -F 'GUARD_PROCEEDED' <<<"$out" >/dev/null ||
        fail "a preassigned step was blocked by the pool-claim guard: $out"
    [[ ! -s "$dir/calls.log" ]] ||
        fail "the guard walked the molecule for a claim that was never a pool claim: $(cat "$dir/calls.log")"
}

test_unknown_claim_reason_still_checks() {
    local dir out
    dir=$(new_case)
    live_sessions "$dir"

    # An absent reason is not a promise the bead was preassigned. Check it.
    out=$(run_guard "$dir" "gastown__polecat-gc-8a4d" "gastown__polecat-gc-psfm" \
        "mol-polecat-work.implement" '"gc.root_bead_id":"winnow-5azcp",' "")

    grep -F 'CLAIM_DECLINED_LIVE_OWNER' <<<"$out" >/dev/null ||
        fail "an unknown claim reason skipped the guard instead of checking: $out"
}

test_live_owner_is_declined_and_the_step_restored
test_dead_owner_is_a_resume_and_proceeds
test_closed_session_still_listed_is_not_live
test_own_molecule_proceeds_without_probing_liveness
test_unreadable_liveness_fails_closed
test_unresolvable_molecule_proceeds_unguarded
test_work_bead_claim_skips_the_guard
test_preassigned_step_skips_the_walk_entirely
test_unknown_claim_reason_still_checks

echo "polecat live-owner guard tests passed"
