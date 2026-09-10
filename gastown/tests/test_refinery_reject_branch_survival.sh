#!/usr/bin/env bash
# Contract tests for the reject -> resume round trip (gcp-afgi).
#
# `mol-refinery-patrol` handle-failures used to end its branch-caused rejection
# with `git push origin --delete $BRANCH`, while the consumer of that rejection,
# `mol-polecat-work` workspace-setup, is written to RESUME from exactly that
# branch: it reads `metadata.branch`, treats it as authoritative, and fetches
# the named remote ref. The rejection update never unsets `metadata.branch`, so
# the refinery returned a bead to the pool still naming a branch it had just
# destroyed.
#
# The result is not a silent fresh start. It is a bricked bead: with the remote
# ref gone and no local ref -- that one lived in the PREVIOUS polecat's worktree
# -- the resume falls to `STOP. Do not create a different branch.` and
# drain-acks, so every polecat that claims the bead exits on sight until a human
# clears the metadata by hand.
#
# The same-worktree re-claim is what hides it: that worktree still holds
# `refs/heads/$BRANCH`, so the resume succeeds through the local-ref fallback
# and silently re-pushes the deleted remote. A test that re-claims in the same
# worktree therefore goes GREEN against the unfixed code. These tests resume
# from a DIFFERENT clone, which is the only shape that reproduces the deadlock.
#
# Nothing here asserts the fix by grepping for the absent command alone -- an
# absent string proves nothing about what the refinery does to the remote. The
# shipped block is extracted from the formula between its sentinels and EXECUTED
# against a real bare origin, then a second clone executes the shipped polecat
# resolution block against that same origin. A regression shows up as "the
# rejected branch is gone from origin" and "the resuming clone halted", not as a
# queue of beads that drain-ack on sight.
set -uo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
REFINERY_FORMULA="$ROOT/gastown/formulas/mol-refinery-patrol.toml"
POLECAT_FORMULA="$ROOT/gastown/formulas/mol-polecat-work.toml"

FAILURES=0

fail() {
    echo "FAIL: $*" >&2
    FAILURES=$((FAILURES + 1))
}

WORKDIR=$(mktemp -d)
trap 'rm -rf "$WORKDIR"' EXIT

# Extract one sentinel-delimited block of shipped formula text.
#
# Placeholders are substituted from the formula's own [vars] defaults, and any
# `{{...}}` left over afterwards is a hard error: an edit that reaches for a var
# this harness cannot supply must fail here rather than execute a block with a
# literal "{{...}}" in it and pass vacuously.
#
# Usage: extract_block <formula> <block-name> <outfile>
extract_block() {
    python3 - "$1" "$2" "$3" <<'PY'
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

# A `gc` that answers only what the shipped blocks actually call: the failure
# paths' `gc runtime drain-ack`. It records the call so a test can tell "the
# block halted" from "the block never reached its halt".
make_gc_stub() {
    local dir="$1"
    mkdir -p "$dir"
    cat > "$dir/gc" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${GC_STUB_LOG:?GC_STUB_LOG unset}"
exit 0
STUB
    chmod +x "$dir/gc"
}

git_quiet() {
    git -c init.defaultBranch=integration \
        -c user.email=test@example.com \
        -c user.name="Contract Test" \
        -c advice.detachedHead=false \
        "$@"
}

# Build a bare origin holding `integration` plus a pushed polecat branch that
# carries one commit of real work, and leave the refinery standing in its own
# clone at the shape handle-failures reaches: `temp` checked out from
# origin/$BRANCH. Echoes the fixture root.
build_fixture() {
    local root="$1" branch="$2"
    mkdir -p "$root"
    git_quiet init --bare -q "$root/origin.git"

    git_quiet init -q "$root/seed"
    echo "baseline" > "$root/seed/README.md"
    git_quiet -C "$root/seed" add README.md
    git_quiet -C "$root/seed" commit -qm "seed"
    git_quiet -C "$root/seed" push -q "$root/origin.git" HEAD:integration

    # The resuming worktree is cloned HERE, before the branch is pushed: an
    # ordinary clone with the default refspec that simply has not seen this
    # branch yet. That is what a polecat worktree actually is, and it is the
    # only faithful model of the deadlock -- a --single-branch clone would also
    # lack the ref, but it lacks the refspec too, so `checkout --track` fails
    # there for a reason production never hits.
    git_quiet clone -q --branch integration "$root/origin.git" "$root/resumer"

    # Polecat A: the worktree that created the branch and pushed it.
    git_quiet clone -q --branch integration "$root/origin.git" "$root/polecat-a"
    git_quiet -C "$root/polecat-a" checkout -q -b "$branch"
    echo "the work that must survive rejection" > "$root/polecat-a/feature.txt"
    git_quiet -C "$root/polecat-a" add feature.txt
    git_quiet -C "$root/polecat-a" commit -qm "feat: the work under test"
    git_quiet -C "$root/polecat-a" push -q origin "$branch"

    # The refinery's own clone, at the point handle-failures runs.
    git_quiet clone -q --branch integration "$root/origin.git" "$root/refinery"
    git_quiet -C "$root/refinery" fetch -q origin "$branch"
    git_quiet -C "$root/refinery" checkout -q -b temp "origin/$branch"
}

# ---------------------------------------------------------------------------
# 1. The round trip: a branch-caused rejection leaves the branch on origin, and
#    a polecat worktree that has never seen it resumes from it.
# ---------------------------------------------------------------------------
test_reject_then_resume_from_a_different_worktree() {
    local root="$WORKDIR/roundtrip" branch="polecat/gcp-fixture"
    build_fixture "$root" "$branch"

    local reject_block="$WORKDIR/reject-block.sh"
    extract_block "$REFINERY_FORMULA" reject-branch-disposition "$reject_block" || {
        fail "could not extract reject-branch-disposition from mol-refinery-patrol"
        return
    }

    local stub_dir="$root/bin"
    make_gc_stub "$stub_dir"
    local log="$root/gc-calls.log"
    : > "$log"

    local reject_out
    reject_out=$(cd "$root/refinery" && \
        PATH="$stub_dir:$PATH" GC_STUB_LOG="$log" \
        TARGET=integration BRANCH="$branch" \
        bash "$reject_block" 2>&1)
    local reject_code=$?
    if [ "$reject_code" -ne 0 ]; then
        fail "shipped rejection block exited $reject_code: $reject_out"
    fi

    if [ -z "$(git_quiet ls-remote "$root/origin.git" "refs/heads/$branch")" ]; then
        fail "the rejection deleted $branch from origin; the bead it returned to the pool still names that branch, so every polecat that claims it will halt"
        return
    fi

    # The resumer was cloned before the push, so the shipped block's own fetch
    # is its only path to the ref -- exactly the step that fails when the
    # rejection deleted the remote branch.
    if git_quiet -C "$root/resumer" show-ref --verify --quiet "refs/remotes/origin/$branch"; then
        fail "fixture error: the resumer already knows origin/$branch, so it does not model a different worktree"
        return
    fi

    local resolve_block="$WORKDIR/resolve-block.sh"
    extract_block "$POLECAT_FORMULA" branch-resolution "$resolve_block" || {
        fail "could not extract branch-resolution from mol-polecat-work"
        return
    }

    local resume_out
    resume_out=$(cd "$root/resumer" && \
        PATH="$stub_dir:$PATH" GC_STUB_LOG="$log" \
        BRANCH="$branch" \
        bash "$resolve_block" 2>&1)
    local resume_code=$?
    if [ "$resume_code" -ne 0 ]; then
        fail "the resuming polecat halted (exit $resume_code) instead of picking the rejected branch back up: $resume_out"
        return
    fi

    local head
    head=$(git_quiet -C "$root/resumer" rev-parse --abbrev-ref HEAD)
    if [ "$head" != "$branch" ]; then
        fail "resuming polecat landed on '$head', expected '$branch'"
    fi
    if [ ! -f "$root/resumer/feature.txt" ]; then
        fail "resuming polecat checked out $branch but the rejected commit's work is missing"
    fi
    if grep -q 'drain-ack' "$log"; then
        fail "the resuming polecat drain-acked; it took a halt path rather than resuming"
    fi
}

# ---------------------------------------------------------------------------
# 2. The resolution block still HALTS on a branch that genuinely does not
#    exist. Without this, test 1 could go green against a polecat side that had
#    been "fixed" by making it invent a branch instead -- which would strand the
#    rejected work just as thoroughly, and silently.
# ---------------------------------------------------------------------------
test_resolution_still_halts_on_a_missing_branch() {
    local root="$WORKDIR/missing" branch="polecat/gcp-fixture"
    build_fixture "$root" "$branch"

    local stub_dir="$root/bin"
    make_gc_stub "$stub_dir"
    local log="$root/gc-calls.log"
    : > "$log"

    local resolve_block="$WORKDIR/resolve-block.sh"
    extract_block "$POLECAT_FORMULA" branch-resolution "$resolve_block" || {
        fail "could not extract branch-resolution from mol-polecat-work"
        return
    }

    git_quiet clone -q --branch integration "$root/origin.git" "$root/polecat-c"

    local out
    out=$(cd "$root/polecat-c" && \
        PATH="$stub_dir:$PATH" GC_STUB_LOG="$log" \
        BRANCH="polecat/never-existed" \
        bash "$resolve_block" 2>&1)
    local code=$?

    if [ "$code" -eq 0 ]; then
        fail "branch-resolution accepted a branch that exists nowhere; it must halt rather than invent one"
    fi
    case "$out" in
        *"STOP. Do not create a different branch."*) ;;
        *) fail "branch-resolution halted without the STOP message; got: $out" ;;
    esac
    if ! grep -q 'runtime drain-ack' "$log"; then
        fail "branch-resolution halted without drain-acking, so the session would idle instead of releasing its slot"
    fi
}

# ---------------------------------------------------------------------------
# 3. Structural: no branch deletion anywhere on the rejection route, and the
#    merged path's deletion is untouched. Test 1 only executes the sentinelled
#    block; a `git push origin --delete` re-added elsewhere in handle-failures
#    would sail past it.
# ---------------------------------------------------------------------------
test_branch_deletion_lives_only_on_the_merged_path() {
    python3 - "$REFINERY_FORMULA" <<'PY'
import sys
import tomllib

formula = sys.argv[1]
with open(formula, "rb") as handle:
    doc = tomllib.load(handle)

problems = []
steps = {step["id"]: step.get("description", "") for step in doc["steps"]}

for step_id in ("handle-failures", "rebase-branch"):
    text = steps.get(step_id)
    if text is None:
        continue
    if "push origin --delete" in text:
        problems.append(
            f"{step_id} deletes a branch: the rejection route returns the bead to the "
            "pool with metadata.branch still set, and mol-polecat-work resumes from it"
        )

merged = [sid for sid, text in steps.items() if "push origin --delete" in text]
if not merged:
    problems.append(
        "no branch deletion left anywhere; the merged path must still honour "
        "delete_merged_branches"
    )
for sid in merged:
    if "delete_merged_branches" not in steps[sid]:
        problems.append(f"{sid} deletes a branch without gating on delete_merged_branches")

if problems:
    for problem in problems:
        print(f"FAIL: {problem}", file=sys.stderr)
    sys.exit(1)
PY
    [ $? -eq 0 ] || FAILURES=$((FAILURES + 1))
}

test_reject_then_resume_from_a_different_worktree
test_resolution_still_halts_on_a_missing_branch
test_branch_deletion_lives_only_on_the_merged_path

if [ "$FAILURES" -ne 0 ]; then
    echo "$FAILURES failure(s) in $(basename "${BASH_SOURCE[0]}")" >&2
    exit 1
fi
echo "PASS: $(basename "${BASH_SOURCE[0]}")"
