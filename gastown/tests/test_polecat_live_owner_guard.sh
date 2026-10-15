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
# These tests run the live-owner guard out of the polecat claim script
# against a stubbed `gc` and assert that the refusal is now mechanical: a live
# owner is declined and the step restored, a dead owner is not (that is the
# ordinary post-restart resume, and stalling it would stall the engine).
#
# The owner is the molecule's LAST HOLDER, never the WORK bead's assignee (the
# polecat does not claim the work bead; gcp-952j9): the claimed step's own
# polecat_session, else the most recently updated sibling step that names an
# assignee. run_guard seeds that sibling from its `owner` argument.
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
CLAIM_SH="$ROOT/gastown/assets/scripts/polecat-claim.sh"

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

# extract_guard pulls the guard verbatim out of the claim script, so the code
# under test is the code that ships. A drifted or deleted guard fails here
# rather than passing against a stale copy.
extract_guard() {
    local out="$1"
    awk '/^# GUARD_BEGIN live-owner$/{f=1} /^# GUARD_END live-owner$/{f=0} f' "$CLAIM_SH" >"$out"
    [[ -s "$out" ]] || fail "could not extract the live-owner guard from $CLAIM_SH"
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
    "bd list") cat "$GC_LIST_JSON" ;; # gc-bd-argv-tail: case label matching the fake gc's argv tail
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
# the assertion that the polecat never reached the work. The session's identity
# variables are reset so the test runner's own cannot leak in: BEADS_ACTOR is
# the session under test, and SELF_IDS may add its other spellings as
# assignments (GC_SESSION_NAME=... GC_SESSION_ID=...).
run_guard() {
    local dir="$1" owner_assignee="$2" me="$3" step_ref="${4-mol-polecat-work.implement}"
    local root_meta="${5-\"gc.root_bead_id\":\"winnow-5azcp\",}"
    local claim_reason="${6-claimed}"
    # step_tag is the claimed step's own polecat_session; work_assignee seeds an
    # assignee on the WORK bead, which the guard must never read.
    local step_tag="${7-}" work_assignee="${8-}"
    local tag_meta="" work_owner=""
    [[ -z "$step_tag" ]] || tag_meta="\"polecat_session\":\"$step_tag\","
    [[ -z "$work_assignee" ]] || work_owner="\"assignee\":\"$work_assignee\","

    cat >"$dir/root.json" <<'JSON'
[{"id":"winnow-5azcp","status":"in_progress","metadata":{"gc.input_convoy_id":"winnow-0inqp"}}]
JSON
    cat >"$dir/convoy.json" <<'JSON'
{"children":[{"id":"winnow-pcpn6","status":"in_progress"}]}
JSON
    cat >"$dir/work.json" <<JSON
[{"id":"winnow-pcpn6","status":"open",${work_owner}"metadata":{"gc.session_id":"gc-8a4d"}}]
JSON
    # The molecule's steps: an older sibling held by a long-gone session, the
    # last holder named by owner_assignee, and the claimed step itself with a
    # LATER stamp, so a guard that fails to exclude its own step picks us.
    cat >"$dir/list.json" <<JSON
[{"id":"winnow-sib0","status":"closed","assignee":"winnow/gastown.old","updated_at":"2026-09-07T19:00:00Z","metadata":{"gc.root_bead_id":"winnow-5azcp"}},
 {"id":"winnow-sib1","status":"closed","assignee":"$owner_assignee","updated_at":"2026-09-07T20:30:00Z","metadata":{"gc.root_bead_id":"winnow-5azcp"}},
 {"id":"winnow-iaroy","status":"in_progress","assignee":"$me","updated_at":"2026-09-07T20:40:00Z","metadata":{"gc.root_bead_id":"winnow-5azcp"}}]
JSON
    cat >"$dir/guard-harness.sh" <<HARNESS
unset BEADS_ACTOR GC_ALIAS GC_SESSION_ID GC_SESSION_NAME GC_AGENT
BEADS_ACTOR="$me"
${SELF_IDS:-}
WORK_ID="winnow-iaroy"
EXPECTED_ASSIGNEE="$me"
STEP_REF="$step_ref"
CLAIM_REASON="$claim_reason"
SHOW_JSON='[{"id":"winnow-iaroy","status":"in_progress","assignee":"$me","metadata":{${root_meta}${tag_meta}"gc.step_ref":"$step_ref"}}]'
GC_RIG="winnow"
BINDING_PREFIX="gastown."
HARNESS
    cat "$dir/guard.sh" >>"$dir/guard-harness.sh"
    echo 'echo GUARD_PROCEEDED' >>"$dir/guard-harness.sh"

    GC_CALLS="$dir/calls.log" \
        GC_ROOT_BEAD="winnow-5azcp" GC_ROOT_JSON="$dir/root.json" \
        GC_WORK_BEAD="winnow-pcpn6" GC_WORK_JSON="$dir/work.json" GC_LIST_JSON="$dir/list.json" \
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
  {"id":"gc-8a4d","name":"winnow/gastown.furiosa","session_name":"gastown__polecat-gc-8a4d","alias":"winnow/gastown.furiosa","template":"winnow/gastown.polecat","state":"active","closed":false},
  {"id":"gc-psfm","name":"winnow/gastown.nux","session_name":"gastown__polecat-gc-psfm","alias":"winnow/gastown.nux","template":"winnow/gastown.polecat","state":"active","closed":false},
  {"id":"gc-crw1","name":"winnow/specialists.thomas","session_name":"winnow--specialists__thomas","alias":"winnow/specialists.thomas","template":"winnow/specialists.spec","state":"active","closed":false},
  {"id":"gc-ref1","name":"winnow/gastown.refinery","session_name":"winnow--gastown__refinery","alias":"winnow/gastown.refinery","template":"winnow/gastown.refinery","state":"active","closed":false}
]}
JSON
}

test_live_owner_is_declined_and_the_step_restored() {
    local dir out
    dir=$(new_case)
    live_sessions "$dir"

    # The incident, exactly: nux/gc-psfm holds a clean claim on the implement
    # step while furiosa/gc-8a4d last held the molecule and is active.
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
    grep -F 'session nudge winnow/gastown.witness' "$dir/calls.log" >/dev/null ||
        fail "declining polecat did not report the duplicate pour to the witness"
}

# gc reads the step's gc.session_name as a runtime session name. GUARD_OWNER is
# an assignee, which under gc 1.5.0 is the session's alias (namepool polecats)
# or its bead id, never its session_name. Restoring the key from GUARD_OWNER
# binds the step to a session name that does not exist.
test_restore_takes_the_session_name_from_the_live_row() {
    local dir out
    dir=$(new_case)
    live_sessions "$dir"

    out=$(run_guard "$dir" "winnow/gastown.furiosa" "winnow/gastown.nux")

    grep -F 'CLAIM_DECLINED_LIVE_OWNER winnow-iaroy' <<<"$out" >/dev/null ||
        fail "a duplicate pour onto a live owner held by alias was not declined: $out"
    grep -F -- '--assignee=winnow/gastown.furiosa' "$dir/calls.log" >/dev/null ||
        fail "the step was not restored to its owner's assignee spelling"
    grep -F -- '--set-metadata gc.session_name=gastown__polecat-gc-8a4d ' "$dir/calls.log" >/dev/null ||
        fail "the restore did not take gc.session_name from the live session row: $(cat "$dir/calls.log")"
    ! grep -F -- 'gc.session_name=winnow/gastown.furiosa' "$dir/calls.log" >/dev/null ||
        fail "the restore wrote an alias into gc.session_name"

    # Unreadable liveness matched no row, so there is no session name to put
    # back. Clear the key rather than guess one from the assignee.
    dir=$(new_case)
    printf 'not json at all' >"$dir/sessions.json"
    out=$(run_guard "$dir" "winnow/gastown.furiosa" "winnow/gastown.nux")
    grep -F 'CLAIM_DECLINED_LIVE_OWNER' <<<"$out" >/dev/null || fail "unreadable liveness did not decline: $out"
    grep -F -- '--set-metadata gc.session_name= ' "$dir/calls.log" >/dev/null ||
        fail "with no live row the restore must clear gc.session_name: $(cat "$dir/calls.log")"
}

# One session, two spellings. gc 1.4.3 claimed under the runtime session_name;
# a gc 1.5.0 namepool polecat's BEADS_ACTOR is its alias. A molecule straddling
# the upgrade finds its own work bead under the old spelling, and the live row
# for that spelling is THIS session, so a one-string test declines the
# session's own molecule. Upstream #360 (9f98ea4e) settled this for the claim:
# any of BEADS_ACTOR, GC_ALIAS, GC_SESSION_ID, GC_SESSION_NAME, GC_AGENT is us.
test_own_molecule_under_another_spelling_is_not_declined() {
    local dir out
    dir=$(new_case)
    live_sessions "$dir"

    out=$(SELF_IDS="GC_ALIAS=winnow/gastown.nux GC_SESSION_ID=gc-psfm GC_SESSION_NAME=gastown__polecat-gc-psfm GC_AGENT=winnow/gastown.nux" \
        run_guard "$dir" "gastown__polecat-gc-psfm" "winnow/gastown.nux")

    ! grep -F 'CLAIM_DECLINED_LIVE_OWNER' <<<"$out" >/dev/null ||
        fail "the guard declined this session's own molecule held under its session_name: $out"
    grep -F 'GUARD_PROCEEDED' <<<"$out" >/dev/null ||
        fail "the guard did not proceed on this session's own molecule: $out"
    ! grep -F 'session list' "$dir/calls.log" >/dev/null ||
        fail "the guard probed liveness for an owner that is one of this session's own identities"
    ! grep -F -- '--assignee=gastown__polecat-gc-psfm' "$dir/calls.log" >/dev/null ||
        fail "the guard restored the step as if to another owner"
    # Nothing is written: the work bead is not ours to move, and the step is
    # already ours.
    ! grep -F 'bd update' "$dir/calls.log" >/dev/null || # gc-bd-argv-tail: stub call log, not an invocation
        fail "the guard wrote to a bead for this session's own molecule: $(cat "$dir/calls.log")"
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

test_non_step_claim_skips_the_guard() {
    local dir out
    dir=$(new_case)
    live_sessions "$dir"

    # No gc.step_ref means the claim is not a formula step, so there is no
    # molecule to find a last holder in, and the lookup would be wasted reads on
    # the hot startup path.
    out=$(run_guard "$dir" "gastown__polecat-gc-8a4d" "gastown__polecat-gc-psfm" "")

    grep -F 'GUARD_PROCEEDED' <<<"$out" >/dev/null ||
        fail "a claim carrying no gc.step_ref was blocked by the step guard: $out"
    [[ ! -s "$dir/calls.log" ]] ||
        fail "the guard read bead state for a claim carrying no gc.step_ref: $(cat "$dir/calls.log")"
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

# gcp-qjkp: a crew, specialist or mayor seat is always live and never runs
# polecat steps. When one is the molecule's last holder it is the slinger, not a
# worker, and declining would hand the step to a seat that will not run it. Only
# a live POLECAT or REFINERY owner is a worker.
test_live_crew_owner_is_the_slinger_and_proceeds() {
    local dir out
    dir=$(new_case)
    live_sessions "$dir"

    out=$(run_guard "$dir" "winnow/specialists.thomas" "winnow/gastown.nux")

    grep -F 'GUARD_PROCEEDED' <<<"$out" >/dev/null ||
        fail "a live crew owner stalled the molecule: $out"
    ! grep -F 'CLAIM_DECLINED_LIVE_OWNER' <<<"$out" >/dev/null ||
        fail "a live crew owner was declined as a duplicate pour: $out"
    grep -F 'a live winnow/specialists.spec session: that is the slinger, not a worker; proceeding.' <<<"$out" >/dev/null ||
        fail "proceeding past a live crew owner was not announced: $out"
    ! grep -F 'bd update winnow-iaroy' "$dir/calls.log" >/dev/null || # gc-bd-argv-tail: stub call log, not an invocation
        fail "the step was handed to the crew seat: $(cat "$dir/calls.log")"
    ! grep -F 'session nudge' "$dir/calls.log" >/dev/null ||
        fail "the guard nudged the witness about a crew slinger"
    ! grep -F 'runtime drain-ack' "$dir/calls.log" >/dev/null ||
        fail "the guard drained on a crew slinger"
}

# The WORK bead is unclaimed for the whole run, so with nobody on it the guard
# must still find a duplicate pour: a live polecat last held the molecule.
test_duplicate_pour_declines_with_the_work_bead_unclaimed() {
    local dir out
    dir=$(new_case)
    live_sessions "$dir"

    out=$(run_guard "$dir" "winnow/gastown.furiosa" "winnow/gastown.nux")

    ! grep -F '"assignee"' "$dir/work.json" >/dev/null ||
        fail "fixture error: the work bead should be unassigned"
    grep -F 'CLAIM_DECLINED_LIVE_OWNER winnow-iaroy' <<<"$out" >/dev/null ||
        fail "a duplicate pour was not declined with the work bead unclaimed: $out"
    grep -F 'molecule winnow-5azcp was last held by winnow/gastown.furiosa' <<<"$out" >/dev/null ||
        fail "decline did not name the molecule's last holder: $out"
    ! grep -F 'GUARD_PROCEEDED' <<<"$out" >/dev/null ||
        fail "guard declined but still fell through to the work"
}

# A released step keeps its own polecat_session (ReleaseIfCurrent touches only
# status and assignee), so that stamp names the holder before any sibling does.
test_released_step_names_its_own_last_holder() {
    local dir out
    dir=$(new_case)
    live_sessions "$dir"

    # The siblings say the crew seat; the step's own stamp says furiosa. The
    # stamp wins, and the sibling lookup is never made.
    out=$(run_guard "$dir" "winnow/specialists.thomas" "winnow/gastown.nux" \
        "mol-polecat-work.implement" '"gc.root_bead_id":"winnow-5azcp",' "claimed" \
        "gastown__polecat-gc-8a4d")

    grep -F 'CLAIM_DECLINED_LIVE_OWNER winnow-iaroy' <<<"$out" >/dev/null ||
        fail "a released step did not name its own last holder: $out"
    grep -F 'was last held by gastown__polecat-gc-8a4d' <<<"$out" >/dev/null ||
        fail "decline named the sibling instead of the step's own stamp: $out"
    ! grep -F -- '--metadata-field' "$dir/calls.log" >/dev/null ||
        fail "the guard listed sibling steps although the step named its holder: $(cat "$dir/calls.log")"
}

# A crew seat on the WORK bead is the slinger's name, not a holder's. The guard
# must not read it, so it neither declines on it nor takes it over.
test_crew_assignee_on_the_work_bead_is_never_read() {
    local dir out
    dir=$(new_case)
    live_sessions "$dir"

    # The last holder is a dead polecat: an ordinary resume.
    out=$(run_guard "$dir" "gastown__polecat-gc-dead" "winnow/gastown.nux" \
        "mol-polecat-work.implement" '"gc.root_bead_id":"winnow-5azcp",' "claimed" \
        "" "winnow/specialists.thomas")

    grep -F 'GUARD_PROCEEDED' <<<"$out" >/dev/null ||
        fail "a crew assignee on the work bead stalled the resume: $out"
    ! grep -F 'CLAIM_DECLINED_LIVE_OWNER' <<<"$out" >/dev/null ||
        fail "a crew assignee on the work bead was read as the holder: $out"
    ! grep -F 'winnow-pcpn6' "$dir/calls.log" >/dev/null ||
        fail "the guard touched the work bead: $(cat "$dir/calls.log")"
}

test_live_refinery_owner_is_still_declined() {
    local dir out
    dir=$(new_case)
    live_sessions "$dir"

    out=$(run_guard "$dir" "winnow/gastown.refinery" "winnow/gastown.nux")

    grep -F 'CLAIM_DECLINED_LIVE_OWNER winnow-iaroy' <<<"$out" >/dev/null ||
        fail "a live refinery owner was not declined: $out"
    ! grep -F 'GUARD_PROCEEDED' <<<"$out" >/dev/null ||
        fail "guard declined but still fell through to the work"
    grep -F 'bd update winnow-iaroy --assignee=winnow/gastown.refinery' "$dir/calls.log" >/dev/null || # gc-bd-argv-tail: stub call log, not an invocation
        fail "the step was not restored to the refinery: $(cat "$dir/calls.log")"
}

# A live row with no template cannot be classified. It is treated like a worker,
# which is how every live owner was treated before the template check.
test_live_owner_without_a_template_fails_closed() {
    local dir out
    dir=$(new_case)
    cat >"$dir/sessions.json" <<'JSON'
{"sessions":[{"id":"gc-8a4d","name":"winnow/gastown.furiosa","session_name":"gastown__polecat-gc-8a4d","state":"active","closed":false}]}
JSON

    out=$(run_guard "$dir" "gastown__polecat-gc-8a4d" "gastown__polecat-gc-psfm")

    grep -F 'CLAIM_DECLINED_LIVE_OWNER' <<<"$out" >/dev/null ||
        fail "a live owner with no template was not declined: $out"
    ! grep -F 'GUARD_PROCEEDED' <<<"$out" >/dev/null ||
        fail "guard fell through on a live owner it could not classify"
}

test_live_owner_is_declined_and_the_step_restored
test_restore_takes_the_session_name_from_the_live_row
test_dead_owner_is_a_resume_and_proceeds
test_own_molecule_under_another_spelling_is_not_declined
test_closed_session_still_listed_is_not_live
test_own_molecule_proceeds_without_probing_liveness
test_unreadable_liveness_fails_closed
test_unresolvable_molecule_proceeds_unguarded
test_non_step_claim_skips_the_guard
test_preassigned_step_skips_the_walk_entirely
test_unknown_claim_reason_still_checks
test_live_crew_owner_is_the_slinger_and_proceeds
test_live_refinery_owner_is_still_declined
test_live_owner_without_a_template_fails_closed
test_duplicate_pour_declines_with_the_work_bead_unclaimed
test_released_step_names_its_own_last_holder
test_crew_assignee_on_the_work_bead_is_never_read

echo "polecat live-owner guard tests passed"
