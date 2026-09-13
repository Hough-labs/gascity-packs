# Reaper budget starvation — analysis and plan (gcp-uzq0)

Status: **unblocked, dispatchable after the Bead B question in §8.**
`gcp-jxtc` LANDED 2026-09-13T20:59Z — `16f92c8` verified on `origin/integration`.
Every line reference below was re-verified against that result (1748 lines); see
§9 for what changed and the one finding it strengthens.

**Do not validate against live reaper logs.** The city's import pin is still
`2583963` (2026-09-06), where the reaper is **1079 lines** — 23 commits behind
`integration`. Every operational number in §1 was produced by that pinned script,
not by the one this plan patches.

Author: `gascity-packs/crew.pacman`, 2026-09-13. Written at the mayor's request
(analysis + plan + test approach) after they assigned `gcp-uzq0` with measured
evidence.

---

## 1. The symptom, restated from the durable record

From `$GC_CITY/.gc/runtime/logs/polecat-worktree-reap.log`, last 3000 lines,
all rigs, measured by the mayor 2026-09-13:

    88  budget_exhausted
    51  scan_complete
    21  roster_read_timed_out
    17  budget_spent_before_git_status

63% of cycles do not finish. The reaper is staged at dry-run, so this currently
costs observability rather than work — but it is what stands between the city
and a reaper that would actually reap once `gcp-jxtc` lands.

## 2. What is already fixed, and must not be re-built

**The reaper already rotates its window.** `gcp-schs` shipped a cursor:
`polecat-worktree-reap.sh:727-766` rotates the sorted candidate list to start
after the last-decided candidate, and `:1720-1731` persists it. A full pass
deletes the cursor so the next cycle starts at the head.

This matters because the mayor's scoping note says of `gcp-7fgg`:

> a fixed enumeration order plus a budget break always drops the SAME sorted
> tail … A fix that only raises the budget leaves that bias in place.

That is **true of the home audit and false of the reaper.** Anyone dispatched to
"add rotation to the reaper" would discover the machinery already exists and
then have to make a judgment call — the failure mode this seat exists to
prevent. See `gcp-5u8u` for the same trap caught in the same family of beads.

## 3. The actual defect — rotation is inert exactly when it is needed

The cursor advances **only when a candidate is decided**. From `:1729`:

```sh
elif [ -n "$DECIDED_LAST" ]; then
    printf '%s\n' "$DECIDED_LAST" >"$CURSOR_FILE" 2>/dev/null || true
fi
```

and the comment immediately below it, verbatim:

> A partial cycle that decided NOTHING leaves the previous cursor alone: it has
> no resume point of its own, and overwriting with an empty one would send the
> next cycle back to the head of the list — the bias, restored for free.

That reasoning is correct about writing an *empty* cursor. But combine it with
`gcp-uzq0`'s defect and the two compose into a hard stall:

1. The bulk bead read at `:813` consumes what is left of the 8s budget.
2. The candidate loop therefore never runs — `examined=0`, zero decisions.
3. `DECIDED_LAST` is empty, so the cursor is left untouched.
4. The next cycle rotates to **the same start point** and repeats.

So the round-robin never advances. Rotation is downstream of the very
starvation it was built to mitigate, and a rig that cannot afford one bead read
gets no coverage at all — not a slow walk, none. This is the mechanism behind
`gcp-ga3m` ("~half of runs emit no would-reap set at all") and it is why
`gcp-co29`'s promotion criterion can be met by a single load-lucky cycle.

## 4. Where the budget actually goes

The cycle makes **three `gc`-class calls** before the per-candidate git work:

| Site | Call |
|---|---|
| `:813` | bulk `bd`/`gc bd show <ids> --json` — the gate read |
| `:945` | `gc session list --state=all --json` — the roster read |
| `:1023` | bulk `bd`/`gc bd show <ids> --json` — the pre-removal recheck read |

Each pays full `gc` process startup. Measured on **gascity-packs**
(`inherited_city` endpoint) at load 18.68, 2026-09-13:

| Read | via `gc` | via bare `bd` | ratio |
|---|---|---|---|
| bead show, 1 id | 0.49 / 0.51 / 0.51 s | 0.10 / 0.10 / 0.09 s | ~5x |
| bead show, 30 ids | 1.89 / 1.52 s | 0.68 / 0.65 s | ~2.5x |
| `gc session list` | 3.32 / 1.84 / 1.44 s | — | — |

Two of those three calls already consume **3.0–5.2s of the 8s budget** before a
single `git status` runs — which is precisely the 17 `budget_spent_before_git_status`
lines in the log.

Two corrections to the bead's own cost model, both worth carrying forward:

- **The bead's "5.4s per invocation" is a winnow number, not a universal one.**
  Here the same call is 0.5s. The *ratio* (gc ≈ 5x bare bd) is what replicates
  across rigs; the absolute figure varies with endpoint origin and load. Plan
  against the ratio.
- **There is a real marginal per-id cost**, contra the description's "flat"
  claim. Fitting the two points above: bare `bd` ≈ 0.075s fixed + ~0.020s/id;
  `gc bd` ≈ 0.46s fixed + ~0.041s/id. Fixed overhead dominates at small N, which
  is why the 1-id and 14-id timings overlapped on gauntlet — but at winnow's 84
  candidates the marginal term is most of the cost (5.4s → 12.9s). A fix that
  only removes fixed overhead still degrades on a large rig.

## 5. Plan

Three beads, sequenced. **All land behind `gcp-jxtc`.**

### Bead A — make the reads cheap (the `gcp-uzq0` fix)

Replace the three `gc`-class invocations with the cheapest form that is still
correct, keeping every existing budget/yield semantic untouched.

- `GC_BD=(gc bd --rig "$RIG_NAME")` at `:446` becomes a bare `bd` invocation
  rooted at `$RIG_ROOT`, with the current `gc bd` form retained as a fallback
  when bare `bd` is absent or cannot resolve the store.
- The `run_bounded` wrapper, the `budget_left` accounting, the `classify_outcome`
  reason codes and every `record` call stay exactly as they are. This is a
  substitution of the transport, not a rework of the budget model.

**The correctness risk that gates this bead.** Bare `bd` must resolve the *same*
bead store as `gc bd --rig`, and rigs differ:

- gascity-packs (`inherited_city`): verified identical this session — bare `bd`
  from `$RIG_ROOT` and `gc bd --rig gascity-packs` returned the same
  `{id,status,assignee}` for `gcp-uzq0`.
- winnow (`explicit`, `127.0.0.1:3307`): **not verified.** A bare `bd` read there
  failed/timed out in this session, but winnow is suspended and its config
  carries an `EXPIRED` marker on that host/port, so this is inconclusive — it is
  not evidence that bare `bd` is wrong, only that the substitution is unproven
  on an explicit-endpoint rig. Proving it on a live `explicit` rig is acceptance
  for this bead, not an afterthought.

Fallback must be silent-safe: if bare `bd` cannot resolve, the script uses
`gc bd` and records a reason — it must never read the *wrong* rig's store.

### Bead B — make the cursor advance under starvation

Advance the cursor when a cycle **enumerated** candidates but decided none, so
rotation engages in exactly the case it currently cannot.

The existing comment rules out writing an *empty* cursor, and it is right to.
This is the different move: advance deliberately to the end of the window the
cycle covered (or by a bounded stride when nothing was examined at all), so
consecutive starved cycles walk the set instead of re-walking one point.

Constraint: a starved cycle must not be able to *look* like coverage. The
advance is a fairness mechanism, not a claim of examination — `scan_complete`
must still mean what it means today, and `gcp-co29`'s promotion criterion must
not be satisfiable by rotated starvation.

### Bead C — port rotation to the home audit (`gcp-7fgg`), as a sibling

**Do not fold `gcp-7fgg` into Beads A/B.** The mayor's stated reason for one
fix — "four separate patches to one script would conflict on the merge lane" —
does not apply: the home audit lives in `gastown/formulas/mol-witness-patrol.toml`
(`audit-polecat-homes`), a different file from `polecat-worktree-reap.sh`. Its
bias claim is genuinely true, because unlike the reaper it has **no cursor at
all** — `home_budget_exhausted` defers the remainder with nothing to rotate it
(`mol-witness-patrol.toml:863`).

So: `gcp-uzq0` + `gcp-ga3m` + `gcp-co29` are one fix (Beads A/B, one script).
`gcp-7fgg` is its sibling in a second file, and wants `gcp-schs`'s cursor
pattern ported to it.

## 6. Test approach

The hard part is that the failure is **load-dependent and non-monotonic** — the
gauntlet data shows a *lower*-load run producing worse coverage than a
higher-load one, so wall-clock A/B on a live rig proves nothing.

1. **Deterministic budget tests, not timing tests.** Drive the script with
   `--budget` (a plain flag, `:311`) and `GC_REAP_BUDGET_SECONDS` (`:293`) at
   values chosen to land the cut at a known point. Assert on emitted *reason
   codes*, which are already a closed vocabulary (`budget_spent_before_bead_query`,
   `bead_query_timed_out`, `worktree_budget_exhausted`, `scan_complete`), not on
   elapsed seconds.
2. **The regression test for Bead B is a cursor assertion across cycles.** Run
   N consecutive starved cycles (budget small enough to guarantee zero
   decisions) and assert the cursor *differs* between cycles and that the union
   of covered windows grows. Today that test fails: the cursor is byte-identical
   every cycle. That is the RED check, and it is red for the right reason —
   a real behavioural claim, not a missing flag.
3. **Bead A's acceptance is an equivalence test, not a speed test.** For each
   `gc.endpoint_origin` (`inherited_city`, `managed_city`, `explicit`), assert
   bare `bd` and `gc bd --rig` return the same `{id,status}` set for the same id
   list. Speed is the motivation; identity is the contract.
4. **Cost is a recorded measurement, not an assertion.** Log the per-call cost
   into the existing `record` stream rather than asserting a threshold in CI —
   a timing assertion on a shared box is a flake generator.
5. **Do not validate by deleting worktrees.** The bead says this and it stays
   true: hand-removing the candidate backlog makes the symptom vanish and leaves
   every mechanism intact to rebuild it.

## 7. Sequencing

```
gcp-jxtc (in flight, gastown.furiosa)
   └── Bead A  (gcp-uzq0)   cheap reads          — same script, land behind jxtc
         └── Bead B          cursor under starvation — same script, after A
   Bead C (gcp-7fgg)         home-audit rotation  — different file, parallel-safe
```

Bead C touches no file A or B touches and can run in parallel with either.

## 8. Open question for the Overseer / mayor

Bead B changes what the cursor *means* on a zero-decision cycle, and the current
behaviour is deliberate and commented. I am confident the change is right —
today's behaviour is a hard stall — but it reverses a documented decision, so it
is worth one explicit nod before dispatch rather than after.

---

## 9. Re-verification against jxtc's result (2026-09-13T21:00Z)

`gcp-jxtc` landed as `16f92c8` (+194/-5 on the reaper, 1559 → 1748 lines).
Both findings above were derived from the pre-jxtc tree and were re-checked
against the merged result rather than assumed forward. Both hold.

**Finding 1 (rotation already exists) — unchanged.** The cursor block is intact
at `:727-766`, and the write at `:1720-1731` is structurally identical.

**Finding 2 (cursor frozen under starvation) — HOLDS, AND jxtc MADE IT WORSE.**
This is the one thing that changed, and it strengthens Bead B rather than
weakening it.

jxtc added a fourth `DECIDED_LAST="$DECIDED_PREV"` rollback site. There were
three (now `:1392`, `:1475`, `:1599`); the new one is `:1653`, the removal-reserve
refusal:

```sh
if [ "$(budget_left)" -lt "$REMOVAL_RESERVE_SECONDS" ]; then
    TRUNCATED=1
    DECIDED_LAST="$DECIDED_PREV"
    record worktree_reap_failed "$BEAD" "$WT" ... reap_budget_insufficient
```

Its comment is correct per candidate — a reap that never happened must stay
inside the next cycle's window rather than be rotated past. But the *cross-cycle*
consequence runs the wrong way: the fewer seconds the cycle has, the more
candidates take a rollback path, so `DECIDED_LAST` advances less precisely when
the budget is tightest. In the limit where the first candidate cannot afford the
reserve, `DECIDED_LAST` is never set at all and the cursor does not move.

So jxtc improved per-candidate safety and worsened cross-cycle fairness under
exactly the budget pressure this bead describes. The two changes are not in
conflict — Bead B's advance must simply be driven by what the cycle
**enumerated**, not by what it **disposed of**, which is the distinction the new
rollback site makes unavoidable.

**A constraint on Bead A's expected saving, found during re-verification.** The
roster read at `:945` is a direct `gc session list --state=all --json` — it does
not go through the `GC_BD` array, and `gc session list` is a gc-native concept
with no bare-`bd` equivalent. So Bead A can only cheapen the *two bead reads*
(`:813`, `:1023`). The 1.4–3.3s roster read stays gc-class and stays in the
budget. Expected recovery is therefore bounded at roughly two fixed-overhead
units (~0.8s here, ~8s on a winnow-class rig) — real, and on winnow decisive,
but not the whole budget. Do not promise more than that.

**New test knob.** jxtc added `REMOVAL_RESERVE_SECONDS` (`:300`, env
`GC_REAP_REMOVAL_RESERVE_SECONDS`, flag at `:319`). Together with `--budget`
(`:311`) it gives the Bead B cursor test a second dial: force
`reap_budget_insufficient` deterministically by setting a reserve larger than the
remaining budget, and assert the cursor still advances.

**Bead C re-confirmed.** `gastown/formulas/mol-witness-patrol.toml` still
contains zero occurrences of `cursor`. The home audit has no rotation to this
day, so Bead C stands exactly as written.
