#!/usr/bin/env bash
# Contract tests for the known-red wiring in mol-polecat-work (gcp-oczc,
# gc-cgxps phase 2 part 2) and mol-refinery-patrol (gcp-jb9f, part 3).
#
# preflight-tests and self-review run every phase through gate_run, so the log
# carries the `gate(<phase>): RUN` headers known-red segments on, and they ask
# the pack's vendored known-red whether a red is already known on the base
# branch. Preflight also skips a phase an open base-red bead already covers.
# The refinery's run-tests writes the same kind of log, and handle-failures
# classifies it through known-red before it diagnoses or files anything.
#
# Every block is EXECUTED from the shipped formula text, never transcribed:
# resolve-known-red, gate-run, known-red-phase-skip, preflight's own
# preflight-phases and preflight-red, and the refinery's refinery-gates,
# refinery-known-red-match and refinery-known-red-file. They run against a stub `gc` that answers
# `gc formula list --json` from a canned file and forwards every ledger call to
# tests/fixtures/known_red/fake_gc.py, and against the REAL
# gastown/assets/scripts/known-red, so a drift between the formula and the
# matcher's output format fails here. The blocks are sourced through
# `bash -c '... "$1"'`, so single-quoted `$1` is the point.
# shellcheck disable=SC2016
set -uo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
FORMULA="$ROOT/gastown/formulas/mol-polecat-work.toml"
REFINERY="$ROOT/gastown/formulas/mol-refinery-patrol.toml"
KNOWN_RED="$ROOT/gastown/assets/scripts/known-red"
FAKE_GC="$ROOT/tests/fixtures/known_red/fake_gc.py"

WORK_BEAD="gcp-work"
FAILURES=0

fail() {
    echo "FAIL: $*" >&2
    FAILURES=$((FAILURES + 1))
}

# (f) preflight-tests overrides the base step with the base's title and needs,
# and the shared blocks are identical wherever they appear.
test_f_structure() {
    python3 - "$FORMULA" <<'PY' || fail "(f) the known-red blocks are misplaced or have drifted apart (see above)"
import sys
import tomllib

doc = tomllib.load(open(sys.argv[1], "rb"))
steps = {step["id"]: step for step in doc["steps"]}
problems = []

ids = [step["id"] for step in doc["steps"]]
if ids != ["workspace-setup", "preflight-tests", "self-review", "submit-and-exit"]:
    problems.append(f"steps are {ids}, want preflight-tests between workspace-setup and self-review")
pre = steps.get("preflight-tests")
if pre is None:
    problems.append("no preflight-tests step")
else:
    if pre.get("title") != "Verify pre-flights pass on base branch":
        problems.append(f"preflight-tests title is {pre.get('title')!r}, want the base's")
    if pre.get("needs") != ["workspace-setup"]:
        problems.append(f"preflight-tests needs {pre.get('needs')!r}, want ['workspace-setup']")


def block(text, name):
    begin, end = f"# --- {name}:begin ---", f"# --- {name}:end ---"
    if text.count(begin) != 1 or text.count(end) != 1:
        return None
    body = text.split(begin, 1)[1].split(end, 1)[0]
    return [line.lstrip() for line in body.strip().split("\n")]


texts = {sid: step.get("description", "") for sid, step in steps.items()}
for name, want in (
    ("resolve-known-red", ["preflight-tests", "self-review"]),
    ("gate-run", ["preflight-tests", "self-review"]),
    ("known-red-phase-skip", ["preflight-tests"]),
):
    begin = f"# --- {name}:begin ---"
    holders = sorted(sid for sid, text in texts.items() if begin in text)
    if holders != sorted(want):
        problems.append(f"{name} lives in {holders}, want exactly {sorted(want)}")
        continue
    copies = {sid: block(texts[sid], name) for sid in want}
    for sid, lines in copies.items():
        if lines is None:
            problems.append(f"{sid}: want exactly one {name} begin and one end sentinel")
    first = copies[want[0]]
    for sid in want[1:]:
        if first is not None and copies[sid] is not None and copies[sid] != first:
            problems.append(f"{name}: {sid}'s copy differs from {want[0]}'s after stripping leading whitespace")

for problem in problems:
    print(f"  {problem}", file=sys.stderr)
sys.exit(1 if problems else 0)
PY
}

# extract_block <formula> <step> <name> <outfile> [var=value ...] — one
# sentinel block from that step, rendered with the formula's [vars] defaults
# plus the given overrides. Anything left unrendered is a hard error: a block
# still holding a literal "{{...}}" would run and could pass vacuously.
extract_block() {
    python3 - "$@" <<'PY'
import re
import sys
import tomllib

formula, step, name, out, *overrides = sys.argv[1:]
begin, end = f"# --- {name}:begin ---", f"# --- {name}:end ---"
doc = tomllib.load(open(formula, "rb"))
text = next((s.get("description", "") for s in doc["steps"] if s["id"] == step), "")
if begin not in text:
    sys.exit(f"no {name} block in {step} of {formula}")
block = text.split(begin, 1)[1].split(end, 1)[0]
values = {n: spec.get("default", "") for n, spec in (doc.get("vars") or {}).items()}
values.update(kv.split("=", 1) for kv in overrides)
block = re.sub(r"\{\{\s*(\w+)\s*\}\}", lambda m: values.get(m.group(1), m.group(0)), block)
leftover = sorted(set(re.findall(r"\{\{[^}]*\}\}", block)))
if leftover:
    sys.exit(f"{name} block has unrendered placeholders: {leftover}")
open(out, "w").write(block)
PY
}

# The stub gc. `formula list` answers from $GC_STUB_FORMULAS (or fails when it
# is unset), `convoy status` names one work bead, `mail send`, `session
# nudge`, `runtime drain-ack` and a ledger `note` are journalled to
# $GC_STUB_CALLS, and every other ledger call goes to
# the fake ledger known-red's own tests use. Anything else fails loudly.
write_gc_stub() {
    cat >"$TMP/bin/gc" <<'STUB'
#!/usr/bin/env bash
if [ "${1:-}" = "bd" ] && [ "${2:-}" = "note" ]; then
    printf 'note %s: %s\n' "$3" "$(cat)" >>"$GC_STUB_CALLS"
    exit 0
fi
case "${1:-} ${2:-}" in
"formula list")
    [ -n "${GC_STUB_FORMULAS:-}" ] || exit 1
    cat "$GC_STUB_FORMULAS"
    ;;
"convoy status")
    printf '{"children":[{"id":"%s"}]}\n' "$GC_STUB_WORK_BEAD"
    ;;
"mail send")
    shift 2
    printf 'mail %s\n' "$*" >>"$GC_STUB_CALLS"
    ;;
"session nudge")
    shift 2
    printf 'nudge %s\n' "$*" >>"$GC_STUB_CALLS"
    ;;
"runtime drain-ack")
    printf 'runtime drain-ack\n' >>"$GC_STUB_CALLS"
    ;;
"bd "*)
    exec python3 "$FAKE_GC" "$@"
    ;;
*)
    echo "stub gc: unexpected invocation: $*" >&2
    exit 64
    ;;
esac
STUB
    chmod +x "$TMP/bin/gc"
}

# make_pack <dir> [with-known-red] — a pack tree holding the formula and, when
# asked, an executable known-red that is the real one.
make_pack() {
    mkdir -p "$1/formulas" "$1/assets/scripts"
    : >"$1/formulas/mol-polecat-work.toml"
    if [ -n "${2:-}" ]; then
        ln -sf "$KNOWN_RED" "$1/assets/scripts/known-red"
    fi
}

# formulas_json <pack> [refinery-pack] — the canned `gc formula list --json`
# answer. mol-refinery-patrol's source is in refinery-pack, which defaults to
# the same pack.
formulas_json() {
    printf '{"formulas":[{"name":"mol-polecat-base","source":"/elsewhere/formulas/mol-polecat-base.toml"},{"name":"mol-polecat-work","source":"%s/formulas/mol-polecat-work.toml"},{"name":"mol-refinery-patrol","source":"%s/formulas/mol-refinery-patrol.toml"}]}\n' "$1" "${2:-$1}" \
        >"$TMP/formulas.json"
}

# seed_ledger [id:phase:status ...] — the fake ledger's base-red beads. The
# first bead's last-seen is old, so `known-red list` also prints its STALE
# trailer, which kr_phase_covered must not read as a bead row.
seed_ledger() {
    python3 - "$TMP/ledger.json" "$@" <<'PY'
import json
import sys

path, *specs = sys.argv[1:]
beads = {}
for i, spec in enumerate(specs):
    bid, phase, status = spec.split(":")
    seen = "2026-01-01T00:00:00Z" if i == 0 else "2099-01-01T00:00:00Z"
    beads[bid] = {
        "id": bid, "title": f"base red {bid}", "status": status, "priority": 1,
        "labels": ["base-red"], "created_at": "2026-09-01T00:00:00Z",
        "metadata": {
            "base_red_phase": phase,
            "base_red_sigs": f"go:internal/{bid}.TestRed",
            "base_red_last_seen": f"abc123@{seen}",
        },
    }
json.dump({"prefix": "gcp", "beads": beads}, open(path, "w"))
PY
    : >"$TMP/fake_gc.log"
}

# run_blocks <file...> -- [env assignments...] — sources the blocks in order
# in one shell from $TMP/repo, the way an agent runs the step's one fenced
# block. Sets RUN_CODE and leaves the output in $TMP/run.log.
run_blocks() {
    local -a files=()
    while [ "$#" -gt 0 ] && [ "$1" != "--" ]; do
        files+=("$1")
        shift
    done
    [ "$#" -gt 0 ] && shift
    : >"$TMP/calls.log"
    (
        cd "$TMP/repo" &&
            env -u GC_CITY -u GC_CITY_PATH -u GC_PACK_DIR -u GC_STUB_FORMULAS \
                -u GC_RIG -u FAKE_GC_FAIL -u FAKE_GC_FAIL_ON \
                PATH="$TMP/bin:$PATH" \
                FAKE_GC="$FAKE_GC" \
                FAKE_GC_DB="$TMP/ledger.json" \
                FAKE_GC_LOG="$TMP/fake_gc.log" \
                GC_STUB_CALLS="$TMP/calls.log" \
                GC_STUB_WORK_BEAD="$WORK_BEAD" \
                "$@" \
                bash -c 'set -uo pipefail; for f in "$@"; do . "$f"; done' _ "${files[@]}"
    ) >"$TMP/run.log" 2>&1
    RUN_CODE=$?
    if grep -q '^stub gc' "$TMP/run.log"; then
        fail "a block made a call the stub does not model: $(cat "$TMP/run.log")"
    fi
}

# resolve_in <env...> — runs resolve_known_red mol-polecat-work; its stdout is
# written to $TMP/resolved.
resolve_in() {
    printf '%s\n' 'resolve_known_red mol-polecat-work >"$RESOLVED"' >"$TMP/call-resolve.sh"
    run_blocks "$TMP/resolve.sh" "$TMP/call-resolve.sh" -- RESOLVED="$TMP/resolved" "$@"
}

# (a) resolve_known_red
test_a_resolves_from_the_formula_source() {
    make_pack "$TMP/pack-a" yes
    formulas_json "$TMP/pack-a"
    : >"$TMP/resolved"
    resolve_in GC_STUB_FORMULAS="$TMP/formulas.json"
    [ "$RUN_CODE" -eq 0 ] || fail "(a) resolve_known_red must return 0 when the formula's pack has known-red: $(cat "$TMP/run.log")"
    [ "$(cat "$TMP/resolved")" = "$TMP/pack-a/assets/scripts/known-red" ] ||
        fail "(a) want the formula source's pack copy, got '$(cat "$TMP/resolved")'"
}

test_a_falls_back_to_gc_pack_dir() {
    make_pack "$TMP/pack-empty"
    make_pack "$TMP/pack-env" yes
    formulas_json "$TMP/pack-empty"
    : >"$TMP/resolved"
    resolve_in GC_STUB_FORMULAS="$TMP/formulas.json" GC_PACK_DIR="$TMP/pack-env"
    [ "$RUN_CODE" -eq 0 ] || fail "(a) resolve_known_red must fall back to GC_PACK_DIR: $(cat "$TMP/run.log")"
    [ "$(cat "$TMP/resolved")" = "$TMP/pack-env/assets/scripts/known-red" ] ||
        fail "(a) want GC_PACK_DIR's copy, got '$(cat "$TMP/resolved")'"
    # The same fallback when gc cannot list formulas at all.
    : >"$TMP/resolved"
    resolve_in GC_PACK_DIR="$TMP/pack-env"
    [ "$(cat "$TMP/resolved")" = "$TMP/pack-env/assets/scripts/known-red" ] ||
        fail "(a) a failed formula list must still fall back to GC_PACK_DIR, got '$(cat "$TMP/resolved")'"
}

test_a_returns_1_when_neither_exists() {
    make_pack "$TMP/pack-empty"
    formulas_json "$TMP/pack-empty"
    : >"$TMP/resolved"
    resolve_in GC_STUB_FORMULAS="$TMP/formulas.json" GC_PACK_DIR="$TMP/pack-empty"
    [ "$RUN_CODE" -eq 1 ] || fail "(a) resolve_known_red must return 1 when no known-red exists, got $RUN_CODE"
    [ ! -s "$TMP/resolved" ] || fail "(a) a failed resolve must print nothing, got '$(cat "$TMP/resolved")'"
}

# gate <phase> <command> — runs gate_run once against $TMP/gate.log.
gate() {
    printf 'gate_run %q %q\n' "$1" "$2" >"$TMP/call-gate.sh"
    run_blocks "$TMP/gate.sh" "$TMP/call-gate.sh" -- GATE_LOG="$TMP/gate.log"
}

# (b) gate_run
test_b_gate_run() {
    : >"$TMP/gate.log"
    gate typecheck 'echo checked'
    [ "$RUN_CODE" -eq 0 ] || fail "(b) a passing command must return 0, got $RUN_CODE"
    [ "$(cat "$TMP/gate.log")" = "$(printf 'gate(typecheck): RUN echo checked\nchecked\ngate(typecheck): PASS')" ] ||
        fail "(b) a pass must write RUN, the output and PASS, got: $(cat "$TMP/gate.log")"

    : >"$TMP/gate.log"
    gate lint 'echo broken; exit 3'
    [ "$RUN_CODE" -eq 1 ] || fail "(b) a failing command must return 1, got $RUN_CODE"
    [ "$(cat "$TMP/gate.log")" = "$(printf 'gate(lint): RUN echo broken; exit 3\nbroken\ngate(lint): FAIL')" ] ||
        fail "(b) a failure must write RUN, the output and FAIL, got: $(cat "$TMP/gate.log")"
    grep -q '^gate(lint): FAIL$' "$TMP/run.log" || fail "(b) a failure must print the log's tail"

    : >"$TMP/gate.log"
    gate build ''
    [ "$RUN_CODE" -eq 0 ] || fail "(b) an empty command must return 0, got $RUN_CODE"
    [ ! -s "$TMP/gate.log" ] || fail "(b) an empty command must write nothing, got: $(cat "$TMP/gate.log")"

    # winnow's shape: double quotes and $(...) in the rendered var.
    printf '#!/usr/bin/env bash\necho "stub-gate ran phase=$1"\n' >"$TMP/repo/stub-gate.sh"
    : >"$TMP/gate.log"
    gate test 'bash "$(pwd)/stub-gate.sh" test'
    [ "$RUN_CODE" -eq 0 ] || fail "(b) winnow's command shape must run: $(cat "$TMP/run.log")"
    grep -qx 'stub-gate ran phase=test' "$TMP/gate.log" ||
        fail "(b) winnow's command output must land in the log, got: $(cat "$TMP/gate.log")"
}

# (c) The real known-red reads a gate_run log's pytest red as its nodeid.
test_c_known_red_reads_a_gate_run_pytest_red() {
    : >"$TMP/gate.log"
    gate typecheck 'echo fine'
    gate pytest 'echo "FAILED tests/test_wiring.py::test_red - assert 1 == 2"; echo "1 failed in 0.1s"; exit 1'
    local sigs
    sigs=$(cd "$TMP/repo" && "$KNOWN_RED" sigs "$TMP/gate.log")
    [ "$sigs" = "pytest:tests/test_wiring.py::test_red" ] ||
        fail "(c) known-red sigs should be exactly the pytest nodeid, got: $sigs"
}

# covered <phase> [env...] — runs kr_phase_covered with the real known-red.
covered() {
    local phase="$1"
    shift
    printf 'kr_phase_covered %q\n' "$phase" >"$TMP/call-covered.sh"
    run_blocks "$TMP/skip.sh" "$TMP/call-covered.sh" -- KR="$KNOWN_RED" "$@"
}

# (d) kr_phase_covered against the fake ledger
test_d_phase_covered() {
    seed_ledger gcp-bt1:test:open gcp-bt2:test,lint:blocked gcp-py1:pytest:open
    covered test
    [ "$RUN_CODE" -eq 0 ] || fail "(d) a phase=test base-red must cover test: $(cat "$TMP/run.log")"
    [ "$(cat "$TMP/run.log")" = "gcp-bt1 gcp-bt2" ] ||
        fail "(d) want exactly the covering ids 'gcp-bt1 gcp-bt2', got: $(cat "$TMP/run.log")"

    seed_ledger gcp-bt1:test:open gcp-py1:pytest:open
    covered lint
    [ "$RUN_CODE" -eq 1 ] || fail "(d) a phase=test base-red must not cover lint, got $RUN_CODE: $(cat "$TMP/run.log")"

    seed_ledger gcp-py1:pytest:open
    covered test
    [ "$RUN_CODE" -eq 1 ] || fail "(d) a phase=pytest base-red must not cover test (gcp-98gh), got $RUN_CODE: $(cat "$TMP/run.log")"

    seed_ledger gcp-bt1:test:open
    covered test FAKE_GC_FAIL=1
    [ "$RUN_CODE" -eq 1 ] || fail "(d) a failing ledger must never skip a phase, got $RUN_CODE: $(cat "$TMP/run.log")"
    [ ! -s "$TMP/run.log" ] || fail "(d) a failing ledger must print no ids, got: $(cat "$TMP/run.log")"

    # The real known-red is always self-consistent, so a stand-in pins the
    # fail-closed checks it cannot reach: a covering answer from a list that
    # exited non-zero, a count that disagrees with the rows, and a first line
    # that does not parse. None of them may skip a phase.
    local header='known-red: 1 base-red bead(s) in ledger gcp (statuses open,in_progress,blocked,deferred, phase test); 0 STALE (unseen >72h)'
    local row='gcp-bt1        open        P1  phase=test  last seen 1h ago @abc123'
    local case_name output code
    for case_name in nonzero-exit count-mismatch unparseable; do
        case "$case_name" in
        nonzero-exit) output=$(printf '%s\n%s\n    go:internal/x.TestRed' "$header" "$row"); code=2 ;;
        count-mismatch) output=$(printf '%s\n%s' "${header/1 base-red/2 base-red}" "$row"); code=0 ;;
        unparseable) output=$(printf 'WARN: 1 base-red bead(s) skipped\n%s' "$row"); code=0 ;;
        esac
        printf '%s\n' "$output" >"$TMP/kr-output"
        printf '#!/usr/bin/env bash\ncat %q\nexit %s\n' "$TMP/kr-output" "$code" >"$TMP/fake-kr"
        chmod +x "$TMP/fake-kr"
        printf 'kr_phase_covered test\n' >"$TMP/call-covered.sh"
        run_blocks "$TMP/skip.sh" "$TMP/call-covered.sh" -- KR="$TMP/fake-kr"
        [ "$RUN_CODE" -eq 1 ] || fail "(d) $case_name must not cover the phase, got $RUN_CODE: $(cat "$TMP/run.log")"
    done
    # The same stand-in, consistent and exiting 0, does cover: the cases above
    # fail for their own reason, not because the stand-in is unreadable.
    printf '%s\n%s\n' "$header" "$row" >"$TMP/kr-output"
    printf '#!/usr/bin/env bash\ncat %q\n' "$TMP/kr-output" >"$TMP/fake-kr"
    run_blocks "$TMP/skip.sh" "$TMP/call-covered.sh" -- KR="$TMP/fake-kr"
    [ "$RUN_CODE" -eq 0 ] && [ "$(cat "$TMP/run.log")" = "gcp-bt1" ] ||
        fail "(d) a consistent stand-in answer must cover test, got $RUN_CODE: $(cat "$TMP/run.log")"
}

# preflight <env...> — the preflight §1 block rendered with stub phase
# commands that record their invocation, then the §2/§3 block. typecheck uses
# winnow's quoting shape.
preflight() {
    : >"$TMP/invoked"
    printf '#!/usr/bin/env bash\necho "$1" >>"$INVOKED"\n' >"$TMP/repo/stub-gate.sh"
    extract_block "$FORMULA" preflight-tests preflight-phases "$TMP/phases.sh" \
        typecheck_command='bash "$(pwd)/stub-gate.sh" typecheck' \
        lint_command='echo lint >>"$INVOKED"' \
        test_command="${PREFLIGHT_TEST:-echo test >>\"\$INVOKED\"}" || return 1
    extract_block "$FORMULA" preflight-tests preflight-red "$TMP/red.sh" base_branch=integration convoy_id=gcp-convoy binding_prefix=gastown. || return 1
    run_blocks "$TMP/resolve.sh" "$TMP/gate.sh" "$TMP/skip.sh" "$TMP/phases.sh" "$TMP/red.sh" -- \
        GC_STUB_FORMULAS="$TMP/formulas.json" INVOKED="$TMP/invoked" "$@"
}

# (e) the preflight loop skips a phase an open base-red covers, and only it.
test_e_preflight_skips_only_the_covered_phase() {
    make_pack "$TMP/pack-a" yes
    formulas_json "$TMP/pack-a"
    seed_ledger gcp-bt1:test:open
    preflight || { fail "(e) could not render the preflight blocks"; return; }
    local log
    log="$(git -C "$TMP/repo" rev-parse --absolute-git-dir)/preflight-gate.log"
    [ "$RUN_CODE" -eq 0 ] || fail "(e) the preflight blocks exited $RUN_CODE: $(cat "$TMP/run.log")"
    grep -qx 'typecheck' "$TMP/invoked" || fail "(e) typecheck must run, invoked: $(cat "$TMP/invoked")"
    grep -qx 'lint' "$TMP/invoked" || fail "(e) lint must run, invoked: $(cat "$TMP/invoked")"
    ! grep -qx 'test' "$TMP/invoked" || fail "(e) test must NOT run on base while gcp-bt1 covers it"
    grep -qx 'phase test not re-run on base: known red gcp-bt1' "$log" ||
        fail "(e) the log must say why test was skipped, got: $(cat "$log")"
    grep -q '^PRE-FLIGHTS GREEN' "$TMP/run.log" || fail "(e) a skipped phase is not a failure, got: $(cat "$TMP/run.log")"
    [ ! -s "$TMP/calls.log" ] || fail "(e) a green preflight must not note or mail, got: $(cat "$TMP/calls.log")"

    # Without known-red every phase runs.
    formulas_json "$TMP/pack-empty"
    make_pack "$TMP/pack-empty"
    preflight || return
    grep -qx 'test' "$TMP/invoked" || fail "(e) without known-red the test phase must run, invoked: $(cat "$TMP/invoked")"
    grep -q '^WARN known-red not found' "$TMP/run.log" || fail "(e) a missing known-red must WARN, got: $(cat "$TMP/run.log")"
}

# The preflight red branch acts on known-red's exit code.
test_preflight_red_known_notes_and_files_nothing() {
    make_pack "$TMP/pack-a" yes
    formulas_json "$TMP/pack-a"
    seed_ledger gcp-lt1:lint:open
    python3 - "$TMP/ledger.json" <<'PY'
import json, sys
db = json.load(open(sys.argv[1]))
db["beads"]["gcp-lt1"]["metadata"]["base_red_sigs"] = "go:internal/x.TestKnown"
json.dump(db, open(sys.argv[1], "w"))
PY
    PREFLIGHT_TEST='printf "%s\n" "--- FAIL: TestKnown (0.00s)" "FAIL	example.com/org/repo/internal/x	0.1s"; exit 1' preflight
    grep -q '^PRE-FLIGHTS RED, all KNOWN: gcp-lt1' "$TMP/run.log" ||
        fail "an all-KNOWN red must be cited, got: $(cat "$TMP/run.log")"
    { grep -q "^note $WORK_BEAD: " "$TMP/calls.log" && grep -qx 'KNOWN: gcp-lt1' "$TMP/calls.log"; } ||
        fail "the KNOWN id must be noted on the work bead, got: $(cat "$TMP/calls.log")"
    ! grep -q '^mail' "$TMP/calls.log" || fail "an all-KNOWN red must not mail the witness"
    ! grep -q '"create"' "$TMP/fake_gc.log" || fail "an all-KNOWN red must file nothing"
}

test_preflight_red_new_is_filed_and_mailed() {
    make_pack "$TMP/pack-a" yes
    formulas_json "$TMP/pack-a"
    seed_ledger
    PREFLIGHT_TEST='printf "%s\n" "--- FAIL: TestNew (0.00s)" "FAIL	example.com/org/repo/internal/y	0.1s"; exit 1' preflight
    local filed
    filed=$(python3 -c 'import json,sys; print(" ".join(sorted(json.load(open(sys.argv[1]))["beads"])))' "$TMP/ledger.json")
    [ "$filed" = "gcp-fk1" ] || fail "a NEW red must be filed through known-red, ledger holds: $filed"
    [ "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["beads"]["gcp-fk1"]["metadata"]["base_red_phase"])' "$TMP/ledger.json" 2>/dev/null)" = "test" ] ||
        fail "the filed bead must carry phase=test, the name of the var that holds the command"
    grep -q "^mail gastown.witness -s NOTICE: integration has failing pre-flights -m Filed: gcp-fk1" "$TMP/calls.log" ||
        fail "the witness NOTICE must name the filed bead, got: $(cat "$TMP/calls.log")"
}

test_preflight_red_lookup_failure_files_nothing() {
    make_pack "$TMP/pack-a" yes
    formulas_json "$TMP/pack-a"
    seed_ledger
    PREFLIGHT_TEST='printf "%s\n" "--- FAIL: TestNew (0.00s)" "FAIL	example.com/org/repo/internal/y	0.1s"; exit 1' preflight FAKE_GC_FAIL=1
    grep -q 'known-red lookup failed; not filed' "$TMP/calls.log" ||
        fail "a failed lookup must say so to the witness, got: $(cat "$TMP/calls.log")"
    ! grep -q '"create"' "$TMP/fake_gc.log" || fail "a failed lookup must file nothing"
}

# (f2) The refinery reuses the polecat's blocks as identical copies, each in
# the one step that needs it, and keeps its step ids and needs.
test_f2_refinery_structure() {
    python3 - "$REFINERY" "$FORMULA" <<'PY' || fail "(f2) the refinery's known-red blocks are misplaced or have drifted (see above)"
import sys
import tomllib

refinery, polecat = (tomllib.load(open(p, "rb")) for p in sys.argv[1:3])
problems = []

# mol-refinery-patrol's steps at e585cda6, before this wiring.
want_steps = [
    ("validate-identity", None), ("check-inbox", ["validate-identity"]),
    ("find-work", ["check-inbox"]), ("rebase", ["find-work"]),
    ("run-tests", ["rebase"]), ("handle-failures", ["run-tests"]),
    ("merge-push", ["handle-failures"]), ("patrol-summary", ["merge-push"]),
    ("next-iteration", ["patrol-summary"]),
]
got_steps = [(s["id"], s.get("needs")) for s in refinery["steps"]]
if got_steps != want_steps:
    problems.append(f"refinery steps/needs are {got_steps}, want {want_steps}")


def block(text, name):
    begin, end = f"# --- {name}:begin ---", f"# --- {name}:end ---"
    if text.count(begin) != 1 or text.count(end) != 1:
        return None
    body = text.split(begin, 1)[1].split(end, 1)[0]
    return [line.lstrip() for line in body.strip().split("\n")]


texts = {s["id"]: s.get("description", "") for s in refinery["steps"]}
preflight = next(s.get("description", "") for s in polecat["steps"] if s["id"] == "preflight-tests")
for name, want, shared in (
    ("gate-run", ["run-tests"], True),
    ("resolve-known-red", ["handle-failures"], True),
    ("known-red-phase-skip", [], True),
    ("refinery-gates", ["run-tests"], False),
    ("refinery-known-red-match", ["handle-failures"], False),
    ("refinery-known-red-file", ["handle-failures"], False),
):
    holders = sorted(sid for sid, text in texts.items() if f"# --- {name}:begin ---" in text)
    if holders != want:
        problems.append(f"{name} lives in {holders}, want exactly {want}")
        continue
    for sid in want:
        lines = block(texts[sid], name)
        if lines is None:
            problems.append(f"{sid}: want exactly one {name} begin and one end sentinel")
        elif shared and lines != block(preflight, name):
            problems.append(f"{name}: {sid}'s copy differs from mol-polecat-work preflight-tests' after stripping leading whitespace")

for problem in problems:
    print(f"  {problem}", file=sys.stderr)
sys.exit(1 if problems else 0)
PY
}

# refinery_gates [var=value ...] — run-tests' refinery-gates block, rendered
# with the given vars, run after run-tests' own gate-run copy. Its log is
# $REFINERY_LOG.
refinery_gates() {
    : >"$TMP/invoked"
    extract_block "$REFINERY" run-tests refinery-gates "$TMP/r-gates.sh" "$@" || return 1
    run_blocks "$TMP/r-gate.sh" "$TMP/r-gates.sh" -- INVOKED="$TMP/invoked"
}

# Stub gate commands that record their invocation.
ALL_GATES=(
    setup_command='echo setup >>"$INVOKED"'
    typecheck_command='echo typecheck >>"$INVOKED"'
    lint_command='echo lint >>"$INVOKED"'
    build_command='echo build >>"$INVOKED"'
    test_command='echo test >>"$INVOKED"'
)

# (g) refinery-gates runs every configured gate under its var's name.
test_g_refinery_gates() {
    local phase
    refinery_gates "${ALL_GATES[@]}" run_tests=true || { fail "(g) could not render refinery-gates"; return; }
    [ "$(paste -sd ' ' - <"$TMP/invoked")" = "setup typecheck lint build test" ] ||
        fail "(g) want every gate invoked in order, invoked: $(cat "$TMP/invoked")"
    for phase in setup typecheck lint build test; do
        grep -q "^gate($phase): RUN " "$REFINERY_LOG" && grep -qx "gate($phase): PASS" "$REFINERY_LOG" ||
            fail "(g) want a RUN and a PASS for $phase, log: $(cat "$REFINERY_LOG")"
    done

    refinery_gates "${ALL_GATES[@]}" run_tests=false || return
    ! grep -q '^gate(test)' "$REFINERY_LOG" || fail "(g) run_tests=false must write no test segment, log: $(cat "$REFINERY_LOG")"
    ! grep -qx test "$TMP/invoked" || fail "(g) run_tests=false must not invoke the test command"

    refinery_gates "${ALL_GATES[@]}" run_tests=true lint_command='echo lint >>"$INVOKED"; exit 1' || return
    grep -qx 'gate(lint): FAIL' "$REFINERY_LOG" || fail "(g) a failing lint must write gate(lint): FAIL, log: $(cat "$REFINERY_LOG")"
    grep -qx build "$TMP/invoked" && grep -qx test "$TMP/invoked" ||
        fail "(g) the gates after a FAIL must still run, invoked: $(cat "$TMP/invoked")"

    # A second run truncates the log: the FAIL above is gone.
    refinery_gates "${ALL_GATES[@]}" run_tests=true typecheck_command='' || return
    ! grep -q ': FAIL$' "$REFINERY_LOG" || fail "(g) a second run must truncate the log, log: $(cat "$REFINERY_LOG")"
    ! grep -q '^gate(typecheck)' "$REFINERY_LOG" || fail "(g) an empty command must write no segment, log: $(cat "$REFINERY_LOG")"
    ! grep -qx typecheck "$TMP/invoked" || fail "(g) an empty command must invoke nothing"
}

GO_KNOWN_RED='printf "%s\n" "--- FAIL: TestKnown (0.00s)" "FAIL	example.com/org/repo/internal/x	0.1s"; exit 1'
GO_NEW_RED='printf "%s\n" "--- FAIL: TestNew (0.00s)" "FAIL	example.com/org/repo/internal/y	0.1s"; exit 1'

# red_log <test command> — a refinery gate log whose test gate runs it.
red_log() {
    refinery_gates "${ALL_GATES[@]}" run_tests=true test_command="$1" || fail "could not write a refinery gate log"
}

# ledger_sig <id> <sig> [closed] — sets a seeded bead's sig; "closed" also
# closes it a day ago, inside known-red's 7-day FIXED-UPSTREAM window.
ledger_sig() {
    python3 - "$TMP/ledger.json" "$@" <<'PY'
import json
import sys
from datetime import datetime, timedelta, timezone

path, bid, sig, *closed = sys.argv[1:]
db = json.load(open(path))
bead = db["beads"][bid]
bead["metadata"]["base_red_sigs"] = sig
if closed:
    bead["status"] = "closed"
    bead["closed_at"] = (datetime.now(timezone.utc) - timedelta(days=1)).strftime("%Y-%m-%dT%H:%M:%SZ")
json.dump(db, open(path, "w"))
PY
}

# refinery_match <env...> — handle-failures step 0: its resolve-known-red copy,
# then refinery-known-red-match.
refinery_match() {
    run_blocks "$TMP/r-resolve.sh" "$TMP/r-match.sh" -- \
        GC_STUB_FORMULAS="$TMP/formulas.json" WORK="$WORK_BEAD" TARGET=integration "$@"
}

# refinery_file <env...> — handle-failures §3's refinery-known-red-file, alone.
refinery_file() {
    run_blocks "$TMP/r-file.sh" -- WORK="$WORK_BEAD" TARGET=integration "$@"
}

no_create() {
    ! grep -q '"create"' "$TMP/fake_gc.log" || fail "$1 must file nothing, ledger calls: $(cat "$TMP/fake_gc.log")"
}

# (h) refinery-known-red-match classifies the gate log through known-red.
test_h_refinery_match() {
    # The refinery formula sits in its own pack: the resolve keys on it.
    make_pack "$TMP/pack-p"
    make_pack "$TMP/pack-r" yes
    formulas_json "$TMP/pack-p" "$TMP/pack-r"

    seed_ledger gcp-lt1:test:open
    ledger_sig gcp-lt1 go:internal/x.TestKnown
    red_log "$GO_KNOWN_RED"
    refinery_match
    [ "$(cat "$KR_PATH_FILE")" = "$TMP/pack-r/assets/scripts/known-red" ] ||
        fail "(h) want the refinery pack's known-red in the path file, got '$(cat "$KR_PATH_FILE")': $(cat "$TMP/run.log")"
    grep -q '^ALL REDS KNOWN: gcp-lt1\.' "$TMP/run.log" || fail "(h) an all-KNOWN red must be cited, got: $(cat "$TMP/run.log")"
    { grep -q "^note $WORK_BEAD: " "$TMP/calls.log" && grep -qx 'KNOWN: gcp-lt1' "$TMP/calls.log"; } ||
        fail "(h) the KNOWN id must be noted on the work bead, got: $(cat "$TMP/calls.log")"
    ! grep -q '^mail' "$TMP/calls.log" || fail "(h) an all-KNOWN red must not mail"
    no_create "(h) an all-KNOWN red"

    seed_ledger
    red_log "$GO_NEW_RED"
    refinery_match
    grep -q '^DIAGNOSE' "$TMP/run.log" && grep -Eq '^NEW +- +go:internal/y\.TestNew' "$TMP/run.log" ||
        fail "(h) a NEW red must be listed for diagnosis, got: $(cat "$TMP/run.log")"
    [ ! -s "$TMP/calls.log" ] || fail "(h) a NEW red must not note or mail, got: $(cat "$TMP/calls.log")"
    no_create "(h) a NEW red at match"

    # Closed a day ago, and no commit in the test repo cites it: exit 3.
    seed_ledger gcp-c1:test:open
    ledger_sig gcp-c1 go:internal/x.TestKnown closed
    red_log "$GO_KNOWN_RED"
    refinery_match
    grep -q '^DIAGNOSE' "$TMP/run.log" && grep -Eq '^FIXED-UPSTREAM +gcp-c1 +go:internal/x\.TestKnown' "$TMP/run.log" ||
        fail "(h) a FIXED-UPSTREAM red must be diagnosed at the refinery, got: $(cat "$TMP/run.log")"
    ! grep -q 'ALL REDS KNOWN' "$TMP/run.log" || fail "(h) a FIXED-UPSTREAM red must never merge past as KNOWN"

    seed_ledger
    red_log "$GO_NEW_RED"
    refinery_match FAKE_GC_FAIL=1
    grep -q 'known-red lookup failed' "$TMP/run.log" || fail "(h) a failed lookup must say so, got: $(cat "$TMP/run.log")"
    no_create "(h) a failed lookup"

    formulas_json "$TMP/pack-p"
    refinery_match
    grep -q '^WARN known-red unavailable' "$TMP/run.log" || fail "(h) no resolvable known-red must WARN, got: $(cat "$TMP/run.log")"
    [ -e "$KR_PATH_FILE" ] && [ ! -s "$KR_PATH_FILE" ] || fail "(h) the WARN case must leave the path file empty"

    formulas_json "$TMP/pack-p" "$TMP/pack-r"
    : >"$REFINERY_LOG"
    refinery_match
    grep -q '^WARN known-red unavailable' "$TMP/run.log" || fail "(h) an empty gate log must WARN, got: $(cat "$TMP/run.log")"
}

# (i) refinery-known-red-file files through known-red, in a shell of its own.
test_i_refinery_file() {
    make_pack "$TMP/pack-p"
    make_pack "$TMP/pack-r" yes

    # known-red did not run in step 0.
    seed_ledger
    red_log "$GO_NEW_RED"
    formulas_json "$TMP/pack-p"
    refinery_match
    refinery_file
    grep -q 'known-red did not run in step 0' "$TMP/run.log" || fail "(i) an empty path file must hand over to DUP_KEYWORD, got: $(cat "$TMP/run.log")"
    [ ! -s "$TMP/calls.log" ] || fail "(i) an empty path file must not mail, got: $(cat "$TMP/calls.log")"
    no_create "(i) an empty path file"

    formulas_json "$TMP/pack-p" "$TMP/pack-r"
    seed_ledger
    red_log "$GO_NEW_RED"
    refinery_match
    refinery_file
    local filed phase from
    filed=$(python3 -c 'import json,sys; print(" ".join(sorted(json.load(open(sys.argv[1]))["beads"])))' "$TMP/ledger.json")
    [ "$filed" = "gcp-fk1" ] || fail "(i) a NEW red must be filed exactly once, ledger holds: '$filed', output: $(cat "$TMP/run.log")"
    read -r phase from < <(python3 -c 'import json,sys; m=json.load(open(sys.argv[1]))["beads"]["gcp-fk1"]["metadata"]; print(m["base_red_phase"], m["base_red_from"])' "$TMP/ledger.json" 2>/dev/null)
    [ "$phase $from" = "test $WORK_BEAD" ] || fail "(i) want base_red_phase=test and base_red_from=$WORK_BEAD, got '$phase $from'"
    grep -q '^FILED: gcp-fk1\.' "$TMP/run.log" || fail "(i) the output must name the filed bead, got: $(cat "$TMP/run.log")"

    seed_ledger
    red_log 'echo "something broke"; exit 1'
    refinery_match
    refinery_file
    no_create "(i) a red with no stable id"
    grep -q 'DUP_KEYWORD' "$TMP/run.log" || fail "(i) a raw red must be handed to the DUP_KEYWORD block, got: $(cat "$TMP/run.log")"

    seed_ledger
    red_log "$GO_NEW_RED"
    refinery_match
    refinery_file FAKE_GC_FAIL_ON=create
    [ "$RUN_CODE" -eq 1 ] || fail "(i) a failed file must exit 1, got $RUN_CODE: $(cat "$TMP/run.log")"
    grep -q '^mail mayor/ -s ESCALATION: refinery known-red file failed' "$TMP/calls.log" ||
        fail "(i) a failed file must escalate to the mayor, got: $(cat "$TMP/calls.log")"
    grep -q '^nudge gastown.witness KNOWN-RED HALT' "$TMP/calls.log" ||
        fail "(i) a failed file must nudge the witness, got: $(cat "$TMP/calls.log")"
    grep -qx 'runtime drain-ack' "$TMP/calls.log" || fail "(i) a failed file must drain-ack, got: $(cat "$TMP/calls.log")"
    [ "$(python3 -c 'import json,sys; print(len(json.load(open(sys.argv[1]))["beads"]))' "$TMP/ledger.json")" = 0 ] ||
        fail "(i) a failed file must leave nothing filed"

    seed_ledger gcp-c1:test:open
    ledger_sig gcp-c1 go:internal/x.TestKnown closed
    red_log "$GO_KNOWN_RED"
    refinery_match
    refinery_file
    no_create "(i) a FIXED-UPSTREAM red"
    [ "$(grep -c '^nudge gastown.witness ' "$TMP/calls.log")" = 1 ] && grep -q '^nudge gastown.witness KNOWN-RED: .*gcp-c1' "$TMP/calls.log" ||
        fail "(i) a FIXED-UPSTREAM red must nudge the witness once, naming gcp-c1, got: $(cat "$TMP/calls.log")"
    [ "$(awk '/^nudge /' "$TMP/calls.log" | cut -d' ' -f3- | wc -c)" -le 201 ] ||
        fail "(i) the nudge must be 200 characters or less"
}

TMP=$(mktemp -d "${TMPDIR:-/tmp}/gastown-known-red-wiring.XXXXXX") || exit 1
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin" "$TMP/repo"
git -C "$TMP/repo" init -q || exit 1
# One commit citing no bead: known-red's FIXED-UPSTREAM check runs `git log
# HEAD`, which fails on an empty repo.
git -C "$TMP/repo" -c user.name=test -c user.email=test@example.com commit -q --allow-empty -m "initial" || exit 1
REFINERY_LOG="$TMP/repo/.git/refinery-gate.log"
KR_PATH_FILE="$TMP/repo/.git/refinery-known-red.path"
write_gc_stub
seed_ledger

test_f_structure
test_f2_refinery_structure

POLECAT_OK=1
for name in resolve-known-red:resolve gate-run:gate known-red-phase-skip:skip; do
    extract_block "$FORMULA" preflight-tests "${name%%:*}" "$TMP/${name#*:}.sh" || { fail "could not extract ${name%%:*}"; POLECAT_OK=0; continue; }
    bash -n "$TMP/${name#*:}.sh" || { fail "extracted ${name%%:*} block is not valid shell"; POLECAT_OK=0; }
done
if [ "$POLECAT_OK" -ne 1 ]; then
    echo "$FAILURES test(s) failed" >&2
    exit 1
fi

test_a_resolves_from_the_formula_source
test_a_falls_back_to_gc_pack_dir
test_a_returns_1_when_neither_exists
test_b_gate_run
test_c_known_red_reads_a_gate_run_pytest_red
test_d_phase_covered
test_e_preflight_skips_only_the_covered_phase
test_preflight_red_known_notes_and_files_nothing
test_preflight_red_new_is_filed_and_mailed
test_preflight_red_lookup_failure_files_nothing

# The refinery's blocks, from mol-refinery-patrol's own copies. A missing one
# fails (g)-(i) without stopping the polecat cases above.
REFINERY_OK=1
for spec in run-tests:gate-run:r-gate run-tests:refinery-gates:r-gates \
    handle-failures:resolve-known-red:r-resolve \
    handle-failures:refinery-known-red-match:r-match \
    handle-failures:refinery-known-red-file:r-file; do
    IFS=: read -r step block out <<<"$spec"
    if ! extract_block "$REFINERY" "$step" "$block" "$TMP/$out.sh" binding_prefix=gastown.; then
        fail "could not extract $block from the refinery's $step"
        REFINERY_OK=0
    elif ! bash -n "$TMP/$out.sh"; then
        fail "the refinery's extracted $block block is not valid shell"
        REFINERY_OK=0
    fi
done
if [ "$REFINERY_OK" -eq 1 ]; then
    test_g_refinery_gates
    test_h_refinery_match
    test_i_refinery_file
else
    fail "(g), (h) and (i) cannot run without the refinery's blocks"
fi

if [ "$FAILURES" -ne 0 ]; then
    echo "$FAILURES test(s) failed" >&2
    exit 1
fi
echo "all known-red wiring tests passed"
