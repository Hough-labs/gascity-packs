#!/usr/bin/env bash
# test_dolt_push_state_check.sh — regression tests for the auto-push outage
# detector (gastown/assets/scripts/dolt-push-state-check.sh).
#
# The detector's whole difficulty is the false positive, and there are TWO of
# them. Both negative tests replay real measured traces rather than invented
# ones, because both false positives look perfectly reasonable in the abstract.
#
#   1. THE DEBOUNCE TROUGH (test 1). Auto-push debounces on
#      `dolt.auto-push-interval`, so a HEALTHY store sits with
#      `last_commit != head` for up to a full interval on every sawtooth trough.
#      Replays winnow 14:08-14:15, sampled once a minute on a recovered store
#      with no manual push, and requires silence across all eight samples. A
#      naive "alert when last_commit != head" check fires on six of them.
#
#   2. THE LYING WATERMARK (test 2b, gcp-llja). bd records auto-push FAILURE
#      whenever its `dolt.auto-push-timeout` fires — including on pushes that
#      complete server-side moments later — so `last_commit` freezes
#      permanently on any store whose pushes outrun that timer, while the remote
#      keeps advancing. Replays winnow 00:16-00:56, where the watermark sat
#      frozen for 40 minutes as remotes/origin/main moved in lockstep with
#      last_push. A watermark-only check calls that an 1845s outage and pages
#      CRITICAL forever. The fix is to decide from the remote's actual position;
#      test 2c pins that the verdict turns on the remote and nothing else.
#
# Run: bash gastown/tests/test_dolt_push_state_check.sh
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
SCRIPT="$ROOT/gastown/assets/scripts/dolt-push-state-check.sh"

PASS=0
FAIL=0
# FAIL count as of the last verdict. `pass` reports only when nothing has
# tripped since — otherwise a test that failed four assertions still prints an
# "ok:" line underneath them, which is the same class of misleading green this
# suite exists to prevent. Keeping the gate inside `pass` means every test gets
# it, including ones added later that forget to ask for it.
LAST_VERDICT_FAIL=0

fail() {
    echo "FAIL: $*" >&2
    FAIL=$((FAIL + 1))
}

pass() {
    if [ "$FAIL" -ne "$LAST_VERDICT_FAIL" ]; then
        LAST_VERDICT_FAIL="$FAIL"
        return 0
    fi
    echo "  ok: $*"
    PASS=$((PASS + 1))
}

# ── Harness ──────────────────────────────────────────────────────────────────
# A stub `gc` answers the only two calls the detector makes:
#   gc rig list --json          -> $GC_RIGS_JSON
#   gc bd sql -C <path> --json  -> $GC_SQL_DIR/<basename of path>.json
# The detector issues TWO distinct queries per suspicious scope — the watermark
# sweep against dolt_log, then the ground-truth read of the remote tracking ref
# out of dolt_remote_branches — so the stub dispatches on the query text and
# serves `<name>.remote.json` for the second. A scope with no `.remote.json`
# fixture has never had its remote consulted, which is itself an assertion:
# the healthy path must not pay for the extra round trip.
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
        query=""
        for arg in "$@"; do
            [ "$prev" = "-C" ] && scope="$arg"
            case "$arg" in *dolt_log*|*dolt_remote_branches*) query="$arg" ;; esac
            prev="$arg"
        done
        [ -n "$scope" ] || { echo "stub gc bd sql called without -C" >&2; exit 9; }
        suffix=""
        case "$query" in *dolt_remote_branches*) suffix=".remote" ;; esac
        result="$GC_SQL_DIR/$(basename "$scope")$suffix.json"
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

# store_result <sql-dir> <name> <watermark_found> <unpushed> <age> [branch]
# Stands in for what the scope's own dolt_log reports, measured against the
# push-state watermark. An empty age emits SQL NULL, which is what a converged
# store returns for MIN(date) over no rows.
store_result() {
    local dir="$1" name="$2" found="$3" unpushed="$4" age="${5:-}" branch="${6:-main}"
    mkdir -p "$dir"
    cat >"$dir/$name.json" <<JSON
[
  {
    "branch": "$branch",
    "watermark_found": $found,
    "unpushed_count": $unpushed,
    "oldest_unpushed_age_s": ${age:-null}
  }
]
JSON
}

# remote_result <sql-dir> <name> <remote_hash> <head_found> <unpushed> <age>
# Stands in for where remotes/origin/<branch> ACTUALLY is — the ground truth the
# detector consults before alerting. unpushed=0 means the remote is at local
# head, i.e. pushes are landing whatever push-state claims.
remote_result() {
    local dir="$1" name="$2" hash="$3" found="$4" unpushed="$5" age="${6:-}"
    mkdir -p "$dir"
    cat >"$dir/$name.remote.json" <<JSON
[
  {
    "remote_hash": "$hash",
    "remote_head_found": $found,
    "remote_unpushed_count": $unpushed,
    "remote_unpushed_age_s": ${age:-null}
  }
]
JSON
}

# no_remote_ref <sql-dir> <name> — the store has no such tracking ref at all;
# Dolt returns an empty result set.
no_remote_ref() {
    mkdir -p "$1"
    printf '[]\n' >"$1/$2.remote.json"
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

# ── 2. A genuinely-behind remote past the threshold MUST fire ────────────────
# The winnow outage shape: `last_push` keeps advancing while `last_commit` stays
# put, so unpushed commits pile up and the oldest ages without bound — and the
# remote ref is stuck right alongside, because the pushes really are failing.
test_sustained_divergence_fires() {
    local city="$SCRATCH/outage" sql="$SCRATCH/outage-sql" rigs="$SCRATCH/outage-rigs.json"
    local log="$SCRATCH/outage-argv.log"
    mkdir -p "$city"
    make_scope "$city" winnow "v7369kk5kh68bo5lv6ctal41bhppdnpf"
    rigs_json "$city" winnow >"$rigs"
    store_result "$sql" winnow 1 412 64800   # 18h frozen, the real outage duration
    # The remote never moved either — a real outage, not a lying watermark.
    remote_result "$sql" winnow "v7369kk5kh68bo5lv6ctal41bhppdnpf" 1 412 64800

    local out
    out=$(run_check "$city" "$sql" "$rigs" "$log")
    [ "$(verdict_for "$out" winnow)" = "STALE" ] ||
        fail "an 18h-behind remote did not report STALE"
    printf '%s' "$out" | jq -e 'select(.scope=="winnow") | .detail | test("v7369kk5kh68bo5lv6ctal41bhppdnpf")' >/dev/null ||
        fail "the STALE alert does not name the frozen commit"
    printf '%s' "$out" | jq -e 'select(.scope=="winnow") | .oldest_unpushed_age_s == 64800' >/dev/null ||
        fail "the STALE alert does not carry the measured age"
    pass "sustained divergence (18h behind remote) reports STALE and names the frozen commit"

    # Just below the line stays quiet: the boundary is >= threshold, not >. The
    # 899s case never reaches the remote query — the cheap filter answers it.
    store_result "$sql" winnow 1 3 899
    out=$(run_check "$city" "$sql" "$rigs" "$log")
    [ "$(verdict_for "$out" winnow)" = "OK" ] ||
        fail "age 899s (one second under the 900s threshold) wrongly fired"
    store_result "$sql" winnow 1 3 900
    remote_result "$sql" winnow "v7369kk5kh68bo5lv6ctal41bhppdnpf" 1 3 900
    out=$(run_check "$city" "$sql" "$rigs" "$log")
    [ "$(verdict_for "$out" winnow)" = "STALE" ] ||
        fail "age 900s (exactly the threshold) did not fire"
    pass "threshold boundary is exact: 899s OK, 900s STALE"
}

# ── 2b. A frozen watermark over an ADVANCING remote must NOT fire ────────────
# THE FALSE POSITIVE THIS CHECK EXISTS TO AVOID (gcp-llja).
#
# bd wraps auto-push in `dolt.auto-push-timeout` (default 30s) and takes the
# failure path when it fires — recording last_push but NOT last_commit — even
# though the push completes server-side afterwards. On winnow a routine push of
# a ~7min backlog measured 41s against that 30s timeout, so essentially every
# cycle recorded failure and the watermark froze permanently.
#
# Measured on winnow, 2026-08-14 00:16-00:56 UTC. last_commit frozen at
# fqvpipur… (dated 00:16:02) for 40 minutes across every sample, while the
# remote advanced on its own, unaided, in lockstep with last_push:
#
#   sample    last_push  remote_head  local_head
#   00:48:41  00:45:20   4o9gc4ck…    dlnl2o5o…
#   00:49:55  00:45:20   4o9gc4ck…    hdh653nh…
#   00:51:14  00:50:57   755lvh7f…    luf5m0rd…
#   00:52:31  00:50:57   755lvh7f…    p01ltfgu…
#
# The watermark-only check reported STALE 1845 900 "auto-push not landing: 135
# commit(s) unpushed" at that exact moment. It was false — the data was on the
# remote, current to within one debounce interval — and it would have paged the
# mayor CRITICAL forever.
test_frozen_watermark_over_live_remote_does_not_fire() {
    local city="$SCRATCH/frozen" sql="$SCRATCH/frozen-sql" rigs="$SCRATCH/frozen-rigs.json"
    local log="$SCRATCH/frozen-argv.log"
    mkdir -p "$city"
    make_scope "$city" winnow "fqvpipurtkajfdpcbgic5dquran54u57"
    rigs_json "$city" winnow >"$rigs"

    # Each sample: watermark age (frozen, growing past 1845s) paired with where
    # the remote actually is. The remote trails local head by at most a debounce
    # interval — commits keep arriving while a push is in flight.
    #   "<watermark_unpushed> <watermark_age> <remote_hash> <remote_unpushed> <remote_age>"
    local samples=(
        "125 1719 4o9gc4ckqjjcvo0dvjnhs4rvgm0mek9j 2 74"
        "129 1793 4o9gc4ckqjjcvo0dvjnhs4rvgm0mek9j 4 148"
        "133 1872 755lvh7f3f4pbn8vknv5okrn6ho9vejh 1 17"
        "135 1949 755lvh7f3f4pbn8vknv5okrn6ho9vejh 3 94"
    )
    local sample fired=0
    for sample in "${samples[@]}"; do
        # shellcheck disable=SC2086
        set -- $sample
        : >"$log"
        store_result "$sql" winnow 1 "$1" "$2"
        remote_result "$sql" winnow "$3" 1 "$4" "$5"
        local out v
        out=$(run_check "$city" "$sql" "$rigs" "$log")
        v=$(verdict_for "$out" winnow)
        [ "$v" = "FROZEN" ] || { fired=1; fail "frozen-watermark sample (watermark age $2, remote age $5) reported $v, want FROZEN"; }
    done
    [ "$fired" -eq 0 ] &&
        pass "a frozen watermark over a remote that is current reports FROZEN, never STALE"

    # The alert-worthy fact must be legible: the remote's position, and that bd
    # is the thing that is broken here — not the push path.
    store_result "$sql" winnow 1 135 1845
    remote_result "$sql" winnow "755lvh7f3f4pbn8vknv5okrn6ho9vejh" 1 0 ""
    local out
    out=$(run_check "$city" "$sql" "$rigs" "$log")
    [ "$(verdict_for "$out" winnow)" = "FROZEN" ] ||
        fail "a remote sitting exactly at local head did not report FROZEN"
    printf '%s' "$out" | jq -e 'select(.scope=="winnow") | .detail | test("755lvh7f3f4pbn8vknv5okrn6ho9vejh")' >/dev/null ||
        fail "the FROZEN record does not name the remote head it verified against"
    printf '%s' "$out" | jq -e 'select(.scope=="winnow") | .detail | test("auto-push-timeout")' >/dev/null ||
        fail "the FROZEN record does not point at the actual cause (bd's auto-push-timeout)"
    ! printf '%s' "$out" | jq -e 'select(.scope=="winnow") | .detail | test("not landing")' >/dev/null ||
        fail "the FROZEN record still claims auto-push is not landing"
    pass "the FROZEN record names the verified remote head and blames bd's watermark, not the push"
}

# ── 2c. The verdict is drawn from the remote, not from watermark heuristics ──
# Same frozen watermark, same age, same everything on disk — only the remote's
# position differs. The verdicts must differ with it. This is what makes the
# distinction structural rather than a guess about how old a watermark is.
test_verdict_follows_the_remote_position() {
    local city="$SCRATCH/pivot" sql="$SCRATCH/pivot-sql" rigs="$SCRATCH/pivot-rigs.json"
    local log="$SCRATCH/pivot-argv.log"
    mkdir -p "$city"
    make_scope "$city" liverig "fqvpipurtkajfdpcbgic5dquran54u57"
    make_scope "$city" deadrig "fqvpipurtkajfdpcbgic5dquran54u57"
    rigs_json "$city" liverig deadrig >"$rigs"
    store_result "$sql" liverig 1 135 1845
    store_result "$sql" deadrig 1 135 1845
    remote_result "$sql" liverig "755lvh7f3f4pbn8vknv5okrn6ho9vejh" 1 2 74
    remote_result "$sql" deadrig "fqvpipurtkajfdpcbgic5dquran54u57" 1 135 1845

    local out
    out=$(run_check "$city" "$sql" "$rigs" "$log")
    [ "$(verdict_for "$out" liverig)" = "FROZEN" ] ||
        fail "identical watermarks: the scope whose remote is current did not report FROZEN"
    [ "$(verdict_for "$out" deadrig)" = "STALE" ] ||
        fail "identical watermarks: the scope whose remote is behind did not report STALE"
    printf '%s' "$out" | jq -e 'select(.scope=="deadrig") | .oldest_unpushed_age_s == 1845' >/dev/null ||
        fail "the STALE age is not the remote-derived one"
    pass "identical watermarks yield FROZEN vs STALE purely on the remote's position"
}

# ── 2d. An unverifiable remote is UNKNOWN, never a CRITICAL page ─────────────
# The tracking ref is a local ref: it can be missing (nothing has ever pushed or
# fetched it), name a commit this store does not have (remote ahead/diverged),
# or be unreadable. None of those establish that auto-push has stopped landing,
# and the whole point of this bead is that an unestablished inference must not
# page. They surface as UNKNOWN — a finding the patrol investigates.
test_unverifiable_remote_is_unknown_not_stale() {
    local city="$SCRATCH/noref" sql="$SCRATCH/noref-sql" rigs="$SCRATCH/noref-rigs.json"
    local log="$SCRATCH/noref-argv.log"
    mkdir -p "$city"
    make_scope "$city" norefrig "fqvpipurtkajfdpcbgic5dquran54u57"
    make_scope "$city" aheadrig "fqvpipurtkajfdpcbgic5dquran54u57"
    make_scope "$city" unreadrig "fqvpipurtkajfdpcbgic5dquran54u57"
    rigs_json "$city" norefrig aheadrig unreadrig >"$rigs"
    store_result "$sql" norefrig 1 135 1845
    store_result "$sql" aheadrig 1 135 1845
    store_result "$sql" unreadrig 1 135 1845
    no_remote_ref "$sql" norefrig
    remote_result "$sql" aheadrig "9zzzzzzzzzzzzzzzzzzzzzzzzzzzzzzz" 0 0
    # unreadrig: no .remote.json fixture -> the stub exits non-zero, as an
    # endpoint that dies between the two queries does.

    local out
    out=$(run_check "$city" "$sql" "$rigs" "$log")
    [ "$(verdict_for "$out" norefrig)" = "UNKNOWN" ] ||
        fail "a missing remote tracking ref did not report UNKNOWN"
    [ "$(verdict_for "$out" aheadrig)" = "UNKNOWN" ] ||
        fail "a remote head absent from the local log did not report UNKNOWN"
    [ "$(verdict_for "$out" unreadrig)" = "UNKNOWN" ] ||
        fail "an unreadable remote position did not report UNKNOWN"
    pass "a remote position that cannot be established reports UNKNOWN, never STALE"
}

# ── 2e. The healthy path must not pay for the cross-check ────────────────────
# The remote read is the expensive half (a second round trip per scope), and it
# is only ever justified once the free watermark filter has flagged the scope.
# A store inside the debounce window must be answered without it.
test_healthy_scope_never_queries_the_remote() {
    local city="$SCRATCH/cheap" sql="$SCRATCH/cheap-sql" rigs="$SCRATCH/cheap-rigs.json"
    local log="$SCRATCH/cheap-argv.log"
    mkdir -p "$city"
    make_scope "$city" healthyrig "fqvpipurtkajfdpcbgic5dquran54u57"
    rigs_json "$city" healthyrig >"$rigs"
    store_result "$sql" healthyrig 1 2 140
    remote_result "$sql" healthyrig "755lvh7f3f4pbn8vknv5okrn6ho9vejh" 1 0 ""
    : >"$log"

    local out
    out=$(run_check "$city" "$sql" "$rigs" "$log")
    [ "$(verdict_for "$out" healthyrig)" = "OK" ] ||
        fail "a scope inside the debounce window did not report OK"
    ! grep -F 'dolt_remote_branches' "$log" >/dev/null ||
        fail "the remote was queried for a scope the cheap filter already cleared"
    pass "a scope inside the debounce window is answered without reading the remote"
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
    # fastrig's remote is behind by the same 200s, so the verdict turns purely
    # on the threshold. defaultrig never reaches the remote query.
    remote_result "$sql" fastrig "v7369kk5kh68bo5lv6ctal41bhppdnpf" 1 5 200

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
    remote_result "$sql" winnow "v7369kk5kh68bo5lv6ctal41bhppdnpf" 1 412 64800
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
    remote_result "$sql" goodrig "v7369kk5kh68bo5lv6ctal41bhppdnpf" 1 412 64800

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
test_frozen_watermark_over_live_remote_does_not_fire
test_verdict_follows_the_remote_position
test_unverifiable_remote_is_unknown_not_stale
test_healthy_scope_never_queries_the_remote
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
