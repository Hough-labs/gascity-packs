# gauntlet-tdd

The [gauntlet](https://github.com/Hough-labs/gauntlet) RED-to-GREEN contract
loop distributed as a Gas City pack.

Encodes the TDD cycle a careful contributor runs by hand — scaffold a contract
from a bead's acceptance criteria, watch it fail, implement, watch it pass —
so any city that imports this pack gets the same discipline as platform-native
formulas and commands.

## Status

**v0.1.0** — initial release. Ships one formula with a matching wrapper
command:

| Formula | Command | Purpose |
|---------|---------|---------|
| `mol-tdd-red-green` | `gc <binding> tdd red-green <bead-id>` | Bead → scaffold → RED → implement → GREEN |

The loop writes a `.bats` contract into the repository's contracts directory,
a report to `.gc/gauntlet-tdd/loops/<bead-id>.md`, and whatever the
implementation itself changes. It does not push or open PRs — that stays with
the rig's own submit path.

## Usage

In your city's `pack.toml`:

```toml
[imports.gauntlet-tdd]
source = "../packs/gauntlet-tdd"
```

Then, from inside a rig session:

```
gc gauntlet-tdd tdd red-green gaunt-8ibp
```

or explicitly:

```
gc gauntlet-tdd tdd red-green gaunt-8ibp --rig gauntlet
```

The equivalent direct sling, if you would rather skip the wrapper:

```
gc sling gauntlet/polecat mol-tdd-red-green --formula --var contract_bead=gaunt-8ibp
```

## Requirements

### The gauntlet CLI

The `gauntlet` binary must be on the agent's PATH inside the rig worktree.
The formula assumes these verbs, all of which are dispatched in
`cmd/gauntlet/main.go`:

| Step | Verb |
|---|---|
| scaffold the contract | `gauntlet scaffold --from-bead <id>` |
| prove RED | `gauntlet lint [path] [--json]` |
| prove GREEN | `gauntlet run local <bead-id> [--contracts-dir <path>] --contracts=bats` |
| drop the red-by-design tag | `gauntlet bats untag-green` |

**The two commands spell the contracts directory differently.** `gauntlet
lint` takes a positional path and rejects the flag form outright —
`lint: unknown flag: --contracts-dir` — while `gauntlet run local` takes
`--contracts-dir <path>`. The formula derives both spellings from the single
`contracts_dir` var, and the test suite asserts no lint invocation is given
the flag. Worth knowing because the failure is invisible at the default: with
`contracts_dir` unset, both forms collapse to `.gauntlet` and the mistake
never shows.

Verified against gauntlet at commit `201c94f` — `git describe --tags` reports
**`v0.1.0-454-g201c94f`**. The CLI has no `--version` flag and no `version`
subcommand, so `git describe` in the gauntlet checkout is the version marker
to compare against.

### Single-implementer rigs

The `implement` step is the only routed step. It carries
`gc.run_target = "{{implementer_target}}"`, which defaults to
**`gastown.polecat`**.

`gc.run_target` only reaches roles the *consuming rig* actually imports. The
gauntlet rig imports `gastown` (giving `gastown.polecat` and
`gastown.refinery`) and its own local crew pack; the twelve build-pack roles
that `bmad`, `gstack` and friends fan out to — design-author, task-decomposer,
implementation-reviewer and the rest — are winnow-only and are **not**
reachable there.

So this formula is deliberately built for a single-implementer rig: exactly
one routed step, to one role, which every gastown-importing rig has. If your
rig's implementer is a different role, name it rather than adding steps:

```
gc gauntlet-tdd tdd red-green gaunt-8ibp --rig gauntlet --implementer crew.valkyrie
```

**Required imports.** A consuming rig must import a pack providing the role
named by `implementer_target`. With the default that is the `gastown` pack,
and `gastown.polecat` is then the only step target this pack names. The test
suite asserts that every step target the formulas name is documented here, so
a new routed role cannot be added without landing in this section.

### The bead is the contract

`gauntlet scaffold --from-bead` reads the bead's **acceptance criteria** and
emits one `@test` stub per testable assertion. A bead with empty acceptance
criteria scaffolds to nothing, so the `intake` step halts on it rather than
producing an empty contract two steps later.

## Why the red gate is `gauntlet lint`

Freshly scaffolded stubs are skip-guarded and tagged `red-by-design`. A
skipped test is not a failed test, so **`gauntlet run local` exits 0 on a
brand-new scaffold**. Measured on the smoke below, on the same tree:

```
$ gauntlet run local gaunt-8ibp --contracts=bats
GAUNTLET_SUMMARY workflow=bats-tests total=3 pass=0 fail=0 red_expected=0 red_unexpected=0 regressions=0 skipped=3 duration=0
$ echo $?
0

$ gauntlet lint
.gauntlet/gauntlet-tdd-smoke.bats:7   todo_skip  scaffold placeholder 'skip "TODO"' left in test
.gauntlet/gauntlet-tdd-smoke.bats:11  todo_skip  scaffold placeholder 'skip "TODO"' left in test
.gauntlet/gauntlet-tdd-smoke.bats:15  todo_skip  scaffold placeholder 'skip "TODO"' left in test
scanned=1  clean=0  findings=3
$ echo $?
1
```

Using `run local` as the red gate would therefore certify an empty contract
and wave the whole loop through — an inverted gate, not a weaker one. The
scaffold command says so itself on the way out: *"stubs are skip-guarded and
lint-red; run `gauntlet lint` to observe red, then replace skip with real
assertions."*

`gauntlet lint` is the red gate. `gauntlet run local` is the green gate. The
pack's test suite asserts that neither can drift into the other's job.

## Why the lane is pinned to bats

`gauntlet scaffold --from-bead` emits a `.bats` skeleton, and a bead-scoped
`gauntlet run local` picks its runner by **file extension** (`inferTool`), not
by a lane flag — `.bats` routes to the bats runner, `.hurl` to the hurl
runner. A scaffolded bead's only covering file is therefore always `.bats`.

Every run in this formula still passes `--contracts=bats` explicitly, and the
test suite asserts that no step passes `--contracts=hurl`. That turns a
property of the current scaffold output into an enforced invariant: the loop
cannot drift onto the hurl lane, and the two open hurl-corpus defects in the
gauntlet repo (`gaunt-4bzz`, `gaunt-svhp`) stay off this pack's path by
construction rather than by luck.

## Why run state is appended, never replaced

The molecule root bead is the control bead, and every step writes its run
state there with `gc bd update <root-id> --append-notes`. **Never `--notes`:
that flag REPLACES the field.**

This is not a tidiness preference — it is the one cross-step handoff the loop
depends on. `scaffold` records `contract_path:`, and `implement` reads it
back two steps later to know which file it is working on. A replacing write
anywhere in between erases it, and `gc bd update` still exits 0, so the loss
surfaces as an unexplained `no contract_path on the root bead` at the
implement gate rather than at the write that caused it.

Appending also leaves the witness's and refinery's own annotations on a
shared bead intact. The `implement` reader takes `tail -1`, so a key written
more than once resolves to the latest value.

## Related: `gauntlet loop`

`gauntlet loop --bead <id> [--exit-on-green] [--max-iter N] [--exec '<cmd>']`
is a real command in the gauntlet CLI (dispatched at `cmd/gauntlet/main.go`)
that runs this same RED-to-GREEN cycle in a single process. It appears in no
help text and no docs, which is easy to miss.

This pack deliberately does **not** wrap it. `loop`'s `--exec` model drives
implementation as an opaque subprocess; this formula's implement step is a gc
dispatch, so the witness sees a real session and the refinery sees a real
branch. Different orchestration models — use `gauntlet loop` for a local
single-process cycle, use this pack when the loop should be visible to the
city.

## End-to-end smoke

Run against bead **`gaunt-8ibp`** ("gauntlet-tdd pack smoke: RED-to-GREEN on
the bats lane") in the gauntlet rig, on the bats lane:

| Stage | Command | Result |
|---|---|---|
| scaffold | `gauntlet scaffold --from-bead gaunt-8ibp` | wrote `.gauntlet/gauntlet-tdd-smoke.bats`, 3 `@test` stubs, tier=B |
| RED | `gauntlet lint` | exit 1 — `scanned=1 clean=0 findings=3`, three `todo_skip` |
| (control) | `gauntlet run local gaunt-8ibp --contracts=bats` | exit 0 on the *unimplemented* scaffold — why lint is the red gate |
| implement | stubs replaced with real assertions | — |
| GREEN | `gauntlet lint` | exit 0 — `scanned=1 clean=1 findings=0` |
| GREEN | `gauntlet run local gaunt-8ibp --contracts=bats` | exit 0 — `total=3 pass=3 fail=0 skipped=0` |

Note for anyone reproducing it outside a rig worktree: `scaffold --from-bead`
resolves the bead through the `bd` CLI against whatever store the CWD resolves
to, and an inherited `BEADS_DIR` from an agent session overrides that. If the
scaffold reports "no issue found" for a bead `gc bd show` can read, that
inherited variable is the cause, not a missing bead.

## Tests

```
python3 -m pytest gauntlet-tdd/tests/test_gauntlet_tdd_formulas.py -q
```

The suite is pack-local, mirroring `pr-pipeline/tests/`. It asserts the
formulas parse, declare their required vars, name only documented step
targets, keep the red gate on `gauntlet lint`, keep the lane pinned to bats,
and write run state with `--append-notes` rather than `--notes`. `.github/workflows/ci.yml` names `gauntlet-tdd/tests` in its pytest path
list — that list is explicit, not a glob, so a new pack's suite is invisible
to CI until it is added there.
