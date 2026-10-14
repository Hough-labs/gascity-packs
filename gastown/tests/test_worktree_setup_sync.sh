#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
SCRIPT="$ROOT/gastown/assets/scripts/worktree-setup.sh"

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

git_c() {
    git -c user.email=a@a.com -c user.name=a "$@"
}

# new_upstream_and_rig — a bare "upstream" repo plus a rig clone of it, with
# one commit on main and origin/HEAD already configured (the common case:
# the rig was cloned from an origin that already existed).
new_upstream_and_rig() {
    local base="$1"
    git_c init -q --bare -b main "$base/upstream.git"
    git_c init -q -b main "$base/seed"
    (cd "$base/seed" && git_c commit -q --allow-empty -m init \
        && git_c remote add origin "$base/upstream.git" \
        && git_c push -q origin main)
    git_c clone -q "$base/upstream.git" "$base/rig"
}

# stable_branch — the branch worktree-setup.sh gives the worktree at <wt> for
# <agent> (its branch_name()). --sync keeps exactly this branch current with
# origin/HEAD, so the tests check it out to exercise the sync of the
# worktree's own branch.
stable_branch() {
    local rig="$1" wt="$2" agent="$3" hash
    hash=$(printf '%s' "$wt" | git_c -C "$rig" hash-object --stdin | cut -c1-12)
    printf 'gc-%s-%s' "$agent" "$hash"
}

test_sync_pulls_when_branch_lacks_origin_tracking() {
    local base="$1"
    local rig="$base/rig" wt="$base/wt-notrack"
    local branch
    branch=$(stable_branch "$rig" "$wt" notrack)

    # Build #299's precondition by hand, not through the script: the branch
    # the no-start-point fallback creates (the path taken when origin/HEAD
    # isn't configured at creation time -- e.g. a rig set up locally and
    # given a remote afterwards) has no branch.<name>.remote/.merge config.
    # --no-track pins that state even when the developer's
    # branch.autoSetupMerge (always, inherit) would track the start point.
    git_c -C "$rig" worktree add -q --no-track "$wt" -b "$branch"
    if git_c -C "$wt" rev-parse --abbrev-ref --symbolic-full-name '@{u}' >/dev/null 2>&1; then
        fail "test setup bug: $branch must have no upstream tracking configured"
    fi

    # origin's default branch has since moved ahead of the worktree -- the
    # exact "we hit this in production" scenario from the issue, where a
    # frozen worktree fell 31 commits behind main.
    (cd "$base" && git_c clone -q "$base/upstream.git" advance \
        && cd advance \
        && git_c commit -q --allow-empty -m "advanced upstream" \
        && git_c push -q origin main)
    local advanced_sha
    advanced_sha=$(git_c -C "$base/advance" rev-parse main)

    sh "$SCRIPT" "$rig" "$wt" notrack --sync

    local wt_sha
    wt_sha=$(git_c -C "$wt" rev-parse HEAD)
    [ "$wt_sha" = "$advanced_sha" ] ||
        fail "sync should have pulled the advanced commit despite missing tracking config; want $advanced_sha got $wt_sha"
    # Still on its own branch: stable_branch() matched the script's name, so
    # this exercised the fast-forward rather than a fresh branch at origin/HEAD.
    [ "$(git_c -C "$wt" branch --show-current)" = "$branch" ] ||
        fail "sync should have kept the worktree on $branch"
}

test_sync_still_works_with_configured_tracking() {
    local base="$1"
    local rig="$base/rig" wt="$base/wt-tracked"
    local branch
    branch=$(stable_branch "$rig" "$wt" tracked)

    # The already-working case: a branch created from an explicit
    # origin-tracking start point (the DEFAULT_REF path this script's own
    # creation logic normally takes) gets real tracking config under git's
    # default branch.autoSetupMerge; --track pins it even when the
    # developer's setting (false, simple) would not. sync_worktree never
    # reads tracking config, so this guards that configured tracking is
    # harmless to the sync rather than exercising a separate path.
    git_c -C "$rig" worktree add -q --track "$wt" -b "$branch" refs/remotes/origin/main
    if ! git_c -C "$wt" rev-parse --abbrev-ref --symbolic-full-name '@{u}' >/dev/null 2>&1; then
        fail "test setup bug: $branch must have upstream tracking configured"
    fi

    (cd "$base" && git_c clone -q "$base/upstream.git" advance2 \
        && cd advance2 \
        && git_c commit -q --allow-empty -m "advanced tracked" \
        && git_c push -q origin main)
    local advanced_sha
    advanced_sha=$(git_c -C "$base/advance2" rev-parse main)

    sh "$SCRIPT" "$rig" "$wt" tracked --sync

    local wt_sha
    wt_sha=$(git_c -C "$wt" rev-parse HEAD)
    [ "$wt_sha" = "$advanced_sha" ] ||
        fail "sync should still pull for a normally-tracked branch; want $advanced_sha got $wt_sha"
    [ "$(git_c -C "$wt" branch --show-current)" = "$branch" ] ||
        fail "sync should have kept the worktree on $branch"
}

# new_split_rig <dir> — a bare upstream whose HEAD is main, with three
# branches: main = init, integration = init + one commit, archive = init + one
# other commit. The rig is cloned from it, so origin/HEAD = main while the
# rig's configured default_branch (what gc passes as --default-branch) is a
# different branch -- the disagreement worktree-setup.sh used to resolve by
# guessing from origin/HEAD.
new_split_rig() {
    local base="$1"
    mkdir -p "$base"
    git_c init -q --bare -b main "$base/upstream.git"
    git_c init -q -b main "$base/seed"
    (cd "$base/seed" \
        && git_c remote add origin "$base/upstream.git" \
        && git_c commit -q --allow-empty -m init \
        && git_c push -q origin main \
        && git_c checkout -q -b integration \
        && git_c commit -q --allow-empty -m "integration work" \
        && git_c push -q origin integration \
        && git_c checkout -q -b archive main \
        && git_c commit -q --allow-empty -m "archive work" \
        && git_c push -q origin archive)
    git_c clone -q "$base/upstream.git" "$base/rig"
}

# ref_sha <repo> <ref> — the commit a ref names.
ref_sha() {
    git_c -C "$1" rev-parse --verify "$2^{commit}"
}

# setup_run <rig> <wt> <err-file> <args...> — run the script as the pre_start
# does, with the agent name fixed to "a". Prints nothing, leaves stderr in
# <err-file>, and returns the script's exit status.
setup_run() {
    local rig="$1" wt="$2" err="$3"
    shift 3
    sh "$SCRIPT" "$rig" "$wt" a "$@" 2>"$err"
}

test_worktree_start_point_prefers_rig_default_branch() {
    local base="$1/${FUNCNAME[0]}"
    new_split_rig "$base"
    local rig="$base/rig" wt="$base/wt" err="$base/err"
    local branch merge
    branch=$(stable_branch "$rig" "$wt" a)

    # No --sync: this is the create site alone.
    setup_run "$rig" "$wt" "$err" --default-branch integration ||
        fail "create with --default-branch integration failed: $(cat "$err")"

    [ "$(ref_sha "$wt" HEAD)" = "$(ref_sha "$rig" refs/remotes/origin/integration)" ] ||
        fail "worktree should be cut from origin/integration, not origin/HEAD (main); got $(ref_sha "$wt" HEAD)"
    merge=$(git_c -C "$rig" config --get "branch.$branch.merge" || true)
    case "$merge" in
        '' | refs/heads/integration) ;;
        *) fail "$branch must not track a mainline other than integration; merge=$merge" ;;
    esac
}

test_sync_moves_a_mis_cut_branch_to_rig_default_branch() {
    local base="$1/${FUNCNAME[0]}"
    new_split_rig "$base"
    local rig="$base/rig" wt="$base/wt" err="$base/err"
    local branch
    branch=$(stable_branch "$rig" "$wt" a)

    # A branch cut from origin/HEAD before the rig's default_branch was passed.
    git_c -C "$rig" worktree add -q --no-track "$wt" -b "$branch" refs/remotes/origin/main

    setup_run "$rig" "$wt" "$err" --sync --default-branch integration ||
        fail "sync with --default-branch integration failed: $(cat "$err")"

    [ "$(ref_sha "$wt" HEAD)" = "$(ref_sha "$rig" refs/remotes/origin/integration)" ] ||
        fail "sync should move the mis-cut branch to origin/integration; got $(ref_sha "$wt" HEAD)"
    [ "$(git_c -C "$wt" branch --show-current)" = "$branch" ] ||
        fail "sync should have kept the worktree on $branch"
}

test_disagreement_emits_a_diagnostic() {
    local base="$1/${FUNCNAME[0]}"
    new_split_rig "$base"
    local rig="$base/rig" wt="$base/wt" err="$base/err"
    local line='worktree-setup: rig default_branch integration differs from origin/HEAD (main); using integration'

    setup_run "$rig" "$wt" "$err" --sync --default-branch integration ||
        fail "setup failed: $(cat "$err")"

    # The create site and the sync site both run, but the guard prints it once.
    [ "$(grep -cxF "$line" "$err")" = 1 ] ||
        fail "the disagreement line should appear exactly once; stderr was: $(cat "$err")"
}

test_agreeing_rig_is_unchanged_and_quiet() {
    local base="$1/${FUNCNAME[0]}"
    new_split_rig "$base"
    local rig="$base/rig" wt="$base/wt" err="$base/err"

    setup_run "$rig" "$wt" "$err" --sync --default-branch main ||
        fail "setup with an agreeing default_branch failed: $(cat "$err")"

    [ "$(ref_sha "$wt" HEAD)" = "$(ref_sha "$rig" refs/remotes/origin/main)" ] ||
        fail "an agreeing rig should still be cut from origin/main; got $(ref_sha "$wt" HEAD)"
    if grep -q 'differs from origin/HEAD' "$err"; then
        fail "an agreeing rig must not print the disagreement line: $(cat "$err")"
    fi
}

test_origin_head_is_only_a_fallback() {
    local base="$1/${FUNCNAME[0]}"
    new_split_rig "$base"
    local rig="$base/rig" err="$base/err"
    local wt label

    # Four ways gc can hand over "no default_branch": nothing, an empty value,
    # a value an older gc left unrendered, and a flag with no value.
    for label in none empty unrendered bare; do
        wt="$base/wt-$label"
        case "$label" in
            none) setup_run "$rig" "$wt" "$err" --sync ;;
            empty) setup_run "$rig" "$wt" "$err" --sync --default-branch '' ;;
            unrendered) setup_run "$rig" "$wt" "$err" --sync --default-branch '{{.DefaultBranch}}' ;;
            bare) setup_run "$rig" "$wt" "$err" --sync --default-branch ;;
        esac || fail "$label: should fall back to origin/HEAD, but exited non-zero: $(cat "$err")"
        [ "$(ref_sha "$wt" HEAD)" = "$(ref_sha "$rig" refs/remotes/origin/main)" ] ||
            fail "$label: should be cut from origin/HEAD (main); got $(ref_sha "$wt" HEAD)"
    done
}

test_local_only_default_branch_is_used() {
    local base="$1/${FUNCNAME[0]}"
    new_split_rig "$base"
    local rig="$base/rig" wt="$base/wt" err="$base/err"
    local edge

    # A rig default_branch that was never pushed.
    edge=$(git_c -C "$rig" commit-tree -p refs/remotes/origin/main -m edge 'refs/remotes/origin/main^{tree}')
    git_c -C "$rig" update-ref refs/heads/edge "$edge"

    setup_run "$rig" "$wt" "$err" --sync --default-branch edge ||
        fail "a local-only default_branch should still resolve: $(cat "$err")"

    [ "$(ref_sha "$wt" HEAD)" = "$edge" ] ||
        fail "worktree should sit on the local-only edge ($edge); got $(ref_sha "$wt" HEAD)"
    grep -qxF 'worktree-setup: note: base branch edge is local-only — it does not exist on origin' "$err" ||
        fail "expected the local-only note; stderr was: $(cat "$err")"
}

test_missing_default_branch_stops_without_substituting() {
    local base="$1/${FUNCNAME[0]}"
    new_split_rig "$base"
    local rig="$base/rig" wt="$base/wt" err="$base/err"
    local branch rc=0
    branch=$(stable_branch "$rig" "$wt" a)

    setup_run "$rig" "$wt" "$err" --sync --default-branch nope || rc=$?

    [ "$rc" = 1 ] || fail "a default_branch that exists nowhere should exit 1; got $rc"
    grep -qxF "worktree-setup: STOP: base branch nope exists neither on origin nor locally in $rig; not substituting origin/HEAD" "$err" ||
        fail "expected the STOP line; stderr was: $(cat "$err")"
    if git_c -C "$rig" show-ref --verify --quiet "refs/heads/$branch"; then
        fail "no branch should be created when the base cannot be resolved"
    fi
}

test_stale_local_default_branch_branches_from_origin() {
    local base="$1/${FUNCNAME[0]}"
    new_split_rig "$base"
    local rig="$base/rig" wt="$base/wt" err="$base/err"

    # A local integration that is not an ancestor of origin's, yet holds nothing
    # that no remote branch has: archive's tip is on origin/archive.
    git_c -C "$rig" branch integration refs/remotes/origin/archive

    setup_run "$rig" "$wt" "$err" --sync --default-branch integration ||
        fail "a stale local default_branch should not halt: $(cat "$err")"

    [ "$(ref_sha "$wt" HEAD)" = "$(ref_sha "$rig" refs/remotes/origin/integration)" ] ||
        fail "worktree should be cut from origin/integration; got $(ref_sha "$wt" HEAD)"
    grep -qxF 'worktree-setup: note: local integration is stale (0 commits off-remote); branching from origin' "$err" ||
        fail "expected the stale note; stderr was: $(cat "$err")"
}

test_local_only_commits_on_default_branch_stop() {
    local base="$1/${FUNCNAME[0]}"
    new_split_rig "$base"
    local rig="$base/rig" wt="$base/wt" err="$base/err"
    local ahead rc=0

    # origin/integration plus one commit that no remote has.
    ahead=$(git_c -C "$rig" commit-tree -p refs/remotes/origin/integration -m unpushed 'refs/remotes/origin/integration^{tree}')
    git_c -C "$rig" update-ref refs/heads/integration "$ahead"

    setup_run "$rig" "$wt" "$err" --sync --default-branch integration || rc=$?

    [ "$rc" = 1 ] || fail "local-only commits on the default branch should exit 1; got $rc"
    grep -qxF 'worktree-setup: STOP: local integration has commits that are on no remote; reconcile or push it first' "$err" ||
        fail "expected the local-only-commits STOP line; stderr was: $(cat "$err")"
}

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
new_upstream_and_rig "$tmp"

test_sync_pulls_when_branch_lacks_origin_tracking "$tmp"
test_sync_still_works_with_configured_tracking "$tmp"

test_worktree_start_point_prefers_rig_default_branch "$tmp"
test_sync_moves_a_mis_cut_branch_to_rig_default_branch "$tmp"
test_disagreement_emits_a_diagnostic "$tmp"
test_agreeing_rig_is_unchanged_and_quiet "$tmp"
test_origin_head_is_only_a_fallback "$tmp"
test_local_only_default_branch_is_used "$tmp"
test_missing_default_branch_stops_without_substituting "$tmp"
test_stale_local_default_branch_branches_from_origin "$tmp"
test_local_only_commits_on_default_branch_stop "$tmp"

echo "worktree-setup sync tests passed"
