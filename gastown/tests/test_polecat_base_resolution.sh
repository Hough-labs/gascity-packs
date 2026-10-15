#!/usr/bin/env bash
# Executable reproduction of the pool-wide halt in gcp-19hoi.
#
# On 2026-10-13 every gascity-packs polecat halted at workspace-setup with
# halt_reason=base_branch_diverged. The rig root's LOCAL integration was a stale
# pre-restack ref: after the 10-10 force-push restack its old tip was not an
# ancestor of origin/integration, so the ancestry check STOPped — yet nothing was
# local-only (the old tip lives on origin/archive/integration-v0.4.0). The check
# fires on a merely STALE local copy, which is wider than its stated reason: "a
# base that has advanced only locally". Every future restack would strand the
# pool the same way.
#
# The base-resolution block now lives in gastown/assets/scripts/polecat-workspace.sh
# (its `base-resolve` mode, between the GUARD_BEGIN/GUARD_END base-resolve
# markers; gcp-xeael). These tests run that mode the way the formula step does:
# SOURCED into the polecat's shell, because BASE_REF has to land in the caller's
# shell for the blocks after it. Each case runs against a scratch bare origin
# plus clone, with a stubbed `gc` that logs its argv. Only case A changes with
# the fix; B, C and E pin the STOP that must survive, D the in-sync path.
#
#   A stale             local tip is not an ancestor of origin but is on a remote
#                       branch (archived)      -> proceed from origin
#   B stale_unarchived  same, but on no remote -> STOP
#   C ahead             local holds an unpushed commit -> STOP
#   D in_sync           local == origin        -> proceed
#   E revlist_error     the commit count itself fails -> STOP (fail closed)
#
# WORKSPACE_SCRIPT overrides the script under test, for a red-check against an older one.
# Assertions grep for literal shell snippets, so single-quoted `$VAR` is the point.
# shellcheck disable=SC2016
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
SCRIPT="${WORKSPACE_SCRIPT:-$ROOT/gastown/assets/scripts/polecat-workspace.sh}"
REAL_GIT=$(command -v git)

# A host global git config (tag signing, hooks path, templates) must not reach
# the scratch repos.
export GIT_CONFIG_GLOBAL=/dev/null
export GIT_CONFIG_SYSTEM=/dev/null
export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@example.invalid
export GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@example.invalid

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

# check_script confirms the script under test still carries exactly one
# base-resolution block, with the STOP that must survive, and no unrendered
# template variable: the formula step renders its {{...}} into the call's
# arguments, so the script must hold none. A drifted or deleted block fails here
# rather than passing against a stale copy.
check_script() {
    [[ "$(grep -c '^# GUARD_BEGIN base-resolve$' "$SCRIPT")" == 1 ]] ||
        fail "expected exactly one '# GUARD_BEGIN base-resolve' in $SCRIPT"
    [[ "$(grep -c '^# GUARD_END base-resolve$' "$SCRIPT")" == 1 ]] ||
        fail "expected exactly one '# GUARD_END base-resolve' in $SCRIPT"
    awk '/^# GUARD_BEGIN base-resolve$/{f=1} /^# GUARD_END base-resolve$/{f=0} f' "$SCRIPT" |
        grep -F 'halt_reason=base_branch_diverged' >/dev/null ||
        fail "the base-resolve block does not contain the diverged STOP"
    ! grep -F '{{' "$SCRIPT" >/dev/null || fail "$SCRIPT has an unrendered template variable"
    bash -n "$SCRIPT" || fail "$SCRIPT is not valid shell"
}

# write_gc_stub records every call; the block only writes, never reads.
write_gc_stub() {
    local bin="$1"
    mkdir -p "$bin"
    cat >"$bin/gc" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$GC_CALLS"
SH
    chmod +x "$bin/gc"
}

# write_git_wrapper makes `git rev-list` fail and passes everything else through.
write_git_wrapper() {
    local bin="$1"
    cat >"$bin/git" <<SH
#!/usr/bin/env bash
if [ "\${1-}" = rev-list ]; then
    echo "fatal: simulated rev-list failure" >&2
    exit 128
fi
exec "$REAL_GIT" "\$@"
SH
    chmod +x "$bin/git"
}

# commit <repo> <file> makes one commit that touches <file>.
commit() {
    local repo="$1" file="$2"
    echo "$file $RANDOM" >>"$repo/$file"
    "$REAL_GIT" -C "$repo" add "$file"
    "$REAL_GIT" -C "$repo" -c commit.gpgsign=false commit -q -m "$file"
}

# new_case builds a fresh scratch bare origin and clone with c1 <- c2 on
# integration, pushed, and the clone's local integration at c2. It prints the
# scratch dir; the clone is $dir/clone.
new_case() {
    local dir
    dir=$(mktemp -d)
    mkdir -p "$dir/bin"
    write_gc_stub "$dir/bin"
    check_script
    : >"$dir/calls.log"

    "$REAL_GIT" init -q --bare -b integration "$dir/origin.git"
    "$REAL_GIT" init -q -b integration "$dir/seed"
    commit "$dir/seed" c1
    commit "$dir/seed" c2
    "$REAL_GIT" -C "$dir/seed" remote add origin "$dir/origin.git"
    "$REAL_GIT" -C "$dir/seed" push -q origin integration
    "$REAL_GIT" clone -q "$dir/origin.git" "$dir/clone"
    printf '%s' "$dir"
}

# restack force-moves origin/integration to a commit that does not contain the
# old tip, then refreshes the clone the way `git fetch --prune origin` does at
# the top of workspace-setup. When <archive> is "archive" the old tip is first
# kept on a second remote branch, the way the restack archives it.
restack() {
    local dir="$1" archive="$2"
    if [[ "$archive" == archive ]]; then
        "$REAL_GIT" -C "$dir/seed" push -q origin integration:refs/heads/archive/integration
    fi
    "$REAL_GIT" -C "$dir/seed" checkout -q -B restacked integration~1
    commit "$dir/seed" n1
    "$REAL_GIT" -C "$dir/seed" push -q --force origin restacked:integration
    "$REAL_GIT" -C "$dir/clone" fetch -q --prune origin
}

# run_block sources the script's base-resolve mode with the inputs the formula
# step binds (the work bead from section 1, the rendered base branch and binding
# prefix), then echoes BASE_REF. A STOP exits before that line, so its absence
# is the assertion that the polecat never reached the work. Sets RC and OUT.
run_block() {
    local dir="$1" path_prefix="${2-$1/bin}"
    cat >"$dir/harness.sh" <<HARNESS
WORK_BEAD_ID="gcp-test1"
GC_RIG="gascity-packs"
. "$SCRIPT" base-resolve "\$WORK_BEAD_ID" integration gastown.
HARNESS
    echo 'echo "BASE_REF=$BASE_REF"' >>"$dir/harness.sh"

    set +e
    OUT=$(cd "$dir/clone" && GC_CALLS="$dir/calls.log" PATH="$path_prefix:$PATH" bash "$dir/harness.sh" 2>&1)
    RC=$?
    set -e
}

assert_halted() {
    local dir="$1" label="$2"
    [[ "$RC" == 1 ]] || fail "$label: expected exit 1 (STOP), got $RC: $OUT"
    grep -F 'halt_reason=base_branch_diverged' "$dir/calls.log" >/dev/null ||
        fail "$label: STOP did not stamp halt_reason=base_branch_diverged: $(cat "$dir/calls.log")"
    grep -F 'runtime drain-ack' "$dir/calls.log" >/dev/null ||
        fail "$label: STOP did not drain: $(cat "$dir/calls.log")"
    ! grep -F 'BASE_REF=' <<<"$OUT" >/dev/null ||
        fail "$label: halted but still fell through to the work: $OUT"
}

assert_branches_from_origin() {
    local dir="$1" label="$2"
    [[ "$RC" == 0 ]] || fail "$label: expected exit 0, got $RC: $OUT"
    grep -Fx 'BASE_REF=refs/remotes/origin/integration' <<<"$OUT" >/dev/null ||
        fail "$label: did not branch from origin: $OUT"
    ! grep -F 'halt_reason=base_branch_diverged' "$dir/calls.log" >/dev/null ||
        fail "$label: stamped a halt it should not have: $(cat "$dir/calls.log")"
    ! grep -F 'runtime drain-ack' "$dir/calls.log" >/dev/null ||
        fail "$label: drained although it proceeded: $(cat "$dir/calls.log")"
}

# A: the 2026-10-13 incident. Local integration is the pre-restack tip, which
# origin keeps on an archive branch; nothing is local-only.
test_case_A_stale() {
    local dir
    dir=$(new_case)
    restack "$dir" archive
    run_block "$dir"
    assert_branches_from_origin "$dir" "A stale"
    grep -F 'note: local integration is stale (0 commits off-remote); branching from origin' <<<"$OUT" >/dev/null ||
        fail "A stale: did not say why it proceeded: $OUT"
}

# B: stale too, but the old tip is on no remote branch (only a tag, or nothing).
# Branching from origin would orphan those commits, so this must still STOP.
test_case_B_stale_unarchived() {
    local dir
    dir=$(new_case)
    restack "$dir" no-archive
    run_block "$dir"
    assert_halted "$dir" "B stale_unarchived"
}

# C: local integration holds an unpushed commit: the original reason for the check.
test_case_C_ahead() {
    local dir
    dir=$(new_case)
    commit "$dir/clone" local-only
    run_block "$dir"
    assert_halted "$dir" "C ahead"
}

# D: in sync.
test_case_D_in_sync() {
    local dir
    dir=$(new_case)
    run_block "$dir"
    assert_branches_from_origin "$dir" "D in_sync"
}

# E: case A's repo, but the commit count itself fails. An answer nobody verified
# is not proof that nothing is local-only, so the block must fail closed.
test_case_E_revlist_error() {
    local dir
    dir=$(new_case)
    restack "$dir" archive
    write_git_wrapper "$dir/bin"
    run_block "$dir"
    assert_halted "$dir" "E revlist_error"
}

test_case_A_stale
test_case_B_stale_unarchived
test_case_C_ahead
test_case_D_in_sync
test_case_E_revlist_error

echo "polecat base-resolution tests passed"
