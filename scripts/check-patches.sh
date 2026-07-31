#!/usr/bin/env bash
# scripts/check-patches.sh — verify patches/ matches the BASELINE..REV divergence.
#
# Usage: make check-patches [REV=<commit-ish>]
#        (the Makefile passes BASELINE and REV in via the environment)
#
# patches/ is a DERIVED artifact — the `git format-patch BASELINE..REV` export
# of the fork's divergence, excluding patches/ itself. This is the authoritative
# check that the export has not drifted from the commits it claims to describe.
#
# REV is validated as a COMMIT, not as the working tree: `patches/` is read out
# of REV's tree, never off disk. A regenerated-but-uncommitted export is not
# what a push sends, so counting it would let exactly the drift this guards
# against through. REV defaults to HEAD; the pre-push hook passes the SHA git is
# about to send, so the commit validated is the commit that lands.
#
# Exits 0 when the export is in sync, or when REV does not descend from BASELINE
# (a branch off pure upstream carries no fork divergence to export). Exits 1 on
# drift, with the regeneration command to run.

set -euo pipefail

# BASELINE is normally injected by `make check-patches`; keep a default so the
# script is runnable standalone. Must match the Makefile's BASELINE.
BASELINE="${BASELINE:-f69ec02b39e04b1febc3ced4c47fd4972f706e91}"
REV="${REV:-HEAD}"

stale() {
    echo "patches/ is stale: $*"
    echo "  Run: make patches && git add patches && git commit"
    exit 1
}

SHA=$(git rev-parse --quiet --verify "$REV^{commit}") ||
    { echo "check-patches: $REV is not a commit" >&2; exit 1; }

git rev-parse --quiet --verify "$BASELINE^{commit}" >/dev/null 2>&1 ||
    { echo "check-patches: BASELINE $BASELINE not found locally" >&2; exit 1; }

# A ref that does not descend from BASELINE is not carrying the fork's patch
# stack — an upstream-only topic branch, say. `BASELINE..REV` there would export
# an unrelated history and fail for a reason the author cannot act on.
if ! git merge-base --is-ancestor "$BASELINE" "$SHA"; then
    echo "patches/ not checked: $REV does not descend from BASELINE $(git rev-parse --short "$BASELINE")"
    exit 0
fi

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

git format-patch --zero-commit "$BASELINE..$SHA" --output-directory "$tmp" -- . ':!patches/' >/dev/null 2>&1

expected=$(find "$tmp" -maxdepth 1 -name '*.patch' | wc -l | tr -d ' ')
actual=$(git ls-tree -r --name-only "$SHA" -- patches/ | grep -c '\.patch$' || true)

if [ "$expected" != "$actual" ]; then
    stale "$actual present, $expected expected."
fi

for f in "$tmp"/*.patch; do
    [ -e "$f" ] || continue
    b=$(basename "$f")
    git cat-file -e "$SHA:patches/$b" 2>/dev/null || stale "missing $b."
    # Skip the `From <sha> ...` header line on both sides before comparing: it
    # is the one line format-patch derives from the commit rather than from its
    # content, and the committed export was generated on a different invocation.
    git cat-file blob "$SHA:patches/$b" | tail -n +2 > "$tmp/.committed"
    tail -n +2 "$f"                                > "$tmp/.regen"
    cmp -s "$tmp/.committed" "$tmp/.regen" || stale "content drift in $b."
done

echo "patches/ up to date ($actual patches)"
