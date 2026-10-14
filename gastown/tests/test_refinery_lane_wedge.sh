#!/usr/bin/env bash
# Contract tests for lane-wedge.sh and the find-work block that reads it (gcp-ubv2).
#
# When the target branch itself is red, the rig's pre-push gate refuses every
# merge's push and merge-push.sh returns status 7. The refinery used to drain
# with the bead still assigned, so the next fresh session re-selected the same
# head, was refused again, and drained again until the restart circuit breaker
# opened and kept the lane down for 80 minutes (feryn, 2026-10-01).
#
# lane-wedge.sh parks the lane instead. `mark` records the refused head and the
# sha the target stood at, mails the mayor once per (target, sha) and notes the
# bead. `check` holds while the target stands at that sha and clears the marker
# once it moves. The script runs here for real, under a PATH holding only the
# tools the refinery's merge lanes are given, against a bare origin and a clone,
# with a journalling gc stub. The shipped find-work-lane-wedge block is
# extracted from the formula and executed, not transcribed.
#
# The suite fails unless EXPECTED_TESTS tests ran. Point SCRIPT at another copy
# of the script to run the same cases against it.
set -uo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
SCRIPT="${SCRIPT:-$ROOT/gastown/assets/scripts/refinery/lane-wedge.sh}"
FORMULA="$ROOT/gastown/formulas/mol-refinery-patrol.toml"
EXPECTED_TESTS=12

FAILURES=0
PASS_TESTS=0
CASE=""
CASE_START_FAILURES=0
T=""

fail() {
    echo "FAIL[$CASE]: $*" >&2
    FAILURES=$((FAILURES + 1))
}

expect() {
    [ "$2" = "$3" ] || fail "$1 is '$2', want '$3'"
}

# --- stubs and fixture ------------------------------------------------------

# The fake gc. Every call is journalled one per line as `gc <argv>` (a mail
# body spans several lines). Dispatch is on the argv words one at a time. Any
# call it does not model exits 64, so a script that grows a gc call fails here.
write_gc_stub() {
    cat >"$1/gc" <<'STUB'
#!/usr/bin/env bash
ARGS=("$@")
printf 'gc %s\n' "$*" >>"$GC_STUB_LOG"
unexpected() {
    echo "stub gc: unexpected invocation: gc ${ARGS[*]}" >&2
    exit 64
}
case "${1:-}" in
mail)
    [ "${2:-}" = send ] || unexpected
    [ "${GC_STUB_MAIL_FAIL:-}" != 1 ] || exit 1
    ;;
bd)
    case "${2:-}" in
    note)
        cat >>"$GC_STUB_NOTES"
        ;;
    *) unexpected ;;
    esac
    ;;
formula)
    [ "${2:-}" = list ] || unexpected
    echo '{"formulas":[]}'
    ;;
*) unexpected ;;
esac
exit 0
STUB
    chmod +x "$1/gc"
}

# make_bin <dir> — a PATH holding only the tools the merge lanes are given
# (test_refinery_merge_lanes.sh), plus git, and the gc stub.
make_bin() {
    local bin="$1" tool path
    mkdir -p "$bin"
    for tool in bash sh env cat cp mv rm rmdir mkdir mktemp ls ln chmod touch \
        cut dirname basename grep sed awk tr head tail wc sort uniq jq sleep date \
        find xargs expr git; do
        path=$(command -v "$tool") || continue
        ln -sf "$path" "$bin/$tool"
    done
    write_gc_stub "$bin"
}

git_q() { git "$@" >/dev/null 2>&1; }

# new_case <name> — a bare origin with integration, a seed clone that pushes to
# it, the refinery clone, the stubs and the logs.
new_case() {
    CASE="$1"
    CASE_START_FAILURES=$FAILURES
    T=$(mktemp -d)
    ORIGIN="$T/origin.git"
    SEED="$T/seed"
    REFINERY="$T/refinery"
    BIN="$T/bin"
    mkdir -p "$T/home" "$T/tmp"
    git_q init --bare -b integration "$ORIGIN"
    git_q init -b integration "$SEED"
    git -C "$SEED" config user.name seed
    git -C "$SEED" config user.email seed@example.invalid
    git -C "$SEED" config commit.gpgsign false
    echo one >"$SEED/file"
    git_q -C "$SEED" add file
    git_q -C "$SEED" commit -m one
    git_q -C "$SEED" remote add origin "$ORIGIN"
    git_q -C "$SEED" push origin integration
    git_q clone "$ORIGIN" "$REFINERY"
    make_bin "$BIN"
    : >"$T/gc.log"
    : >"$T/notes"
    : >"$T/refused.log"
    MARKER="$(git -C "$REFINERY" rev-parse --absolute-git-dir)/refinery-lane-wedged.json"
}

end_case() {
    if [ "$FAILURES" -ne "$CASE_START_FAILURES" ]; then
        {
            echo "--- $CASE: last run output ---"
            cat "$T/out" 2>/dev/null
            echo "--- $CASE: gc calls ---"
            cat "$T/gc.log"
        } >&2
    fi
    trash "$T" 2>/dev/null || rm -rf "$T"
    PASS_TESTS=$((PASS_TESTS + 1))
}

origin_tip() { git --git-dir="$ORIGIN" rev-parse refs/heads/integration; }

# advance_origin — land one more commit on the origin's integration.
advance_origin() {
    echo "$RANDOM" >>"$SEED/file"
    git_q -C "$SEED" commit -am advance
    git_q -C "$SEED" push origin integration
}

# write_refused_log <sha> — merge-push output that ends in the REFUSED line.
write_refused_log() {
    {
        echo "remote: pre-push gate: lint is red"
        echo "merge-ff-push: push to integration was rejected (status 1); origin/integration is STILL $1."
        echo "merge-ff-push: REFUSED target=integration sha=$1"
    } >"$T/refused.log"
}

# run_script <args...> — run lane-wedge.sh inside the refinery clone under the
# restricted PATH. Sets RC and leaves the output in $T/out.
run_script() {
    (
        cd "$REFINERY" || exit 90
        env -i PATH="$BIN" HOME="$T/home" TMPDIR="$T/tmp" \
            GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 GC_RIG=testrig \
            GC_STUB_LOG="$T/gc.log" GC_STUB_NOTES="$T/notes" \
            GC_STUB_MAIL_FAIL="${MAIL_FAIL:-}" \
            "$BIN/bash" "$SCRIPT" "$@"
    ) >"$T/out" 2>&1
    RC=$?
}

# mark_head <id> [sha] — mark <id> against a log refused at [sha] (the origin tip).
mark_head() {
    local sha="${2:-$(origin_tip)}"
    write_refused_log "$sha"
    run_script mark --work "$1" --log "$T/refused.log"
}

mail_count() { grep -cF "gc mail send mayor/ --notify -s ESCALATION: merge lane wedged on testrig/integration at " "$T/gc.log"; }
marker_field() { jq -r "$@" "$MARKER"; }
output_has() { grep -qE -- "$1" "$T/out"; }

# --- mark -------------------------------------------------------------------

test_mark_new_wedge_records_escalates_and_notes() {
    local sha
    new_case mark_new_wedge
    sha=$(origin_tip)
    mark_head gcp-a
    expect "exit status" "$RC" 0
    output_has "^LANE-WEDGE NEW integration ${sha:0:12} head=gcp-a escalation=sent\$" ||
        fail "no 'LANE-WEDGE NEW' line; output: $(cat "$T/out")"
    [ -f "$MARKER" ] || fail "no marker at $MARKER"
    expect "marker target" "$(marker_field .target)" integration
    expect "marker target_sha" "$(marker_field .target_sha)" "$sha"
    expect "marker heads" "$(marker_field -c .heads)" '["gcp-a"]'
    expect "marker escalation" "$(marker_field .escalation)" sent
    [ -n "$(marker_field .since)" ] || fail "marker has no since"
    expect "mails" "$(mail_count)" 1
    grep -qF "gc mail send mayor/ --notify -s ESCALATION: merge lane wedged on testrig/integration at ${sha:0:12} [HIGH] -m " "$T/gc.log" ||
        fail "the mail subject is not the escalation subject; calls: $(head -n 1 "$T/gc.log")"
    # The release is the marker's removal, and the mail says so on its own line,
    # followed by the line about a fix bead that is not labelled base-red.
    grep -qxF "Release: rm $MARKER" "$T/gc.log" || fail "the mail has no 'Release: rm $MARKER' line"
    grep -A1 -xF "Release: rm $MARKER" "$T/gc.log" | tail -n 1 |
        grep -qxF "A fix bead that is not labelled base-red lands only after that rm." ||
        fail "the line after the release is not the base-red caveat"
    grep -qF "push to integration refused while origin/integration stood at $sha" "$T/notes" ||
        fail "the bead was not noted; notes: $(cat "$T/notes")"
    grep -qF "stays assigned to the refinery and is not rejected" "$T/notes" ||
        fail "the note does not say the bead is kept"
    end_case
}

test_mark_same_sha_escalates_once() {
    new_case mark_same_sha
    mark_head gcp-a
    expect "first exit status" "$RC" 0
    mark_head gcp-b
    expect "second exit status" "$RC" 0
    output_has '^LANE-WEDGE KNOWN integration [0-9a-f]{12} heads=gcp-a,gcp-b escalation=sent$' ||
        fail "no 'LANE-WEDGE KNOWN' line; output: $(cat "$T/out")"
    expect "mails" "$(mail_count)" 1
    expect "marker heads" "$(marker_field -c .heads)" '["gcp-a","gcp-b"]'
    end_case
}

test_mark_new_sha_escalates_again() {
    local second
    new_case mark_new_sha
    mark_head gcp-a
    advance_origin
    second=$(origin_tip)
    mark_head gcp-b
    expect "exit status" "$RC" 0
    output_has "^LANE-WEDGE NEW integration ${second:0:12} head=gcp-b escalation=sent\$" ||
        fail "no 'LANE-WEDGE NEW' line for the second sha; output: $(cat "$T/out")"
    expect "mails" "$(mail_count)" 2
    expect "marker target_sha" "$(marker_field .target_sha)" "$second"
    expect "marker heads" "$(marker_field -c .heads)" '["gcp-b"]'
    end_case
}

test_mark_retries_a_failed_escalation() {
    new_case mark_retry
    MAIL_FAIL=1 mark_head gcp-a
    expect "first exit status" "$RC" 0
    expect "first marker escalation" "$(marker_field .escalation)" failed
    output_has '^WARN lane-wedge: the escalation mail failed' ||
        fail "the failed mail printed no WARN; output: $(cat "$T/out")"
    mark_head gcp-a
    expect "second exit status" "$RC" 0
    expect "second marker escalation" "$(marker_field .escalation)" sent
    expect "mails" "$(mail_count)" 2
    expect "marker heads" "$(marker_field -c .heads)" '["gcp-a"]'
    end_case
}

test_mark_without_a_refused_line_writes_nothing() {
    new_case mark_without_refused_line
    echo "merge-ff-push: push to integration was rejected (status 1)" >"$T/refused.log"
    run_script mark --work gcp-a --log "$T/refused.log"
    expect "exit status" "$RC" 2
    [ ! -e "$MARKER" ] || fail "a marker was written without a REFUSED line"
    [ ! -s "$T/gc.log" ] || fail "gc was called without a REFUSED line: $(cat "$T/gc.log")"
    end_case
}

# --- check ------------------------------------------------------------------

test_check_without_marker_is_none() {
    new_case check_without_marker
    run_script check
    expect "exit status" "$RC" 0
    expect "output" "$(cat "$T/out")" "LANE-WEDGE none"
    end_case
}

test_check_holds_while_target_stands() {
    local sha
    new_case check_holds
    sha=$(origin_tip)
    mark_head gcp-a
    run_script check
    expect "exit status" "$RC" 3
    expect "output" "$(cat "$T/out")" "LANE-WEDGE holds integration ${sha:0:12} skip=gcp-a"
    [ -f "$MARKER" ] || fail "check removed the marker while the target stood still"
    end_case
}

test_check_clears_when_target_moves() {
    local before after
    new_case check_clears
    before=$(origin_tip)
    mark_head gcp-a
    advance_origin
    after=$(origin_tip)
    run_script check
    expect "exit status" "$RC" 0
    expect "output" "$(cat "$T/out")" "LANE-WEDGE cleared integration ${before:0:12} -> ${after:0:12}"
    [ ! -e "$MARKER" ] || fail "the marker survived the target moving"
    end_case
}

test_check_holds_when_fetch_fails() {
    local sha
    new_case check_fetch_fails
    sha=$(origin_tip)
    mark_head gcp-a
    git_q -C "$REFINERY" remote set-url origin "$T/missing.git"
    run_script check
    expect "exit status" "$RC" 3
    expect "output" "$(cat "$T/out")" "LANE-WEDGE holds integration ${sha:0:12} fetch-failed skip=gcp-a"
    [ -f "$MARKER" ] || fail "check removed the marker when it could not fetch"
    end_case
}

test_check_removes_an_unreadable_marker() {
    new_case check_unreadable
    echo "this is not json" >"$MARKER"
    run_script check
    expect "exit status" "$RC" 0
    output_has '^WARN lane-wedge: unreadable marker .* removed\.$' ||
        fail "no unreadable-marker WARN; output: $(cat "$T/out")"
    [ ! -e "$MARKER" ] || fail "the unreadable marker was kept"
    end_case
}

# --- the formula's block and the script's shape -----------------------------

# extract_lane_wedge_block <outfile> — the shipped find-work-lane-wedge block,
# read out of the formula with tomllib.
extract_lane_wedge_block() {
    python3 - "$FORMULA" "$1" <<'PY'
import re
import sys
import tomllib

formula, out = sys.argv[1:3]
begin = "# --- find-work-lane-wedge:begin ---"
end = "# --- find-work-lane-wedge:end ---"
with open(formula, "rb") as handle:
    doc = tomllib.load(handle)
blocks = [
    text.split(begin, 1)[1].split(end, 1)[0]
    for text in (step.get("description", "") for step in doc["steps"])
    if begin in text and end in text
]
if len(blocks) != 1:
    sys.exit(f"expected exactly one find-work-lane-wedge block, found {len(blocks)}")
if re.search(r"\{\{[^}]*\}\}", blocks[0]):
    sys.exit("the find-work-lane-wedge block carries a template placeholder")
with open(out, "w") as handle:
    handle.write(blocks[0])
PY
}

test_find_work_block_sets_the_filter() {
    local last
    new_case find_work_block
    extract_lane_wedge_block "$T/block.sh" || { fail "could not extract the block"; end_case; return; }
    cat >"$T/run-block.sh" <<'RUNNER'
. "$1"
printf '%s|%s\n' "$LANE_WEDGE_ONLY" "$LANE_WEDGE_SKIP"
RUNNER
    # The block finds the script the way merge-batch.sh is found: by the
    # formula's source, else GC_PACK_DIR. The stub lists no formula.
    mkdir -p "$T/pack/assets/scripts/refinery"
    cp -f "$SCRIPT" "$T/pack/assets/scripts/refinery/lane-wedge.sh"
    chmod +x "$T/pack/assets/scripts/refinery/lane-wedge.sh"

    mark_head gcp-a
    (
        cd "$REFINERY" || exit 90
        env -i PATH="$BIN" HOME="$T/home" TMPDIR="$T/tmp" \
            GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 GC_RIG=testrig \
            GC_PACK_DIR="$T/pack" GC_STUB_LOG="$T/gc.log" GC_STUB_NOTES="$T/notes" \
            "$BIN/bash" "$T/run-block.sh" "$T/block.sh"
    ) >"$T/out" 2>&1
    last=$(tail -n 1 "$T/out")
    expect "a held wedge's filter" "$last" "base-red|gcp-a"

    rm -f "$MARKER"
    (
        cd "$REFINERY" || exit 90
        env -i PATH="$BIN" HOME="$T/home" TMPDIR="$T/tmp" \
            GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 GC_RIG=testrig \
            GC_PACK_DIR="$T/pack" GC_STUB_LOG="$T/gc.log" GC_STUB_NOTES="$T/notes" \
            "$BIN/bash" "$T/run-block.sh" "$T/block.sh"
    ) >"$T/out" 2>&1
    last=$(tail -n 1 "$T/out")
    expect "no marker's filter" "$last" "|"
    end_case
}

test_script_has_no_patrol_control() {
    new_case script_shape
    [ -x "$SCRIPT" ] || fail "$SCRIPT is not executable"
    expect "template placeholders in the script" "$(grep -c '{{' "$SCRIPT")" 0
    expect "patrol-loop control in the script" "$(grep -cE 'drain-ack|gc bd mol (wisp|burn)' "$SCRIPT")" 0
    end_case
}

# --- runner -----------------------------------------------------------------

test_mark_new_wedge_records_escalates_and_notes
test_mark_same_sha_escalates_once
test_mark_new_sha_escalates_again
test_mark_retries_a_failed_escalation
test_mark_without_a_refused_line_writes_nothing
test_check_without_marker_is_none
test_check_holds_while_target_stands
test_check_clears_when_target_moves
test_check_holds_when_fetch_fails
test_check_removes_an_unreadable_marker
test_find_work_block_sets_the_filter
test_script_has_no_patrol_control

# A test defined but never called would pass vacuously: every definition needs
# exactly one call line.
while read -r defined; do
    [ "$(grep -cx "$defined" "${BASH_SOURCE[0]}")" = 1 ] || {
        CASE=runner
        fail "$defined is not called exactly once"
    }
done < <(sed -n 's/^\(test_[a-z_]*\)() {$/\1/p' "${BASH_SOURCE[0]}")

if [ "$PASS_TESTS" -ne "$EXPECTED_TESTS" ]; then
    echo "FAIL: $PASS_TESTS of $EXPECTED_TESTS tests ran" >&2
    exit 1
fi
if [ "$FAILURES" -ne 0 ]; then
    echo "$FAILURES failure(s)" >&2
    exit 1
fi
echo "OK: $PASS_TESTS tests passed"
