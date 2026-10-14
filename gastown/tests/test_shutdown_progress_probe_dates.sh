#!/usr/bin/env bash
# The shutdown-dance progress probe decides whether a warrant target is still
# working by aging its claimed bead's updated_at. That parse used GNU
# `date -u -d` alone, which BSD date (macOS) rejects: the age came out unknown
# for every bead, so every warrant was pardoned and escalated and a stuck
# session was never reaped. These cases pin the parse to a numeric age on the
# host that runs them.
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
SHUTDOWN_FORMULA="$ROOT/gastown/formulas/mol-shutdown-dance.toml"

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

physical_mktemp_dir() {
    local dir
    dir=$(mktemp -d) || return 1
    (cd "$dir" && pwd -P)
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

# bead_timestamp <seconds-ago> [fraction] — RFC3339 UTC, the shape gc emits for
# a bead's updated_at. Python rather than date: the point of this file is that
# the probe's own date parsing must not be what builds the fixture.
bead_timestamp() {
    python3 - "$1" "${2:-}" <<'PY'
import datetime
import sys

ago = int(sys.argv[1])
fraction = sys.argv[2]
moment = datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(seconds=ago)
print(moment.strftime("%Y-%m-%dT%H:%M:%S") + fraction + "Z")
PY
}

# run_probe <bead-updated-at> — runs the extracted probe against a target whose
# only claimed bead carries that updated_at, and prints the probe's output.
run_probe() {
    local updated_at=$1 tmp probe bd_subcommand
    tmp=$(physical_mktemp_dir)
    trap 'rm -rf "$tmp"' RETURN
    probe="$tmp/probe.sh"
    bd_subcommand=$(printf '%s%s' b d)
    extract_shutdown_probe "$probe"

    (
        # The sourced probe calls gc and reads $target; shellcheck cannot see it.
        # shellcheck disable=SC2329
        gc() {
            case "$*" in
                "session list --state=all --json")
                    printf '%s\n' '{"sessions":[{"id":"session-1","name":"demo/gastown.worker","template":"demo/gastown.polecat","rig":"demo","alias":"demo/gastown.worker"}]}'
                    ;;
                "$bd_subcommand --rig demo list --status=in_progress --json --limit=0")
                    printf '%s\n' '[{"id":"demo-b1","assignee":"demo/gastown.worker"}]'
                    ;;
                "$bd_subcommand --rig demo show demo-b1 --json")
                    printf '[{"id":"demo-b1","updated_at":"%s","metadata":{}}]\n' "$updated_at"
                    ;;
                *)
                    return 1
                    ;;
            esac
        }
        # shellcheck disable=SC2034
        target="demo/gastown.worker"
        # shellcheck source=/dev/null
        source "$probe"
    )
}

test_aged_bead_reads_as_no_progress() {
    local output
    output=$(run_probe "$(bead_timestamp 3600)")
    printf '%s\n' "$output" | grep -q '^progress_signal=none$' ||
        fail "a bead untouched for an hour should read progress=none, got: $output"
}

test_recent_bead_reads_as_bead_progress() {
    local output
    output=$(run_probe "$(bead_timestamp 60)")
    printf '%s\n' "$output" | grep -q '^progress_signal=bead$' ||
        fail "a bead touched a minute ago should read progress=bead, got: $output"
}

test_fractional_seconds_parse() {
    local output
    output=$(run_probe "$(bead_timestamp 60 .123456)")
    printf '%s\n' "$output" | grep -q '^progress_signal=bead$' ||
        fail "a fractional-second updated_at should parse and read progress=bead, got: $output"
}

test_unparseable_bead_timestamp_stays_unknown() {
    local output
    output=$(run_probe "not-a-timestamp")
    printf '%s\n' "$output" | grep -q '^progress_signal=unknown$' ||
        fail "an unparseable updated_at should read progress=unknown, got: $output"
}

test_aged_bead_reads_as_no_progress
test_recent_bead_reads_as_bead_progress
test_fractional_seconds_parse
test_unparseable_bead_timestamp_stays_unknown

echo "shutdown progress probe date tests passed"
