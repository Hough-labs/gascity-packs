#!/usr/bin/env bash
# test_dolt_push_state_check.sh — regression tests for the auto-push outage
# detector (gastown/assets/scripts/dolt-push-state-check.sh).
#
# The detector's whole difficulty is the false positive. Auto-push debounces on
# `dolt.auto-push-interval`, so a HEALTHY store sits with `last_commit != head`
# for up to a full interval on every sawtooth trough. The negative test below
# replays a real measured trough (winnow, 14:08-14:15, sampled once a minute on
# a recovered store with no manual push) and requires the check to stay silent
# across all eight samples. A naive "alert when last_commit != head" check fires
# on six of them.
#
# Run: bash gastown/tests/test_dolt_push_state_check.sh
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
SCRIPT="$ROOT/gastown/assets/scripts/dolt-push-state-check.sh"

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

# ── Harness ──────────────────────────────────────────────────────────────────
# A stub `gc` answers the only two calls the detector makes:
#   gc rig list --json          -> $GC_RIGS_JSON
#   gc bd sql -C <path> --json  -> $GC_SQL_DIR/<basename of path>.json
# Every invocation is appended to $GC_ARGV_LOG so tests can assert HOW the store
# was reached — the endpoint-agnostic `-C <scope path>` form, and never
# `gc dolt health`.
write_gc_stub() {
    local bin="$1"
    mkdir -p "$bin"
    cat >"$bin/gc" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$GC_ARGV_LOG"
case "$1" in
    rig)
        cat "$GC_RIGS_JSON"
        ;;
    bd)
        # Locate the -C value; the detector must always scope the query to a path.
        scope=""
        prev=""
        for arg in "$@"; do
            [ "$prev" = "-C" ] && scope="$arg"
            prev="$arg"
        done
        [ -n "$scope" ] || { echo "stub gc bd sql called without -C" >&2; exit 9; }
        result="$GC_SQL_DIR/$(basename "$scope").json"
        if [ -f "$result" ]; then
            cat "$result"
        else
            echo '{"error":"unreachable"}'
            exit 1
        fi
        ;;
    *)
        echo "stub gc: unexpected command $1" >&2
        exit 9
        ;;
esac
SH
    chmod +x "$bin/gc"
}

# make_scope <city-root> <name> [last_commit] [config-body]
# Creates a rig root with a .beads dir. Omit last_commit to skip push-state.json
# entirely (a scope that does not auto-push).
make_scope() {
    local root="$1" name="$2" last_commit="${3:-}" config="${4:-}"
    local dir="$root/$name/.beads"
    mkdir -p "$dir"
    printf '%s\n' "issue_prefix: $name" >"$dir/config.yaml"
    [ -n "$config" ] && printf '%s\n' "$config" >>"$dir/config.yaml"
    if [ -n "$last_commit" ]; then
        cat >"$dir/push-state.json" <<JSON
{
  "last_push": "2026-08-13T18:08:35Z",
  "last_commit": "$last_commit"
}
JSON
    fi
    return 0
}

# rigs_json <city-root> <name>... — the `gc rig list --json` fixture.
rigs_json() {
    local root="$1"
    shift
    local out="{\"rigs\":["
    local sep=""
    for name in "$@"; do
        out+="$sep{\"name\":\"$name\",\"path\":\"$root/$name\",\"suspended\":false}"
        sep=","
    done
    printf '%s]}' "$out"
}

# store_result <sql-dir> <name> <watermark_found> <unpushed> <age>
# Stands in for what the scope's own dolt_log reports. An empty age emits SQL
# NULL, which is what a converged store returns for MIN(date) over no rows.
store_result() {
    local dir="$1" name="$2" found="$3" unpushed="$4" age="${5:-}"
    mkdir -p "$dir"
    cat >"$dir/$name.json" <<JSON
[
  {
    "watermark_found": $found,
    "unpushed_count": $unpushed,
    "oldest_unpushed_age_s": ${age:-null}
  }
]
JSON
}

# run_check <city-root> <sql-dir> <rigs-json-file> <argv-log> — returns the
# detector's JSON-lines output.
run_check() {
    GC_RIGS_JSON="$3" GC_SQL_DIR="$2" GC_ARGV_LOG="$4" PATH="$BIN:$PATH" \
        bash "$SCRIPT" --json
}

verdict_for() {
    printf '%s' "$1" | jq -r --arg s "$2" 'select(.scope == $s) | .verdict'
}

SCRATCH=$(mktemp -d)
trap 'rm -rf "$SCRATCH"' EXIT
BIN="$SCRATCH/bin"
write_gc_stub "$BIN"

# ── 1. The healthy sawtooth trough must NOT fire ─────────────────────────────
# The measured trace, with the store state each sample implies. Auto-push landed
# three times ~5m20s apart (interval 5m); between landings `last_commit` trails
# head, which is normal debounce, not an outage.
#
#   sample  last_push  last_commit  head       unpushed  oldest-unpushed age
#   14:08   14:03:11   ppgaq46k     ms3gscos   1         30s
#   14:09   14:08:35   ms3gscos     ms3gscos   0         -    (converged)
#   14:10   14:08:35   ms3gscos     ms3gscos   0         -    (converged)
#   14:11   14:08:35   ms3gscos     f62i9npv   1         20s
#   14:12   14:08:35   ms3gscos     1f7hvh54   2         80s
#   14:13   14:08:35   ms3gscos     1f7hvh54   2         140s
#   14:14   14:13:55   1f7hvh54     1f7hvh54   0         -    (converged)
#   14:15   14:13:55   1f7hvh54     1f7hvh54   0         -    (converged)
#
# Peak unpushed age across the whole trough is 140s — far under the 900s
# threshold (3 x the 5m interval).
test_healthy_sawtooth_never_fires() {
    local city="$SCRATCH/healthy" sql="$SCRATCH/healthy-sql" rigs="$SCRATCH/healthy-rigs.json"
    local log="$SCRATCH/healthy-argv.log"
    mkdir -p "$city"
    make_scope "$city" winnow "v7369kk5kh68bo5lv6ctal41bhppdnpf"
    rigs_json "$city" winnow >"$rigs"

    # Each sample is "<unpushed_count> <oldest-unpushed age>"; an empty age is a
    # converged sample (MIN(date) over no rows -> SQL NULL).
    local samples=("1 30" "0 " "0 " "1 20" "2 80" "2 140" "0 " "0 ")
    local sample fired=0
    for sample in "${samples[@]}"; do
        local unpushed="${sample%% *}" age="${sample#* }"
        : >"$log"
        store_result "$sql" winnow 1 "$unpushed" "$age"
        local out v
        out=$(run_check "$city" "$sql" "$rigs" "$log")
        v=$(verdict_for "$out" winnow)
        [ "$v" = "OK" ] || { fired=1; fail "healthy trough sample (unpushed=$unpushed age=${age:-0}) reported $v, want OK"; }
    done
    [ "$fired" -eq 0 ] && pass "healthy 14:08-14:15 sawtooth trough stays silent across all 8 samples"
}

# ── 2. A frozen watermark past the threshold MUST fire ───────────────────────
# The winnow outage shape: `last_push` keeps advancing while `last_commit` stays
# put, so unpushed commits pile up and the oldest ages without bound.
test_sustained_divergence_fires() {
    local city="$SCRATCH/outage" sql="$SCRATCH/outage-sql" rigs="$SCRATCH/outage-rigs.json"
    local log="$SCRATCH/outage-argv.log"
    mkdir -p "$city"
    make_scope "$city" winnow "v7369kk5kh68bo5lv6ctal41bhppdnpf"
    rigs_json "$city" winnow >"$rigs"
    store_result "$sql" winnow 1 412 64800   # 18h frozen, the real outage duration

    local out
    out=$(run_check "$city" "$sql" "$rigs" "$log")
    [ "$(verdict_for "$out" winnow)" = "STALE" ] ||
        fail "an 18h-frozen last_commit did not report STALE"
    printf '%s' "$out" | jq -e 'select(.scope=="winnow") | .detail | test("v7369kk5kh68bo5lv6ctal41bhppdnpf")' >/dev/null ||
        fail "the STALE alert does not name the frozen commit"
    printf '%s' "$out" | jq -e 'select(.scope=="winnow") | .oldest_unpushed_age_s == 64800' >/dev/null ||
        fail "the STALE alert does not carry the measured age"
    pass "sustained divergence (18h frozen watermark) reports STALE and names the frozen commit"

    # Just below the line stays quiet: the boundary is >= threshold, not >.
    store_result "$sql" winnow 1 3 899
    out=$(run_check "$city" "$sql" "$rigs" "$log")
    [ "$(verdict_for "$out" winnow)" = "OK" ] ||
        fail "age 899s (one second under the 900s threshold) wrongly fired"
    store_result "$sql" winnow 1 3 900
    out=$(run_check "$city" "$sql" "$rigs" "$log")
    [ "$(verdict_for "$out" winnow)" = "STALE" ] ||
        fail "age 900s (exactly the threshold) did not fire"
    pass "threshold boundary is exact: 899s OK, 900s STALE"
}

# ── 3. The interval comes from config, never hardcoded ───────────────────────
# Same 200s age, two scopes: one with a 1m interval (threshold 180s -> STALE),
# one on the 5m default (threshold 900s -> OK). A hardcoded 5m would miss the
# first; a hardcoded 1m would false-positive the second.
test_interval_is_read_from_config() {
    local city="$SCRATCH/interval" sql="$SCRATCH/interval-sql" rigs="$SCRATCH/interval-rigs.json"
    local log="$SCRATCH/interval-argv.log"
    mkdir -p "$city"
    make_scope "$city" fastrig "v7369kk5kh68bo5lv6ctal41bhppdnpf" "dolt.auto-push-interval: 1m"
    make_scope "$city" defaultrig "v7369kk5kh68bo5lv6ctal41bhppdnpf"
    rigs_json "$city" fastrig defaultrig >"$rigs"
    store_result "$sql" fastrig 1 5 200
    store_result "$sql" defaultrig 1 5 200

    local out
    out=$(run_check "$city" "$sql" "$rigs" "$log")
    [ "$(verdict_for "$out" fastrig)" = "STALE" ] ||
        fail "200s under a configured 1m interval (threshold 180s) did not fire"
    [ "$(verdict_for "$out" defaultrig)" = "OK" ] ||
        fail "200s under the default 5m interval (threshold 900s) wrongly fired"
    printf '%s' "$out" | jq -e 'select(.scope=="fastrig") | .threshold_s == 180' >/dev/null ||
        fail "configured 1m interval did not yield a 180s threshold"
    pass "threshold tracks the configured dolt.auto-push-interval, not a hardcoded 5m"

    # The nested YAML spelling must resolve identically to the flat dotted one.
    local city2="$SCRATCH/interval2" rigs2="$SCRATCH/interval2-rigs.json"
    mkdir -p "$city2"
    make_scope "$city2" fastrig "v7369kk5kh68bo5lv6ctal41bhppdnpf" "$(printf 'dolt:\n  auto-push-interval: 1m')"
    rigs_json "$city2" fastrig >"$rigs2"
    out=$(GC_RIGS_JSON="$rigs2" GC_SQL_DIR="$sql" GC_ARGV_LOG="$log" PATH="$BIN:$PATH" bash "$SCRIPT" --json)
    printf '%s' "$out" | jq -e 'select(.scope=="fastrig") | .threshold_s == 180' >/dev/null ||
        fail "nested 'dolt:/auto-push-interval' spelling was not honoured"
    pass "nested and flat dotted config spellings both resolve the interval"
}

# ── 4. Explicit-endpoint rigs are covered, and gc dolt health is never used ──
# The 18h outage happened on a rig pinned to its OWN endpoint (:3307), which
# `gc dolt health` structurally cannot see. The detector must reach every scope
# through `gc bd sql -C <scope path>`, which resolves that scope's own
# .beads/config.yaml — and must never route through the managed-server view.
test_reaches_each_scope_by_its_own_path() {
    local city="$SCRATCH/endpoint" sql="$SCRATCH/endpoint-sql" rigs="$SCRATCH/endpoint-rigs.json"
    local log="$SCRATCH/endpoint-argv.log"
    mkdir -p "$city"
    # An explicitly-pinned rig, exactly as winnow is configured.
    make_scope "$city" winnow "v7369kk5kh68bo5lv6ctal41bhppdnpf" \
        "$(printf 'gc.endpoint_origin: explicit\ndolt.host: 127.0.0.1\ndolt.port: 3307')"
    rigs_json "$city" winnow >"$rigs"
    store_result "$sql" winnow 1 412 64800
    : >"$log"

    local out
    out=$(run_check "$city" "$sql" "$rigs" "$log")
    [ "$(verdict_for "$out" winnow)" = "STALE" ] ||
        fail "an explicit-endpoint rig was not evaluated"
    grep -F -- "-C $city/winnow" "$log" >/dev/null ||
        fail "the store was not queried through its own scope path (-C)"
    ! grep -E 'dolt (health|sync)' "$log" >/dev/null ||
        fail "the detector routed through gc dolt health/sync — endpoint-blind for explicit rigs"
    pass "explicit-endpoint rig is reached via 'gc bd sql -C <scope path>', not gc dolt health"
}

# ── 5. Scopes that do not auto-push are skipped, not alerted ────────────────
test_non_autopush_scopes_are_skipped() {
    local city="$SCRATCH/skip" sql="$SCRATCH/skip-sql" rigs="$SCRATCH/skip-rigs.json"
    local log="$SCRATCH/skip-argv.log"
    mkdir -p "$city"
    make_scope "$city" nopush ""            # no push-state.json at all
    make_scope "$city" turnedoff "v7369kk5kh68bo5lv6ctal41bhppdnpf" "dolt.auto-push: false"
    rigs_json "$city" nopush turnedoff >"$rigs"
    store_result "$sql" turnedoff 1 999 99999

    local out
    out=$(run_check "$city" "$sql" "$rigs" "$log")
    [ "$(verdict_for "$out" nopush)" = "SKIP" ] ||
        fail "a scope with no push-state.json was not skipped"
    [ "$(verdict_for "$out" turnedoff)" = "SKIP" ] ||
        fail "a scope with dolt.auto-push disabled was not skipped despite a stale state file"
    pass "scopes that do not auto-push are skipped, not alerted"
}

# ── 6. Unreadable stores are reported, never silently read as healthy ───────
# The failure this guards: an absent or unmatched signal reported as OK is what
# let the original outage look healthy for 18h.
test_unreadable_store_is_unknown_not_ok() {
    local city="$SCRATCH/unknown" sql="$SCRATCH/unknown-sql" rigs="$SCRATCH/unknown-rigs.json"
    local log="$SCRATCH/unknown-argv.log"
    mkdir -p "$city"
    make_scope "$city" downrig "v7369kk5kh68bo5lv6ctal41bhppdnpf"
    make_scope "$city" ghostrig "v7369kk5kh68bo5lv6ctal41bhppdnpf"
    rigs_json "$city" downrig ghostrig >"$rigs"
    # downrig: no fixture -> the stub exits non-zero, as an unreachable store does.
    store_result "$sql" ghostrig 0 0        # watermark absent from this store's log

    local out
    out=$(run_check "$city" "$sql" "$rigs" "$log")
    [ "$(verdict_for "$out" downrig)" = "UNKNOWN" ] ||
        fail "an unreachable store was not reported UNKNOWN"
    [ "$(verdict_for "$out" ghostrig)" = "UNKNOWN" ] ||
        fail "a last_commit absent from the store's log was not reported UNKNOWN"
    pass "unreachable store and missing watermark both report UNKNOWN, never OK"
}

# ── 7. One bad scope must not abort the sweep ───────────────────────────────
test_sweep_continues_past_a_bad_scope() {
    local city="$SCRATCH/sweep" sql="$SCRATCH/sweep-sql" rigs="$SCRATCH/sweep-rigs.json"
    local log="$SCRATCH/sweep-argv.log"
    mkdir -p "$city"
    make_scope "$city" downrig "v7369kk5kh68bo5lv6ctal41bhppdnpf"
    make_scope "$city" badhash "not-a-valid-dolt-hash"
    make_scope "$city" goodrig "v7369kk5kh68bo5lv6ctal41bhppdnpf"
    rigs_json "$city" downrig badhash goodrig >"$rigs"
    store_result "$sql" goodrig 1 412 64800

    local out rc=0
    out=$(run_check "$city" "$sql" "$rigs" "$log") || rc=$?
    [ "$rc" -eq 0 ] || fail "the sweep exited $rc instead of completing"
    [ "$(verdict_for "$out" badhash)" = "UNKNOWN" ] ||
        fail "a malformed last_commit was not reported UNKNOWN"
    [ "$(verdict_for "$out" goodrig)" = "STALE" ] ||
        fail "a later scope was not evaluated after earlier bad scopes"
    [ "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" = "3" ] ||
        fail "expected one verdict per scope"
    pass "a bad scope is reported and the sweep continues to the remaining scopes"
}

test_healthy_sawtooth_never_fires
test_sustained_divergence_fires
test_interval_is_read_from_config
test_reaches_each_scope_by_its_own_path
test_non_autopush_scopes_are_skipped
test_unreadable_store_is_unknown_not_ok
test_sweep_continues_past_a_bad_scope

echo
if [ "$FAIL" -gt 0 ]; then
    echo "dolt push-state check tests: $PASS passed, $FAIL FAILED" >&2
    exit 1
fi
echo "dolt push-state check tests passed ($PASS assertions)"
