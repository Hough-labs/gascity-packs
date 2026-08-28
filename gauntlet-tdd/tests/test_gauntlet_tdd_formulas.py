"""Guards for the gauntlet-tdd pack's formulas.

Two invariants carry the whole pack, and both are the kind that fail silently
when they break:

1. **The red gate is `gauntlet lint`, never `gauntlet run local`.** Freshly
   scaffolded stubs are skip-guarded, so a bead-scoped `run local` exits 0 on
   an empty contract (measured on the gaunt-8ibp smoke: `pass=0 fail=0
   skipped=3`, exit 0, while `gauntlet lint` on the same tree exits 1 with
   three findings). A formula that proved red with `run local` would certify
   an empty contract and wave every later step through — an inverted gate, not
   a weaker one, and one that reports success the whole way.

2. **The lane is pinned to bats.** A bead-scoped run dispatches by file
   extension via `inferTool`, so a `.bats` covering file never reaches the
   hurl runner. That is what keeps the gauntlet repo's two open hurl-corpus
   defects (gaunt-4bzz, gaunt-svhp) off this pack's path. Asserting it here
   turns a property of today's scaffold output into an enforced invariant.

Plus the drift guard AC1 asks for: every step target a formula names must be
documented in the pack README as a required import, because `gc.run_target`
reaches no further than the roles the consuming rig actually imports.
"""

from __future__ import annotations

import pathlib
import re
import tomllib
import unittest


PACK_ROOT = pathlib.Path(__file__).resolve().parents[1]
FORMULAS = PACK_ROOT / "formulas"
README = PACK_ROOT / "README.md"

# Reserved graph.v2 runtime vars. A formula that declares one of these has its
# value clobbered by the runtime binding, silently. See
# gascity/formulas/REQUIREMENTS.md.
RESERVED_RUNTIME_VARS = frozenset({"issue", "bead_id", "convoy_id"})

# `{{token}}` occurrences, used both to resolve templated run targets and to
# catch a template token that names no declared var.
TEMPLATE_TOKEN = re.compile(r"\{\{([a-z_][a-z0-9_]*)\}\}")


def formula_paths() -> list[pathlib.Path]:
    paths = sorted(FORMULAS.glob("*.formula.toml"))
    assert paths, "no formulas found — the glob or the pack layout is wrong"
    return paths


def step_bodies(data: dict) -> dict[str, str]:
    return {step["id"]: step.get("description", "") for step in data["steps"]}


def shell_lines(body: str) -> list[str]:
    """Lines inside ```bash fences — the parts a step actually executes.

    An invocation check has to separate running a command from writing about
    one, or the rationale prose that explains WHY `run local` is the wrong red
    gate reads as a step invoking it. The repo's own drift guard draws the same
    line (tests/test_prompt_formula_command_drift.py, fenced_blocks).
    """
    lines: list[str] = []
    inside = False
    for raw in body.split("\n"):
        stripped = raw.strip()
        if stripped.startswith("```"):
            inside = stripped[3:].strip() == "bash" if not inside else False
            continue
        if inside:
            lines.append(raw)
    return lines


def shell_text(body: str) -> str:
    return "\n".join(shell_lines(body))


class PackFormulaShapeTests(unittest.TestCase):
    """Every formula in the pack parses and declares what it needs."""

    def test_every_formula_parses_as_toml(self) -> None:
        for path in formula_paths():
            with self.subTest(formula=path.name):
                data = tomllib.loads(path.read_text(encoding="utf-8"))
                self.assertIn("formula", data)
                self.assertIn("steps", data)
                self.assertTrue(data["steps"], "a formula with no steps runs nothing")

    def test_no_formula_declares_a_reserved_runtime_var(self) -> None:
        for path in formula_paths():
            data = tomllib.loads(path.read_text(encoding="utf-8"))
            declared = set(data.get("vars", {}))
            with self.subTest(formula=path.name):
                self.assertEqual(
                    declared & RESERVED_RUNTIME_VARS,
                    set(),
                    "reserved graph.v2 runtime vars are bound by the runtime and "
                    "would clobber the declared value",
                )

    def test_every_template_token_names_a_declared_var(self) -> None:
        # A typo'd `{{contact_bead}}` renders as empty string rather than
        # failing, so the scaffold would run against no bead at all.
        for path in formula_paths():
            text = path.read_text(encoding="utf-8")
            data = tomllib.loads(text)
            declared = set(data.get("vars", {}))
            with self.subTest(formula=path.name):
                for token in sorted(set(TEMPLATE_TOKEN.findall(text))):
                    self.assertIn(token, declared, f"{{{{{token}}}}} names no declared var")

    def test_step_needs_resolve_to_real_steps(self) -> None:
        for path in formula_paths():
            data = tomllib.loads(path.read_text(encoding="utf-8"))
            ids = {step["id"] for step in data["steps"]}
            with self.subTest(formula=path.name):
                for step in data["steps"]:
                    for need in step.get("needs", []):
                        self.assertIn(need, ids, f"step {step['id']} needs unknown {need}")


class StepTargetsAreDocumentedTests(unittest.TestCase):
    """AC1: a formula names only step targets the README documents.

    `gc.run_target` routing reaches only the roles the consuming rig actually
    imports, so an undocumented target is a step that silently never runs on a
    rig that did not happen to import it.
    """

    def test_run_targets_are_documented_in_the_readme(self) -> None:
        readme = README.read_text(encoding="utf-8")
        for path in formula_paths():
            data = tomllib.loads(path.read_text(encoding="utf-8"))
            variables = data.get("vars", {})
            for step in data["steps"]:
                target = step.get("metadata", {}).get("gc.run_target")
                if not target:
                    continue
                with self.subTest(formula=path.name, step=step["id"]):
                    # A templated target documents its DEFAULT role: that is
                    # the one a rig gets without passing anything.
                    token = TEMPLATE_TOKEN.fullmatch(target)
                    if token:
                        var = variables.get(token.group(1), {})
                        self.assertIn(
                            "default",
                            var,
                            "a templated run target needs a default, or the step "
                            "routes nowhere when the caller passes nothing",
                        )
                        resolved = var["default"]
                    else:
                        resolved = target
                    self.assertIn(
                        resolved,
                        readme,
                        f"step target {resolved!r} is not documented in README.md",
                    )


class RedGreenGateTests(unittest.TestCase):
    """AC4 + the green-gate half of the same invariant."""

    @classmethod
    def setUpClass(cls) -> None:
        cls.path = FORMULAS / "mol-tdd-red-green.formula.toml"
        cls.text = cls.path.read_text(encoding="utf-8")
        cls.data = tomllib.loads(cls.text)
        cls.steps = step_bodies(cls.data)

    def test_formula_is_present_and_well_formed(self) -> None:
        self.assertEqual(self.data["formula"], "mol-tdd-red-green")
        self.assertEqual(self.data["contract"], "graph.v2")

    def test_contract_bead_is_the_required_input(self) -> None:
        variables = self.data.get("vars", {})
        self.assertIn("contract_bead", variables)
        self.assertTrue(variables["contract_bead"]["required"])

    def test_companion_vars_carry_defaults(self) -> None:
        variables = self.data.get("vars", {})
        for name in ("implementer_target", "contracts_dir"):
            with self.subTest(var=name):
                self.assertIn(name, variables)
                self.assertIn("default", variables[name])
        self.assertEqual(variables["implementer_target"]["default"], "gastown.polecat")

    def test_red_gate_step_invokes_gauntlet_lint(self) -> None:
        self.assertIn("assert-red", self.steps)
        self.assertIn("gauntlet lint", shell_text(self.steps["assert-red"]))

    def test_red_gate_step_never_invokes_run_local(self) -> None:
        # The whole point: `run local` exits 0 on a skip-guarded scaffold, so
        # using it here would assert GREEN on an empty contract. The step's
        # prose explains exactly that, so the check reads the shell it runs.
        self.assertNotIn("gauntlet run local", shell_text(self.steps["assert-red"]))

    def test_no_step_treats_a_run_local_exit_zero_as_proof_of_red(self) -> None:
        # Only the implement loop and the green gate may run the contract at
        # all; a red assertion built on `run local` is inverted, not weaker.
        allowed = {"implement", "assert-green"}
        for step_id, body in self.steps.items():
            if "gauntlet run local" not in shell_text(body):
                continue
            with self.subTest(step=step_id):
                self.assertIn(
                    step_id,
                    allowed,
                    "only the implement and green-gate steps may run the contract",
                )

    def test_green_gate_requires_both_lint_and_a_bead_scoped_run(self) -> None:
        green = shell_text(self.steps["assert-green"])
        self.assertIn("gauntlet lint", green)
        self.assertIn("gauntlet run local", green)
        # A run whose tests all skipped exits 0. The green gate has to reject
        # that explicitly or it inherits the same hole as the red gate.
        self.assertIn("skipped", green)

    def test_scaffold_step_asserts_a_bats_artifact(self) -> None:
        scaffold = shell_text(self.steps["scaffold"])
        self.assertIn("gauntlet scaffold --from-bead", scaffold)
        # The emitted artifact's extension is what routes a bead-scoped run to
        # the bats runner, so the step has to check it rather than assume it.
        self.assertIn('!= "bats"', scaffold)


class LanePinnedToBatsTests(unittest.TestCase):
    """AC7: the loop must not reach the hurl lane."""

    def test_no_formula_step_passes_contracts_hurl(self) -> None:
        for path in formula_paths():
            text = path.read_text(encoding="utf-8")
            with self.subTest(formula=path.name):
                self.assertNotIn("--contracts=hurl", text)

    def test_every_run_local_invocation_pins_the_bats_lane(self) -> None:
        # An unpinned `run local` defaults to `all`, which does include hurl.
        seen = 0
        for path in formula_paths():
            data = tomllib.loads(path.read_text(encoding="utf-8"))
            for step_id, body in step_bodies(data).items():
                for line in shell_lines(body):
                    if "gauntlet run local" not in line:
                        continue
                    seen += 1
                    with self.subTest(formula=path.name, step=step_id):
                        self.assertIn("--contracts=bats", line)
        self.assertGreater(seen, 0, "no run local invocation found — the scan is wrong")

    def test_readme_records_the_smoke_bead(self) -> None:
        # AC7 requires the bead the end-to-end smoke ran against to be named,
        # so the claim is reproducible rather than asserted.
        readme = README.read_text(encoding="utf-8")
        self.assertRegex(readme, r"\bgaunt-8ibp\b")


class ConfigPurityTests(unittest.TestCase):
    """A published pack must be configuration-pure.

    Author-absolute host paths do not resolve in a consumer city. Mirrors the
    pr-pipeline guard (pr-pipeline/tests/test_pr_pipeline_formulas.py).
    """

    def test_no_author_absolute_paths(self) -> None:
        for path in list(formula_paths()) + [README, PACK_ROOT / "pack.toml"]:
            text = path.read_text(encoding="utf-8")
            with self.subTest(asset=path.name):
                self.assertNotIn("/home/ds", text)
                self.assertNotIn("/Users/", text)


if __name__ == "__main__":
    unittest.main()
