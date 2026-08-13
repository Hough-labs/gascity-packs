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
# `gc bd list` that filters a fixture the way the real one does, so a
# regression to an open-only scan shows up here as "the in_progress bead was
# not found" rather than as a silent queue stall in production.
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
extract_find_work_query() {
    python3 - "$FORMULA" "$1" <<'PY'
import sys
import tomllib

formula, out = sys.argv[1], sys.argv[2]
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

with open(out, "w") as handle:
    handle.write(blocks[0])
PY
}

# Stub `gc` implementing just enough of `bd list` to answer the shipped query:
# assignee equality, a comma-separated status filter, --has-metadata-key,
# --exclude-type, and --limit. Anything else is an error, so a query that grows
# a flag this stub does not model fails loudly instead of passing vacuously.
write_gc_stub() {
    local dir="$1"
    cat >"$dir/gc" <<'STUB'
#!/usr/bin/env bash
if [ "${1:-}" != "bd" ] || [ "${2:-}" != "list" ]; then
    echo "stub gc: unexpected invocation: $*" >&2
    exit 64
fi
shift 2
printf '%s\n' "$*" >>"$GC_STUB_LOG"
exec python3 "$GC_STUB_FILTER" "$GC_STUB_FIXTURE" "$@"
STUB
    chmod +x "$dir/gc"

    cat >"$dir/filter.py" <<'PY'
import json
import sys

fixture, *args = sys.argv[1:]
with open(fixture) as handle:
    beads = json.load(handle)

assignee = None
statuses = None
metadata_key = None
excluded_types = set()
limit = None

for arg in args:
    if arg == "--json":
        continue
    if arg.startswith("--rig="):
        continue
    if arg.startswith("--assignee="):
        assignee = arg.split("=", 1)[1]
    elif arg.startswith("--status="):
        statuses = set(arg.split("=", 1)[1].split(","))
    elif arg.startswith("--has-metadata-key="):
        metadata_key = arg.split("=", 1)[1]
    elif arg.startswith("--exclude-type="):
        excluded_types.update(arg.split("=", 1)[1].split(","))
    elif arg.startswith("--limit="):
        limit = int(arg.split("=", 1)[1])
    else:
        sys.exit(f"stub gc bd list: unmodelled flag {arg!r}")

# `bd list` hides closed issues unless asked; the stub mirrors that so a query
# cannot appear to work by sweeping closed beads back into the queue.
matched = [
    bead
    for bead in beads
    if bead.get("status") != "closed"
    and (assignee is None or bead.get("assignee") == assignee)
    and (statuses is None or bead.get("status") in statuses)
    and (metadata_key is None or (bead.get("metadata") or {}).get(metadata_key))
    and bead.get("issue_type") not in excluded_types
]
if limit:
    matched = matched[:limit]
print(json.dumps(matched))
PY
}

bead() {
    # bead <id> <status> <assignee> [branch] [type]
    python3 - "$@" <<'PY'
import json
import sys

bead_id, status, assignee = sys.argv[1:4]
branch = sys.argv[4] if len(sys.argv) > 4 else ""
issue_type = sys.argv[5] if len(sys.argv) > 5 else "task"
print(json.dumps({
    "id": bead_id,
    "status": status,
    "assignee": assignee,
    "issue_type": issue_type,
    "metadata": {"branch": branch} if branch else {},
}))
PY
}

# Run the shipped query against a fixture and echo the WORK it resolves.
run_find_work() {
    local fixture_json="$1"
    local agent="$2"
    local rig="${3:-}"
    local out

    printf '%s' "$fixture_json" >"$TMP/fixture.json"
    : >"$TMP/stub.log"
    out=$(
        PATH="$TMP/bin:$PATH" \
        GC_STUB_FIXTURE="$TMP/fixture.json" \
        GC_STUB_FILTER="$TMP/bin/filter.py" \
        GC_STUB_LOG="$TMP/stub.log" \
        GC_AGENT="$agent" \
        GC_RIG="$rig" \
            bash -c 'set -uo pipefail; . "$1"; printf "%s" "$WORK"' _ "$TMP/find-work.sh" 2>&1
    ) || {
        echo "__ERROR__ $out"
        return
    }
    printf '%s' "$out"
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
extract_find_work_query "$TMP/find-work.sh" || exit 1

test_in_progress_bead_with_branch_is_found
test_open_bead_with_branch_is_still_found
test_mixed_queue_returns_a_single_candidate
test_bead_without_branch_is_not_merge_work
test_other_agents_in_progress_work_is_not_stolen
test_epics_are_excluded
test_empty_queue_yields_no_work
test_query_is_rig_scoped_when_gc_rig_is_set
test_open_only_scans_are_not_reintroduced
test_polecat_handoff_verifies_the_status_it_writes

if [ "$FAILURES" -ne 0 ]; then
    echo "$FAILURES test(s) failed" >&2
    exit 1
fi
echo "all find-work tests passed"
