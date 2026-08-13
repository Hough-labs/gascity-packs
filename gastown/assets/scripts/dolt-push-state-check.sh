#!/usr/bin/env bash
# dolt-push-state-check.sh — detect Dolt auto-push outages from push-state drift.
#
# The gap this closes: `bd` DOES warn when auto-push fails, but only when it is
# neither quiet nor `--json` — and gc drives every bead WRITE through beads with
# exactly that flag. So the caller class performing essentially all writes is
# exactly the class that cannot see the warning. On 2026-08-12 a winnow auto-push
# outage ran ~18h with nothing in the city noticing.
#
# Why not `gc dolt health`: that command observes the MANAGED city server only.
# The rig that went dark (winnow) is pinned to an EXPLICIT endpoint (:3307, not
# the managed :51160), so a health-routed check is structurally blind to it.
# Everything here goes through `gc bd sql -C <scope-path>`, which resolves each
# scope's OWN endpoint from that scope's .beads/config.yaml — managed, inherited
# and explicit alike.
#
# THE SIGNAL — divergence that FAILS TO CONVERGE, not divergence itself.
#
# `bd` writes .beads/push-state.json per scope:
#     { "last_push": "...", "last_commit": "<dolt hash>" }
# On success it records both. On FAILURE it deliberately records last_push but
# NOT last_commit, so change-detection still fires once the remote recovers.
# That asymmetry is the free signal: during an outage last_push keeps advancing
# while last_commit stays frozen behind the store head.
#
# But `last_commit != head` is NOT an alertable condition. Auto-push debounces on
# `dolt.auto-push-interval` (default 5m), so on a perfectly HEALTHY store
# last_commit trails head for up to a full interval on every sawtooth trough —
# a naive "alert when last_commit != head" check fires on a store that is working
# correctly. What distinguishes an outage is that the trough never drains.
#
# So the measured quantity is the AGE OF THE OLDEST UNPUSHED COMMIT: the commit
# that has been waiting longest for a push that never came. On a healthy store
# that age is bounded by one debounce interval; during an outage it grows without
# bound. Alert at >= multiplier (default 3) x the configured interval.
#
# Measuring the oldest unpushed commit — rather than "how long ago was
# last_commit written" — is also what keeps a long-idle store from
# false-positiving: when a first commit lands after hours of quiet, the age
# starts at ~0 and only crosses the threshold if pushes genuinely stop landing.
#
# Verdicts (one record per scope, on stdout):
#   OK      converged, or diverged but still inside the debounce window
#   STALE   sustained divergence >= threshold — THE ALERT
#   SKIP    scope does not auto-push (no push-state.json, or auto-push disabled)
#   UNKNOWN store unreadable, or last_commit absent from this store's log
#
# Env:
#   GC_PUSH_STALE_MULTIPLIER  threshold multiple of the interval (default 3)
#   GC_PUSH_DEFAULT_INTERVAL  fallback interval seconds when unconfigured (300)
#
# Usage:
#   dolt-push-state-check.sh            # TSV: scope verdict age_s threshold_s detail
#   dolt-push-state-check.sh --json     # one JSON object per scope, per line
#   dolt-push-state-check.sh --snapshot # sweep + write $GC_CITY/.gc/runtime/dolt-push-state.json
#
# --snapshot exists because pack assets install into a content-hashed cache
# directory that a formula step cannot name — `{{.ConfigDir}}` in agent.toml is
# the only stable handle on this file. So the deacon's `pre_start` runs
# --snapshot, and the snapshot records this script's own resolved path under
# `script_path`. The patrol step reads that path back and re-runs the sweep
# itself, so each patrol cycle alerts on a FRESH measurement rather than on a
# reading taken once at session start.
#
# Exit: 0 when the sweep ran (verdicts are in the output, including STALE);
#       2 on a usage or environment error. A STALE scope is a finding to be
#       read out of the output, not a crash — one bad rig must not abort the
#       sweep over the others.

set -euo pipefail

SELF=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")

JSON=0
SNAPSHOT=0
case "${1:-}" in
  --json) JSON=1 ;;
  --snapshot) SNAPSHOT=1; JSON=1 ;;
  "") ;;
  *)
    echo "dolt-push-state-check: unknown argument '$1' (expected --json or --snapshot)" >&2
    exit 2
    ;;
esac

# --snapshot needs the city root to place its output. Env wins; otherwise walk
# up from cwd for city.toml, the same discovery the churn watcher uses.
if [ "$SNAPSHOT" -eq 1 ]; then
  if [ -z "${GC_CITY:-}" ]; then
    dir=$(pwd)
    while [ "$dir" != "/" ]; do
      if [ -f "$dir/city.toml" ]; then
        GC_CITY="$dir"
        break
      fi
      dir=$(dirname "$dir")
    done
  fi
  if [ -z "${GC_CITY:-}" ] || [ ! -f "$GC_CITY/city.toml" ]; then
    echo "dolt-push-state-check: --snapshot needs GC_CITY (no city.toml found)" >&2
    exit 2
  fi
  SNAPSHOT_FILE="${GC_PUSH_SNAPSHOT_FILE:-$GC_CITY/.gc/runtime/dolt-push-state.json}"
  mkdir -p "$(dirname "$SNAPSHOT_FILE")"
fi

MULTIPLIER="${GC_PUSH_STALE_MULTIPLIER:-3}"
DEFAULT_INTERVAL="${GC_PUSH_DEFAULT_INTERVAL:-300}"

# Dolt commit hashes are 32 base32 chars. Validated before interpolation: the
# value comes off disk, and it lands inside a SQL string literal.
HASH_RE='^[0-9a-z]{32}$'

# parse_duration <value> — Go-style duration ("5m", "300s", "2h") or bare
# seconds, to seconds. Echoes nothing when unparseable so the caller can fall
# back rather than silently threshold on garbage.
parse_duration() {
  local v="$1" num unit
  v="${v//[[:space:]]/}"
  [ -n "$v" ] || return 0
  if [[ "$v" =~ ^([0-9]+)([smh]?)$ ]]; then
    num="${BASH_REMATCH[1]}"
    unit="${BASH_REMATCH[2]}"
    case "$unit" in
      h) echo $((num * 3600)) ;;
      m) echo $((num * 60)) ;;
      *) echo "$num" ;;
    esac
  fi
}

# config_value <config.yaml> <key> — read a scalar out of a .beads config,
# tolerating both the flat dotted form (`dolt.auto-push-interval: 5m`) and the
# nested form (`dolt:` / `  auto-push-interval: 5m`). Both spellings appear in
# real configs in the same file, so keying on the leaf name covers both. The
# key must be followed by a colon, which is what keeps `auto-push` from
# matching `auto-push-interval`.
config_value() {
  local cfg="$1" key="$2" out=""
  [ -f "$cfg" ] || return 0
  # `|| true`: an unmatched key is the common case, and grep's exit 1 under
  # `set -o pipefail` would otherwise take the whole sweep down.
  out=$(sed -e 's/#.*$//' "$cfg" \
    | grep -E "(^|[.[:space:]])${key}[[:space:]]*:" \
    | head -1 \
    | sed -E "s/.*${key}[[:space:]]*:[[:space:]]*//" \
    | tr -d '"'\''\r' \
    | sed -e 's/[[:space:]]*$//' || true)
  printf '%s' "$out"
}

emit() {
  local scope="$1" verdict="$2" age="$3" threshold="$4" detail="$5"
  if [ "$JSON" -eq 1 ]; then
    jq -cn \
      --arg scope "$scope" --arg verdict "$verdict" --arg detail "$detail" \
      --argjson age "${age:-null}" --argjson threshold "${threshold:-null}" \
      '{scope:$scope, verdict:$verdict, oldest_unpushed_age_s:$age, threshold_s:$threshold, detail:$detail}'
  else
    printf '%s\t%s\t%s\t%s\t%s\n' "$scope" "$verdict" "${age:-null}" "${threshold:-null}" "$detail"
  fi
}

RIGS_JSON=$(gc rig list --json 2>/dev/null || true)
if ! printf '%s' "$RIGS_JSON" | jq -e '.rigs | type == "array"' >/dev/null 2>&1; then
  echo "dolt-push-state-check: could not enumerate rigs via 'gc rig list --json'" >&2
  exit 2
fi

# Every scope with its own ledger — the city (the hq rig) and each rig. Suspended
# rigs are skipped: they are not writing beads, so a frozen watermark there is
# expected rather than a finding.
sweep() {
  while IFS=$'\t' read -r NAME PATH_; do
    [ -n "$NAME" ] || continue

    BEADS_DIR="$PATH_/.beads"
    STATE_FILE="$BEADS_DIR/push-state.json"
    CONFIG="$BEADS_DIR/config.yaml"

    # No push-state file means auto-push has never run here — nothing to measure.
    if [ ! -f "$STATE_FILE" ]; then
      emit "$NAME" SKIP "" "" "no push-state.json (scope does not auto-push)"
      continue
    fi

    # An explicit `dolt.auto-push: false` with a lingering state file is a scope
    # that USED to auto-push. Its watermark is frozen by design, not by failure.
    if [ "$(config_value "$CONFIG" 'auto-push')" = "false" ]; then
      emit "$NAME" SKIP "" "" "dolt.auto-push disabled (stale push-state.json)"
      continue
    fi

    LAST_PUSH=$(jq -r '.last_push // ""' "$STATE_FILE" 2>/dev/null || echo "")
    LAST_COMMIT=$(jq -r '.last_commit // ""' "$STATE_FILE" 2>/dev/null || echo "")

    INTERVAL=$(parse_duration "$(config_value "$CONFIG" 'auto-push-interval')")
    [ -n "$INTERVAL" ] || INTERVAL="$DEFAULT_INTERVAL"
    THRESHOLD=$((INTERVAL * MULTIPLIER))

    # The watermark clause. With a recorded last_commit, "unpushed" means every
    # commit newer than it. With NO last_commit, push-state exists only because a
    # push ran and failed before ever recording one — so nothing in this store has
    # been confirmed pushed, and the whole log is unpushed. A genuinely new store
    # hits that branch too, and correctly stays OK: its oldest commit is recent.
    if [ -n "$LAST_COMMIT" ]; then
      if ! [[ "$LAST_COMMIT" =~ $HASH_RE ]]; then
        emit "$NAME" UNKNOWN "" "$THRESHOLD" "malformed last_commit in push-state.json"
        continue
      fi
      WATERMARK="(SELECT date FROM dolt_log WHERE commit_hash = '$LAST_COMMIT')"
      UNPUSHED_WHERE="date > $WATERMARK"
      FOUND_EXPR="(SELECT COUNT(*) FROM dolt_log WHERE commit_hash = '$LAST_COMMIT')"
    else
      UNPUSHED_WHERE="1 = 1"
      FOUND_EXPR="1"
    fi

    # UTC_TIMESTAMP(), not NOW(): dolt_log.date is UTC while NOW() is server-local,
    # and mixing them yields an age off by the server's UTC offset (negative ages
    # west of Greenwich). The comparison stays server-side so it is the same clock
    # that wrote the commit dates.
    QUERY="SELECT
      $FOUND_EXPR AS watermark_found,
      (SELECT COUNT(*) FROM dolt_log WHERE $UNPUSHED_WHERE) AS unpushed_count,
      TIMESTAMPDIFF(SECOND,
        (SELECT MIN(date) FROM dolt_log WHERE $UNPUSHED_WHERE),
        UTC_TIMESTAMP()) AS oldest_unpushed_age_s"

    if ! RESULT=$(gc bd sql -C "$PATH_" --json "$QUERY" 2>/dev/null); then
      emit "$NAME" UNKNOWN "" "$THRESHOLD" "store unreachable at its own endpoint"
      continue
    fi

    FOUND=$(printf '%s' "$RESULT" | jq -r 'if type == "array" then .[0].watermark_found else empty end' 2>/dev/null || echo "")
    UNPUSHED=$(printf '%s' "$RESULT" | jq -r 'if type == "array" then .[0].unpushed_count else empty end' 2>/dev/null || echo "")
    AGE=$(printf '%s' "$RESULT" | jq -r 'if type == "array" then (.[0].oldest_unpushed_age_s // empty) else empty end' 2>/dev/null || echo "")

    # Numeric-guard before any arithmetic test: a non-numeric here would abort the
    # whole sweep under `set -e` rather than reporting one bad scope.
    if ! [[ "$FOUND" =~ ^[0-9]+$ ]] || ! [[ "$UNPUSHED" =~ ^[0-9]+$ ]]; then
      emit "$NAME" UNKNOWN "" "$THRESHOLD" "unreadable dolt_log result"
      continue
    fi

    # last_commit names a commit this store has never heard of — the watermark and
    # the ledger have diverged in a way the age math cannot describe. Report it
    # rather than reading the empty result as convergence.
    if [ "$FOUND" -eq 0 ]; then
      emit "$NAME" UNKNOWN "" "$THRESHOLD" "last_commit $LAST_COMMIT not present in this store's dolt_log"
      continue
    fi

    if [ "$UNPUSHED" -eq 0 ]; then
      emit "$NAME" OK 0 "$THRESHOLD" "converged (last_commit is head)"
      continue
    fi

    if ! [[ "$AGE" =~ ^-?[0-9]+$ ]]; then
      emit "$NAME" UNKNOWN "" "$THRESHOLD" "unpushed commits present but age unreadable"
      continue
    fi

    # A negative age means the oldest unpushed commit is dated in the future
    # relative to the server clock — clock skew, not a push outage. Never alert.
    if [ "$AGE" -lt 0 ]; then
      emit "$NAME" UNKNOWN "$AGE" "$THRESHOLD" "negative age (clock skew between commit dates and server UTC)"
      continue
    fi

    if [ "$AGE" -ge "$THRESHOLD" ]; then
      emit "$NAME" STALE "$AGE" "$THRESHOLD" \
        "auto-push not landing: $UNPUSHED commit(s) unpushed, oldest ${AGE}s >= ${THRESHOLD}s (${MULTIPLIER}x ${INTERVAL}s interval); last_commit frozen at $LAST_COMMIT, last_push $LAST_PUSH"
    else
      emit "$NAME" OK "$AGE" "$THRESHOLD" \
        "diverged but inside the debounce window: $UNPUSHED commit(s) unpushed, oldest ${AGE}s < ${THRESHOLD}s"
    fi
  done < <(printf '%s' "$RIGS_JSON" | jq -r '.rigs[] | select(.suspended != true) | [.name, .path] | @tsv')
}

OUTPUT=$(sweep)

if [ "$SNAPSHOT" -eq 0 ]; then
  if [ -n "$OUTPUT" ]; then
    printf '%s\n' "$OUTPUT"
  fi
  exit 0
fi

# Snapshot mode. `script_path` is the whole point of the file: it is the handle
# the patrol step uses to re-run this sweep on its own cadence, since it cannot
# name the content-hashed pack cache directory itself.
GENERATED_AT=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
if [ -n "$OUTPUT" ]; then
  printf '%s\n' "$OUTPUT" | jq -s \
    --arg script "$SELF" --arg at "$GENERATED_AT" \
    '{generated_at: $at, script_path: $script, scopes: .}' >"$SNAPSHOT_FILE"
else
  jq -n --arg script "$SELF" --arg at "$GENERATED_AT" \
    '{generated_at: $at, script_path: $script, scopes: []}' >"$SNAPSHOT_FILE"
fi
printf '%s\n' "$SNAPSHOT_FILE"
