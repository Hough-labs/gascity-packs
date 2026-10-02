#!/usr/bin/env bash
# Black-box characterization of the refinery's merge-push step: every merge lane
# (direct, mr, local), run end to end (gcp-l8td.4 B1.1, gcp-l8td.5 B1.2a,
# gcp-l8td.6 B1.2b).
#
# The lane used to be 14 fenced blocks of mol-refinery-patrol's merge-push step,
# hand-rendered by the agent on every patrol. It is now gastown/assets/scripts/
# refinery/merge-push.sh, and the step is one invoke block that locates the
# script, runs it, and acts on its exit status. The mr lane is dormant (every rig
# lands direct) and the post-merge close and both cleanups had no executed test
# before B1.1, so each case asserts what a lane DID: the work bead it left behind
# (metadata, status, close reason), the gc/gh/curl calls it made, and the refs it
# moved on a real bare origin. It never asserts how the lane is written.
#
# Every case runs the step's own invoke block, EXTRACTED from the shipped formula
# through tomllib (the renderer's un-escape) and never transcribed: the block
# between `# --- merge-push:invoke:begin ---` and `:end ---`. That block locates
# merge-push.sh, runs it, and applies the step's status table, so the journal and
# the exit status each case sees are the real step's, not a stand-in. Point
# FORMULA at another copy of the formula to check that. A missing or duplicated
# sentinel, or a `{{` left in the block, aborts the whole suite. Point SCRIPT at
# another copy of the script to check that the suite can fail; that copy is
# staged as a pack tree, because the block finds the script, and the script finds
# the approval gate, by position.
#
# The suite fails unless the 23 lane cases and the 2 locator cases ran. A handful
# of script-only cases (config resolution, invariants) run once, after them.
#
# The rig is real git: a bare origin, a polecat clone that pushed the branch,
# and the refinery's clone with `temp` rebased onto the target, which is what
# the `rebase` step leaves behind. Everything else is stubbed and journalled:
#   gc    beads against a JSON fixture of the work bead, plus mail, nudges,
#         drain-ack, the next-wisp pour/burn, and `formula list`. That last one
#         answers with no formulas, so the block falls back to GC_PACK_DIR, which
#         points at the real pack: the lane runs the REAL merge-push.sh and, when
#         approval is on, the REAL merge-approval-gate.sh beside it.
#   gh    pull requests from a JSON fixture; the live head sha is read off the
#         bare origin, as GitHub would report it.
#   curl  the GitHub REST fallback, used when gh is absent.
#   git   the real binary, except that `git remote get-url origin` answers
#         https://github.com/acme/widgets.git. The bare origin stands in for
#         that repository, so the lane's repo resolution and the gate's agree.
# Every lane process runs under `env -i` with a PATH holding only symlinked
# tools and these stubs. "gh absent" is then real even on a host that has gh,
# and no agent-session GC_* variable can leak in. Any stub call the model does
# not know fails loudly (exit 64) and fails the case.
set -uo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
FORMULA="${FORMULA:-$ROOT/gastown/formulas/mol-refinery-patrol.toml}"
PACK_DIR="$ROOT/gastown"
SCRIPT="${SCRIPT:-$PACK_DIR/assets/scripts/refinery/merge-push.sh}"
ADAPTER=script
# Cases finished so far.
PASS_CASES=0

WORK_ID=gcp-work
WISP_ID=gcp-wisp
NEXT_WISP_ID=gcp-next
BRANCH_NAME=polecat/gcp-work
TARGET_NAME=integration
REFINERY_AGENT=testrig/gastown.refinery
ORIGIN_REPO=acme/widgets
ORIGIN_URL_GITHUB="https://github.com/$ORIGIN_REPO.git"
PR_URL="https://github.com/$ORIGIN_REPO/pull/7"
API_URL="https://api.github.com/repos/$ORIGIN_REPO"
ISSUE_TITLE="Teach the widget to count"

FAILURES=0
CASE=""

fail() {
    echo "FAIL[$CASE]: $*" >&2
    FAILURES=$((FAILURES + 1))
}

# extract_invoke <file> — write the merge-push step's invoke block to <file>.
# Exits non-zero, naming each problem, when the step is missing or duplicated,
# the sentinel pair is not exactly one, or a placeholder is left in the block:
# nothing is rendered, because every config value resolves inside the script.
extract_invoke() {
    python3 - "$FORMULA" "$1" <<'PY'
import sys
import tomllib

formula, out = sys.argv[1:3]
begin, end = "# --- merge-push:invoke:begin ---", "# --- merge-push:invoke:end ---"
with open(formula, "rb") as handle:
    doc = tomllib.load(handle)
steps = [s for s in doc.get("steps", []) if s.get("id") == "merge-push"]
if len(steps) != 1:
    sys.exit(f"extract: expected exactly one merge-push step in {formula}, found {len(steps)}")
text = steps[0].get("description", "")
if text.count(begin) != 1 or text.count(end) != 1:
    sys.exit(f"extract: want exactly one begin and one end sentinel in merge-push, "
             f"found {text.count(begin)} and {text.count(end)}")
block = text.split(begin, 1)[1].split(end, 1)[0]
if "{{" in block:
    sys.exit("extract: the invoke block carries a template placeholder")
with open(out, "w") as handle:
    handle.write(block)
PY
}

# --- stubs ------------------------------------------------------------------

# The fake gc. The work bead lives in $GC_STUB_BEAD as `gc bd show --json`
# returns it; update and close mutate it. Every call is journalled one per line
# as `gc <argv>`. Dispatch is on the argv words one at a time, so no line here
# spells a bare beads invocation.
write_gc_stub() {
    cat >"$1/gc" <<'STUB'
#!/usr/bin/env bash
ARGS=("$@")
printf 'gc %s\n' "$*" >>"$GC_STUB_LOG"
unexpected() {
    printf 'gc %s\n' "${ARGS[*]}" >>"$STUB_UNEXPECTED"
    echo "stub gc: unexpected invocation: gc ${ARGS[*]}" >&2
    exit 64
}
edit_bead() {
    local tmp
    tmp=$(mktemp) || exit 70
    jq "$@" "$GC_STUB_BEAD" >"$tmp" && mv -f "$tmp" "$GC_STUB_BEAD"
}
case "${1:-}" in
bd)
    case "${2:-}" in
    show)
        { [ "$#" -eq 4 ] && [ "$3" = "$GC_STUB_WORK" ] && [ "$4" = --json ]; } || unexpected
        cat "$GC_STUB_BEAD"
        ;;
    update)
        id="${3:-}"
        shift 3
        # The poured successor wisp: only its assignment is journalled.
        [ "$id" = "$GC_STUB_NEXT_WISP" ] && exit 0
        [ "$id" = "$GC_STUB_WORK" ] || unexpected
        while [ "$#" -gt 0 ]; do
            case "$1" in
            --assignee=*) edit_bead --arg v "${1#*=}" '.[0].assignee = $v' ;;
            --status=*) edit_bead --arg v "${1#*=}" '.[0].status = $v' ;;
            --set-metadata)
                edit_bead --arg k "${2%%=*}" --arg v "${2#*=}" '.[0].metadata[$k] = $v'
                shift
                ;;
            --unset-metadata)
                edit_bead --arg k "$2" 'del(.[0].metadata[$k])'
                shift
                ;;
            *) unexpected ;;
            esac
            shift
        done
        ;;
    close)
        { [ "$#" -eq 5 ] && [ "$3" = "$GC_STUB_WORK" ] && [ "$4" = --reason ]; } || unexpected
        edit_bead --arg r "$5" '.[0].status = "closed" | .[0].close_reason = $r'
        ;;
    mol)
        case "${3:-}" in
        wisp) printf '{"new_epic_id":"%s"}\n' "$GC_STUB_NEXT_WISP" ;;
        burn) : ;;
        *) unexpected ;;
        esac
        ;;
    *) unexpected ;;
    esac
    ;;
formula)
    [ "${2:-}" = list ] || unexpected
    if [ -n "${GC_STUB_FORMULA_SOURCE:-}" ]; then
        printf '{"formulas":[{"name":"mol-refinery-patrol","source":"%s"}]}\n' "$GC_STUB_FORMULA_SOURCE"
    else
        printf '{"formulas":[]}\n'
    fi
    ;;
runtime) [ "${2:-}" = drain-ack ] || unexpected ;;
mail) [ "${2:-}" = send ] || unexpected ;;
session) [ "${2:-}" = nudge ] || unexpected ;;
*) unexpected ;;
esac
exit 0
STUB
    chmod +x "$1/gc"
}

# The fake gh. It holds one pull request, $STUB_PR, in the shape `gh pr view
# --json` returns. headRefOid is read live off the bare origin, so the gate
# sees whatever head the lane actually pushed. STUB_GH_MISSING makes every view
# fail the way gh does for a PR it cannot resolve.
write_gh_stub() {
    cat >"$1/gh" <<'STUB'
#!/usr/bin/env bash
ARGS=("$@")
printf 'gh %s\n' "$*" >>"$GH_STUB_LOG"
unexpected() {
    printf 'gh %s\n' "${ARGS[*]}" >>"$STUB_UNEXPECTED"
    echo "stub gh: unexpected invocation: gh ${ARGS[*]}" >&2
    exit 64
}
pr_json() {
    local head oid
    head=$(jq -r '.headRefName' "$STUB_PR")
    oid=$(git --git-dir="$STUB_ORIGIN_DIR" rev-parse --verify -q "refs/heads/$head" || true)
    jq --arg oid "$oid" '. + {headRefOid: $oid}' "$STUB_PR"
}
[ "${1:-}" = pr ] || unexpected
case "${2:-}" in
create)
    while [ "$#" -gt 0 ]; do
        if [ "$1" = --body-file ] && [ "$#" -ge 2 ]; then
            cp -f "$2" "$STUB_BODY_CAPTURE"
        fi
        shift
    done
    jq -r '.url' "$STUB_PR"
    ;;
view)
    if [ -n "${STUB_GH_MISSING:-}" ]; then
        echo "GraphQL: Could not resolve to a PullRequest with the number of 7. (repository.pullRequest)" >&2
        exit 1
    fi
    query=""
    while [ "$#" -gt 0 ]; do
        if [ "$1" = -q ] && [ "$#" -ge 2 ]; then
            query="$2"
            shift
        fi
        shift
    done
    if [ -n "$query" ]; then
        pr_json | jq -r "$query"
    else
        pr_json
    fi
    ;;
*) unexpected ;;
esac
STUB
    chmod +x "$1/gh"
}

# The fake GitHub REST API. It holds one pull request, $STUB_REST_PR, in REST
# shape. The list call finds it only after the create call has made it.
write_curl_stub() {
    cat >"$1/curl" <<'STUB'
#!/usr/bin/env bash
ARGS=("$@")
printf 'curl %s\n' "$*" >>"$CURL_STUB_LOG"
unexpected() {
    printf 'curl %s\n' "${ARGS[*]}" >>"$STUB_UNEXPECTED"
    echo "stub curl: unexpected invocation: curl ${ARGS[*]}" >&2
    exit 64
}
method=GET
url=""
while [ "$#" -gt 0 ]; do
    case "$1" in
    -X) method="${2:-}"; shift ;;
    https://*) url="$1" ;;
    esac
    shift
done
[ -f "${STUB_REST_PR:-}" ] || unexpected
case "$method $url" in
"GET $STUB_API/pulls")
    if [ -e "$STUB_REST_CREATED" ]; then
        jq -c '[{number: .number}]' "$STUB_REST_PR"
    else
        echo '[]'
    fi
    ;;
"POST $STUB_API/pulls")
    : >"$STUB_REST_CREATED"
    cat "$STUB_REST_PR"
    ;;
"GET $STUB_API/pulls/$(jq -r '.number' "$STUB_REST_PR")")
    cat "$STUB_REST_PR"
    ;;
*) unexpected ;;
esac
STUB
    chmod +x "$1/curl"
}

# git itself, except for the one question whose honest answer (a local path)
# would send the lane down its non-GitHub branch.
write_git_shim() {
    local real_git
    real_git="$(git --exec-path)/git"
    [ -x "$real_git" ] || real_git=$(command -v git)
    cat >"$1/git" <<SHIM
#!/usr/bin/env bash
if [ "\$#" -eq 3 ] && [ "\$1" = remote ] && [ "\$2" = get-url ] && [ "\$3" = origin ]; then
    printf '%s\n' "\${STUB_ORIGIN_URL:?}"
    exit 0
fi
exec "$real_git" "\$@"
SHIM
    chmod +x "$1/git"
}

# make_bin <dir> [with-gh] — a PATH holding only these tools and the stubs.
make_bin() {
    local bin="$1" tool path
    mkdir -p "$bin"
    for tool in bash sh env cat cp mv rm rmdir mkdir mktemp ls ln chmod touch \
        cut dirname basename grep sed awk tr head tail wc sort uniq jq sleep date \
        find xargs expr; do
        path=$(command -v "$tool") || continue
        ln -sf "$path" "$bin/$tool"
    done
    write_git_shim "$bin"
    write_gc_stub "$bin"
    write_curl_stub "$bin"
    if [ -n "${2:-}" ]; then
        write_gh_stub "$bin"
    fi
}

# --- rig --------------------------------------------------------------------

git_q() { git "$@" >/dev/null 2>&1; }

new_case() {
    CASE="$ADAPTER:$1"
    CASE_START_FAILURES=$FAILURES
    T=$(mktemp -d "${TMPDIR:-/tmp}/merge-lanes.XXXXXX")
    ORIGIN="$T/origin.git"
    REFINERY="$T/refinery"
    BEAD="$T/bead.json"
    mkdir -p "$T/home" "$T/tmp"
    cat >"$T/home/.gitconfig" <<'CFG'
[init]
	defaultBranch = integration
[user]
	name = refinery
	email = refinery@example.invalid
[advice]
	detachedHead = false
[protocol "file"]
	allow = always
[commit]
	gpgsign = false
CFG
    export HOME="$T/home"
    export GIT_CONFIG_GLOBAL="$T/home/.gitconfig"
    export GIT_CONFIG_NOSYSTEM=1
    export GIT_AUTHOR_NAME=refinery GIT_AUTHOR_EMAIL=refinery@example.invalid
    export GIT_COMMITTER_NAME=refinery GIT_COMMITTER_EMAIL=refinery@example.invalid
    : >"$T/gc.log"
    : >"$T/gh.log"
    : >"$T/curl.log"
    : >"$T/lane.out"
    LANE_BIN="$HARNESS/bin-gh"
    LANE_ENV_EXTRA=()
    STUB_GH_MISSING=""
    jq -n --arg url "$PR_URL" --arg head "$BRANCH_NAME" --arg base "$TARGET_NAME" \
        '{url: $url, number: 7, state: "OPEN", headRefName: $head, baseRefName: $base,
          headRepositoryOwner: {login: "acme"}, headRepository: {name: "widgets"}}' >"$T/pr.json"
}

end_case() {
    [ ! -s "$T/unexpected" ] || fail "unmodelled stub call(s): $(tr '\n' ';' <"$T/unexpected")"
    if [ "$FAILURES" -ne "$CASE_START_FAILURES" ]; then
        {
            echo "--- $CASE: lane output (status ${LANE_STATUS:-unset}) ---"
            cat "$T/lane.out"
            echo "--- $CASE: gc calls ---"
            cat "$T/gc.log"
        } >&2
    fi
    rm -rf "$T"
    PASS_CASES=$((PASS_CASES + 1))
}

# build_rig <shape> — the rig at the moment merge-push runs. Shapes:
#   unmerged        an ordinary merge candidate: one commit on the branch
#   landed_ff       the branch is already on the target under its own sha
#   landed_patch_id the branch's commit was cherry-picked onto the target
#   empty           the polecat committed nothing; the target never moved
#   empty_moved     the polecat committed nothing and the target moved on, so
#                   `temp` is no longer the branch tip
build_rig() {
    local shape="$1" seed="$T/seed" polecat="$T/polecat"
    git_q init --bare "$ORIGIN"
    git_q init "$seed"
    echo baseline >"$seed/README.md"
    git_q -C "$seed" add README.md
    git_q -C "$seed" commit -m "chore: baseline"
    git_q -C "$seed" push "$ORIGIN" HEAD:integration
    FORK_SHA=$(git -C "$seed" rev-parse HEAD)

    git_q clone "$ORIGIN" "$polecat"
    git_q -C "$polecat" checkout -b "$BRANCH_NAME"
    case "$shape" in
    empty | empty_moved) ;;
    *)
        echo "the work this bead carried" >"$polecat/feature.txt"
        git_q -C "$polecat" add feature.txt
        git_q -C "$polecat" commit -m "feat: the work this bead carried"
        ;;
    esac
    git_q -C "$polecat" push origin "$BRANCH_NAME"
    BRANCH_SHA=$(git -C "$polecat" rev-parse HEAD)

    case "$shape" in
    landed_ff)
        git_q -C "$polecat" push origin "$BRANCH_NAME:integration"
        ;;
    landed_patch_id)
        # A concurrent commit first, so the cherry-pick is a rewrite with a new
        # sha and the branch is NOT an ancestor of the target.
        git_q -C "$seed" pull "$ORIGIN" integration
        echo "someone else" >"$seed/other.txt"
        git_q -C "$seed" add other.txt
        git_q -C "$seed" commit -m "feat: a concurrent bead"
        git_q -C "$seed" fetch "$ORIGIN" "$BRANCH_NAME"
        git_q -C "$seed" cherry-pick "$BRANCH_SHA"
        LANDED_SHA=$(git -C "$seed" rev-parse HEAD)
        git_q -C "$seed" push "$ORIGIN" HEAD:integration
        ;;
    empty_moved)
        echo "another bead's work" >"$seed/elsewhere.txt"
        git_q -C "$seed" add elsewhere.txt
        git_q -C "$seed" commit -m "feat: a different bead entirely"
        git_q -C "$seed" push "$ORIGIN" HEAD:integration
        ;;
    esac

    git_q clone "$ORIGIN" "$REFINERY"
    git_q -C "$REFINERY" fetch origin "$BRANCH_NAME"
    git_q -C "$REFINERY" checkout -b temp "origin/$BRANCH_NAME"
    # What the `rebase` step leaves behind, including its "skipped previously
    # applied commit" collapse.
    git_q -C "$REFINERY" rebase origin/integration || git_q -C "$REFINERY" rebase --abort
    TEMP_SHA=$(git -C "$REFINERY" rev-parse --verify -q temp)
    TARGET_BEFORE=$(origin_tip)
    # The setup above is quiet, so say so plainly when it did not produce a rig.
    [ -n "$TEMP_SHA" ] && [ -n "$TARGET_BEFORE" ] ||
        fail "harness bug: build_rig $shape left no temp branch or no origin/integration"
}

# add_second_worktree — the target branch checked out in another worktree of
# the refinery clone, as a rig's main checkout commonly has it.
add_second_worktree() {
    git_q -C "$REFINERY" worktree add "$T/second" integration ||
        fail "harness bug: could not check integration out in a second worktree"
}

# write_bead [key=value ...] — the work bead as a polecat hands it over. The
# stale rejection_reason proves that the lanes which clear it do clear it.
write_bead() {
    local kv tmp
    jq -n --arg id "$WORK_ID" --arg title "$ISSUE_TITLE" --arg agent "$REFINERY_AGENT" \
        --arg branch "$BRANCH_NAME" --arg target "$TARGET_NAME" --arg fork "$FORK_SHA" \
        '[{id: $id, title: $title,
           description: "The widget cannot count yet.",
           notes: "Counting lives in widget.go.",
           issue_type: "task", priority: 2, status: "in_progress", assignee: $agent,
           metadata: {branch: $branch, target: $target, fork_sha: $fork,
                      rejection_reason: "an earlier attempt was rejected"}}]' >"$BEAD"
    for kv in "$@"; do
        tmp=$(mktemp)
        jq --arg k "${kv%%=*}" --arg v "${kv#*=}" '.[0].metadata[$k] = $v' "$BEAD" >"$tmp" &&
            mv -f "$tmp" "$BEAD"
    done
}

edit_pr() {
    local tmp
    tmp=$(mktemp)
    jq "$@" "$T/pr.json" >"$tmp" && mv -f "$tmp" "$T/pr.json"
}

# --- running the step ---------------------------------------------------------

# run_process <script> [arg ...] — runs one script inside the refinery clone, as
# the patrol does. The cd fails closed: a lane run anywhere else would fetch and
# push the origin of whatever checkout the suite was started from. SCRIPT_ENV (the
# run's) and then LANE_ENV_EXTRA (the case's) add to the environment; a case's
# entry wins over the run's. GC_PACK_DIR names the pack the invoke
# block falls back to when `gc formula list` names no formula, and WORK is what
# the patrol's earlier steps leave for the block.
run_process() {
    (
        cd "$REFINERY" || exit 90
        env -i \
            PATH="$LANE_BIN" HOME="$T/home" TMPDIR="$T/tmp" \
            GIT_CONFIG_GLOBAL="$T/home/.gitconfig" GIT_CONFIG_NOSYSTEM=1 \
            GIT_AUTHOR_NAME=refinery GIT_AUTHOR_EMAIL=refinery@example.invalid \
            GIT_COMMITTER_NAME=refinery GIT_COMMITTER_EMAIL=refinery@example.invalid \
            GC_BEAD_ID="$WISP_ID" GC_AGENT="$REFINERY_AGENT" GC_RIG=testrig \
            GC_PACK_DIR="$PACK_DIR" WORK="$WORK_ID" \
            GC_STUB_LOG="$T/gc.log" GC_STUB_BEAD="$BEAD" GC_STUB_WORK="$WORK_ID" \
            GC_STUB_NEXT_WISP="$NEXT_WISP_ID" GC_STUB_FORMULA_SOURCE= \
            GH_STUB_LOG="$T/gh.log" STUB_PR="$T/pr.json" STUB_ORIGIN_DIR="$ORIGIN" \
            STUB_BODY_CAPTURE="$T/pr-body.md" STUB_GH_MISSING="$STUB_GH_MISSING" \
            CURL_STUB_LOG="$T/curl.log" STUB_API="$API_URL" STUB_REST_PR="$T/rest-pr.json" \
            STUB_REST_CREATED="$T/rest-created" \
            STUB_ORIGIN_URL="$ORIGIN_URL_GITHUB" STUB_UNEXPECTED="$T/unexpected" \
            ${SCRIPT_ENV[@]+"${SCRIPT_ENV[@]}"} \
            ${LANE_ENV_EXTRA[@]+"${LANE_ENV_EXTRA[@]}"} \
            "$BASH" "$@"
    ) >>"$T/lane.out" 2>&1
}

# write_config_json <file> [var=value ...] — the city config the script reads
# through MERGE_PUSH_CONFIG_JSON, with run_lane's overrides as testrig's
# FormulaVars. rig_name maps to nothing, because GC_RIG supplies the rig.
write_config_json() {
    local file="$1" kv vars='{}'
    shift
    for kv in "$@"; do
        case "${kv%%=*}" in
        rig_name) ;;
        require_merge_approval | review_agent | delete_merged_branches | target_branch | binding_prefix)
            vars=$(jq -c --arg k "${kv%%=*}" --arg v "${kv#*=}" '. + {($k): $v}' <<<"$vars")
            ;;
        *)
            fail "run_lane has no FormulaVars mapping for ${kv%%=*}"
            return 1
            ;;
        esac
    done
    jq -n --argjson vars "$vars" \
        '{config: {Rigs: [{Name: "testrig", DefaultBranch: "integration", FormulaVars: $vars}]}}' >"$file"
}

# run_lane [var=value ...] — run the merge-push step's invoke block against the
# rig and bead. Sets LANE_STATUS (the block's own exit status: 0 for the statuses
# the step continues on, 1 where it drains), SCRIPT_STATUS (the script's, from its
# RESULT line, empty if it never ran) and LANE (the strategy the lane chose, from
# its `merge-push: LANE` line, empty if it stopped before choosing).
run_lane() {
    local SCRIPT_ENV=(MERGE_PUSH_CONFIG_JSON="$T/config.json")
    LANE_STATUS=""
    LANE=""
    SCRIPT_STATUS=""
    if ! write_config_json "$T/config.json" "$@"; then
        LANE_STATUS=70
        return
    fi
    cp -f "$HARNESS/invoke.sh" "$T/invoke.sh"
    run_process "$T/invoke.sh"
    LANE_STATUS=$?
    LANE=$(sed -n 's/^merge-push: LANE //p' "$T/lane.out" | tail -n 1)
    SCRIPT_STATUS=$(sed -n 's/^merge-push: RESULT \([0-9]*\) .*/\1/p' "$T/lane.out" | tail -n 1)
    if grep -q '^merge-push: config ' "$T/lane.out" && [ -z "$SCRIPT_STATUS" ]; then
        fail "merge-push.sh ran but printed no RESULT line"
    fi
}

# --- assertions -------------------------------------------------------------

origin_tip() { git --git-dir="$ORIGIN" rev-parse refs/heads/integration; }
origin_ref() { git --git-dir="$ORIGIN" rev-parse --verify -q "refs/heads/$1"; }
short_sha() { git -C "$REFINERY" rev-parse --short "$1"; }
meta() { jq -r --arg k "$1" '.[0].metadata[$k] // "<unset>"' "$BEAD"; }
bead() { jq -r --arg k "$1" '.[0][$k] // "<unset>"' "$BEAD"; }
logged() { grep -qF -- "$2" "$T/$1.log"; }
count_logged() { grep -cF -- "$2" "$T/$1.log"; }
first_line_of() { grep -nF -- "$2" "$T/$1.log" | head -n 1 | cut -d: -f1; }
output_has() { grep -qE -- "$1" "$T/lane.out"; }

expect() {
    [ "$2" = "$3" ] || fail "$1 is '$2', want '$3'"
}

expect_lane() {
    expect "the lane the prefix chose" "$LANE" "$1"
}

expect_status() {
    expect "the lane's exit status" "$LANE_STATUS" "$1"
}

expect_target_unchanged() {
    expect "origin/integration" "$(origin_tip)" "$TARGET_BEFORE"
}

expect_drained() {
    logged gc "gc runtime drain-ack" || fail "the lane never ran gc runtime drain-ack"
}

expect_not_drained() {
    ! logged gc "gc runtime drain-ack" || fail "the lane ran gc runtime drain-ack"
}

expect_not_closed() {
    [ "$(bead status)" != closed ] || fail "the bead was closed: $(bead close_reason)"
}

expect_no_merge_metadata() {
    expect "merge_result" "$(meta merge_result)" "<unset>"
    expect "merged_sha" "$(meta merged_sha)" "<unset>"
    expect "merged_target" "$(meta merged_target)" "<unset>"
}

# halt_false_completion's effects (merge-push.sh).
expect_false_completion_halt() {
    expect "status" "$(bead status)" blocked
    expect "assignee" "$(bead assignee)" ""
    expect "merge_result" "$(meta merge_result)" refused_false_completion
    expect "gc.routed_to" "$(meta gc.routed_to)" human
    expect "session nudges" "$(count_logged gc "gc session nudge ")" 2
    grep -F "gc session nudge mayor " "$T/gc.log" | grep -qF "FALSE-COMPLETION HALT" ||
        fail "no FALSE-COMPLETION HALT nudge to mayor"
    grep -F "gc session nudge testrig/gastown.witness " "$T/gc.log" | grep -qF "FALSE-COMPLETION HALT" ||
        fail "no FALSE-COMPLETION HALT nudge to the witness (testrig/gastown.witness)"
    expect_drained
    expect_status 1
    expect_target_unchanged
}

# block_existing_pr's effects, and the step's status-9 pour/assign/burn, for one
# exact reason.
expect_existing_pr_blocked() {
    local reason="$1" wisp update burn
    expect "assignee" "$(bead assignee)" ""
    expect "merge_result" "$(meta merge_result)" blocked
    expect "gc.routed_to" "$(meta gc.routed_to)" human
    expect "blocked_reason" "$(meta blocked_reason)" "$reason"
    logged gc "gc mail send mayor/ -s ESCALATION: invalid existing_pr for $WORK_ID -m $reason" ||
        fail "no ESCALATION mail to mayor/ carrying the reason"
    wisp=$(first_line_of gc "gc bd mol wisp mol-refinery-patrol --root-only")
    update=$(first_line_of gc "gc bd update $NEXT_WISP_ID --assignee=$REFINERY_AGENT")
    burn=$(first_line_of gc "gc bd mol burn $WISP_ID --force")
    if [ -z "$wisp" ] || [ -z "$update" ] || [ -z "$burn" ]; then
        fail "want the next wisp poured, assigned and this one burned; got wisp@${wisp:-none} update@${update:-none} burn@${burn:-none}"
    elif [ "$wisp" -ge "$update" ] || [ "$update" -ge "$burn" ]; then
        fail "want pour, then assign, then burn; got wisp@$wisp update@$update burn@$burn"
    fi
    expect_drained
    expect_status 1
    expect_not_closed
    expect_target_unchanged
}

# --- cases: direct ----------------------------------------------------------

test_lane_direct_lands_and_closes() {
    new_case direct_lands_and_closes
    build_rig unmerged
    write_bead
    run_lane
    expect_lane direct
    expect_status 0
    expect "origin/integration" "$(origin_tip)" "$TEMP_SHA"
    expect "merge_result" "$(meta merge_result)" merged
    expect "merged_sha" "$(meta merged_sha)" "$TEMP_SHA"
    expect "merged_target" "$(meta merged_target)" "$TARGET_NAME"
    expect "rejection_reason" "$(meta rejection_reason)" "<unset>"
    expect "status" "$(bead status)" closed
    expect "close reason" "$(bead close_reason)" "Merged to $TARGET_NAME at $(short_sha "$TEMP_SHA")"
    expect_not_drained
    end_case
}

test_lane_direct_already_merged_ancestor() {
    new_case direct_already_merged_ancestor
    build_rig landed_ff
    write_bead
    run_lane
    expect_lane direct
    expect_status 0
    expect "status" "$(bead status)" closed
    expect "merge_result" "$(meta merge_result)" already_merged
    expect "already_merged_via" "$(meta already_merged_via)" ancestor
    expect "merged_sha" "$(meta merged_sha)" "$BRANCH_SHA"
    case "$(bead close_reason)" in
    "Already merged to $TARGET_NAME at "*) : ;;
    *) fail "close reason is '$(bead close_reason)', want 'Already merged to $TARGET_NAME at ...'" ;;
    esac
    expect_target_unchanged
    ! output_has 'merge-ff-push:' || fail "merge-ff-push ran for a bead the gate had already closed"
    end_case
}

test_lane_direct_already_merged_patch_id() {
    new_case direct_already_merged_patch_id
    build_rig landed_patch_id
    write_bead
    run_lane
    expect_lane direct
    expect_status 0
    expect "status" "$(bead status)" closed
    expect "merge_result" "$(meta merge_result)" already_merged
    expect "already_merged_via" "$(meta already_merged_via)" rebase_patch_id
    expect "merged_sha" "$(meta merged_sha)" "$LANDED_SHA"
    case "$(bead close_reason)" in
    "Already merged to $TARGET_NAME at "*) : ;;
    *) fail "close reason is '$(bead close_reason)', want 'Already merged to $TARGET_NAME at ...'" ;;
    esac
    expect_target_unchanged
    ! output_has 'merge-ff-push:' || fail "merge-ff-push ran for a bead the gate had already closed"
    end_case
}

test_lane_direct_false_completion_halts() {
    new_case direct_false_completion_halts
    build_rig empty
    write_bead
    run_lane
    expect_lane direct
    expect_false_completion_halt
    end_case
}

test_lane_direct_lost_race_then_lands() {
    local racer racing merged
    new_case direct_lost_race_then_lands
    build_rig unmerged
    write_bead
    # A racing commit that fast-forwards the target, parked on another ref
    # before the hook is armed.
    racer="$T/racer"
    git_q clone "$ORIGIN" "$racer"
    echo "bump" >"$racer/overlay.txt"
    git_q -C "$racer" add overlay.txt
    git_q -C "$racer" commit -m "chore: bump the deploy overlay"
    git_q -C "$racer" push origin HEAD:refs/heads/racing
    racing=$(git -C "$racer" rev-parse HEAD)
    # The first push is refused and the target advances under it; later
    # pushes go through. A receive hook runs inside git's object quarantine,
    # which forbids ref updates, so the advance steps outside it.
    cat >"$ORIGIN/hooks/pre-receive" <<HOOK
#!/bin/sh
unset GIT_QUARANTINE_PATH GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES
if [ ! -e "$T/raced" ]; then
    : >"$T/raced"
    git --git-dir="$ORIGIN" update-ref refs/heads/integration $racing
    echo "push refused by the test: the target moved" >&2
    exit 1
fi
exit 0
HOOK
    chmod +x "$ORIGIN/hooks/pre-receive"
    run_lane
    expect_lane direct
    expect_status 0
    [ -e "$T/raced" ] || fail "harness bug: the race hook never fired"
    merged=$(meta merged_sha)
    expect "merge_result" "$(meta merge_result)" merged
    git --git-dir="$ORIGIN" merge-base --is-ancestor "$merged" refs/heads/integration 2>/dev/null ||
        fail "merged_sha $merged is not reachable from origin/integration"
    git --git-dir="$ORIGIN" merge-base --is-ancestor "$racing" refs/heads/integration 2>/dev/null ||
        fail "the racing commit $racing was clobbered"
    expect "origin/integration" "$(origin_tip)" "$merged"
    expect "status" "$(bead status)" closed
    expect "close reason" "$(bead close_reason)" "Merged to $TARGET_NAME at $(short_sha "$merged")"
    end_case
}

test_lane_direct_push_veto_status_7() {
    new_case direct_push_veto_status_7
    build_rig unmerged
    write_bead
    cat >"$ORIGIN/hooks/pre-receive" <<HOOK
#!/bin/sh
echo x >>"$T/push-attempts"
echo "push refused by the test" >&2
exit 1
HOOK
    chmod +x "$ORIGIN/hooks/pre-receive"
    run_lane
    expect_lane direct
    output_has '\(status 7\)' || fail "the output does not name merge-ff-push status 7"
    expect "push attempts" "$(wc -l <"$T/push-attempts" | tr -d ' ')" 1
    expect_no_merge_metadata
    expect_not_closed
    expect_drained
    expect_status 1
    expect_target_unchanged
    end_case
}

test_lane_direct_approval_on_promotes_to_mr() {
    new_case direct_approval_on_promotes_to_mr
    build_rig unmerged
    write_bead
    run_lane require_merge_approval=true
    output_has 'using merge_strategy=mr' || fail "no 'using merge_strategy=mr' promotion message"
    expect_lane mr
    grep -qE '^gh pr (create|view) ' "$T/gh.log" || fail "the mr lane made no pull request call"
    expect "merge_approval_state" "$(meta merge_approval_state)" awaiting_review
    expect_not_closed
    expect_target_unchanged
    end_case
}

test_lane_direct_cleanup_with_target_in_second_worktree() {
    new_case direct_cleanup_with_target_in_second_worktree
    build_rig unmerged
    add_second_worktree
    write_bead
    run_lane delete_merged_branches=true
    expect_lane direct
    expect "status" "$(bead status)" closed
    git -C "$REFINERY" symbolic-ref -q HEAD >/dev/null &&
        fail "the refinery clone's HEAD is $(git -C "$REFINERY" symbolic-ref HEAD), want detached"
    expect "the refinery clone's HEAD" "$(git -C "$REFINERY" rev-parse HEAD)" "$(origin_tip)"
    git -C "$REFINERY" rev-parse --verify -q refs/heads/temp >/dev/null &&
        fail "temp still exists after cleanup"
    expect "the second worktree's branch" "$(git -C "$T/second" symbolic-ref -q HEAD)" refs/heads/integration
    origin_ref "$BRANCH_NAME" >/dev/null && fail "origin still has $BRANCH_NAME after delete_merged_branches=true"
    end_case
}

# --- cases: mr --------------------------------------------------------------

test_lane_mr_creates_pr_via_gh() {
    new_case mr_creates_pr_via_gh
    build_rig unmerged
    write_bead merge_strategy=mr
    run_lane
    expect_lane mr
    logged gh "gh pr create --repo $ORIGIN_REPO --base $TARGET_NAME --head $BRANCH_NAME --title $ISSUE_TITLE ($WORK_ID) --body-file " ||
        fail "no scoped create call with the bead's title; gh calls: $(tr '\n' ';' <"$T/gh.log")"
    grep -qF "## Refinery handoff" "$T/pr-body.md" 2>/dev/null ||
        fail "the PR body file has no '## Refinery handoff' section"
    expect "pr_url" "$(meta pr_url)" "$PR_URL"
    expect "pr_number" "$(meta pr_number)" 7
    end_case
}

test_lane_mr_reuses_existing_pr() {
    new_case mr_reuses_existing_pr
    build_rig unmerged
    write_bead "existing_pr=$PR_URL"
    run_lane
    output_has 'existing_pr requires pull-request handoff; using merge_strategy=mr' ||
        fail "existing_pr did not promote the direct default to mr"
    expect_lane mr
    grep -qE '^gh pr create ' "$T/gh.log" && fail "a pull request was created although existing_pr names one"
    # TWO reads of the existing PR, not one: github-helpers validates it
    # (:1420-1472) before any lane runs, and mr-verify reads it again as
    # PR_REF (:2115).
    expect "scoped views of the existing PR" \
        "$(count_logged gh "gh pr view --repo $ORIGIN_REPO --json url,number,state,headRefName,baseRefName,headRepositoryOwner,headRepository -- $PR_URL")" 2
    expect "close reason" "$(bead close_reason)" "Pull request ready: $PR_URL"
    end_case
}

test_lane_mr_rest_fallback_without_gh() {
    new_case mr_rest_fallback_without_gh
    build_rig unmerged
    LANE_BIN="$HARNESS/bin-nogh"
    LANE_ENV_EXTRA=(GH_TOKEN=test-token)
    jq -n --arg head "$BRANCH_NAME" --arg base "$TARGET_NAME" \
        '{html_url: "https://github.com/acme/widgets/pull/42", number: 42, state: "open",
          head: {ref: $head, repo: {name: "widgets", owner: {login: "acme"}}},
          base: {ref: $base}}' >"$T/rest-pr.json"
    write_bead merge_strategy=mr
    run_lane
    expect_lane mr
    [ ! -s "$T/gh.log" ] || fail "gh was called although it is absent"
    grep -F "$API_URL/pulls" "$T/curl.log" | grep -qE -- '--get|-X POST' ||
        fail "no create-or-find call to $API_URL/pulls; curl calls: $(tr '\n' ';' <"$T/curl.log")"
    expect "pr_url" "$(meta pr_url)" "https://github.com/acme/widgets/pull/42"
    expect "pr_number" "$(meta pr_number)" 42
    expect "close reason" "$(bead close_reason)" "Pull request ready: https://github.com/acme/widgets/pull/42"
    end_case
}

# Each existing_pr refusal. github-helpers validates existing_pr
# (:1420-1472) with exactly the messages mr-verify's twins use
# (:2121-2123, :2137-2176), and it runs first, so it is the one that fires.
test_lane_mr_existing_pr_not_found_blocks() {
    new_case mr_existing_pr_not_found_blocks
    build_rig unmerged
    write_bead merge_strategy=mr "existing_pr=$PR_URL"
    STUB_GH_MISSING=1
    run_lane
    expect_existing_pr_blocked "Existing PR $PR_URL was not found or is not accessible."
    end_case
}

test_lane_mr_existing_pr_not_open_blocks() {
    new_case mr_existing_pr_not_open_blocks
    build_rig unmerged
    write_bead merge_strategy=mr "existing_pr=$PR_URL"
    edit_pr '.state = "CLOSED"'
    run_lane
    expect_existing_pr_blocked "Existing PR $PR_URL is CLOSED, want OPEN."
    end_case
}

test_lane_mr_existing_pr_wrong_head_blocks() {
    new_case mr_existing_pr_wrong_head_blocks
    build_rig unmerged
    write_bead merge_strategy=mr "existing_pr=$PR_URL"
    edit_pr '.headRefName = "polecat/someone-else"'
    run_lane
    expect_existing_pr_blocked "Existing PR $PR_URL targets branch polecat/someone-else, want $BRANCH_NAME."
    end_case
}

test_lane_mr_existing_pr_wrong_base_blocks() {
    new_case mr_existing_pr_wrong_base_blocks
    build_rig unmerged
    write_bead merge_strategy=mr "existing_pr=$PR_URL"
    edit_pr '.baseRefName = "main"'
    run_lane
    expect_existing_pr_blocked "Existing PR $PR_URL targets base main, want $TARGET_NAME."
    end_case
}

test_lane_mr_existing_pr_wrong_repo_blocks() {
    new_case mr_existing_pr_wrong_repo_blocks
    build_rig unmerged
    write_bead merge_strategy=mr "existing_pr=$PR_URL"
    edit_pr '.url = "https://github.com/other/widgets/pull/7"'
    run_lane
    expect_existing_pr_blocked "Existing PR $PR_URL belongs to repo other/widgets, want $ORIGIN_REPO."
    end_case
}

test_lane_mr_existing_pr_wrong_head_repo_blocks() {
    new_case mr_existing_pr_wrong_head_repo_blocks
    build_rig unmerged
    write_bead merge_strategy=mr "existing_pr=$PR_URL"
    edit_pr '.headRepositoryOwner.login = "forker"'
    run_lane
    expect_existing_pr_blocked "Existing PR $PR_URL head repo forker/widgets, want $ORIGIN_REPO."
    end_case
}

test_lane_mr_4a_closes_pull_request_ready() {
    new_case mr_4a_closes_pull_request_ready
    build_rig unmerged
    write_bead merge_strategy=mr
    run_lane
    expect_lane mr
    expect_status 0
    expect "merge_result" "$(meta merge_result)" pull_request
    expect "merged_target" "$(meta merged_target)" "$TARGET_NAME"
    expect "rejection_reason" "$(meta rejection_reason)" "<unset>"
    expect "status" "$(bead status)" closed
    expect "close reason" "$(bead close_reason)" "Pull request ready: $PR_URL"
    expect "origin/$BRANCH_NAME" "$(origin_ref "$BRANCH_NAME")" "$TEMP_SHA"
    expect_target_unchanged
    expect_not_drained
    end_case
}

test_lane_mr_4b_refused_parks() {
    new_case mr_4b_refused_parks
    build_rig unmerged
    write_bead merge_strategy=mr
    run_lane require_merge_approval=true
    expect_lane mr
    expect "pr_number" "$(meta pr_number)" 7
    expect "merge_approval_state" "$(meta merge_approval_state)" awaiting_review
    case "$(meta merge_approval_gate_reason)" in
    "<unset>" | "") fail "merge_approval_gate_reason was not recorded" ;;
    esac
    output_has 'APPROVAL GATE REFUSED' || fail "no 'APPROVAL GATE REFUSED' in the output"
    expect_not_closed
    expect_not_drained
    expect_target_unchanged
    end_case
}

test_lane_mr_4b_approved_lands_and_closes() {
    new_case mr_4b_approved_lands_and_closes
    build_rig unmerged
    # What record-merge-approval.sh writes, for the head the lane will push.
    write_bead merge_strategy=mr \
        merge_approval.verdict=approved \
        merge_approval.pr_number=7 \
        "merge_approval.head_sha=$TEMP_SHA" \
        merge_approval.reviewer=testrig/specialists.iris \
        merge_approval.recorded_at=2026-09-27T00:00:00Z
    run_lane require_merge_approval=true
    expect_lane mr
    output_has 'GATE: approved' || fail "the real approval gate did not approve"
    expect "merge_approval_state" "$(meta merge_approval_state)" approved
    expect "merge_approval_gate_reason" "$(meta merge_approval_gate_reason)" "<unset>"
    expect "origin/integration" "$(origin_tip)" "$TEMP_SHA"
    expect "merge_result" "$(meta merge_result)" merged
    expect "merged_sha" "$(meta merged_sha)" "$TEMP_SHA"
    expect "status" "$(bead status)" closed
    expect "close reason" "$(bead close_reason)" "Merged to $TARGET_NAME at $(short_sha "$TEMP_SHA")"
    end_case
}

test_lane_mr_zero_diff_halts() {
    new_case mr_zero_diff_halts
    build_rig empty_moved
    write_bead merge_strategy=mr
    run_lane
    expect_lane mr
    expect_false_completion_halt
    expect "origin/$BRANCH_NAME" "$(origin_ref "$BRANCH_NAME")" "$FORK_SHA"
    [ ! -s "$T/gh.log" ] || fail "a pull request call was made for an empty branch: $(tr '\n' ';' <"$T/gh.log")"
    end_case
}

test_lane_mr_cleanup_with_target_in_second_worktree() {
    new_case mr_cleanup_with_target_in_second_worktree
    build_rig unmerged
    add_second_worktree
    write_bead merge_strategy=mr
    run_lane
    expect_lane mr
    expect_status 0
    expect "status" "$(bead status)" closed
    # The mr cleanup detaches onto the target, as the direct lane's does, so the
    # target being checked out in another worktree no longer stops it (gcp-l8td.6).
    ! output_has "already (checked out|used by worktree)" ||
        fail "the mr cleanup still tried to check the target out while another worktree has it"
    git -C "$REFINERY" symbolic-ref -q HEAD >/dev/null &&
        fail "the refinery clone's HEAD is $(git -C "$REFINERY" symbolic-ref HEAD), want detached"
    expect "the refinery clone's HEAD" "$(git -C "$REFINERY" rev-parse HEAD)" "$(origin_tip)"
    git -C "$REFINERY" rev-parse --verify -q refs/heads/temp >/dev/null &&
        fail "temp still exists after cleanup"
    expect "the second worktree's branch" "$(git -C "$T/second" symbolic-ref -q HEAD)" refs/heads/integration
    # The pull request needs its source branch: mr mode never deletes it.
    origin_ref "$BRANCH_NAME" >/dev/null || fail "origin lost $BRANCH_NAME; mr mode must keep it"
    end_case
}

# --- cases: local -----------------------------------------------------------

test_lane_local_mails_mayor() {
    local before
    new_case local_mails_mayor
    build_rig unmerged
    write_bead merge_strategy=local
    before=$(cat "$BEAD")
    run_lane
    expect_lane local
    logged gc "gc mail send mayor/ -s ESCALATION: unsupported merge_strategy=local -m Work bead: $WORK_ID" ||
        fail "no ESCALATION mail to mayor/ for merge_strategy=local"
    [ "$(cat "$BEAD")" = "$before" ] || fail "the local lane changed the bead"
    ! logged gc "gc bd close" || fail "the local lane closed the bead"
    ! logged gc "gc bd mol burn" || fail "the local lane burned the wisp"
    [ ! -s "$T/gh.log" ] || fail "the local lane called gh"
    expect "the script's exit status" "$SCRIPT_STATUS" 11
    expect_status 0
    expect_not_drained
    expect_target_unchanged
    end_case
}

# --- cases: locating the script ---------------------------------------------

test_locator_uses_formula_source() {
    local pack before
    new_case locator_uses_formula_source
    build_rig unmerged
    write_bead
    before=$(cat "$BEAD")
    # A pack tree of its own, whose merge-push.sh only records that it ran. GC_PACK_DIR
    # keeps pointing at the real pack, so only the formula's own source can have won.
    pack="$T/pack"
    mkdir -p "$pack/formulas" "$pack/assets/scripts/refinery"
    : >"$pack/formulas/mol-refinery-patrol.toml"
    cat >"$pack/assets/scripts/refinery/merge-push.sh" <<'MARK'
#!/usr/bin/env bash
printf 'ran: %s\n' "$*" >>"$MARKER_FILE"
echo "merge-push: RESULT 0 marker"
exit 0
MARK
    chmod +x "$pack/assets/scripts/refinery/merge-push.sh"
    LANE_ENV_EXTRA=(GC_STUB_FORMULA_SOURCE="$pack/formulas/mol-refinery-patrol.toml" MARKER_FILE="$T/marker")
    run_lane
    expect_status 0
    expect "the formula's pack script's calls" "$(cat "$T/marker" 2>/dev/null)" "ran: --work $WORK_ID"
    ! output_has '^merge-push: config ' || fail "the real merge-push.sh ran, so GC_PACK_DIR won over the formula's source"
    [ "$(cat "$BEAD")" = "$before" ] || fail "the bead changed"
    end_case
}

test_locator_fails_closed() {
    local before
    new_case locator_fails_closed
    build_rig unmerged
    write_bead
    before=$(cat "$BEAD")
    # gc names no formula and GC_PACK_DIR is empty: nothing resolves.
    LANE_ENV_EXTRA=(GC_PACK_DIR=)
    run_lane
    expect_status 1
    expect_drained
    output_has 'merge-push.sh not runnable' || fail "no 'merge-push.sh not runnable' line in the output"
    ! output_has '^merge-push: (config|LANE|RESULT) ' || fail "merge-push.sh ran although nothing resolved it"
    [ "$(cat "$BEAD")" = "$before" ] || fail "the bead changed"
    expect_not_closed
    ! logged gc "gc bd update" || fail "the step wrote to a bead: $(grep -F 'gc bd update' "$T/gc.log" | tr '\n' ';')"
    expect_target_unchanged
    end_case
}

# --- cases: the script only -------------------------------------------------

# resolve_in_source_mode <config-json> <GC_AGENT> [flag ...] — source the script
# in source-only mode, run resolve_config, and print the resolved values one
# key=value per line. Exits with resolve_config's status.
resolve_in_source_mode() {
    local config="$1" agent="$2"
    shift 2
    (
        # The script is written for, and characterized under, a plain shell.
        set +uo pipefail
        unset REFINERY_GH
        export GC_RIG=testrig GC_AGENT="$agent" MERGE_PUSH_CONFIG_JSON="$config"
        export MERGE_PUSH_SOURCE_ONLY=1
        # shellcheck source=/dev/null # the script under test, chosen at run time
        . "$SCRIPT" || exit 91
        resolve_config --work "$WORK_ID" "$@" >/dev/null || exit
        printf '%s\n' "require=$CFG_REQUIRE_MERGE_APPROVAL" "review=$CFG_REVIEW_AGENT" \
            "delete=$CFG_DELETE_MERGED_BRANCHES" "target=$CFG_TARGET_DEFAULT" \
            "prefix=$CFG_BINDING_PREFIX" "rig=$CFG_RIG"
    )
}

# resolved <output> <key> — one value from resolve_in_source_mode's output.
resolved() {
    printf '%s\n' "$1" | sed -n "s/^$2=//p"
}

# write_rig_config <file> <FormulaVars-json> — testrig (and a decoy rig whose
# values must never be read) with the given FormulaVars.
write_rig_config() {
    jq -n --argjson vars "$2" '{config: {Rigs: [
        {Name: "otherrig", DefaultBranch: "decoy", FormulaVars: {review_agent: "decoy", target_branch: "decoy"}},
        {Name: "testrig", DefaultBranch: "integration", FormulaVars: $vars}]}}' >"$1"
}

test_script_invariants() {
    new_case script_invariants
    [ -x "$SCRIPT" ] || fail "$SCRIPT is not executable"
    expect "template placeholders in the script" "$(grep -c '{{' "$SCRIPT")" 0
    expect "patrol-loop control in the script" "$(grep -cE 'drain-ack|gc bd mol (wisp|burn)' "$SCRIPT")" 0
    end_case
}

test_config_precedence() {
    local out
    new_case config_precedence
    write_rig_config "$T/vars.json" '{"review_agent": "specialists.iris", "require_merge_approval": "true",
        "delete_merged_branches": "false", "target_branch": "develop", "binding_prefix": "vars."}'
    write_rig_config "$T/bare.json" '{}'
    write_rig_config "$T/empty.json" '{"review_agent": "", "target_branch": "", "require_merge_approval": ""}'

    # A flag beats FormulaVars.
    out=$(resolve_in_source_mode "$T/vars.json" testrig/gastown.refinery \
        --require-approval off --review-agent flag.agent --delete-merged-branches maybe \
        --target-default main --binding-prefix flag.) || fail "resolve_config failed with flags"
    expect "require_merge_approval (flag over FormulaVars)" "$(resolved "$out" require)" off
    expect "review_agent (flag over FormulaVars)" "$(resolved "$out" review)" flag.agent
    expect "delete_merged_branches (flag over FormulaVars)" "$(resolved "$out" delete)" maybe
    expect "target default (flag over FormulaVars)" "$(resolved "$out" target)" main
    expect "binding_prefix (flag over FormulaVars)" "$(resolved "$out" prefix)" flag.

    # FormulaVars beat derived values and the embedded defaults.
    out=$(resolve_in_source_mode "$T/vars.json" testrig/gastown.refinery) ||
        fail "resolve_config failed with FormulaVars"
    expect "require_merge_approval (FormulaVars over default)" "$(resolved "$out" require)" true
    expect "review_agent (FormulaVars over default)" "$(resolved "$out" review)" specialists.iris
    expect "delete_merged_branches (FormulaVars over default)" "$(resolved "$out" delete)" false
    expect "target default (FormulaVars over DefaultBranch)" "$(resolved "$out" target)" develop
    expect "binding_prefix (FormulaVars over GC_AGENT)" "$(resolved "$out" prefix)" vars.
    expect "rig (GC_RIG)" "$(resolved "$out" rig)" testrig

    # Derived values beat the defaults; the defaults apply when nothing speaks.
    out=$(resolve_in_source_mode "$T/bare.json" testrig/gastown.refinery) ||
        fail "resolve_config failed with empty FormulaVars"
    expect "target default (derived from DefaultBranch)" "$(resolved "$out" target)" integration
    expect "binding_prefix (derived from GC_AGENT)" "$(resolved "$out" prefix)" gastown.
    expect "require_merge_approval (default)" "$(resolved "$out" require)" false
    expect "review_agent (default)" "$(resolved "$out" review)" ""
    expect "delete_merged_branches (default)" "$(resolved "$out" delete)" true

    # A FormulaVars key that is PRESENT wins even when empty.
    out=$(resolve_in_source_mode "$T/empty.json" testrig/gastown.refinery) ||
        fail "resolve_config failed with present-but-empty FormulaVars"
    expect "review_agent (present but empty)" "$(resolved "$out" review)" ""
    expect "target default (present but empty, not DefaultBranch)" "$(resolved "$out" target)" ""
    expect "require_merge_approval (present but empty)" "$(resolved "$out" require)" ""
    end_case
}

test_config_binding_prefix_derivation() {
    local out status
    new_case config_binding_prefix_derivation
    write_rig_config "$T/bare.json" '{}'
    out=$(resolve_in_source_mode "$T/bare.json" testrig/gastown.refinery) ||
        fail "resolve_config failed for testrig/gastown.refinery"
    expect "binding_prefix for testrig/gastown.refinery" "$(resolved "$out" prefix)" gastown.
    out=$(resolve_in_source_mode "$T/bare.json" testrig/refinery) ||
        fail "resolve_config failed for testrig/refinery"
    expect "binding_prefix for testrig/refinery" "$(resolved "$out" prefix)" ""
    # Underivable: the whole script exits 1 before it touches anything.
    (
        cd "$T" || exit 90
        env -i PATH="$HARNESS/bin-gh" HOME="$T/home" TMPDIR="$T/tmp" \
            GC_RIG=testrig GC_AGENT=other/gastown.refinery \
            MERGE_PUSH_CONFIG_JSON="$T/bare.json" \
            GC_STUB_LOG="$T/gc.log" STUB_UNEXPECTED="$T/unexpected" \
            "$BASH" "$SCRIPT" --work "$WORK_ID"
    ) >"$T/lane.out" 2>&1
    status=$?
    expect "the script's exit status for GC_AGENT=other/gastown.refinery" "$status" 1
    output_has 'cannot derive binding_prefix' || fail "no 'cannot derive binding_prefix' in the output"
    tail -n 1 "$T/lane.out" | grep -qE '^merge-push: RESULT 1 ' ||
        fail "the last line is not 'merge-push: RESULT 1 ...': $(tail -n 1 "$T/lane.out")"
    [ ! -s "$T/gc.log" ] || fail "the script called gc before rejecting its config: $(tr '\n' ';' <"$T/gc.log")"
    end_case
}

test_config_unreadable_turns_gate_on() {
    new_case config_unreadable_turns_gate_on
    build_rig unmerged
    write_bead
    LANE_ENV_EXTRA=(MERGE_PUSH_CONFIG_JSON="$T/no-such-config.json")
    run_lane
    expect_lane mr
    expect "the script's exit status" "$SCRIPT_STATUS" 4
    output_has 'require_merge_approval resolves ON \(fail closed\)' || fail "no fail-closed line in the output"
    output_has 'APPROVAL GATE REFUSED' || fail "no 'APPROVAL GATE REFUSED' in the output"
    expect_not_closed
    expect_target_unchanged
    end_case
}

test_config_defaults_match_formula_vars() {
    local out name key want
    new_case config_defaults_match_formula_vars
    write_rig_config "$T/bare.json" '{}'
    out=$(resolve_in_source_mode "$T/bare.json" testrig/gastown.refinery) ||
        fail "resolve_config failed with empty FormulaVars"
    for name in require_merge_approval:require review_agent:review delete_merged_branches:delete; do
        key="${name#*:}"
        name="${name%%:*}"
        want=$(python3 - "$FORMULA" "$name" <<'PY'
import sys
import tomllib

with open(sys.argv[1], "rb") as handle:
    print(str(tomllib.load(handle)["vars"][sys.argv[2]].get("default", "")))
PY
        ) || fail "could not read [vars.$name].default from $FORMULA"
        expect "the script's embedded default for $name vs [vars.$name].default" "$(resolved "$out" "$key")" "$want"
    done
    end_case
}

test_script_honors_refinery_gh() {
    new_case script_honors_refinery_gh
    build_rig unmerged
    write_bead merge_strategy=mr
    LANE_BIN="$HARNESS/bin-refinery-gh"
    LANE_ENV_EXTRA=(REFINERY_GH=refinery-gh)
    run_lane
    expect_lane mr
    expect_status 0
    grep -qE '^gh pr (create|view) ' "$T/gh.log" ||
        fail "refinery-gh received no pull request call; its calls: $(tr '\n' ';' <"$T/gh.log")"
    expect "pr_url" "$(meta pr_url)" "$PR_URL"
    expect "close reason" "$(bead close_reason)" "Pull request ready: $PR_URL"
    end_case
}

# --- runner -----------------------------------------------------------------

HARNESS=$(mktemp -d "${TMPDIR:-/tmp}/merge-lanes-harness.XXXXXX")
trap 'rm -rf "$HARNESS"' EXIT
make_bin "$HARNESS/bin-gh" with-gh
make_bin "$HARNESS/bin-nogh"
# No gh at all, only the gh stub installed under another name.
make_bin "$HARNESS/bin-refinery-gh"
write_gh_stub "$HARNESS"
mv -f "$HARNESS/gh" "$HARNESS/bin-refinery-gh/refinery-gh"

# Fail fast and loudly if the formula no longer carries the invoke block.
if ! extract_invoke "$HARNESS/invoke.sh"; then
    echo "FAIL: cannot extract the merge-push:invoke block from $FORMULA" >&2
    exit 1
fi

# The block finds merge-push.sh, and the script finds the approval gate, by
# position in a pack tree. A SCRIPT override is staged as one, beside the real
# gate, so the same block runs it.
if [ "$SCRIPT" != "$PACK_DIR/assets/scripts/refinery/merge-push.sh" ]; then
    mkdir -p "$HARNESS/pack/assets/scripts/refinery"
    cp -R "$PACK_DIR/assets/scripts/checks" "$HARNESS/pack/assets/scripts/checks"
    cp -f "$SCRIPT" "$HARNESS/pack/assets/scripts/refinery/merge-push.sh"
    chmod +x "$HARNESS/pack/assets/scripts/refinery/merge-push.sh"
    PACK_DIR="$HARNESS/pack"
fi

run_all_cases() {
    PASS_CASES=0
    test_lane_direct_lands_and_closes
    test_lane_direct_already_merged_ancestor
    test_lane_direct_already_merged_patch_id
    test_lane_direct_false_completion_halts
    test_lane_direct_lost_race_then_lands
    test_lane_direct_push_veto_status_7
    test_lane_direct_approval_on_promotes_to_mr
    test_lane_mr_creates_pr_via_gh
    test_lane_mr_reuses_existing_pr
    test_lane_mr_rest_fallback_without_gh
    test_lane_mr_existing_pr_not_found_blocks
    test_lane_mr_existing_pr_not_open_blocks
    test_lane_mr_existing_pr_wrong_head_blocks
    test_lane_mr_existing_pr_wrong_base_blocks
    test_lane_mr_existing_pr_wrong_repo_blocks
    test_lane_mr_existing_pr_wrong_head_repo_blocks
    test_lane_mr_4a_closes_pull_request_ready
    test_lane_mr_4b_refused_parks
    test_lane_mr_4b_approved_lands_and_closes
    test_lane_mr_zero_diff_halts
    test_lane_local_mails_mayor
    test_lane_direct_cleanup_with_target_in_second_worktree
    test_lane_mr_cleanup_with_target_in_second_worktree
    test_locator_uses_formula_source
    test_locator_fails_closed
    echo "$ADAPTER: $PASS_CASES cases"
}

run_all_cases
if [ "$PASS_CASES" -ne 25 ]; then
    echo "FAIL: want 25 cases (23 lane, 2 locator); ran $PASS_CASES" >&2
    FAILURES=$((FAILURES + 1))
fi

test_script_invariants
test_config_precedence
test_config_binding_prefix_derivation
test_config_unreadable_turns_gate_on
test_config_defaults_match_formula_vars
test_script_honors_refinery_gh

if [ "$FAILURES" -ne 0 ]; then
    echo "refinery merge-lane characterization: $FAILURES failure(s)" >&2
    exit 1
fi
echo "refinery merge-lane characterization passed"
