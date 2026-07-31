#!/usr/bin/env bash
# tests/test_fork_patch_guard.sh — regression tests for the fork's stale-patches
# guard (.githooks/pre-push + scripts/check-patches.sh).
#
# Usage: make test-patch-guard
#
# The guard only ever runs inside `git push`, so nothing in the normal test
# sweep touches it — it can rot silently, and the failure mode is invisible
# until a branch reaches the merge gate. These tests drive the real hook
# end-to-end: a scratch repo with a real bare remote, real `git push`, and the
# repo's actual Makefile and hook copied in.
#
# The regression this pins down: the hook once validated only pushes whose
# remote ref was refs/heads/integration, so a topic branch carrying an
# un-exported fork commit pushed clean and failed one review cycle later, at
# the integration push its author never performs.

set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

PASS=0
FAIL=0

fail() {
    echo "FAIL: $*" >&2
    FAIL=$((FAIL + 1))
}

pass() {
    echo "  ok: $*"
    PASS=$((PASS + 1))
}

SCRATCH=$(mktemp -d)
trap 'rm -rf "$SCRATCH"' EXIT

# ── Scratch fork ─────────────────────────────────────────────────────────────
# An upstream commit (the BASELINE), then the fork's patch-management commit on
# top of it, exported into patches/ exactly as the real integration branch is.

git init --quiet --bare "$SCRATCH/remote.git"
git init --quiet -b integration "$SCRATCH/work"
cd "$SCRATCH/work"

git config user.email "test@example.com"
git config user.name "Patch Guard Test"
git config commit.gpgsign false
git config tag.gpgSign false
git remote add origin "$SCRATCH/remote.git"

echo "upstream content" > upstream.txt
git add upstream.txt
git commit --quiet -m "upstream: baseline commit"

# Everything downstream keys off this SHA, including the hook's `make` run —
# export it so the Makefile's `BASELINE ?=` default is overridden there too.
export BASELINE
BASELINE=$(git rev-parse HEAD)

mkdir -p .githooks scripts tests
cp -f "$ROOT/Makefile" Makefile
cp -f "$ROOT/.githooks/pre-push" .githooks/pre-push
cp -f "$ROOT/scripts/check-patches.sh" scripts/check-patches.sh
chmod +x .githooks/pre-push scripts/check-patches.sh
git config core.hooksPath .githooks

git add Makefile .githooks scripts
git commit --quiet -m "chore(fork): add patch management system"
make -s patches >/dev/null
git add patches/
git commit --quiet --amend --no-edit

git push --quiet origin integration >/dev/null 2>&1 ||
    fail "baseline integration push should be accepted (fork tooling in sync)"

# ── A fork commit on a topic branch, not yet exported ────────────────────────

git switch --quiet -c polecat/scratch-1
echo "fork change" > fork.txt
git add fork.txt
git commit --quiet -m "feat: a fork commit whose export was forgotten"

test_stale_topic_branch_push_is_refused() {
    local out
    if out=$(git push origin polecat/scratch-1 2>&1); then
        fail "stale patches/ on a topic branch was accepted; hook did not fire"
        return
    fi
    case "$out" in
        *"patches/ is stale"*) pass "stale topic-branch push refused" ;;
        *) fail "topic-branch push failed for the wrong reason: $out" ;;
    esac
}

test_regenerated_but_uncommitted_export_is_still_refused() {
    # The push sends commits, not the working tree. An export regenerated on
    # disk but never committed is not what lands, so it must not satisfy the
    # guard — this is the difference between checking REV's tree and checking
    # whatever happens to be sitting in patches/.
    local out
    make -s patches >/dev/null
    if out=$(git push origin polecat/scratch-1 2>&1); then
        fail "uncommitted patches/ regeneration was accepted as in sync"
    else
        case "$out" in
            *"patches/ is stale"*) pass "uncommitted export still refused" ;;
            *) fail "push failed for the wrong reason: $out" ;;
        esac
    fi
    git checkout --quiet -- patches/ 2>/dev/null || true
    git clean --quiet -fd patches/ 2>/dev/null || true
}

test_exported_topic_branch_push_is_accepted() {
    local out
    make -s patches >/dev/null
    git add patches/
    git commit --quiet --amend --no-edit
    # A branch of its own: amending rewrote polecat/scratch-1, so reusing it
    # here would report non-fast-forward — an echo of an earlier test's push
    # rather than this one's verdict.
    git switch --quiet -c polecat/scratch-2
    if out=$(git push origin polecat/scratch-2 2>&1); then
        pass "topic-branch push accepted once the export is committed"
    else
        fail "in-sync topic-branch push was refused: $out"
    fi
}

test_branch_off_baseline_is_still_guarded() {
    # The original behaviour must survive: integration itself stays guarded.
    local out
    git switch --quiet integration
    echo "another fork change" > fork2.txt
    git add fork2.txt
    git commit --quiet -m "feat: unexported commit on integration"
    if out=$(git push origin integration 2>&1); then
        fail "stale patches/ on integration was accepted"
    else
        case "$out" in
            *"patches/ is stale"*) pass "integration push still refused when stale" ;;
            *) fail "integration push failed for the wrong reason: $out" ;;
        esac
    fi
    git reset --quiet --hard HEAD~1
}

test_branch_not_descending_from_baseline_is_skipped() {
    # An orphan branch shares no history with BASELINE, so BASELINE..HEAD would
    # export an unrelated stack. Nothing to enforce there — let it through.
    local out
    git checkout --quiet --orphan unrelated
    git rm --quiet -rf . >/dev/null 2>&1 || true
    echo "unrelated" > unrelated.txt
    git add unrelated.txt
    git commit --quiet -m "docs: unrelated history"
    if out=$(git push origin unrelated 2>&1); then
        pass "branch not descending from BASELINE pushed without enforcement"
    else
        fail "orphan branch push was refused: $out"
    fi
    git switch --quiet integration
}

test_tag_push_is_skipped() {
    local out
    git tag scratch-tag integration
    if out=$(git push origin scratch-tag 2>&1); then
        pass "tag push skipped by the guard"
    else
        fail "tag push was refused: $out"
    fi
}

test_branch_deletion_is_skipped() {
    local out
    if out=$(git push origin --delete unrelated 2>&1); then
        pass "branch deletion skipped by the guard"
    else
        fail "branch deletion was refused: $out"
    fi
}

test_stale_topic_branch_push_is_refused
test_regenerated_but_uncommitted_export_is_still_refused
test_exported_topic_branch_push_is_accepted
test_branch_off_baseline_is_still_guarded
test_branch_not_descending_from_baseline_is_skipped
test_tag_push_is_skipped
test_branch_deletion_is_skipped

echo ""
if [ "$FAIL" -ne 0 ]; then
    echo "test_fork_patch_guard: $PASS passed, $FAIL failed"
    exit 1
fi
echo "test_fork_patch_guard: $PASS passed"
