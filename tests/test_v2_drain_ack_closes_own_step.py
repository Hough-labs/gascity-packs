"""A v2 workflow step must close itself before `gc runtime drain-ack`.

Every step of a formula_compiler >= 2.0.0 workflow is a bead that a pool worker
claims with `gc hook --claim`, so the step an agent is running is in_progress
and assigned to its session. `gc runtime drain-ack` begins by releasing every
in_progress claim the session still holds (gascity
`releaseUnexecutedClaimsOnDrainAck`, #5265, effective for pool sessions since
#5505): a step that acks without closing itself is handed back to the pool,
open and still routed, a fresh session runs it again, and the workflow-finalize
control it blocks never fires.

So in every step checked here, each `gc runtime drain-ack` must be preceded, in
the same fenced bash block, by a fail-closed close of the step the session is
running: resolved with `gc hook current --id-only`, guarded on status and
`gc.step_ref`, and closed `|| exit 1`. This is the shape gascity's core
formulas use (gascity ga-51rapt; mol-do-work's drain step, #5153).

Mid-workflow early exits and root-only patrol formulas cannot be fixed by the
close alone and are pinned below as known exceptions, so a new drain-ack site
has to be classified rather than silently inheriting either list.
"""

from __future__ import annotations

import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import textwrap
import tomllib

import pytest


REPO_ROOT = Path(__file__).resolve().parents[1]

# Steps whose every drain-ack must be preceded by the guarded own-step close.
# These are terminal steps: they block workflow-finalize directly, so closing
# them (gc.outcome=pass on success, fail on a halt) is sufficient on its own.
CHECKED_STEPS = {
    ("gastown/formulas/mol-polecat-work.toml", "submit-and-exit"),
    ("gastown/formulas/mol-review-leg.toml", "notify-close"),
    ("pr-pipeline/formulas/mol-pr-from-issue.formula.toml", "drain"),
}

# Mid-workflow early exits. Closing the step alone does not stop its
# dependents (a closed blocker satisfies `needs` whatever its gc.outcome), so
# these wait on the v2 early-abort idiom (scope + on_fail=abort_scope). Tracked
# in gascity; see the ga-uppw56 follow-ups. Remove an entry when it is fixed.
DEFERRED_STEPS = {
    ("gastown/formulas/mol-polecat-work.toml", "workspace-setup"),
    ("gastown/formulas/mol-polecat-work.toml", "self-review"),
    ("gastown/formulas/mol-review-leg.toml", "load-assignment"),
}

# v2 formulas whose steps are not beads: poured `--root-only` by a named
# session, so there is no step claim to close. Their drain-ack hazard is a
# different one (see the ga-uppw56 follow-ups).
EXEMPT_FORMULAS = {
    "gastown/formulas/mol-refinery-patrol.toml",
}

_OWN_STEP_CLOSE = re.compile(
    r'gc bd (?:update "\$([A-Z_]+)"[^\n]*--status[= ]closed|close "\$([A-Z_]+)")[^\n]*\|\| exit 1'
)


def bash_blocks(description: str) -> list[str]:
    blocks: list[str] = []
    block: list[str] = []
    in_bash = False
    for line in description.split("\n"):
        stripped = line.strip()
        if not in_bash and stripped.startswith("```bash"):
            in_bash, block = True, []
        elif in_bash and stripped == "```":
            in_bash = False
            blocks.append("\n".join(block))
        elif in_bash:
            block.append(line)
    return blocks


def drain_ack_violations(description: str, step_id: str) -> list[str]:
    """Every drain-ack line not preceded, in its own bash block, by a
    fail-closed, claim-resolved, step-guarded close of the running step."""
    violations = []
    for block in bash_blocks(description):
        lines = block.split("\n")
        for i, line in enumerate(lines):
            if "gc runtime drain-ack" not in line:
                continue
            preceding = "\n".join(lines[:i])
            closes_own_step = any(
                (m.group(1) or m.group(2)) != "WORK_BEAD_ID"
                for m in _OWN_STEP_CLOSE.finditer(preceding)
            )
            guarded = f'endswith(".{step_id}")' in preceding
            if "gc hook current --id-only" not in preceding or not closes_own_step or not guarded:
                violations.append(line.strip())
    return violations


def v2_formulas():
    for path in sorted(REPO_ROOT.glob("*/formulas/*.toml")):
        data = tomllib.loads(path.read_text())
        if "formula_compiler" in data.get("requires", {}):
            yield path.relative_to(REPO_ROOT).as_posix(), data


def drain_ack_steps():
    for rel, data in v2_formulas():
        for step in data.get("steps", []):
            if "gc runtime drain-ack" in step.get("description", ""):
                yield rel, step


def test_every_v2_drain_ack_step_is_classified():
    unclassified = [
        f"{rel}: {step['id']}"
        for rel, step in drain_ack_steps()
        if rel not in EXEMPT_FORMULAS
        and (rel, step["id"]) not in CHECKED_STEPS | DEFERRED_STEPS
    ]
    assert not unclassified, (
        "v2 formula steps run `gc runtime drain-ack` but are in no list above; "
        "a terminal step belongs in CHECKED_STEPS (and must close itself first): "
        + ", ".join(unclassified)
    )


@pytest.mark.parametrize("rel,step_id", sorted(CHECKED_STEPS))
def test_terminal_step_closes_itself_before_drain_ack(rel, step_id):
    data = tomllib.loads((REPO_ROOT / rel).read_text())
    steps = {s["id"]: s for s in data.get("steps", [])}
    assert step_id in steps, f"{rel} has no step {step_id}"
    description = steps[step_id]["description"]
    assert "gc runtime drain-ack" in description, f"{rel} {step_id} no longer drain-acks; drop it from CHECKED_STEPS"
    violations = drain_ack_violations(description, step_id)
    assert not violations, (
        f"{rel} {step_id}: drain-ack hands this still-claimed step back to the pool, "
        "so a fresh session re-runs it and the workflow never finalizes. Close the step "
        "the session is running first (gc hook current --id-only, guarded on in_progress "
        f"and a gc.step_ref ending .{step_id}, `|| exit 1`). Unguarded acks: {violations}"
    )


GUARDED = (
    'STEP_BEAD_ID=$(gc hook current --id-only) || exit 1\n'
    'STEP_BEAD=$(gc bd show "$STEP_BEAD_ID" --json) || exit 1\n'
    'printf \'%s\' "$STEP_BEAD" | jq -e \'.status == "in_progress" and ((.metadata["gc.step_ref"] // "") | endswith(".s"))\' >/dev/null || exit 1\n'
    'gc bd update "$STEP_BEAD_ID" --set-metadata gc.outcome=pass --status=closed || exit 1\n'
)


@pytest.mark.parametrize(
    "block,ok",
    [
        ("gc runtime drain-ack\nexit", False),
        ('gc bd close "$WORK_BEAD_ID" || exit 1\ngc runtime drain-ack', False),
        (
            'STEP_BEAD_ID=$(gc hook current --id-only) || exit 1\n'
            'gc bd update "$STEP_BEAD_ID" --status=closed\n'
            'gc runtime drain-ack',
            False,
        ),
        ('gc bd update "$STEP_BEAD_ID" --status=closed || exit 1\ngc runtime drain-ack', False),
        (
            'STEP_BEAD_ID=$(gc hook current --id-only) || exit 1\n'
            'gc bd update "$STEP_BEAD_ID" --status=closed || exit 1\n'
            'gc runtime drain-ack',
            False,
        ),
        (GUARDED + "gc runtime drain-ack", True),
        ('STEP_BEAD_ID=$(gc hook current --id-only) || exit 1\ngc runtime drain-ack\n' + GUARDED, False),
    ],
    ids=["bare", "work-bead-only", "not-fail-closed", "not-from-claim", "unguarded", "guarded", "ack-first"],
)
def test_checker_recognizes_the_guarded_close(block, ok):
    assert (not drain_ack_violations(f"```bash\n{block}\n```", "s")) == ok


# The checks above read the shape of each close. The ones below RUN every
# own-step close in mol-polecat-work's submit-and-exit against a fake `gc`,
# because the shape alone was satisfied by a close that could never fire there:
# the polecat startup block re-points onto a step with a plain
# `gc bd update <step> --claim`, which records the claim under BEADS_ACTOR but
# does not move the stamp `gc hook current` reads. The hook's crash-recovery
# tier serves the in_progress WORK bead at step boundaries and stamps THAT, so
# at submit-and-exit `gc hook current` names the work bead, the guard refused,
# and drain-ack never ran (gcp-fooz4 P1).
POLECAT_FORMULA = "gastown/formulas/mol-polecat-work.toml"
SUBMIT_STEP_REF = "mol-polecat-work.submit-and-exit"
ME = "winnow/gastown.furiosa"
WORK = "winnow-w1"
STEP = "winnow-w1.s9"

FAKE_GC = r"""
import json
import os
import sys

argv = sys.argv[1:]
with open(os.environ["GC_STUB_LOG"], "a") as log:
    log.write(json.dumps(["gc", *argv]) + "\n")
with open(os.environ["GC_STUB_BEADS"]) as handle:
    beads = json.load(handle)


def flag(name):
    for index, arg in enumerate(argv):
        if arg.startswith(name + "="):
            return arg.split("=", 1)[1]
        if arg == name and index + 1 < len(argv):
            return argv[index + 1]
    return None


scope, verb = (argv + ["", ""])[:2]
if scope == "hook" and verb == "current":
    current = os.environ.get("GC_STUB_HOOK_CURRENT")
    if current is None:
        sys.exit("gc: no current claim for this session")
    print(current)
elif scope == "runtime" and verb == "drain-ack":
    pass
elif scope == "bd" and verb == "show":
    found = [bead for bead in beads if bead["id"] == argv[2]]
    if not found:
        sys.exit("gc bd: no issue found matching " + repr(argv[2]))
    print(json.dumps(found))
elif scope == "bd" and verb == "list":
    # An empty --assignee is modelled as no filter at all: the worst reading,
    # so a resolve that forgets to require an identity lists everybody's steps.
    assignee = flag("--assignee")
    statuses = (flag("--status") or "").split(",")
    key = flag("--has-metadata-key")
    print(json.dumps([
        bead for bead in beads
        if (not assignee or bead.get("assignee") == assignee)
        and (statuses == [""] or bead["status"] in statuses)
        and (not key or key in bead.get("metadata", {}))
    ]))
elif scope == "bd" and verb == "update":
    target = next(bead for bead in beads if bead["id"] == argv[2])
    status = flag("--status")
    if status:
        target["status"] = status
    with open(os.environ["GC_STUB_BEADS"], "w") as handle:
        json.dump(beads, handle)
else:
    sys.exit("stub gc: unmodelled call: " + " ".join(argv))
"""


def submit_and_exit_drain_sites() -> list[str]:
    """Every own-step close in submit-and-exit, from the `gc hook current`
    resolve through the `gc runtime drain-ack` it guards, dedented."""
    data = tomllib.loads((REPO_ROOT / POLECAT_FORMULA).read_text())
    step = next(s for s in data["steps"] if s["id"] == "submit-and-exit")
    sites = []
    for block in bash_blocks(step["description"]):
        lines = block.split("\n")
        for i, line in enumerate(lines):
            if "gc runtime drain-ack" not in line:
                continue
            start = max(
                (j for j in range(i) if "gc hook current --id-only" in lines[j]),
                default=None,
            )
            assert start is not None, f"drain-ack with no `gc hook current` resolve before it: {line.strip()}"
            sites.append(textwrap.dedent("\n".join(lines[start : i + 1])))
    return sites


DRAIN_SITES = submit_and_exit_drain_sites()
DRAIN_SITE_IDS = [
    f"site{n}-" + (re.search(r"gc\.failure_reason=\"?\$?(\w+)", site) or re.search(r"gc\.outcome=(\w+)", site)).group(1)
    for n, site in enumerate(DRAIN_SITES, start=1)
]


def bead(bead_id, status, assignee, step_ref=None):
    metadata = {"gc.step_ref": step_ref} if step_ref else {}
    return {"id": bead_id, "status": status, "assignee": assignee, "metadata": metadata}


def molecule(*extra):
    """A polecat at submit-and-exit: the WORK bead it holds in_progress for the
    whole run (0060), an earlier step it already closed, and its re-pointed
    submit-and-exit step. A sibling polecat holds its own submit-and-exit step,
    so a resolve that is not scoped to this session has something to find."""
    return [
        bead(WORK, "in_progress", ME),
        bead("winnow-w1.s8", "closed", ME, "mol-polecat-work.self-review"),
        bead(STEP, "in_progress", ME, SUBMIT_STEP_REF),
        bead("winnow-w2.s9", "in_progress", "winnow/gastown.nux", SUBMIT_STEP_REF),
        *extra,
    ]


def run_drain_site(tmp_path, site, beads, hook_current, actor=ME):
    if shutil.which("jq") is None:
        pytest.skip("jq is required to run the formula's shell")
    stub_bin = tmp_path / "bin"
    stub_bin.mkdir()
    fake = stub_bin / "gc"
    fake.write_text(f"#!{sys.executable}\n{FAKE_GC}")
    fake.chmod(0o755)
    store = tmp_path / "beads.json"
    store.write_text(json.dumps(beads))
    log = tmp_path / "calls.log"
    log.touch()
    env = {
        "PATH": f"{stub_bin}{os.pathsep}{os.environ.get('PATH', '')}",
        "GC_STUB_BEADS": str(store),
        "GC_STUB_LOG": str(log),
        "BEADS_ACTOR": actor,
    }
    if hook_current is not None:
        env["GC_STUB_HOOK_CURRENT"] = hook_current
    result = subprocess.run(
        ["bash", "-c", site], env=env, capture_output=True, text=True, timeout=60
    )
    calls = [json.loads(line) for line in log.read_text().splitlines()]
    after = {b["id"]: b for b in json.loads(store.read_text())}
    return result, calls, after


def made(calls, *prefix):
    return [call for call in calls if tuple(call[: len(prefix)]) == prefix]


@pytest.mark.parametrize("site", DRAIN_SITES, ids=DRAIN_SITE_IDS)
@pytest.mark.parametrize(
    "hook_current",
    [WORK, None],
    ids=["hook-names-the-work-bead", "hook-current-unavailable"],
)
def test_drain_ack_closes_a_step_the_hook_does_not_name(tmp_path, site, hook_current):
    result, calls, after = run_drain_site(tmp_path, site, molecule(), hook_current)

    assert result.returncode == 0, result.stderr
    assert after[STEP]["status"] == "closed", "the re-pointed submit-and-exit step was left claimed"
    assert made(calls, "gc", "runtime", "drain-ack"), "drain-ack never ran"
    assert after[WORK]["status"] == "in_progress", "the WORK bead is never the polecat's to close"
    assert after["winnow-w2.s9"]["status"] == "in_progress", "closed another session's step"


@pytest.mark.parametrize("site", DRAIN_SITES, ids=DRAIN_SITE_IDS)
def test_drain_ack_keeps_closing_the_step_the_hook_names(tmp_path, site):
    """Upstream #490's resolve still comes first and is still sufficient."""
    result, calls, after = run_drain_site(tmp_path, site, molecule(), STEP)

    assert result.returncode == 0, result.stderr
    assert after[STEP]["status"] == "closed"
    assert made(calls, "gc", "runtime", "drain-ack")
    assert not made(calls, "gc", "bd", "list"), "the hook named the step; no fallback was needed"


@pytest.mark.parametrize("site", DRAIN_SITES, ids=DRAIN_SITE_IDS)
@pytest.mark.parametrize(
    "beads,actor",
    [
        ([bead(WORK, "in_progress", ME), bead("winnow-w2.s9", "in_progress", "winnow/gastown.nux", SUBMIT_STEP_REF)], ME),
        (molecule(bead("winnow-w0.s9", "in_progress", ME, SUBMIT_STEP_REF)), ME),
        (molecule(), ""),
    ],
    ids=["no-own-step", "two-own-steps", "no-actor"],
)
def test_drain_ack_refuses_without_exactly_one_own_step(tmp_path, site, beads, actor):
    result, calls, after = run_drain_site(tmp_path, site, beads, WORK, actor=actor)

    assert result.returncode == 1, result.stdout + result.stderr
    assert not made(calls, "gc", "runtime", "drain-ack"), "acked a drain with no step of ours to close"
    assert not made(calls, "gc", "bd", "update"), "closed a step it could not attribute to this session"
