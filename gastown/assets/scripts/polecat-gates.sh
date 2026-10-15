#!/usr/bin/env bash
# polecat-gates.sh preflight|self-review
#
# The quality gates of mol-polecat-work, run as one script so the polecat makes
# one short call and does not retype them. "preflight" is the preflight-tests
# step's gates on the base branch; "self-review" is the self-review step's
# section 2 (BASE_REF must be exported by the caller).
#
# Inputs, set by the formula step in the environment of this call (an empty
# value is allowed; an unset one stops the script):
#   preflight:   PG_BASE_BRANCH PG_BINDING_PREFIX PG_CONVOY_ID
#                PG_TYPECHECK_COMMAND PG_LINT_COMMAND
#   self-review: PG_SETUP_COMMAND PG_TYPECHECK_COMMAND PG_LINT_COMMAND
#                PG_BUILD_COMMAND PG_TEST_COMMAND PG_AFFECTED_TESTS_COMMAND
# Env also read: GC_CITY GC_CITY_PATH GC_PACK_DIR GC_RIG
#
# The resolve-known-red, gate-run and known-red-phase-skip blocks are shared by
# both modes. Their sentinel lines let the tests extract them.

if [ "$#" -ne 1 ] || { [ "$1" != preflight ] && [ "$1" != self-review ]; }; then
    echo "GATES_USAGE polecat-gates.sh preflight|self-review"
    exit 2
fi
# --- resolve-known-red:begin ---
# resolve_known_red <formula> prints the path of the pack's known-red and
# returns 0, or returns 1. The named formula's own source anchors the pack, so
# the matcher is always the copy shipped beside the formula being run.
# GC_PACK_DIR is only a fallback, because gc exports it to pack commands and
# not to agent shells.
resolve_known_red() {
    rkr_rel="assets/scripts/known-red"
    rkr_city="${GC_CITY:-${GC_CITY_PATH:-}}"
    if [ -n "$rkr_city" ]; then
        rkr_json=$(gc formula list --city "$rkr_city" --json 2>/dev/null)
    else
        rkr_json=$(gc formula list --json 2>/dev/null)
    fi
    rkr_src=$(printf '%s' "$rkr_json" |
        jq -r --arg f "$1" '.formulas[]? | select(.name == $f) | .source // empty' 2>/dev/null |
        head -1)
    if [ -n "$rkr_src" ]; then
        # <pack>/formulas/<formula>.toml -> <pack>
        rkr_pack=$(dirname "$(dirname "$rkr_src")")
        if [ -x "$rkr_pack/$rkr_rel" ]; then
            echo "$rkr_pack/$rkr_rel"
            return 0
        fi
    fi
    if [ -n "${GC_PACK_DIR:-}" ] && [ -x "$GC_PACK_DIR/$rkr_rel" ]; then
        echo "$GC_PACK_DIR/$rkr_rel"
        return 0
    fi
    return 1
}
# --- resolve-known-red:end ---
# --- gate-run:begin ---
# gate_run <phase> '<command>' appends one segment known-red can read to
# $GATE_LOG: a `gate(<phase>): RUN` header, the command's output, then
# `gate(<phase>): PASS` or `gate(<phase>): FAIL`. An empty command is a phase
# the rig does not configure: it writes nothing and returns 0. The command is
# passed single-quoted and eval'd, so double quotes and $(...) in it work.
gate_run() {
    gr_phase="$1"
    gr_cmd="$2"
    [ -n "${gr_cmd//[[:space:]]/}" ] || return 0
    echo "gate($gr_phase): RUN $(printf '%s' "$gr_cmd" | tr -s '[:space:]' ' ')" | tee -a "$GATE_LOG"
    if ( eval "$gr_cmd" ) </dev/null >>"$GATE_LOG" 2>&1; then
        echo "gate($gr_phase): PASS" | tee -a "$GATE_LOG"
        return 0
    fi
    echo "gate($gr_phase): FAIL" >>"$GATE_LOG"
    tail -n 40 "$GATE_LOG"
    return 1
}
# --- gate-run:end ---
# --- known-red-phase-skip:begin ---
# kr_phase_covered <phase> prints the ids of the open base-red beads covering
# that phase and returns 0, or returns 1. It returns 1 for no covering bead, a
# failed lookup, and output it cannot parse: a phase is never skipped on an
# answer nobody verified. Needs KR set to the known-red path.
kr_phase_covered() {
    kpc_out=$("$KR" list --phase "$1" 2>/dev/null) || return 1
    printf '%s' "$kpc_out" | awk '
        NR == 1 {
            if ($0 !~ /^known-red: [0-9]+ base-red bead[(]s[)] in ledger /) { bad = 1; exit }
            want = $2 + 0
            next
        }
        /^[A-Za-z0-9]+-[A-Za-z0-9.]+ / { ids = ids (ids == "" ? "" : " ") $1; n++ }
        END {
            if (bad || NR == 0 || want == 0 || n != want) exit 1
            print ids
        }'
}
# --- known-red-phase-skip:end ---
if [ "$1" = preflight ]; then
: "${PG_BASE_BRANCH?not set (the formula step sets it; an empty value is allowed)}"
: "${PG_BINDING_PREFIX?not set (the formula step sets it; an empty value is allowed)}"
: "${PG_CONVOY_ID?not set (the formula step sets it; an empty value is allowed)}"
: "${PG_TYPECHECK_COMMAND?not set (the formula step sets it; an empty value is allowed)}"
: "${PG_LINT_COMMAND?not set (the formula step sets it; an empty value is allowed)}"
# --- preflight-phases:begin ---
KR=$(resolve_known_red mol-polecat-work) || KR=""
GATE_LOG="$(git rev-parse --git-dir)/preflight-gate.log"
: > "$GATE_LOG"
[ -n "$KR" ] || echo "WARN known-red not found; running every phase and filing by hand"
preflight_phase() {
    [ -n "${2//[[:space:]]/}" ] || return 0
    if [ -n "$KR" ] && pp_ids=$(kr_phase_covered "$1"); then
        echo "phase $1 not re-run on base: known red $pp_ids" | tee -a "$GATE_LOG"
        return 0
    fi
    gate_run "$1" "$2"
}
preflight_phase typecheck "$PG_TYPECHECK_COMMAND"
preflight_phase lint "$PG_LINT_COMMAND"
# --- preflight-phases:end ---
# --- preflight-red:begin ---
if ! grep -q '^gate([A-Za-z0-9_-]*): FAIL' "$GATE_LOG"; then
    echo "PRE-FLIGHTS GREEN on ${PG_BASE_BRANCH} (log: $GATE_LOG)"
else
    CONVOY_STATUS=$(gc convoy status ${PG_CONVOY_ID} --json)
    WORK_BEAD_ID=$(printf '%s' "$CONVOY_STATUS" | jq -r 'if (.children | length) == 1 then .children[0].id else empty end')
    WITNESS_TARGET="${GC_RIG:+$GC_RIG/}${PG_BINDING_PREFIX}witness"
    if [ -z "$KR" ]; then
        echo "PRE-FLIGHTS RED and known-red is unavailable: file by hand with the fallback block in §3."
    else
        KR_OUT=$("$KR" match "$GATE_LOG" 2>&1)
        KR_CODE=$?
        printf '%s\n' "$KR_OUT"
        case "$KR_CODE" in
        0|3)
            KNOWN_IDS=$(printf '%s\n' "$KR_OUT" | awk '$1 == "KNOWN" { print $2 }' | sort -u | paste -sd ' ' -)
            FIXED_IDS=$(printf '%s\n' "$KR_OUT" | awk '$1 == "FIXED-UPSTREAM" { print $2 }' | sort -u | paste -sd ' ' -)
            gc bd note "$WORK_BEAD_ID" --stdin <<KNOWN_RED_NOTE
Pre-flight on ${PG_BASE_BRANCH}: every red is already known (known-red match exit $KR_CODE). Filed nothing.
KNOWN: ${KNOWN_IDS:-none}
FIXED-UPSTREAM (the next rebase picks these up): ${FIXED_IDS:-none}
KNOWN_RED_NOTE
            echo "PRE-FLIGHTS RED, all KNOWN: ${KNOWN_IDS:-none}; FIXED-UPSTREAM: ${FIXED_IDS:-none}. Filed nothing. Proceed."
            ;;
        1)
            FILE_OUT=$("$KR" file "$GATE_LOG" --summary "red in pre-flight on ${PG_BASE_BRANCH} at $(git rev-parse --short HEAD)" --from "$WORK_BEAD_ID" 2>&1)
            FILE_CODE=$?
            printf '%s\n' "$FILE_OUT"
            FILED=$(printf '%s\n' "$FILE_OUT" | awk '$1 == "known-red:" && $2 == "filed" { print $3 }' | paste -sd ' ' -)
            UNFILED=$(printf '%s\n' "$FILE_OUT" | awk '$1 ~ /^raw:/')
            case "$FILE_CODE" in
            0) FILE_NOTE="" ;;
            1) FILE_NOTE="These reds have no stable id, so known-red cannot file them; quote them on $WORK_BEAD_ID: $UNFILED" ;;
            *) FILE_NOTE="known-red file exited $FILE_CODE, so nothing may be filed. A create can land and still fail: run known-red list before filing again." ;;
            esac
            gc mail send "$WITNESS_TARGET" -s "NOTICE: ${PG_BASE_BRANCH} has failing pre-flights" -m "Filed: ${FILED:-none}. Proceeding with $WORK_BEAD_ID. $FILE_NOTE"
            echo "PRE-FLIGHTS RED, NEW reds filed: ${FILED:-none}. Proceed. $FILE_NOTE"
            ;;
        *)
            gc mail send "$WITNESS_TARGET" -s "NOTICE: ${PG_BASE_BRANCH} has failing pre-flights" -m "known-red lookup failed; not filed (match exit $KR_CODE). Log: $GATE_LOG. Proceeding with $WORK_BEAD_ID."
            echo "PRE-FLIGHTS RED, known-red lookup failed (exit $KR_CODE); filed nothing. Proceed."
            ;;
        esac
    fi
fi
# --- preflight-red:end ---
else
: "${BASE_REF:?base ref not resolved — run step 1 of this step first}"
export BASE_REF
: "${PG_SETUP_COMMAND?not set (the formula step sets it; an empty value is allowed)}"
: "${PG_TYPECHECK_COMMAND?not set (the formula step sets it; an empty value is allowed)}"
: "${PG_LINT_COMMAND?not set (the formula step sets it; an empty value is allowed)}"
: "${PG_BUILD_COMMAND?not set (the formula step sets it; an empty value is allowed)}"
: "${PG_TEST_COMMAND?not set (the formula step sets it; an empty value is allowed)}"
: "${PG_AFFECTED_TESTS_COMMAND?not set (the formula step sets it; an empty value is allowed)}"
# --- self-review-gates:begin ---
KR=$(resolve_known_red mol-polecat-work) || KR=""
GATE_LOG="$(git rev-parse --git-dir)/self-review-gate.log"
: > "$GATE_LOG"
gate_run setup "$PG_SETUP_COMMAND"
gate_run typecheck "$PG_TYPECHECK_COMMAND"
gate_run lint "$PG_LINT_COMMAND"
gate_run build "$PG_BUILD_COMMAND"
if [ -n "$PG_AFFECTED_TESTS_COMMAND" ]; then
    # Rig has an affected-tests detector. Run only the tests our diff
    # touches — same logic the rig's CI uses to dispatch test workflows.
    # The command must read `git diff --name-only $BASE_REF...HEAD`
    # internally (BASE_REF is exported in step 1) and execute the relevant
    # subset. The guard above is load-bearing: fenced blocks run in separate
    # shells, and an unset BASE_REF makes that diff read `HEAD...HEAD`, which
    # exits 0 with no files — zero tests run, and the fail-closed clause
    # below never fires. It must also fail closed: a pipe-style detector
    # without `set -o pipefail` swallows a failed diff, runs zero tests,
    # exits 0, and pushes untested work.
    # The test above is single-quoted like gate_run's argument, so testing it
    # never expands or runs any of it.
    gate_run affected-tests "$PG_AFFECTED_TESTS_COMMAND"
else
    # No affected detector — run test_command as the rig configured it.
    # That is not necessarily the full suite: a rig's test_command may
    # itself select by diff.
    gate_run test "$PG_TEST_COMMAND"
fi
if ! grep -q '^gate([A-Za-z0-9_-]*): FAIL' "$GATE_LOG"; then
    echo "SELF-REVIEW GATES GREEN (log: $GATE_LOG)"
elif [ -z "$KR" ]; then
    echo "SELF-REVIEW RED (log: $GATE_LOG). known-red not found: attribute by hand, §3."
else
    echo "SELF-REVIEW RED (log: $GATE_LOG). known-red: $KR"
    "$KR" match "$GATE_LOG"
    echo "known-red match exit $?"
fi
# --- self-review-gates:end ---
fi
