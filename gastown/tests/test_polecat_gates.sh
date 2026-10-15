#!/usr/bin/env bash
# Tests for gastown/assets/scripts/polecat-gates.sh, the one script behind the
# preflight-tests and self-review gate steps of mol-polecat-work (gcp-v9mvh).
#
# The two gate fences used to be 136 and 91 lines of shell that every polecat
# retyped. They now ship as one script, and each formula step carries a short
# stub that locates it and passes the rig's commands as PG_* env. These tests
# run the real script and the real stubs, decoded from the formula, against a
# stub `gc`. Their byte-for-byte identity with the old fences was proven by a
# throwaway harness, which is not committed; test_known_red_wiring.sh covers
# the shared blocks.
#
# No test depends on wall-clock time: every command is a stub or `true`, and
# stdin is /dev/null.
# shellcheck disable=SC2016  # the stub gate commands carry $MARK unexpanded
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
GATES="$ROOT/gastown/assets/scripts/polecat-gates.sh"
FORMULA="$ROOT/gastown/formulas/mol-polecat-work.toml"
USAGE_LINE='GATES_USAGE polecat-gates.sh preflight|self-review'

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

# new_case <name> — a fresh sandbox $CASE with a git repo to run in ($CASE/repo,
# the gates write their log under its git dir), a stub `gc` in $CASE/bin that
# journals its calls to $CASE/calls.log, and $CASE/marker, the file the stub
# gate commands append to. `gc formula list --json` prints $FORMULAS.
new_case() {
    CASE="$TMPROOT/$1"
    mkdir -p "$CASE/bin" "$CASE/repo"
    : >"$CASE/calls.log"
    : >"$CASE/marker"
    git -C "$CASE/repo" init -q
    cat >"$CASE/bin/gc" <<'SH'
#!/usr/bin/env bash
printf 'gc %s\n' "$*" >>"$CASE/calls.log"
case "${1:-} ${2:-}" in
    "formula list") printf '%s\n' "$FORMULAS" ;;
    "convoy status") printf '{"children":[{"id":"w-1"}]}\n' ;;
esac
exit 0
SH
    chmod +x "$CASE/bin/gc"
    FORMULAS='{"formulas":[]}'
}

# run_gates <argv...> -- <env...> — runs the script from $CASE/repo with only the
# given env, so a caller's PG_* or GC_* cannot leak in. Sets RC and leaves
# stdout and stderr in $CASE/out and $CASE/err.
run_gates() {
    local -a args=()
    while [ "$#" -gt 0 ] && [ "$1" != "--" ]; do
        args+=("$1")
        shift
    done
    [ "$#" -gt 0 ] && shift
    RC=0
    (
        cd "$CASE/repo" &&
            env -i PATH="$CASE/bin:$PATH" HOME="$CASE" GIT_CONFIG_GLOBAL=/dev/null \
                CASE="$CASE" FORMULAS="$FORMULAS" MARK="$CASE/marker" "$@" \
                bash "$GATES" ${args[@]+"${args[@]}"} </dev/null
    ) >"$CASE/out" 2>"$CASE/err" || RC=$?
}

# render_stub <step> <outfile> <var=value...> — the decoded stub of that step:
# the bash fence that calls the gates script, with every {{var}} replaced the way
# gc renders the step. A {{var}} left over is a hard error.
render_stub() {
    python3 -I - "$FORMULA" "$@" <<'PY'
import re
import sys
import tomllib

formula, step, out, *pairs = sys.argv[1:]
values = dict(pair.split("=", 1) for pair in pairs)
doc = tomllib.load(open(formula, "rb"))
text = next(s["description"] for s in doc["steps"] if s["id"] == step)
fences = re.findall(r"```bash\n(.*?)\n```", text, re.S)
stub = next(f for f in fences if 'bash "$PG"' in f)
rendered = re.sub(r"\{\{(\w+)\}\}", lambda m: values.get(m.group(1), m.group(0)), stub)
left = sorted(set(re.findall(r"\{\{\w+\}\}", rendered)))
if left:
    sys.exit(f"unrendered placeholders in the {step} stub: {left}")
open(out, "w").write(rendered + "\n")
PY
}

# no_gate_ran — fails unless no stub gate command ran.
no_gate_ran() {
    [ ! -s "$CASE/marker" ] || fail "$1: a gate command ran: $(cat "$CASE/marker")"
}

test_usage_rejects_unknown_mode() {
    local label
    new_case usage
    for label in none bogus extra; do
        case "$label" in
            none) run_gates -- ;;
            bogus) run_gates bogus -- ;;
            extra) run_gates preflight self-review -- ;;
        esac
        [ "$RC" -eq 2 ] || fail "$label: want exit 2, got $RC"
        [ "$(cat "$CASE/out")" = "$USAGE_LINE" ] ||
            fail "$label: want exactly '$USAGE_LINE' on stdout, got: $(cat "$CASE/out")"
        [ ! -s "$CASE/err" ] || fail "$label: want empty stderr, got: $(cat "$CASE/err")"
    done
}

test_unset_required_var_stops() {
    new_case unset
    # PG_LINT_COMMAND is the one var left out; the typecheck command would leave
    # a mark if the script got as far as running a gate.
    run_gates preflight -- PG_BASE_BRANCH=integration PG_BINDING_PREFIX=gastown. \
        PG_CONVOY_ID=gcp-convoy PG_TYPECHECK_COMMAND='echo typecheck >>"$MARK"'
    [ "$RC" -ne 0 ] || fail "want a non-zero exit with PG_LINT_COMMAND unset, got 0"
    grep -q 'PG_LINT_COMMAND' "$CASE/err" || fail "want stderr to name PG_LINT_COMMAND, got: $(cat "$CASE/err")"
    no_gate_ran "an unset PG_LINT_COMMAND"

    # An EMPTY value is legal: it is a phase the rig does not configure.
    run_gates preflight -- PG_BASE_BRANCH=integration PG_BINDING_PREFIX=gastown. \
        PG_CONVOY_ID=gcp-convoy PG_TYPECHECK_COMMAND='' PG_LINT_COMMAND=''
    [ "$RC" -eq 0 ] || fail "empty phase commands must pass, got $RC: $(cat "$CASE/err")"
    grep -q '^PRE-FLIGHTS GREEN on integration' "$CASE/out" ||
        fail "empty phase commands must print PRE-FLIGHTS GREEN, got: $(cat "$CASE/out")"
}

test_empty_affected_tests_runs_test_command() {
    new_case affected
    run_gates self-review -- BASE_REF=origin/integration \
        PG_SETUP_COMMAND='' PG_TYPECHECK_COMMAND='' PG_LINT_COMMAND='' PG_BUILD_COMMAND='' \
        PG_TEST_COMMAND='echo ran-test >>"$MARK"' PG_AFFECTED_TESTS_COMMAND=''
    [ "$RC" -eq 0 ] || fail "want exit 0, got $RC: $(cat "$CASE/err")"
    [ "$(cat "$CASE/marker")" = "ran-test" ] ||
        fail "an empty PG_AFFECTED_TESTS_COMMAND must run PG_TEST_COMMAND exactly once, marker: $(cat "$CASE/marker")"
    local log
    log="$(git -C "$CASE/repo" rev-parse --absolute-git-dir)/self-review-gate.log"
    grep -qx 'gate(test): PASS' "$log" || fail "want a gate(test) PASS in the log, got: $(cat "$log")"
    ! grep -q '^gate(affected-tests)' "$log" || fail "want no affected-tests segment, got: $(cat "$log")"
}

test_preflight_stub_stops_when_script_unresolved() {
    new_case preflight-stub
    render_stub preflight-tests "$CASE/stub.sh" base_branch=integration binding_prefix=gastown. \
        convoy_id=gcp-convoy typecheck_command='echo typecheck >>"$MARK"' lint_command='echo lint >>"$MARK"'
    # `gc formula list --json` finds no formula, so the script cannot be located.
    RC=0
    (cd "$CASE/repo" && env -i PATH="$CASE/bin:$PATH" HOME="$CASE" CASE="$CASE" \
        FORMULAS="$FORMULAS" MARK="$CASE/marker" bash "$CASE/stub.sh" </dev/null) \
        >"$CASE/out" 2>"$CASE/err" || RC=$?
    [ "$RC" -eq 1 ] || fail "want exit 1, got $RC"
    grep -q '^STOP: gates script not found' "$CASE/out" ||
        fail "want a line starting 'STOP: gates script not found', got: $(cat "$CASE/out")"
    grep -qx 'gc runtime drain-ack' "$CASE/calls.log" || fail "want gc runtime drain-ack, calls: $(cat "$CASE/calls.log")"
    no_gate_ran "an unresolved script"
}

test_self_review_stub_stops_when_script_unresolved() {
    new_case self-review-stub
    render_stub self-review "$CASE/stub.sh" base_branch=integration convoy_id=gcp-convoy \
        setup_command='echo setup >>"$MARK"' typecheck_command='echo typecheck >>"$MARK"' \
        lint_command='echo lint >>"$MARK"' build_command='echo build >>"$MARK"' \
        test_command='echo test >>"$MARK"' affected_tests_command=''
    RC=0
    (cd "$CASE/repo" && env -i PATH="$CASE/bin:$PATH" HOME="$CASE" CASE="$CASE" \
        FORMULAS="$FORMULAS" MARK="$CASE/marker" BASE_REF=origin/integration \
        bash "$CASE/stub.sh" </dev/null) >"$CASE/out" 2>"$CASE/err" || RC=$?
    [ "$RC" -eq 1 ] || fail "want exit 1, got $RC"
    grep -q '^STOP: gates script not found' "$CASE/out" ||
        fail "want a line starting 'STOP: gates script not found', got: $(cat "$CASE/out")"
    grep -qx 'gc runtime drain-ack' "$CASE/calls.log" || fail "want gc runtime drain-ack, calls: $(cat "$CASE/calls.log")"
    no_gate_ran "an unresolved script"
}

test_self_review_stub_exports_base_ref() {
    new_case export-base-ref
    FORMULAS='{"formulas":[{"name":"mol-polecat-work","source":"'"$FORMULA"'"}]}'
    render_stub self-review "$CASE/stub.sh" base_branch=integration convoy_id=gcp-convoy \
        setup_command='' typecheck_command='' lint_command='' build_command='' test_command='' \
        affected_tests_command='echo "affected BASE_REF=$BASE_REF" >>"$MARK"'
    # The caller sets BASE_REF without exporting it. The stub must export it, or
    # the gates script and the affected-tests command never see it.
    RC=0
    (cd "$CASE/repo" && env -i PATH="$CASE/bin:$PATH" HOME="$CASE" CASE="$CASE" \
        FORMULAS="$FORMULAS" MARK="$CASE/marker" GIT_CONFIG_GLOBAL=/dev/null \
        bash -c 'BASE_REF=origin/integration; . "$1"' _ "$CASE/stub.sh" </dev/null) \
        >"$CASE/out" 2>"$CASE/err" || RC=$?
    [ "$RC" -eq 0 ] || fail "want exit 0, got $RC: $(cat "$CASE/out") $(cat "$CASE/err")"
    [ "$(cat "$CASE/marker")" = "affected BASE_REF=origin/integration" ] ||
        fail "the affected-tests command must see BASE_REF, marker: '$(cat "$CASE/marker")'"
}

test_usage_rejects_unknown_mode
test_unset_required_var_stops
test_empty_affected_tests_runs_test_command
test_preflight_stub_stops_when_script_unresolved
test_self_review_stub_stops_when_script_unresolved
test_self_review_stub_exports_base_ref
echo "polecat gates tests passed"
