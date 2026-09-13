#!/usr/bin/env bash
# Contract tests for mol-refinery-patrol's merge-state gate (gcp-a4e7).
#
# The gate has to separate three states that all present as "the rebase of this
# branch onto the target is empty":
#
#   1. the work ALREADY LANDED and the polecat crashed between `git push` and
#      `gc bd close` -> close the bead as merged;
#   2. the polecat produced nothing at all -> halt as a false completion;
#   3. the branch was merely rebased/reset onto newer target and never
#      introduced anything of its own (gcp-duy) -> also halt.
#
# Before the fix the gate had a single already-merged arm, `git merge-base
# --is-ancestor origin/$BRANCH origin/$TARGET`. That arm is unreachable on this
# lane: the merge script rebases `temp` onto the target and ff-merges, which
# rewrites the commit, so the pre-rebase branch sha is nowhere on the target
# afterwards. State 1 therefore fell through to the 0-diff guard and halted a
# genuinely merged bead to a human (live case winnow-zgr2y.6) -- exactly the
# outcome the already-merged arm exists to prevent.
#
# So state 1 is exercised here against a REBASING origin, which is the shape
# that reproduces the defect: a test that lands the branch by fast-forward goes
# green against the unfixed gate, because ancestry still holds there. The
# ancestor arm is kept under test too (a rig that ff-merges must still
# short-circuit), and states 2 and 3 pin the halts the content arm must not
# swallow.
#
# Nothing here asserts the fix by grepping. Both shipped blocks -- the helper
# group and the gate that calls it -- are extracted from the formula between
# their sentinels and EXECUTED against real git repositories, with a `gc` stub
# recording what the gate did to the bead. A regression shows up as "a merged
# bead was marked refused_false_completion" or "an empty branch was closed as
# merged", not as an absent string.
set -uo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
FORMULA="$ROOT/gastown/formulas/mol-refinery-patrol.toml"

FAILURES=0

fail() {
    echo "FAIL: $*" >&2
    FAILURES=$((FAILURES + 1))
}

# Extract one sentinel-delimited block of shipped formula text, substituting the
# formula's own [vars] defaults. Any `{{...}}` left over is a hard error rather
# than a block that executes a literal placeholder and passes vacuously.
extract_block() {
    python3 - "$FORMULA" "$1" "$2" <<'PY'
import re
import sys
import tomllib

formula, name, out = sys.argv[1:4]
begin = f"# --- {name}:begin ---"
end = f"# --- {name}:end ---"

with open(formula, "rb") as handle:
    doc = tomllib.load(handle)

blocks = [
    text.split(begin, 1)[1].split(end, 1)[0]
    for text in (step.get("description", "") for step in doc["steps"])
    if begin in text and end in text
]
if len(blocks) != 1:
    sys.exit(f"expected exactly one {name} block in {formula}, found {len(blocks)}")

block = blocks[0]
values = {n: spec.get("default", "") for n, spec in (doc.get("vars") or {}).items()}
block = re.sub(r"\{\{\s*(\w+)\s*\}\}", lambda m: values.get(m.group(1), m.group(0)), block)
leftover = re.findall(r"\{\{[^}]*\}\}", block)
if leftover:
    sys.exit(f"unsubstituted placeholders in {name}: {sorted(set(leftover))}")

with open(out, "w") as handle:
    handle.write(block)
PY
}

git_quiet() {
    git -c init.defaultBranch=integration \
        -c user.email=test@example.com \
        -c user.name="Contract Test" \
        -c advice.detachedHead=false \
        -c protocol.file.allow=always \
        "$@"
}

# A `gc` that answers exactly what the shipped blocks call. The `gc bd show
# --json` call serves the work bead's metadata (the gate reads `fork_sha` from
# it); every other call is recorded so a test can read back what the gate
# decided.
make_gc_stub() {
    local dir="$1"
    mkdir -p "$dir"
    cat > "$dir/gc" <<'STUB'
#!/usr/bin/env bash
printf 'gc %s\n' "$*" >> "${GC_STUB_LOG:?GC_STUB_LOG unset}"
case "gc $*" in
    *"gc bd show"*--json*) printf '[{"metadata":{"fork_sha":"%s"}}]\n' "${GC_STUB_FORK_SHA:-}" ;;
esac
exit 0
STUB
    chmod +x "$dir/gc"
}

# Build a rig at the moment merge-push runs: a bare origin holding the target
# and the polecat branch, and the refinery's clone with `temp` already rebased
# onto the target, which is what the `rebase` step leaves behind.
#
# $3 selects how the branch relates to the target:
#   landed_by_rebase  the work is on the target under a REWRITTEN sha (the
#                     crash-after-push case this bead is about)
#   landed_by_ff      the work is on the target under its own sha (ancestor arm)
#   unmerged          ordinary merge candidate, nothing on the target yet
#   empty_branch      the polecat committed nothing; tip is still the fork
#   rebased_no_change branch reset onto a commit that is another bead's work
build_rig() {
    local root="$1" branch="$2" shape="$3"
    ORIGIN="$root/origin.git"
    REFINERY="$root/refinery"
    mkdir -p "$root"
    git_quiet init --bare -q "$ORIGIN"

    git_quiet init -q "$root/seed"
    echo baseline > "$root/seed/README.md"
    git_quiet -C "$root/seed" add README.md
    git_quiet -C "$root/seed" commit -qm "chore: baseline"
    git_quiet -C "$root/seed" push -q "$ORIGIN" HEAD:integration
    FORK_SHA=$(git_quiet -C "$root/seed" rev-parse HEAD)

    # The polecat's branch.
    git_quiet clone -q --branch integration "$ORIGIN" "$root/polecat"
    git_quiet -C "$root/polecat" checkout -q -b "$branch"
    if [ "$shape" != "empty_branch" ]; then
        echo "the work this bead carried" > "$root/polecat/feature.txt"
        git_quiet -C "$root/polecat" add feature.txt
        git_quiet -C "$root/polecat" commit -qm "feat: the work this bead carried"
    fi

    case "$shape" in
        landed_by_rebase)
            # The refinery's own merge: rebase the branch onto the target and
            # ff-merge it. The commit that lands is a REWRITE -- same patch, new
            # sha -- so the branch is no longer an ancestor of the target.
            local lander="$root/lander"
            git_quiet clone -q --branch integration "$ORIGIN" "$lander"
            git_quiet -C "$lander" fetch -q "$root/polecat" "$branch:temp"
            git_quiet -C "$lander" checkout -q temp
            # A commit of its own first, so the rebase must rewrite rather than
            # fast-forward -- otherwise the landed sha equals the branch sha and
            # the ancestor arm would still fire.
            git_quiet -C "$lander" checkout -q integration
            echo "someone else" > "$lander/other.txt"
            git_quiet -C "$lander" add other.txt
            git_quiet -C "$lander" commit -qm "feat: a concurrent bead"
            git_quiet -C "$lander" checkout -q temp
            git_quiet -C "$lander" rebase -q integration
            git_quiet -C "$lander" checkout -q integration
            git_quiet -C "$lander" merge -q --ff-only temp
            LANDED_SHA=$(git_quiet -C "$lander" rev-parse HEAD)
            git_quiet -C "$lander" push -q origin integration
            ;;
        landed_by_ff)
            local lander="$root/lander"
            git_quiet clone -q --branch integration "$ORIGIN" "$lander"
            git_quiet -C "$lander" fetch -q "$root/polecat" "$branch:temp"
            git_quiet -C "$lander" merge -q --ff-only temp
            LANDED_SHA=$(git_quiet -C "$lander" rev-parse HEAD)
            git_quiet -C "$lander" push -q origin integration
            ;;
        rebased_no_change)
            # gcp-duy: another bead lands, and this branch is reset onto it. It
            # now has a non-empty diff against its own fork point, but every
            # commit it carries is already on the target and belongs elsewhere.
            local lander="$root/lander"
            git_quiet clone -q --branch integration "$ORIGIN" "$lander"
            echo "another bead's work" > "$lander/elsewhere.txt"
            git_quiet -C "$lander" add elsewhere.txt
            git_quiet -C "$lander" commit -qm "feat: a different bead entirely"
            git_quiet -C "$lander" push -q origin integration
            git_quiet -C "$root/polecat" fetch -q origin integration
            git_quiet -C "$root/polecat" reset -q --hard origin/integration
            ;;
    esac

    git_quiet -C "$root/polecat" push -q origin "$branch"

    git_quiet clone -q --branch integration "$ORIGIN" "$REFINERY"
    git_quiet -C "$REFINERY" fetch -q origin "$branch"
    git_quiet -C "$REFINERY" checkout -q -b temp "origin/$branch"
    # The `rebase` step ran before merge-push; reproduce its result, including
    # the "skipped previously applied commit" collapse to zero.
    git_quiet -C "$REFINERY" rebase -q origin/integration >/dev/null 2>&1 ||
        git_quiet -C "$REFINERY" rebase --abort >/dev/null 2>&1
}

# Execute the shipped helper group + gate against the refinery clone. Echoes the
# gate's exit status; the gc stub log holds what it did to the bead.
run_gate() {
    local branch="$1" fork="$2"
    (
        cd "$REFINERY" || exit 90
        export PATH="$STUBDIR:$PATH"
        export GC_STUB_LOG GC_STUB_FORK_SHA="$fork"
        # No `set -e`: the blocks must abort on their own explicit checks.
        # shellcheck disable=SC2034
        WORK=test-bead
        # shellcheck disable=SC2034
        BRANCH="$branch"
        # shellcheck disable=SC2034
        TARGET=integration
        # shellcheck disable=SC1090
        . "$HELPERS"
        # shellcheck disable=SC1090
        . "$GATE"
    ) >/dev/null 2>&1
}

logged() { grep -qF -- "$1" "$GC_STUB_LOG"; }

new_case() {
    TMP=$(mktemp -d)
    GC_STUB_LOG="$TMP/gc.log"
    : > "$GC_STUB_LOG"
    export GC_STUB_LOG
}

# --- tests ------------------------------------------------------------------

test_crash_after_a_rebasing_merge_closes_as_already_merged() {
    # The defect: the work IS on the target, under a rewritten sha, and the
    # rebase of the branch collapses to nothing. The old gate halted here.
    local status
    new_case
    build_rig "$TMP" polecat/test landed_by_rebase

    run_gate polecat/test "$FORK_SHA"
    status=$?

    [ "$status" -eq 0 ] ||
        fail "rebased already-merged branch exited $status, want 0 (close as merged, do not halt)"
    logged "gc bd close test-bead" ||
        fail "rebased already-merged branch never closed the bead — the merged work is stranded"
    logged "--set-metadata merge_result=already_merged" ||
        fail "rebased already-merged branch did not record merge_result=already_merged"
    logged "--set-metadata already_merged_via=rebase_patch_id" ||
        fail "rebased already-merged branch did not record how it was established"
    ! logged "merge_result=refused_false_completion" ||
        fail "rebased already-merged branch was halted as a false completion — the gcp-a4e7 defect"
    # merged_sha must name a commit that is actually ON the target. The
    # pre-rebase branch tip is not one, which is the whole reason this arm
    # cannot reuse the ancestor arm's sha.
    logged "--set-metadata merged_sha=$LANDED_SHA" ||
        fail "merged_sha does not name the commit on integration that carried the work ($LANDED_SHA)"
    rm -rf "$TMP"
}

test_fast_forward_merge_still_short_circuits_on_ancestry() {
    # A rig that lands by fast-forward keeps the cheaper arm; the content arm
    # must not have displaced it.
    local status
    new_case
    build_rig "$TMP" polecat/test landed_by_ff

    run_gate polecat/test "$FORK_SHA"
    status=$?

    [ "$status" -eq 0 ] ||
        fail "ff-merged branch exited $status, want 0"
    logged "--set-metadata already_merged_via=ancestor" ||
        fail "ff-merged branch did not take the ancestor arm"
    logged "--set-metadata merged_sha=$LANDED_SHA" ||
        fail "ff-merged branch recorded the wrong merged_sha"
    rm -rf "$TMP"
}

test_starved_zero_commit_branch_still_halts() {
    local status
    new_case
    build_rig "$TMP" polecat/test empty_branch

    run_gate polecat/test "$FORK_SHA"
    status=$?

    [ "$status" -ne 0 ] ||
        fail "empty branch exited 0 — a branch with no commits must halt, never close"
    logged "--set-metadata merge_result=refused_false_completion" ||
        fail "empty branch did not halt as a false completion"
    ! logged "gc bd close test-bead" ||
        fail "empty branch was closed as merged — the content arm swallowed a false completion"
    rm -rf "$TMP"
}

test_rebased_zero_change_branch_is_not_already_landed() {
    # gcp-duy's shape: the branch was reset onto newer target, so its "commits
    # since fork_sha" arrived via the rebase and belong to other beads.
    #
    # This is asserted against the predicate rather than the whole gate on
    # purpose. Such a branch tip IS on the target, so the ancestor arm reaches
    # it first and closes it — that false positive is gcp-duy's open defect on
    # the reachability axis, not this one's. What belongs here is the narrower
    # obligation this bead creates: the new content arm must not become a
    # SECOND way to reach the same wrong answer.
    local status
    new_case
    build_rig "$TMP" polecat/test rebased_no_change

    status=$(
        cd "$REFINERY" || exit 90
        # shellcheck disable=SC1090
        . "$HELPERS"
        branch_already_landed origin/integration origin/polecat/test "$FORK_SHA"
        printf '%s' "$?"
    )

    [ "$status" = "1" ] ||
        fail "branch_already_landed returned $status for a branch that introduced nothing of its own, want 1 (not already merged)"
    rm -rf "$TMP"
}

test_missing_fork_sha_stays_conservative() {
    # Without fork_sha neither arm can separate landed work from a starved
    # polecat, so the gate must fall through to the halt rather than guess.
    local status
    new_case
    build_rig "$TMP" polecat/test landed_by_rebase

    run_gate polecat/test ""
    status=$?

    [ "$status" -ne 0 ] ||
        fail "missing fork_sha exited 0 — the gate guessed instead of staying conservative"
    ! logged "merge_result=already_merged" ||
        fail "missing fork_sha closed the bead as merged with no fork point to judge against"
    rm -rf "$TMP"
}

test_unmerged_branch_falls_through_to_the_merge() {
    local status
    new_case
    build_rig "$TMP" polecat/test unmerged

    run_gate polecat/test "$FORK_SHA"
    status=$?

    [ "$status" -eq 0 ] ||
        fail "ordinary merge candidate exited $status, want 0 (fall through to the merge script)"
    ! logged "gc bd close test-bead" ||
        fail "ordinary merge candidate was closed by the gate instead of being merged"
    ! logged "merge_result=refused_false_completion" ||
        fail "ordinary merge candidate was halted as a false completion"
    rm -rf "$TMP"
}

HARNESS=$(mktemp -d)
trap 'rm -rf "$HARNESS"' EXIT
HELPERS="$HARNESS/helpers.sh"
GATE="$HARNESS/gate.sh"
STUBDIR="$HARNESS/bin"
extract_block merge-state-helpers "$HELPERS"
extract_block merge-state-gate "$GATE"
make_gc_stub "$STUBDIR"

test_crash_after_a_rebasing_merge_closes_as_already_merged
test_fast_forward_merge_still_short_circuits_on_ancestry
test_starved_zero_commit_branch_still_halts
test_rebased_zero_change_branch_is_not_already_landed
test_missing_fork_sha_stays_conservative
test_unmerged_branch_falls_through_to_the_merge

if [ "$FAILURES" -ne 0 ]; then
    echo "refinery already-merged gate tests: $FAILURES failure(s)" >&2
    exit 1
fi
echo "refinery already-merged gate tests passed"
