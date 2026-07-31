#!/usr/bin/env bash
# Producer for the gc-native merge approval signal.
#
# gc has no way to emit a formal GitHub review event, so the refinery had no
# reviewed-merge signal it could read: `merge_strategy=direct` merged unreviewed
# and `mr` published a PR without ever merging. This script is the missing
# producer. A reviewer agent records its verdict on the work bead itself — gc's
# own durable store — keyed to the PR number AND the exact head SHA it reviewed.
#
# The head SHA is what makes the signal safe to consume: an approval names one
# commit, so commits pushed after review do not inherit it. The consumer
# (checks/merge-approval-gate.sh) refuses any signal whose SHA is not the live
# PR head.
#
# Usage:
#   record-merge-approval.sh --bead <id> --pr <number|#number|url> \
#       --sha <40-hex-head-sha> --verdict approved|changes_requested \
#       [--reviewer <identity>]
#
# The reviewer identity defaults to $GC_AGENT, then $BEADS_ACTOR.
#
# Exit codes:
#   0  signal recorded
#   1  bead store write failed (nothing was recorded)
#   2  invalid usage or invalid argument (nothing was recorded)

set -uo pipefail

SELF=$(basename "$0")

usage() {
    cat >&2 <<EOF
usage: $SELF --bead <id> --pr <number|#number|url> --sha <40-hex> \\
           --verdict approved|changes_requested [--reviewer <identity>]
EOF
}

die_usage() {
    echo "ERROR: $*" >&2
    usage
    exit 2
}

BEAD=""
PR_ARG=""
SHA_ARG=""
VERDICT=""
REVIEWER=""

need_value() {
    # $1 = remaining arg count including the flag itself, $2 = flag name
    [ "$1" -ge 2 ] || die_usage "$2 requires a value"
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --bead) need_value "$#" --bead; BEAD="$2"; shift 2 ;;
        --bead=*) BEAD="${1#*=}"; shift ;;
        --pr) need_value "$#" --pr; PR_ARG="$2"; shift 2 ;;
        --pr=*) PR_ARG="${1#*=}"; shift ;;
        --sha) need_value "$#" --sha; SHA_ARG="$2"; shift 2 ;;
        --sha=*) SHA_ARG="${1#*=}"; shift ;;
        --verdict) need_value "$#" --verdict; VERDICT="$2"; shift 2 ;;
        --verdict=*) VERDICT="${1#*=}"; shift ;;
        --reviewer) need_value "$#" --reviewer; REVIEWER="$2"; shift 2 ;;
        --reviewer=*) REVIEWER="${1#*=}"; shift ;;
        -h|--help) usage; exit 0 ;;
        *) die_usage "unknown argument: $1" ;;
    esac
done

[ -n "$BEAD" ] || die_usage "--bead is required"
[ -n "$PR_ARG" ] || die_usage "--pr is required"
[ -n "$SHA_ARG" ] || die_usage "--sha is required"
[ -n "$VERDICT" ] || die_usage "--verdict is required"

# Accept the three shapes a reviewer agent naturally has on hand: a bare
# number, a `#123` reference, or the PR URL the refinery recorded in
# metadata.pr_url. Everything downstream compares plain integers.
PR_NUMBER=$(printf '%s\n' "$PR_ARG" |
    sed -nE 's|^[Hh][Tt][Tt][Pp][Ss]?://[^/]+/[^/]+/[^/]+/pull/([0-9]+)/?$|\1|p; s|^#([0-9]+)$|\1|p; s|^([0-9]+)$|\1|p' |
    head -n 1)
if [[ ! "$PR_NUMBER" =~ ^[1-9][0-9]*$ ]]; then
    die_usage "could not read a pull request number from --pr $PR_ARG"
fi

# Require the full 40-hex object name. An abbreviated SHA cannot be compared for
# equality against the live head the gate reads back from GitHub, and a prefix
# comparison is exactly the kind of near-match that would let a stale approval
# through.
if [[ ! "$SHA_ARG" =~ ^[0-9a-fA-F]{40}$ ]]; then
    die_usage "--sha must be a full 40-character hex commit SHA"
fi
HEAD_SHA=$(printf '%s' "$SHA_ARG" | tr '[:upper:]' '[:lower:]')

case "$VERDICT" in
    approved|changes_requested) ;;
    *) die_usage "--verdict must be approved or changes_requested" ;;
esac

if [ -z "$REVIEWER" ]; then
    REVIEWER="${GC_AGENT:-${BEADS_ACTOR:-}}"
fi
if [ -z "$REVIEWER" ]; then
    die_usage "--reviewer is required when neither GC_AGENT nor BEADS_ACTOR is set"
fi

RECORDED_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)

# One update, five keys. A half-written signal is the dangerous state — a
# verdict without its SHA would read as "approved" to a naive consumer — so the
# whole signal lands atomically or not at all.
if ! gc bd update "$BEAD" \
    --set-metadata merge_approval.verdict="$VERDICT" \
    --set-metadata merge_approval.pr_number="$PR_NUMBER" \
    --set-metadata merge_approval.head_sha="$HEAD_SHA" \
    --set-metadata merge_approval.reviewer="$REVIEWER" \
    --set-metadata merge_approval.recorded_at="$RECORDED_AT"; then
    echo "ERROR: failed to record merge approval signal on $BEAD" >&2
    exit 1
fi

echo "merge approval recorded: bead=$BEAD verdict=$VERDICT pr=$PR_NUMBER sha=$HEAD_SHA reviewer=$REVIEWER at=$RECORDED_AT"
