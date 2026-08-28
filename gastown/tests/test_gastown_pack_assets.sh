#!/usr/bin/env bash
# These are contract tests over pack files: nearly every assertion greps for a
# literal shell snippet, so single-quoted `$VAR` is the point, not an error.
# shellcheck disable=SC2016
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
GASTOWN="$ROOT/gastown"

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

parse_toml() {
    python3 - "$@" <<'PY'
import sys
import tomllib

for path in sys.argv[1:]:
    with open(path, "rb") as handle:
        tomllib.load(handle)
PY
}

test_dog_assets_are_pack_local() {
    [[ -f "$GASTOWN/agents/dog/agent.toml" ]] || fail "missing dog agent config"
    [[ -f "$GASTOWN/agents/dog/prompt.template.md" ]] || fail "missing dog prompt"
    [[ -f "$GASTOWN/formulas/mol-shutdown-dance.toml" ]] || fail "missing shutdown dance formula"
    parse_toml "$GASTOWN/agents/dog/agent.toml" "$GASTOWN/formulas/mol-shutdown-dance.toml"
    grep -F 'wake_mode = "fresh"' "$GASTOWN/agents/dog/agent.toml" >/dev/null ||
        fail "dog agent should own wake_mode"
    grep -F 'work_dir = ".gc/agents/dogs/{{.AgentBase}}"' "$GASTOWN/agents/dog/agent.toml" >/dev/null ||
        fail "dog agent should own work_dir"
    ! grep -F 'fallback = true' "$GASTOWN/agents/dog/agent.toml" >/dev/null ||
        fail "gastown dog should be authoritative over fallback dog providers"
    ! grep -A3 -F '[[patches.agent]]' "$GASTOWN/pack.toml" | grep -F 'name = "dog"' >/dev/null ||
        fail "dog should not be split between pack-local agent and same-name patch"
    [[ ! -e "$GASTOWN/agents/dog/overlay/.gitkeep" ]] ||
        fail "dog overlay placeholder should not be present without an overlay contract"
}

test_retired_dog_formulas_are_not_reintroduced() {
    [[ ! -e "$GASTOWN/formulas/mol-dog-jsonl.toml" ]] || fail "mol-dog-jsonl formula should remain retired"
    [[ ! -e "$GASTOWN/formulas/mol-dog-reaper.toml" ]] || fail "mol-dog-reaper formula should remain retired"
    ! grep -R --exclude='test_gastown_pack_assets.sh' "mol-dog-jsonl\\|mol-dog-reaper" "$GASTOWN" >/dev/null ||
        fail "gastown pack should not advertise retired dog formulas"
}

test_shutdown_dance_contracts_are_executable() {
    local formula="$GASTOWN/formulas/mol-shutdown-dance.toml"

    ! grep -F '[vars.warrant_id]' "$formula" >/dev/null ||
        fail "warrant_id should be the claimed work bead, not a required formula var"
    grep -F 'gc bd show "$GC_BEAD_ID"' "$formula" >/dev/null ||
        fail "shutdown dance should inspect the claimed warrant bead"
    grep -F 'gc bd close "$GC_BEAD_ID"' "$formula" >/dev/null ||
        fail "shutdown dance should close the claimed warrant bead"
    ! grep -F '<wisp-id>' "$formula" >/dev/null ||
        fail "shutdown dance should not contain raw wisp placeholders"
    ! grep -F '<work-bead>' "$formula" >/dev/null ||
        fail "shutdown dance should not contain raw work bead placeholders"
    ! grep -F 'gc mail send {{requester}}/' "$formula" >/dev/null ||
        fail "routine dog requester reporting must use nudge, not mail"
    grep -F 'requester_endpoint="${requester%/}/"' "$formula" >/dev/null ||
        fail "shutdown dance should normalize requester endpoints"
    grep -F 'gc session nudge "$requester_endpoint" "DOG_DONE:' "$formula" >/dev/null ||
        fail "shutdown dance should notify requester with DOG_DONE nudges"
    ! grep -F 'gc session peek "{{target}}"' "$formula" >/dev/null ||
        fail "shutdown dance should use quoted target shell variables for peeks"
    ! grep -F 'gc session kill "{{target}}"' "$formula" >/dev/null ||
        fail "shutdown dance should use quoted target shell variables for kills"
    grep -F 'Verify the warrant bead exists and is not closed' "$formula" >/dev/null ||
        fail "receive step should verify the warrant is not closed rather than demanding open"
    grep -F 'Both `open` and `in_progress` are valid warrant states' "$formula" >/dev/null ||
        fail "receive step should explicitly accept open and in_progress warrant states"
    ! grep -F 'exists and is open' "$formula" >/dev/null ||
        fail "receive step must not regress to an open-only warrant instruction; claimed warrants are in_progress"
}

test_shutdown_dance_lifecycle_and_audit_contracts() {
    local formula="$GASTOWN/formulas/mol-shutdown-dance.toml"
    local prompt="$GASTOWN/agents/dog/prompt.template.md"

    ! grep -Fi 'burn' "$formula" >/dev/null ||
        fail "early-exit paths should drain-ack and exit, not burn a wisp that was never poured"
    [[ "$(grep -c 'gc runtime drain-ack' "$formula")" -ge 8 ]] ||
        fail "every early-exit path and the epitaph should end with gc runtime drain-ack"
    local malformed_branches malformed_closes malformed_drains
    malformed_branches="$(grep -c 'is missing target or reason' "$formula" || true)"
    malformed_closes="$(grep -A4 'is missing target or reason' "$formula" | grep -cF 'gc bd close "$GC_BEAD_ID"' || true)"
    malformed_drains="$(grep -A4 'is missing target or reason' "$formula" | grep -cF 'gc runtime drain-ack' || true)"
    [[ "$malformed_branches" -ge 1 ]] ||
        fail "shutdown dance should validate warrant target/reason metadata"
    [[ "$malformed_closes" -eq "$malformed_branches" ]] ||
        fail "every malformed-warrant branch must close the claimed warrant before exiting"
    [[ "$malformed_drains" -eq "$malformed_branches" ]] ||
        fail "every malformed-warrant branch must drain-ack before exiting, not leak the claimed warrant"
    grep -F 'MALFORMED_WARRANT' "$formula" >/dev/null ||
        fail "malformed warrants should close with a malformed-warrant audit reason"
    ! grep -E '^\[vars' "$formula" >/dev/null ||
        fail "warrant values come from bead metadata; the formula should not declare pour vars"
    grep -F 'EXECUTE_FAILED: kill did not take effect' "$formula" >/dev/null ||
        fail "kill failures should close the warrant as EXECUTE_FAILED, not Executed"
    grep -F 'DOG_DONE: $target - EXECUTE_FAILED (escalated)' "$formula" >/dev/null ||
        fail "kill failures should notify the requester with EXECUTE_FAILED, not EXECUTED"
    grep -F 'gone or shows fresh startup output' "$formula" >/dev/null ||
        fail "execute verification should treat gone-or-freshly-restarted as kill success"
    ! grep -F '{{requester}}' "$prompt" >/dev/null ||
        fail "dog prompt should use the normalized requester endpoint, not raw requester templates"
    ! grep -F 'nudge deacon/' "$prompt" >/dev/null ||
        fail "dog prompt should notify the warrant's requester, not a hardcoded deacon endpoint"
    grep -F 'gc session nudge "$requester_endpoint"' "$prompt" >/dev/null ||
        fail "dog prompt DOG_DONE guidance should use the normalized requester endpoint"
}

test_composition_is_documented() {
    # The retired maintenance pack is gone: the runtime composes the builtin
    # core pack via explicit city.toml includes, and gastown owns the only
    # mol-shutdown-dance. The docs must describe that model, not the old
    # fallback/ordering workarounds.
    grep -F 'builtin core pack' "$GASTOWN/README.md" >/dev/null ||
        fail "README should attribute mechanical housekeeping to the builtin core pack"
    ! grep -F '[imports.maintenance]' "$GASTOWN/README.md" >/dev/null ||
        fail "README should not reference the retired maintenance pack import"
    ! grep -Fi 'implicit maintenance' "$GASTOWN/README.md" >/dev/null ||
        fail "README should not describe implicit maintenance injection"
    grep -F 'gc formula show mol-shutdown-dance' "$GASTOWN/README.md" >/dev/null ||
        fail "README should document how to verify the effective shutdown-dance formula"
    grep -F 'builtin core' "$GASTOWN/pack.toml" >/dev/null ||
        fail "pack.toml should attribute mechanical housekeeping to the builtin core pack"
    ! grep -F '[imports.maintenance]' "$GASTOWN/pack.toml" >/dev/null ||
        fail "pack.toml should not reference the retired maintenance pack import"
}

test_polecat_startup_uses_standard_hook_claim() {
    local agent prompt propulsion
    agent="$GASTOWN/agents/polecat/agent.toml"
    prompt="$GASTOWN/agents/polecat/prompt.template.md"
    propulsion="$GASTOWN/template-fragments/propulsion.template.md"

    grep -F 'gc hook --claim --json' "$agent" >/dev/null ||
        fail "polecat nudge should call the standard hook claim path"
    grep -F 'gc hook --claim --json' "$prompt" >/dev/null ||
        fail "polecat prompt should call the standard hook claim path"
    grep -F 'gc hook --claim --json' "$propulsion" >/dev/null ||
        fail "polecat propulsion fragment should call the standard hook claim path"
    grep -F 'After closing any formula step bead, immediately run' "$prompt" >/dev/null ||
        fail "polecat prompt must require hook continuation after each formula step"
    grep -F 'After closing a step bead,' "$propulsion" >/dev/null ||
        fail "polecat propulsion fragment must require hook continuation after each formula step"
    ! grep -F 'run `gc hook` or' "$prompt" >/dev/null ||
        fail "polecat prompt must not regress to an unclaimed hook/work-query choice"
    ! grep -F 'run `gc hook` or' "$propulsion" >/dev/null ||
        fail "polecat propulsion fragment must not regress to an unclaimed hook/work-query choice"
}

test_review_leg_contract_forbids_synthetic_mutation() {
    local formula prompt
    formula="$GASTOWN/formulas/mol-review-leg.toml"
    prompt="$GASTOWN/agents/polecat/prompt.template.md"

    grep -F 'Do not create synthetic/test beads' "$formula" >/dev/null ||
        fail "review-leg formula must forbid synthetic test beads"
    grep -F 'Do not create test beads' "$formula" >/dev/null ||
        fail "review-leg load-assignment must forbid test bead creation"
    grep -F 'The only allowed bead mutations are the formula-prescribed' "$formula" >/dev/null ||
        fail "review-leg formula must define allowed mutation boundary"
    grep -F 'treat that text as' "$formula" >/dev/null ||
        fail "review-leg formula must treat plans/checklists as review subject matter"
    grep -F 'Do not start cities, spawn sessions, route extra work' "$formula" >/dev/null ||
        fail "review-leg formula must forbid executing reviewed checklist items"
    grep -F 'Formula-specific non-implementation assignments may explicitly tell you' "$prompt" >/dev/null ||
        fail "polecat prompt must allow formula-specific review/control close steps"
    ! grep -F '`gc bd close`, `gc bd close`' "$prompt" >/dev/null ||
        fail "polecat prompt must not duplicate its close prohibition"
    grep -F 'Default implementation formula: `mol-polecat-work`' "$prompt" >/dev/null ||
        fail "polecat prompt must describe mol-polecat-work as the default implementation formula"
    ! grep -F '**You MUST NOT close beads. EVER. No exceptions.**' "$prompt" >/dev/null ||
        fail "polecat prompt must not globally forbid review-leg close steps"
}

test_refinery_direct_merge_is_worktree_safe_and_fail_closed() {
    local formula direct_block
    formula="$GASTOWN/formulas/mol-refinery-patrol.toml"

    direct_block=$(python3 - "$formula" <<'PY'
import sys
text = open(sys.argv[1], encoding="utf-8").read()
start = text.index('**If MERGE_STRATEGY = "direct"')
end = text.index('**If MERGE_STRATEGY = "mr"')
print(text[start:end])
PY
)

    # The worktree base is a resolved SHA, not `origin/$TARGET`. Same detached
    # worktree as before — the target branch may be checked out in the rig's
    # main worktree — but pinning the base closes the ref-vs-SHA gap between
    # the tip the merge is performed on and the tip the advance check compares
    # against.
    [[ "$direct_block" == *'git worktree add --detach "$mfp_wt" "$BEFORE_SHA"'* ]] ||
        fail "direct refinery merge must use a detached target worktree pinned to the resolved BEFORE_SHA"
    [[ "$direct_block" == *'+refs/heads/${TARGET}:refs/remotes/origin/${TARGET}'* ]] ||
        fail "direct refinery merge refspecs must brace TARGET for zsh-safe expansion"
    [[ "$direct_block" == *'git -C "$mfp_wt" push origin "HEAD:$TARGET"'* ]] ||
        fail "direct refinery merge must push the verified merge worktree HEAD"

    # gcp-p87: the abort must not depend on `set -e` propagating through the
    # refinery's execution harness — it did not, and the lane ran on into the
    # metadata write and the close after a failed ff-merge.
    [[ "$direct_block" == *'mfp_merge_status=$?'* ]] ||
        fail "direct refinery merge must check the ff-merge exit status explicitly"
    ! printf '%s\n' "$direct_block" | grep -E '^[[:space:]]*set[[:space:]]+-[a-z]*e' >/dev/null ||
        fail "direct refinery merge must not rely on set -e for its abort path"

    # gcp-p87: `[ "$MERGED_SHA" != "$REMOTE" ]` was tautological on exactly the
    # failure path it guarded — after a failed ff-merge the worktree HEAD is
    # still the target tip, pushing an unchanged HEAD is a successful no-op, and
    # the comparison was the old tip against itself. Verification must instead
    # read the target back after the push and require that it ADVANCED, and that
    # it advanced BY THIS BRANCH.
    ! [[ "$direct_block" == *'[ "$MERGED_SHA" != "$REMOTE" ]'* ]] ||
        fail "direct refinery merge still carries the tautological pre-push SHA comparison"
    [[ "$direct_block" == *'[ "$AFTER_SHA" = "$BEFORE_SHA" ]'* ]] ||
        fail "direct refinery merge must require the target to have advanced"
    [[ "$direct_block" == *'git merge-base --is-ancestor "$TEMP_SHA" "$AFTER_SHA"'* ]] ||
        fail "direct refinery merge must require the target to have advanced by this branch"
    [[ "$direct_block" == *'STOP. Do not mutate bead state.'* ]] ||
        fail "direct refinery merge must fail closed before metadata writes"
    ! printf '%s\n' "$direct_block" | grep -E '^[[:space:]]*git checkout \$TARGET([[:space:]]|$)' >/dev/null ||
        fail "direct refinery merge must not checkout target branch in the active worktree"

    python3 - "$formula" <<'PY' || fail "direct refinery merge must verify origin before setting merged metadata"
import sys
text = open(sys.argv[1], encoding="utf-8").read()
start = text.index('**If MERGE_STRATEGY = "direct"')
end = text.index('**If MERGE_STRATEGY = "mr"')
block = text[start:end]
verify = block.index('git merge-base --is-ancestor "$TEMP_SHA" "$AFTER_SHA"')
metadata = block.index('--set-metadata merge_result=merged')
if verify >= metadata:
    raise SystemExit(1)
PY
}

test_post_merge_worktree_teardown_has_an_owner() {
    local reaper="$GASTOWN/assets/scripts/polecat-worktree-reap.sh"
    local witness_cfg="$GASTOWN/agents/witness/agent.toml"
    local witness_prompt="$GASTOWN/agents/witness/prompt.template.md"
    local patrol="$GASTOWN/formulas/mol-witness-patrol.toml"
    local polecat="$GASTOWN/formulas/mol-polecat-work.toml"

    [[ -f "$reaper" ]] || fail "missing post-merge worktree reaper script"
    [[ -x "$reaper" ]] || fail "worktree reaper must be executable"
    parse_toml "$witness_cfg" "$patrol" "$polecat"

    # The reaper needs a wiring that actually fires. A formula step cannot name
    # it (pack assets install into a content-hashed cache), so pre_start with
    # the config-dir template is the only stable handle.
    grep -F 'pre_start = ["{{.ConfigDir}}/assets/scripts/polecat-worktree-reap.sh {{.RigRoot}} --rig {{.Rig}}"]' \
        "$witness_cfg" >/dev/null ||
        fail "witness must run the worktree reaper from pre_start with rig root and rig name"

    # Ownership must be stated where each role reads it, or teardown drifts
    # back to nobody.
    grep -F 'id = "reap-merged-worktrees"' "$patrol" >/dev/null ||
        fail "witness patrol should own a post-merge worktree teardown step"
    grep -F 'needs = ["reap-merged-worktrees"]' "$patrol" >/dev/null ||
        fail "the teardown step must be wired into the patrol chain, not orphaned"
    grep -F 'Reap per-bead polecat worktrees once their bead closes' "$witness_prompt" >/dev/null ||
        fail "witness prompt should list post-merge worktree teardown as a duty"
    grep -F 'Do NOT delete this worktree yourself' "$polecat" >/dev/null ||
        fail "polecat formula should point worktree teardown at the witness"

    # The live-owner gate reads metadata.polecat_session off the WORK bead. The
    # startup claim block only stamps the step bead, so without this write the
    # gate is decorative and PR rework can lose its worktree.
    grep -F -e '--set-metadata polecat_session="${BEADS_ACTOR:-${GC_SESSION_NAME:-${GC_SESSION_ID:-${GC_AGENT:-}}}}"' \
        "$polecat" >/dev/null ||
        fail "workspace-setup must stamp polecat_session on the work bead for the teardown liveness gate"
    python3 - "$polecat" <<'PY' || fail "polecat_session must be stamped alongside work_dir, not somewhere unrelated"
import sys
text = open(sys.argv[1], encoding="utf-8").read()
start = text.index('**If no worktree** — create one scoped to the bead')
end = text.index('**3. Ensure branch exists.**')
block = text[start:end]
if 'work_dir="$WORKTREE_PATH"' not in block or 'polecat_session=' not in block:
    raise SystemExit(1)
PY

    # The gates are the safety contract; losing any one of them silently turns
    # housekeeping into data loss.
    grep -F '*/polecats/*/worktrees/*' "$reaper" >/dev/null ||
        fail "reaper must restrict candidates to per-bead polecat worktrees"
    grep -F '[ "$STATUS" != "closed" ]' "$reaper" >/dev/null ||
        fail "reaper must reap only closed beads"
    grep -F 'git -C "$WT" status --porcelain' "$reaper" >/dev/null ||
        fail "reaper must refuse to remove a worktree with uncommitted work"
    grep -F 'session_state "$OWNER"' "$reaper" >/dev/null ||
        fail "reaper must defer while a live session still owns the bead"

    # Gate 4 must FAIL CLOSED. A roster read that errors or does not parse is
    # `unconfirmed`, never `absent` — the same rule the witness's absent-confirm
    # block enforces. The old fallback to an empty roster made the gate vanish
    # on exactly the reads that failed.
    ! grep -F '{"sessions":[]}' "$reaper" >/dev/null ||
        fail "reaper must not fall back to an empty session roster; that makes the liveness gate fail open"
    grep -F 'ROSTER_STATE="unconfirmed"' "$reaper" >/dev/null ||
        fail "reaper must seed the roster state to unconfirmed and promote it only on a clean read"
    grep -F 'worktree_owner_unconfirmed' "$reaper" >/dev/null ||
        fail "reaper must skip and log when session liveness cannot be confirmed"

    # Staged rollout: dry run is the default and the witness wiring must not
    # opt in, so real removal cannot begin on a pin bump alone.
    grep -x -F 'DRY_RUN=1' "$reaper" >/dev/null ||
        fail "reaper must default to dry run"
    grep -F -- '--no-dry-run) DRY_RUN=0 ;;' "$reaper" >/dev/null ||
        fail "reaper must make real removal opt-in behind --no-dry-run"
    ! grep -E '^pre_start = .*--no-dry-run' "$witness_cfg" >/dev/null ||
        fail "witness pre_start must not enable live removal while the rollout is staged"

    # The reaper cleans up around the canonical checkout; it must never write
    # into it.
    ! grep -F 'LOG_DIR="$RIG_ROOT' "$reaper" >/dev/null ||
        fail "reaper must not default its log inside the rig repo"

    # pre_start is bounded by [session] setup_timeout (10s) and SIGKILLed on
    # overrun, which fails the session start and eventually latches the
    # supervisor circuit breaker open — gcp-ntbf, where a per-worktree bead
    # read cost winnow its witness for 26h. Two shape rules keep housekeeping
    # incapable of blocking the start, and both are easy to undo by accident.
    grep -F 'show "${BEAD_IDS_ARGV[@]}"' "$reaper" >/dev/null ||
        fail "reaper must read every candidate bead in one bulk gc bd show, not one call per worktree"
    ! grep -E 'gc_bd show|GC_BD\[@\]\}" show "\$BEAD"' "$reaper" >/dev/null ||
        fail "reaper must not query beads per worktree; that is the N+1 that killed the witness"
    grep -F 'budget_left' "$reaper" >/dev/null ||
        fail "reaper must bound its own wall clock so it can never outlive the pre_start deadline"
    grep -F 'worktree_budget_exhausted' "$reaper" >/dev/null ||
        fail "reaper must record and yield when its budget expires rather than being SIGKILLed"
    grep -F 'worktree_budget_exhausted' "$patrol" >/dev/null ||
        fail "patrol log-review table must explain the budget-exhausted event the reaper can emit"
    grep -F 'worktree_bead_query_failed' "$patrol" >/dev/null ||
        fail "patrol log-review table must explain the bulk-query-failed event the reaper can emit"

    # gcp-mqu9: budget truncation used to be reported with the same wording as a
    # data-plane failure, which sent two investigations at a healthy Dolt server.
    # A check the budget never allowed must name itself, not a subsystem the run
    # never called.
    grep -F 'worktree_budget_truncated' "$reaper" >/dev/null ||
        fail "reaper must report a check its budget skipped as truncation, not as a failure of the subsystem it never called"
    grep -F 'classify_outcome' "$reaper" >/dev/null ||
        fail "reaper must classify each bounded call as skipped/timeout/failed; a bare 124 cannot tell not-attempted from overran"
    ! grep -F 'git status failed in the worktree' "$reaper" >/dev/null ||
        fail "reaper must not assert git status failed without knowing that it ran"

    # The log is forensics, so a line must carry the time of ITS OWN event.
    grep -F -e '--arg ts "$(date -u' "$reaper" >/dev/null ||
        fail "reaper must stamp each log line when the event happens, not once at the start of the run"

    # And the witness must be able to explain every line it can be handed.
    local ev
    while IFS= read -r ev; do
        [[ -n "$ev" ]] || continue
        grep -F "\`$ev\`" "$patrol" >/dev/null ||
            fail "reaper event $ev has no entry in the mol-witness-patrol log-review table"
    done < <(grep -oE 'record worktree_[a-z_]+' "$reaper" | awk '{print $2}' | sort -u)
}

test_polecat_home_teardown_has_an_owner() {
    # gcp-actg: a polecat's per-bead worktrees have an owner (the step above);
    # its persistent agent HOME had none. A home carries no bead, so every
    # guard on the rig — all of them bead-keyed — is structurally blind to it,
    # and the blindness is invisible in each guard's own diff. This test is the
    # inventory that says the roster-keyed sweep exists and stays wired.
    local audit="$GASTOWN/assets/scripts/polecat-home-audit.sh"
    local witness_cfg="$GASTOWN/agents/witness/agent.toml"
    local witness_prompt="$GASTOWN/agents/witness/prompt.template.md"
    local patrol="$GASTOWN/formulas/mol-witness-patrol.toml"

    [[ -f "$audit" ]] || fail "missing polecat agent-home audit sweep"
    [[ -x "$audit" ]] || fail "home audit sweep must be executable"
    parse_toml "$witness_cfg" "$patrol"

    # It is a patrol step, NOT a pre_start, and must not drift back. pre_start
    # is bounded by [session] setup_timeout (10s) and SIGKILLed on overrun; the
    # witness already spends most of that on the reaper, and an overrun fails
    # the session start and eventually latches the circuit breaker (gcp-ntbf,
    # gcp-oo0v). The pack-wide inventory in test_agent_pre_start_budget.sh is
    # the other half of this guard.
    ! grep -F 'polecat-home-audit.sh' "$witness_cfg" >/dev/null ||
        fail "the home audit must not be wired as a witness pre_start; it belongs in the patrol cycle"

    grep -F 'id = "audit-polecat-homes"' "$patrol" >/dev/null ||
        fail "witness patrol should own a polecat home audit step"
    grep -F 'needs = ["audit-polecat-homes"]' "$patrol" >/dev/null ||
        fail "the home audit step must be wired into the patrol chain, not orphaned"
    grep -F 'Audit polecat agent-home worktrees no live session owns' "$witness_prompt" >/dev/null ||
        fail "witness prompt should list the home audit as a duty"

    # A formula step cannot name the content-hashed pack cache, so it resolves
    # the sweep from the formula's own resolved source path — the one candidate
    # guaranteed present and version-coherent with the formula.
    grep -F 'gc formula list' "$patrol" >/dev/null ||
        fail "home audit step must resolve the sweep from the formula's own source path"
    grep -F 'assets/scripts/polecat-home-audit.sh' "$patrol" >/dev/null ||
        fail "home audit step must actually run the sweep"
    grep -F 'UNWATCHED this cycle' "$patrol" >/dev/null ||
        fail "an unresolvable sweep must be reported as a finding, not a silent OK"

    # THE POINT OF THE BEAD: ownership comes from the session roster and from
    # nothing in the bead store. A home HAS no bead, so a bead lookup can only
    # come back empty and be misread as "nothing owns it" — the shared root of
    # this family of blind spots (gascity-18kz, gcp-4k6o). Comments are dropped
    # so the header may say what the script does not do.
    local bead_reads
    bead_reads=$(grep -nE '(^|[^[:alnum:]_-])gc[[:space:]]+bd([[:space:]]|$)' "$audit" |
        grep -vE '^[0-9]+:[[:space:]]*#' || true)
    [[ -z "$bead_reads" ]] ||
        fail "home audit must not read the bead store: ${bead_reads//$'\n'/ | }"
    grep -F 'gc session list --state=all --json' "$audit" >/dev/null ||
        fail "home audit must key ownership on the session roster"

    # The gates are the safety contract; losing any one turns housekeeping into
    # data loss.
    grep -F '[ "$(basename "$(dirname "$wt")")" = "polecats" ]' "$audit" >/dev/null ||
        fail "home audit must restrict candidates to polecat agent homes"
    grep -F 'record home_children_kept' "$audit" >/dev/null ||
        fail "home audit must defer a home that still hosts per-bead worktrees; a LIVE polecat from another slot can be working inside a dead home's subtree (gcp-actg)"
    grep -F 'git -C "$WT" status --porcelain' "$audit" >/dev/null ||
        fail "home audit must refuse to remove a home with uncommitted work"
    grep -F 'git -C "$WT" rev-list --count HEAD --not --remotes' "$audit" >/dev/null ||
        fail "home audit must refuse to remove a home holding commits that reach no remote; unlike a per-bead worktree there is no closed bead to prove the work landed"

    # Fail closed on the roster, the same rule the reaper's gate 4 carries: a
    # confirmation read that fails is not proof of absence, and reading it as
    # an empty roster clears every home on the rig at once.
    ! grep -F '{"sessions":[]}' "$audit" >/dev/null ||
        fail "home audit must not fall back to an empty session roster; that makes the ownership gate fail open"
    grep -F 'ROSTER_STATE="unconfirmed"' "$audit" >/dev/null ||
        fail "home audit must seed the roster state to unconfirmed and promote it only on a clean read"
    grep -F 'record home_roster_unreadable' "$audit" >/dev/null ||
        fail "home audit must report and stop when the roster cannot be read"

    # Staged rollout: dry run is the default and the patrol wiring must not opt
    # in, so real removal cannot begin on a pin bump alone.
    grep -x -F 'DRY_RUN=1' "$audit" >/dev/null ||
        fail "home audit must default to dry run"
    grep -F -- '--no-dry-run) DRY_RUN=0 ;;' "$audit" >/dev/null ||
        fail "home audit must make real removal opt-in behind --no-dry-run"
    ! grep -F -- '"$AUDIT" "$GC_RIG_ROOT" --rig "$GC_RIG" --no-dry-run' "$patrol" >/dev/null ||
        fail "the patrol invocation must not enable live removal while the rollout is staged"

    # The sweep cleans up around the canonical checkout; it must never write
    # into it.
    ! grep -F 'LOG_DIR="$RIG_ROOT' "$audit" >/dev/null ||
        fail "home audit must not default its log inside the rig repo"

    # The log is forensics, so a line must carry the time of ITS OWN event.
    grep -F -e '--arg ts "$(date -u' "$audit" >/dev/null ||
        fail "home audit must stamp each log line when the event happens, not once at the start of the run"

    # And the witness must be able to explain every line it can be handed.
    local ev
    while IFS= read -r ev; do
        [[ -n "$ev" ]] || continue
        grep -F "\`$ev\`" "$patrol" >/dev/null ||
            fail "home audit event $ev has no entry in the mol-witness-patrol log-review table"
    done < <(grep -oE 'record home_[a-z_]+' "$audit" | awk '{print $2}' | sort -u)
}

test_dolt_push_outage_detection_is_wired() {
    local check="$GASTOWN/assets/scripts/dolt-push-state-check.sh"
    local deacon_cfg="$GASTOWN/agents/deacon/agent.toml"
    local patrol="$GASTOWN/formulas/mol-deacon-patrol.toml"

    [[ -f "$check" ]] || fail "missing dolt auto-push outage detector"
    [[ -x "$check" ]] || fail "auto-push detector must be executable"
    parse_toml "$deacon_cfg" "$patrol"

    # gcp-oo0v: the detector USED to run from the deacon's pre_start. It cannot.
    # The sweep is one `gc bd sql -C <scope>` per scope — 18.6s measured against
    # a 10s [session] setup_timeout — and a pre_start killed on that deadline
    # fails the whole session start, so six cycles latched the supervisor
    # circuit breaker and the town lost its deacon for ~5h. No pre_start on this
    # agent, and the pack-wide guard in test_agent_pre_start_budget.sh is what
    # stops a new one arriving unmeasured on a pin bump.
    ! grep -E '^[[:space:]]*pre_start[[:space:]]*=' "$deacon_cfg" >/dev/null ||
        fail "deacon must not wire a pre_start; the auto-push sweep cannot fit setup_timeout (gcp-oo0v)"

    grep -F 'id = "dolt-push-divergence"' "$patrol" >/dev/null ||
        fail "deacon patrol should own an auto-push divergence step"
    grep -F 'needs = ["dolt-push-divergence"]' "$patrol" >/dev/null ||
        fail "the divergence step must be wired into the patrol chain, not orphaned"

    # The detector moved INTO the patrol step, which has a whole cycle to run
    # it. A formula step still cannot name the content-hashed pack cache, so it
    # resolves the script from the formula's own resolved source path — the one
    # candidate guaranteed present and version-coherent with the formula.
    grep -F 'gc formula list' "$patrol" >/dev/null ||
        fail "divergence step must resolve the detector from the formula's own source path"
    grep -F 'assets/scripts/dolt-push-state-check.sh' "$patrol" >/dev/null ||
        fail "divergence step must run the detector itself, not read a session-start snapshot"

    # The old wiring fell back to the pre_start snapshot when the detector was
    # unresolvable. That fallback is now a lie in two ways — no pre_start writes
    # it, and a stale reading is not this cycle's measurement — so an
    # unresolvable detector must be reported as blind, not passed over as OK.
    ! grep -F 'falling back to snapshot' "$patrol" >/dev/null ||
        fail "divergence step must not fall back to a stale snapshot as if it were a fresh reading"
    grep -F 'BLIND this cycle' "$patrol" >/dev/null ||
        fail "an unresolvable detector must be reported as a finding, not a silent OK"

    # The point of the whole check is endpoint coverage. `gc dolt health` sees
    # the MANAGED server only, and the rig that went dark for 18h was pinned to
    # its own explicit endpoint — so the detector must reach each scope by that
    # scope's own path. Comments are stripped before the negative assertion:
    # the header explains why gc dolt health is wrong, and saying so must not
    # read as using it.
    grep -F 'gc bd sql -C' "$check" >/dev/null ||
        fail "detector must query each scope through its own path (gc bd sql -C)"
    ! grep -vE '^[[:space:]]*#' "$check" | grep -E 'gc dolt (health|sync)' >/dev/null ||
        fail "detector must not route through gc dolt health/sync (endpoint-blind for explicit rigs)"

    # gcp-qhx1 scoped dolt-remotes-patrol and gc dolt sync OUT: they are an
    # upstream-pinned order and a gc binary change, not this pack's to touch.
    ! grep -F 'dolt-remotes-patrol' "$patrol" >/dev/null ||
        fail "deacon patrol must not take over dolt-remotes-patrol"
}

test_submit_and_exit_cannot_be_replayed() {
    local formula prompt fragment submit_block
    formula="$GASTOWN/formulas/mol-polecat-work.toml"
    prompt="$GASTOWN/agents/polecat/prompt.template.md"
    fragment="$GASTOWN/template-fragments/approval-fallacy.template.md"

    parse_toml "$formula"

    submit_block=$(python3 - "$formula" <<'PY'
import sys
import tomllib

data = tomllib.load(open(sys.argv[1], "rb"))
step = next(s for s in data["steps"] if s["id"] == "submit-and-exit")
print(step["description"])
PY
)

    # gcp-rz8a: the step ended at drain-ack without closing its own step bead.
    # The molecule carries gc.session_affinity=require, so the pool respawned the
    # same named session and `gc hook --claim` handed it the completed step
    # again. Closing the step bead is what makes the step run once.
    [[ "$submit_block" == *'--metadata-field gc.step_ref=mol-polecat-work.submit-and-exit'* ]] ||
        fail "submit-and-exit must resolve its own step bead by step_ref, not guess at an id"
    [[ "$submit_block" == *'gc bd close "$STEP_BEAD_ID"'* ]] ||
        fail "submit-and-exit must close its own step bead so the pool cannot re-claim a completed submit"
    [[ "$submit_block" != *'gc bd close "$GC_BEAD_ID"'* ]] ||
        fail "for a polecat \$GC_BEAD_ID is the convoy, not this step; closing it closes live work"
    [[ "$submit_block" != *'gc bd close "$WORK_BEAD_ID"'* ]] ||
        fail "the polecat never closes the work bead; only the refinery does"

    # A claimed step bead carries the session's assignee but is still stored
    # `open` (observed on gcp-vgmf). A query for `in_progress` alone matches
    # nothing, so STEP_BEAD_ID comes back empty and the close never happens —
    # the fix reads as applied while the respawn loop stays wide open.
    [[ "$submit_block" == *'--status=open,in_progress'* ]] ||
        fail "submit-and-exit must resolve its step bead with --status=open,in_progress"
    [[ "$submit_block" != *'--status=in_progress '* ]] ||
        fail "a claimed step bead is stored open; --status=in_progress alone resolves nothing"

    # An agent may run each fenced block in its own shell, so the two blocks
    # that decide whether bead state gets re-written must derive their own ids
    # rather than inherit them and silently degrade to "nothing to close".
    python3 - "$formula" <<'PY' || fail "the guard and the close must re-derive their ids, not inherit them"
import sys
import tomllib

data = tomllib.load(open(sys.argv[1], "rb"))
step = next(s for s in data["steps"] if s["id"] == "submit-and-exit")
text = step["description"]
guard = text[text.index("**2. Already-submitted guard"): text.index("**3. Branch-shape gate")]
close = text[text.index("**10."):]
for block in (guard, close):
    if "--metadata-field gc.step_ref=mol-polecat-work.submit-and-exit" not in block:
        raise SystemExit(1)
if "gc convoy status" not in guard:
    raise SystemExit(1)
PY

    # The close has to happen BEFORE the drain, or the reconciler kills the
    # session first and the step bead is left open exactly as before.
    python3 - "$formula" <<'PY' || fail "submit-and-exit must close its step bead before draining"
import sys
import tomllib

data = tomllib.load(open(sys.argv[1], "rb"))
step = next(s for s in data["steps"] if s["id"] == "submit-and-exit")
tail = step["description"]
tail = tail[tail.index("**10."):]
if tail.index('gc bd close "$STEP_BEAD_ID"') >= tail.index("gc runtime drain-ack"):
    raise SystemExit(1)
PY

    # A halt that reached the step's contracted end must close the step bead
    # too; a FAILED push must not, because the handoff never happened and the
    # next session has to re-claim and retry it.
    python3 - "$formula" <<'PY' || fail "auto_push=false must close the step bead; push failures must leave it open"
import sys
import tomllib

data = tomllib.load(open(sys.argv[1], "rb"))
step = next(s for s in data["steps"] if s["id"] == "submit-and-exit")
text = step["description"]
halt = text[text.index("auto_push=false: halting at branch-ready"):]
halt = halt[: halt.index("git push origin HEAD")]
if 'gc bd close "$STEP_BEAD_ID"' not in halt:
    raise SystemExit(1)
failed = text[text.index("PUSH FAILED (exit $PUSH_EXIT)"):]
failed = failed[: failed.index("**6.")]
if 'gc bd close "$STEP_BEAD_ID"' in failed:
    raise SystemExit(1)
PY

    # gcp-rz8a's severity line: a replayed step 8 clears gc.routed_to="human",
    # which is how a bead the refinery parked on an armed require_merge_approval
    # gate gets pulled back out of an operator escalation. The guard must be
    # read and acted on BEFORE the update that clears the routing.
    [[ "$submit_block" == *'[ "$ROUTED_TO" = "human" ]'* ]] ||
        fail "the refinery handoff must refuse to run when gc.routed_to is human"
    python3 - "$formula" <<'PY' || fail "the human-routing guard must precede the update that clears gc.routed_to"
import sys
import tomllib

data = tomllib.load(open(sys.argv[1], "rb"))
step = next(s for s in data["steps"] if s["id"] == "submit-and-exit")
reassign = step["description"]
reassign = reassign[reassign.index("**8. Reassign to refinery"):]
if reassign.index('[ "$ROUTED_TO" = "human" ]') >= reassign.index('--set-metadata gc.routed_to=""'):
    raise SystemExit(1)
PY

    # Second brake: an idempotence guard that bails out before any bead write.
    [[ "$submit_block" == *"ALREADY_SUBMITTED"* ]] ||
        fail "submit-and-exit must detect a completed handoff before re-writing bead state"
    python3 - "$formula" <<'PY' || fail "the already-submitted guard must run before the first bead write"
import sys
import tomllib

data = tomllib.load(open(sys.argv[1], "rb"))
step = next(s for s in data["steps"] if s["id"] == "submit-and-exit")
text = step["description"]
if text.index("ALREADY_SUBMITTED") >= text.index("gc bd update"):
    raise SystemExit(1)
PY

    # The prompt-side guard could not run at all in the observed session:
    # $GC_BEAD_ID was empty, so it never resolved a work bead. Both copies must
    # recover the convoy, and both must key on POSITIVE evidence — a molecule's
    # work bead is never assigned to the polecat session, so "not in_progress
    # for me" reports already-submitted on work that was never submitted.
    local guard
    for guard in "$prompt" "$fragment"; do
        grep -F 'CONVOY_ID="${GC_BEAD_ID:-}"' "$guard" >/dev/null ||
            fail "$(basename "$guard") must not read the convoy straight from \$GC_BEAD_ID; it is not always exported"
        grep -F 'gc.root_bead_id' "$guard" >/dev/null ||
            fail "$(basename "$guard") must recover the convoy from the step bead's molecule root"
        grep -F -- '--status=open,in_progress' "$guard" >/dev/null ||
            fail "$(basename "$guard") must query the held step bead with --status=open,in_progress"
        ! grep -F -- '--status=in_progress ' "$guard" >/dev/null ||
            fail "$(basename "$guard") queries a claimed step bead, which is stored open, not in_progress"
        ! grep -F '[ "$WORK_STATUS" != "in_progress" ]' "$guard" >/dev/null ||
            fail "$(basename "$guard") must not treat an unassigned work bead as already submitted"
        grep -F '[ "$WORK_STATUS" = "closed" ]' "$guard" >/dev/null ||
            fail "$(basename "$guard") must require positive evidence (closed, or handed to another assignee)"
    done
}

test_work_bead_is_claimed_for_the_whole_run() {
    # gcp-5gir: mol-polecat-work only ever claimed its own STEP beads, so the
    # WORK bead stayed open+unassigned from dispatch until the refinery handoff.
    # For the whole implementation window it was indistinguishable, in
    # `gc bd ready`, from a bead nobody had touched — and a second `gc sling` onto
    # it spawns a duplicate polecat whose later push supersedes the first,
    # discarding work that was already written and self-reviewed.
    local formula prompt fragment setup_block submit_block
    formula="$GASTOWN/formulas/mol-polecat-work.toml"
    prompt="$GASTOWN/agents/polecat/prompt.template.md"
    fragment="$GASTOWN/template-fragments/approval-fallacy.template.md"

    parse_toml "$formula"

    setup_block=$(python3 - "$formula" <<'PY'
import sys
import tomllib

data = tomllib.load(open(sys.argv[1], "rb"))
step = next(s for s in data["steps"] if s["id"] == "workspace-setup")
print(step["description"])
PY
)
    submit_block=$(python3 - "$formula" <<'PY'
import sys
import tomllib

data = tomllib.load(open(sys.argv[1], "rb"))
step = next(s for s in data["steps"] if s["id"] == "submit-and-exit")
print(step["description"])
PY
)

    # The claim itself. Status AND assignee: status alone leaves the witness's
    # orphan pass blind (it skips unassigned beads), assignee alone leaves the
    # bead in `gc bd ready`, which is the defect.
    [[ "$setup_block" == *'gc bd update "$WORK_BEAD_ID" --status=in_progress --assignee="$POLECAT_SESSION"'* ]] ||
        fail "workspace-setup must claim the WORK bead with both status=in_progress and an assignee"

    # It has to happen before the worktree is built, not somewhere later: every
    # second the bead spends open+unassigned is a second another planner can
    # sling a duplicate polecat onto it.
    python3 - "$formula" <<'PY' || fail "the work-bead claim must land in step 1, before the worktree is created"
import sys
import tomllib

data = tomllib.load(open(sys.argv[1], "rb"))
step = next(s for s in data["steps"] if s["id"] == "workspace-setup")
text = step["description"]
claim = text.index('gc bd update "$WORK_BEAD_ID" --status=in_progress')
if claim >= text.index("**2. Ensure worktree exists.**"):
    raise SystemExit(1)
PY

    # A write that exits 0 is not a claim: `--status` on this bead has been seen
    # not to stick (gcp-s14g), and a status that stays `open` leaves it in
    # `gc bd ready` with the fix reading as applied.
    [[ "$setup_block" == *'CLAIMED_STATUS'* && "$setup_block" == *'CLAIMED_ASSIGNEE'* ]] ||
        fail "workspace-setup must read the work-bead claim back instead of trusting the write"

    # The done sequence, the resume re-verify and the worktree reaper all read
    # `assignee == polecat_session` as "a polecat still holds this". Stamping
    # only the assignee leaves a crashed predecessor's tag behind, and the bead
    # reads as already handed to the refinery.
    [[ "$setup_block" == *'--assignee="$POLECAT_SESSION" --set-metadata polecat_session="$POLECAT_SESSION"'* ]] ||
        fail "the work-bead claim must stamp polecat_session together with the assignee"

    # Never steal a bead the refinery or an operator escalation already owns.
    [[ "$setup_block" == *'[ "$CURRENT_ASSIGNEE" != "$POLECAT_SESSION" ]'* ]] ||
        fail "the claim must leave a foreign assignee alone rather than overwrite it"

    # The bead's own note: pool dispatch leaves gc.routed_to blank on the work
    # bead on purpose so scale_check can see pool demand. Stamping it here
    # breaks spawn accounting instead of fixing visibility.
    [[ "$setup_block" != *'gc.routed_to='* ]] ||
        fail "the work-bead claim must not stamp gc.routed_to; routing lives on the molecule root"

    # Release is a single assignee move, session -> refinery. A release that
    # passed through unassigned would re-open the very window this closes.
    [[ "$submit_block" == *'gc bd update "$WORK_BEAD_ID" --status=open --assignee="$REFINERY_TARGET"'* ]] ||
        fail "submit-and-exit must hand the work bead straight to the refinery"

    # Holding the claim means `gc hook --claim`'s crash-recovery tier
    # (`gc bd list --status in_progress --assignee=<you> --limit=1`) can return the
    # WORK bead instead of the next formula step — at every step boundary, where
    # the successor step is still stored `open`. Without the re-point the
    # molecule stops advancing and the branch is never pushed (gcp-tl8's shape).
    grep -F 'gc.step_ref" // empty' "$prompt" >/dev/null ||
        fail "the startup claim block must detect a hook result that is not a formula step"
    grep -F 'STEP_REPOINTED' "$prompt" >/dev/null ||
        fail "the startup claim block must re-point at the molecule's next ready step"
    python3 - "$prompt" <<'PY' || fail "the step re-point must run before the polecat_session stamp, so the stamp lands on the bead actually being executed"
import sys

text = open(sys.argv[1], encoding="utf-8").read()
block = text[text.index("bash <<'GC_CLAIM'"): text.index("GC_CLAIM\n```")]
if "STEP_REPOINTED" not in block:
    raise SystemExit(1)
if block.index("STEP_REPOINTED") >= block.index('--set-metadata polecat_session='):
    raise SystemExit(1)
PY

    # A resumed molecule finds its work bead held by its own PREVIOUS session
    # (pool restarts mint a new identity). Reading that as "handed off" drains
    # with the branch unpushed — the failure the guard exists to prevent.
    local guard
    for guard in "$prompt" "$fragment"; do
        grep -F '[ "$WORK_ASSIGNEE" != "$WORK_SESSION_TAG" ]' "$guard" >/dev/null ||
            fail "$(basename "$guard") must not read a previous polecat session's own claim as a completed handoff"
        grep -F 'metadata.polecat_session' "$guard" >/dev/null ||
            fail "$(basename "$guard") must read metadata.polecat_session to tell a held bead from a handed-off one"
    done
}

test_dog_assets_are_pack_local
test_retired_dog_formulas_are_not_reintroduced
test_work_bead_is_claimed_for_the_whole_run
test_submit_and_exit_cannot_be_replayed
test_post_merge_worktree_teardown_has_an_owner
test_polecat_home_teardown_has_an_owner
test_dolt_push_outage_detection_is_wired
test_shutdown_dance_contracts_are_executable
test_shutdown_dance_lifecycle_and_audit_contracts
test_composition_is_documented
test_polecat_startup_uses_standard_hook_claim
test_review_leg_contract_forbids_synthetic_mutation
test_refinery_direct_merge_is_worktree_safe_and_fail_closed

echo "gastown pack asset tests passed"
