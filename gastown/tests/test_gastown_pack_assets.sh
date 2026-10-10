#!/usr/bin/env bash
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

test_digest_archive_bead_is_not_left_open() {
    # gcp-156c: step 3 was labelled "archive" but only ran `gc bd create`,
    # which files an issue `open`, and nothing ever closed it. A digest runs
    # daily, so that leaked one permanently-open task per run, forever --
    # hand-clearing them does nothing because the next cycle files another.
    # `gc bd create` has no create-time status flag, so capture-then-close is
    # the only available shape; pin it here so "archive" cannot silently go
    # back to meaning "file work nobody actions".
    local formula="$GASTOWN/formulas/mol-digest-generate.toml"

    [[ -f "$formula" ]] || fail "missing digest formula"
    parse_toml "$formula"

    grep -F 'DIGEST_BEAD=$(gc bd create --type=task' "$formula" >/dev/null ||
        fail "digest archive step must capture the id of the bead it creates"
    grep -F 'gc bd close "$DIGEST_BEAD"' "$formula" >/dev/null ||
        fail "digest archive step must close the bead it creates; an open one leaks every run"
    grep -F "jq -r '.id // empty'" "$formula" >/dev/null ||
        fail "digest bead id capture must degrade to empty rather than feed a garbled id to close"
    grep -F 'if [ -n "$DIGEST_BEAD" ]; then' "$formula" >/dev/null ||
        fail "a failed id capture must be reported, not silently swallowed back into the leak"

    # The archival record has to stay findable, or closing it just hides the
    # digest history instead of tidying the backlog.
    grep -F -- '--labels=digest,{{period}}' "$formula" >/dev/null ||
        fail "the archived digest bead must keep its digest label so the record stays findable"

    python3 - "$formula" <<'DIGEST_ORDER' || fail "the digest bead must be closed inside the archive step, after it is created"
import sys
text = open(sys.argv[1], encoding="utf-8").read()
start = text.index('**3. Archive as bead:**')
end = text.index('**4. Close work bead')
block = text[start:end]
if block.index('gc bd create --type=task') >= block.index('gc bd close "$DIGEST_BEAD"'):
    raise SystemExit(1)
DIGEST_ORDER
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

# Five role-surfaces resolve a work bead from the environment, by deliberately
# different rules, and the differences are load-bearing. Two properties decide
# which form is safe -- NOT "pooled vs singleton": the refinery and the deacon
# carry identical max_active_sessions = 1 + wake_mode = "fresh" pins, so pooling
# cannot tell them apart. What differs is (a) whether more than one session
# shares the env, and (b) whether the role rotates wisps IN-SESSION, which makes
# a spawn-fixed trigger go stale mid-loop:
#   shutdown dance (dog pool, max_active_sessions = 3) - resolve the CLAIM
#     first. The spawn trigger is fixed at wake and is not advanced by
#     `gc hook --claim`, so under contention it names a bead this session never
#     claimed - and the dance closes whatever it resolves.
#   deacon patrol formula (singleton, wake_mode = "fresh", pours the next wisp
#     then EXITS the turn) - may prefer the trigger: one process env holds
#     exactly one wisp for its whole life.
#   refinery patrol formula (singleton too, but re-reads the formula steps
#     in-session after burning) - bare ${GC_BEAD_ID:-} plus a live assignee
#     query, never the trigger: the wisp advances while the trigger does not.
#   refinery / witness / deacon prompt templates - bare ${GC_BEAD_ID:-} plus the
#     same live query. Exempt from the trigger rule by form, not by luck: a bare
#     resolution backed by the assignee query cannot mis-select on any role, so
#     it stays correct even on the singletons. Pinned below so the exemption is
#     gated rather than conventional.
# Pin the discriminator, and the rotation property it rests on, so the forms
# cannot silently converge on the permissive one.
test_work_bead_resolution_discriminator_is_pinned() {
    local dance="$GASTOWN/formulas/mol-shutdown-dance.toml"
    local deacon="$GASTOWN/formulas/mol-deacon-patrol.toml"
    local refinery="$GASTOWN/formulas/mol-refinery-patrol.toml"
    local refinery_prompt="$GASTOWN/agents/refinery/prompt.template.md"

    local claim_first='GC_BEAD_ID="${GC_BEAD_ID:-$(gc hook current --id-only 2>/dev/null)}"'
    local trigger_fallback='GC_BEAD_ID="${GC_BEAD_ID:-${GC_TRIGGER_WORK_BEAD_ID:?no work bead id in env}}"'

    # Order-sensitive by construction: presence greps alone would stay green on
    # a reordering. Record both forms in file order and require claim-then-
    # trigger at exactly the two normalization sites the formula prose names.
    local dance_order
    dance_order="$(awk -v claim="$claim_first" -v trig="$trigger_fallback" '
        index($0, claim) { printf "C"; next }
        index($0, trig)  { printf "T" }
    ' "$dance")"
    [[ "$dance_order" == "CTCT" ]] ||
        fail "shutdown dance must resolve the claimed warrant before the spawn trigger at exactly the two normalization sites (preamble and receive-warrant step 1); got '$dance_order'"

    # Nesting the resolver inside the trigger fallback is inert: ${A:-${B:-$(C)}}
    # never evaluates $(C) while B is non-empty, so a stale trigger still wins
    # and the dance closes a foreign bead.
    ! grep -F 'GC_TRIGGER_WORK_BEAD_ID:-$(gc hook current' "$dance" >/dev/null ||
        fail "shutdown dance must not nest the claim resolver inside the trigger fallback; that form is inert whenever the trigger is set"

    # The signature above matches two exact literals, so it is blind to a
    # NOVEL-form trigger resolution added to a third block (a bare
    # ${GC_TRIGGER_WORK_BEAD_ID:-} matches neither literal and leaves the
    # signature at CTCT). Bound the references instead of only their shape, so a
    # new one has to be added consciously rather than silently.
    local dance_trigger_refs
    dance_trigger_refs="$(grep -cF 'GC_TRIGGER_WORK_BEAD_ID' "$dance" || true)"
    [[ "$dance_trigger_refs" -eq 3 ]] ||
        fail "shutdown dance must carry exactly 3 GC_TRIGGER_WORK_BEAD_ID references (the prose paragraph plus the two fallback lines); got $dance_trigger_refs. A new one is a new resolution site: update the prose contract and this pin together."

    local deacon_trigger
    deacon_trigger="$(grep -cF 'CURRENT_WISP=${GC_BEAD_ID:-${GC_TRIGGER_WORK_BEAD_ID:-}}' "$deacon" || true)"
    [[ "$deacon_trigger" -eq 1 ]] ||
        fail "deacon patrol should keep exactly one trigger-preferring wisp resolution; got $deacon_trigger"
    grep -F 'max_active_sessions = 1' "$GASTOWN/agents/deacon/agent.toml" >/dev/null ||
        fail "the deacon's trigger-first wisp resolution is safe only while the deacon is a singleton; agent.toml no longer pins max_active_sessions = 1"
    grep -F 'wake_mode = "fresh"' "$GASTOWN/agents/deacon/agent.toml" >/dev/null ||
        fail "the deacon's trigger-first wisp resolution is safe only on a fresh wake; agent.toml no longer pins wake_mode"

    # The third precondition lives in the formula, not in agent.toml, so neither
    # pin above can ever catch its loss: the deacon pours the successor, burns
    # this wisp, and EXITS the turn, so one process env holds exactly one wisp
    # for its whole life and the restarted session gets a fresh trigger. An
    # in-session loop here revives the stale-trigger failure with both config
    # pins still green.
    grep -F 'IDLE: no work, exiting turn.' "$deacon" >/dev/null ||
        fail "the deacon's trigger-first wisp resolution is safe only while each iteration ends by exiting the turn; mol-deacon-patrol.toml no longer emits the IDLE exit signal"
    grep -F 'the restarted session resumes from it' "$deacon" >/dev/null ||
        fail "the deacon's trigger-first wisp resolution is safe only while the successor wisp is resumed by a RESTARTED session (fresh trigger); mol-deacon-patrol.toml no longer hands the successor to a restarted session"
    ! grep -F 're-read formula steps to begin' "$deacon" >/dev/null ||
        fail "the deacon now rotates wisps in-session like the refinery, so its spawn trigger goes stale mid-loop; mol-deacon-patrol.toml must drop the trigger-preferring resolution for the bare \${GC_BEAD_ID:-} plus live assignee query"

    # The refinery's opposite rule rests on the opposite property, so pin that
    # too rather than leaving it asserted only in a comment: it re-reads the
    # formula steps in-session after burning, advancing the wisp while the
    # spawn-fixed trigger stays put.
    grep -F 're-read formula steps to begin' "$refinery" >/dev/null ||
        fail "the refinery no longer rotates wisps in-session; that rotation is the recorded reason it must never resolve a wisp from the spawn trigger, so re-derive the per-role rule and this discriminator before relaxing either form"

    # Every environment-resolved wisp assignment in the refinery must be the
    # bare query-backed form. Comparing the two counts catches conversion in
    # either direction without freezing the number of call sites.
    local path env_assignments bare_assignments
    for path in "$refinery" "$refinery_prompt"; do
        ! grep -F 'GC_TRIGGER_WORK_BEAD_ID' "$path" >/dev/null ||
            fail "the refinery rotates wisps in-session, so a spawn-fixed trigger goes stale mid-loop; it must resolve every wisp from \$GC_BEAD_ID plus the live assignee query, never the trigger: $path"
        env_assignments="$(grep -cF 'CURRENT_WISP=${GC_BEAD_ID' "$path" || true)"
        bare_assignments="$(grep -cF 'CURRENT_WISP=${GC_BEAD_ID:-}' "$path" || true)"
        [[ "$env_assignments" -ge 1 ]] ||
            fail "refinery should resolve its current wisp from \$GC_BEAD_ID: $path"
        [[ "$env_assignments" -eq "$bare_assignments" ]] ||
            fail "every refinery wisp resolution must be the bare \${GC_BEAD_ID:-} form backed by the live assignee query ($bare_assignments of $env_assignments): $path"
    done

    # The remaining two surfaces of the census in the header comment. They are
    # correct today by form -- bare plus the live query cannot mis-select on a
    # singleton -- so gate that exemption instead of leaving it to convention: a
    # harmonization edit that copies the deacon formula's trigger-preferring
    # line into either template goes red here rather than passing silently.
    local template
    for template in "$GASTOWN/agents/witness/prompt.template.md" \
                    "$GASTOWN/agents/deacon/prompt.template.md"; do
        ! grep -F 'GC_TRIGGER_WORK_BEAD_ID' "$template" >/dev/null ||
            fail "singleton prompt templates stay exempt from the per-role trigger rules by using the bare \${GC_BEAD_ID:-} form; they must not resolve a wisp from the spawn trigger: $template"
        env_assignments="$(grep -cF 'CURRENT_WISP=${GC_BEAD_ID' "$template" || true)"
        bare_assignments="$(grep -cF 'CURRENT_WISP=${GC_BEAD_ID:-}' "$template" || true)"
        [[ "$env_assignments" -ge 1 ]] ||
            fail "prompt template should resolve its current wisp from \$GC_BEAD_ID: $template"
        [[ "$env_assignments" -eq "$bare_assignments" ]] ||
            fail "every prompt-template wisp resolution must be the bare \${GC_BEAD_ID:-} form backed by the live assignee query ($bare_assignments of $env_assignments): $template"
    done
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
    grep -F 'default_sling_formula = "mol-polecat-work"' "$agent" >/dev/null ||
        fail "plain polecat sling must compile the implementation workflow instead of routing a bare task"
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

test_claim_verify_separates_read_failure_from_unassigned() {
    # winnow-2fj8u: SHOW_OK required a NON-EMPTY assignee, but `gc bd show` omits
    # the field entirely when it is null. "Read fine, genuinely unassigned" and
    # "read failed" were therefore the same observation, and a readable
    # unassigned bead took the CLAIM_RELEASED path instead of CLAIM_REJECTED.
    # Key read-success on the bead echoing its own id, never on the assignee.
    local prompt="$GASTOWN/agents/polecat/prompt.template.md"

    grep -F 'SHOW_ID="$(printf '"'"'%s'"'"' "$SHOW_JSON" | jq -r '"'"'.[0].id // empty'"'"' 2>/dev/null)"' "$prompt" >/dev/null ||
        fail "claim-verify must read the bead id to prove the show succeeded"
    grep -F 'if [ "$SHOW_CODE" -eq 0 ] && [ -n "$SHOW_ID" ] && [ -n "$STATUS" ]; then' "$prompt" >/dev/null ||
        fail "claim-verify read-success test must not depend on a non-empty assignee"
    ! grep -F '[ -n "$STATUS" ] && [ -n "$ASSIGNEE" ]' "$prompt" >/dev/null ||
        fail "claim-verify regressed to conflating an unassigned bead with a failed read"
}

test_claim_refuses_a_pour_onto_a_live_owner() {
    # gcp-mjjg: gc's ReleaseIfCurrent returns an in-flight step bead to the pool
    # without writing a bd event, so a duplicate pour is indistinguishable from
    # ordinary unclaimed work at claim time. The molecule's WORK bead carries no
    # gc.routed_to and so is never released — it is the only durable record of
    # who owns the molecule, and the guard must consult it before any work
    # begins. Behavioural coverage lives in test_polecat_live_owner_guard.sh;
    # this pins the guard into the startup contract so it cannot be quietly
    # dropped from the claim block.
    local prompt="$GASTOWN/agents/polecat/prompt.template.md"

    grep -F '# GUARD_BEGIN live-owner' "$prompt" >/dev/null ||
        fail "polecat claim block lost the live-owner guard"
    grep -F '# GUARD_END live-owner' "$prompt" >/dev/null ||
        fail "live-owner guard is missing its extraction sentinel"
    grep -F 'CLAIM_DECLINED_LIVE_OWNER' "$prompt" >/dev/null ||
        fail "live-owner guard must announce its refusal with a distinct token"
    grep -F 'gc session list --json' "$prompt" >/dev/null ||
        fail "live-owner guard must probe session liveness, not assume it"

    # The guard runs BEFORE the step re-point and the polecat_session stamp:
    # both mutate bead state, and a declining polecat must touch nothing.
    local guard_line stamp_line
    guard_line=$(grep -n '# GUARD_END live-owner' "$prompt" | head -1 | cut -d: -f1)
    stamp_line=$(grep -n 'set-metadata polecat_session="\$EXPECTED_ASSIGNEE"' "$prompt" | head -1 | cut -d: -f1)
    [[ -n "$guard_line" && -n "$stamp_line" && "$guard_line" -lt "$stamp_line" ]] ||
        fail "live-owner guard must run before the claim block stamps polecat_session"

    grep -F '`CLAIM_DECLINED_LIVE_OWNER`, it has already drain-acked' "$prompt" >/dev/null ||
        fail "the prose listing drain-acked claim outcomes must name CLAIM_DECLINED_LIVE_OWNER"
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

test_witness_wisp_queries_pin_include_infra() {
    local prompt formula total flagged
    prompt="$GASTOWN/agents/witness/prompt.template.md"
    formula="$GASTOWN/formulas/mol-witness-patrol.toml"

    # Wisp roots are ephemeral, so gc bd list skips the wisps tier unless
    # --include-infra is passed: a wisp-reconcile query without it returns []
    # even when a wisp is assigned, and the witness pours a duplicate. That
    # regressed once already, so pin the flag rather than trust the comments.
    # Deliberately witness-scoped: the refinery and deacon patrol queries
    # still carry the bare form and are tracked separately in #252, so a
    # pack-wide assertion would fail here instead of guarding this contract.
    total=$(grep -h -- '--type=molecule' "$prompt" "$formula" |
        grep -c -F 'gc bd list' || true)
    flagged=$(grep -h -- '--type=molecule' "$prompt" "$formula" |
        grep -F 'gc bd list' | grep -c -- '--include-infra' || true)

    # -ge, not -eq: the flagged/total assertion below owns the contract, so an
    # exact count only adds a cardinality pin -- and a legitimate sixth query,
    # or a prose line that happens to name all three tokens counted above,
    # then fails the suite with nothing wrong. Measured: -ge holds every
    # regression mode red (flag stripped from a prompt query, from the formula
    # query, a query site deleted, an unflagged sixth site) while dropping
    # both false positives. A prose line carrying the query tokens but not the
    # flag still fails -- loud, in the safe direction. Requiring --json on
    # counted lines would silence that last one too, but it is not a
    # substitute: it stops counting any query that does not pipe to jq, so an
    # unflagged new site written without --json passes silently.
    [[ "$total" -ge 5 ]] ||
        fail "expected at least 5 witness --type=molecule wisp queries (4 prompt + 1 formula), found $total"
    [[ "$flagged" -eq "$total" ]] ||
        fail "witness --type=molecule wisp queries must pass --include-infra ($flagged/$total do)"
}

test_witness_handoff_recovery_is_guarded_and_fail_closed() {
    local witness polecat refinery block signature writers

    witness="$GASTOWN/formulas/mol-witness-patrol.toml"
    polecat="$GASTOWN/formulas/mol-polecat-work.toml"
    refinery="$GASTOWN/formulas/mol-refinery-patrol.toml"
    parse_toml "$witness" "$polecat" "$refinery"

    # Witness Step 3a completes the refinery handoff for a polecat that died
    # between submit-and-exit steps 5 and 6 (gastownhall/gascity-packs#276).
    # It mutates a bead assigned to a dead actor and then deletes its worktree,
    # so every property below is one that an edit can silently invert while the
    # formula still parses and the rest of this suite stays green.

    # Placement. A presence-only grep survives moving 3a after 3b, which makes
    # it dead code for every bead 3b has already returned to pool. A sequence
    # signature pins order, count, and cardinality together, and pins the
    # precondition (Step 3's on-main close) rather than 3a alone.
    # Leading whitespace is tolerated because the close now sits inside the
    # STILL_ORPHANED gate asserted below; the line is still pinned whole, so
    # this admits indentation and nothing else.
    signature=$(awk '
        /^[[:space:]]*gc bd close <bead> --force$/ { print "step3-close" }
        /^\*\*Step 3a:/                           { print "step3a" }
        /^\*\*Step 3b:/                           { print "step3b" }
    ' "$witness" | tr '\n' ' ')
    [[ "$signature" == "step3-close step3a step3b " ]] ||
        fail "witness recovery must run Step 3's on-main close, then Step 3a, then Step 3b (got: $signature)"

    # Discriminator. metadata.target is a mint-time sling input that nothing
    # ever unsets and that survives both refinery rejection paths, so keying on
    # it fires 3a for beads that never submitted -- shipping an already-rejected
    # or half-finished tip to a refinery whose only merge gate is tests-pass.
    block=$(awk '/^\*\*Step 3a:/{f=1} /^\*\*Step 3b:/{f=0} f' "$witness")
    # Matched without the leading `if `: the same condition now carries the
    # STILL_ORPHANED gate in front of it, pinned as a whole line below.
    printf '%s\n' "$block" |
        grep -F '[ "$HANDOFF_STAGE" = "target_recorded" ] && [ -n "$BRANCH_ON_ORIGIN" ]; then' >/dev/null ||
        fail "Step 3a must key the handoff on handoff_stage and a branch that is really on origin"
    ! printf '%s\n' "$block" | grep -F '[ -n "$BEAD_TARGET" ]' >/dev/null ||
        fail "Step 3a must not treat metadata.target as a completion signal"
    # Both halves of the backstop, in one pin. ls-remote patterns match ref
    # tails, so the bare "$BRANCH" form is truthy for a branch that is not on
    # origin whenever a tail-colliding ref (archive/polecat/<id>) survives it;
    # the fully-qualified form measures the property the message below names.
    printf '%s\n' "$block" |
        grep -F '[ -n "$BRANCH" ] && BRANCH_ON_ORIGIN=$(git ls-remote --heads origin "refs/heads/$BRANCH"' >/dev/null ||
        fail "Step 3a must guard the empty branch and query the fully-qualified ref: ls-remote patterns match ref tails"

    # The claim guard and the fail-closed arm. bd refuses a cross-actor
    # --assignee write against the dead polecat's live in_progress claim
    # without --force; unchecked, the witness would then mail success, delete
    # the worktree, and skip the 3b reset that used to recover the bead.
    printf '%s\n' "$block" | grep -F -- '--set-metadata gc.routed_to="" --force' >/dev/null ||
        fail "Step 3a's cross-actor reassignment must pass --force"
    # Failure policy, pinned separately from the ordering signature below so a
    # change to either reports as itself. delete-source runs after the
    # reassignment has already succeeded, so it is best-effort like the
    # wake/nudge: leaving it bare invites a future editor to read it as
    # load-bearing and abort a handoff that in fact completed.
    printf '%s\n' "$block" |
        grep -F 'gc workflow delete-source <bead> --apply || true' >/dev/null ||
        fail "Step 3a's subtree cleanup must state its best-effort failure policy (|| true), as the wake/nudge do"
    printf '%s\n' "$block" |
        grep -F 'REFINERY_TARGET="${GC_RIG:+$GC_RIG/}{{binding_prefix}}refinery"' >/dev/null ||
        fail "Step 3a must use submit-and-exit step 6's conditional rig prefix for the assignee write"

    # Ordering inside the block, again as a signature: the reassignment's exit
    # status is the if condition, the subtree cleanup and the success mail,
    # wake, nudge, and worktree removal all sit inside the success arm ahead of
    # a real else, and the subtree cleanup precedes the signal so the refinery
    # is never woken mid-cleanup. Substring pins alone stay green if the mail
    # is hoisted above the if or the else is dropped -- and every statement
    # ordered after the if is a statement the failure arm cannot reach, which
    # is what makes falling through to Step 3b a true no-op.
    signature=$(printf '%s\n' "$block" | awk '
        /^  if gc bd update <bead> /                  { print "guarded-update" }
        /^    gc workflow delete-source <bead> --apply/ { print "delete-source" }
        /gc mail send mayor\/ -s "ORPHAN_HANDED_OFF/  { print "mail" }
        /gc session wake "\$REFINERY_TARGET"/         { print "wake" }
        /gc session nudge "\$REFINERY_TARGET"/        { print "nudge" }
        /^  else$/                                    { print "else" }
    ' | tr '\n' ' ')
    [[ "$signature" == "guarded-update delete-source mail wake nudge else " ]] ||
        fail "Step 3a must check the reassignment's exit status first, then delete the subtree and mail/wake/nudge in the success arm, and fall through in an else (got: $signature)"
    # A completed handoff is an ordinary refinery handoff: the task artifact
    # stays in place for the refinery's verified terminal cleanup
    # (gc gastown task-artifact-cleanup), never a witness force-removal.
    ! printf '%s\n' "$block" | grep -E 'git worktree remove|rm -rf' >/dev/null ||
        fail "Step 3a must leave the task artifact for the refinery's terminal cleanup"

    # The marker contract spans three formulas: one writer, three clearers.
    # Losing any clearer silently restores the stale-marker over-trigger that
    # keying on handoff_stage exists to prevent.
    writers=$(cat "$polecat" "$witness" "$refinery" |
        grep -c -F -- '--set-metadata handoff_stage=target_recorded' || true)
    [[ "$writers" -eq 1 ]] ||
        fail "handoff_stage must be written only by submit-and-exit step 5 (found $writers writers)"
    grep -F 'gc bd update "$WORK_BEAD_ID" --unset-metadata handoff_stage' "$polecat" >/dev/null ||
        fail "workspace-setup must clear a stale handoff_stage on every fresh attempt"
    [[ $(grep -c -F -- '--unset-metadata handoff_stage' "$refinery") -eq 2 ]] ||
        fail "both refinery rejection paths must clear handoff_stage"

    # 3b keeps its own recovery for everything that falls through.
    grep -F 'gc workflow delete-source <bead> --apply && gc workflow reopen-source <bead>' "$witness" >/dev/null ||
        fail "Step 3b must still reopen the source bead for fall-through recoveries"

    # All three destructive outcomes re-state the pre-destruction verdict, and
    # the verdict itself starts closed. Step 3a is not covered by a guard at the
    # pool reset: its success arm skips to Step 4 and never reaches Step 3b, so
    # each site is pinned individually rather than inferred from one of them.
    grep -F 'STILL_ORPHANED=false' "$witness" >/dev/null ||
        fail "the pre-destruction verdict must start closed (STILL_ORPHANED=false)"
    local gate
    for gate in \
        'if [ "$STILL_ORPHANED" = "true" ] && [ "$ON_MAIN" = "true" ]; then' \
        'if [ "$STILL_ORPHANED" = "true" ] && [ "$HANDOFF_STAGE" = "target_recorded" ] && [ -n "$BRANCH_ON_ORIGIN" ]; then' \
        'if [ "$STILL_ORPHANED" != "true" ]; then'; do
        grep -F -- "$gate" "$witness" >/dev/null ||
            fail "a destructive witness recovery path is not gated on the liveness re-check: $gate"
    done
}

test_boot_wisp_queries_pin_include_infra() {
    local prompt formula total flagged
    prompt="$GASTOWN/agents/boot/prompt.template.md"
    formula="$GASTOWN/formulas/mol-boot-patrol.toml"

    # Same contract as the witness guard above, scoped to boot: boot's patrol
    # loop reconciles to exactly one open wisp, and without --include-infra
    # every one of its queries returns [] regardless of status, so the surplus
    # burn never runs and each cycle pours a fresh wisp while its predecessor
    # leaks. Boot shipped with the bare form on all three sites one commit
    # after the witness fix, so scope this per-agent rather than widening the
    # witness test: a pack-wide assertion is red either way (measured 10/21 at
    # this commit) because the deacon and refinery sites are still bare and
    # tracked separately in #252.
    total=$(grep -h -- '--type=molecule' "$prompt" "$formula" |
        grep -c -F 'gc bd list' || true)
    flagged=$(grep -h -- '--type=molecule' "$prompt" "$formula" |
        grep -F 'gc bd list' | grep -c -- '--include-infra' || true)

    # -ge for the same reason as the witness guard: the flagged/total assertion
    # owns the contract, so the count is a floor that catches a deleted query
    # site, not a cardinality pin that a legitimate fourth query would break.
    [[ "$total" -ge 3 ]] ||
        fail "expected at least 3 boot --type=molecule wisp queries (5 at this commit: 2 prompt + 3 formula), found $total"
    [[ "$flagged" -eq "$total" ]] ||
        fail "boot --type=molecule wisp queries must pass --include-infra ($flagged/$total do)"
}

test_boot_patrol_burn_resolves_current_wisp() {
    local prompt formula asset name burn_lines bare

    prompt="$GASTOWN/agents/boot/prompt.template.md"
    formula="$GASTOWN/formulas/mol-boot-patrol.toml"

    # gc never sets GC_BEAD_ID for a named session: the session env builder
    # exports GC_SESSION_ID/NAME/ALIAS/TEMPLATE/ORIGIN/AGENT, and GC_BEAD_ID is
    # exported only into ralph check scripts. Boot has no hook-claim block to
    # export it, so a bare "$GC_BEAD_ID" burn target expands to the empty
    # string: "burn this wisp" reclaims nothing and leaves the wisp behind on
    # every cycle -- the same leak the --include-infra guard above exists for,
    # arriving by a different route. Every other patrol prompt resolves through
    # CURRENT_WISP with an in-progress fallback query, and so does every other
    # patrol formula except the witness's, which burns an agent-resolved
    # <this-wisp-id> placeholder instead. So pin that idiom on both boot assets
    # rather than the burn line alone: the deletion of either half is what
    # makes the target silently empty.
    for asset in "$prompt" "$formula"; do
        name=$(basename "$asset")

        grep -qF 'CURRENT_WISP=${GC_BEAD_ID:-}' "$asset" ||
            fail "$name must seed CURRENT_WISP from \$GC_BEAD_ID"
        grep -q -- 'CURRENT_WISP=\$(gc bd list .*--status=in_progress .*--include-infra' "$asset" ||
            fail "$name must fall back to an in-progress wisp query when \$GC_BEAD_ID is unset"
        grep -qF 'gc bd mol burn "$CURRENT_WISP" --force' "$asset" ||
            fail "$name must burn the resolved \$CURRENT_WISP"
    done

    # No burn call anywhere in boot's assets may address GC_BEAD_ID directly.
    # This is the assertion that survives a rewrite of the block above, and it
    # is what catches a *new* bare burn site rather than a mutated one. Same
    # prose tradeoff as the guards above: a doc line carrying both tokens fails
    # loudly, in the safe direction.
    burn_lines=$(grep -h -F 'gc bd mol burn' "$prompt" "$formula" || true)
    [[ -n "$burn_lines" ]] ||
        fail "expected boot assets to carry gc bd mol burn calls, found none"
    bare=$(printf '%s\n' "$burn_lines" | grep -c -F 'GC_BEAD_ID' || true)
    [[ "$bare" -eq 0 ]] ||
        fail "boot burn targets must resolve through \$CURRENT_WISP, not a bare \$GC_BEAD_ID ($bare do not)"
}

test_boot_deacon_observation_query_sees_wisps_tier() {
    local prompt formula asset name lines unflagged

    prompt="$GASTOWN/agents/boot/prompt.template.md"
    formula="$GASTOWN/formulas/mol-boot-patrol.toml"

    # The tier census above cannot protect this site. Reverting the
    # deacon-observation query to its blind pre-fix form drops --type=molecule
    # too, so the line leaves the numerator and the denominator together (5/5
    # -> 4/4) and the -ge 3 floor absorbs the loss: whole suite green, while
    # the decision table's wisp-keyed rows ("young wisp -> backoff", "very
    # stale wisp -> warrant") go back to being untriggerable because a patrol
    # wisp never shows in the deacon's work. Pin the site by its distinctive
    # text instead of by tier membership. The prompt's quick-reference row is
    # deliberately untyped -- it asks about deacon work generally -- so it
    # matches no counter at all and this is the only guard that reaches it.
    for asset in "$prompt" "$formula"; do
        name=$(basename "$asset")

        # || true is load-bearing: the suite runs under set -euo pipefail, so
        # an unguarded grep would kill the run with no diagnostic on exactly
        # the deletion arm the next assertion exists to report.
        lines=$(grep -- 'gc bd list --assignee=.*deacon' "$asset" || true)
        [[ -n "$lines" ]] ||
            fail "$name must keep a deacon-observation query"

        # Every matching line, not merely one of them: a grep -q over the whole
        # match set passes as soon as any deacon query carries the flag, so a
        # new blind one added beside a good one reads as covered. That is the
        # same addition shape the bare-burn census above exists to catch.
        unflagged=$(printf '%s\n' "$lines" | grep -c -v -- '--include-infra' || true)
        [[ "$unflagged" -eq 0 ]] ||
            fail "$name deacon-observation queries must pass --include-infra ($unflagged do not)"
    done
}

test_refinery_direct_merge_is_worktree_safe_and_fail_closed() {
    local script direct_block
    # The direct lane is merge-push.sh's (the formula's merge-push step runs it
    # since gcp-l8td.6): from the merge's worktree cleanup through lane_direct.
    script="$GASTOWN/assets/scripts/refinery/merge-push.sh"

    direct_block=$(python3 - "$script" <<'PY'
import sys
text = open(sys.argv[1], encoding="utf-8").read()
start = text.index('merge_ff_push_cleanup_wt() {')
end = text.index('# MERGE_STRATEGY = mr:')
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

    python3 - "$script" <<'PY' || fail "direct refinery merge must verify origin before setting merged metadata"
import sys
text = open(sys.argv[1], encoding="utf-8").read()
start = text.index('merge_ff_push_cleanup_wt() {')
end = text.index('# MERGE_STRATEGY = mr:')
block = text[start:end]
verify = block.index('git merge-base --is-ancestor "$TEMP_SHA" "$AFTER_SHA"')
metadata = block.index('--set-metadata merge_result=merged')
if verify >= metadata:
    raise SystemExit(1)
PY
}

# The refinery formula and its prompt are one contract surface (the paired pin
# in test_work_bead_resolution_discriminator_is_pinned loops both paths for the
# same reason), so the prompt must not contradict the formula's guarded rebase.
# Issue 374 made `git rebase origin/$TARGET` conditional on an ancestry probe,
# which turned two previously-correct prompt lines wrong: a one-liner under a
# column header titled "Correct command", and a categorical rebase MUST. Both
# are what an agent copies instead of re-reading the step.
test_refinery_rebase_guidance_matches_the_guarded_step() {
    local refinery refinery_prompt probe path unguarded
    refinery="$GASTOWN/formulas/mol-refinery-patrol.toml"
    refinery_prompt="$GASTOWN/agents/refinery/prompt.template.md"
    probe='git merge-base --is-ancestor "origin/$TARGET" "origin/$BRANCH"'

    # The formula decides and the prompt may only describe the decision, so the
    # probe has to be present in both: dropping it from either half is what let
    # the two descriptions drift apart in the first place.
    for path in "$refinery" "$refinery_prompt"; do
        grep -F -- "$probe" "$path" >/dev/null ||
            fail "the refinery rebase is an ancestry decision, not an unconditional rebase; the probe is missing from $path"
    done

    # Every quick-reference row naming the rebase must name the probe in the
    # same row.  Counting unguarded rows rather than pinning one exact row keeps
    # this from freezing the row's wording.  Scoped to table rows (lines opening
    # with `|`), because file-wide it also reds prose that legitimately names the
    # bare rebase -- describing the rc=1 arm, for instance.  The cheat-sheet
    # one-liner this exists to catch is a table row by construction.
    unguarded="$(grep -E '^\|' "$refinery_prompt" | grep -F 'git rebase origin/$TARGET' | grep -c -v -F -- "$probe" || true)"
    [[ "${unguarded:-0}" -eq 0 ]] ||
        fail "the refinery prompt publishes 'git rebase origin/\$TARGET' as a Correct command without the ancestry probe in the same row (${unguarded} row(s)); a bare cheat-sheet one-liner overrides the guarded step"

    # The Sequential Rebase Protocol's MUST is the other half. Scoped to the
    # diverged case it agrees with the step; categorical it forbids the skip arm.
    ! grep -F 'Next branch MUST rebase on new baseline.' "$refinery_prompt" >/dev/null ||
        fail "the refinery prompt's Sequential Rebase Protocol still states a categorical rebase MUST; scope it to the diverged case so it cannot override the rebase step's skip arm"
}

test_prime_prompts_are_city_generic_and_compact() {
    local mayor propulsion awareness
    mayor="$GASTOWN/agents/mayor/prompt.template.md"
    propulsion="$GASTOWN/template-fragments/propulsion.template.md"
    awareness="$GASTOWN/template-fragments/operational-awareness.template.md"

    ! grep -E 'hq-|gt-|anthropics/|Wyvern game' "$mayor" >/dev/null ||
        fail "mayor prompt must not hardcode demo cities, rigs, prefixes, or organizations"
    ! grep -E '\{\{ \.IssuePrefix \}\}|\{\{ \.RigName \}\}' "$mayor" >/dev/null ||
        fail "city-scoped mayor prompt must not render rig-scoped variables"
    ! grep -F '**Rig lifecycle commands:**' "$mayor" >/dev/null ||
        fail "mayor prompt should not duplicate the rig lifecycle quick-reference"
    [[ $(grep -c '^## Handoff$' "$mayor") -eq 1 ]] ||
        fail "mayor prompt should describe handoff once"

    grep -F 'gc hook --claim --json' "$propulsion" >/dev/null ||
        fail "propulsion roles should use the standard hook claim path"
    ! grep -E '\{\{ \.(WorkQuery|AssignedReadyQuery|RoutedPoolQuery) \}\}' "$propulsion" >/dev/null ||
        fail "mayor, crew, and dog propulsion should not inline generated work-query blobs"
    ! grep -F '{{ .WorkQuery }}' "$GASTOWN/agents/dog/prompt.template.md" >/dev/null ||
        fail "dog prompt should not expose the generated pool query"
    grep -F 'gc hook --claim --json' "$GASTOWN/agents/dog/prompt.template.md" >/dev/null ||
        fail "dog prompt should use atomic hook claim"
    ! grep -F 'port 3307' "$awareness" >/dev/null ||
        fail "operational awareness must not hardcode a Dolt port"
    grep -F 'gc dolt status' "$awareness" >/dev/null ||
        fail "operational awareness should direct agents to the effective Dolt port"
    grep -F 'Never probe a guessed or fixed Dolt port.' "$awareness" >/dev/null ||
        fail "operational awareness must forbid guessed Dolt endpoints"
    grep -F 'configured endpoint and the exact probe target' "$awareness" >/dev/null ||
        fail "operational awareness must require configured and probed endpoint evidence"
    grep -F 'endpoint is unknown and stop' "$awareness" >/dev/null ||
        fail "operational awareness must fail closed when endpoint discovery fails"
    grep -F 'run_bounded() {' "$awareness" >/dev/null ||
        fail "operational awareness should define a portable diagnostic timeout helper"
    # Steps 1 and 4 dial the resolved endpoint directly, not through `gc`:
    # gc's own startup (measured 5-23s here, gascity-8tvt) cannot fit a bound
    # small enough to tell a wedged server from a slow CLI (gcp-02bn).
    grep -F 'run_bounded 10 dolt --host "$DOLT_HOST" --port "$DOLT_PORT"' "$awareness" >/dev/null ||
        fail "operational awareness should bound the process-list diagnostic at the resolved endpoint"
    grep -F 'run_bounded 60 gc dolt health --json' "$awareness" >/dev/null ||
        fail "operational awareness should bound the health diagnostic"
    [[ "$(grep -c -F 'run_bounded 10 dolt --host "$DOLT_HOST" --port "$DOLT_PORT"' "$awareness")" -ge 2 ]] ||
        fail "operational awareness should bound the reachability diagnostic at the resolved endpoint"
    grep -F 'python3 - "$bound_seconds" "$@"' "$awareness" >/dev/null ||
        fail "operational awareness should use the portable Python timeout fallback"
    grep -F 'process.wait(timeout=2)' "$awareness" >/dev/null ||
        fail "operational awareness should grant a short SIGTERM grace period"
    grep -F 'process.kill()' "$awareness" >/dev/null ||
        fail "operational awareness should kill a diagnostic that ignores SIGTERM"
    grep -F 'sys.exit(124)' "$awareness" >/dev/null ||
        fail "operational awareness should use the conventional timeout exit status"
    ! grep -E '(^|[[:space:]])timeout[[:space:]]+[0-9]' "$awareness" >/dev/null ||
        fail "operational awareness must not require GNU coreutils timeout"

    # The pins above are content-only: they cannot see a python syntax error, a
    # dropped `shift`, or a deleted exit path inside the fenced helper. Execute
    # the shipped helper so a functionally broken run_bounded cannot ship green.
    # This also carries the deadline contract that `sys.exit(124)` above can no
    # longer carry alone: that literal now appears twice (deadline and bad-bound
    # rejection), so the presence pin is satisfied by either occurrence.
    local helper helper_rc
    helper="$(sed -n '/^run_bounded() {$/,/^}$/p' "$awareness")"
    [[ -n "$helper" ]] ||
        fail "run_bounded helper not found between 'run_bounded() {' and its closing brace"
    [[ "$helper" != *'SHOW FULL PROCESSLIST'* ]] ||
        fail "run_bounded helper extraction overshot its closing brace anchor"

    helper_rc=0
    ( eval "$helper"; run_bounded 5 sh -c 'exit 7' ) || helper_rc=$?
    [[ "$helper_rc" -eq 7 ]] ||
        fail "shipped run_bounded must pass a bounded command's exit status through (want 7, got $helper_rc)"

    helper_rc=0
    ( eval "$helper"; run_bounded 1 sleep 3 ) || helper_rc=$?
    [[ "$helper_rc" -eq 124 ]] ||
        fail "shipped run_bounded must return 124 when the deadline fires (want 124, got $helper_rc)"

    helper_rc=0
    ( eval "$helper"; run_bounded 5s true ) 2>/dev/null || helper_rc=$?
    [[ "$helper_rc" -eq 124 ]] ||
        fail "shipped run_bounded must reject a GNU-suffix bound closed with 124 (want 124, got $helper_rc)"

    # A child that dies to a signal inside the bound reports a negative
    # returncode; the helper must report the shell's 128+N (143), not 241.
    helper_rc=0
    ( eval "$helper"; run_bounded 5 sh -c 'kill -TERM $$; sleep 5' ) || helper_rc=$?
    [[ "$helper_rc" -eq 143 ]] ||
        fail "shipped run_bounded must report a signal-killed child as 128+N (want 143, got $helper_rc)"
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
    # is bounded by [session] setup_timeout (10s) and SIGKILLed on overrun, and
    # an overrun fails the session start and eventually latches the circuit
    # breaker (gcp-ntbf, gcp-oo0v). The pack-wide inventory in test_agent_pre_start_budget.sh is
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
    # Shape, not tree name (gcp-elv3): a home is `<lane-tree>/<agent>`, two
    # levels under the rig's worktree root. The `polecats` literal this
    # replaced is what hid every `views/<view-home>` from the sweep.
    grep -F '[ "${worktrees_root##*/}" = worktrees ]' "$audit" >/dev/null ||
        fail "home audit must restrict candidates to agent homes under the rig's worktree root"
    grep -F '[ "${lane_tree##*/}" != worktrees ]' "$audit" >/dev/null ||
        fail "home audit must exclude the per-bead worktrees one level deeper; those are task worktrees, not homes"
    grep -F '[ "$wt" != "$MAIN_WT" ]' "$audit" >/dev/null ||
        fail "home audit must exclude the main worktree; it is the canonical checkout, never a candidate"
    ! grep -E '^[[:space:]]*\*/[A-Za-z]+/\*' "$audit" >/dev/null ||
        fail "home audit must not gate on a lane-tree name; that is the blind spot gcp-elv3 closed"
    grep -F 'record home_children_kept' "$audit" >/dev/null ||
        fail "home audit must defer a home that still hosts per-bead worktrees; a LIVE polecat from another slot can be working inside a dead home's subtree (gcp-actg)"
    grep -F 'git -C "$WT" status --porcelain' "$audit" >/dev/null ||
        fail "home audit must refuse to remove a home with uncommitted work"
    grep -F 'git -C "$WT" rev-list --count HEAD --not --remotes' "$audit" >/dev/null ||
        fail "home audit must refuse to remove a home holding commits that reach no remote; unlike a per-bead worktree there is no closed bead to prove the work landed"

    # Fail closed on the roster: a confirmation read that fails is not proof
    # of absence, and reading it as an empty roster clears every home on the
    # rig at once.
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

    # gcp-rz8a: the step ended at drain-ack without closing its own step bead,
    # so the pool handed the completed step to the next session. Upstream #490
    # now closes the claimed step (via `gc hook current`) before every
    # drain-ack in this step, and tests/test_v2_drain_ack_closes_own_step.py
    # pins that. What stays pinned here is that the close never targets the
    # convoy or the work bead.
    [[ "$submit_block" != *'gc bd close "$GC_BEAD_ID"'* ]] ||
        fail "for a polecat \$GC_BEAD_ID is the convoy, not this step; closing it closes live work"
    [[ "$submit_block" != *'gc bd close "$WORK_BEAD_ID"'* ]] ||
        fail "the polecat never closes the work bead; only the refinery does"

    # gcp-rz8a's severity line: a replayed step 6 clears gc.routed_to="human",
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
reassign = reassign[reassign.index("**6. Reassign to refinery"):]
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

    # gcp-0pa4: the assignee mark was `!= $STEP_SESSION`, which every third party
    # a bead can end up on satisfies — an operator parking it on a crew seat, a
    # witness re-routing it, a reviewer taking it. A resuming polecat read that
    # as a handoff, drained, and the refinery never received the work while the
    # branch sat on origin unmerged (observed on winnow-zgr2y.8, parked on
    # winnow/specialists.thomas). Only one assignee means "submit-and-exit ran".
    [[ "$submit_block" == *'REFINERY_TARGET="${GC_RIG:+$GC_RIG/}{{binding_prefix}}refinery"'* ]] ||
        fail "the already-submitted guard must resolve the refinery target the same way the handoff writes it"
    [[ "$submit_block" == *'[ "$SUBMITTED_ASSIGNEE" = "$REFINERY_TARGET" ]'* ]] ||
        fail "the already-submitted guard must require the work bead to be held by the refinery, not merely by somebody other than this session"
    [[ "$submit_block" != *'[ "$SUBMITTED_ASSIGNEE" != "$STEP_SESSION" ]'* ]] ||
        fail "assignee != this session is not proof of a refinery handoff (gcp-0pa4)"

    # The resolve has to sit inside the guard's own block: every fenced block in
    # this step re-derives its ids because an agent may run each in a fresh
    # shell, and an empty REFINERY_TARGET here silently turns the identity test
    # into "assignee is empty", which never fires and never bails out.
    python3 - "$formula" <<'PY' || fail "the already-submitted guard must resolve REFINERY_TARGET in its own block rather than inherit it"
import sys
import tomllib

data = tomllib.load(open(sys.argv[1], "rb"))
step = next(s for s in data["steps"] if s["id"] == "submit-and-exit")
text = step["description"]
guard = text[text.index("**0. Already-submitted guard"): text.index("**1. Branch-shape gate")]
if 'REFINERY_TARGET="${GC_RIG:+$GC_RIG/}{{binding_prefix}}refinery"' not in guard:
    raise SystemExit(1)
if guard.index("REFINERY_TARGET=") >= guard.index('[ "$SUBMITTED_ASSIGNEE" = "$REFINERY_TARGET" ]'):
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
        # Scoped to the convoy-recovery query itself. This used to be a
        # file-wide `! grep -- '--status=in_progress '`, which conflated two
        # different lookups: the startup claim block legitimately resolves an
        # in-flight, hook-claimed step with in_progress ALONE (adding `open`
        # there would let it jump to a step whose predecessor has not closed).
        # The invariant that actually matters is local to this query — the step
        # bead it recovers the convoy from is stored `open`, so in_progress
        # alone matches nothing and the recovery silently yields no convoy.
        python3 - "$guard" <<'PY' || fail "$(basename "$guard") must recover the convoy's held step bead with --status=open,in_progress; a pool-assigned step bead is stored open, so in_progress alone matches nothing"
import sys

text = open(sys.argv[1], encoding="utf-8").read()
start = text.index("ROOT_BEAD_ID=$(gc bd list")
query = text[start:text.index("CONVOY_ID=$(gc bd show", start)]
if "--status=open,in_progress" not in query:
    raise SystemExit(1)
PY
        ! grep -F '[ "$WORK_STATUS" != "in_progress" ]' "$guard" >/dev/null ||
            fail "$(basename "$guard") must not treat an unassigned work bead as already submitted"
        grep -F '[ "$WORK_STATUS" = "closed" ]' "$guard" >/dev/null ||
            fail "$(basename "$guard") must require positive evidence (closed, or held by the refinery)"

        # The same gcp-0pa4 defect as the formula guard, in the copy an agent
        # actually has in context when it decides whether to drain.
        grep -F 'REFINERY_TARGET="${GC_RIG:+$GC_RIG/}{{ .BindingPrefix }}refinery"' "$guard" >/dev/null ||
            fail "$(basename "$guard") must resolve the refinery target the same way the handoff writes it"
        grep -F '[ "$WORK_ASSIGNEE" = "$REFINERY_TARGET" ]' "$guard" >/dev/null ||
            fail "$(basename "$guard") must require the work bead to be held by the refinery before draining"
        ! grep -F '[ "$WORK_ASSIGNEE" != "$EXPECTED_ASSIGNEE" ]' "$guard" >/dev/null ||
            fail "$(basename "$guard") reads any third-party assignee as a completed handoff (gcp-0pa4)"
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
if claim >= text.index("**2. Ensure a safe per-bead artifact worktree exists.**"):
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

    # Never steal a bead the refinery or an operator escalation already owns —
    # and never mistake "any assignee" for that. gcp-cvbs: the guard used to
    # skip the claim for every non-empty assignee, which is the ordinary shape
    # of planned work (the crew seat that filed it), so the bead stayed open in
    # `gc bd ready` all run and a second molecule was poured on it. The skip
    # must name its two owners. Behaviour is covered end-to-end in
    # test_polecat_work_bead_claim_guard.sh; these pin the condition itself.
    [[ "$setup_block" == *'[ "$CURRENT_ASSIGNEE" = "$REFINERY_TARGET" ]'* ]] ||
        fail "the claim must identify a refinery-held bead by identity, not by 'somebody else holds it'"
    [[ "$setup_block" == *'[ "$CURRENT_ROUTED_TO" = "human" ]'* ]] ||
        fail "the claim must recognise the gc.routed_to=human operator escalation"
    [[ "$setup_block" != *'if [ -n "$CURRENT_ASSIGNEE" ] && [ "$CURRENT_ASSIGNEE" != "$POLECAT_SESSION" ]'* ]] ||
        fail "the claim skip is back to 'any assignee that is not me', which voids it on every crew-authored bead"

    # The bead's own note: pool dispatch leaves gc.routed_to blank on the work
    # bead on purpose so scale_check can see pool demand. Stamping it here
    # breaks spawn accounting instead of fixing visibility. READING the key is
    # how the escalation above is recognised, so the ban is on the write.
    [[ "$setup_block" != *'set-metadata gc.routed_to'* ]] ||
        fail "the work-bead claim must not stamp gc.routed_to; routing lives on the molecule root"
    [[ "$setup_block" != *'unset-metadata gc.routed_to'* ]] ||
        fail "the work-bead claim must not clear gc.routed_to; submit-and-exit is the single release point"

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

    # `gc bd ready` is blocker-aware but EXCLUDES in_progress, so on its own it
    # cannot see a step this session already claimed. The hook's recovery tier
    # matches the in-flight step AND the held work bead and returns either, so a
    # ready-only re-point silently finds nothing on the work-bead outcome — the
    # stall it exists to prevent. Resume the claimed step before falling back.
    python3 - "$prompt" <<'PY' || fail "the step re-point must look for an in_progress step bead before falling back to the blocker-aware gc bd ready query"
import sys

text = open(sys.argv[1], encoding="utf-8").read()
block = text[text.index("bash <<'GC_CLAIM'"): text.index("GC_CLAIM\n```")]
inflight = block.index('--status=in_progress \\\n    --has-metadata-key gc.step_ref')
if inflight >= block.index("gc bd ready --assignee="):
    raise SystemExit(1)
PY

    # The fallback must stay `gc bd ready`, not a bare `gc bd list` over open
    # steps: an `open` step whose predecessor has not closed is not runnable,
    # and jumping to it skips the step in between.
    [[ "$(grep -c -F 'gc bd ready --assignee=' "$prompt")" == "1" ]] ||
        fail "the step re-point's fallback must remain the single blocker-aware gc bd ready query"
    python3 - "$prompt" <<'PY' || fail "the step re-point must run before the polecat_session stamp, so the stamp lands on the bead actually being executed"
import sys

text = open(sys.argv[1], encoding="utf-8").read()
block = text[text.index("bash <<'GC_CLAIM'"): text.index("GC_CLAIM\n```")]
if "STEP_REPOINTED" not in block:
    raise SystemExit(1)
# Match the STAMP precisely, not any polecat_session write: the live-owner
# guard also writes that key when it restores a step to its owner, and that
# write legitimately precedes the re-point (a declining polecat never reaches
# it). The stamp is the one that names THIS session.
if block.index("STEP_REPOINTED") >= block.index('--set-metadata polecat_session="$EXPECTED_ASSIGNEE"'):
    raise SystemExit(1)
PY

    # A resumed molecule finds its work bead held by its own PREVIOUS session
    # (pool restarts mint a new identity). Reading that as "handed off" drains
    # with the branch unpushed — the failure the guard exists to prevent. The
    # escape used to be an explicit `assignee != metadata.polecat_session`
    # exception; gcp-0pa4 replaced it with the positive
    # `assignee == $REFINERY_TARGET` test, which excludes a predecessor session
    # and every other non-refinery identity by construction. Pin the property,
    # not the mechanism: no polecat session identity is ever the refinery target.
    local guard
    for guard in "$prompt" "$fragment"; do
        grep -F '[ "$WORK_ASSIGNEE" = "$REFINERY_TARGET" ]' "$guard" >/dev/null ||
            fail "$(basename "$guard") must not read a previous polecat session's own claim as a completed handoff"
    done
}

test_dog_assets_are_pack_local
test_retired_dog_formulas_are_not_reintroduced
test_work_bead_is_claimed_for_the_whole_run
test_submit_and_exit_cannot_be_replayed
test_polecat_home_teardown_has_an_owner
test_dolt_push_outage_detection_is_wired
test_digest_archive_bead_is_not_left_open
test_shutdown_dance_contracts_are_executable
test_shutdown_dance_lifecycle_and_audit_contracts
test_work_bead_resolution_discriminator_is_pinned
test_composition_is_documented
test_polecat_startup_uses_standard_hook_claim
test_claim_verify_separates_read_failure_from_unassigned
test_claim_refuses_a_pour_onto_a_live_owner
test_review_leg_contract_forbids_synthetic_mutation
test_prime_prompts_are_city_generic_and_compact
test_witness_wisp_queries_pin_include_infra
test_witness_handoff_recovery_is_guarded_and_fail_closed
test_boot_wisp_queries_pin_include_infra
test_boot_patrol_burn_resolves_current_wisp
test_boot_deacon_observation_query_sees_wisps_tier
test_refinery_direct_merge_is_worktree_safe_and_fail_closed
test_refinery_rebase_guidance_matches_the_guarded_step

echo "gastown pack asset tests passed"
