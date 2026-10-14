#!/usr/bin/env bash
# lane-wedge.sh — park the refinery's merge lane when the remote refuses a push
# while the target stands still (gcp-ubv2).
#
# merge-push.sh returns status 7 when a push is refused and origin/<target> is
# still where the merge started: a red pre-push gate, a busy slot after the
# wait, a receive hook, or permissions. Nothing the refinery can do clears that,
# and a session that quits with the bead still assigned only has its successor
# re-select the same head, be refused again and quit again. On 2026-10-01 that
# loop restarted feryn's refinery six times in an hour, tripped the session
# circuit breaker, and kept the lane down for 80 minutes.
#
# So the lane is parked instead: a marker records the target and the sha the
# push was refused at, and find-work reads it. While the target stands at that
# sha, find-work takes only beads labelled base-red (a fix for the red target)
# and skips every head already refused. The marker clears when origin/<target>
# moves. The work bead is KEPT: its assignee and status are unchanged, and it
# only gets a note.
#
# Usage (run inside the refinery's clone):
#   lane-wedge.sh mark --work <id> --log <file>
#   lane-wedge.sh check
#
# The marker is $(git rev-parse --absolute-git-dir)/refinery-lane-wedged.json:
#   {"target", "target_sha", "since", "heads": [<id>, ...], "escalation": "sent"|"failed"}
#
# mark   Read the LAST `merge-ff-push: REFUSED target=<T> sha=<S>` line of <file>
#        (the merge-push output). With none, exit 2 and touch nothing. The same
#        target and sha as the marker adds <id> to heads; anything else starts a
#        new marker. Unless the marker already records a sent escalation, mail the
#        mayor ONCE, then note the bead. A failed mail is recorded as
#        escalation=failed and sent again by the next mark at the same sha.
#        Exit 0 once the marker is written, 2 when it cannot be.
#
# check  Print one line and exit:
#          LANE-WEDGE none                                  0  no marker
#          WARN lane-wedge: unreadable marker <M> removed.  0  marker removed
#          LANE-WEDGE cleared <T> <S12> -> <C12>            0  target moved; removed
#          LANE-WEDGE holds <T> <S12> skip=<a,b>            3  target unmoved
#          LANE-WEDGE holds <T> <S12> fetch-failed skip=..  3  fetch failed; kept
#        skip= lists the heads the remote already refused at this sha.
#
# Exit 1 is a usage error. The script never drains the session and never pours
# or burns a patrol wisp: the formula owns the patrol loop.
#
# No `set -e`, `set -u` or `set -o pipefail`: every command that matters is
# checked on its own exit status.

usage() {
  echo "usage: lane-wedge.sh mark --work <id> --log <file> | lane-wedge.sh check" >&2
  return 1
}

# marker_path prints the marker's absolute path, or fails outside a git clone.
marker_path() {
  local gd
  gd=$(git rev-parse --absolute-git-dir 2>/dev/null) || return 1
  printf '%s/refinery-lane-wedged.json\n' "$gd"
}

# marker_valid <file> succeeds when <file> parses as a marker.
marker_valid() {
  jq -e '(.target | type == "string") and (.target_sha | type == "string")
         and (.heads | type == "array")' "$1" >/dev/null 2>&1
}

cmd_mark() {
  local work="" log="" m line t s s12 same stored_esc since heads esc
  local tmp body note heads_csv
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --work) work="${2:-}"; shift 2 || return 1 ;;
      --log) log="${2:-}"; shift 2 || return 1 ;;
      *) usage; return 1 ;;
    esac
  done
  if [ -z "$work" ] || [ -z "$log" ]; then
    usage
    return 1
  fi
  m=$(marker_path) || { echo "lane-wedge: not inside a git clone." >&2; return 1; }

  line=$(grep -E '^merge-ff-push: REFUSED target=[^ ]+ sha=[0-9a-f]+$' "$log" 2>/dev/null | tail -n 1)
  if [ -z "$line" ]; then
    echo "lane-wedge: no 'merge-ff-push: REFUSED' line in $log; marker not written." >&2
    return 2
  fi
  t=${line#*target=}
  t=${t%% *}
  s=${line##* sha=}
  s12=${s:0:12}

  same=0
  stored_esc=""
  since=""
  heads="[]"
  if [ -f "$m" ] && marker_valid "$m" \
    && [ "$(jq -r '.target' "$m")" = "$t" ] && [ "$(jq -r '.target_sha' "$m")" = "$s" ]; then
    same=1
    stored_esc=$(jq -r '.escalation // empty' "$m")
    since=$(jq -r '.since // empty' "$m")
    heads=$(jq -c '.heads' "$m")
  fi
  if [ "$same" -eq 1 ]; then
    heads=$(printf '%s' "$heads" | jq -c --arg w "$work" 'if index($w) then . else . + [$w] end')
  else
    heads=$(jq -nc --arg w "$work" '[$w]')
    since=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  fi
  esc="$stored_esc"

  if [ "$stored_esc" != "sent" ]; then
    body=$(printf '%s\n' \
      "The refinery's push to $t was refused while origin/$t stood still at $s." \
      "Bead: $work" \
      "Target: $t at $s" \
      "The lane is parked: only base-red beads until origin/$t moves." \
      "" \
      "Release: rm $m" \
      "A fix bead that is not labelled base-red lands only after that rm." \
      "" \
      "Push output (last 30 lines):")
    body="$body
$(tail -n 30 "$log")"
    if gc mail send mayor/ --notify \
      -s "ESCALATION: merge lane wedged on ${GC_RIG:+$GC_RIG/}$t at ${s12} [HIGH]" \
      -m "$body"; then
      esc="sent"
    else
      esc="failed"
      echo "WARN lane-wedge: the escalation mail failed; the next mark at $s sends it again." >&2
    fi
  fi

  note="LANE-WEDGED: push to $t refused while origin/$t stood at $s (merge-push status 7). This bead stays assigned to the refinery and is not rejected. It merges on the first patrol after origin/$t moves; until then find-work takes only base-red beads."
  if ! printf '%s\n' "$note" | gc bd note "$work" --stdin; then
    echo "WARN lane-wedge: could not note $work; carrying on." >&2
  fi

  tmp=$(mktemp "$m.XXXXXX") || return 2
  if ! jq -n --arg t "$t" --arg s "$s" --arg since "$since" --argjson heads "$heads" --arg esc "$esc" \
    '{target: $t, target_sha: $s, since: $since, heads: $heads, escalation: $esc}' >"$tmp" \
    || ! mv -f "$tmp" "$m"; then
    rm -f "$tmp"
    echo "lane-wedge: could not write $m." >&2
    return 2
  fi

  heads_csv=$(jq -r '.heads | join(",")' "$m")
  if [ "$same" -eq 1 ]; then
    echo "LANE-WEDGE KNOWN $t $s12 heads=$heads_csv escalation=$esc"
  else
    echo "LANE-WEDGE NEW $t $s12 head=$work escalation=$esc"
  fi
  return 0
}

cmd_check() {
  local m t s s12 skip cur
  [ "$#" -eq 0 ] || { usage; return 1; }
  m=$(marker_path) || { echo "lane-wedge: not inside a git clone." >&2; return 1; }
  if [ ! -f "$m" ]; then
    echo "LANE-WEDGE none"
    return 0
  fi
  if ! marker_valid "$m"; then
    rm -f "$m"
    echo "WARN lane-wedge: unreadable marker $m removed."
    return 0
  fi
  t=$(jq -r '.target' "$m")
  s=$(jq -r '.target_sha' "$m")
  s12=${s:0:12}
  skip=$(jq -r '.heads | join(",")' "$m")
  if ! git fetch origin "+refs/heads/${t}:refs/remotes/origin/${t}" >/dev/null 2>&1 \
    || ! cur=$(git rev-parse "refs/remotes/origin/$t" 2>/dev/null); then
    echo "LANE-WEDGE holds $t $s12 fetch-failed skip=$skip"
    return 3
  fi
  if [ "$cur" != "$s" ]; then
    rm -f "$m"
    echo "LANE-WEDGE cleared $t $s12 -> ${cur:0:12}"
    return 0
  fi
  echo "LANE-WEDGE holds $t $s12 skip=$skip"
  return 3
}

sub="${1:-}"
[ "$#" -gt 0 ] && shift
case "$sub" in
  mark) cmd_mark "$@" ;;
  check) cmd_check "$@" ;;
  *) usage ;;
esac
exit $?
