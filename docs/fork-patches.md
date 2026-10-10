# Fork patch management (the `integration` branch)

This fork carries a small set of fork-local changes on top of a **pinned
upstream `gastownhall/gascity-packs` commit**. The mechanism is a
`git format-patch` / `git am` patch stack, lifted from the same system used in
`gascity`, `gastown`, and `beads`.

## The model

- **`integration`** — the branch that carries the fork. It is
  `BASELINE` + the commits in `patches/`, in order.
- **`BASELINE`** — a pinned upstream commit, defined in the `Makefile`. The
  fork's patches are always replayed onto exactly this commit, so the pack set
  a fork build ships is reproducible.
- **`patches/`** — a **derived artifact**: the `git format-patch BASELINE..HEAD`
  export of the fork's divergence, excluding `patches/` itself. It is committed
  so the divergence is reviewable and replayable, but it is regenerated, never
  hand-edited.

### Why the baseline is a commit SHA, not a release tag

In `gascity` the baseline is deliberately a pinned upstream **release tag** SHA,
so the fork tracks an LTS line rather than a moving `main`. This repo has no
comparable release cadence — when the fork started, its newest tag (`v0.4.0`,
the first baseline `f69ec02b`) was already the last one, and `upstream/main`
moved 116 commits past it before the first upgrade, so pinning a tag would
replay the fork onto a pack set nothing in production actually uses. The baseline here is therefore an upstream `main`
commit, still pinned **by SHA** so it can never move under the fork. When this
repo starts cutting meaningful releases, move `BASELINE` onto a release SHA and
this section becomes a note about how it used to work.

There is also no `BASELINE_VERSION` here. That value exists in `gascity` to
stamp `gc version` on a fork binary; this repo builds no binary, so a version
string nothing reads would be dead weight. Pack versions are carried by
`registry.toml`.

## Setup in a fresh clone

Nothing to remember. The pre-push guard lives in `.githooks/`, which git does not
consult by default, so the `Makefile` arms it at parse time — any `make`
invocation in this repo points `core.hooksPath` at `.githooks` and the guard
becomes real. This is as automatic as git safely allows: it deliberately runs
nothing of its own from a freshly cloned repo.

Arming never overrides a `core.hooksPath` you already set (a global hooks manager,
say). In that case, or to set it explicitly:

```bash
make hooks
```

The guard is advisory either way — `git push --no-verify` bypasses it, and a clone
that never runs `make` is never armed. `make check-patches` is the authoritative
check; run it in CI if the fork ever grows one.

### What the guard covers

Every pushed **branch**, not just `integration`. The obligation to re-export
`patches/` belongs to whoever authors a fork commit, so the check has to fire on
the push that author actually performs — their topic branch. Guarding only
`integration` put the check on a push the author never makes: a stale export
went out green, and surfaced a full review cycle later when someone else pushed
the merge, on a branch that had already been approved.

Tag pushes and branch deletions are skipped (no tree to validate), as are
branches that do not descend from `BASELINE` — an upstream-only topic branch
carries no fork divergence to export, and `BASELINE..HEAD` there would describe
an unrelated stack.

The commit validated is the SHA git is about to send, read out of that commit's
tree — never the working tree. A `patches/` regenerated on disk but not
committed is not what the push delivers, so it does not satisfy the guard. This
is why the everyday flow below ends in a commit.

`make test-patch-guard` exercises the hook end-to-end against a scratch repo
with a real remote.

Remotes follow the same convention as the `gascity` fork — `origin` is the fork,
`upstream` is the source repo:

```bash
git remote -v
# origin    git@github.com:Hough-labs/gascity-packs.git
# upstream  git@github.com:gastownhall/gascity-packs.git
```

## Everyday workflow — adding or changing a fork patch

```bash
git switch integration
# ... make your change ...
git commit -m "fix(scope): what and why"

make patches                       # regenerate patches/ from the divergence
git add patches/
git commit --amend --no-edit       # fold the export into the same commit
```

`make check-patches` (run automatically by the pre-push hook on every branch
push) fails the push if `patches/` does not match the `BASELINE..<pushed SHA>`
divergence, so the export can never silently drift from the commits.

The same applies to a fork commit authored on a topic branch — `polecat/<bead>`,
a feature branch, anything that will eventually reach `integration`. Regenerate
and commit the export there too, or the push is refused:

```bash
make patches && git add patches/ && git commit --amend --no-edit
```

To check a commit other than `HEAD` by hand:

```bash
make check-patches REV=<commit-ish>
```

## Upgrading the baseline (moving to a newer upstream commit)

1. Pick the new upstream commit (`git fetch upstream`, then resolve it with
   `git rev-parse upstream/main`) and update **every** copy of `BASELINE` — the
   `Makefile`, and the standalone defaults in `scripts/upgrade-integration.sh`
   and `scripts/check-patches.sh`. All three must agree;
   `git grep -n <old-baseline> -- ':!patches/'` lists them.
2. **Fold that bump into the patches that introduce it** — the patch-management
   patch (`0001`) creates the `Makefile` block and the upgrade script, and the
   pre-push guard patch creates `scripts/check-patches.sh`. A bump committed on
   top would just be a patch rewriting lines earlier patches had written, and
   the stack would grow by one such patch per upgrade forever. Make one fixup
   per introducing commit instead, so the stack stays at the fork's real
   changes:

   ```bash
   git commit --fixup <sha-of-patch-0001-commit> -- Makefile scripts/upgrade-integration.sh
   git commit --fixup <sha-of-the-guard-commit> -- scripts/check-patches.sh
   GIT_SEQUENCE_EDITOR=true git rebase --autosquash --onto <old-baseline> <old-baseline>
   make patches && git add patches/ && git commit --amend --no-edit
   ```

   This is the one exception to the everyday "commit it like any other fork
   patch" flow.
3. Run the guided upgrade:

   ```bash
   make upgrade
   ```

   It fetches `upstream`, copies `patches/` to a tmpdir (the reset would wipe
   it), resets `integration` to `BASELINE`, replays the patches with
   `git am --3way`, and regenerates `patches/`.
4. On a conflict, `git am` stops with instructions: resolve, `git add`,
   `git am --continue`. The upgrade script has already exited by then, so its
   last step does not run: once every patch is applied, regenerate the export
   yourself (`make patches && git add patches/ && git commit`). To bail out,
   `git am --abort` and reset to the PRE-upgrade tip, not to `BASELINE`: the
   reset left `integration` at bare upstream and the script's tmpdir copy of
   `patches/` is already gone.
5. **When upstream already fixed what a patch fixes, drop the patch.** A patch
   that only conflicts is adapted; a patch whose defect upstream fixed is
   skipped (`git am --skip`) or removed from history afterwards, never
   reverted on top. The bar is behaviour: run the patch's own test against
   upstream's code, or cite the upstream test that covers the case. Where the
   patch does more than upstream, keep upstream's change and re-apply only
   the extra. A skip renumbers every later patch file, so refer to patches by
   subject or bead id in notes, never by number.
6. **Look for duplication that did not conflict.** `git am --3way` only
   surfaces textual conflicts. An upstream fix in a different file, or a
   redesign the patch now fights, replays cleanly. Classify every patch
   (carried / adapted / partial / superseded) against the new upstream range,
   not only the ones that stopped.
7. **Run the full gates on the new tip and diff the reds** against the old
   tip and against pristine upstream at the new baseline, with the `gc` the
   city will run. A red that neither of those has is the upgrade's. Use a
   clean git identity (`GIT_CONFIG_GLOBAL`): a signing global config fails
   tests that create tags.
8. **Check the `gc` the new baseline needs.** Upstream packs move with the
   `gc` release they were written against; read that release's Upgrading
   Notes against the pack content, and make sure the city gets that `gc`
   before (or with) the pack pin.
9. **Re-pin fork-only registry releases.** A release `commit` in
   `registry.toml` that names a fork commit dies with the old history: the
   replay rewrites every fork commit. Re-pin each such release to the
   restacked commit carrying the identical subtree
   (`git rev-parse <old>:<pack>` equals `git rev-parse <new>:<pack>`), inside
   the patch that introduced the pin, and check
   `git merge-base --is-ancestor <pin> HEAD`. Re-validate:

   ```bash
   make registry-format-validate
   make registry-validate GC=/path/to/gc
   ```

   Before the force-push, `registry-validate` passes even with a stale pin,
   because origin still carries the old history; only the ancestry check
   catches it.
10. **Publish without losing the old history.** Tag the old tip on origin
    (`archive/integration-<old-baseline>`) and keep the tag: city lockfiles
    and pins name old commits. Then
    `git push --force-with-lease=integration:<old-tip> origin integration`.
11. **Move in-flight branches.** A branch cut from the old `integration` does
    not descend from the new `BASELINE`, so the pre-push guard reports it as
    "not checked" and is blind to it. Rebase each with
    `git rebase --onto origin/integration <old-tip> <branch>`; a plain rebase
    would replay every adapted commit whose patch id changed. Beads already
    queued at the refinery need the same rebase before they merge.

## Why patches/ is excluded from its own export

`git format-patch BASELINE..HEAD -- . ':!patches/'` excludes the `patches/`
pathspec. Without the exclusion the export would recursively include previous
exports, ballooning every patch. A commit that touches only `patches/` is
therefore omitted from the export entirely (history simplification treats it as
empty), which is why the everyday flow folds `patches/` back into the source
commit with `--amend`.
