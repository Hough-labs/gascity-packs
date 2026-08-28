Drive the gauntlet RED-to-GREEN contract loop for a bead — scaffold the
contract from the bead's acceptance criteria, prove it red, implement, prove
it green.

This dispatches a coding agent to a rig with the `mol-tdd-red-green` formula.
The agent scaffolds a `.bats` contract from `<bead-id>`'s acceptance criteria,
proves it RED with `gauntlet lint`, implements until the assertions hold, and
proves it GREEN with a bead-scoped `gauntlet run local --contracts=bats`. A
report is saved to `.gc/gauntlet-tdd/loops/<bead-id>.md`.

Usage:
  gc <binding> tdd red-green <bead-id> [flags]

Arguments:
  <bead-id>              Bead whose acceptance criteria seed the contract.
                         Must be a full id (`gaunt-8ibp`), not a fragment —
                         `bd` fuzzy-matches partial ids onto the wrong bead.

Flags:
  --rig <name>           Rig to run the loop inside (defaults to $GC_RIG).
  --agent <name>         Agent name to sling to (default: "polecat").
                         Set this if your city's coding-worker pool uses a
                         different name (e.g. "claude", "worker").
  --implementer <role>   Role the implement step is routed to
                         (default: "gastown.polecat"). Must be a role the
                         consuming rig actually imports — `gc.run_target`
                         reaches no further than the rig's own imports.
  --contracts-dir <path> Contracts directory override. Default is the
                         repository's own `.gauntlet/`.

Examples:
  # Inside a rig session (GC_RIG is set automatically):
  gc <binding> tdd red-green gaunt-8ibp

  # Explicitly target a rig:
  gc <binding> tdd red-green gaunt-8ibp --rig gauntlet

  # Route implementation to a rig-specific implementer role:
  gc <binding> tdd red-green gaunt-8ibp --rig gauntlet --implementer crew.valkyrie

Direct sling (skip this command):
  gc sling gauntlet/polecat mol-tdd-red-green --formula --var contract_bead=gaunt-8ibp

Requirements:
  The `gauntlet` CLI must be on the agent's PATH inside the rig worktree, and
  the bead must carry non-empty acceptance criteria — they are the contract.

Output:
  The contract is written under the repository's contracts directory as a
  `.bats` file carrying `# covers: <bead-id>`. The report is written to
  `<repo-root>/.gc/gauntlet-tdd/loops/<bead-id>.md`. The molecule's root bead
  notes record `contract_path:`, `red_findings:` and `report_path:`, or
  `halt_reason:` if a gate stopped the loop.

Environment variables (set by gc):
  GC_CITY_PATH      absolute city root
  GC_PACK_DIR       absolute pack directory
  GC_PACK_NAME      pack name ("gauntlet-tdd")
  GC_CITY_NAME      city workspace name
  GC_RIG            current rig name (when running inside a rig session)
