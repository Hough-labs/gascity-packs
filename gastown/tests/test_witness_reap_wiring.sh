#!/usr/bin/env bash
# Contract tests for the witness patrol's worktree-reap wiring (gcp-d9uj).
#
# polecat-worktree-reap.sh was the witness `pre_start`, which gascity SIGKILLs at
# [session] setup_timeout, so it held itself to 8s and on a loaded city spent all
# of it on one bead read. It is now the `reap-merged-worktrees` step of
# mol-witness-patrol: a patrol cycle has no start deadline, so the budget is a
# policy var (`worktree_reap_budget`) and the removal mode is a per-rig var
# (`worktree_reap_mode`, default dry-run) instead of an edit to the pack.
#
# What this suite proves is the WIRING, so every case that runs the fence extracts
# the sentinel-delimited block of shipped formula text through tomllib, with the
# formula's [vars] defaults substituted and any `{{...}}` left over a hard error,
# and EXECUTES it under `env -i`. The one placeholder a case leaves literal is the
# one it is testing, on purpose: that is what the renderer leaves for a patrol
# poured root-only without the rig setting the var, and it must mean the safe
# value, never an armed reaper.
#
# gc is stubbed (it answers `formula list` and fails any other call). The reaper is
# a stub that logs its argv for the argv cases, and the REAL script for the
# end-to-end cases, which run against a real git rig with 12 closed-bead worktrees.
#
# The suite fails unless all 12 cases ran.
set -uo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
FORMULA="${FORMULA:-$ROOT/gastown/formulas/mol-witness-patrol.toml}"
REAL_REAPER="$ROOT/gastown/assets/scripts/polecat-worktree-reap.sh"
EXPECTED_CASES=12

FAILURES=0
PASS_CASES=0
CASE=""
CASE_START_FAILURES=0
T=""

export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@example.invalid
export GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@example.invalid

fail() {
    echo "FAIL[$CASE]: $*" >&2
    FAILURES=$((FAILURES + 1))
}

assert_eq() {
    # assert_eq <what> <want> <got>
    [ "$2" = "$3" ] || fail "$1: want '$2', got '$3'"
}

# --- extracting the shipped block ----------------------------------------------------

# extract_fence <outfile> [leave:VAR | set:VAR=value ...]
#
# The text from `# --- worktree-reap:begin ---` to `# --- worktree-reap:end ---`,
# which must occur in exactly one step. Placeholders come from the formula's [vars]
# defaults. `set:` overrides one the way a rig's formula_vars would, and `leave:`
# keeps one literal, which is the only placeholder allowed to survive.
extract_fence() {
    python3 - "$FORMULA" "$@" <<'PY'
import re
import sys
import tomllib

formula, out, *options = sys.argv[1:]
leave = [o[len("leave:"):] for o in options if o.startswith("leave:")]
overrides = dict(o[len("set:"):].split("=", 1) for o in options if o.startswith("set:"))
begin = "# --- worktree-reap:begin ---"
end = "# --- worktree-reap:end ---"

with open(formula, "rb") as handle:
    doc = tomllib.load(handle)

blocks = []
for step in doc["steps"]:
    text = step.get("description", "")
    if begin in text:
        rest = text.split(begin, 1)[1]
        if end not in rest:
            sys.exit(f"no {end} after the begin sentinel")
        blocks.append((step["id"], rest.split(end, 1)[0]))
if len(blocks) != 1:
    sys.exit(f"expected exactly one worktree-reap block in {formula}, found {len(blocks)}")
if blocks[0][0] != "reap-merged-worktrees":
    sys.exit(f"the worktree-reap block is in step {blocks[0][0]!r}, not reap-merged-worktrees")
block = blocks[0][1]

values = {n: spec.get("default", "") for n, spec in (doc.get("vars") or {}).items()}
for name in leave:
    if name not in values:
        sys.exit(f"{name!r} is not a declared var of this formula")
for name in overrides:
    if name not in values:
        sys.exit(f"{name!r} is not a declared var of this formula")
values.update(overrides)
for name in leave:
    values.pop(name)
block = re.sub(r"\{\{\s*(\w+)\s*\}\}", lambda m: values.get(m.group(1), m.group(0)), block)
leftover = sorted(set(re.findall(r"\{\{[^}]*\}\}", block)) - {"{{%s}}" % n for n in leave})
if leftover:
    sys.exit(f"unsubstituted placeholders in the fence: {leftover}")

with open(out, "w", encoding="utf-8") as handle:
    handle.write(block)
PY
}

# --- the fixture ---------------------------------------------------------------------

# gc answers `formula list` with the staged formula's source and serves the two
# reads the real reaper makes (`gc bd show`, `gc session list`) for the end-to-end cases.
# Anything else is unmodelled and fails the case.
write_gc_stub() {
    cat >"$1/gc" <<'STUB'
#!/usr/bin/env bash
printf 'gc %s\n' "$*" >>"${GC_STUB_LOG:?GC_STUB_LOG unset}"
case "${1:-}" in
formula)
    if [ -n "${GC_STUB_NO_FORMULA:-}" ]; then
        printf '{"formulas":[]}'
    else
        printf '{"formulas":[{"name":"mol-witness-patrol","source":"%s"}]}' "${GC_STUB_FORMULA_SOURCE:-}"
    fi
    ;;
session)
    printf '{"sessions":[]}'
    ;;
bd)
    shift
    if [ "${1:-}" = --rig ]; then shift 2; fi
    if [ "${1:-}" = show ]; then
        shift
        ids=""
        for a in "$@"; do
            case "$a" in -*) continue ;; esac
            ids="$ids$a
"
        done
        jq -c --arg ids "$ids" '($ids | split("\n") | map(select(length > 0))) as $want
            | [ .[] | select(.id as $i | $want | index($i)) ]' "${GC_BEADS_JSON:?GC_BEADS_JSON unset}"
    else
        printf '[]'
    fi
    ;;
*)
    printf '%s\n' "$*" >>"${GC_STUB_UNEXPECTED:?}"
    exit 64
    ;;
esac
STUB
    chmod +x "$1/gc"
}

# The stand-in reaper: it logs "<tag> <argv>" and exits as its env says. The tag is
# written into the script, so a case can tell WHICH copy of the script ran.
write_reaper_stub() {
    # write_reaper_stub <path> <tag>
    cat >"$1" <<STUB
#!/usr/bin/env bash
printf '%s %s\n' "$2" "\$*" >>"\${STUB_REAP_LOG:?STUB_REAP_LOG unset}"
exit "\${STUB_REAP_RC:-0}"
STUB
    chmod +x "$1"
}

# A shim in front of git and rm that journals every destructive call the sweep
# makes, then runs the real one. A dry run must leave both journals empty.
write_destructive_shims() {
    local real_git real_rm
    real_git=$(command -v git)
    real_rm=$(command -v rm)
    cat >"$1/git" <<SHIM
#!/usr/bin/env bash
for a in "\$@"; do
    if [ "\$a" = remove ]; then printf 'git %s\n' "\$*" >>"\${SHIM_DESTRUCTIVE_LOG:?}"; fi
done
exec "$real_git" "\$@"
SHIM
    cat >"$1/rm" <<SHIM
#!/usr/bin/env bash
for a in "\$@"; do
    case "\$a" in -*r*) printf 'rm %s\n' "\$*" >>"\${SHIM_DESTRUCTIVE_LOG:?}"; break ;; esac
done
exec "$real_rm" "\$@"
SHIM
    chmod +x "$1/git" "$1/rm"
}

# new_case <name> — a fresh staged pack tree (the one `formula list` names) and an
# empty fallback tree (what GC_PACK_DIR points at), each with a stub reaper.
new_case() {
    CASE="$1"
    CASE_START_FAILURES=$FAILURES
    T=$(mktemp -d)
    mkdir -p "$T/bin" "$T/home" "$T/rigroot" \
        "$T/pack/formulas" "$T/pack/assets/scripts" \
        "$T/fallback/assets/scripts"
    : >"$T/pack/formulas/mol-witness-patrol.toml"
    write_gc_stub "$T/bin"
    write_reaper_stub "$T/pack/assets/scripts/polecat-worktree-reap.sh" FORMULA_SOURCE
    write_reaper_stub "$T/fallback/assets/scripts/polecat-worktree-reap.sh" PACK_DIR
    : >"$T/gc.log"
    : >"$T/reap.log"
    : >"$T/unexpected"
}

end_case() {
    [ ! -s "$T/unexpected" ] || fail "unmodelled stub call(s): $(tr '\n' ';' <"$T/unexpected")"
    if [ "$FAILURES" -ne "$CASE_START_FAILURES" ]; then
        {
            echo "--- $CASE: last run stdout ---"
            cat "$T/out" 2>/dev/null
            echo "--- $CASE: last run stderr ---"
            cat "$T/err" 2>/dev/null
            echo "--- $CASE: gc calls ---"
            cat "$T/gc.log"
            echo "--- $CASE: reaper calls ---"
            cat "$T/reap.log"
        } >&2
    fi
    trash "$T" 2>/dev/null || rm -rf "$T"
    PASS_CASES=$((PASS_CASES + 1))
}

# run_fence <file> [VAR=value ...] — run an extracted fence the way the patrol does,
# under `env -i` so no agent-session variable leaks in. Defaults model a witness
# session: GC_RIG and GC_RIG_ROOT set, a formula source gc can name. The fence's own
# status is returned; stdout and stderr land in $T/out and $T/err.
run_fence() {
    local file="$1"
    shift
    (
        cd "$T" || exit 90
        env -i \
            PATH="$T/bin:$PATH" HOME="$T/home" \
            GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 \
            GC_RIG=testrig GC_RIG_ROOT="$T/rigroot" \
            GC_STUB_LOG="$T/gc.log" GC_STUB_UNEXPECTED="$T/unexpected" \
            GC_STUB_FORMULA_SOURCE="$T/pack/formulas/mol-witness-patrol.toml" \
            STUB_REAP_LOG="$T/reap.log" \
            "$@" \
            bash "$file"
    ) >"$T/out" 2>"$T/err"
}

# run_reap <mode|LITERAL> <budget|LITERAL> [VAR=value ...] — the fence with the two
# rig vars rendered as given. LITERAL leaves the placeholder unrendered, as a
# root-only pour without the rig's var does. The reaper log is emptied first.
run_reap() {
    local mode="$1" budget="$2" opts=()
    shift 2
    if [ "$mode" = LITERAL ]; then opts+=(leave:worktree_reap_mode); else opts+=("set:worktree_reap_mode=$mode"); fi
    if [ "$budget" = LITERAL ]; then opts+=(leave:worktree_reap_budget); else opts+=("set:worktree_reap_budget=$budget"); fi
    extract_fence "$T/reap.sh" "${opts[@]}" || { fail "could not extract the worktree-reap fence"; return 1; }
    : >"$T/reap.log"
    run_fence "$T/reap.sh" "$@"
}

reap_calls() { cat "$T/reap.log"; }

# --- the shipped text ----------------------------------------------------------------

formula_var() {
    # formula_var <var> <key> — [vars.<var>].<key>, read through tomllib.
    python3 - "$FORMULA" "$@" <<'PY'
import sys
import tomllib

with open(sys.argv[1], "rb") as handle:
    print(tomllib.load(handle)["vars"][sys.argv[2]][sys.argv[3]])
PY
}

# --- the cases -----------------------------------------------------------------------

case_vars_and_defaults() {
    new_case vars_and_defaults
    assert_eq "worktree_reap_mode default" dry-run "$(formula_var worktree_reap_mode default)"
    assert_eq "worktree_reap_budget default" 120 "$(formula_var worktree_reap_budget default)"
    end_case
}

# Resolution order. The formula's own source path is primary, so the script that
# runs is the one shipped beside the formula that asked for it. GC_PACK_DIR is
# exported only when gc invokes a pack command, so it can never be the primary
# (gcp-amo).
case_formula_source_wins() {
    new_case formula_source_wins
    run_reap dry-run 120 GC_PACK_DIR="$T/fallback" || fail "fence exited $? with both candidates present"
    assert_eq "which copy ran" "FORMULA_SOURCE $T/rigroot --rig testrig --budget 120" "$(reap_calls)"
    grep -qF "formula list" "$T/gc.log" || fail "the formula source was never asked for: $(cat "$T/gc.log")"
    end_case
}

case_pack_dir_is_fallback_only() {
    new_case pack_dir_is_fallback_only
    # gc names no source for the formula: the fallback is the only candidate.
    run_reap dry-run 120 GC_PACK_DIR="$T/fallback" GC_STUB_NO_FORMULA=1 ||
        fail "fence exited $? with only GC_PACK_DIR available"
    assert_eq "no formula source" "PACK_DIR $T/rigroot --rig testrig --budget 120" "$(reap_calls)"
    # gc names a source, but its tree carries no script: still the fallback.
    trash "$T/pack/assets/scripts/polecat-worktree-reap.sh"
    run_reap dry-run 120 GC_PACK_DIR="$T/fallback" ||
        fail "fence exited $? with the source tree missing the script"
    assert_eq "source tree without the script" "PACK_DIR $T/rigroot --rig testrig --budget 120" "$(reap_calls)"
    # A non-executable source copy is not runnable either, and must not win.
    write_reaper_stub "$T/pack/assets/scripts/polecat-worktree-reap.sh" FORMULA_SOURCE
    chmod -x "$T/pack/assets/scripts/polecat-worktree-reap.sh"
    run_reap dry-run 120 GC_PACK_DIR="$T/fallback" ||
        fail "fence exited $? with a non-executable source copy"
    assert_eq "non-executable source copy" "PACK_DIR $T/rigroot --rig testrig --budget 120" "$(reap_calls)"
    end_case
}

# A sweep that cannot be resolved is itself the finding: loud, non-zero, and the
# reaper never runs. The home-audit precedent echoes and moves on; this fence also
# fails its own status so a silent exit 0 is impossible.
case_unresolvable_is_loud() {
    new_case unresolvable_is_loud
    local status
    run_reap dry-run 120 GC_STUB_NO_FORMULA=1
    status=$?
    [ "$status" -ne 0 ] || fail "an unresolvable sweep exited 0"
    grep -qF "FINDING polecat-worktree-reap: sweep not runnable" "$T/out" ||
        fail "no loud finding on stdout: $(cat "$T/out")"
    grep -qF "UNREAPED this cycle" "$T/out" || fail "the finding does not say what is at stake"
    assert_eq "reaper calls" "" "$(reap_calls)"
    # GC_PACK_DIR set but empty of the script is the same finding, not a pass.
    run_reap dry-run 120 GC_STUB_NO_FORMULA=1 GC_PACK_DIR="$T/fallback-missing"
    status=$?
    [ "$status" -ne 0 ] || fail "a GC_PACK_DIR without the script exited 0"
    grep -qF "FINDING polecat-worktree-reap: sweep not runnable" "$T/out" ||
        fail "no loud finding for a GC_PACK_DIR without the script: $(cat "$T/out")"
    end_case
}

case_no_rig_is_loud() {
    new_case no_rig_is_loud
    local status
    run_reap dry-run 120 GC_RIG_ROOT=
    status=$?
    [ "$status" -ne 0 ] || fail "a fence with no rig root exited 0"
    grep -qF "FINDING polecat-worktree-reap: GC_RIG_ROOT=''" "$T/out" ||
        fail "no loud finding for the missing rig root: $(cat "$T/out")"
    assert_eq "reaper calls with no rig root" "" "$(reap_calls)"
    run_reap dry-run 120 GC_RIG=
    status=$?
    [ "$status" -ne 0 ] || fail "a fence with no rig name exited 0"
    assert_eq "reaper calls with no rig name" "" "$(reap_calls)"
    end_case
}

case_reaper_failure_is_a_finding() {
    new_case reaper_failure_is_a_finding
    local status
    run_reap dry-run 120 STUB_REAP_RC=3
    status=$?
    [ "$status" -ne 0 ] || fail "a reaper that exited 3 left the fence at 0"
    grep -qF "FINDING polecat-worktree-reap: exited 3" "$T/out" ||
        fail "the reaper's failure is not reported: $(cat "$T/out")"
    end_case
}

# Dry-run is the default: nothing in the pack arms the reaper.
case_dry_run_is_the_default() {
    new_case dry_run_is_the_default
    local mode
    for mode in dry-run LITERAL; do
        run_reap "$mode" 120 || fail "fence exited $? for mode $mode"
        case "$(reap_calls)" in
            *--no-dry-run*) fail "mode $mode passed --no-dry-run: $(reap_calls)" ;;
            "") fail "mode $mode never ran the reaper" ;;
        esac
    done
    # Unrendered is reported, so a rig that set the var and never got it is visible.
    grep -qF "INFO: worktree_reap_mode='{{worktree_reap_mode}}' is not dry-run or remove; dry-run." "$T/out" ||
        fail "an unrendered mode was not reported: $(cat "$T/out")"
    # And the formula's own default, with no override at all, is what ships.
    extract_fence "$T/default.sh" || fail "could not extract with defaults"
    : >"$T/reap.log"
    run_fence "$T/default.sh" || fail "fence exited $? with the shipped defaults"
    case "$(reap_calls)" in
        *--no-dry-run*) fail "the shipped defaults pass --no-dry-run: $(reap_calls)" ;;
    esac
    end_case
}

case_only_remove_arms() {
    new_case only_remove_arms
    local mode n
    run_reap remove 120 || fail "fence exited $? for mode remove"
    assert_eq "armed argv" "FORMULA_SOURCE $T/rigroot --rig testrig --budget 120 --no-dry-run" "$(reap_calls)"
    n=$(grep -o -e '--no-dry-run' "$T/reap.log" | wc -l | tr -d ' ')
    assert_eq "--no-dry-run count" 1 "$n"
    # Nothing but the exact word arms it.
    for mode in REMOVE Remove true yes 1 armed no-dry-run --no-dry-run " remove" "remove " ""; do
        run_reap "$mode" 120 || fail "fence exited $? for mode '$mode'"
        case "$(reap_calls)" in
            *--no-dry-run*) fail "mode '$mode' armed the reaper: $(reap_calls)" ;;
            "") fail "mode '$mode' never ran the reaper" ;;
        esac
    done
    end_case
}

case_budget() {
    new_case budget
    local pair want got
    # <value>:<want> — the value the var renders as, and the --budget the reaper gets.
    for pair in 120:120 300:300 1:1 540:540 541:540 9999:540 abc:120 0:120 -5:120 1.5:120 "":120 LITERAL:120; do
        want=${pair##*:}
        run_reap dry-run "${pair%%:*}" || fail "fence exited $? for budget '${pair%%:*}'"
        got=$(reap_calls | sed -n 's/.*--budget \([^ ]*\).*/\1/p')
        assert_eq "budget '${pair%%:*}'" "$want" "$got"
    done
    end_case
}

# End to end against the REAL script, in a real git rig with 12 closed-bead
# worktrees (the acceptance's ">= 10 candidates"). The pack tree's script is the
# shipped one, found the way the fence finds it.
setup_real_rig() {
    local rig="$T/rig" home="$T/city/.gc/worktrees/rig/polecats/nux" i id
    git init -q "$rig"
    git -C "$rig" config user.email reap@test
    git -C "$rig" config user.name reap
    echo seed >"$rig/seed.txt"
    git -C "$rig" add seed.txt
    git -C "$rig" commit -qm seed
    REAP_HOME="$home"
    : >"$T/beads.json"
    local rows=()
    for i in $(seq -w 1 12); do
        id="wt-$i"
        git -C "$rig" worktree add -q "$home/worktrees/$id" --detach HEAD
        rows+=("{\"id\":\"$id\",\"status\":\"closed\",\"metadata\":{\"polecat_session\":\"deadsess\"}}")
    done
    printf '[%s]\n' "$(
        IFS=,
        echo "${rows[*]}"
    )" >"$T/beads.json"
    cp -f "$REAL_REAPER" "$T/pack/assets/scripts/polecat-worktree-reap.sh"
    chmod +x "$T/pack/assets/scripts/polecat-worktree-reap.sh"
    mkdir -p "$T/shims" "$T/logs"
    write_destructive_shims "$T/shims"
    : >"$T/destructive.log"
}

run_real() {
    # run_real <mode>
    run_reap "$1" 120 GC_RIG_ROOT="$T/rig" GC_RIG=rig \
        PATH="$T/shims:$T/bin:$PATH" LOG_DIR="$T/logs" \
        GC_BEADS_JSON="$T/beads.json" SHIM_DESTRUCTIVE_LOG="$T/destructive.log"
}

count_events() {
    # count_events <event> — lines of the reap log carrying that event.
    grep -cF "\"event\":\"$1\"" "$T/logs/polecat-worktree-reap.log" 2>/dev/null || true
}

case_real_dry_run_removes_nothing() {
    new_case real_dry_run_removes_nothing
    setup_real_rig
    local i
    run_real dry-run || fail "the real sweep exited $? in dry-run"
    assert_eq "worktree_reap_pending" 12 "$(count_events worktree_reap_pending)"
    assert_eq "worktree_scan_complete" 1 "$(count_events worktree_scan_complete)"
    assert_eq "worktree_budget_exhausted" 0 "$(count_events worktree_budget_exhausted)"
    assert_eq "worktree_reaped" 0 "$(count_events worktree_reaped)"
    for i in $(seq -w 1 12); do
        [ -d "$REAP_HOME/worktrees/wt-$i" ] || fail "dry-run removed worktree wt-$i"
    done
    assert_eq "destructive calls in dry-run" "" "$(cat "$T/destructive.log")"
    grep -qF '"dry_run":true' "$T/logs/polecat-worktree-reap.log" || fail "the sweep did not record itself as a dry run"
    # The same with the placeholder unrendered: still no removal.
    run_real LITERAL || fail "the real sweep exited $? with the mode unrendered"
    assert_eq "destructive calls with an unrendered mode" "" "$(cat "$T/destructive.log")"
    for i in $(seq -w 1 12); do
        [ -d "$REAP_HOME/worktrees/wt-$i" ] || fail "an unrendered mode removed worktree wt-$i"
    done
    end_case
}

case_real_remove_reaps_what_dry_run_listed() {
    new_case real_remove_reaps_what_dry_run_listed
    setup_real_rig
    local i
    run_real remove || fail "the real sweep exited $? armed"
    assert_eq "worktree_reaped" 12 "$(count_events worktree_reaped)"
    assert_eq "worktree_scan_complete" 1 "$(count_events worktree_scan_complete)"
    assert_eq "worktree_budget_exhausted" 0 "$(count_events worktree_budget_exhausted)"
    for i in $(seq -w 1 12); do
        [ ! -e "$REAP_HOME/worktrees/wt-$i" ] || fail "armed sweep left worktree wt-$i"
    done
    [ -s "$T/destructive.log" ] || fail "armed sweep removed nothing through git or rm"
    end_case
}

# The prose must not send the next reader back down the path this change closed,
# and the agent config must wire no reaper (the other half of "a move, not an
# addition"; test_agent_pre_start_budget.sh keeps the inventory).
case_prose_and_agent_config() {
    new_case prose_and_agent_config
    local witness="$ROOT/gastown/agents/witness/agent.toml"
    python3 - "$FORMULA" <<'PY' || fail "the patrol still claims a formula step cannot name a pack asset"
import re
import sys
import tomllib

with open(sys.argv[1], "rb") as handle:
    doc = tomllib.load(handle)
step = next(s for s in doc["steps"] if s["id"] == "reap-merged-worktrees")
text = re.sub(r"\s+", " ", step["description"])
for stale in (
    "a formula step cannot name it",
    "is wired as the witness `pre_start`",
    "so it has already run for this session",
    "is the only stable handle on the script",
):
    if stale in text:
        sys.exit(f"stale claim survives: {stale!r}")
for needed in ("gc formula list --json", "GC_PACK_DIR"):
    if needed not in text:
        sys.exit(f"the step no longer mentions {needed!r}")
PY
    [ "$(grep -c polecat-worktree-reap "$witness")" = 0 ] ||
        fail "agent.toml still names the reaper: $(grep -n polecat-worktree-reap "$witness")"
    ! grep -Eq '^[[:space:]]*pre_start[[:space:]]*=' "$witness" || fail "the witness wires a pre_start again"
    end_case
}

case_vars_and_defaults
case_formula_source_wins
case_pack_dir_is_fallback_only
case_unresolvable_is_loud
case_no_rig_is_loud
case_reaper_failure_is_a_finding
case_dry_run_is_the_default
case_only_remove_arms
case_budget
case_real_dry_run_removes_nothing
case_real_remove_reaps_what_dry_run_listed
case_prose_and_agent_config

if [ "$PASS_CASES" -ne "$EXPECTED_CASES" ]; then
    echo "FAIL: $PASS_CASES of $EXPECTED_CASES cases ran" >&2
    exit 1
fi
if [ "$FAILURES" -ne 0 ]; then
    echo "FAIL: $FAILURES assertion(s) failed across $PASS_CASES cases" >&2
    exit 1
fi
echo "OK: $PASS_CASES cases passed"
