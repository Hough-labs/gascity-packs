"""mol-polecat-work declares one continuation group, "main", on every step it owns.

Gas City no longer stamps a blanket `gc.continuation_group` on pool-routed graph
steps (gascity #5622, c91381b22): continuation is formula-declared only. Without
a declared group the steps of one polecat molecule are plain pool beads, so a
polecat that closes a step and runs `gc hook --claim` for the next one can be
handed an older routed pool bead that belongs to another molecule (gcp-fm79v).

When a step declares the group, graphroute stamps `gc.continuation_group` and
`gc.session_affinity=require` on it, and `gc hook --claim` pins the open
siblings that share the molecule root and the group to the claiming session.
The pin only holds if every step of the molecule names the same group, so a
step that declares a different one splits the molecule across two groups.

mol-polecat-work extends gc core's mol-polecat-base and overrides four of its
steps. A child step with the same id replaces the parent's wholesale, so the
declaration has to be on each of the four; the base's own load-context and
implement are gascity's to declare and are deliberately not copied here.
"""

from __future__ import annotations

import json
from pathlib import Path
import tomllib

import pytest

from gc_live_city import (
    REPO_ROOT,
    gc_test_bin,  # noqa: F401 -- pytest fixture, used by name
    run_gc,
    write_city,
)


FORMULA = REPO_ROOT / "gastown" / "formulas" / "mol-polecat-work.toml"
FORMULA_NAME = "mol-polecat-work"

GROUP_KEY = "gc.continuation_group"
AFFINITY_KEY = "gc.session_affinity"
GROUP = "main"
AFFINITY = "require"

# The steps this formula defines itself. Each one must carry the declaration.
DECLARING_STEPS = (
    "workspace-setup",
    "preflight-tests",
    "self-review",
    "submit-and-exit",
)

GASCITY_CORE_SOURCE = (
    "https://github.com/gastownhall/gascity.git//internal/bootstrap/packs/core"
)


def formula_steps() -> list[dict]:
    return tomllib.loads(FORMULA.read_text(encoding="utf-8"))["steps"]


def formula_step(step_id: str) -> dict:
    matches = [step for step in formula_steps() if step["id"] == step_id]
    assert len(matches) == 1, (
        f"{FORMULA.name} defines {len(matches)} steps with id {step_id!r}; "
        "expected exactly one"
    )
    return matches[0]


@pytest.mark.parametrize("step_id", DECLARING_STEPS)
def test_overriding_step_declares_the_main_continuation_group(step_id: str) -> None:
    metadata = formula_step(step_id).get("metadata", {})

    assert metadata.get(GROUP_KEY) == GROUP, (
        f"{FORMULA.name} step {step_id!r} does not declare "
        f"{GROUP_KEY} = {GROUP!r} (metadata: {metadata}); a pool claim can then "
        "return another molecule's bead in place of this molecule's next step"
    )
    assert metadata.get(AFFINITY_KEY) == AFFINITY, (
        f"{FORMULA.name} step {step_id!r} does not declare "
        f"{AFFINITY_KEY} = {AFFINITY!r} (metadata: {metadata})"
    )


def test_every_declared_continuation_group_is_main() -> None:
    declared = {
        step["id"]: step["metadata"][GROUP_KEY]
        for step in formula_steps()
        if GROUP_KEY in step.get("metadata", {})
    }
    # A scan that finds no declarations would make the equality below vacuous.
    assert declared, f"{FORMULA.name} declares no {GROUP_KEY} on any step"

    split = {step_id: group for step_id, group in declared.items() if group != GROUP}
    assert not split, (
        f"{FORMULA.name} steps declare a continuation group other than "
        f"{GROUP!r}, which splits the molecule across groups: {split}"
    )


def test_compiled_workflow_steps_carry_the_continuation_group(
    tmp_path: Path, gc_test_bin: Path  # noqa: F811
) -> None:
    """The TOML above is what we wrote; this is what gc compiles it into.

    `extends` replaces a parent step wholesale by id, so the metadata has to
    survive the merge with gc core's mol-polecat-base, not merely sit in our file.
    """
    workspace = write_city(tmp_path, {"gastown": REPO_ROOT / "gastown"})
    pack_toml = workspace.city_dir / "pack.toml"
    pack_toml.write_text(
        pack_toml.read_text(encoding="utf-8")
        + f"\n[imports.core]\nsource = {json.dumps(GASCITY_CORE_SOURCE)}\n",
        encoding="utf-8",
    )

    result = run_gc(gc_test_bin, workspace, "formula", "show", FORMULA_NAME, "--json")
    assert result.returncode == 0, (
        f"gc formula show {FORMULA_NAME} exited {result.returncode}:\n"
        f"{result.stdout}{result.stderr}"
    )
    compiled = {step["id"]: step for step in json.loads(result.stdout)["steps"]}

    for step_id in DECLARING_STEPS:
        recipe_id = f"{FORMULA_NAME}.{step_id}"
        assert recipe_id in compiled, (
            f"gc compiled {FORMULA_NAME} without step {recipe_id!r}; "
            f"got {sorted(compiled)}"
        )
        metadata = compiled[recipe_id].get("metadata", {})
        assert metadata.get(GROUP_KEY) == GROUP, (
            f"compiled step {recipe_id!r} lost {GROUP_KEY} = {GROUP!r} "
            f"(metadata: {metadata})"
        )
        assert metadata.get(AFFINITY_KEY) == AFFINITY, (
            f"compiled step {recipe_id!r} lost {AFFINITY_KEY} = {AFFINITY!r} "
            f"(metadata: {metadata})"
        )
