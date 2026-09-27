#!/usr/bin/env bash
# Contract tests for the polecat's refinery-handoff stamp (gcp-et7g).
#
# The refinery's find-work step orders each priority band by
# `metadata.first_submitted_at`, falling back to `created_at`. That key only
# means "when this bead joined the merge queue" if the polecat's handoff writes
# it, writes it ONCE, and writes it in the same update that names the refinery:
# a later write leaves a window where find-work sees an unstamped bead, and a
# rewrite on resubmit sends a rejected bead to the back of its band instead of
# back to its original place in line.
#
# The block under test is extracted from the shipped formula between its
# handoff-stamp sentinels and EXECUTED against a stub `gc` that really mutates a
# fixture, so every assertion reads what the block's writes left behind.
# Assertions grep a literal shell snippet or the stub's call log, so
# single-quoted `$VAR` is the point, not an error.
# shellcheck disable=SC2016
set -uo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
FORMULA="$ROOT/gastown/formulas/mol-polecat-work.toml"

BEAD="gcp-et7g.1"
REFINERY="gascity-packs/gastown.refinery"
POLECAT="gastown__polecat-gc-fv7ot"
RFC3339_UTC='^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$'

FAILURES=0

fail() {
    echo "FAIL: $*" >&2
    FAILURES=$((FAILURES + 1))
}

# extract_stamp pulls the handoff block verbatim out of submit-and-exit. Any
# `{{placeholder}}` left in it is a hard error: the harness cannot render it, and
# an unrendered one would make the test pass against text the formula never runs.
extract_stamp() {
    python3 - "$FORMULA" "$1" <<'PY'
import re
import sys
import tomllib

formula, out = sys.argv[1:3]
begin = "# --- handoff-stamp:begin ---"
end = "# --- handoff-stamp:end ---"
with open(formula, "rb") as handle:
    doc = tomllib.load(handle)
step = next(s for s in doc["steps"] if s["id"] == "submit-and-exit")
text = step["description"]
if text.count(begin) != 1 or text.count(end) != 1:
    sys.exit("submit-and-exit must carry exactly one handoff-stamp block")
block = text.split(begin, 1)[1].split(end, 1)[0]
leftover = sorted(set(re.findall(r"\{\{[^}]*\}\}", block)))
if leftover:
    sys.exit(f"handoff-stamp block has unrendered placeholders: {leftover}")
with open(out, "w") as handle:
    handle.write(block)
PY
}

# The stub answers `show` and `update` from a JSON fixture and logs every call.
# `update` really mutates the fixture, and an empty --set-metadata value deletes
# the key. GC_STUB_SHOW_FAIL makes `show` fail, as a transient store error does.
write_gc_stub() {
    local dir="$1"
    cat >"$dir/gc" <<'STUB'
#!/usr/bin/env bash
if [ "${1:-}" != "bd" ]; then
    echo "stub gc: unexpected invocation: $*" >&2
    exit 64
fi
printf '%s\n' "$*" >>"$GC_STUB_LOG"
verb="${2:-}"
shift 2
case "$verb" in
    show)
        [ -z "${GC_STUB_SHOW_FAIL:-}" ] || exit 1
        exec python3 "$GC_STUB_STORE" show "$GC_STUB_FIXTURE" "$@"
        ;;
    update) exec python3 "$GC_STUB_STORE" update "$GC_STUB_FIXTURE" "$@" ;;
    *) echo "stub gc: unmodelled beads subcommand: $verb" >&2; exit 64 ;;
esac
STUB
    chmod +x "$dir/gc"

    cat >"$dir/store.py" <<'PY'
import json
import sys

verb, fixture, *args = sys.argv[1:]
with open(fixture) as handle:
    beads = json.load(handle)

positional = [arg for arg in args if not arg.startswith("--")]
bead_id = positional[0] if positional else None
target = next((bead for bead in beads if bead["id"] == bead_id), None)

if verb == "show":
    print(json.dumps([target] if target else []))
    sys.exit(0)

if target is None:
    sys.exit(f"stub gc update: no such bead {bead_id!r}")
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
    if name in ("--status", "--assignee"):
        target[name.lstrip("-")] = value
    elif name == "--set-metadata":
        key, _, new_value = value.partition("=")
        metadata = target.setdefault("metadata", {})
        if new_value:
            metadata[key] = new_value
        else:
            metadata.pop(key, None)
    else:
        sys.exit(f"stub gc update: unmodelled flag {name!r}")
with open(fixture, "w") as handle:
    json.dump(beads, handle)
PY
}

# seed_bead [first_submitted_at] — the work bead as a polecat holds it just
# before the handoff.
seed_bead() {
    python3 - "$TMP/fixture.json" "$BEAD" "$POLECAT" "${1:-}" <<'PY'
import json
import sys

path, bead_id, polecat, first = sys.argv[1:5]
metadata = {"branch": f"polecat/{bead_id}", "target": "integration"}
if first:
    metadata["first_submitted_at"] = first
with open(path, "w") as handle:
    json.dump([{
        "id": bead_id,
        "status": "in_progress",
        "assignee": polecat,
        "metadata": metadata,
    }], handle)
PY
}

# run_stamp [show-fail] — runs the shipped block once, the way submit-and-exit
# does, with a fresh call log.
run_stamp() {
    : >"$TMP/calls.log"
    PATH="$TMP/bin:$PATH" \
    GC_STUB_FIXTURE="$TMP/fixture.json" \
    GC_STUB_STORE="$TMP/bin/store.py" \
    GC_STUB_LOG="$TMP/calls.log" \
    GC_STUB_SHOW_FAIL="${1:-}" \
    WORK_BEAD_ID="$BEAD" \
    REFINERY_TARGET="$REFINERY" \
        bash -c 'set -uo pipefail; . "$1"' _ "$TMP/stamp.sh" >"$TMP/run.log" 2>&1 || {
        fail "the handoff block exited non-zero: $(cat "$TMP/run.log")"
        return 1
    }
    if grep -q '^stub gc' "$TMP/run.log"; then
        fail "the handoff block made a call the stub does not model: $(cat "$TMP/run.log")"
        return 1
    fi
}

# field <key> — a top-level field, or metadata.<key>, of the fixture bead.
field() {
    python3 - "$TMP/fixture.json" "$1" <<'PY'
import json
import sys

path, key = sys.argv[1:3]
bead = json.load(open(path))[0]
if key.startswith("metadata."):
    print(bead.get("metadata", {}).get(key.split(".", 1)[1], ""))
else:
    print(bead.get(key, ""))
PY
}

# The update calls the block made. The log holds the stub's argv, so every line
# is an argv tail, never an invocation.
update_calls() {
    grep -E '^bd update ' "$TMP/calls.log" || true # gc-bd-argv-tail: stub call log, not an invocation
}

test_first_handoff_stamps_both_keys_in_the_handoff_write() {
    seed_bead
    run_stamp || return
    local first last
    first=$(field metadata.first_submitted_at)
    last=$(field metadata.last_submitted_at)
    [[ "$last" =~ $RFC3339_UTC ]] ||
        fail "last_submitted_at must be UTC RFC3339 in created_at's format (find-work compares them as strings), got '$last'"
    [[ -n "$first" && "$first" == "$last" ]] ||
        fail "a first handoff must set first_submitted_at to the same instant as last_submitted_at, got first='$first' last='$last'"

    # The handoff itself still happens, and in the SAME write as the stamp.
    [[ "$(field assignee)" == "$REFINERY" ]] || fail "the bead must be handed to the refinery"
    [[ "$(field status)" == "open" ]] || fail "the handoff must set status=open"
    [[ -z "$(field metadata.gc.routed_to)" ]] || fail "the handoff must clear gc.routed_to"
    local updates
    updates=$(update_calls)
    [[ $(printf '%s\n' "$updates" | grep -c .) -eq 1 ]] ||
        fail "the stamp must ride the handoff write, not a separate update; got: $updates"
    [[ "$updates" == *"--assignee=$REFINERY"*"last_submitted_at="*"first_submitted_at="* ]] ||
        fail "the one update must carry the assignee and both stamps; got: $updates"
}

test_resubmit_keeps_first_and_advances_last() {
    seed_bead
    run_stamp || return
    local first1 last1
    first1=$(field metadata.first_submitted_at)
    last1=$(field metadata.last_submitted_at)

    # The refinery rejects it back to the pool; a polecat fixes and resubmits.
    # The stamp has one-second resolution, so wait out the second.
    sleep 1
    run_stamp || return
    local first2 last2
    first2=$(field metadata.first_submitted_at)
    last2=$(field metadata.last_submitted_at)
    [[ "$first2" == "$first1" ]] ||
        fail "a resubmit must keep first_submitted_at byte-identical, '$first1' became '$first2'"
    [[ "$last2" > "$last1" ]] ||
        fail "a resubmit must advance last_submitted_at, '$last1' -> '$last2'"
    [[ "$(update_calls)" != *"first_submitted_at="* ]] ||
        fail "a resubmit must not rewrite first_submitted_at at all"
}

test_preseeded_first_submitted_at_is_kept() {
    local original="2026-09-01T06:00:00Z"
    seed_bead "$original"
    run_stamp || return
    [[ "$(field metadata.first_submitted_at)" == "$original" ]] ||
        fail "an existing first_submitted_at must survive the handoff, got '$(field metadata.first_submitted_at)'"
    [[ "$(field metadata.last_submitted_at)" > "$original" ]] ||
        fail "last_submitted_at must still be written, got '$(field metadata.last_submitted_at)'"
}

test_unreadable_bead_is_not_stamped_fresh() {
    # A failed read is not evidence the key is absent. Writing a fresh first
    # stamp there would overwrite the original and demote a resubmit to the back
    # of its band. The handoff itself must still go through.
    local original="2026-09-01T06:00:00Z"
    seed_bead "$original"
    run_stamp show-fail || return
    [[ "$(field metadata.first_submitted_at)" == "$original" ]] ||
        fail "an unreadable bead must not get a fresh first_submitted_at, got '$(field metadata.first_submitted_at)'"
    [[ "$(field assignee)" == "$REFINERY" ]] ||
        fail "a failed stamp read must not block the handoff"
    [[ "$(field metadata.last_submitted_at)" =~ $RFC3339_UTC ]] ||
        fail "last_submitted_at does not depend on the read and must still be written"
}

test_auto_push_halt_is_not_stamped() {
    # auto_push=false halts at branch-ready with no refinery handoff, so nothing
    # has joined the merge queue and nothing may be stamped. The stamp keys are
    # written only inside the handoff block.
    python3 - "$FORMULA" <<'PY' || fail "the stamp keys must be written only in the handoff-stamp block, never on the auto_push=false halt"
import sys
import tomllib

doc = tomllib.load(open(sys.argv[1], "rb"))
text = next(s for s in doc["steps"] if s["id"] == "submit-and-exit")["description"]
halt = text[text.index('if [ "$AUTO_PUSH" = "false" ]'):]
halt = halt[: halt.index("\nfi\n")]
if "submitted_at" in halt:
    raise SystemExit(1)
outside = text.split("# --- handoff-stamp:begin ---")[0] + text.split("# --- handoff-stamp:end ---")[1]
if "submitted_at=" in outside:
    raise SystemExit(1)
PY
}

TMP=$(mktemp -d "${TMPDIR:-/tmp}/gastown-handoff-stamp.XXXXXX") || exit 1
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin"
write_gc_stub "$TMP/bin"
extract_stamp "$TMP/stamp.sh" || exit 1
bash -n "$TMP/stamp.sh" || { echo "FAIL: extracted handoff-stamp block is not valid shell" >&2; exit 1; }

test_first_handoff_stamps_both_keys_in_the_handoff_write
test_resubmit_keeps_first_and_advances_last
test_preseeded_first_submitted_at_is_kept
test_unreadable_bead_is_not_stamped_fresh
test_auto_push_halt_is_not_stamped

if [ "$FAILURES" -ne 0 ]; then
    echo "$FAILURES test(s) failed" >&2
    exit 1
fi
echo "all handoff-stamp tests passed"
