#!/usr/bin/env bash
# The shutdown-dance progress probe scans a warrant target's artifact worktree
# for recent file writes, but only after validate_progress_artifact_dir accepts
# the target's provider home. That check accepted a home directly under
# <rig_ns>/polecats and nothing else, so a specialists lane
# (<rig_ns>/{views,infra,dba,nimbus,tess}/<agent>) always read
# progress_signal=unknown: every warrant on those lanes was pardoned and
# escalated, and a stuck specialist was never reaped.
#
# These cases key the validation on worktree shape (a provider home two levels
# under the rig namespace), not on the name of the tree it lives in.
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
SHUTDOWN_FORMULA="$ROOT/gastown/formulas/mol-shutdown-dance.toml"

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

# mktemp -d returns /var/folders/... on macOS, where /var is a symlink to
# /private/var. The probe's rig-namespace guard rejects any path that differs
# from its physical form, so the fixtures must start physical too.
physical_mktemp_dir() {
    local dir
    dir=$(cd "$(mktemp -d)" && pwd -P) || return 1
    printf '%s\n' "$dir"
}

extract_shutdown_probe() {
    local output=$1
    python3 - "$SHUTDOWN_FORMULA" "$output" <<'PY'
import pathlib
import sys
import tomllib

formula_path = pathlib.Path(sys.argv[1])
output_path = pathlib.Path(sys.argv[2])
with formula_path.open("rb") as handle:
    formula = tomllib.load(handle)
execute = next(step for step in formula["steps"] if step["id"] == "execute")
description = execute["description"]
begin = description.index("# BEGIN SHUTDOWN_PROGRESS_PROBE")
end = description.index("# END SHUTDOWN_PROGRESS_PROBE", begin)
block = description[begin:end].splitlines()[1:]
output_path.write_text("\n".join(block) + "\n", encoding="utf-8")
PY
}

init_repo() {
    local repo=$1
    git init -q "$repo"
    git -C "$repo" config user.email lane-home-test@example.com
    git -C "$repo" config user.name "Lane Home Test"
    printf 'fixture\n' >"$repo/fixture.txt"
    git -C "$repo" add fixture.txt
    git -C "$repo" commit -qm "fixture"
}

# run_probe <city> <provider-home> <artifact-dir> — runs the extracted probe
# against a target session whose work_dir is <provider-home> and whose claimed
# bead records <artifact-dir>, and prints the probe's output. The bead is an
# hour old, so only the worktree scan can produce a progress signal.
run_probe() {
    local city=$1 provider=$2 artifact=$3 tmp probe bd_subcommand updated_at
    tmp=$(physical_mktemp_dir)
    trap 'rm -rf "$tmp"' RETURN
    probe="$tmp/probe.sh"
    bd_subcommand=$(printf '%s%s' b d)
    updated_at=$(python3 -c '
import datetime
moment = datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(hours=1)
print(moment.strftime("%Y-%m-%dT%H:%M:%SZ"))')
    extract_shutdown_probe "$probe"

    (
        # The sourced probe calls gc and reads $target; shellcheck cannot see it.
        # shellcheck disable=SC2329
        gc() {
            case "$*" in
                "session list --state=all --json")
                    printf '{"sessions":[{"id":"session-1","name":"demo/gastown.worker","template":"demo/gastown.polecat","rig":"demo","alias":"demo/gastown.worker","work_dir":"%s"}]}\n' "$provider"
                    ;;
                "$bd_subcommand --rig demo list --status=in_progress --json --limit=0")
                    printf '%s\n' '[{"id":"demo-b1","assignee":"demo/gastown.worker"}]'
                    ;;
                "$bd_subcommand --rig demo show demo-b1 --json")
                    printf '[{"id":"demo-b1","updated_at":"%s","metadata":{"artifact_dir":"%s"}}]\n' \
                        "$updated_at" "$artifact"
                    ;;
                *)
                    return 1
                    ;;
            esac
        }
        # shellcheck disable=SC2034
        GC_CITY_PATH="$city"
        # shellcheck disable=SC2034
        target="demo/gastown.worker"
        # shellcheck source=/dev/null
        source "$probe"
    ) 2>/dev/null
}

# lane_fixture <provider-home-relative-to-city> — builds a city whose provider
# home is a real worktree at <city>/<provider-home> and whose canonical
# artifact worktree for demo-b1 holds a freshly written file. Prints the city,
# provider home and artifact dir, one per line.
lane_fixture() {
    local home=$1 city repo provider artifact
    city=$(physical_mktemp_dir)
    repo="$city/repo"
    init_repo "$repo"
    provider="$city/$home"
    artifact="$city/.gc/worktrees/demo/artifacts/worktrees/demo-b1"
    mkdir -p "$(dirname "$provider")" "$(dirname "$artifact")"
    git -C "$repo" worktree add -q --detach "$provider"
    git -C "$repo" worktree add -q --detach "$artifact"
    printf 'fresh\n' >"$artifact/work.txt"
    printf '%s\n%s\n%s\n' "$city" "$provider" "$artifact"
}

test_specialists_lane_home_scans_canonical_artifact() {
    local fixture city provider artifact output
    fixture=$(lane_fixture .gc/worktrees/demo/views/specialists.view)
    city=$(sed -n 1p <<<"$fixture")
    provider=$(sed -n 2p <<<"$fixture")
    artifact=$(sed -n 3p <<<"$fixture")
    trap 'rm -rf "$city"' RETURN

    output=$(run_probe "$city" "$provider" "$artifact")
    printf '%s\n' "$output" | grep -q '^progress_signal=worktree:' ||
        fail "a specialists lane home should scan its canonical artifact, got: $output"
}

test_polecats_lane_home_still_scans() {
    local fixture city provider artifact output
    fixture=$(lane_fixture .gc/worktrees/demo/polecats/gastown.worker)
    city=$(sed -n 1p <<<"$fixture")
    provider=$(sed -n 2p <<<"$fixture")
    artifact=$(sed -n 3p <<<"$fixture")
    trap 'rm -rf "$city"' RETURN

    output=$(run_probe "$city" "$provider" "$artifact")
    printf '%s\n' "$output" | grep -q '^progress_signal=worktree:' ||
        fail "a polecats home should still scan its canonical artifact, got: $output"
}

test_home_outside_rig_namespace_fails_closed() {
    local fixture city provider artifact output
    # .gc/agents/demo/iris sits two levels under .gc/agents, not under the rig
    # namespace .gc/worktrees/demo, so its grandparent is not the namespace.
    fixture=$(lane_fixture .gc/agents/demo/iris)
    city=$(sed -n 1p <<<"$fixture")
    provider=$(sed -n 2p <<<"$fixture")
    artifact=$(sed -n 3p <<<"$fixture")
    trap 'rm -rf "$city"' RETURN

    output=$(run_probe "$city" "$provider" "$artifact")
    printf '%s\n' "$output" | grep -q '^progress_signal=unknown$' ||
        fail "a home outside the rig namespace should fail closed, got: $output"
}

test_specialists_lane_home_scans_canonical_artifact
test_polecats_lane_home_still_scans
test_home_outside_rig_namespace_fails_closed

echo "shutdown progress lane-home tests passed"
