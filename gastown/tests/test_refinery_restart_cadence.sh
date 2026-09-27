#!/usr/bin/env bash
# Contract tests for the refinery's restart cadence (gcp-l8td.2).
#
# Under wake_mode = "resume" nothing restarts a refinery conversation except
# check-inbox's restart block, and that block used to fire only when "context
# feels heavy". Trialled alone on 2026-09-24, one conversation carried every
# bead to 126k of its 200k window. The trigger is now a number: every successor
# wisp poured without a restart is stamped with the conversation's
# GC_CONTINUATION_EPOCH and a running iteration count, and check-inbox compares
# that count with restart_after_iterations before any merge work.
#
# Two halves, both EXECUTED from the shipped formula text rather than
# transcribed: the four session-iteration-stamp blocks (one per pour site that
# continues the conversation) and the one restart-cadence-check block. The stub
# `gc` really mutates a fixture and journals every update, so an assertion reads
# what the block's writes left behind, not what its source says. The blocks are
# sourced through `bash -c '... "$1"'`, so single-quoted `$1` is the point.
# shellcheck disable=SC2016
set -uo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
FORMULA="$ROOT/gastown/formulas/mol-refinery-patrol.toml"

CURRENT="gcp-wisp-cur"
NEXT="gcp-wisp-nxt"
REFINERY="gascity-packs/gastown.refinery"

FAILURES=0

fail() {
    echo "FAIL: $*" >&2
    FAILURES=$((FAILURES + 1))
}

# The stamp must sit at every pour that continues the conversation, and only
# there. The check-inbox pour starts a NEW conversation: the epoch bump makes
# its unstamped wisp read correctly as one, so stamping it would be wrong.
test_stamp_blocks_sit_at_exactly_the_four_continuing_pours() {
    python3 - "$FORMULA" <<'PY' || fail "the session-iteration-stamp blocks are misplaced or have drifted apart (see above)"
import sys
import tomllib

doc = tomllib.load(open(sys.argv[1], "rb"))
steps = {step["id"]: step.get("description", "") for step in doc["steps"]}
begin = "# --- session-iteration-stamp:begin ---"
end = "# --- session-iteration-stamp:end ---"
pour = "gc bd mol wisp mol-refinery-patrol"
problems = []

holders = sorted(sid for sid, text in steps.items() if begin in text)
expected = sorted(["rebase", "handle-failures", "merge-push", "next-iteration"])
if holders != expected:
    problems.append(f"stamp blocks live in {holders}, want exactly {expected}")
total = sum(text.count(begin) for text in steps.values())
if total != 4:
    problems.append(f"formula carries {total} stamp blocks, want 4")

blocks = {}
for sid, text in steps.items():
    if begin not in text:
        continue
    if text.count(begin) != 1 or text.count(end) != 1:
        problems.append(f"{sid}: want exactly one begin and one end sentinel")
        continue
    before, rest = text.split(begin, 1)
    body, after = rest.split(end, 1)
    blocks[sid] = [line.lstrip() for line in body.strip().split("\n")]
    # In place: after this step's pour, before its burn, and it is the ONLY
    # assignment of NEXT in the step, so no unstamped write survives beside it.
    if pour not in before:
        problems.append(f"{sid}: the stamp block must follow the successor pour")
    if "gc bd mol burn" not in after:
        problems.append(f"{sid}: the stamp block must precede the burn of the current wisp")
    if text.count('gc bd update "$NEXT"') != 1 or 'gc bd update "$NEXT"' not in body:
        problems.append(f"{sid}: NEXT must be assigned once, inside the stamp block")
    if text.count(pour) != 1:
        problems.append(f"{sid}: want exactly one successor pour, found {text.count(pour)}")

reference = blocks.get("next-iteration")
for sid, lines in blocks.items():
    if reference is not None and lines != reference:
        problems.append(f"{sid}: stamp block differs from next-iteration's after stripping leading whitespace")

inbox = steps["check-inbox"]
if begin in inbox:
    problems.append("check-inbox must not stamp: its pour starts a new conversation")
if "--set-metadata session_" in inbox:
    problems.append("check-inbox must not write session_epoch/session_iterations")
if inbox.count(pour) != 1:
    problems.append(f"check-inbox: want exactly one restart pour, found {inbox.count(pour)}")

for problem in problems:
    print(f"  {problem}", file=sys.stderr)
sys.exit(1 if problems else 0)
PY
}

# The cadence check runs first in check-inbox, ahead of the restart block it
# gates, and the prose names every trigger that runs that block.
test_cadence_check_runs_first_in_check_inbox() {
    python3 - "$FORMULA" <<'PY' || fail "the restart-cadence-check block is misplaced (see above)"
import sys
import tomllib

doc = tomllib.load(open(sys.argv[1], "rb"))
steps = {step["id"]: step.get("description", "") for step in doc["steps"]}
begin = "# --- restart-cadence-check:begin ---"
problems = []
holders = [sid for sid, text in steps.items() if begin in text]
if holders != ["check-inbox"]:
    problems.append(f"restart-cadence-check lives in {holders}, want only check-inbox")
inbox = steps["check-inbox"]
if inbox.count(begin) != 1:
    problems.append("check-inbox must carry exactly one restart-cadence-check block")
elif not (
    inbox.index("**1. Context check")
    < inbox.index(begin)
    < inbox.index("gc bd mol wisp mol-refinery-patrol")
    < inbox.index("gc runtime request-restart")
    < inbox.index("**2. Check mail")
):
    problems.append("the cadence check must open section 1, ahead of the restart block and the mail check")
prose = inbox.split("# --- restart-cadence-check:end ---", 1)[-1].split("```bash", 1)[0]
for trigger in ("RESTART DUE", "context advisory", "context feels heavy"):
    if trigger not in prose:
        problems.append(f"the restart-block prose must name the trigger {trigger!r}")
if "restart_after_iterations" not in doc.get("vars", {}):
    problems.append("[vars] must declare restart_after_iterations")
for problem in problems:
    print(f"  {problem}", file=sys.stderr)
sys.exit(1 if problems else 0)
PY
}

# extract_block <name> <outfile> [restart_after_iterations] — one sentinel
# block, from next-iteration when several exist (the structural test above has
# already proved the copies identical). Placeholders are rendered from the
# formula's own [vars] defaults, with restart_after_iterations overridable per
# case. Anything left unrendered is a hard error: a block holding a literal
# "{{...}}" would run and could pass vacuously.
extract_block() {
    python3 - "$FORMULA" "$1" "$2" "${3-}" <<'PY'
import re
import sys
import tomllib

formula, name, out, cadence = sys.argv[1:5]
begin = f"# --- {name}:begin ---"
end = f"# --- {name}:end ---"
doc = tomllib.load(open(formula, "rb"))
steps = {step["id"]: step.get("description", "") for step in doc["steps"]}
holders = [sid for sid, text in steps.items() if begin in text]
if not holders:
    sys.exit(f"no {name} block in {formula}")
text = steps["next-iteration" if "next-iteration" in holders else holders[0]]
block = text.split(begin, 1)[1].split(end, 1)[0]
values = {n: spec.get("default", "") for n, spec in (doc.get("vars") or {}).items()}
if name == "restart-cadence-check":
    values["restart_after_iterations"] = cadence
block = re.sub(r"\{\{\s*(\w+)\s*\}\}", lambda m: values.get(m.group(1), m.group(0)), block)
leftover = sorted(set(re.findall(r"\{\{[^}]*\}\}", block)))
if leftover:
    sys.exit(f"{name} block has unrendered placeholders: {leftover}")
open(out, "w").write(block)
PY
}

# The stub answers `show` and `update` from a JSON fixture, journals every
# update's argv as JSON (read back from Python, never grepped), and accepts
# `runtime drain-ack`. GC_STUB_SHOW_FAIL / GC_STUB_UPDATE_FAIL make those verbs
# fail the way a transient store error does. Anything else is unmodelled and
# fails loudly, so a block reaching for a call the test does not model cannot
# pass by accident.
write_gc_stub() {
    local dir="$1"
    cat >"$dir/gc" <<'STUB'
#!/usr/bin/env bash
if [ "${1:-}" = "runtime" ] && [ "${2:-}" = "drain-ack" ]; then
    echo "drain-ack" >>"$GC_STUB_DRAINS"
    exit 0
fi
if [ "${1:-}" != "bd" ]; then
    echo "stub gc: unexpected invocation: $*" >&2
    exit 64
fi
verb="${2:-}"
shift 2
case "$verb" in
    show)
        [ -z "${GC_STUB_SHOW_FAIL:-}" ] || exit 1
        exec python3 "$GC_STUB_STORE" show "$GC_STUB_FIXTURE" "$@"
        ;;
    update)
        [ -z "${GC_STUB_UPDATE_FAIL:-}" ] || exit 1
        exec python3 "$GC_STUB_STORE" update "$GC_STUB_FIXTURE" "$@"
        ;;
    *) echo "stub gc: unmodelled subcommand: $verb" >&2; exit 64 ;;
esac
STUB
    chmod +x "$dir/gc"

    cat >"$dir/store.py" <<'PY'
import json
import sys

verb, fixture, *args = sys.argv[1:]
with open(fixture) as handle:
    state = json.load(handle)
beads = state["beads"]

positional = [arg for arg in args if not arg.startswith("--")]
bead_id = positional[0] if positional else None
target = next((bead for bead in beads if bead["id"] == bead_id), None)

if verb == "show":
    # Missing metadata comes back as null, the way the live store shows a wisp.
    print(json.dumps([target] if target else []))
    sys.exit(0)

if target is None:
    sys.exit(f"stub gc update: no such bead {bead_id!r}")
state["updates"].append(args)
index = 0
while index < len(args):
    arg = args[index]
    if not arg.startswith("--"):
        index += 1
        continue
    if "=" in arg and not arg.startswith("--set-metadata"):
        name, value = arg.split("=", 1)
        index += 1
    else:
        name, value = arg, args[index + 1]
        index += 2
    if name == "--assignee":
        target["assignee"] = value
    elif name == "--set-metadata":
        key, _, new_value = value.partition("=")
        metadata = target.get("metadata") or {}
        metadata[key] = new_value
        target["metadata"] = metadata
    else:
        sys.exit(f"stub gc update: unmodelled flag {name!r}")
with open(fixture, "w") as handle:
    json.dump(state, handle)
PY
}

# seed [epoch] [iterations] — CURRENT as a running patrol wisp, stamped with
# whichever of the two keys are given, and a freshly poured, unassigned NEXT.
seed() {
    python3 - "$TMP/fixture.json" "$CURRENT" "$NEXT" "$REFINERY" "${1-}" "${2-}" <<'PY'
import json
import sys

path, current, nxt, refinery, epoch, iterations = sys.argv[1:7]
metadata = {}
if epoch:
    metadata["session_epoch"] = epoch
if iterations:
    metadata["session_iterations"] = iterations
with open(path, "w") as handle:
    json.dump({
        "beads": [
            {"id": current, "status": "in_progress", "assignee": refinery,
             "metadata": metadata or None},
            {"id": nxt, "status": "open", "assignee": "", "metadata": None},
        ],
        "updates": [],
    }, handle)
PY
}

# field <bead> <key> — a top-level field, or metadata.<key>, of a fixture bead.
field() {
    python3 - "$TMP/fixture.json" "$1" "$2" <<'PY'
import json
import sys

path, bead_id, key = sys.argv[1:4]
bead = next(b for b in json.load(open(path))["beads"] if b["id"] == bead_id)
if key.startswith("metadata."):
    print((bead.get("metadata") or {}).get(key.split(".", 1)[1], ""))
else:
    print(bead.get(key, ""))
PY
}

# updates — the journalled update argvs, one JSON array per line.
updates() {
    python3 -c 'import json,sys; [print(json.dumps(u)) for u in json.load(open(sys.argv[1]))["updates"]]' "$TMP/fixture.json"
}

# run_block <file> [epoch|-] [extra env assignments...] — sources the block the
# way an agent runs it: GC_BEAD_ID names the current wisp, NEXT holds the pour.
# An epoch of "-" leaves GC_CONTINUATION_EPOCH unset. Sets RUN_CODE and leaves
# the output in $TMP/run.log.
run_block() {
    local file="$1" epoch="${2:--}"
    shift 2 || shift $#
    : >"$TMP/drains.log"
    local -a env_args=(
        PATH="$TMP/bin:$PATH"
        GC_STUB_FIXTURE="$TMP/fixture.json"
        GC_STUB_STORE="$TMP/bin/store.py"
        GC_STUB_DRAINS="$TMP/drains.log"
        GC_AGENT="$REFINERY"
        GC_BEAD_ID="$CURRENT"
        NEXT="$NEXT"
        CURRENT_WISP="$CURRENT"
    )
    [ "$epoch" = "-" ] || env_args+=(GC_CONTINUATION_EPOCH="$epoch")
    env -u GC_CONTINUATION_EPOCH "${env_args[@]}" "$@" \
        bash -c 'set -uo pipefail; . "$1"' _ "$file" >"$TMP/run.log" 2>&1
    RUN_CODE=$?
    if grep -q '^stub gc' "$TMP/run.log"; then
        fail "the block made a call the stub does not model: $(cat "$TMP/run.log")"
    fi
}

# cadence <N> <epoch|-> [stamped-epoch] [stamped-k] [extra env...] — renders
# the check with restart_after_iterations=N and runs it against CURRENT.
cadence() {
    local n="$1" epoch="$2"
    seed "${3-}" "${4-}"
    shift 4 2>/dev/null || shift $#
    extract_block restart-cadence-check "$TMP/cadence.sh" "$n" || {
        fail "could not extract restart-cadence-check"
        return 1
    }
    run_block "$TMP/cadence.sh" "$epoch" "$@"
    [ "$RUN_CODE" -eq 0 ] || fail "the cadence check exited $RUN_CODE: $(cat "$TMP/run.log")"
    [ "$(updates | grep -c .)" -eq 0 ] || fail "the cadence check must only read, it wrote: $(updates)"
    [ ! -s "$TMP/drains.log" ] || fail "the cadence check must never drain the session"
}

# verdict_is <expected-line-regex> [warn] — exactly one verdict line (plus one
# WARN line when asked for), and RESTART DUE only when the verdict is.
verdict_is() {
    local want="$1" warn="${2:-}"
    local out lines verdicts
    out=$(cat "$TMP/run.log")
    lines=$(grep -c . "$TMP/run.log")
    verdicts=$(grep -vc '^WARN' "$TMP/run.log")
    [ "$verdicts" -eq 1 ] || fail "the cadence check must print exactly one verdict line, got: $out"
    if [ -n "$warn" ]; then
        grep -q '^WARN' "$TMP/run.log" || fail "expected a WARN line, got: $out"
        [ "$lines" -eq 2 ] || fail "expected one WARN line and one verdict, got: $out"
    else
        [ "$lines" -eq 1 ] || fail "expected no WARN line, got: $out"
    fi
    grep -Eq "$want" "$TMP/run.log" || fail "verdict should match /$want/, got: $out"
    if [[ "$want" != ^RESTART* ]] && grep -q 'RESTART DUE' "$TMP/run.log"; then
        fail "RESTART DUE must not be printed here, got: $out"
    fi
}

test_cadence_a_below_threshold_continues() {
    cadence 2 e7 e7 1 || return
    verdict_is '^restart cadence: 1/2 in epoch e7$'
}

test_cadence_b_threshold_reached_is_due() {
    cadence 2 e7 e7 2 || return
    verdict_is '^RESTART DUE: 2 iterations in conversation epoch e7 \(restart_after_iterations=2\)$'
}

test_cadence_c_epoch_mismatch_is_a_new_conversation() {
    # Under fresh mode the controller restarts after every burn, so the wisp
    # always carries the previous conversation's epoch, however high its count.
    cadence 2 e8 e7 5 || return
    verdict_is '^restart cadence: 0/2 in epoch e8$'
}

test_cadence_d_epoch_unset_is_off() {
    cadence 2 - e7 5 || return
    verdict_is '^restart cadence: off \(.+\)$'
}

test_cadence_e_zero_is_off() {
    cadence 0 e7 e7 9 || return
    verdict_is '^restart cadence: off \(restart_after_iterations=0\)$'
}

test_cadence_e_non_integer_warns_then_off() {
    cadence abc e7 e7 9 || return
    verdict_is '^restart cadence: off \(restart_after_iterations=0\)$' warn
    grep -q "restart_after_iterations='abc'" "$TMP/run.log" ||
        fail "the WARN line should name the bad value, got: $(cat "$TMP/run.log")"
}

test_cadence_f_one_restarts_after_every_bead() {
    cadence 1 e7 e7 1 || return
    verdict_is '^RESTART DUE: 1 iterations in conversation epoch e7 \(restart_after_iterations=1\)$'
}

test_cadence_unstamped_wisp_counts_zero() {
    # The first wisp of a conversation poured by check-inbox's restart block
    # carries no stamp at all (metadata: null in the live store).
    cadence 2 e7 || return
    verdict_is '^restart cadence: 0/2 in epoch e7$'
}

test_cadence_unreadable_wisp_is_off_not_due() {
    cadence 2 e7 e7 9 GC_STUB_SHOW_FAIL=1 || return
    verdict_is '^restart cadence: off \(could not read '"$CURRENT"'\)$'
}

# run_stamp <epoch|-> [extra env...] — runs the shipped stamp block once.
run_stamp() {
    run_block "$TMP/stamp.sh" "$@"
}

test_stamp_continues_the_count_within_a_conversation() {
    seed e7 1
    run_stamp e7 || return
    [ "$RUN_CODE" -eq 0 ] || fail "the stamp block exited $RUN_CODE: $(cat "$TMP/run.log")"
    [ "$(field "$NEXT" metadata.session_iterations)" = "2" ] ||
        fail "matching epoch with k=1 must stamp NEXT session_iterations=2, got '$(field "$NEXT" metadata.session_iterations)'"
    [ "$(field "$NEXT" metadata.session_epoch)" = "e7" ] ||
        fail "NEXT must carry the conversation's epoch, got '$(field "$NEXT" metadata.session_epoch)'"
    [ "$(field "$NEXT" assignee)" = "$REFINERY" ] || fail "NEXT must still be assigned to the refinery"
    # One write carries the assignment and both keys: a separate stamp write
    # would leave a window where the next session reads an unstamped wisp.
    local calls
    calls=$(updates)
    [ "$(printf '%s\n' "$calls" | grep -c .)" -eq 1 ] || fail "want exactly one update, got: $calls"
    [[ "$calls" == *"\"$NEXT\""*"\"--assignee=$REFINERY\""*"\"session_epoch=e7\""*"\"session_iterations=2\""* ]] ||
        fail "the one update must name NEXT and carry the assignee and both keys, got: $calls"
    [ "$(field "$CURRENT" metadata.session_iterations)" = "1" ] || fail "CURRENT must not be rewritten"
}

test_stamp_restarts_the_count_in_a_new_conversation() {
    seed e7 4
    run_stamp e8 || return
    [ "$RUN_CODE" -eq 0 ] || fail "the stamp block exited $RUN_CODE: $(cat "$TMP/run.log")"
    [ "$(field "$NEXT" metadata.session_iterations)" = "1" ] ||
        fail "a different epoch must stamp NEXT session_iterations=1, got '$(field "$NEXT" metadata.session_iterations)'"
    [ "$(field "$NEXT" metadata.session_epoch)" = "e8" ] ||
        fail "NEXT must carry the new epoch, got '$(field "$NEXT" metadata.session_epoch)'"
}

test_stamp_starts_at_one_on_an_unstamped_wisp() {
    seed
    run_stamp e7 || return
    [ "$(field "$NEXT" metadata.session_iterations)" = "1" ] ||
        fail "an unstamped CURRENT must stamp NEXT session_iterations=1, got '$(field "$NEXT" metadata.session_iterations)'"
}

test_stamp_writes_neither_key_without_an_epoch() {
    seed e7 1
    run_stamp - || return
    [ "$RUN_CODE" -eq 0 ] || fail "the stamp block exited $RUN_CODE: $(cat "$TMP/run.log")"
    [ "$(field "$NEXT" assignee)" = "$REFINERY" ] || fail "NEXT must still be assigned without an epoch"
    [ -z "$(field "$NEXT" metadata.session_epoch)$(field "$NEXT" metadata.session_iterations)" ] ||
        fail "with GC_CONTINUATION_EPOCH unset NEXT must get neither key"
    [[ "$(updates)" != *session_* ]] || fail "with the epoch unset the update must not name either key, got: $(updates)"
}

test_stamp_unreadable_current_still_assigns() {
    # A failed read must not strand the loop: NEXT is still assigned. The
    # count restarts at 1, which lets this conversation run long, so the WARN
    # line makes that visible; the context-feels-heavy trigger still applies.
    seed e7 1
    run_stamp e7 GC_STUB_SHOW_FAIL=1 || return
    [ "$RUN_CODE" -eq 0 ] || fail "an unreadable CURRENT must not stop the handoff: $(cat "$TMP/run.log")"
    [ "$(field "$NEXT" assignee)" = "$REFINERY" ] || fail "NEXT must still be assigned"
    [ "$(field "$NEXT" metadata.session_iterations)" = "1" ] ||
        fail "an unreadable CURRENT stamps 1, got '$(field "$NEXT" metadata.session_iterations)'"
    grep -q '^WARN' "$TMP/run.log" || fail "an unreadable CURRENT must print a WARN line"
}

test_stamp_failed_assign_drains_and_stops() {
    seed e7 1
    run_stamp e7 GC_STUB_UPDATE_FAIL=1 || return
    [ "$RUN_CODE" -eq 1 ] || fail "a failed assignment must exit 1, got $RUN_CODE"
    grep -q 'not burning' "$TMP/run.log" || fail "a failed assignment must say it is not burning"
    [ -s "$TMP/drains.log" ] || fail "a failed assignment must drain-ack before exiting"
}

TMP=$(mktemp -d "${TMPDIR:-/tmp}/gastown-restart-cadence.XXXXXX") || exit 1
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin"
write_gc_stub "$TMP/bin"

test_stamp_blocks_sit_at_exactly_the_four_continuing_pours
test_cadence_check_runs_first_in_check_inbox

extract_block session-iteration-stamp "$TMP/stamp.sh" || exit 1
bash -n "$TMP/stamp.sh" || { echo "FAIL: extracted session-iteration-stamp block is not valid shell" >&2; exit 1; }
extract_block restart-cadence-check "$TMP/cadence.sh" 2 || exit 1
bash -n "$TMP/cadence.sh" || { echo "FAIL: extracted restart-cadence-check block is not valid shell" >&2; exit 1; }

test_cadence_a_below_threshold_continues
test_cadence_b_threshold_reached_is_due
test_cadence_c_epoch_mismatch_is_a_new_conversation
test_cadence_d_epoch_unset_is_off
test_cadence_e_zero_is_off
test_cadence_e_non_integer_warns_then_off
test_cadence_f_one_restarts_after_every_bead
test_cadence_unstamped_wisp_counts_zero
test_cadence_unreadable_wisp_is_off_not_due

test_stamp_continues_the_count_within_a_conversation
test_stamp_restarts_the_count_in_a_new_conversation
test_stamp_starts_at_one_on_an_unstamped_wisp
test_stamp_writes_neither_key_without_an_epoch
test_stamp_unreadable_current_still_assigns
test_stamp_failed_assign_drains_and_stops

if [ "$FAILURES" -ne 0 ]; then
    echo "$FAILURES test(s) failed" >&2
    exit 1
fi
echo "all restart-cadence tests passed"
