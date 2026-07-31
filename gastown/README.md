# Gastown Pack

Gastown is the domain-specific coding workflow pack. It provides the city
coordinator roles, rig worker roles, patrol formulas, and the pack-local dog
pool used for stuck-agent shutdown warrants.

## Import

```toml
[imports.gastown]
source = "../packs/gastown"
```

Use the pack as the workspace pack for city-scoped agents and as a rig pack for
rig-scoped agents.

## Composition

Gas City composes the builtin core pack (mechanical housekeeping orders)
through the explicit `includes` entries that `gc init` writes into
city.toml; this pack composes alongside it via `[imports.gastown]`. The
retired maintenance pack no longer exists: gastown's `mol-shutdown-dance`
and dog prompt fragments (`propulsion-dog`, `architecture`,
`following-mol`) are the only copies in play, and cross-pack agent name
collisions are hard errors rather than fallback resolutions.

Verify the composed recipe after changing imports:

```bash
gc formula show mol-shutdown-dance
```

The recipe must read warrant metadata from the claimed bead via
`$GC_BEAD_ID` and must not declare a required `warrant_id` var.

## Merge Approval Gate

`mol-refinery-patrol` can require a reviewed merge. The gate is **opt-in per
rig** and off by default, so rigs that do not require review are unaffected:

```toml
[rigs.formula_vars]
require_merge_approval = "true"
review_agent = "specialists.iris"   # optional: nudged when a bead parks
```

`review_agent` is resolved, not assumed. A bare name is nudged at rig scope
first (`<rig>/specialists.iris`) and then town-level (`gastown.mayor`), so a
rig-local reviewer and a town agent are both reachable without the operator
having to know which scope owns the session; the rig attempt stays first so a
rig-local reviewer is never shadowed by a town agent of the same name. Write
`otherrig/agent` to pin another rig, or a leading `/` (`/gastown.mayor`) to go
straight to town level. Whichever way it resolves, the outcome is written to the
work bead as `merge_approval_nudge`: either `delivered:` and the address that
took it, or `failed:` and every scope that refused. The nudge is fire-and-forget
and a failed one never blocks the park, so without that marker an unreachable
reviewer is a silent failure — the bead parks correctly and nobody is ever told.

gc cannot emit a formal GitHub review event, so the approval signal is
gc-native: it lives in the work bead's own metadata, keyed to the PR number
and the exact head SHA the reviewer read.

| Metadata key | Meaning |
|---|---|
| `merge_approval.verdict` | `approved` or `changes_requested` |
| `merge_approval.pr_number` | PR the verdict applies to |
| `merge_approval.head_sha` | Full 40-hex commit the reviewer read |
| `merge_approval.reviewer` | Approving reviewer identity |
| `merge_approval.recorded_at` | UTC timestamp |
| `merge_approval_state` | `awaiting_review` while the gate has the bead parked |
| `merge_approval_gate_reason` | Why the gate refused this commit |
| `merge_approval_nudge` | Whether the reviewer was actually reached |

A reviewer agent produces the signal:

```bash
assets/scripts/record-merge-approval.sh \
    --bead <work-bead> --pr <number|url> --sha <live-head-sha> --verdict approved
```

The refinery consumes it through
`assets/scripts/checks/merge-approval-gate.sh`, which re-reads the live PR head
from GitHub and permits the merge only when the approved SHA is still the head.
An approval therefore authorizes one commit, not a branch — pushing after review
invalidates it. Every other outcome refuses, including the ones the gate cannot
explain (unreadable bead, PR lookup failure, unresolvable head SHA): a tool
error is a suspect, not a licence to merge.

The patrol formula locates that script through its own resolved source path —
`gc formula list --json` reports where gc loaded `mol-refinery-patrol.toml`
from, and the gate sits beside it in the same pack tree. That anchor is the
only one that holds in the context the formula actually runs in (the agent's
own shell, where `GC_PACK_DIR` is unset — gc exports it for pack *commands*
only) and it is version-coherent by construction: a formula from one pin can
never reach a gate from another. `$GC_CITY/.gc/scripts/checks/` and
`GC_PACK_DIR` remain fallbacks for cities that stage checks themselves. If none
resolve, patrol stops without touching bead state — an unreadable gate is not
an approval.

Turning the gate on implies the pull-request lane. `merge_strategy=direct` is
promoted to `mr`, because a reviewed merge needs a PR to review; PR publication
becomes the start of review instead of the terminal handoff, and a refused
merge parks the bead (`merge_approval_state=awaiting_review`) for the next
patrol iteration rather than closing or escalating it.

## Dog Pool

Gastown owns `mol-shutdown-dance` and the dog agent that runs stuck-agent
warrants, including the dog's `wake_mode` and `work_dir` settings. In import
composition gastown's dog expands as the distinct `gastown.dog` agent; the
dolt pack ships its own separate dog for Dolt maintenance formulas, and the
two coexist under their binding-qualified names.

Gastown deliberately does not ship retired dog formulas for JSONL export or
stale-session reaping. The Gas City builtin core pack provides JSONL export,
stale-session and stale-data cleanup, and Dolt housekeeping as deterministic
exec orders.
