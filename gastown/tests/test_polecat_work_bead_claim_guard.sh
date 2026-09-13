#!/usr/bin/env bash
# Executable reproduction of the duplicate dispatch in gcp-cvbs / gaunt-m58w.
#
# `mol-polecat-work`'s workspace-setup step claims the WORK bead so it stops
# sitting in `gc bd ready` looking untouched while a polecat is building on it.
# The guard in front of that claim was written to protect a refinery-owned or
# operator-escalated bead — but its condition was "any non-empty assignee", and
# planned work normally arrives already assigned to the crew seat that filed it.
# So on 2026-09-04 gauntlet's gaunt-m58w (assignee gauntlet/crew.valkyrie) kept
# status=open for the whole run and a SECOND mol-polecat-work molecule was
# poured on it; the same shape recurred live on gcp-jxtc on 2026-09-13, where
# the duplicate carried its own submit-and-exit and came within one step of
# pushing a second branch over two finished commits.
#
# These tests run the claim guard out of the formula against a stubbed `gc` and
# assert the narrowed rule mechanically: a crew-assigned bead IS claimed, and
# the claim is skipped only for the two owners this session must not displace —
# the refinery target, and a `gc.routed_to=human` operator escalation.
# Nearly every assertion greps for a literal shell snippet out of the formula,
# so single-quoted `$VAR` is the point, not an error.
# shellcheck disable=SC2016
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
FORMULA="$ROOT/gastown/formulas/mol-polecat-work.toml"

ME="gastown__polecat-gc-oiac"
RIG="gascity-packs"
REFINERY="$RIG/gastown.refinery"
CREW="$RIG/crew.valkyrie"
BEAD="gcp-cvbs"

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

# extract_guard pulls the guard verbatim out of the step description that ships,
# so a drifted or deleted guard fails here rather than passing against a stale
# copy. `{{binding_prefix}}` is the one render the formula engine would do; it
# is substituted so the refinery identity under test is the real one.
extract_guard() {
    local out="$1"
    python3 - "$FORMULA" <<'PY' >"$out"
import sys
import tomllib

data = tomllib.load(open(sys.argv[1], "rb"))
step = next(s for s in data["steps"] if s["id"] == "workspace-setup")
text = step["description"]
begin = "# CLAIM_GUARD_BEGIN work-bead"
end = "# CLAIM_GUARD_END work-bead"
if begin not in text or end not in text:
    raise SystemExit("workspace-setup has no extractable work-bead claim guard")
body = text[text.index(begin): text.index(end) + len(end)]
sys.stdout.write(body.replace("{{binding_prefix}}", "gastown."))
PY
    [[ -s "$out" ]] || fail "could not extract the work-bead claim guard from $FORMULA"
    grep -F 'gc bd update "$WORK_BEAD_ID" --status=in_progress' "$out" >/dev/null ||
        fail "extracted guard does not contain the claim"
    bash -n "$out" || fail "extracted guard is not valid shell"
}

# write_gc_stub answers only the reads the guard makes and records every call,
# so a test asserts on what the guard DID, not just on what it printed. The
# claim is stateful: once an update lands, subsequent reads report the claimed
# bead, which is what lets the guard's own readback loop settle.
write_gc_stub() {
    local bin="$1"
    mkdir -p "$bin"
    cat >"$bin/gc" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$GC_CALLS"
case "$1 $2" in
    "bd show") # gc-bd-argv-tail: case label matching the fake gc's argv tail
        if [ -f "$GC_CLAIMED_FLAG" ]; then cat "$GC_CLAIMED_JSON"; else cat "$GC_WORK_JSON"; fi
        ;;
    "bd update") # gc-bd-argv-tail: case label matching the fake gc's argv tail
        case "$*" in *--status=in_progress*) : >"$GC_CLAIMED_FLAG" ;; esac
        ;;
    *) ;;
esac
SH
    chmod +x "$bin/gc"
}

new_case() {
    local dir
    dir=$(mktemp -d)
    mkdir -p "$dir/bin"
    write_gc_stub "$dir/bin"
    extract_guard "$dir/guard.sh"
    : >"$dir/calls.log"
    printf '%s' "$dir"
}

# run_guard binds the one input workspace-setup has already derived
# ($WORK_BEAD_ID) and runs the guard as the formula would.
run_guard() {
    local dir="$1" assignee="$2" routed_to="$3" rig="${4-$RIG}"

    cat >"$dir/work.json" <<JSON
[{"id":"$BEAD","status":"open","assignee":"$assignee","metadata":{"gc.routed_to":"$routed_to"}}]
JSON
    cat >"$dir/claimed.json" <<JSON
[{"id":"$BEAD","status":"in_progress","assignee":"$ME","metadata":{"gc.routed_to":"$routed_to","polecat_session":"$ME"}}]
JSON
    cat >"$dir/harness.sh" <<HARNESS
WORK_BEAD_ID="$BEAD"
GC_RIG="$rig"
BEADS_ACTOR="$ME"
HARNESS
    cat "$dir/guard.sh" >>"$dir/harness.sh"

    GC_CALLS="$dir/calls.log" \
        GC_WORK_JSON="$dir/work.json" \
        GC_CLAIMED_JSON="$dir/claimed.json" \
        GC_CLAIMED_FLAG="$dir/claimed.flag" \
        PATH="$dir/bin:$PATH" bash "$dir/harness.sh"
}

assert_claimed() {
    local dir="$1" why="$2"
    grep -F "bd update $BEAD --status=in_progress --assignee=$ME --set-metadata polecat_session=$ME" \
        "$dir/calls.log" >/dev/null || fail "$why"
}

assert_not_claimed() {
    local dir="$1" why="$2"
    ! grep -F "bd update $BEAD" "$dir/calls.log" >/dev/null || fail "$why"
}

# The defect itself. gaunt-m58w was assigned to gauntlet/crew.valkyrie — the
# seat that authored it, neither the refinery nor an escalation — and the guard
# fired anyway, leaving the bead open for a second sling to land on.
test_crew_assigned_work_bead_is_claimed() {
    local dir out
    dir=$(new_case)
    out=$(run_guard "$dir" "$CREW" "")

    assert_claimed "$dir" "a crew-assigned work bead was not claimed; it stays open in gc bd ready for a duplicate sling"
    grep -F "was assigned to $CREW" <<<"$out" >/dev/null ||
        fail "claiming over a foreign assignee left no trace in the transcript: $out"
    ! grep -F 'not yours to re-claim' <<<"$out" >/dev/null ||
        fail "the refinery/escalation skip path fired on a crew seat: $out"
}

# The narrow intent the guard's prose always claimed: a bead the refinery is
# landing is not this session's to take back.
test_refinery_held_work_bead_is_left_alone() {
    local dir out
    dir=$(new_case)
    out=$(run_guard "$dir" "$REFINERY" "")

    assert_not_claimed "$dir" "the claim stole a work bead the refinery owns"
    grep -F "is held by $REFINERY" <<<"$out" >/dev/null ||
        fail "skip path did not name the refinery holder: $out"
    grep -F 'not yours to re-claim' <<<"$out" >/dev/null ||
        fail "skip path did not explain itself: $out"
}

# gc.routed_to=human is the operator escalation the refinery writes when it
# REFUSES to land a bead. submit-and-exit halts the handoff on that same marker
# (gcp-rz8a); the claim must not quietly pull the bead back out of it, even
# though the assignee left behind is an ordinary seat rather than the refinery.
test_operator_escalation_is_left_alone() {
    local dir out
    dir=$(new_case)
    out=$(run_guard "$dir" "$CREW" "human")

    assert_not_claimed "$dir" "the claim pulled a gc.routed_to=human bead back out of its escalation"
    grep -F 'gc.routed_to=human' <<<"$out" >/dev/null ||
        fail "skip path did not name the escalation marker: $out"
}

test_unassigned_work_bead_is_claimed() {
    local dir out
    dir=$(new_case)
    out=$(run_guard "$dir" "" "")

    assert_claimed "$dir" "an unassigned work bead was not claimed"
    ! grep -F 'was assigned to' <<<"$out" >/dev/null ||
        fail "an unassigned bead was reported as a takeover: $out"
}

# Re-entry after a crash or a re-run of the step: the bead already carries this
# session's name. Claiming again is an idempotent refresh, and must not be
# mistaken for someone else's bead.
test_own_claim_is_refreshed() {
    local dir out
    dir=$(new_case)
    out=$(run_guard "$dir" "$ME" "")

    assert_claimed "$dir" "re-running workspace-setup did not refresh this session's own claim"
    ! grep -F 'not yours to re-claim' <<<"$out" >/dev/null ||
        fail "the guard refused to re-claim this session's own bead: $out"
}

# `${GC_RIG:+$GC_RIG/}` — in an HQ-only city the refinery is a bare
# `gastown.refinery` with no rig prefix, and the skip must still recognise it.
# Getting this wrong strands beads outside the refinery pool (see the formula's
# note on the same expression in submit-and-exit).
test_refinery_is_recognised_without_a_rig_prefix() {
    local dir out
    dir=$(new_case)
    out=$(run_guard "$dir" "gastown.refinery" "" "")

    assert_not_claimed "$dir" "an HQ-only city's unprefixed refinery holder was not recognised"
    grep -F 'is held by gastown.refinery' <<<"$out" >/dev/null ||
        fail "skip path did not name the unprefixed refinery holder: $out"
}

# The claim is only real if the bead actually reads back claimed — `--status`
# on this bead has been observed not to stick (gcp-s14g), and a status that
# stays `open` leaves it in `gc bd ready`, which is the defect wearing the
# fix's clothes.
test_claim_is_read_back_and_settles() {
    local dir out
    dir=$(new_case)
    out=$(run_guard "$dir" "$CREW" "")

    ! grep -F 'after the claim; it may still be re-slung' <<<"$out" >/dev/null ||
        fail "a claim the stub accepted still reported an unsettled readback: $out"
    [[ "$(grep -c -F "bd update $BEAD --status=in_progress" "$dir/calls.log")" == "1" ]] ||
        fail "the readback loop retried a claim that had already landed"
}

# Pin the property, not just the behaviour: the skip has to be an IDENTITY test
# against named owners. "Somebody else's name is on it" is satisfied by every
# crew seat, which is the ordinary shape of planned work and was the defect.
test_skip_condition_names_its_owners() {
    local dir
    dir=$(new_case)

    grep -F '[ "$CURRENT_ASSIGNEE" = "$REFINERY_TARGET" ]' "$dir/guard.sh" >/dev/null ||
        fail "the skip must test the assignee against the refinery target by identity"
    grep -F '[ "$CURRENT_ROUTED_TO" = "human" ]' "$dir/guard.sh" >/dev/null ||
        fail "the skip must recognise the gc.routed_to=human operator escalation"
    ! grep -F '[ -n "$CURRENT_ASSIGNEE" ] && [ "$CURRENT_ASSIGNEE" != "$POLECAT_SESSION" ]' \
        "$dir/guard.sh" >/dev/null ||
        fail "the skip is back to 'any assignee that is not me', which voids the claim on every crew-authored bead"

    # Routing is READ here to spot the escalation; stamping it would break the
    # pool's spawn accounting (the formula says so directly).
    ! grep -F 'set-metadata gc.routed_to' "$dir/guard.sh" >/dev/null ||
        fail "the claim guard must not stamp gc.routed_to; routing lives on the molecule root"
}

test_crew_assigned_work_bead_is_claimed
test_refinery_held_work_bead_is_left_alone
test_operator_escalation_is_left_alone
test_unassigned_work_bead_is_claimed
test_own_claim_is_refreshed
test_refinery_is_recognised_without_a_rig_prefix
test_claim_is_read_back_and_settles
test_skip_condition_names_its_owners

echo "PASS: $(basename "$0")"
