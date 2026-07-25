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
comparable release cadence — its newest tag (`v0.3.0`) is ~190 commits behind
`upstream/main`, so pinning there would replay the fork onto a pack set nothing
in production actually uses. The baseline here is therefore an upstream `main`
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

`make check-patches` (run automatically by the pre-push hook on this branch)
fails the push if `patches/` does not match the current `BASELINE..HEAD`
divergence, so the export can never silently drift from the commits.

## Upgrading the baseline (moving to a newer upstream commit)

1. Pick the new upstream commit (`git fetch upstream`, then resolve it with
   `git rev-parse upstream/main`) and update **both** `BASELINE` in the
   `Makefile` and the standalone default in `scripts/upgrade-integration.sh` —
   the two must agree.
2. **Fold that bump into the patch that introduces it** — the patch-management
   patch (`0001`) is what creates the `Makefile` block and the upgrade script,
   so a bump committed on top would just be a patch rewriting a line an earlier
   patch had written, and the stack would grow by one such patch per upgrade
   forever. Amend it into `0001` instead, so the stack stays at the fork's real
   changes:

   ```bash
   git commit --fixup <sha-of-patch-0001-commit>
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
   `git am --continue` — or `git am --abort` to bail.
5. Re-validate the pack set against the new baseline:

   ```bash
   make registry-format-validate
   make registry-validate GC=/path/to/gc
   ```

## Why patches/ is excluded from its own export

`git format-patch BASELINE..HEAD -- . ':!patches/'` excludes the `patches/`
pathspec. Without the exclusion the export would recursively include previous
exports, ballooning every patch. A commit that touches only `patches/` is
therefore omitted from the export entirely (history simplification treats it as
empty), which is why the everyday flow folds `patches/` back into the source
commit with `--amend`.
