#!/usr/bin/env bash
# Contract tests for the refinery patrol's find-work query (gcp-s14g).
#
# `mol-refinery-patrol` step find-work scanned with `--status=open`, so a bead
# that was `in_progress`, assigned to the refinery, and carrying
# `metadata.branch` was invisible to the queue forever. The resulting stall is
# self-concealing: every patrol legitimately concludes "no work", writes
# `IDLE: no work, exiting turn.`, and exits, so no wake signal fires and the
# queue looks healthy from outside. One such bead sat ~19h and gated a
# nine-bead wave.
#
# That state is not an edge case reachable only through crash recovery: it
# arises on the normal polecat submit path, where the polecat reassigns the
# bead to the refinery and the status does not always come back to `open`.
#
# These tests never assert the fix by grepping the flag alone — a flag string
# proves nothing about which beads come back. The shipped query text is
# extracted from the formula between its sentinels and EXECUTED against a stub
# that filters a fixture the way the real store does, so a regression to an
# open-only scan shows up here as "the in_progress bead was not found" rather
# than as a silent queue stall in production.
#
# The second half of the contract is gcp-mi9t: the scan was assignee-only, so a
# bead carrying `gc.routed_to=<rig>/gastown.refinery` with NO assignee was
# invisible. For a pool role that shape self-heals (the supervisor spawns a
# claimer); the refinery is a singleton patrol with no such path, so such beads
# sat until a human named their ids in a nudge (th-lm5n ~72min, th-albz
# ~31min). The step now converts routed -> assigned itself. The stub models the
# write and the read-back, so "found it" and "claimed it under the identity the
# primary scan can see" are separate, executed assertions.
set -uo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
FORMULA="$ROOT/gastown/formulas/mol-refinery-patrol.toml"
REFINERY_PROMPT="$ROOT/gastown/agents/refinery/prompt.template.md"
POLECAT_FORMULA="$ROOT/gastown/formulas/mol-polecat-work.toml"

FAILURES=0

fail() {
    echo "FAIL: $*" >&2
    FAILURES=$((FAILURES + 1))
}

# The block under test is the shipped formula text, extracted between its
# sentinels — not a transcription that could drift from what the refinery runs.
#
# Formula placeholders are substituted from the formula's own [vars] defaults,
# because the block now composes the refinery's identity from
# {{binding_prefix}} and an unsubstituted "{{...}}" would silently make every
# routed lookup miss. Callers may override one var (used to exercise both the
# bound "gastown." binding this rig ships and the unbound default). Any
# placeholder left over after substitution is a hard error: a future edit that
# reaches for a var this harness cannot supply fails here rather than passing
# vacuously.
#
# Usage: extract_find_work_query <outfile> [var] [value]
extract_find_work_query() {
    python3 - "$FORMULA" "$1" "${2:-}" "${3:-}" <<'PY'
import re
import sys
import tomllib

formula, out, override_var, override_value = sys.argv[1:5]
begin = "# --- find-work-query:begin ---"
end = "# --- find-work-query:end ---"

with open(formula, "rb") as handle:
    doc = tomllib.load(handle)

blocks = [
    text.split(begin, 1)[1].split(end, 1)[0]
    for text in (step.get("description", "") for step in doc["steps"])
    if begin in text and end in text
]
if len(blocks) != 1:
    sys.exit(f"expected exactly one find-work-query block, found {len(blocks)}")

block = blocks[0]
values = {name: spec.get("default", "") for name, spec in (doc.get("vars") or {}).items()}
if override_var:
    if override_var not in values:
        sys.exit(f"{override_var!r} is not a declared var of this formula")
    values[override_var] = override_value
for name, value in values.items():
    block = block.replace("{{%s}}" % name, value)

leftover = sorted(set(re.findall(r"\{\{[^}]*\}\}", block)))
if leftover:
    sys.exit(f"find-work-query block has unsubstituted placeholders: {leftover}")

with open(out, "w") as handle:
    handle.write(block)
PY
}

# Stub `gc` implementing just enough of the beads CLI to answer the shipped
# query: a list filter, the claiming write, and the read-back. It models
# assignee equality, --no-assignee, a comma-separated status filter,
# --has-metadata-key, --metadata-field, --exclude-type and --limit. Anything
# else is an error, so a query that grows a flag this stub does not model fails
# loudly instead of passing vacuously.
#
# The write really mutates the fixture, so the read-back the shipped block
# performs is a genuine read of what the write left behind — not a stub that
# agrees with itself. GC_STUB_CLAIM_HIJACK simulates another writer winning the
# race: the write lands under that identity instead, and the block must decline
# the bead.
write_gc_stub() {
    local dir="$1"
    cat >"$dir/gc" <<'STUB'
#!/usr/bin/env bash
if [ "${1:-}" != "bd" ]; then
    echo "stub gc: unexpected invocation: $*" >&2
    exit 64
fi
verb="${2:-}"
shift 2
printf '%s %s\n' "$verb" "$*" >>"$GC_STUB_LOG"
case "$verb" in
    list|update|show) exec python3 "$GC_STUB_FILTER" "$verb" "$GC_STUB_FIXTURE" "$@" ;;
    *) echo "stub gc: unmodelled beads subcommand: $verb" >&2; exit 64 ;;
esac
STUB
    chmod +x "$dir/gc"

    cat >"$dir/filter.py" <<'PY'
import json
import os
import sys

verb, fixture, *args = sys.argv[1:]
with open(fixture) as handle:
    beads = json.load(handle)


def flags(argv):
    """Yield (name, value) for both --flag=value and `--flag value` forms."""
    index = 0
    while index < len(argv):
        arg = argv[index]
        if not arg.startswith("--"):
            yield None, arg
            index += 1
            continue
        if "=" in arg:
            name, value = arg.split("=", 1)
            yield name, value
            index += 1
            continue
        # A valueless flag is followed by its value unless the next token is
        # itself a flag. --json and --no-assignee take no value.
        if arg in ("--json", "--no-assignee"):
            yield arg, None
            index += 1
            continue
        if index + 1 >= len(argv):
            sys.exit(f"stub gc: flag {arg!r} is missing its value")
        yield arg, argv[index + 1]
        index += 2


def emit(matched):
    print(json.dumps(matched))


if verb == "list":
    assignee = None
    no_assignee = False
    statuses = None
    metadata_key = None
    metadata_fields = {}
    excluded_types = set()
    limit = None
    for name, value in flags(args):
        if name in ("--json", None):
            continue
        if name == "--rig":
            continue
        elif name == "--assignee":
            assignee = value
        elif name == "--no-assignee":
            no_assignee = True
        elif name == "--status":
            statuses = set(value.split(","))
        elif name == "--has-metadata-key":
            metadata_key = value
        elif name == "--metadata-field":
            key, _, expected = value.partition("=")
            metadata_fields[key] = expected
        elif name == "--exclude-type":
            excluded_types.update(value.split(","))
        elif name == "--limit":
            limit = int(value)
        else:
            sys.exit(f"stub gc list: unmodelled flag {name!r}")

    # The real list hides closed issues unless asked. The stub mirrors that so a
    # query cannot appear to work by sweeping closed beads back into the queue.
    matched = [
        bead
        for bead in beads
        if bead.get("status") != "closed"
        and (assignee is None or bead.get("assignee") == assignee)
        and (not no_assignee or not bead.get("assignee"))
        and (statuses is None or bead.get("status") in statuses)
        and (metadata_key is None or (bead.get("metadata") or {}).get(metadata_key))
        and all(
            (bead.get("metadata") or {}).get(key) == expected
            for key, expected in metadata_fields.items()
        )
        and bead.get("issue_type") not in excluded_types
    ]
    if limit:
        matched = matched[:limit]
    emit(matched)

elif verb == "show":
    bead_id = None
    for name, value in flags(args):
        if name is None:
            bead_id = value
        elif name == "--json":
            continue
        else:
            sys.exit(f"stub gc show: unmodelled flag {name!r}")
    emit([bead for bead in beads if bead.get("id") == bead_id])

elif verb == "update":
    bead_id = None
    updates = {}
    metadata_updates = {}
    for name, value in flags(args):
        if name is None:
            bead_id = value
        elif name in ("--assignee", "--status"):
            updates[name.lstrip("-")] = value
        elif name == "--set-metadata":
            key, _, new_value = value.partition("=")
            metadata_updates[key] = new_value
        else:
            sys.exit(f"stub gc update: unmodelled flag {name!r}")

    hijack = os.environ.get("GC_STUB_CLAIM_HIJACK", "")
    if hijack and "assignee" in updates:
        updates["assignee"] = hijack

    target = next((bead for bead in beads if bead.get("id") == bead_id), None)
    if target is None:
        sys.exit(f"stub gc update: no such bead {bead_id!r}")
    target.update(updates)
    metadata = target.setdefault("metadata", {})
    for key, new_value in metadata_updates.items():
        if new_value:
            metadata[key] = new_value
        else:
            metadata.pop(key, None)
    with open(fixture, "w") as handle:
        json.dump(beads, handle)

else:
    sys.exit(f"stub gc: unmodelled subcommand {verb!r}")
PY
}

bead() {
    # bead <id> <status> <assignee> [branch] [type] [routed_to]
    python3 - "$@" <<'PY'
import json
import sys

bead_id, status, assignee = sys.argv[1:4]
branch = sys.argv[4] if len(sys.argv) > 4 else ""
issue_type = sys.argv[5] if len(sys.argv) > 5 else "task"
routed_to = sys.argv[6] if len(sys.argv) > 6 else ""
metadata = {}
if branch:
    metadata["branch"] = branch
if routed_to:
    metadata["gc.routed_to"] = routed_to
print(json.dumps({
    "id": bead_id,
    "status": status,
    "assignee": assignee,
    "issue_type": issue_type,
    "metadata": metadata,
}))
PY
}

# Run the shipped query against a fixture and echo the WORK it resolves.
#
# The block's own diagnostics go to $TMP/run.log rather than into the captured
# value, so a step that declines a bead and says why cannot be mistaken for a
# step that resolved one. $TMP/fixture.json is left holding whatever the block
# wrote to it, which is how the claim is asserted.
#
# Usage: run_find_work <fixture-json> <agent> [rig] [block] [claim-hijack]
run_find_work() {
    local fixture_json="$1"
    local agent="$2"
    local rig="${3:-}"
    local script="${4:-$TMP/find-work.sh}"
    local hijack="${5:-}"
    local out

    printf '%s' "$fixture_json" >"$TMP/fixture.json"
    : >"$TMP/stub.log"
    : >"$TMP/run.log"
    out=$(
        PATH="$TMP/bin:$PATH" \
        GC_STUB_FIXTURE="$TMP/fixture.json" \
        GC_STUB_FILTER="$TMP/bin/filter.py" \
        GC_STUB_LOG="$TMP/stub.log" \
        GC_STUB_CLAIM_HIJACK="$hijack" \
        GC_AGENT="$agent" \
        GC_RIG="$rig" \
            bash -c 'set -uo pipefail; . "$1" >"$2" 2>&1; printf "%s" "$WORK"' \
                _ "$script" "$TMP/run.log"
    ) || {
        echo "__ERROR__ $(cat "$TMP/run.log")"
        return
    }
    if grep -q "^stub gc" "$TMP/run.log"; then
        echo "__ERROR__ $(cat "$TMP/run.log")"
        return
    fi
    printf '%s' "$out"
}

# The assignee the fixture bead ended up with after the block ran.
claimed_assignee() {
    python3 -c 'import json,sys; print(next((b["assignee"] for b in json.load(open(sys.argv[1])) if b["id"] == sys.argv[2]), "__missing__"))' \
        "$TMP/fixture.json" "$1"
}

# The value of one metadata key on the fixture bead after the block ran.
claimed_metadata() {
    python3 -c 'import json,sys; print(next((b.get("metadata", {}).get(sys.argv[3], "") for b in json.load(open(sys.argv[1])) if b["id"] == sys.argv[2]), "__missing__"))' \
        "$TMP/fixture.json" "$1" "$2"
}

fixture() {
    python3 -c 'import json,sys; print(json.dumps([json.loads(a) for a in sys.argv[1:]]))' "$@"
}

test_in_progress_bead_with_branch_is_found() {
    # The regression. Before gcp-s14g this returned empty and the patrol wrote
    # IDLE while a real merge candidate sat on its hook.
    local got
    got=$(run_find_work \
        "$(fixture "$(bead winnow-l0cj.6 in_progress winnow/gastown.refinery polecat/winnow-l0cj.6)")" \
        winnow/gastown.refinery winnow)
    [[ "$got" == "winnow-l0cj.6" ]] ||
        fail "an in_progress bead assigned to the refinery with metadata.branch must be found, got '$got'"
}

test_open_bead_with_branch_is_still_found() {
    local got
    got=$(run_find_work \
        "$(fixture "$(bead winnow-451o open winnow/gastown.refinery polecat/winnow-451o)")" \
        winnow/gastown.refinery winnow)
    [[ "$got" == "winnow-451o" ]] ||
        fail "the open path must keep working, got '$got'"
}

test_mixed_queue_returns_a_single_candidate() {
    local got
    got=$(run_find_work \
        "$(fixture \
            "$(bead winnow-451o open winnow/gastown.refinery polecat/winnow-451o)" \
            "$(bead winnow-l0cj.6 in_progress winnow/gastown.refinery polecat/winnow-l0cj.6)")" \
        winnow/gastown.refinery winnow)
    [[ "$got" == "winnow-451o" || "$got" == "winnow-l0cj.6" ]] ||
        fail "a mixed queue must yield exactly one candidate, got '$got'"
}

test_bead_without_branch_is_not_merge_work() {
    # --has-metadata-key=branch is what separates merge candidates from
    # ordinary assigned beads. Widening the status filter must not widen this.
    local got
    got=$(run_find_work \
        "$(fixture "$(bead winnow-nobranch in_progress winnow/gastown.refinery)")" \
        winnow/gastown.refinery winnow)
    [[ -z "$got" ]] ||
        fail "a bead with no metadata.branch is not merge work, got '$got'"
}

test_other_agents_in_progress_work_is_not_stolen() {
    # in_progress beads belonging to a polecat mid-implementation must stay
    # invisible: the assignee filter, not the status filter, is what keeps the
    # refinery out of live work.
    local got
    got=$(run_find_work \
        "$(fixture "$(bead winnow-mine in_progress winnow/gastown.furiosa polecat/winnow-mine)")" \
        winnow/gastown.refinery winnow)
    [[ -z "$got" ]] ||
        fail "work assigned to another agent must not be claimed, got '$got'"
}

test_epics_are_excluded() {
    local got
    got=$(run_find_work \
        "$(fixture "$(bead winnow-epic in_progress winnow/gastown.refinery polecat/winnow-epic epic)")" \
        winnow/gastown.refinery winnow)
    [[ -z "$got" ]] ||
        fail "epics must stay excluded from the merge queue, got '$got'"
}

test_empty_queue_yields_no_work() {
    local got
    got=$(run_find_work "$(fixture)" winnow/gastown.refinery winnow)
    [[ -z "$got" ]] ||
        fail "an empty queue must yield no work, got '$got'"
}

test_query_is_rig_scoped_when_gc_rig_is_set() {
    run_find_work \
        "$(fixture "$(bead winnow-451o open winnow/gastown.refinery polecat/winnow-451o)")" \
        winnow/gastown.refinery winnow >/dev/null
    grep -F -- '--rig=winnow' "$TMP/stub.log" >/dev/null ||
        fail "the query must scope to the rig database when GC_RIG is set"

    run_find_work \
        "$(fixture "$(bead hq-451o open gastown.refinery polecat/hq-451o)")" \
        gastown.refinery "" >/dev/null
    ! grep -F -- '--rig' "$TMP/stub.log" >/dev/null ||
        fail "the query must omit --rig for HQ-only refineries"
}

test_open_only_scans_are_not_reintroduced() {
    # The same hole existed in the startup orphan scan, which is the fallback
    # for exactly the beads the patrol query missed. Both must sweep both
    # statuses, or the fallback cannot catch what the primary drops.
    grep -F -- '--status=open,in_progress' "$REFINERY_PROMPT" >/dev/null ||
        fail "the refinery startup orphan scan must sweep open,in_progress"
    ! grep -E -- '--assignee=[^ ]*GC_AGENT[^ ]*" --status=open( |$)' "$REFINERY_PROMPT" >/dev/null ||
        fail "the refinery prompt must not document an open-only assigned-work query"
    ! grep -E -- '--status=open --json' "$REFINERY_PROMPT" >/dev/null ||
        fail "the refinery orphan scan must not regress to an open-only filter"
}

# ── gcp-mi9t: routed-but-unassigned work ─────────────────────────────────────
# REFINERY is the identity this rig's refinery actually runs under: the gastown
# pack is imported with binding_prefix "gastown.", so gc.routed_to values name
# "<rig>/gastown.refinery". BOUND_ONLY re-extracts the shipped block under that
# binding; the declared default ("" — the pack unbound) is exercised separately
# by test_routed_scan_composes_its_identity_from_the_binding.
REFINERY="winnow/gastown.refinery"

test_routed_but_unassigned_bead_is_found_and_claimed() {
    # The gcp-mi9t regression. Nothing in the town converts routed -> assigned
    # for a singleton patrol, so before this the bead was invisible forever.
    local got
    got=$(run_find_work \
        "$(fixture "$(bead winnow-th5n open "" polecat/winnow-th5n task "$REFINERY")")" \
        "$REFINERY" winnow "$BOUND_ONLY")
    [[ "$got" == "winnow-th5n" ]] ||
        fail "a routed, unassigned bead with metadata.branch must be found, got '$got'"

    # Found is not enough: it must be converted to assigned work, or the next
    # patrol pass re-discovers it and the crash path re-hides it.
    local assignee
    assignee=$(claimed_assignee winnow-th5n)
    [[ "$assignee" == "$REFINERY" ]] ||
        fail "the claim must write the role identity the primary scan matches, got '$assignee'"

    # The routing hint has done its job; leaving it makes the bead look like
    # unclaimed demand to anything else reading routed_to.
    local routed
    routed=$(claimed_metadata winnow-th5n gc.routed_to)
    [[ -z "$routed" ]] ||
        fail "the claim must clear gc.routed_to, got '$routed'"
}

test_routed_scan_does_not_claim_with_the_session_identity() {
    # `--claim` would write $BEADS_ACTOR (a session name like
    # gastown__refinery-gc-xxxx), which --assignee=$GC_AGENT cannot match, so a
    # crash mid-merge would re-hide the bead behind a dead session's name.
    run_find_work \
        "$(fixture "$(bead winnow-th5n open "" polecat/winnow-th5n task "$REFINERY")")" \
        "$REFINERY" winnow "$BOUND_ONLY" >/dev/null
    ! grep -E '^update .*--claim( |$)' "$TMP/stub.log" >/dev/null ||
        fail "the claim must name \$GC_AGENT explicitly, not inherit the session actor"
    # Anchored to an `update` line: the list queries carry --assignee too, so an
    # unanchored grep would pass without a claim ever being written.
    grep -E "^update .*--assignee=$REFINERY( |$)" "$TMP/stub.log" >/dev/null ||
        fail "the claim must write the canonical role identity"
}

test_a_lost_claim_race_yields_no_work() {
    # Another writer got there first. The block reads back what the write
    # actually left and must decline the bead rather than merging a branch it
    # does not own.
    local got
    got=$(run_find_work \
        "$(fixture "$(bead winnow-th5n open "" polecat/winnow-th5n task "$REFINERY")")" \
        "$REFINERY" winnow "$BOUND_ONLY" winnow/gastown.furiosa)
    [[ -z "$got" ]] ||
        fail "a claim that read back under another identity must not become work, got '$got'"
}

test_routed_bead_assigned_to_someone_else_is_not_stolen() {
    # A routing hint is not ownership: an operator parking a bead on a seat, or
    # a polecat still holding it, both look like this.
    local got
    got=$(run_find_work \
        "$(fixture "$(bead winnow-th5n open winnow/gastown.furiosa polecat/winnow-th5n task "$REFINERY")")" \
        "$REFINERY" winnow "$BOUND_ONLY")
    [[ -z "$got" ]] ||
        fail "a routed bead held by another agent must not be claimed, got '$got'"
}

test_routed_bead_for_another_agent_is_ignored() {
    local got
    got=$(run_find_work \
        "$(fixture "$(bead winnow-pool open "" polecat/winnow-pool task winnow/gastown.polecat)")" \
        "$REFINERY" winnow "$BOUND_ONLY")
    [[ -z "$got" ]] ||
        fail "work routed to the polecat pool is not the refinery's, got '$got'"
}

test_routed_bead_without_branch_is_not_merge_work() {
    local got
    got=$(run_find_work \
        "$(fixture "$(bead winnow-nobranch open "" "" task "$REFINERY")")" \
        "$REFINERY" winnow "$BOUND_ONLY")
    [[ -z "$got" ]] ||
        fail "the routed scan must keep the branch requirement, got '$got'"
}

test_assigned_work_wins_and_the_routed_scan_is_not_consulted() {
    # Assigned work is already yours; a second query would only widen the
    # window in which the refinery can pick up something it should not.
    local got
    got=$(run_find_work \
        "$(fixture \
            "$(bead winnow-451o open "$REFINERY" polecat/winnow-451o)" \
            "$(bead winnow-th5n open "" polecat/winnow-th5n task "$REFINERY")")" \
        "$REFINERY" winnow "$BOUND_ONLY")
    [[ "$got" == "winnow-451o" ]] ||
        fail "assigned work must win over routed work, got '$got'"
    ! grep -F -- "--metadata-field" "$TMP/stub.log" >/dev/null ||
        fail "the routed scan must not run when the assignee scan already found work"
    local assignee
    assignee=$(claimed_assignee winnow-th5n)
    [[ -z "$assignee" ]] ||
        fail "the routed bead must be left untouched this pass, got '$assignee'"
}

test_routed_scan_composes_its_identity_from_the_binding() {
    # The identity is built from {{binding_prefix}}, not hardcoded. Under the
    # declared default (the pack unbound) the same block must look for
    # "<rig>/refinery" — and must NOT match the bound spelling.
    local got
    got=$(run_find_work \
        "$(fixture "$(bead winnow-unbound open "" polecat/winnow-unbound task winnow/refinery)")" \
        winnow/refinery winnow "$TMP/find-work-unbound.sh")
    [[ "$got" == "winnow-unbound" ]] ||
        fail "the unbound binding must look for <rig>/refinery, got '$got'"

    got=$(run_find_work \
        "$(fixture "$(bead winnow-th5n open "" polecat/winnow-th5n task "$REFINERY")")" \
        winnow/refinery winnow "$TMP/find-work-unbound.sh")
    [[ -z "$got" ]] ||
        fail "the unbound binding must not match a bound routed_to value, got '$got'"
}

test_routed_scan_is_rig_scoped_when_gc_rig_is_set() {
    run_find_work \
        "$(fixture "$(bead winnow-th5n open "" polecat/winnow-th5n task "$REFINERY")")" \
        "$REFINERY" winnow "$BOUND_ONLY" >/dev/null
    [[ $(grep -c -- '--rig=winnow' "$TMP/stub.log") -ge 2 ]] ||
        fail "both find-work queries must scope to the rig database"
}

test_prompt_points_at_the_step_instead_of_restating_it() {
    # A role prompt is injected as authoritative context; a formula step has to
    # be opened deliberately. A quick-reference cell restating only the assignee
    # half of find-work is the lossy copy an agent actually runs — the same
    # drift class that once dropped gc.routed_to from the rejection flow.
    grep -F 'gc.routed_to=<self>' "$REFINERY_PROMPT" >/dev/null ||
        fail "the refinery prompt must name the routed half of find-work"
    ! grep -E '^\| Find [^|]*\| `gc bd list' "$REFINERY_PROMPT" >/dev/null ||
        fail "the prompt must point at the find-work step, not restate its query in a cell"
}

test_polecat_handoff_verifies_the_status_it_writes() {
    # The other half of gcp-s14g: the submit handoff writes --status=open and
    # that write was observed not to stick. It reads back and corrects once,
    # and it must never abort the handoff over bookkeeping — the branch is
    # already pushed by then.
    grep -F 'HANDOFF_STATUS=' "$POLECAT_FORMULA" >/dev/null ||
        fail "the polecat submit handoff should read back the status it wrote"
    grep -F 'find-work scans open,in_progress' "$POLECAT_FORMULA" >/dev/null ||
        fail "the handoff warning should name the refinery behaviour that makes it non-fatal"
    ! grep -A12 'HANDOFF_STATUS=' "$POLECAT_FORMULA" | grep -E 'exit [1-9]' >/dev/null ||
        fail "a status that will not settle must not abort a handoff whose branch is already pushed"
}

TMP=$(mktemp -d "${TMPDIR:-/tmp}/gastown-find-work.XXXXXX") || exit 1
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin"
write_gc_stub "$TMP/bin"
# The shipped block under this rig's real binding, and under the formula's
# declared default, so the identity it composes is tested both ways.
BOUND_ONLY="$TMP/find-work.sh"
extract_find_work_query "$TMP/find-work.sh" binding_prefix "gastown." || exit 1
extract_find_work_query "$TMP/find-work-unbound.sh" || exit 1

test_in_progress_bead_with_branch_is_found
test_open_bead_with_branch_is_still_found
test_mixed_queue_returns_a_single_candidate
test_bead_without_branch_is_not_merge_work
test_other_agents_in_progress_work_is_not_stolen
test_epics_are_excluded
test_empty_queue_yields_no_work
test_query_is_rig_scoped_when_gc_rig_is_set
test_routed_but_unassigned_bead_is_found_and_claimed
test_routed_scan_does_not_claim_with_the_session_identity
test_a_lost_claim_race_yields_no_work
test_routed_bead_assigned_to_someone_else_is_not_stolen
test_routed_bead_for_another_agent_is_ignored
test_routed_bead_without_branch_is_not_merge_work
test_assigned_work_wins_and_the_routed_scan_is_not_consulted
test_routed_scan_composes_its_identity_from_the_binding
test_routed_scan_is_rig_scoped_when_gc_rig_is_set
test_open_only_scans_are_not_reintroduced
test_prompt_points_at_the_step_instead_of_restating_it
test_polecat_handoff_verifies_the_status_it_writes

if [ "$FAILURES" -ne 0 ]; then
    echo "$FAILURES test(s) failed" >&2
    exit 1
fi
echo "all find-work tests passed"
