#!/usr/bin/env bash
# Pack-wide guard: nothing may be wired as a `pre_start` without a measured,
# enforced wall-clock bound inside the session setup_timeout.
#
# WHY THIS EXISTS. Twice now the same bug has cost a city an agent for hours:
#
#   gcp-ntbf  the witness reaper read one bead per candidate worktree; on a rig
#             with many worktrees that outran setup_timeout and winnow lost its
#             witness for 26h.
#   gcp-oo0v  the deacon's dolt-push-state sweep costs one `gc bd sql -C
#             <scope>` per scope — 18.6s measured — and the town lost its
#             deacon for ~5h, patrols dead, breaker latched.
#
# The mechanism is identical both times and it is not obvious from the diff
# that adds it. `pre_start` runs before the session exists, gc bounds it by
# `[session] setup_timeout` (10s by default) and SIGKILLs on overrun, and a
# killed pre_start fails the WHOLE session start. Six failures in an hour latch
# the supervisor's circuit breaker open, so the agent does not come back on its
# own. Neither script was broken; both simply could not fit the budget, and
# nothing anywhere asserted that they had to.
#
# gcp-oo0v also showed how such a line ARRIVES: not from someone editing an
# agent, but from a pin bump pulling in a pack whose agent.toml gained a
# pre_start. The reviewer verified the new formula content was live and never
# thought to look for a new pre_start. So the guard is an INVENTORY, not a
# heuristic: every pre_start in the repo must be listed below with the budget
# that bounds it. A new one fails this test until somebody measures it, which
# is exactly the step both incidents skipped.
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)

# gascity's default [session] setup_timeout. A pre_start's self-imposed budget
# must sit strictly inside it, with room for process startup and the rest of
# the pre_start list.
SETUP_TIMEOUT_SECONDS=10

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

# ── The inventory ────────────────────────────────────────────────────────────
# One line per wired pre_start: "<agent.toml path>\t<command>". Adding a
# pre_start means adding it here, which means having measured it. Deleting one
# means deleting its line. Anything else is a diff this test rejects.
#
#   gastown/agents/polecat, gastown/agents/refinery
#       worktree-setup.sh --sync. Local git plumbing plus up to three calls to
#       a remote; the remote calls share a 6s budget
#       (GC_WORKTREE_SETUP_BUDGET_SECONDS) and are abandoned, not retried, when
#       it expires — a worktree one fetch behind is fixed next cycle.
#   gastown/agents/witness
#       polecat-worktree-reap.sh. One bulk bead read plus per-worktree git
#       status, held to 8s (GC_REAP_BUDGET_SECONDS); deferred candidates are
#       reaped on the next patrol.
EXPECTED_PRE_STARTS=$(
    cat <<'INVENTORY'
gastown/agents/polecat/agent.toml	{{.ConfigDir}}/assets/scripts/worktree-setup.sh {{.RigRoot}} {{.WorkDir}} {{.AgentBase}} --sync
gastown/agents/refinery/agent.toml	{{.ConfigDir}}/assets/scripts/worktree-setup.sh {{.RigRoot}} {{.WorkDir}} {{.AgentBase}} --sync
gastown/agents/witness/agent.toml	{{.ConfigDir}}/assets/scripts/polecat-worktree-reap.sh {{.RigRoot}} --rig {{.Rig}}
INVENTORY
)

# ── What is actually wired ───────────────────────────────────────────────────
# Parsed, not grepped: a pre_start can be a bare string or a list, and a
# grep-shaped guard would miss the reformatting that a pin bump can bring.
actual_pre_starts() {
    python3 - "$ROOT" <<'PY'
import pathlib
import sys
import tomllib

root = pathlib.Path(sys.argv[1])
rows = []
for path in sorted(root.rglob("agent.toml")):
    if ".git" in path.parts:
        continue
    with path.open("rb") as handle:
        try:
            data = tomllib.load(handle)
        except tomllib.TOMLDecodeError as exc:
            raise SystemExit(f"unparseable agent config {path.relative_to(root)}: {exc}")
    value = data.get("pre_start")
    if value is None:
        continue
    commands = [value] if isinstance(value, str) else list(value)
    rel = path.relative_to(root).as_posix()
    for command in commands:
        rows.append(f"{rel}\t{command}")
print("\n".join(rows))
PY
}

test_every_pre_start_is_inventoried() {
    local actual
    actual=$(actual_pre_starts) || fail "could not read agent configs"

    if [[ "$actual" != "$EXPECTED_PRE_STARTS" ]]; then
        echo "pre_start inventory drifted." >&2
        echo "--- expected (gastown/tests/test_agent_pre_start_budget.sh) ---" >&2
        printf '%s\n' "$EXPECTED_PRE_STARTS" >&2
        echo "--- actual (agent.toml files) ---" >&2
        printf '%s\n' "$actual" >&2
        echo >&2
        echo "A NEW pre_start is not a formatting change. Measure its wall clock on a" >&2
        echo "real city first: it must finish well inside [session] setup_timeout" >&2
        echo "(${SETUP_TIMEOUT_SECONDS}s), enforce that budget itself, and exit 0 when the" >&2
        echo "budget expires — a pre_start killed on the deadline fails the whole session" >&2
        echo "start and latches the supervisor circuit breaker (gcp-ntbf, gcp-oo0v)." >&2
        echo "Work that cannot fit belongs in a patrol formula step, not here." >&2
        fail "pre_start inventory out of date"
    fi
}

# A budget nobody enforces is a comment. For each script the inventory names,
# assert the enforcement is still in the file and that its default actually
# fits — a bump to 30s "to make it stop timing out" is the shape of the next
# incident, so the number is asserted, not just its presence.
assert_bounded() {
    local script="$1" default_var="$2"
    local path="$ROOT/gastown/assets/scripts/$script"
    local budget

    [[ -f "$path" ]] || fail "$script is wired as a pre_start but is missing"
    [[ -x "$path" ]] || fail "$script is wired as a pre_start but is not executable"

    # The DEFINITION, not a mention: deleting the helper while leaving call
    # sites behind is exactly how a bound rots away without the diff looking
    # like a removal.
    grep -E '^run_bounded\(\)' "$path" >/dev/null ||
        fail "$script must define run_bounded; an unbounded pre_start is gcp-ntbf/gcp-oo0v"
    grep -E '^budget_left\(\)' "$path" >/dev/null ||
        fail "$script must define budget_left and spend one shared wall clock, not bound each call independently"

    # And every call that can actually block for tens of seconds must go
    # through it. Comments are dropped — the headers explain the unbounded
    # fetch that caused the incident, and saying so must not read as doing it —
    # but numbering happens FIRST, so the line this reports is the line in the
    # file rather than an offset into the stripped stream.
    local unbounded
    unbounded=$(grep -nE '(^|[^-[:alnum:]_])git([[:space:]]|.*[[:space:]])(fetch|pull|push|clone|ls-remote)([[:space:]]|$)' "$path" |
        grep -vE '^[0-9]+:[[:space:]]*#' |
        grep -v 'run_bounded' || true)
    [[ -z "$unbounded" ]] ||
        fail "$script calls a remote without a deadline: ${unbounded//$'\n'/ | }"

    budget=$(sed -n "s/.*\${$default_var:-\([0-9][0-9]*\)}.*/\1/p" "$path" | head -1)
    [[ -n "$budget" ]] ||
        fail "$script must declare a default budget via \${$default_var:-<seconds>}"
    (( budget > 0 )) ||
        fail "$script declares a non-positive $default_var default"
    (( budget < SETUP_TIMEOUT_SECONDS )) ||
        fail "$script's ${default_var} default (${budget}s) is not inside setup_timeout (${SETUP_TIMEOUT_SECONDS}s); raise the timeout in the same change or shrink the work"
}

test_inventoried_scripts_enforce_their_budget() {
    assert_bounded worktree-setup.sh GC_WORKTREE_SETUP_BUDGET_SECONDS
    assert_bounded polecat-worktree-reap.sh GC_REAP_BUDGET_SECONDS
}

# The deacon is the agent gcp-oo0v killed. Naming it directly means a revert of
# that fix fails with the incident in the message, not just an inventory diff.
test_deacon_carries_no_pre_start() {
    local deacon="$ROOT/gastown/agents/deacon/agent.toml"

    [[ -f "$deacon" ]] || fail "missing deacon agent config"
    ! grep -E '^[[:space:]]*pre_start[[:space:]]*=' "$deacon" >/dev/null ||
        fail "deacon must not wire a pre_start: its push-state sweep measured 18.6s against a ${SETUP_TIMEOUT_SECONDS}s setup_timeout and cost the town its patrols for ~5h (gcp-oo0v). The sweep belongs in mol-deacon-patrol."
}

test_every_pre_start_is_inventoried
test_inventoried_scripts_enforce_their_budget
test_deacon_carries_no_pre_start

echo "agent pre_start budget guard passed"
