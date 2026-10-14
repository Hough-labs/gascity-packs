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

## Merge strategies

Work beads default to `metadata.merge_strategy=direct`: refinery lands the
branch on the target and closes the bead after verifying the remote target.
With `mr` / `pr`, refinery publishes a GitHub pull request and records a
pending handoff. The source bead stays `blocked` until
`gc gastown pr-merge-reconcile` verifies the validated PR head was merged and
its merge commit is reachable from the recorded target branch. The command
also binds the PR repository to the rig's github.com `origin` and ignores
local replacement refs and grafts when proving ancestry. Keeping the source
bead non-closed also keeps its dependency children non-ready.

The reconciler checks at most one pending PR per refinery work scan, including
re-entry after an idle wake. It also adopts interrupted open markers left by a
recycled refinery: complete `pull_request_pending` records finish blocking,
while incomplete or changed-head records return to full refinery validation
without losing work or artifacts. Incomplete recovery retains only the
validated `existing_pr` reuse hint while clearing partial handoff and terminal
evidence. Before GitHub lookup, blocked records must be exact
`pull_request_pending`, or complete `mr_merged` evidence retained after a
verified close failure; other blocked lifecycle states are quarantined. Open
PRs remain pending, changed open heads return to refinery quality gates, and
closed-unmerged, contradictory, or merged-unvalidated PRs remain blocked for
operator review. A verified close records the distinct
`merge_result=mr_merged` state and retains both the validated `pr_head_sha` and
exact `polecat/<work>` source branch through artifact cleanup. Cleanup is never
invoked by the MR publication path. Because blocked beads are not session
demand, the witness patrol wakes the refinery whenever a pending PR check is
due, so a merged PR releases its dependents even when no other merge work
arrives.

This contract applies to new handoffs. An upgrade does not reopen legacy beads
that an older pack already closed at PR publication; operators should audit
those closed `merge_result=pull_request` records against their PR state before
relying on their dependency edges.

## Default Sling Formula

The polecat agent ships an agent-level default sling formula, so a plain
`gc sling <rig>/gastown.polecat "<text>"` compiles `mol-polecat-work`
(`method = "default-on-formula"`) instead of routing a bare bead.

That agent-level value outranks a city's `[agent_defaults]
default_sling_formula`: `Agent.EffectiveDefaultSlingFormula()` returns the
agent's own value before any inherited one, and `ApplyAgentDefaults` fills the
city default in only for agents that set neither their own nor an inherited pack
default. A city that deliberately routed polecat slings through its own default
formula is therefore shadowed when it upgrades to a gastown pack carrying this
knob.

The config-level override is a per-agent patch, which assigns the agent's own
value and so wins over the pack's:

```toml
[[patches.agent]]
dir = "<rig>"
name = "gastown.polecat"
default_sling_formula = "mol-your-formula"
```

Per sling, an explicit choice still short-circuits ahead of the default:
`--no-formula` routes a raw bead, `<formula> --formula` instantiates that formula
instead (`--formula` is a boolean that reinterprets the positional argument), and
`--on <formula>` attaches one to an existing bead. `[agent_defaults]` is the one
knob that cannot override the agent's own value.

## Role prompts and formula commands

`agents/*/prompt.template.md` is injected into an agent's context at spawn and
reads as authoritative operating instructions. A formula step in `formulas/`
has to be opened deliberately. That asymmetry makes a restated command
dangerous: when the formula gains a flag and the prompt's copy does not, the
agent runs the lossy copy, it executes cleanly, and the dropped behaviour is
simply gone. A partial command in injected context is worse than no command.

**The rule: the formula step owns the command.** A prompt template either
names the step, or carries a *complete* copy that names the step it copies; the
formula is authoritative wherever the two disagree. A condensed copy is never
acceptable. Commands an agent runs mid-cycle, such as filing a warrant or
finding work, point at their step.

Copies exist where a pointer cannot do the job:

- **Cold-start bootstrap.** The first wisp pour has no formula step to read
  yet. Marked as bootstrap-only in each template, with a pointer to the
  `next-iteration` step that owns every later pour.
- **Crash recovery.** A patrol session that exits a cycle without running
  `next-iteration` has to restore the one-wisp invariant before it can read a
  step at all, so the witness, deacon, refinery and boot prompts carry a copy
  of that step. Upstream restates these blocks too and pins their queries in
  its own tests (`test_witness_wisp_queries_pin_include_infra`), so the fork
  keeps them rather than replacing them with pointers.
- **A flag whose omission fails silently.** The refinery's Rejection Flow
  quotes the pool-return `gc bd update` verbatim, marked as a copy naming the
  authoritative step, because a rejection that drops
  `--set-metadata gc.routed_to=...` orphans the bead with no error, no stall
  signal, and no wake.

Boot is no longer an exception. It used to be a single-pass watchdog with no
formula, so its prompt carried the warrant command; upstream #261 gave it the
`mol-boot-patrol` loop, its stuck warrant is now filed by that formula's
`check-deacon` step, and its prompt points there.

`tests/test_prompt_formula_command_drift.py` enforces the invariants whose loss
was observed in practice: pool-returning updates declare their routing, warrant
creation in injected context is deduped, a pool-routed warrant also declares
`gc.kind=workflow` so it is a pollable workflow root, and a prompt bail-out path
drain-acks. They run over every prompt template, copies included. Boot alone
is exempt from the bail-out check: its always-mode patrol loop must never
drain-ack, so its crash-recovery copy aborts with a bare `exit 1` on purpose.

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
