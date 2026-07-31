#!/usr/bin/env bash
# Contract tests for the gc-native merge approval signal.
#
# The producer must never leave a half-written signal behind, and the gate must
# refuse every path that is not a current, matching approval — including the
# paths where it cannot reach a verdict at all. Most of what follows is
# fail-closed coverage; the happy paths are the two small tests at the end.
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
PRODUCER="$ROOT/gastown/assets/scripts/record-merge-approval.sh"
GATE="$ROOT/gastown/assets/scripts/checks/merge-approval-gate.sh"

SHA_APPROVED=$(printf 'a%.0s' $(seq 1 40))
SHA_OTHER=$(printf 'b%.0s' $(seq 1 40))

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

write_gc_stub() {
    local bin="$1"
    mkdir -p "$bin"
    cat >"$bin/gc" <<'SH'
#!/usr/bin/env bash
# Only `gc bd show <id> --json` and `gc bd update <id> --set-metadata ...`
# are exercised here.
case "${1:-} ${2:-}" in
    "bd show")
        if [ -n "${STUB_BEAD_JSON:-}" ] && [ -f "$STUB_BEAD_JSON" ]; then
            cat "$STUB_BEAD_JSON"
            exit 0
        fi
        exit 1
        ;;
    "bd update")
        printf '%s\n' "$*" >>"${STUB_UPDATE_LOG:-/dev/null}"
        exit "${STUB_UPDATE_EXIT:-0}"
        ;;
esac
exit 0
SH
    chmod +x "$bin/gc"
}

write_gh_stub() {
    local bin="$1"
    mkdir -p "$bin"
    cat >"$bin/gh" <<'SH'
#!/usr/bin/env bash
# Only `gh pr view <number> --json ...` is exercised here.
if [ "${STUB_GH_EXIT:-0}" != "0" ]; then
    echo "gh: simulated failure" >&2
    exit "${STUB_GH_EXIT}"
fi
if [ -n "${STUB_PR_JSON:-}" ] && [ -f "$STUB_PR_JSON" ]; then
    cat "$STUB_PR_JSON"
    exit 0
fi
exit 1
SH
    chmod +x "$bin/gh"
}

# bead_json writes a work bead payload in the shape `gc bd show --json` returns
# (a single-element array). $1 = output path, remaining args = metadata k=v.
bead_json() {
    local out="$1"
    shift
    local jq_args=(-n)
    local filter='{id: "wb-1", metadata: {}}'
    local i=0
    for pair in "$@"; do
        i=$((i + 1))
        jq_args+=(--arg "k$i" "${pair%%=*}" --arg "v$i" "${pair#*=}")
        filter="$filter | .metadata[\$k$i] = \$v$i"
    done
    jq "${jq_args[@]}" "[$filter]" >"$out"
}

pr_json() {
    local out="$1" number="$2" state="$3" head_ref="$4" head_sha="$5"
    jq -n \
        --argjson number "$number" \
        --arg state "$state" \
        --arg headRefName "$head_ref" \
        --arg headRefOid "$head_sha" \
        '{number: $number, state: $state, headRefName: $headRefName, headRefOid: $headRefOid}' \
        >"$out"
}

# run_gate invokes the gate with the standard stub environment and captures its
# exit status and stderr. Sets GATE_STATUS and GATE_OUTPUT.
run_gate() {
    local bin="$1" bead_file="$2" pr_file="$3"
    shift 3
    set +e
    GATE_OUTPUT=$(PATH="$bin:$PATH" \
        STUB_BEAD_JSON="$bead_file" \
        STUB_PR_JSON="$pr_file" \
        STUB_GH_EXIT="${STUB_GH_EXIT:-0}" \
        bash "$GATE" --bead wb-1 --required true "$@" 2>&1)
    GATE_STATUS=$?
    set -e
}

expect_refusal() {
    local want_reason="$1"
    [ "$GATE_STATUS" -eq 1 ] ||
        fail "expected refusal (exit 1) for $want_reason, got exit $GATE_STATUS: $GATE_OUTPUT"
    grep -F "reason=$want_reason" <<<"$GATE_OUTPUT" >/dev/null ||
        fail "expected refusal reason=$want_reason, got: $GATE_OUTPUT"
}

expect_undecidable() {
    local want_reason="$1"
    [ "$GATE_STATUS" -eq 2 ] ||
        fail "expected undecidable (exit 2) for $want_reason, got exit $GATE_STATUS: $GATE_OUTPUT"
    grep -F "reason=$want_reason" <<<"$GATE_OUTPUT" >/dev/null ||
        fail "expected undecidable reason=$want_reason, got: $GATE_OUTPUT"
}

# ── Producer ────────────────────────────────────────────────────────────────

test_producer_records_complete_signal() {
    local tmp bin log
    tmp=$(mktemp -d)
    bin="$tmp/bin"
    log="$tmp/update.log"
    write_gc_stub "$bin"

    PATH="$bin:$PATH" STUB_UPDATE_LOG="$log" GC_AGENT="rig/specialists.iris" \
        bash "$PRODUCER" \
        --bead wb-1 \
        --pr "https://github.com/acme/widgets/pull/7" \
        --sha "$(printf '%s' "$SHA_APPROVED" | tr '[:lower:]' '[:upper:]')" \
        --verdict approved >/dev/null ||
        fail "producer failed on a valid approval"

    [[ "$(wc -l <"$log")" -eq 1 ]] ||
        fail "producer must write the whole signal in a single bd update"
    local line
    line=$(cat "$log")
    grep -F 'merge_approval.verdict=approved' <<<"$line" >/dev/null ||
        fail "verdict not recorded: $line"
    grep -F 'merge_approval.pr_number=7' <<<"$line" >/dev/null ||
        fail "PR URL was not normalized to a number: $line"
    grep -F "merge_approval.head_sha=$SHA_APPROVED" <<<"$line" >/dev/null ||
        fail "head SHA not normalized to lowercase: $line"
    grep -F 'merge_approval.reviewer=rig/specialists.iris' <<<"$line" >/dev/null ||
        fail "reviewer identity not recorded from GC_AGENT: $line"
    grep -E 'merge_approval\.recorded_at=[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z' <<<"$line" >/dev/null ||
        fail "timestamp not recorded: $line"
}

test_producer_rejects_invalid_input() {
    local tmp bin log status
    tmp=$(mktemp -d)
    bin="$tmp/bin"
    log="$tmp/update.log"
    write_gc_stub "$bin"
    : >"$log"

    # An abbreviated SHA cannot be compared against the live head, so it must
    # not be recordable at all.
    set +e
    PATH="$bin:$PATH" STUB_UPDATE_LOG="$log" GC_AGENT="iris" bash "$PRODUCER" \
        --bead wb-1 --pr 7 --sha "aaaaaaa" --verdict approved >/dev/null 2>&1
    status=$?
    set -e
    [ "$status" -eq 2 ] || fail "abbreviated SHA should be rejected with exit 2, got $status"

    set +e
    PATH="$bin:$PATH" STUB_UPDATE_LOG="$log" GC_AGENT="iris" bash "$PRODUCER" \
        --bead wb-1 --pr 7 --sha "$SHA_APPROVED" --verdict lgtm >/dev/null 2>&1
    status=$?
    set -e
    [ "$status" -eq 2 ] || fail "unknown verdict should be rejected with exit 2, got $status"

    set +e
    PATH="$bin:$PATH" STUB_UPDATE_LOG="$log" GC_AGENT="iris" bash "$PRODUCER" \
        --bead wb-1 --pr "not-a-pr" --sha "$SHA_APPROVED" --verdict approved >/dev/null 2>&1
    status=$?
    set -e
    [ "$status" -eq 2 ] || fail "unparseable PR reference should be rejected with exit 2, got $status"

    # No reviewer identity anywhere: an anonymous approval is not a signal.
    set +e
    PATH="$bin:$PATH" STUB_UPDATE_LOG="$log" GC_AGENT="" BEADS_ACTOR="" bash "$PRODUCER" \
        --bead wb-1 --pr 7 --sha "$SHA_APPROVED" --verdict approved >/dev/null 2>&1
    status=$?
    set -e
    [ "$status" -eq 2 ] || fail "missing reviewer identity should be rejected with exit 2, got $status"

    [[ ! -s "$log" ]] || fail "rejected input must not write anything to the bead: $(cat "$log")"
}

test_producer_surfaces_write_failure() {
    local tmp bin status
    tmp=$(mktemp -d)
    bin="$tmp/bin"
    write_gc_stub "$bin"

    set +e
    PATH="$bin:$PATH" STUB_UPDATE_EXIT=1 GC_AGENT="iris" bash "$PRODUCER" \
        --bead wb-1 --pr 7 --sha "$SHA_APPROVED" --verdict approved >/dev/null 2>&1
    status=$?
    set -e
    [ "$status" -eq 1 ] || fail "a failed bead write must exit 1, got $status"
}

# ── Gate: opt-in ────────────────────────────────────────────────────────────

test_gate_is_opt_in() {
    local tmp bin status output
    tmp=$(mktemp -d)
    bin="$tmp/bin"
    write_gc_stub "$bin"
    write_gh_stub "$bin"

    # No bead payload is staged: a gate that reached the store would fail. The
    # disabled gate must not look at all.
    for value in "" false FALSE 0 no off; do
        set +e
        output=$(PATH="$bin:$PATH" bash "$GATE" --bead wb-1 --required "$value" 2>&1)
        status=$?
        set -e
        [ "$status" -eq 0 ] ||
            fail "--required '$value' should disable the gate, got exit $status: $output"
        grep -F 'GATE: not-required' <<<"$output" >/dev/null ||
            fail "--required '$value' should report not-required, got: $output"
    done

    # Unset falls back to the env var, which is also unset here.
    set +e
    output=$(PATH="$bin:$PATH" bash "$GATE" --bead wb-1 2>&1)
    status=$?
    set -e
    [ "$status" -eq 0 ] || fail "an unset opt-in should disable the gate, got exit $status: $output"
}

test_gate_treats_unrecognized_opt_in_as_enabled() {
    local tmp bin bead pr
    tmp=$(mktemp -d)
    bin="$tmp/bin"
    bead="$tmp/bead.json"
    pr="$tmp/pr.json"
    write_gc_stub "$bin"
    write_gh_stub "$bin"
    bead_json "$bead" "branch=polecat/wb-1"
    pr_json "$pr" 7 OPEN "polecat/wb-1" "$SHA_APPROVED"

    # A typo in the rig config must not silently disable review.
    set +e
    GATE_OUTPUT=$(PATH="$bin:$PATH" STUB_BEAD_JSON="$bead" STUB_PR_JSON="$pr" \
        bash "$GATE" --bead wb-1 --required "ture" 2>&1)
    GATE_STATUS=$?
    set -e
    expect_refusal "no_approval_signal"
}

# ── Gate: fail-closed refusals ──────────────────────────────────────────────

test_gate_refuses_missing_and_partial_signals() {
    local tmp bin bead pr
    tmp=$(mktemp -d)
    bin="$tmp/bin"
    bead="$tmp/bead.json"
    pr="$tmp/pr.json"
    write_gc_stub "$bin"
    write_gh_stub "$bin"
    pr_json "$pr" 7 OPEN "polecat/wb-1" "$SHA_APPROVED"

    bead_json "$bead" "branch=polecat/wb-1"
    run_gate "$bin" "$bead" "$pr"
    expect_refusal "no_approval_signal"

    # A verdict without the SHA that scopes it is the dangerous half-write.
    bead_json "$bead" \
        "branch=polecat/wb-1" \
        "merge_approval.verdict=approved" \
        "merge_approval.pr_number=7"
    run_gate "$bin" "$bead" "$pr"
    expect_refusal "incomplete_approval_signal"

    # Reviewer identity and timestamp are part of the signal, not decoration.
    bead_json "$bead" \
        "branch=polecat/wb-1" \
        "merge_approval.verdict=approved" \
        "merge_approval.pr_number=7" \
        "merge_approval.head_sha=$SHA_APPROVED"
    run_gate "$bin" "$bead" "$pr"
    expect_refusal "incomplete_approval_signal"
}

test_gate_refuses_non_approving_verdict() {
    local tmp bin bead pr
    tmp=$(mktemp -d)
    bin="$tmp/bin"
    bead="$tmp/bead.json"
    pr="$tmp/pr.json"
    write_gc_stub "$bin"
    write_gh_stub "$bin"
    pr_json "$pr" 7 OPEN "polecat/wb-1" "$SHA_APPROVED"
    bead_json "$bead" \
        "branch=polecat/wb-1" \
        "merge_approval.verdict=changes_requested" \
        "merge_approval.pr_number=7" \
        "merge_approval.head_sha=$SHA_APPROVED" \
        "merge_approval.reviewer=iris" \
        "merge_approval.recorded_at=2026-07-31T18:00:00Z"

    run_gate "$bin" "$bead" "$pr"
    expect_refusal "verdict_not_approved"
}

test_gate_refuses_wrong_pr_number() {
    local tmp bin bead pr
    tmp=$(mktemp -d)
    bin="$tmp/bin"
    bead="$tmp/bead.json"
    pr="$tmp/pr.json"
    write_gc_stub "$bin"
    write_gh_stub "$bin"
    pr_json "$pr" 7 OPEN "polecat/wb-1" "$SHA_APPROVED"

    # An approval recorded against a different PR cannot authorize this one.
    bead_json "$bead" \
        "branch=polecat/wb-1" \
        "pr_number=7" \
        "merge_approval.verdict=approved" \
        "merge_approval.pr_number=9" \
        "merge_approval.head_sha=$SHA_APPROVED" \
        "merge_approval.reviewer=iris" \
        "merge_approval.recorded_at=2026-07-31T18:00:00Z"
    run_gate "$bin" "$bead" "$pr"
    expect_refusal "pr_number_mismatch"

    # Same check when the bead carries only the PR URL form.
    bead_json "$bead" \
        "branch=polecat/wb-1" \
        "pr_url=https://github.com/acme/widgets/pull/7" \
        "merge_approval.verdict=approved" \
        "merge_approval.pr_number=9" \
        "merge_approval.head_sha=$SHA_APPROVED" \
        "merge_approval.reviewer=iris" \
        "merge_approval.recorded_at=2026-07-31T18:00:00Z"
    run_gate "$bin" "$bead" "$pr"
    expect_refusal "pr_number_mismatch"
}

test_gate_refuses_stale_head_sha() {
    local tmp bin bead pr
    tmp=$(mktemp -d)
    bin="$tmp/bin"
    bead="$tmp/bead.json"
    pr="$tmp/pr.json"
    write_gc_stub "$bin"
    write_gh_stub "$bin"

    # Approval was recorded for SHA_APPROVED; the author has since pushed
    # SHA_OTHER. The approval must not follow the branch forward.
    pr_json "$pr" 7 OPEN "polecat/wb-1" "$SHA_OTHER"
    bead_json "$bead" \
        "branch=polecat/wb-1" \
        "pr_number=7" \
        "merge_approval.verdict=approved" \
        "merge_approval.pr_number=7" \
        "merge_approval.head_sha=$SHA_APPROVED" \
        "merge_approval.reviewer=iris" \
        "merge_approval.recorded_at=2026-07-31T18:00:00Z"

    run_gate "$bin" "$bead" "$pr"
    expect_refusal "stale_head_sha"
}

test_gate_refuses_merge_sha_that_was_not_approved() {
    local tmp bin bead pr
    tmp=$(mktemp -d)
    bin="$tmp/bin"
    bead="$tmp/bead.json"
    pr="$tmp/pr.json"
    write_gc_stub "$bin"
    write_gh_stub "$bin"
    pr_json "$pr" 7 OPEN "polecat/wb-1" "$SHA_APPROVED"
    bead_json "$bead" \
        "branch=polecat/wb-1" \
        "pr_number=7" \
        "merge_approval.verdict=approved" \
        "merge_approval.pr_number=7" \
        "merge_approval.head_sha=$SHA_APPROVED" \
        "merge_approval.reviewer=iris" \
        "merge_approval.recorded_at=2026-07-31T18:00:00Z"

    # The refinery is about to merge a commit that is not the reviewed one:
    # the local branch tip drifted from the PR head.
    run_gate "$bin" "$bead" "$pr" --merge-sha "$SHA_OTHER"
    expect_refusal "merge_sha_not_approved"
}

test_gate_refuses_unbindable_or_closed_pr() {
    local tmp bin bead pr
    tmp=$(mktemp -d)
    bin="$tmp/bin"
    bead="$tmp/bead.json"
    pr="$tmp/pr.json"
    write_gc_stub "$bin"
    write_gh_stub "$bin"

    # No branch on the bead: nothing ties the reviewed PR to this work.
    pr_json "$pr" 7 OPEN "polecat/wb-1" "$SHA_APPROVED"
    bead_json "$bead" \
        "merge_approval.verdict=approved" \
        "merge_approval.pr_number=7" \
        "merge_approval.head_sha=$SHA_APPROVED" \
        "merge_approval.reviewer=iris" \
        "merge_approval.recorded_at=2026-07-31T18:00:00Z"
    run_gate "$bin" "$bead" "$pr"
    expect_refusal "bead_has_no_branch"

    # The reviewed PR belongs to some other branch.
    pr_json "$pr" 7 OPEN "polecat/other" "$SHA_APPROVED"
    bead_json "$bead" \
        "branch=polecat/wb-1" \
        "merge_approval.verdict=approved" \
        "merge_approval.pr_number=7" \
        "merge_approval.head_sha=$SHA_APPROVED" \
        "merge_approval.reviewer=iris" \
        "merge_approval.recorded_at=2026-07-31T18:00:00Z"
    run_gate "$bin" "$bead" "$pr"
    expect_refusal "pr_branch_mismatch"

    # A closed PR is not a live approval target.
    pr_json "$pr" 7 CLOSED "polecat/wb-1" "$SHA_APPROVED"
    bead_json "$bead" \
        "branch=polecat/wb-1" \
        "merge_approval.verdict=approved" \
        "merge_approval.pr_number=7" \
        "merge_approval.head_sha=$SHA_APPROVED" \
        "merge_approval.reviewer=iris" \
        "merge_approval.recorded_at=2026-07-31T18:00:00Z"
    run_gate "$bin" "$bead" "$pr"
    expect_refusal "pr_not_open"
}

test_gate_refuses_when_it_cannot_evaluate() {
    local tmp bin bead pr
    tmp=$(mktemp -d)
    bin="$tmp/bin"
    bead="$tmp/bead.json"
    pr="$tmp/pr.json"
    write_gc_stub "$bin"
    write_gh_stub "$bin"
    pr_json "$pr" 7 OPEN "polecat/wb-1" "$SHA_APPROVED"
    bead_json "$bead" \
        "branch=polecat/wb-1" \
        "merge_approval.verdict=approved" \
        "merge_approval.pr_number=7" \
        "merge_approval.head_sha=$SHA_APPROVED" \
        "merge_approval.reviewer=iris" \
        "merge_approval.recorded_at=2026-07-31T18:00:00Z"

    # The PR lookup fails: the gate cannot tell whether the approval is
    # current, so it must not merge.
    STUB_GH_EXIT=1 run_gate "$bin" "$bead" "$pr"
    unset STUB_GH_EXIT
    expect_undecidable "pr_lookup_failed"

    # GitHub answered but without a usable head SHA.
    jq -n '{number: 7, state: "OPEN", headRefName: "polecat/wb-1", headRefOid: ""}' >"$pr"
    run_gate "$bin" "$bead" "$pr"
    expect_undecidable "unresolvable_live_head_sha"

    # The bead store is unreadable.
    pr_json "$pr" 7 OPEN "polecat/wb-1" "$SHA_APPROVED"
    run_gate "$bin" "$tmp/missing-bead.json" "$pr"
    expect_undecidable "bead_unreadable"
}

# ── Gate: permitted merges ──────────────────────────────────────────────────

test_gate_permits_current_approval() {
    local tmp bin bead pr
    tmp=$(mktemp -d)
    bin="$tmp/bin"
    bead="$tmp/bead.json"
    pr="$tmp/pr.json"
    write_gc_stub "$bin"
    write_gh_stub "$bin"
    pr_json "$pr" 7 OPEN "polecat/wb-1" "$SHA_APPROVED"
    bead_json "$bead" \
        "branch=polecat/wb-1" \
        "pr_number=7" \
        "merge_approval.verdict=approved" \
        "merge_approval.pr_number=7" \
        "merge_approval.head_sha=$SHA_APPROVED" \
        "merge_approval.reviewer=rig/specialists.iris" \
        "merge_approval.recorded_at=2026-07-31T18:00:00Z"

    run_gate "$bin" "$bead" "$pr" --merge-sha "$SHA_APPROVED"
    [ "$GATE_STATUS" -eq 0 ] ||
        fail "a current approval matching the live head should permit the merge: $GATE_OUTPUT"
    grep -F "GATE: approved" <<<"$GATE_OUTPUT" >/dev/null ||
        fail "the permitted path should report the approval it acted on: $GATE_OUTPUT"
    grep -F "reviewer=rig/specialists.iris" <<<"$GATE_OUTPUT" >/dev/null ||
        fail "the permitted path should name the approving reviewer: $GATE_OUTPUT"
}

test_gate_resolves_pr_without_gh_cli() {
    local tmp bin bead pr status output
    tmp=$(mktemp -d)
    bin="$tmp/bin"
    bead="$tmp/bead.json"
    pr="$tmp/pr.json"
    mkdir -p "$bin"
    write_gc_stub "$bin"

    # Rigs without the gh CLI must still be able to reach a verdict, otherwise
    # the fail-closed gate deadlocks them permanently — the very failure this
    # gate exists to end. Build a hermetic PATH so the host's real gh cannot
    # satisfy `command -v gh`.
    local tool
    for tool in bash basename cat tr sed head awk jq sleep; do
        ln -sf "$(command -v "$tool")" "$bin/$tool"
    done
    cat >"$bin/git" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = "remote" ] && [ "${2:-}" = "get-url" ]; then
    echo "https://github.com/acme/widgets.git"
    exit 0
fi
exit 1
SH
    chmod +x "$bin/git"
    cat >"$bin/curl" <<'SH'
#!/usr/bin/env bash
# Answer only the pulls endpoint for the expected repo, in REST shape.
for arg in "$@"; do
    case "$arg" in
        https://api.github.com/repos/acme/widgets/pulls/7)
            cat "$STUB_REST_JSON"
            exit 0
            ;;
    esac
done
exit 22
SH
    chmod +x "$bin/curl"

    jq -n --arg sha "$SHA_APPROVED" \
        '{number: 7, state: "open", head: {ref: "polecat/wb-1", sha: $sha}}' >"$pr"
    bead_json "$bead" \
        "branch=polecat/wb-1" \
        "pr_number=7" \
        "merge_approval.verdict=approved" \
        "merge_approval.pr_number=7" \
        "merge_approval.head_sha=$SHA_APPROVED" \
        "merge_approval.reviewer=iris" \
        "merge_approval.recorded_at=2026-07-31T18:00:00Z"

    set +e
    output=$(PATH="$bin" STUB_BEAD_JSON="$bead" STUB_REST_JSON="$pr" GH_TOKEN=stub-token \
        "$bin/bash" "$GATE" --bead wb-1 --required true --merge-sha "$SHA_APPROVED" 2>&1)
    status=$?
    set -e
    [ "$status" -eq 0 ] ||
        fail "REST fallback should reach the same verdict without gh, got exit $status: $output"
    grep -F "GATE: approved" <<<"$output" >/dev/null ||
        fail "REST fallback should report the approval: $output"
}

# ── Formula wiring ──────────────────────────────────────────────────────────

test_refinery_patrol_consumes_the_gate() {
    local formula="$ROOT/gastown/formulas/mol-refinery-patrol.toml"

    # Parse the TOML rather than grepping around the var block: the default
    # sits after a multi-line description, and an off-by-default gate is the
    # single most important property to assert.
    python3 - "$formula" <<'PY' || fail "require_merge_approval must be declared and default to off"
import sys, tomllib

with open(sys.argv[1], "rb") as handle:
    formula = tomllib.load(handle)
var = formula.get("vars", {}).get("require_merge_approval")
if var is None:
    sys.exit("patrol formula does not declare require_merge_approval")
if var.get("default") != "false":
    sys.exit(f"require_merge_approval default is {var.get('default')!r}, want 'false'")
PY
    grep -F 'merge-approval-gate.sh' "$formula" >/dev/null ||
        fail "patrol formula should invoke the merge approval gate"
    grep -F 'APPROVAL_GATE_STATUS' "$formula" >/dev/null ||
        fail "patrol formula should branch on the gate's exit status"
    grep -F 'merge_approval_state=awaiting_review' "$formula" >/dev/null ||
        fail "a refused merge should park the bead as awaiting_review, not close it"
    # The gate must not be reachable only through GC_PACK_DIR / the city
    # scripts dir again — neither exists in the refinery's shell (gcp-amo).
    grep -F 'gc formula list' "$formula" >/dev/null ||
        fail "the gate must be resolved from the formula's own pack tree, not env vars alone"
}

# ── Gate resolution (gcp-amo) ───────────────────────────────────────────────
#
# The four-candidate lookup this formula shipped with could not resolve the
# gate from the context the refinery actually runs in: GC_PACK_DIR is exported
# only for gc *pack commands* and is unset in every agent process, and nothing
# materializes pack check scripts into `$GC_CITY/.gc/scripts/checks/`. The gate
# was therefore permanently unresolvable, so turning require_merge_approval on
# hard-stopped patrol instead of gating it.
#
# These tests execute the formula's own wiring block rather than a transcription
# of it, so they fail if the resolution strategy regresses. GC_PACK_DIR is unset
# throughout — that is the real runtime condition, not a hypothetical.

# extract_gate_wiring writes the formula's marked wiring block to $1, with the
# formula vars substituted. $2 = require_merge_approval, $3 = review_agent.
extract_gate_wiring() {
    local out="$1" required="${2:-true}" review_agent="${3:-}"
    python3 - "$ROOT/gastown/formulas/mol-refinery-patrol.toml" \
        "$out" "$required" "$review_agent" <<'PY' ||
import sys, tomllib

formula_path, out_path, required, review_agent = sys.argv[1:5]
START = "# >>> merge-approval-gate-wiring >>>"
END = "# <<< merge-approval-gate-wiring <<<"

with open(formula_path, "rb") as handle:
    formula = tomllib.load(handle)

blocks = [
    step.get("description", "")
    for step in formula.get("steps", [])
    if START in step.get("description", "")
]
if len(blocks) != 1:
    sys.exit(f"expected exactly one wiring block, found {len(blocks)}")
body = blocks[0]
block = body[body.index(START) : body.index(END) + len(END)]
if "{{" in block.replace("{{require_merge_approval}}", "").replace(
    "{{review_agent}}", ""
):
    sys.exit("wiring block references a formula var the tests do not substitute")
block = block.replace("{{require_merge_approval}}", required)
block = block.replace("{{review_agent}}", review_agent)
with open(out_path, "w") as handle:
    handle.write(block + "\n")
PY
        fail "could not extract the gate wiring block from the patrol formula"
}

# write_formula_gc_stub writes a `gc` that answers `formula list --json` with
# $2 as mol-refinery-patrol's source path (empty = formula not found), logs
# every bead-write and nudge invocation, and records a `runtime drain-ack`.
write_formula_gc_stub() {
    local bin="$1" source_path="$2"
    mkdir -p "$bin"
    cat >"$bin/gc" <<'SH'
#!/usr/bin/env bash
# Subcommands are matched one word at a time so this stub never spells a
# bare beads invocation that tests/test_no_bare_bd_commands.py would flag.
case "${1:-}" in
    formula)
        [ "${2:-}" = "list" ] || exit 0
        if [ -n "${STUB_FORMULA_SOURCE:-}" ]; then
            jq -n --arg source "$STUB_FORMULA_SOURCE" \
                '{formulas: [{name: "mol-other", source: "/nope/formulas/mol-other.toml"},
                             {name: "mol-refinery-patrol", source: $source}]}'
        else
            jq -n '{formulas: []}'
        fi
        exit 0
        ;;
    bd|session)
        printf '%s\n' "$*" >>"${STUB_UPDATE_LOG:-/dev/null}"
        exit 0
        ;;
    runtime)
        [ "${2:-}" = "drain-ack" ] &&
            printf 'drain-ack\n' >>"${STUB_UPDATE_LOG:-/dev/null}"
        exit 0
        ;;
esac
exit 0
SH
    chmod +x "$bin/gc"
    STUB_FORMULA_SOURCE="$source_path"
    export STUB_FORMULA_SOURCE
}

# plant_pack_tree materializes a pack tree at $1 holding the real gate script,
# and echoes the formula source path inside it.
plant_pack_tree() {
    local pack="$1"
    mkdir -p "$pack/formulas" "$pack/assets/scripts/checks"
    cp "$GATE" "$pack/assets/scripts/checks/merge-approval-gate.sh"
    : >"$pack/formulas/mol-refinery-patrol.toml"
    printf '%s\n' "$pack/formulas/mol-refinery-patrol.toml"
}

# run_wiring sources the extracted block in an isolated shell. $1 = wiring
# file, $2 = bin dir, remaining env comes from the caller. Sets WIRING_STATUS
# and WIRING_OUTPUT; the resolved gate path is echoed as the last line.
run_wiring() {
    local wiring="$1" bin="$2"
    set +e
    WIRING_OUTPUT=$(PATH="$bin:$PATH" \
        GC_CITY="${GC_CITY:-}" GC_CITY_PATH="${GC_CITY_PATH:-}" \
        bash -c '
            unset GC_PACK_DIR
            APPROVAL_REQUIRED=1
            WORK=wb-1
            . "$1"
            printf "RESOLVED=%s\n" "$APPROVAL_GATE"
        ' _ "$wiring" 2>&1)
    WIRING_STATUS=$?
    set -e
}

test_gate_resolver_finds_the_pack_tree_without_gc_pack_dir() {
    local tmp bin wiring pack source
    tmp=$(mktemp -d)
    bin="$tmp/bin"
    wiring="$tmp/wiring.sh"
    pack="$tmp/pack/gastown"
    source=$(plant_pack_tree "$pack")
    extract_gate_wiring "$wiring"
    write_formula_gc_stub "$bin" "$source"

    # No city scripts dir anywhere: the pack tree is the only thing that can
    # answer, which is exactly the production shape.
    GC_CITY="$tmp/city" GC_CITY_PATH="$tmp/city" run_wiring "$wiring" "$bin"

    [ "$WIRING_STATUS" -eq 0 ] ||
        fail "wiring should resolve the gate with GC_PACK_DIR unset, got exit $WIRING_STATUS: $WIRING_OUTPUT"
    grep -Fx "RESOLVED=$pack/assets/scripts/checks/merge-approval-gate.sh" <<<"$WIRING_OUTPUT" >/dev/null ||
        fail "expected the gate resolved from the formula's own pack tree, got: $WIRING_OUTPUT"
    rm -rf "$tmp"
}

test_gate_resolver_works_for_a_sha_pinned_pack() {
    local tmp bin wiring pack source
    tmp=$(mktemp -d)
    bin="$tmp/bin"
    wiring="$tmp/wiring.sh"
    # gc checks a SHA pin out into the content-addressed pack cache and reports
    # that path, so a pinned rig must resolve the same way a branch-tracking one
    # does. Mirror the cache layout rather than a checkout-shaped path.
    pack="$tmp/.gc/cache/repos/$(printf 'c%.0s' $(seq 1 64))/gastown"
    source=$(plant_pack_tree "$pack")
    extract_gate_wiring "$wiring"
    write_formula_gc_stub "$bin" "$source"

    GC_CITY="$tmp/city" GC_CITY_PATH="$tmp/city" run_wiring "$wiring" "$bin"

    [ "$WIRING_STATUS" -eq 0 ] ||
        fail "a SHA-pinned pack should resolve, got exit $WIRING_STATUS: $WIRING_OUTPUT"
    grep -Fx "RESOLVED=$pack/assets/scripts/checks/merge-approval-gate.sh" <<<"$WIRING_OUTPUT" >/dev/null ||
        fail "expected the gate resolved from the pinned pack cache, got: $WIRING_OUTPUT"
    rm -rf "$tmp"
}

test_gate_resolver_falls_back_to_the_city_scripts_dir() {
    local tmp bin wiring city
    tmp=$(mktemp -d)
    bin="$tmp/bin"
    wiring="$tmp/wiring.sh"
    city="$tmp/city"
    mkdir -p "$city/.gc/scripts/checks"
    cp "$GATE" "$city/.gc/scripts/checks/merge-approval-gate.sh"
    extract_gate_wiring "$wiring"
    # gc cannot name the formula's source; the materialized city copy must
    # still be honoured so cities that do stage checks keep working.
    write_formula_gc_stub "$bin" ""

    GC_CITY="$city" GC_CITY_PATH="$city" run_wiring "$wiring" "$bin"

    [ "$WIRING_STATUS" -eq 0 ] ||
        fail "the city scripts dir should still resolve, got exit $WIRING_STATUS: $WIRING_OUTPUT"
    grep -Fx "RESOLVED=$city/.gc/scripts/checks/merge-approval-gate.sh" <<<"$WIRING_OUTPUT" >/dev/null ||
        fail "expected the city-materialized gate, got: $WIRING_OUTPUT"
    rm -rf "$tmp"
}

test_gate_wiring_still_fails_closed_when_nothing_resolves() {
    local tmp bin wiring log output status
    tmp=$(mktemp -d)
    bin="$tmp/bin"
    wiring="$tmp/wiring.sh"
    log="$tmp/update.log"
    extract_gate_wiring "$wiring"
    write_formula_gc_stub "$bin" ""

    set +e
    output=$(PATH="$bin:$PATH" STUB_UPDATE_LOG="$log" \
        GC_CITY="$tmp/city" GC_CITY_PATH="$tmp/city" \
        bash -c '
            unset GC_PACK_DIR
            cd "$2"
            APPROVAL_REQUIRED=1
            WORK=wb-1
            . "$1"
            echo "REACHED_MERGE"
        ' _ "$wiring" "$tmp" 2>&1)
    status=$?
    set -e

    [ "$status" -eq 1 ] ||
        fail "an unresolvable gate must stop with exit 1, got exit $status: $output"
    grep -F "REACHED_MERGE" <<<"$output" >/dev/null &&
        fail "an unresolvable gate must not fall through to the merge: $output"
    grep -F "An unreadable gate is not an approval." <<<"$output" >/dev/null ||
        fail "expected the fail-closed refusal message, got: $output"
    grep -F "set-metadata" "$log" >/dev/null &&
        fail "the fail-closed path must not mutate bead state: $(cat "$log")"
    rm -rf "$tmp"
}

test_resolved_gate_parks_an_unapproved_bead_instead_of_stopping() {
    local tmp bin wiring pack source log bead output status
    tmp=$(mktemp -d)
    bin="$tmp/bin"
    wiring="$tmp/wiring.sh"
    pack="$tmp/pack/gastown"
    log="$tmp/update.log"
    bead="$tmp/bead.json"
    source=$(plant_pack_tree "$pack")
    extract_gate_wiring "$wiring"
    write_formula_gc_stub "$bin" "$source"
    # A work bead with a PR but no approval signal at all — the ordinary state
    # of every bead the moment it reaches the refinery.
    bead_json "$bead" "pr_url=https://github.com/acme/widgets/pull/7"

    set +e
    output=$(PATH="$bin:$PATH" STUB_UPDATE_LOG="$log" STUB_BEAD_JSON="$bead" \
        GC_CITY="$tmp/city" GC_CITY_PATH="$tmp/city" \
        bash -c '
            unset GC_PACK_DIR
            APPROVAL_REQUIRED=1
            WORK=wb-1
            BRANCH=polecat/wb-1
            . "$1"
            gate_output=$(run_approval_gate "$2" 2>&1)
            gate_status=$?
            if [ "$gate_status" -ne 0 ]; then
              park_awaiting_review "$gate_output"
            else
              echo "MERGED"
            fi
        ' _ "$wiring" "$SHA_APPROVED" 2>&1)
    status=$?
    set -e

    [ "$status" -eq 0 ] ||
        fail "an unapproved bead should park, not abort the iteration, got exit $status: $output"
    grep -F "MERGED" <<<"$output" >/dev/null &&
        fail "an unapproved bead must not merge: $output"
    grep -F "APPROVAL GATE REFUSED" <<<"$output" >/dev/null ||
        fail "expected the parked-refusal report, got: $output"
    grep -F "merge_approval_state=awaiting_review" "$log" >/dev/null ||
        fail "expected the bead parked as awaiting_review, log: $(cat "$log")"
    grep -F "drain-ack" "$log" >/dev/null &&
        fail "parking must not drain-ack the patrol: $(cat "$log")"
    rm -rf "$tmp"
}

test_producer_records_complete_signal
test_producer_rejects_invalid_input
test_producer_surfaces_write_failure
test_gate_is_opt_in
test_gate_treats_unrecognized_opt_in_as_enabled
test_gate_refuses_missing_and_partial_signals
test_gate_refuses_non_approving_verdict
test_gate_refuses_wrong_pr_number
test_gate_refuses_stale_head_sha
test_gate_refuses_merge_sha_that_was_not_approved
test_gate_refuses_unbindable_or_closed_pr
test_gate_refuses_when_it_cannot_evaluate
test_gate_permits_current_approval
test_gate_resolves_pr_without_gh_cli
test_refinery_patrol_consumes_the_gate
test_gate_resolver_finds_the_pack_tree_without_gc_pack_dir
test_gate_resolver_works_for_a_sha_pinned_pack
test_gate_resolver_falls_back_to_the_city_scripts_dir
test_gate_wiring_still_fails_closed_when_nothing_resolves
test_resolved_gate_parks_an_unapproved_bead_instead_of_stopping

echo "merge approval gate tests passed"
