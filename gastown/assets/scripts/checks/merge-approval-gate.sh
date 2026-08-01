#!/usr/bin/env bash
# Consumer for the gc-native merge approval signal — the refinery's merge gate.
#
# Reads the signal that record-merge-approval.sh wrote on the work bead and
# decides whether the refinery may land the branch. The signal names a PR number
# and a head SHA; this script re-reads the LIVE PR head from GitHub and permits
# the merge only when the approved SHA is still the head. New commits after
# approval therefore invalidate it — an approval authorizes one commit, not a
# branch.
#
# FAIL CLOSED. Every path that is not a positive, current, matching approval
# refuses the merge, including the paths where the gate cannot tell: a bead it
# cannot read, a PR it cannot resolve, a head SHA GitHub will not return. A
# tool error is a suspect, not a licence to merge.
#
# Usage:
#   merge-approval-gate.sh --bead <id> [--required <true|false>] [--merge-sha <sha>]
#
#   --required   Opt-in switch, normally the rig's require_merge_approval
#                formula var. Unset/empty/false/0/no/off = gate disabled (exit 0).
#                ANY other value enables it, so a typo enables the gate rather
#                than silently disabling it. Falls back to
#                $GC_REQUIRE_MERGE_APPROVAL.
#   --merge-sha  The commit the refinery is about to merge (`git rev-parse temp`).
#                When given it must equal the approved SHA, which closes the gap
#                where the local branch tip has drifted from the reviewed PR head.
#
# Exit codes:
#   0  merge permitted (approved and current), or gate not enabled
#   1  REFUSE — missing, incomplete, non-approving, mismatched, or stale signal
#   2  REFUSE — cannot evaluate (unreadable bead, unresolvable origin repo, PR
#      lookup failure, no token)

set -uo pipefail

SELF=$(basename "$0")

usage() {
    echo "usage: $SELF --bead <id> [--required <true|false>] [--merge-sha <sha>]" >&2
}

# A refusal the gate can explain: the signal was read and found wanting.
refuse() {
    echo "GATE: refused reason=$1" >&2
    exit 1
}

# A refusal the gate cannot explain: it never got to a verdict. Same outcome,
# different exit code so the caller can tell "reviewer said no" from "the gate
# is broken" without the two ever collapsing into a merge.
undecidable() {
    echo "GATE: undecidable reason=$1" >&2
    exit 2
}

die_usage() {
    echo "ERROR: $*" >&2
    usage
    exit 2
}

BEAD=""
REQUIRED=""
REQUIRED_SET=0
MERGE_SHA=""

need_value() {
    [ "$1" -ge 2 ] || die_usage "$2 requires a value"
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --bead) need_value "$#" --bead; BEAD="$2"; shift 2 ;;
        --bead=*) BEAD="${1#*=}"; shift ;;
        --required) need_value "$#" --required; REQUIRED="$2"; REQUIRED_SET=1; shift 2 ;;
        --required=*) REQUIRED="${1#*=}"; REQUIRED_SET=1; shift ;;
        --merge-sha) need_value "$#" --merge-sha; MERGE_SHA="$2"; shift 2 ;;
        --merge-sha=*) MERGE_SHA="${1#*=}"; shift ;;
        -h|--help) usage; exit 0 ;;
        *) die_usage "unknown argument: $1" ;;
    esac
done

if [ "$REQUIRED_SET" -eq 0 ]; then
    REQUIRED="${GC_REQUIRE_MERGE_APPROVAL:-}"
fi

# Opt-in: rigs that do not require review are unaffected. Only the recognized
# off values disable the gate; anything unrecognized turns it ON.
case "$(printf '%s' "$REQUIRED" | tr '[:upper:]' '[:lower:]')" in
    ''|false|0|no|off)
        echo "GATE: not-required"
        exit 0
        ;;
esac

[ -n "$BEAD" ] || die_usage "--bead is required"

# json_payload strips any non-JSON prefix line (bd emits a
# `warning: beads.role not configured` diagnostic on stdout ahead of the real
# payload). Same guard the sibling review check scripts use.
json_payload() {
    awk 'found || /^[[:space:]]*[[{]/{ found=1; print }'
}

read_bead() {
    local attempt=0 output=""
    while [ "$attempt" -lt 5 ]; do
        output=$(gc bd show "$BEAD" --json 2>/dev/null | json_payload)
        if [ -n "$output" ] && printf '%s' "$output" | jq -e 'type == "array" or type == "object"' >/dev/null 2>&1; then
            printf '%s' "$output"
            return 0
        fi
        attempt=$((attempt + 1))
        sleep 0.2
    done
    return 1
}

BEAD_JSON=$(read_bead) || undecidable "bead_unreadable bead=$BEAD"

meta() {
    printf '%s' "$BEAD_JSON" |
        jq -r --arg key "$1" '
            (if type == "array" then .[0] else . end)
            | (.metadata[$key] // "")
            | tostring
        ' 2>/dev/null
}

SIG_VERDICT=$(meta merge_approval.verdict)
SIG_PR=$(meta merge_approval.pr_number)
SIG_SHA=$(printf '%s' "$(meta merge_approval.head_sha)" | tr '[:upper:]' '[:lower:]')
SIG_REVIEWER=$(meta merge_approval.reviewer)
SIG_AT=$(meta merge_approval.recorded_at)
BEAD_BRANCH=$(meta branch)
BEAD_PR=$(meta pr_number)
if [ -z "$BEAD_PR" ]; then
    BEAD_PR=$(printf '%s\n' "$(meta pr_url)" |
        sed -nE 's|^[Hh][Tt][Tt][Pp][Ss]?://[^/]+/[^/]+/[^/]+/pull/([0-9]+)/?$|\1|p' | head -n 1)
fi

if [ -z "$SIG_VERDICT" ] && [ -z "$SIG_PR" ] && [ -z "$SIG_SHA" ]; then
    refuse "no_approval_signal bead=$BEAD"
fi
# A partially written signal is not a weaker approval, it is no approval.
if [ -z "$SIG_VERDICT" ] || [ -z "$SIG_PR" ] || [ -z "$SIG_SHA" ] ||
    [ -z "$SIG_REVIEWER" ] || [ -z "$SIG_AT" ]; then
    refuse "incomplete_approval_signal bead=$BEAD verdict=${SIG_VERDICT:-<empty>} pr=${SIG_PR:-<empty>} sha=${SIG_SHA:-<empty>} reviewer=${SIG_REVIEWER:-<empty>} recorded_at=${SIG_AT:-<empty>}"
fi

if [ "$SIG_VERDICT" != "approved" ]; then
    refuse "verdict_not_approved verdict=$SIG_VERDICT"
fi
if [[ ! "$SIG_PR" =~ ^[1-9][0-9]*$ ]]; then
    refuse "malformed_pr_number pr=$SIG_PR"
fi
if [[ ! "$SIG_SHA" =~ ^[0-9a-f]{40}$ ]]; then
    refuse "malformed_head_sha sha=$SIG_SHA"
fi

# The bead must name the branch, or there is nothing to bind the PR to.
if [ -z "$BEAD_BRANCH" ]; then
    refuse "bead_has_no_branch bead=$BEAD"
fi
# An approval for a different PR is not an approval for this one.
if [ -n "$BEAD_PR" ] && [ "$BEAD_PR" != "$SIG_PR" ]; then
    refuse "pr_number_mismatch signal_pr=$SIG_PR bead_pr=$BEAD_PR"
fi

if [ -n "$MERGE_SHA" ]; then
    MERGE_SHA=$(printf '%s' "$MERGE_SHA" | tr '[:upper:]' '[:lower:]')
    if [[ ! "$MERGE_SHA" =~ ^[0-9a-f]{40}$ ]]; then
        undecidable "malformed_merge_sha merge_sha=$MERGE_SHA"
    fi
    if [ "$MERGE_SHA" != "$SIG_SHA" ]; then
        refuse "merge_sha_not_approved merge_sha=$MERGE_SHA approved_sha=$SIG_SHA"
    fi
fi

resolve_github_token() {
    local token="${GH_TOKEN:-${GITHUB_TOKEN:-${GIT_TOKEN:-}}}"
    if [ -n "$token" ]; then
        printf '%s\n' "$token"
        return 0
    fi
    printf 'protocol=https\nhost=github.com\n\n' |
        GIT_TERMINAL_PROMPT=0 git credential fill 2>/dev/null |
        sed -n 's/^password=//p' | head -n 1
}

# --- origin-repo-resolution:begin ---
# Both lookup paths must ask the SAME repository, and it must be the one this
# rig's branches were actually pushed to. `gh` resolves its base repo with its
# own heuristic, which on a fork that also carries an `upstream` remote answers
# the PARENT — so an unscoped `gh pr view 2` read a stranger's pull request and
# judged the approval against it, refusing every valid approval (gcp-3ty).
# Parse `git remote get-url origin` directly and treat gh's guess as something
# to override, never to trust; same call mol-refinery-patrol's mr lane made in
# gcp-6qp. Resolution lives here once so the gh and REST paths cannot disagree.
ORIGIN_URL=""
ORIGIN_REPO=""
ORIGIN_REPO_ERROR=""

resolve_origin_repo() {
    local origin
    ORIGIN_URL=$(git remote get-url origin 2>/dev/null)
    if [ -z "$ORIGIN_URL" ]; then
        ORIGIN_REPO_ERROR="origin_remote_unreadable"
        return 1
    fi
    origin="$ORIGIN_URL"
    case "$origin" in
        git@github.com:*) origin=${origin#git@github.com:} ;;
        https://github.com/*) origin=${origin#https://github.com/} ;;
        ssh://git@github.com/*) origin=${origin#ssh://git@github.com/} ;;
        *)
            ORIGIN_REPO_ERROR="unsupported_origin_remote"
            return 1
            ;;
    esac
    origin=${origin%.git}
    if [[ ! "$origin" =~ ^[^/]+/[^/]+$ ]]; then
        ORIGIN_REPO_ERROR="unparseable_origin_remote"
        return 1
    fi
    ORIGIN_REPO="$origin"
    return 0
}
# --- origin-repo-resolution:end ---

# Mirrors mol-refinery-patrol's own gh-or-REST split so the gate stays usable in
# rigs without the gh CLI. Without the fallback those rigs would be permanently
# refused — fail-closed, but permanently deadlocked, which is the bug this gate
# exists to end.
lookup_pr_rest() {
    local number="$1" owner repo token raw
    [ -n "$ORIGIN_REPO" ] || return 1
    owner=${ORIGIN_REPO%%/*}
    repo=${ORIGIN_REPO#*/}
    token=$(resolve_github_token)
    [ -n "$token" ] || return 1
    raw=$(curl -fsS \
        -H "Accept: application/vnd.github+json" \
        -H "Authorization: Bearer $token" \
        -H "X-GitHub-Api-Version: 2022-11-28" \
        "https://api.github.com/repos/$owner/$repo/pulls/$number" 2>/dev/null) || return 1
    printf '%s' "$raw" |
        jq '{number, state: (.state | ascii_upcase), headRefName: .head.ref, headRefOid: .head.sha}' 2>/dev/null
}

lookup_pr() {
    local number="$1"
    if command -v gh >/dev/null 2>&1; then
        gh pr view "$number" --repo "$ORIGIN_REPO" \
            --json number,state,headRefName,headRefOid 2>/dev/null
        return $?
    fi
    lookup_pr_rest "$number"
}

# An unscoped lookup is the defect itself, so there is no degraded mode: without
# a resolved origin the gate has no repository it may safely ask about, and a
# gate that cannot ask does not merge.
if ! resolve_origin_repo; then
    undecidable "origin_repo_unresolved cause=$ORIGIN_REPO_ERROR origin=${ORIGIN_URL:-<empty>}"
fi

if ! PR_INFO=$(lookup_pr "$SIG_PR") || [ -z "$PR_INFO" ]; then
    undecidable "pr_lookup_failed pr=$SIG_PR"
fi

LIVE_NUMBER=$(printf '%s' "$PR_INFO" | jq -r '.number // ""' 2>/dev/null)
LIVE_STATE=$(printf '%s' "$PR_INFO" | jq -r '.state // ""' 2>/dev/null | tr '[:lower:]' '[:upper:]')
LIVE_HEAD_REF=$(printf '%s' "$PR_INFO" | jq -r '.headRefName // ""' 2>/dev/null)
LIVE_HEAD_SHA=$(printf '%s' "$PR_INFO" | jq -r '.headRefOid // ""' 2>/dev/null | tr '[:upper:]' '[:lower:]')

if [ -z "$LIVE_NUMBER" ] || [ -z "$LIVE_STATE" ] || [ -z "$LIVE_HEAD_REF" ]; then
    undecidable "pr_lookup_incomplete pr=$SIG_PR"
fi
if [ "$LIVE_NUMBER" != "$SIG_PR" ]; then
    undecidable "pr_identity_mismatch asked=$SIG_PR got=$LIVE_NUMBER"
fi
if [[ ! "$LIVE_HEAD_SHA" =~ ^[0-9a-f]{40}$ ]]; then
    undecidable "unresolvable_live_head_sha pr=$SIG_PR head=${LIVE_HEAD_SHA:-<empty>}"
fi
if [ "$LIVE_STATE" != "OPEN" ]; then
    refuse "pr_not_open pr=$SIG_PR state=$LIVE_STATE"
fi
if [ "$LIVE_HEAD_REF" != "$BEAD_BRANCH" ]; then
    refuse "pr_branch_mismatch pr=$SIG_PR pr_head_ref=$LIVE_HEAD_REF bead_branch=$BEAD_BRANCH"
fi
if [ "$LIVE_HEAD_SHA" != "$SIG_SHA" ]; then
    refuse "stale_head_sha pr=$SIG_PR approved_sha=$SIG_SHA live_head_sha=$LIVE_HEAD_SHA"
fi

echo "GATE: approved bead=$BEAD pr=$SIG_PR sha=$SIG_SHA reviewer=$SIG_REVIEWER recorded_at=$SIG_AT"
exit 0
