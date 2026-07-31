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

echo "merge approval gate tests passed"
