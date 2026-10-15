#!/usr/bin/env bash
# Tests for gastown/assets/scripts/polecat-submit.sh, the one script behind the
# push gate and the refinery handoff of mol-polecat-work's submit-and-exit step
# (gcp-nc8wg).
#
# The two fences used to be 302 and 64 lines of shell that every polecat
# retyped. They now ship as one script with a `push-gate` and a `reassign`
# mode, and the step carries a short stub for each that locates the script and
# passes {{convoy_id}}, {{base_branch}} and {{binding_prefix}} as PS_* env.
# These tests run the real script and the real stubs, decoded from the formula,
# against stub `gc` and `git`. Their identity with the old fences was proven by a
# throwaway harness, which is not committed; test_polecat_push_gate.sh covers
# the gate's outcomes and test_polecat_handoff_stamp.sh the handoff stamp.
#
# What is pinned here is what those two do not reach: the interface (usage,
# required env), the ids the script derives for itself (the old fences inherited
# WORK_BEAD_ID and CURRENT_BRANCH from earlier fences, which a fresh shell does
# not have), the arguments reaching the writes, and the stubs' unresolved-script
# stop, which must close the step before it acks the drain.
#
# No test depends on wall-clock time or on a network: every external command is
# a stub, and stdin is /dev/null.
# shellcheck disable=SC2016  # the assertions grep literal $VAR text
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
SUBMIT="$ROOT/gastown/assets/scripts/polecat-submit.sh"
FORMULA="$ROOT/gastown/formulas/mol-polecat-work.toml"
USAGE_LINE='SUBMIT_USAGE polecat-submit.sh push-gate|reassign'

if ! command -v jq >/dev/null 2>&1; then
    echo "  skip  jq not available (the script's own probes need it)"
    exit 0
fi

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

STEP_REF='mol-polecat-work.submit-and-exit'
WORK_OPEN='[{"id":"w-1","status":"open","assignee":"","metadata":{},"description":"Add a retry to the ingest job when the API 429s.","notes":""}]'

# new_case <name> — a fresh sandbox $CASE with a stub `gc` and `git` in
# $CASE/bin that journal every call to $CASE/calls.log. The work bead the stubs
# serve is $CASE/work.json (set_work), the step bead is $CASE/step.json, and the
# convoy names one child, w-1. `gc formula list --json` prints $FORMULAS.
new_case() {
    CASE="$TMPROOT/$1"
    mkdir -p "$CASE/bin" "$CASE/cwd"
    : >"$CASE/calls.log"
    printf '[{"id":"w-1.s9","status":"in_progress","metadata":{"gc.step_ref":"%s"}}]' "$STEP_REF" >"$CASE/step.json"
    printf '%s' "$WORK_OPEN" >"$CASE/work.json"
    cat >"$CASE/bin/gc" <<'SH'
#!/usr/bin/env bash
printf 'gc %s\n' "$*" >>"$CASE/calls.log"
case "${1:-}:${2:-}" in
    formula:list) printf '%s\n' "$FORMULAS" ;;
    convoy:status) printf '%s\n' "$CONVOY" ;;
    hook:current) printf '%s\n' "${HOOK_CURRENT-w-1.s9}" ;;
    bd:show)
        case "$3" in
            w-1.s9) cat "$CASE/step.json" ;;
            *) cat "$CASE/work.json" ;;
        esac ;;
    bd:note) cat >>"$CASE/note.txt" ;;
    bd:update)
        if [ -n "${REFUSE_HANDOFF:-}" ]; then
            case "$*" in
                *"--assignee=testrig/"* | *"--assignee=gastown."*) echo "Error: another actor holds the claim" >&2; exit 1 ;;
            esac
        fi ;;
esac
exit 0
SH
    cat >"$CASE/bin/git" <<'SH'
#!/usr/bin/env bash
printf 'git %s\n' "$*" >>"$CASE/calls.log"
case "${1:-} ${2:-}" in
    "branch --show-current") echo "${GIT_BRANCH-polecat/w-1}" ;;
    "show-ref --verify") [ "${BASE_REMOTE:-1}" = 1 ] || exit 1 ;;
    "push origin") exit "${PUSH_RC:-0}" ;;
    "ls-remote origin") printf 'deadbeef\t%s\n' "$3" ;;
    "rev-parse HEAD") echo deadbeef ;;
esac
exit 0
SH
    chmod +x "$CASE/bin/gc" "$CASE/bin/git"
    FORMULAS='{"formulas":[]}'
    CONVOY='{"children":[{"id":"w-1"}]}'
}

set_work() { printf '%s' "$1" >"$CASE/work.json"; }

# run_submit <argv...> -- <env...> — runs the script from $CASE/cwd with only the
# given env (plus the stub plumbing), so a caller's PS_*, WORK_BEAD_ID or
# GC_RIG cannot leak in. Sets RC and leaves stdout and stderr in $CASE/out and
# $CASE/err.
run_submit() {
    local -a args=()
    while [ "$#" -gt 0 ] && [ "$1" != "--" ]; do
        args+=("$1")
        shift
    done
    [ "$#" -gt 0 ] && shift
    RC=0
    (
        cd "$CASE/cwd" &&
            env -i PATH="$CASE/bin:$PATH" HOME="$CASE" GIT_CONFIG_GLOBAL=/dev/null \
                CASE="$CASE" FORMULAS="$FORMULAS" CONVOY="$CONVOY" "$@" \
                bash "$SUBMIT" ${args[@]+"${args[@]}"} </dev/null
    ) >"$CASE/out" 2>"$CASE/err" || RC=$?
}

# The env the stubs pass for a normal pour of the push gate and the handoff.
PUSH_ENV=(PS_CONVOY_ID=gcp-convoy PS_BASE_BRANCH=main PS_BINDING_PREFIX=gastown. GC_RIG=testrig)
REASSIGN_ENV=(PS_CONVOY_ID=gcp-convoy PS_BINDING_PREFIX=gastown. GC_RIG=testrig)

calls() { cat "$CASE/calls.log"; }

# called <fixed-string> — fails unless some call in the log contains it.
called() {
    grep -qF -- "$1" "$CASE/calls.log" || fail "want a call containing '$1', calls: $(calls)"
}
never_called() {
    ! grep -qF -- "$1" "$CASE/calls.log" || fail "want no call containing '$1', calls: $(calls)"
}
# line_of <fixed-string> — the line number of the first call containing it, or 0.
line_of() {
    local n
    n=$(grep -nF -- "$1" "$CASE/calls.log" | head -1 | cut -d: -f1) || true
    echo "${n:-0}"
}

# own_step_closed_before_drain — the guarded close of the running step, then the ack.
own_step_closed_before_drain() {
    local hook show close drain
    hook=$(line_of 'gc hook current --id-only')
    show=$(line_of 'gc bd show w-1.s9 --json')
    close=$(line_of 'gc bd update w-1.s9 --set-metadata gc.outcome=fail')
    drain=$(line_of 'gc runtime drain-ack')
    [ "$hook" -gt 0 ] && [ "$show" -gt "$hook" ] && [ "$close" -gt "$show" ] && [ "$drain" -gt "$close" ] ||
        fail "$1: want hook current < show step < close step < drain-ack, got $hook $show $close $drain: $(calls)"
    grep -qF -- "gc bd update w-1.s9 --set-metadata gc.outcome=fail --set-metadata gc.failure_class=hard --set-metadata gc.failure_reason=$2 --status=closed" "$CASE/calls.log" ||
        fail "$1: want the step closed with gc.failure_reason=$2, calls: $(calls)"
}

test_script_holds_no_formula_placeholder() {
    [ "$(grep -c '{{' "$SUBMIT")" = 0 ] || fail "$SUBMIT must hold no {{...}}: gc renders the step text, not the script"
    bash -n "$SUBMIT" || fail "the script is not valid bash"
}

# The shell the script replaced must not also stay in the step: two copies drift.
test_step_text_carries_no_second_copy() {
    python3 -I - "$FORMULA" <<'PY' || fail "the step still carries shell the script now runs"
import sys
import tomllib

doc = tomllib.load(open(sys.argv[1], "rb"))
text = next(s["description"] for s in doc["steps"] if s["id"] == "submit-and-exit")
problems = [m for m in (
    "git push origin HEAD", "RAIL_HIT", "META_UNREADABLE", "HANDOFF_STAMP", "handoff-stamp:begin",
    "PUSH VERIFICATION FAILED", 'HANDOFF_STATUS=',
) if m in text]
if problems:
    sys.exit(f"still in the step text: {problems}")
if text.count('bash "$PS" push-gate') != 1 or text.count('bash "$PS" reassign') != 1:
    sys.exit("want exactly one push-gate call and one reassign call")
PY
}

test_usage_rejects_unknown_mode() {
    local label
    new_case usage
    for label in none bogus extra; do
        : >"$CASE/calls.log"
        case "$label" in
            none) run_submit -- "${PUSH_ENV[@]}" ;;
            bogus) run_submit bogus -- "${PUSH_ENV[@]}" ;;
            extra) run_submit push-gate reassign -- "${PUSH_ENV[@]}" ;;
        esac
        [ "$RC" -eq 2 ] || fail "$label: want exit 2, got $RC"
        [ "$(cat "$CASE/out")" = "$USAGE_LINE" ] ||
            fail "$label: want exactly '$USAGE_LINE' on stdout, got: $(cat "$CASE/out")"
        [ ! -s "$CASE/err" ] || fail "$label: want empty stderr, got: $(cat "$CASE/err")"
        [ ! -s "$CASE/calls.log" ] || fail "$label: a usage error must run nothing, calls: $(calls)"
    done
}

test_unset_required_var_stops() {
    new_case unset
    # PS_CONVOY_ID unset: the script cannot tell which bead it is for.
    run_submit push-gate -- PS_BASE_BRANCH=main PS_BINDING_PREFIX=gastown. GC_RIG=testrig
    [ "$RC" -ne 0 ] || fail "want a non-zero exit with PS_CONVOY_ID unset, got 0"
    grep -q 'PS_CONVOY_ID' "$CASE/err" || fail "want stderr to name PS_CONVOY_ID, got: $(cat "$CASE/err")"
    [ ! -s "$CASE/calls.log" ] || fail "an unset PS_CONVOY_ID must run nothing, calls: $(calls)"

    # PS_BASE_BRANCH empty: push-gate would test refs/remotes/origin/ and push anyway.
    run_submit push-gate -- PS_CONVOY_ID=gcp-convoy PS_BASE_BRANCH= PS_BINDING_PREFIX=gastown. GC_RIG=testrig
    [ "$RC" -ne 0 ] || fail "want a non-zero exit with PS_BASE_BRANCH empty, got 0"
    grep -q 'PS_BASE_BRANCH' "$CASE/err" || fail "want stderr to name PS_BASE_BRANCH, got: $(cat "$CASE/err")"
    [ ! -s "$CASE/calls.log" ] || fail "an empty PS_BASE_BRANCH must run nothing, calls: $(calls)"

    # PS_BINDING_PREFIX unset is an error, but EMPTY is a legal value: the pack
    # is not bound, and the refinery's identity has no prefix.
    run_submit reassign -- PS_CONVOY_ID=gcp-convoy GC_RIG=testrig
    [ "$RC" -ne 0 ] || fail "want a non-zero exit with PS_BINDING_PREFIX unset, got 0"
    grep -q 'PS_BINDING_PREFIX' "$CASE/err" || fail "want stderr to name PS_BINDING_PREFIX, got: $(cat "$CASE/err")"
    [ ! -s "$CASE/calls.log" ] || fail "an unset PS_BINDING_PREFIX must run nothing, calls: $(calls)"

    set_work "$WORK_OPEN"
    run_submit reassign -- PS_CONVOY_ID=gcp-convoy PS_BINDING_PREFIX= GC_RIG=testrig
    [ "$RC" -eq 0 ] || fail "an empty PS_BINDING_PREFIX must pass, got $RC: $(cat "$CASE/err")"
    called 'gc bd update w-1 --status=open --assignee=testrig/refinery'
}

# The old fences read WORK_BEAD_ID and CURRENT_BRANCH from the section-1 fence.
# The script gets them itself, so it runs from a fresh shell, and a stale value
# in the caller's environment never reaches a write.
test_ids_are_derived_not_inherited() {
    new_case ids
    CONVOY='{"children":[{"id":"w-7"}]}'
    run_submit push-gate -- "${PUSH_ENV[@]}" WORK_BEAD_ID=poison CURRENT_BRANCH=poison GIT_BRANCH=polecat/w-7
    [ "$RC" -eq 0 ] || fail "want exit 0, got $RC: $(cat "$CASE/err")"
    called 'gc convoy status gcp-convoy --json'
    called 'gc bd show w-7 --json'
    called 'git push origin HEAD'
    called 'git ls-remote origin refs/heads/polecat/w-7'
    never_called poison

    new_case ids-reassign
    CONVOY='{"children":[{"id":"w-7"}]}'
    run_submit reassign -- "${REASSIGN_ENV[@]}" WORK_BEAD_ID=poison
    [ "$RC" -eq 0 ] || fail "want exit 0, got $RC: $(cat "$CASE/err")"
    called 'gc bd update w-7 --status=open --assignee=testrig/gastown.refinery'
    never_called poison
}

# A convoy that does not name exactly one work bead is not a state the old flow
# could reach (sections 0 and 1 stop on it), so the script stops before it
# writes anything and without a drain: the call can be run again.
test_convoy_without_one_work_bead_stops_before_any_write() {
    local mode label
    for mode in push-gate reassign; do
        for label in no-child two-children unreadable; do
            new_case "convoy-$mode-$label"
            case "$label" in
                no-child) CONVOY='{"children":[]}' ;;
                two-children) CONVOY='{"children":[{"id":"w-1"},{"id":"w-2"}]}' ;;
                unreadable) CONVOY='' ;;
            esac
            if [ "$mode" = push-gate ]; then
                run_submit "$mode" -- "${PUSH_ENV[@]}"
            else
                run_submit "$mode" -- "${REASSIGN_ENV[@]}"
            fi
            [ "$RC" -eq 1 ] || fail "$mode/$label: want exit 1, got $RC"
            grep -q '^STOP: convoy gcp-convoy does not name exactly one work bead' "$CASE/out" ||
                fail "$mode/$label: want the STOP line, got: $(cat "$CASE/out")"
            never_called 'gc bd update'
            never_called 'drain-ack'
            never_called 'git push'
            never_called 'mail send'
        done
    done
}

test_push_gate_pushes_on_the_normal_path() {
    new_case normal
    run_submit push-gate -- "${PUSH_ENV[@]}"
    [ "$RC" -eq 0 ] || fail "want exit 0, got $RC: $(cat "$CASE/err")"
    called 'git fetch --prune origin'
    called 'git show-ref --verify --quiet refs/remotes/origin/main'
    called 'git push origin HEAD'
    never_called 'halt_reason'
    never_called 'drain-ack'
    never_called 'mail send'
}

# {{base_branch}} reaches the base-branch precondition, the recorded target and
# the local-only message through PS_BASE_BRANCH, and nothing else stands in.
test_push_gate_uses_the_base_branch_it_is_given() {
    new_case base
    run_submit push-gate -- PS_CONVOY_ID=gcp-convoy PS_BASE_BRANCH=release/2.x PS_BINDING_PREFIX=gastown. GC_RIG=testrig
    [ "$RC" -eq 0 ] || fail "want exit 0, got $RC: $(cat "$CASE/err")"
    called 'git show-ref --verify --quiet refs/remotes/origin/release/2.x'
    called 'git push origin HEAD'

    new_case base-optout
    set_work '[{"id":"w-1","status":"in_progress","assignee":"","metadata":{"auto_push":"false"},"description":"","notes":""}]'
    run_submit push-gate -- PS_CONVOY_ID=gcp-convoy PS_BASE_BRANCH=release/2.x PS_BINDING_PREFIX=gastown. GC_RIG=testrig
    called '--set-metadata target=release/2.x'
    called '--set-metadata branch=polecat/w-1'
    never_called 'git push'

    new_case base-local-only
    run_submit push-gate -- PS_CONVOY_ID=gcp-convoy PS_BASE_BRANCH=release/2.x PS_BINDING_PREFIX=gastown. GC_RIG=testrig BASE_REMOTE=0
    [ "$RC" -eq 0 ] || fail "want exit 0, got $RC: $(cat "$CASE/err")"
    grep -qx 'base branch release/2.x is local-only: halting at branch-ready (no push, no refinery handoff)' "$CASE/out" ||
        fail "want the local-only line naming release/2.x, got: $(cat "$CASE/out")"
    called '--set-metadata target=release/2.x'
    called '--set-metadata halt_reason=base_branch_local_only'
    called 'Branch ready: base branch release/2.x does not exist on origin'
    never_called 'git push'
    own_step_closed_before_drain "base-local-only" base_branch_local_only
}

# {{binding_prefix}} and GC_RIG build the witness the escalations go to.
test_witness_target_follows_the_rig_and_the_binding_prefix() {
    new_case witness
    set_work ''
    run_submit push-gate -- "${PUSH_ENV[@]}"
    [ "$RC" -eq 0 ] || fail "want exit 0, got $RC: $(cat "$CASE/err")"
    called 'gc mail send testrig/gastown.witness -s HELP: push-gate metadata unreadable on w-1 [HIGH]'

    new_case witness-no-rig
    set_work ''
    run_submit push-gate -- PS_CONVOY_ID=gcp-convoy PS_BASE_BRANCH=main PS_BINDING_PREFIX=gastown.
    called 'gc mail send gastown.witness -s HELP: push-gate metadata unreadable on w-1 [HIGH]'

    new_case witness-unbound
    set_work ''
    run_submit push-gate -- PS_CONVOY_ID=gcp-convoy PS_BASE_BRANCH=main PS_BINDING_PREFIX= GC_RIG=testrig
    called 'gc mail send testrig/witness -s HELP: push-gate metadata unreadable on w-1 [HIGH]'
}

# A rail scan that cannot finish is an asserted rail: grep that dies prints
# nothing, RAIL_HIT stays empty, and the empty-result default must halt.
test_rail_scan_fails_closed_when_the_match_stage_dies() {
    new_case rail-default
    printf '#!/usr/bin/env bash\nexit 2\n' >"$CASE/bin/grep"
    chmod +x "$CASE/bin/grep"
    run_submit push-gate -- "${PUSH_ENV[@]}"
    [ "$RC" -eq 0 ] || fail "want exit 0, got $RC: $(cat "$CASE/err")"
    grep -q '^NO-PUSH RAIL IN PROSE + auto_push ABSENT' "$CASE/out" ||
        fail "want the no-push-rail halt, got: $(cat "$CASE/out")"
    called '--set-metadata halt_reason=no_push_rail_unresolved'
    never_called 'git push'
    own_step_closed_before_drain "rail-default" no_push_rail_unresolved
}

# Every halt closes the running step before it acks the drain, and refuses to
# ack when the hook names anything but this in-progress submit-and-exit step.
test_halts_close_the_step_before_draining() {
    new_case halt-close
    set_work '[{"id":"w-1","status":"in_progress","assignee":"","metadata":{"auto_push":"no"},"description":"","notes":""}]'
    run_submit push-gate -- "${PUSH_ENV[@]}"
    [ "$RC" -eq 0 ] || fail "want exit 0, got $RC: $(cat "$CASE/err")"
    called '--set-metadata halt_reason=auto_push_false'
    own_step_closed_before_drain "opt-out halt" auto_push_false

    new_case halt-wrong-step
    set_work '[{"id":"w-1","status":"in_progress","assignee":"","metadata":{"auto_push":"no"},"description":"","notes":""}]'
    run_submit push-gate -- "${PUSH_ENV[@]}" HOOK_CURRENT=w-1
    [ "$RC" -eq 1 ] || fail "a hook that names the work bead must stop with exit 1, got $RC"
    grep -q 'is not this in-progress step; not acknowledging drain' "$CASE/err" ||
        fail "want the not-this-step message on stderr, got: $(cat "$CASE/err")"
    never_called 'drain-ack'
    never_called 'gc bd update w-1.s9'

    new_case push-failed
    run_submit push-gate -- "${PUSH_ENV[@]}" PUSH_RC=1
    [ "$RC" -eq 1 ] || fail "a failed push must exit 1, got $RC"
    grep -q '^PUSH FAILED (exit 1)' "$CASE/out" || fail "want PUSH FAILED, got: $(cat "$CASE/out")"
    own_step_closed_before_drain "push failed" push_failed
}

test_reassign_hands_the_work_bead_to_the_refinery() {
    new_case handoff
    run_submit reassign -- "${REASSIGN_ENV[@]}"
    [ "$RC" -eq 0 ] || fail "want exit 0, got $RC: $(cat "$CASE/err")"
    local update
    update=$(grep -F 'gc bd update w-1 --status=open --assignee=testrig/gastown.refinery' "$CASE/calls.log") ||
        fail "want the handoff write to testrig/gastown.refinery, calls: $(calls)"
    [[ "$update" == *'--set-metadata gc.routed_to= '* ]] || fail "the handoff must clear gc.routed_to: $update"
    [[ "$update" == *'--set-metadata last_submitted_at='* && "$update" == *'--set-metadata first_submitted_at='* ]] ||
        fail "the first handoff must carry both stamps: $update"
    never_called 'drain-ack'
    never_called 'gc bd note'

    new_case handoff-unbound-no-rig
    run_submit reassign -- PS_CONVOY_ID=gcp-convoy PS_BINDING_PREFIX=gastown.
    called 'gc bd update w-1 --status=open --assignee=gastown.refinery'
}

test_reassign_leaves_a_human_routed_bead_alone() {
    new_case human
    set_work '[{"id":"w-1","status":"open","assignee":"","metadata":{"gc.routed_to":"human"},"description":"","notes":""}]'
    run_submit reassign -- "${REASSIGN_ENV[@]}"
    [ "$RC" -eq 0 ] || fail "want exit 0, got $RC: $(cat "$CASE/err")"
    grep -q '^HANDOFF HALTED: w-1 is routed to human' "$CASE/out" || fail "want HANDOFF HALTED, got: $(cat "$CASE/out")"
    never_called '--assignee='
    called 'gc bd note w-1 --stdin'
    grep -q 'gc.routed_to=human' "$CASE/note.txt" || fail "want the note to name the escalation, got: $(cat "$CASE/note.txt")"
    own_step_closed_before_drain "human halt" routed_to_human
}

test_reassign_refused_write_is_a_failed_handoff() {
    new_case refused
    run_submit reassign -- "${REASSIGN_ENV[@]}" REFUSE_HANDOFF=1
    [ "$RC" -eq 1 ] || fail "a refused handoff must exit 1, got $RC"
    grep -q '^HANDOFF_FAILED w-1 was NOT handed to testrig/gastown.refinery' "$CASE/out" ||
        fail "want HANDOFF_FAILED naming the refinery, got: $(cat "$CASE/out")"
    never_called 'drain-ack'
    never_called 'gc bd update w-1.s9'
}

# render_stub <call-fragment> <outfile> — the bash fence of the step that holds
# that call, with every {{var}} replaced the way gc renders the step. A {{var}}
# left over is a hard error.
render_stub() {
    python3 -I - "$FORMULA" "$@" <<'PY'
import re
import sys
import tomllib

formula, call, out = sys.argv[1:4]
values = {"base_branch": "main", "binding_prefix": "gastown.", "convoy_id": "gcp-convoy"}
doc = tomllib.load(open(formula, "rb"))
text = next(s["description"] for s in doc["steps"] if s["id"] == "submit-and-exit")
stubs = [f for f in re.findall(r"```bash\n(.*?)\n```", text, re.S) if call in f]
if len(stubs) != 1:
    sys.exit(f"want exactly one fence calling {call!r}, found {len(stubs)}")
rendered = re.sub(r"\{\{(\w+)\}\}", lambda m: values.get(m.group(1), m.group(0)), stubs[0])
left = sorted(set(re.findall(r"\{\{\w+\}\}", rendered)))
if left:
    sys.exit(f"unrendered placeholders in the stub: {left}")
open(out, "w").write(rendered + "\n")
PY
}

# run_stub <stubfile> <env...> — runs a rendered stub from $CASE/cwd.
run_stub() {
    local stub="$1"
    shift
    RC=0
    (
        cd "$CASE/cwd" &&
            env -i PATH="$CASE/bin:$PATH" HOME="$CASE" GIT_CONFIG_GLOBAL=/dev/null \
                CASE="$CASE" FORMULAS="$FORMULAS" CONVOY="$CONVOY" GC_RIG=testrig "$@" \
                bash "$stub" </dev/null
    ) >"$CASE/out" 2>"$CASE/err" || RC=$?
}

# The drain-ack contract (tests/test_v2_drain_ack_closes_own_step.py): a stub
# that cannot find the script closes its own step, fail, and then acks.
test_stubs_stop_and_close_the_step_when_the_script_is_unresolved() {
    local call mode reason
    for call in 'bash "$PS" push-gate' 'bash "$PS" reassign'; do
        mode=${call##* }
        new_case "stub-missing-$mode"
        render_stub "$call" "$CASE/stub.sh" || fail "$mode: could not render the stub"
        # `gc formula list --json` finds no formula, so the script cannot be located.
        run_stub "$CASE/stub.sh"
        [ "$RC" -eq 1 ] || fail "$mode: want exit 1, got $RC: $(cat "$CASE/err")"
        grep -q '^STOP: submit script not found' "$CASE/out" ||
            fail "$mode: want a line starting 'STOP: submit script not found', got: $(cat "$CASE/out")"
        own_step_closed_before_drain "$mode stub" submit_script_missing
        never_called 'git push'
        never_called 'gc bd update w-1 '
        never_called 'convoy status'
        reason=$(grep -c 'drain-ack' "$CASE/calls.log")
        [ "$reason" = 1 ] || fail "$mode: want exactly one drain-ack, got $reason"
    done
}

test_stubs_run_the_script_the_formula_resolves() {
    new_case stub-resolves
    FORMULAS='{"formulas":[{"name":"mol-polecat-work","source":"'"$FORMULA"'"}]}'
    render_stub 'bash "$PS" push-gate' "$CASE/push.sh" || fail "could not render the push-gate stub"
    run_stub "$CASE/push.sh"
    [ "$RC" -eq 0 ] || fail "push-gate stub: want exit 0, got $RC: $(cat "$CASE/out") $(cat "$CASE/err")"
    called 'gc convoy status gcp-convoy --json'
    called 'git show-ref --verify --quiet refs/remotes/origin/main'
    called 'git push origin HEAD'

    new_case stub-resolves-reassign
    FORMULAS='{"formulas":[{"name":"mol-polecat-work","source":"'"$FORMULA"'"}]}'
    render_stub 'bash "$PS" reassign' "$CASE/reassign.sh" || fail "could not render the reassign stub"
    run_stub "$CASE/reassign.sh"
    [ "$RC" -eq 0 ] || fail "reassign stub: want exit 0, got $RC: $(cat "$CASE/out") $(cat "$CASE/err")"
    called 'gc bd update w-1 --status=open --assignee=testrig/gastown.refinery'
}

test_script_holds_no_formula_placeholder
test_step_text_carries_no_second_copy
test_usage_rejects_unknown_mode
test_unset_required_var_stops
test_ids_are_derived_not_inherited
test_convoy_without_one_work_bead_stops_before_any_write
test_push_gate_pushes_on_the_normal_path
test_push_gate_uses_the_base_branch_it_is_given
test_witness_target_follows_the_rig_and_the_binding_prefix
test_rail_scan_fails_closed_when_the_match_stage_dies
test_halts_close_the_step_before_draining
test_reassign_hands_the_work_bead_to_the_refinery
test_reassign_leaves_a_human_routed_bead_alone
test_reassign_refused_write_is_a_failed_handoff
test_stubs_stop_and_close_the_step_when_the_script_is_unresolved
test_stubs_run_the_script_the_formula_resolves
echo "polecat submit tests passed"
