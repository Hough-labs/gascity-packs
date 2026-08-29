#!/usr/bin/env bash
# Contract tests for the refinery direct-merge lane's ff-merge/push/verify block.
#
# The lane once closed a work bead with merge_result=merged and a merged_sha
# while the branch was NOT merged and nothing was pushed (gcp-p87, live case
# winnow-ksyp). Two defects produced it, and both are asserted here:
#
#   1. the abort depended solely on `set -e`, which did not propagate through
#      the refinery's execution harness, so execution continued past a failed
#      `git merge --ff-only` into the metadata write and the close;
#   2. the push verification was tautological on exactly that path — after a
#      failed ff-merge the worktree HEAD is still the target tip, pushing an
#      unchanged HEAD is a successful no-op, and the guard compared the old tip
#      to itself.
#
# So these tests never assert "the merge succeeded" from the function's own
# report alone. Every landing case also reads the bare origin back and requires
# that the target ADVANCED and that it advanced BY THIS BRANCH, and every
# non-landing case requires the target to be untouched. `set -e` is deliberately
# NOT set inside the extracted block, and the harness below runs it without
# `set -e` in scope, so a regression to option-inheritance shows up as a failure
# here rather than as a false merge in production.
#
# The second known bad record (winnow-rp57: merged_sha named a different bead's
# commit while its own work landed elsewhere) shares one shape with the first —
# bookkeeping recording a target TIP rather than the commit that carried the
# bead. test_lost_race_rerebases_and_lands_this_branch pins the other half:
# after a lost race the reported sha must be this branch's tip, never the
# racing commit that moved the target.
#
# A later defect (gcp-ileo, twin gascity-mfac) sat in the same block's rejection
# path: it ATTRIBUTED every push rejection to target movement without re-reading
# the remote ref, so a push-gate veto was diagnosed as a race and then retried
# three times, each retry relaunching the pre-push hook and re-queueing for a
# test-mac slot it could never win. The cause must be measured, not asserted, so
# the two rejection shapes are separated here — test_vetoed_push_stops_without_retrying
# (target stationary: one attempt, distinct status) and
# test_rejected_push_with_a_moving_target_still_retries (target really moving:
# keep retrying) — and test_push_carries_an_explicit_gate_wait_budget pins the
# budget that keeps the refinery queueing for a slot rather than refused one.
set -uo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
FORMULA="$ROOT/gastown/formulas/mol-refinery-patrol.toml"

FAILURES=0

fail() {
    echo "FAIL: $*" >&2
    FAILURES=$((FAILURES + 1))
}

# The block under test is the shipped formula text, extracted between its
# sentinels — not a transcription that could drift from what the refinery runs.
extract_block() {
    python3 - "$FORMULA" "$1" <<'PY'
import sys
import tomllib

formula, out = sys.argv[1], sys.argv[2]
begin = "# --- merge-ff-push:begin ---"
end = "# --- merge-ff-push:end ---"

with open(formula, "rb") as handle:
    doc = tomllib.load(handle)

blocks = [
    text.split(begin, 1)[1].split(end, 1)[0]
    for text in (step.get("description", "") for step in doc["steps"])
    if begin in text and end in text
]
if len(blocks) != 1:
    sys.exit(f"expected exactly one merge-ff-push block, found {len(blocks)}")

with open(out, "w") as handle:
    handle.write(blocks[0])
PY
}

git_q() { git "$@" >/dev/null 2>&1; }

# A rig: a bare origin carrying $TARGET, plus the refinery's working clone with
# `temp` rebased onto the target, exactly as the rebase step leaves it.
make_rig() {
    local tmp="$1"
    ORIGIN="$tmp/origin.git"
    WORK="$tmp/work"
    export HOME="$tmp/home"
    mkdir -p "$HOME"
    export GIT_CONFIG_GLOBAL="$HOME/.gitconfig"
    export GIT_CONFIG_NOSYSTEM=1
    export GIT_AUTHOR_NAME=refinery GIT_AUTHOR_EMAIL=refinery@example.invalid
    export GIT_COMMITTER_NAME=refinery GIT_COMMITTER_EMAIL=refinery@example.invalid

    git_q init --bare -b dev "$ORIGIN"
    git_q init -b dev "$WORK"
    git_q -C "$WORK" remote add origin "$ORIGIN"
    echo base >"$WORK/base.txt"
    git_q -C "$WORK" add base.txt
    git_q -C "$WORK" commit -m "chore: base"
    git_q -C "$WORK" push origin dev

    git_q -C "$WORK" checkout -b temp
    echo work >"$WORK/feature.txt"
    git_q -C "$WORK" add feature.txt
    git_q -C "$WORK" commit -m "feat: the work this bead carried"
}

# Someone else advances the target — on a rig whose CI pushes a deploy-overlay
# bump after every merge, this happens on every cycle.
race_the_target() {
    local tmp="$1" msg="${2:-chore: bump dev overlay [skip ci]}"
    local racer="$tmp/racer"
    rm -rf "$racer"
    git_q clone "$ORIGIN" "$racer"
    echo "$msg" >>"$racer/overlay.txt"
    git_q -C "$racer" add overlay.txt
    git_q -C "$racer" commit -m "$msg"
    git_q -C "$racer" push origin dev
    git -C "$racer" rev-parse HEAD
}

# Run the extracted block against the working clone. Echoes
# "<status>|<MERGED_SHA>|<TEMP_SHA>" and streams the block's own output to
# stderr so a failing test is debuggable.
run_merge() {
    local approval="${1:-0}"
    (
        cd "$WORK" || exit 90
        # No `set -e` here on purpose: the block must abort on its own explicit
        # exit-status checks. This is the harness boundary the false merge
        # crossed.
        # Consumed by the block sourced below, not by this shell.
        # shellcheck disable=SC2034
        BRANCH=polecat/test
        # shellcheck disable=SC2034
        TARGET=dev
        # shellcheck disable=SC2034
        APPROVAL_REQUIRED="$approval"
        MERGED_SHA=""
        TEMP_SHA=""
        # shellcheck disable=SC1090
        . "$BLOCK"
        merge_ff_push >&2
        printf '%s|%s|%s\n' "$?" "$MERGED_SHA" "$TEMP_SHA"
    )
}

origin_tip() { git --git-dir="$ORIGIN" rev-parse dev; }

status_of() { printf '%s' "${1%%|*}"; }
merged_of() { local rest="${1#*|}"; printf '%s' "${rest%%|*}"; }
temp_of() { printf '%s' "${1##*|}"; }

# --- tests ------------------------------------------------------------------

test_clean_ff_lands_and_reports_the_branch_tip() {
    local tmp got before after want
    tmp=$(mktemp -d)
    make_rig "$tmp"
    before=$(origin_tip)
    want=$(git -C "$WORK" rev-parse temp)

    got=$(run_merge 0 2>/dev/null)
    after=$(origin_tip)

    [ "$(status_of "$got")" = "0" ] ||
        fail "clean ff returned $(status_of "$got"), want 0"
    [ "$after" != "$before" ] ||
        fail "clean ff left origin/dev at $before — the target never advanced"
    [ "$after" = "$want" ] ||
        fail "clean ff left origin/dev at $after, want the branch tip $want"
    [ "$(merged_of "$got")" = "$want" ] ||
        fail "clean ff reported merged_sha $(merged_of "$got"), want the branch tip $want"
    rm -rf "$tmp"
}

test_lost_race_rerebases_and_lands_this_branch() {
    # The reported case: origin/dev moved between the rebase and the merge, so
    # the ff-merge fails. The lane must re-rebase and land, and the sha it
    # reports must be THIS branch's commit — not the racing commit that moved
    # the target, which is the mislabel winnow-rp57 recorded.
    local tmp got racing after merged
    tmp=$(mktemp -d)
    make_rig "$tmp"
    racing=$(race_the_target "$tmp")

    got=$(run_merge 0 2>/dev/null)
    after=$(origin_tip)
    merged=$(merged_of "$got")

    [ "$(status_of "$got")" = "0" ] ||
        fail "lost race returned $(status_of "$got"), want 0 (re-rebase and retry, never fall through)"
    [ "$merged" != "$racing" ] ||
        fail "lost race reported the racing commit $racing as merged_sha — a target tip, not this bead's commit"
    [ "$merged" = "$(temp_of "$got")" ] ||
        fail "lost race reported merged_sha $merged, want the post-rebase branch tip $(temp_of "$got")"
    [ "$after" = "$merged" ] ||
        fail "lost race left origin/dev at $after, want the merged sha $merged"
    git --git-dir="$ORIGIN" merge-base --is-ancestor "$racing" "$after" ||
        fail "lost race clobbered the racing commit $racing instead of rebasing onto it"
    rm -rf "$tmp"
}

test_failed_ff_with_conflicting_rebase_pushes_nothing() {
    # The winnow-ksyp shape with no mechanical way out: the ff-merge fails and
    # the re-rebase conflicts. The old lane reported merged here. Nothing may be
    # pushed and the status must be non-zero.
    local tmp got before after
    tmp=$(mktemp -d)
    make_rig "$tmp"
    # The racer touches the same file the branch does, so the re-rebase cannot
    # apply mechanically.
    echo conflicting >"$WORK/feature.txt"
    git_q -C "$WORK" add feature.txt
    git_q -C "$WORK" commit --amend -m "feat: the work this bead carried"
    local racer="$tmp/racer"
    git_q clone "$ORIGIN" "$racer"
    echo "other side" >"$racer/feature.txt"
    git_q -C "$racer" add feature.txt
    git_q -C "$racer" commit -m "feat: someone else touched the same file"
    git_q -C "$racer" push origin dev
    before=$(origin_tip)

    got=$(run_merge 0 2>/dev/null)
    after=$(origin_tip)

    [ "$(status_of "$got")" = "3" ] ||
        fail "conflicting re-rebase returned $(status_of "$got"), want 3"
    [ "$after" = "$before" ] ||
        fail "conflicting re-rebase moved origin/dev from $before to $after — nothing may be pushed"
    rm -rf "$tmp"
}

test_failed_ff_under_approval_parks_without_moving_the_branch() {
    # An approval authorizes one commit. On a lost race the lane must refuse to
    # re-rebase (that would land something no reviewer read), park, and push
    # nothing.
    local tmp got before after temp_before temp_after
    tmp=$(mktemp -d)
    make_rig "$tmp"
    race_the_target "$tmp" >/dev/null
    before=$(origin_tip)
    temp_before=$(git -C "$WORK" rev-parse temp)

    got=$(run_merge 1 2>/dev/null)
    after=$(origin_tip)
    temp_after=$(git -C "$WORK" rev-parse temp)

    [ "$(status_of "$got")" = "4" ] ||
        fail "lost race under approval returned $(status_of "$got"), want 4 (park)"
    [ "$after" = "$before" ] ||
        fail "lost race under approval moved origin/dev from $before to $after"
    [ "$temp_after" = "$temp_before" ] ||
        fail "lost race under approval re-rebased temp ($temp_before -> $temp_after); the approved head must not move here"
    rm -rf "$tmp"
}

test_push_that_does_not_advance_the_target_is_refused() {
    # The tautology, isolated: a push that exits 0 while the target ends up
    # where it started. The old guard compared the pre-push snapshot to itself
    # and passed. Verification must read the target back after the push.
    local tmp got before after
    tmp=$(mktemp -d)
    make_rig "$tmp"
    before=$(origin_tip)
    # post-receive runs after the ref moves and its exit status is ignored, so
    # the push still exits 0 while dev ends back at $before.
    cat >"$ORIGIN/hooks/post-receive" <<HOOK
#!/bin/sh
git --git-dir="$ORIGIN" update-ref refs/heads/dev $before
HOOK
    chmod +x "$ORIGIN/hooks/post-receive"

    got=$(run_merge 0 2>/dev/null)
    after=$(origin_tip)

    [ "$after" = "$before" ] ||
        fail "harness bug: dev should have been reset to $before, found $after"
    [ "$(status_of "$got")" = "2" ] ||
        fail "a push that left origin/dev unchanged returned $(status_of "$got"), want 2 (refuse to record a merge)"
    rm -rf "$tmp"
}

test_target_advanced_by_someone_else_is_refused() {
    # The target moved after the push, but not to anything containing this
    # branch. "It changed" is not "this branch landed".
    local tmp got other
    tmp=$(mktemp -d)
    make_rig "$tmp"
    # Build an unrelated commit reachable in the bare repo, then have
    # post-receive point dev at it instead of at what was pushed.
    local racer="$tmp/racer"
    git_q clone "$ORIGIN" "$racer"
    echo unrelated >"$racer/unrelated.txt"
    git_q -C "$racer" add unrelated.txt
    git_q -C "$racer" commit -m "chore: unrelated"
    git_q -C "$racer" push origin HEAD:refs/heads/parked
    other=$(git -C "$racer" rev-parse HEAD)
    cat >"$ORIGIN/hooks/post-receive" <<HOOK
#!/bin/sh
git --git-dir="$ORIGIN" update-ref refs/heads/dev $other
HOOK
    chmod +x "$ORIGIN/hooks/post-receive"

    got=$(run_merge 0 2>/dev/null)

    [ "$(origin_tip)" = "$other" ] ||
        fail "harness bug: dev should be $other, found $(origin_tip)"
    [ "$(status_of "$got")" = "2" ] ||
        fail "a target that advanced without this branch returned $(status_of "$got"), want 2"
    rm -rf "$tmp"
}

test_noop_ff_does_not_report_a_merge() {
    # origin/dev already contains temp: `merge --ff-only` succeeds as a no-op
    # and leaves HEAD at the target tip. Reporting that as merged is exactly the
    # target-tip-for-branch-tip mislabel; the already-merged gate owns this case.
    local tmp got before
    tmp=$(mktemp -d)
    make_rig "$tmp"
    git_q -C "$WORK" push origin temp:dev
    before=$(origin_tip)

    got=$(run_merge 0 2>/dev/null)

    [ "$(status_of "$got")" = "5" ] ||
        fail "no-op ff returned $(status_of "$got"), want 5"
    [ "$(origin_tip)" = "$before" ] ||
        fail "no-op ff moved origin/dev off $before"
    rm -rf "$tmp"
}

test_vetoed_push_stops_without_retrying() {
    # The push is refused while origin/dev never moves — a pre-push gate veto,
    # a remote hook, or permissions. The lane used to ATTRIBUTE every rejection
    # to target movement and retry three times, each retry relaunching the
    # pre-push hook and so re-queueing for a test-mac gate slot that three
    # attempts can never win (gcp-ileo). The cause must be MEASURED off the
    # remote ref: unchanged target => stop after one attempt, and report the
    # veto rather than a race.
    local tmp got before after attempts
    tmp=$(mktemp -d)
    make_rig "$tmp"
    before=$(origin_tip)
    cat >"$ORIGIN/hooks/pre-receive" <<HOOK
#!/bin/sh
echo x >>"$tmp/push-attempts"
echo "push refused by the test" >&2
exit 1
HOOK
    chmod +x "$ORIGIN/hooks/pre-receive"

    got=$(run_merge 0 2>/dev/null)
    after=$(origin_tip)
    attempts=$(wc -l <"$tmp/push-attempts" | tr -d ' ')

    [ "$(status_of "$got")" = "7" ] ||
        fail "a vetoed push against a target that never moved returned $(status_of "$got"), want 7 (rejected, not raced)"
    [ "$after" = "$before" ] ||
        fail "a rejected push still moved origin/dev from $before to $after"
    [ "$attempts" = "1" ] ||
        fail "a vetoed push was attempted $attempts times, want 1 — retrying a veto only adds push-gate load"
    rm -rf "$tmp"
}

test_rejected_push_with_a_moving_target_still_retries() {
    # The other half of the same measurement: the push is rejected AND the
    # target really does advance each time. That is the racing-pusher case the
    # retry bound exists for, so the lane must keep retrying and must exhaust
    # into status 6 — which now means what it says.
    local tmp got c1 c2 attempts
    tmp=$(mktemp -d)
    make_rig "$tmp"
    # Build the racing chain BEFORE the hook is armed, so pushing it does not
    # trip the hook. Both commits are fast-forwards of dev, so each update-ref
    # below is the advance a real racing pusher would produce.
    local racer="$tmp/racer" n
    git_q clone "$ORIGIN" "$racer"
    : >"$tmp/chain"
    # One racing commit per possible push attempt, so every rejection this test
    # provokes has a real advance behind it.
    for n in 1 2 3; do
        echo "bump $n" >>"$racer/overlay.txt"
        git_q -C "$racer" add overlay.txt
        git_q -C "$racer" commit -m "chore: racing bump $n"
        git -C "$racer" rev-parse HEAD >>"$tmp/chain"
    done
    c1=$(sed -n '1p' "$tmp/chain")
    c2=$(sed -n '2p' "$tmp/chain")
    git_q -C "$racer" push origin HEAD:refs/heads/racing

    # Reject the incoming push, but move dev on the way out: the rejection now
    # has a measurable cause, and re-rebasing is the way through it. A receive
    # hook runs inside git's object quarantine, which forbids ref updates, so
    # the racing advance has to step outside it.
    cat >"$ORIGIN/hooks/pre-receive" <<HOOK
#!/bin/sh
unset GIT_QUARANTINE_PATH GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES
n=\$(wc -l <"$tmp/push-attempts" 2>/dev/null || echo 0)
n=\$((n + 1))
echo x >>"$tmp/push-attempts"
racing=\$(sed -n "\${n}p" "$tmp/chain")
if [ -n "\$racing" ]; then
  git --git-dir="$ORIGIN" update-ref refs/heads/dev "\$racing"
fi
echo "push refused by the test (race \$n)" >&2
exit 1
HOOK
    chmod +x "$ORIGIN/hooks/pre-receive"

    got=$(run_merge 0 2>/dev/null)
    attempts=$(wc -l <"$tmp/push-attempts" | tr -d ' ')

    [ "$(status_of "$got")" = "6" ] ||
        fail "a rejected push against a target that kept moving returned $(status_of "$got"), want 6 (retries exhausted)"
    [ "$attempts" -gt 1 ] ||
        fail "a measurably racing target was pushed $attempts time(s), want more than 1 — the retry bound exists for this case"
    git --git-dir="$ORIGIN" merge-base --is-ancestor "$c1" "$(origin_tip)" ||
        fail "harness bug: dev should have been raced past $c1, found $(origin_tip)"
    [ "$(origin_tip)" != "$c1" ] || [ "$attempts" -lt 2 ] ||
        fail "harness bug: dev raced $attempts times but stopped at $c1, not $c2"
    rm -rf "$tmp"
}

test_push_carries_an_explicit_gate_wait_budget() {
    # The rig's pre-push gate (scripts/gate-slot-run) reads
    # PUSH_GATE_MAX_WAIT_SECONDS and defaults it to 0 — a non-blocking slot
    # acquire that vetoes the push whenever both lanes are busy. Running the
    # merge push under that ambient default is what turned a 28-minute slot
    # queue into a refused merge. The push must carry its own budget.
    local tmp got budget
    tmp=$(mktemp -d)
    make_rig "$tmp"
    mkdir -p "$WORK/.git/hooks"
    cat >"$WORK/.git/hooks/pre-push" <<HOOK
#!/bin/sh
printf '%s\n' "\${PUSH_GATE_MAX_WAIT_SECONDS-UNSET}" >>"$tmp/gate-budget"
exit 0
HOOK
    chmod +x "$WORK/.git/hooks/pre-push"

    got=$(run_merge 0 2>/dev/null)

    [ "$(status_of "$got")" = "0" ] ||
        fail "harness bug: the budget probe hook should not have blocked the merge (status $(status_of "$got"))"
    budget=$(sed -n '1p' "$tmp/gate-budget")
    [ -n "$budget" ] && [ "$budget" != "UNSET" ] ||
        fail "the merge push ran with PUSH_GATE_MAX_WAIT_SECONDS unset — it inherits the gate's non-blocking default (gcp-ileo)"
    [ "$budget" -gt 0 ] 2>/dev/null ||
        fail "the merge push ran with PUSH_GATE_MAX_WAIT_SECONDS=$budget; the refinery is a queue and must wait for a slot"
    rm -rf "$tmp"
}

test_block_does_not_rely_on_set_e() {
    # The abort path must be explicit. `set -e` inside the block would re-create
    # the dependency on shell-option inheritance that produced the false merge.
    grep -qE '^[[:space:]]*set[[:space:]]+-[a-z]*e' "$BLOCK" &&
        fail "the merge-ff-push block sets -e; the abort must be explicit (gcp-p87)"
    grep -q 'merge --ff-only' "$BLOCK" ||
        fail "the merge-ff-push block no longer performs an ff-only merge"
    grep -q 'is-ancestor' "$BLOCK" ||
        fail "the merge-ff-push block no longer asserts the target advanced by this branch"
    return 0
}

BLOCK=$(mktemp)
trap 'rm -f "$BLOCK"' EXIT
extract_block "$BLOCK"
export BLOCK

test_block_does_not_rely_on_set_e
test_clean_ff_lands_and_reports_the_branch_tip
test_lost_race_rerebases_and_lands_this_branch
test_failed_ff_with_conflicting_rebase_pushes_nothing
test_failed_ff_under_approval_parks_without_moving_the_branch
test_push_that_does_not_advance_the_target_is_refused
test_target_advanced_by_someone_else_is_refused
test_noop_ff_does_not_report_a_merge
test_vetoed_push_stops_without_retrying
test_rejected_push_with_a_moving_target_still_retries
test_push_carries_an_explicit_gate_wait_budget

if [ "$FAILURES" -ne 0 ]; then
    echo "refinery merge-push tests: $FAILURES failure(s)" >&2
    exit 1
fi
echo "refinery merge-push tests passed"
