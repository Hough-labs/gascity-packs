#!/usr/bin/env bash
# Contract tests for the deacon patrol's reminder text (gcp-di7v).
#
# Two steps of mol-deacon-patrol used to turn a one-shot reading into a
# confident order:
#   - queue-starvation-check called any assignee with no ACTIVE session
#     "orphaned work", which a deliberately parked named seat always is.
#     Orphan recovery is the rig witness's job, so the deacon now says so and
#     classifies nothing.
#   - Step 3b nudged the mayor to raise dolt.auto-push-timeout in a rig's
#     config.yaml from a FROZEN reading that often clears before it is read.
#     The nudge now reports what was observed, when, and how to re-measure.
#
# The step text and the frozen-report block are extracted from the shipped
# formula, and the block is EXECUTED against a stub `gc` that logs every call,
# so the assertions read what the block actually did.
# Assertions grep literal text, so single-quoted `$VAR` is the point.
# shellcheck disable=SC2016
set -uo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
FORMULA="$ROOT/gastown/formulas/mol-deacon-patrol.toml"

FAILURES=0

fail() {
    echo "FAIL: $*" >&2
    FAILURES=$((FAILURES + 1))
}

# step_text prints the full description of one step by id.
step_text() {
    python3 - "$FORMULA" "$1" <<'PY'
import sys
import tomllib

formula, step_id = sys.argv[1:3]
with open(formula, "rb") as handle:
    doc = tomllib.load(handle)
step = next(s for s in doc["steps"] if s["id"] == step_id)
sys.stdout.write(step["description"])
PY
}

# extract_frozen_report pulls the Step 3b block verbatim out of the
# dolt-push-divergence step. Exactly one begin/end pair, and any `{{placeholder}}`
# left in it is a hard error: the harness cannot render it, and an unrendered one
# would make the test pass against text the formula never runs.
extract_frozen_report() {
    python3 - "$FORMULA" "$1" <<'PY'
import re
import sys
import tomllib

formula, out = sys.argv[1:3]
begin = "# --- frozen-report:begin ---"
end = "# --- frozen-report:end ---"
with open(formula, "rb") as handle:
    doc = tomllib.load(handle)
hits = [s for s in doc["steps"] if begin in s["description"]]
if len(hits) != 1:
    sys.exit("exactly one step must carry the frozen-report block")
text = hits[0]["description"]
if text.count(begin) != 1 or text.count(end) != 1:
    sys.exit("the step must carry exactly one frozen-report begin/end pair")
block = text.split(begin, 1)[1].split(end, 1)[0]
leftover = sorted(set(re.findall(r"\{\{[^}]*\}\}", block)))
if leftover:
    sys.exit(f"frozen-report block has unrendered placeholders: {leftover}")
with open(out, "w") as handle:
    handle.write(block)
PY
}

# The stub logs "$*" for every call. Only `session nudge` and `mail` are
# modelled; anything else is a call the block should not be making.
write_gc_stub() {
    local dir="$1"
    cat >"$dir/gc" <<'STUB'
#!/usr/bin/env bash
case "${1:-} ${2:-}" in
    "session nudge"|"mail send")
        printf '%s\n' "$*" >>"$GC_STUB_LOG"
        exit 0
        ;;
esac
echo "stub gc: unexpected invocation: $*" >&2
exit 64
STUB
    chmod +x "$dir/gc"
}

FROZEN_RESULT='{"scope":"ferth","verdict":"FROZEN","oldest_unpushed_age_s":0,"threshold_s":900,"detail":"remotes/origin/main is at local head (9d8vb25l)"}'
OBSERVED="2026-09-06T19:58:35Z"
CHECK_PATH="/pack/assets/scripts/dolt-push-state-check.sh"

# run_frozen_report <city-dir> <log> runs the extracted block once.
run_frozen_report() {
    PATH="$TMP/bin:$PATH" GC_STUB_LOG="$2" GC_CITY="$1" RESULT="$FROZEN_RESULT" \
        OBSERVED_AT="$OBSERVED" CHECK="$CHECK_PATH" bash "$TMP/frozen.sh"
}

test_queue_starvation_names_no_orphans() {
    local text
    text=$(step_text queue-starvation-check) || { fail "could not read queue-starvation-check"; return; }
    case "$text" in
        *"This step does not call it orphaned"*) ;;
        *) fail "queue-starvation-check does not say it does not call an unmatched assignee orphaned" ;;
    esac
    case "$text" in
        *"is orphaned work"*) fail "queue-starvation-check still calls an unmatched assignee orphaned work" ;;
    esac
}

test_frozen_report_states_observation_time_and_remeasure() {
    local city log line
    city=$(mktemp -d "$TMP/city.XXXXXX") || { fail "mktemp"; return; }
    log="$city/stub.log"
    : >"$log"
    run_frozen_report "$city" "$log" || { fail "frozen-report block exited non-zero"; return; }
    if [ "$(grep -c '^session nudge mayor/' "$log")" -ne 1 ]; then
        fail "expected exactly one 'session nudge mayor/' call, got: $(cat "$log")"
        return
    fi
    line=$(grep '^session nudge mayor/' "$log")
    case "$line" in
        *"OBSERVED $OBSERVED"*) ;;
        *) fail "nudge does not carry the observation time: $line" ;;
    esac
    case "$line" in
        *"re-run $CHECK_PATH --json"*) ;;
        *) fail "nudge does not order a re-measure: $line" ;;
    esac
    case "$line" in
        *"act only if ferth still reads FROZEN"*) ;;
        *) fail "nudge does not gate the action on a fresh FROZEN reading: $line" ;;
    esac
    case "$line" in
        *Raise*) fail "nudge still orders a raise: $line" ;;
    esac
    case "$line" in
        *config.yaml*) fail "nudge still points at a config file: $line" ;;
    esac
}

test_frozen_report_is_said_once_per_condition() {
    local city log
    city=$(mktemp -d "$TMP/city.XXXXXX") || { fail "mktemp"; return; }
    log="$city/stub.log"
    : >"$log"
    run_frozen_report "$city" "$log" || { fail "first run exited non-zero"; return; }
    run_frozen_report "$city" "$log" || { fail "second run exited non-zero"; return; }
    if [ "$(grep -c '^session nudge mayor/' "$log")" -ne 1 ]; then
        fail "two runs on one condition should nudge once, got: $(cat "$log")"
    fi
}

TMP=$(mktemp -d "${TMPDIR:-/tmp}/gastown-deacon-reminders.XXXXXX") || exit 1
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin"
write_gc_stub "$TMP/bin"
extract_frozen_report "$TMP/frozen.sh" || exit 1
bash -n "$TMP/frozen.sh" || { echo "FAIL: extracted frozen-report block is not valid shell" >&2; exit 1; }

test_queue_starvation_names_no_orphans
test_frozen_report_states_observation_time_and_remeasure
test_frozen_report_is_said_once_per_condition

if [ "$FAILURES" -ne 0 ]; then
    echo "$FAILURES test(s) failed" >&2
    exit 1
fi
echo "all deacon-patrol reminder tests passed"
