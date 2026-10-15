#!/usr/bin/env bash
# Tests for gastown/assets/scripts/polecat-workspace.sh, the one script behind
# the base resolution, the worktree setup and the branch record of
# mol-polecat-work's workspace-setup step (gcp-xeael).
#
# Those fences were about 270 lines of shell that every polecat retyped. They now
# ship as one script with a `base-resolve`, a `worktree` and a `new-branch` mode,
# and the step carries a short stub for each that locates the script, passes it
# the formula's values as arguments, and SOURCES it. Sourced, not executed: the
# fences ran in the polecat's own shell and left its working directory (a cd into
# the task worktree), BASE_REF and their other variables there for the blocks
# after them, and a child process could hand none of that back.
#
# These tests run the real script and the real stubs, decoded from the formula.
# Their identity with the old fences was proven by a throwaway harness, which is
# not committed; test_polecat_artifact_dir.sh and test_polecat_base_resolution.sh
# run the worktree and base-resolve bodies against real git.
#
# What is pinned here is what those do not reach: the interface (it must be
# sourced, usage, arity), what the call leaves in the caller's shell, the
# arguments reaching the writes, and the stubs' unresolved-script stop.
#
# No test depends on wall-clock time or on a network: every external command is
# a stub (or a scratch repo), and stdin is /dev/null.
# shellcheck disable=SC2016  # the assertions grep literal $VAR text
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
WORKSPACE="$ROOT/gastown/assets/scripts/polecat-workspace.sh"
FORMULA="$ROOT/gastown/formulas/mol-polecat-work.toml"
USAGE_PREFIX='WORKSPACE_USAGE'

if ! command -v jq >/dev/null 2>&1; then
    echo "  skip  jq not available (the stubs' locator needs it)"
    exit 0
fi

# mktemp -d is /var/folders/... on macOS, where /var is a symlink to /private/var,
# and the validator's rig-namespace guard rejects any path that differs from its
# physical form. The worktree test needs a physical root.
TMPROOT=$(cd "$(mktemp -d)" && pwd -P)
trap 'rm -rf "$TMPROOT"' EXIT

# fail names the test that called it, so a red run says which case broke.
fail() {
    local fn name=""
    for fn in "${FUNCNAME[@]}"; do
        case "$fn" in test_*) name=$fn; break ;; esac
    done
    echo "FAIL${name:+ $name}: $*" >&2
    exit 1
}

# new_case <name> — a fresh sandbox $CASE with a stub `gc` and `git` in
# $CASE/bin that journal every call to $CASE/calls.log. `gc formula list --json`
# prints $FORMULAS. The git stub answers the ref probes from env:
#   REMOTE_REF=0 / LOCAL_REF=0   the base is missing on origin / locally
#   EXPECTED_REF=1               polecat/<bead> already exists (default: it does not)
#   ANCESTOR_RC, REVLIST_OUT     the stale-base ancestry check and its count
#   GIT_BRANCH, GIT_STATUS       what `git branch --show-current` / `status --porcelain` print
#   FETCH_RC, CHECKOUT_RC        the exit codes of `git fetch origin` / `git checkout -b`
new_case() {
    CASE="$TMPROOT/$1"
    mkdir -p "$CASE/bin" "$CASE/cwd"
    : >"$CASE/calls.log"
    cat >"$CASE/bin/gc" <<'SH'
#!/usr/bin/env bash
printf 'gc %s\n' "$*" >>"$CASE/calls.log"
case "${1:-}:${2:-}" in
    formula:list) printf '%s\n' "$FORMULAS" ;;
    bd:update)
        if [ -n "${REFUSE_UPDATE:-}" ]; then echo "gc: update refused" >&2; exit 1; fi ;;
esac
exit 0
SH
    cat >"$CASE/bin/git" <<'SH'
#!/usr/bin/env bash
printf 'git %s\n' "$*" >>"$CASE/calls.log"
case "${1:-} ${2:-}" in
    "show-ref --verify")
        case "$4" in
            refs/heads/polecat/* | refs/remotes/origin/polecat/*) [ "${EXPECTED_REF:-0}" = 1 ] || exit 1 ;;
            refs/remotes/*) [ "${REMOTE_REF:-1}" = 1 ] || exit 1 ;;
            refs/heads/*) [ "${LOCAL_REF:-1}" = 1 ] || exit 1 ;;
        esac ;;
    "merge-base --is-ancestor") exit "${ANCESTOR_RC:-0}" ;;
    "rev-list --count") echo "${REVLIST_OUT:-0}" ;;
    "branch --show-current") echo "${GIT_BRANCH-}" ;;
    "status --porcelain") printf '%s' "${GIT_STATUS-}" ;;
    "fetch origin") exit "${FETCH_RC:-0}" ;;
    "checkout -b") exit "${CHECKOUT_RC:-0}" ;;
    "ls-remote --exit-code") exit "${LSREMOTE_RC:-0}" ;;
    "rev-parse "*) echo deadbeef ;;
    "merge-base "*) echo deadbeef ;;
esac
exit 0
SH
    chmod +x "$CASE/bin/gc" "$CASE/bin/git"
    FORMULAS='{"formulas":[]}'
}

# run_sourced <script-args...> -- <env...> -- <after-commands> — sources the
# script into a fresh bash the way a stub does, with only the given env (plus the
# stub plumbing), then runs <after-commands> in that same shell. Sets RC and
# leaves stdout and stderr in $CASE/out and $CASE/err.
run_sourced() {
    local -a args=() env=()
    while [ "$#" -gt 0 ] && [ "$1" != "--" ]; do args+=("$1"); shift; done
    [ "$#" -gt 0 ] && shift
    while [ "$#" -gt 0 ] && [ "$1" != "--" ]; do env+=("$1"); shift; done
    [ "$#" -gt 0 ] && shift
    local after="${1:-:}"
    RC=0
    (
        cd "$CASE/cwd" &&
            env -i PATH="$CASE/bin:$PATH" HOME="$CASE" GIT_CONFIG_GLOBAL=/dev/null \
                CASE="$CASE" FORMULAS="$FORMULAS" ${env[@]+"${env[@]}"} \
                "${BASH_UNDER_TEST:-bash}" -c '. "$@"; '"$after" _ "$WORKSPACE" ${args[@]+"${args[@]}"} </dev/null
    ) >"$CASE/out" 2>"$CASE/err" || RC=$?
}

calls() { cat "$CASE/calls.log"; }

# called <fixed-string> — fails unless some call in the log contains it.
called() {
    grep -qF -- "$1" "$CASE/calls.log" || fail "want a call containing '$1', calls: $(calls)"
}
never_called() {
    ! grep -qF -- "$1" "$CASE/calls.log" || fail "want no call containing '$1', calls: $(calls)"
}

test_script_holds_no_formula_placeholder() {
    [ "$(grep -c '{{' "$WORKSPACE")" = 0 ] || fail "$WORKSPACE must hold no {{...}}: gc renders the step text, not the script"
    bash -n "$WORKSPACE" || fail "the script is not valid bash"
    if [ -x /bin/bash ]; then
        /bin/bash -n "$WORKSPACE" || fail "the script is not valid for the system bash"
    fi
}

# The shell the script replaced must not also stay in the step: two copies drift.
test_step_text_carries_no_second_copy() {
    python3 -I - "$FORMULA" <<'PY' || fail "the step still carries shell the script now runs"
import sys
import tomllib

doc = tomllib.load(open(sys.argv[1], "rb"))
text = next(s["description"] for s in doc["steps"] if s["id"] == "workspace-setup")
problems = [m for m in (
    "validate_artifact_worktree", "ARTIFACT_WORKTREE_VALIDATOR", "BEAD_JSON=", "LEGACY_WORK_DIR",
    "GUARD_BEGIN base-resolve", "BASE_REMOTE=", "WITNESS_TARGET=", 'git -C "$RIG_ROOT" worktree',
    'EXPECTED_BRANCH=', 'git checkout -b "$BRANCH"', "FORK_SHA=", "ARTIFACT_HOME=",
) if m in text]
if problems:
    sys.exit(f"still in the step text: {problems}")
for mode in ("base-resolve", "worktree", "new-branch"):
    if text.count(f'. "$WS" {mode} ') != 1:
        sys.exit(f"want exactly one sourced call of the {mode} mode")
if text.count("polecat-workspace.sh}") != 3:
    sys.exit("want exactly three stubs that locate polecat-workspace.sh")
PY
}

# The script changes its caller's shell, so run as a child it would lose the cd
# and every variable: stop before touching anything rather than run half-useful.
test_executing_instead_of_sourcing_stops() {
    local label
    new_case executed
    for label in base-resolve worktree new-branch; do
        RC=0
        (cd "$CASE/cwd" && env -i PATH="$CASE/bin:$PATH" HOME="$CASE" CASE="$CASE" FORMULAS="$FORMULAS" \
            bash "$WORKSPACE" "$label" w-1 main gastown. </dev/null) >"$CASE/out" 2>"$CASE/err" || RC=$?
        [ "$RC" -eq 2 ] || fail "$label: executed, want exit 2, got $RC"
        grep -q "^$USAGE_PREFIX .*sourced, not executed" "$CASE/out" ||
            fail "$label: want the sourced-not-executed line, got: $(cat "$CASE/out")"
        [ ! -s "$CASE/calls.log" ] || fail "$label: an executed call must run nothing, calls: $(calls)"
    done
}

test_usage_rejects_unknown_mode_and_wrong_arity() {
    local label
    new_case usage
    for label in none bogus base-resolve-3 base-resolve-5 worktree-2 worktree-4 new-branch-3 new-branch-5; do
        : >"$CASE/calls.log"
        case "$label" in
            none) run_sourced -- ;;
            bogus) run_sourced bogus w-1 refs/remotes/origin/main -- ;;
            base-resolve-3) run_sourced base-resolve w-1 main -- ;;
            base-resolve-5) run_sourced base-resolve w-1 main gastown. extra -- ;;
            worktree-2) run_sourced worktree w-1 -- ;;
            worktree-4) run_sourced worktree w-1 refs/remotes/origin/main extra -- ;;
            new-branch-3) run_sourced new-branch w-1 refs/remotes/origin/main -- ;;
            new-branch-5) run_sourced new-branch w-1 refs/remotes/origin/main main extra -- ;;
        esac
        [ "$RC" -eq 2 ] || fail "$label: want exit 2, got $RC"
        grep -q "^$USAGE_PREFIX . polecat-workspace.sh base-resolve " "$CASE/out" ||
            fail "$label: want the usage line, got: $(cat "$CASE/out")"
        [ ! -s "$CASE/calls.log" ] || fail "$label: a usage error must run nothing, calls: $(calls)"
    done
}

# base-resolve leaves BASE_REF in the caller's shell (the rejection-rebase fence
# and new-branch read it there), returns the status of its last command like the
# fence did, and leaves none of its own parameters behind.
test_base_resolve_sets_base_ref_in_the_callers_shell() {
    new_case base-ref
    run_sourced base-resolve w-1 main gastown. -- GC_RIG=testrig -- 'echo "BASE_REF=$BASE_REF"; echo "WORK_BEAD_ID=$WORK_BEAD_ID"; compgen -v | grep "^WS_" || echo no-ws-vars'
    [ "$RC" -eq 0 ] || fail "want exit 0, got $RC: $(cat "$CASE/err")"
    grep -qx 'BASE_REF=refs/remotes/origin/main' "$CASE/out" || fail "want BASE_REF in the caller's shell, got: $(cat "$CASE/out")"
    grep -qx 'WORK_BEAD_ID=w-1' "$CASE/out" || fail "want WORK_BEAD_ID kept, got: $(cat "$CASE/out")"
    grep -qx 'no-ws-vars' "$CASE/out" || fail "the call left WS_ parameters in the shell: $(cat "$CASE/out")"
    called 'gc bd update w-1 --set-metadata base_ref=refs/remotes/origin/main'
    never_called 'drain-ack'

    # The status of the last command comes back, and the shell carries on: a
    # refused base_ref write is not a STOP (self-review reads it back and stops).
    new_case base-ref-refused
    run_sourced base-resolve w-1 main gastown. -- GC_RIG=testrig REFUSE_UPDATE=1 -- 'echo "after rc=$?"; echo "BASE_REF=$BASE_REF"'
    grep -q 'update refused' "$CASE/err" || fail "want the refusal on stderr, got: $(cat "$CASE/err")"
    grep -q 'BASE_REF=refs/remotes/origin/main' "$CASE/out" || fail "the shell must carry on with BASE_REF set, got: $(cat "$CASE/out")"
    grep -qx 'after rc=1' "$CASE/out" || fail "want the failed write's status (1) to come back, got: $(cat "$CASE/out")"
}

# {{base_branch}}, {{binding_prefix}}, the work bead and GC_RIG reach the STOP's
# writes through the arguments, and nothing else stands in.
test_base_resolve_arguments_reach_the_stop() {
    new_case base-stop
    run_sourced base-resolve w-9 release/2.x gastown. -- GC_RIG=testrig REMOTE_REF=0 LOCAL_REF=0
    [ "$RC" -eq 1 ] || fail "a missing base must exit 1, got $RC"
    grep -qx 'STOP: base branch release/2.x exists neither on origin nor locally.' "$CASE/out" ||
        fail "want the STOP line naming release/2.x, got: $(cat "$CASE/out")"
    called 'git show-ref --verify --quiet refs/remotes/origin/release/2.x'
    called 'git show-ref --verify --quiet refs/heads/release/2.x'
    called 'gc bd update w-9 --set-metadata halt_reason=base_branch_missing'
    called 'gc mail send testrig/gastown.witness -s polecat halted: base_branch_missing (w-9)'
    called 'gc runtime drain-ack'

    new_case base-stop-no-rig
    run_sourced base-resolve w-9 main gastown. -- REMOTE_REF=0 LOCAL_REF=0
    called 'gc mail send gastown.witness -s polecat halted: base_branch_missing (w-9)'

    new_case base-stop-unbound
    run_sourced base-resolve w-9 main '' -- GC_RIG=testrig REMOTE_REF=0 LOCAL_REF=0
    called 'gc mail send testrig/witness -s polecat halted: base_branch_missing (w-9)'
}

# new-branch reads BASE_REF from its argument and the base branch from its own:
# a local-only base is not fetched, a remote one is, by the name it is given.
test_new_branch_arguments_reach_the_branch_and_its_record() {
    new_case branch-remote
    run_sourced new-branch w-1 refs/remotes/origin/release/2.x release/2.x -- GC_RIG=testrig
    [ "$RC" -eq 0 ] || fail "want exit 0, got $RC: $(cat "$CASE/err")"
    called 'git fetch origin release/2.x'
    called 'git checkout -b polecat/w-1 refs/remotes/origin/release/2.x'
    called 'gc bd update w-1 --set-metadata branch=polecat/w-1 --set-metadata fork_sha=deadbeef'
    never_called 'drain-ack'

    new_case branch-local-only
    run_sourced new-branch w-1 refs/heads/release/2.x release/2.x -- GC_RIG=testrig
    [ "$RC" -eq 0 ] || fail "want exit 0, got $RC: $(cat "$CASE/err")"
    never_called 'git fetch origin'
    called 'git checkout -b polecat/w-1 refs/heads/release/2.x'

    new_case branch-fetch-lost
    run_sourced new-branch w-1 refs/remotes/origin/release/2.x release/2.x -- GC_RIG=testrig FETCH_RC=1 LSREMOTE_RC=1
    [ "$RC" -eq 1 ] || fail "a base that no longer resolves must exit 1, got $RC"
    grep -q '^STOP: release/2.x no longer resolves on origin' "$CASE/err" ||
        fail "want the STOP line naming release/2.x on stderr, got: $(cat "$CASE/err")"
    called 'git ls-remote --exit-code --heads origin refs/heads/release/2.x'
    never_called 'git checkout -b'
    called 'gc runtime drain-ack'
}

# An empty ref or id is passed through, not invented: new-branch keeps the guard
# it always had on entry, and nothing runs.
test_new_branch_with_an_empty_ref_aborts_on_its_own_guard() {
    new_case branch-no-ref
    run_sourced new-branch w-1 '' main -- GC_RIG=testrig
    [ "$RC" -ne 0 ] || fail "want a non-zero exit with no base ref, got 0"
    grep -q 'base ref not resolved' "$CASE/err" || fail "want the base-ref guard's message, got: $(cat "$CASE/err")"
    [ ! -s "$CASE/calls.log" ] || fail "an empty base ref must run nothing, calls: $(calls)"
}

# The cd is the point of sourcing: after the worktree call the caller is IN the
# task worktree, with the validator defined and nothing of the script's own left.
# Real git, because the validator rejects anything that is not a real worktree of
# the rig's repository.
test_worktree_moves_the_callers_shell_into_the_task_worktree() {
    local rig city provider canonical out
    new_case worktree
    rig="$CASE/rig"
    city="$CASE/city"
    provider="$city/.gc/worktrees/demo/polecats/gastown.nux"
    canonical="$city/.gc/worktrees/demo/artifacts/worktrees/w-1"
    git init -q "$rig"
    git -C "$rig" config user.email t@example.invalid
    git -C "$rig" config user.name t
    git -C "$rig" config commit.gpgsign false
    printf 'x\n' >"$rig/x"
    git -C "$rig" add x
    git -C "$rig" commit -qm x
    git -C "$rig" branch -M main
    git init -q --bare "$CASE/origin.git"
    git -C "$rig" remote add origin "$CASE/origin.git"
    git -C "$rig" push -q origin main
    git -C "$rig" fetch -q origin
    mkdir -p "$(dirname "$provider")"
    git -C "$rig" worktree add -q -b provider-home "$provider" main
    # The sandbox stubs would shadow the real git; these tests need the real one.
    rm -f "$CASE/bin/git"
    # The work bead has no metadata yet: the stub gc answers its show call with an empty object.
    cat >"$CASE/bin/gc" <<'SH'
#!/usr/bin/env bash
printf 'gc %s\n' "$*" >>"$CASE/calls.log"
case "${1:-}:${2:-}" in
    bd:show) printf '[{"id":"w-1","metadata":{}}]\n' ;;
esac
exit 0
SH
    cd "$CASE/cwd"
    for BASH_UNDER_TEST in bash /bin/bash; do
        [ -x "$(command -v "$BASH_UNDER_TEST")" ] || continue
        rm -rf "$canonical"
        git -C "$rig" worktree prune
        : >"$CASE/calls.log"
        # The cwd the polecat starts in is its provider home.
        RC=0
        (
            cd "$provider" &&
                env -i PATH="$CASE/bin:$PATH" HOME="$CASE" GIT_CONFIG_GLOBAL=/dev/null CASE="$CASE" \
                    GC_CITY_PATH="$city" GC_RIG=demo GC_RIG_ROOT="$rig" \
                    "$BASH_UNDER_TEST" -c '. "$1" worktree w-1 refs/remotes/origin/main
                        echo "PWD=$(pwd -P)"; echo "WORKTREE=$WORKTREE"
                        declare -F validate_artifact_worktree >/dev/null && echo validator-defined
                        compgen -v | grep "^WS_" || echo no-ws-vars' _ "$WORKSPACE" </dev/null
        ) >"$CASE/out" 2>"$CASE/err" || RC=$?
        out=$(cat "$CASE/out")
        [ "$RC" -eq 0 ] || fail "$BASH_UNDER_TEST: want exit 0, got $RC: $(cat "$CASE/err")"
        [[ "$out" == *"PWD=$canonical"* ]] || fail "$BASH_UNDER_TEST: the caller was not left in $canonical: $out"
        [[ "$out" == *"WORKTREE=$canonical"* ]] || fail "$BASH_UNDER_TEST: WORKTREE not set in the caller's shell: $out"
        [[ "$out" == *validator-defined* ]] || fail "$BASH_UNDER_TEST: the validator is not defined in the caller's shell: $out"
        [[ "$out" == *no-ws-vars* ]] || fail "$BASH_UNDER_TEST: the call left WS_ parameters behind: $out"
        called "gc bd update w-1 --set-metadata artifact_dir=$canonical --unset-metadata work_dir"
        never_called 'drain-ack'
    done
    unset BASH_UNDER_TEST
}

# render_stub <call-fragment> <outfile> [base_branch] — the bash fence of the step
# that holds that call, with every {{var}} replaced the way gc renders the step. A
# {{var}} left over is a hard error.
render_stub() {
    python3 -I - "$FORMULA" "$1" "$2" "${3:-main}" <<'PY'
import re
import sys
import tomllib

formula, call, out, base = sys.argv[1:5]
values = {"base_branch": base, "binding_prefix": "gastown.", "convoy_id": "gcp-convoy"}
doc = tomllib.load(open(formula, "rb"))
text = next(s["description"] for s in doc["steps"] if s["id"] == "workspace-setup")
stubs = [f for f in re.findall(r"```bash\n(.*?)\n```", text, re.S) if call in f]
if len(stubs) != 1:
    sys.exit(f"want exactly one fence calling {call!r}, found {len(stubs)}")
rendered = re.sub(r"\{\{(\w+)\}\}", lambda m: values.get(m.group(1), m.group(0)), stubs[0])
left = sorted(set(re.findall(r"\{\{\w+\}\}", rendered)))
if left:
    sys.exit(f"unrendered placeholders in the stub: {left}")
open(out, "w").write(rendered + "\n")
PY
}

# run_stub <stubfile> <env...> — runs a rendered stub from $CASE/cwd in one bash,
# then echoes what it left in the shell. The stub is sourced-script glue, so it
# runs as a script file whose last line sources the pack's script.
run_stub() {
    local stub="$1"
    shift
    RC=0
    (
        cd "$CASE/cwd" &&
            env -i PATH="$CASE/bin:$PATH" HOME="$CASE" GIT_CONFIG_GLOBAL=/dev/null \
                CASE="$CASE" FORMULAS="$FORMULAS" GC_RIG=testrig "$@" \
                bash "$stub" </dev/null
    ) >"$CASE/out" 2>"$CASE/err" || RC=$?
}

# workspace-setup is a DEFERRED step in tests/test_v2_drain_ack_closes_own_step.py:
# a mid-workflow early exit, where closing the step alone does not stop its
# dependents. Its stubs therefore stop and ack the drain the way preflight-tests's
# does, with no step close and no write to any bead.
test_stubs_stop_when_the_script_is_unresolved() {
    local call mode
    for call in '. "$WS" base-resolve ' '. "$WS" worktree ' '. "$WS" new-branch '; do
        mode=$(printf '%s' "$call" | awk '{print $3}')
        new_case "stub-missing-$mode"
        render_stub "$call" "$CASE/stub.sh" || fail "$mode: could not render the stub"
        # `gc formula list --json` finds no formula, so the script cannot be located.
        run_stub "$CASE/stub.sh" WORK_BEAD_ID=w-1 BASE_REF=refs/remotes/origin/main
        [ "$RC" -eq 1 ] || fail "$mode: want exit 1, got $RC: $(cat "$CASE/err")"
        grep -q '^STOP: workspace script not found' "$CASE/out" ||
            fail "$mode: want a line starting 'STOP: workspace script not found', got: $(cat "$CASE/out")"
        called 'gc runtime drain-ack'
        [ "$(grep -c 'drain-ack' "$CASE/calls.log")" = 1 ] || fail "$mode: want exactly one drain-ack: $(calls)"
        # The STOP ends the call: a stub that fell through would source an empty
        # path and say so on stderr.
        [ ! -s "$CASE/err" ] || fail "$mode: the STOP must end the call, stderr shows it went on: $(cat "$CASE/err")"
        never_called 'gc bd'
        never_called 'git '
        never_called 'gc mail'
    done
}

# The stubs pass the shell's own WORK_BEAD_ID and BASE_REF and the formula's base
# branch and binding prefix, in the order the script takes them.
test_stubs_run_the_script_the_formula_resolves() {
    new_case stub-base-resolve
    FORMULAS='{"formulas":[{"name":"mol-polecat-work","source":"'"$FORMULA"'"}]}'
    render_stub '. "$WS" base-resolve ' "$CASE/base.sh" release/2.x || fail "could not render the base-resolve stub"
    run_stub "$CASE/base.sh" WORK_BEAD_ID=w-3
    [ "$RC" -eq 0 ] || fail "base-resolve stub: want exit 0, got $RC: $(cat "$CASE/out") $(cat "$CASE/err")"
    called 'git show-ref --verify --quiet refs/remotes/origin/release/2.x'
    called 'gc bd update w-3 --set-metadata base_ref=refs/remotes/origin/release/2.x'

    new_case stub-base-resolve-stop
    FORMULAS='{"formulas":[{"name":"mol-polecat-work","source":"'"$FORMULA"'"}]}'
    render_stub '. "$WS" base-resolve ' "$CASE/base.sh" release/2.x || fail "could not render the base-resolve stub"
    run_stub "$CASE/base.sh" WORK_BEAD_ID=w-3 REMOTE_REF=0 LOCAL_REF=0
    [ "$RC" -eq 1 ] || fail "base-resolve stub on a missing base: want exit 1, got $RC"
    called 'gc mail send testrig/gastown.witness -s polecat halted: base_branch_missing (w-3)'

    new_case stub-new-branch
    FORMULAS='{"formulas":[{"name":"mol-polecat-work","source":"'"$FORMULA"'"}]}'
    render_stub '. "$WS" new-branch ' "$CASE/branch.sh" release/2.x || fail "could not render the new-branch stub"
    run_stub "$CASE/branch.sh" WORK_BEAD_ID=w-3 BASE_REF=refs/remotes/origin/release/2.x
    [ "$RC" -eq 0 ] || fail "new-branch stub: want exit 0, got $RC: $(cat "$CASE/out") $(cat "$CASE/err")"
    called 'git fetch origin release/2.x'
    called 'git checkout -b polecat/w-3 refs/remotes/origin/release/2.x'

    new_case stub-new-branch-unset-ref
    FORMULAS='{"formulas":[{"name":"mol-polecat-work","source":"'"$FORMULA"'"}]}'
    render_stub '. "$WS" new-branch ' "$CASE/branch.sh" || fail "could not render the new-branch stub"
    run_stub "$CASE/branch.sh" WORK_BEAD_ID=w-3
    [ "$RC" -ne 0 ] || fail "new-branch stub with no BASE_REF in the shell: want a non-zero exit, got 0"
    grep -q 'base ref not resolved' "$CASE/err" || fail "want the base-ref guard's message, got: $(cat "$CASE/err")"
    never_called 'git checkout -b'
}

test_script_holds_no_formula_placeholder
test_step_text_carries_no_second_copy
test_executing_instead_of_sourcing_stops
test_usage_rejects_unknown_mode_and_wrong_arity
test_base_resolve_sets_base_ref_in_the_callers_shell
test_base_resolve_arguments_reach_the_stop
test_new_branch_arguments_reach_the_branch_and_its_record
test_new_branch_with_an_empty_ref_aborts_on_its_own_guard
test_worktree_moves_the_callers_shell_into_the_task_worktree
test_stubs_stop_when_the_script_is_unresolved
test_stubs_run_the_script_the_formula_resolves
echo "polecat workspace tests passed"
