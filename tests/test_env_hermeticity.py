"""Guard: the pack test suites must be insensitive to agent-session environment.

Every gastown agent exports a live ``GC_*``/``BEADS_*`` namespace. Test modules
that build a subprocess environment from ``{**os.environ, ...}`` -- or that
snapshot, mutate and restore ``os.environ`` in ``setUp`` without clearing it --
inherit that namespace, so the same tree passes on a CI runner (which sets none
of it) and fails for every polecat running the suite as a local quality gate.

That asymmetry is expensive precisely because it does not look like an
environment bug: seven tests failed that way and four beads were filed against
the phantom before the cause was found (gcp-9ur). Fixing the two variables that
happened to surface it would leave the class intact, so this guard runs the
affected modules twice as subprocesses -- once with a representative agent
session injected, once with the namespace stripped -- and asserts the per-test
outcomes are identical. Any new leak in a guarded module turns it red.
"""

from __future__ import annotations

import os
import pathlib
import subprocess
import sys
import tempfile
import unittest
import xml.etree.ElementTree as ElementTree


REPO_ROOT = pathlib.Path(__file__).resolve().parents[1]

# Modules that drive scripts reading the GC_* namespace. Listing a module here
# costs one extra run of it; leaving one out means its isolation is unguarded.
GUARDED_MODULES = (
    "gascity/tests/test_formula_assets.py",
    "discord/tests/test_discord_intake_service.py",
    "github/tests/test_github_intake_service.py",
)

AMBIENT_PREFIXES = ("GC_", "BEADS_")

# A representative gastown agent session. Values are synthetic so the guard
# behaves identically on a CI runner and inside a live session, and the set is
# deliberately wider than the two names that produced the original failures --
# GC_BIN (six of them) and GC_TEMPLATE (one) -- so it detects the class.
AGENT_SESSION_ENV = {
    "BEADS_ACTOR": "guard__polecat-gc-0000",
    "BEADS_DIR": "/nonexistent/guard/.beads",
    "BEADS_ROUTING_MODE": "off",
    "GC_AGENT": "guard-rig/gastown.guard",
    "GC_ALIAS": "guard-rig/gastown.guard",
    "GC_BEADS": "bd",
    "GC_BIN": "/nonexistent/guard/bin/gc",
    "GC_CITY": "/nonexistent/guard/city",
    "GC_DIR": "/nonexistent/guard/worktree",
    "GC_HOME": "/nonexistent/guard/home",
    "GC_PROVIDER": "claude",
    "GC_RIG": "guard-rig",
    "GC_SESSION_ID": "gc-0000",
    "GC_SESSION_NAME": "guard__polecat-gc-0000",
    "GC_TEMPLATE": "guard-rig/gastown.polecat",
}


def ambient_free_environ() -> dict[str, str]:
    """This process's environment with the whole agent-session namespace removed."""

    return {
        key: value
        for key, value in os.environ.items()
        if not key.startswith(AMBIENT_PREFIXES)
    }


def outcome_of(testcase: ElementTree.Element) -> str:
    """Map a JUnit ``testcase`` element to a single outcome word."""

    for tag in ("error", "failure", "skipped"):
        if testcase.find(tag) is not None:
            return tag
    return "passed"


def run_guarded_modules(
    env: dict[str, str], *, selector: str | None = None
) -> dict[str, str]:
    """Run the guarded modules under ``env`` and return {test id: outcome}."""

    selection = ["-k", selector] if selector else []
    with tempfile.TemporaryDirectory() as tmp:
        report = pathlib.Path(tmp, "report.xml")
        completed = subprocess.run(
            [
                sys.executable,
                "-m",
                "pytest",
                *GUARDED_MODULES,
                *selection,
                "-q",
                "--tb=no",
                "-p",
                "no:cacheprovider",
                f"--junit-xml={report}",
            ],
            cwd=REPO_ROOT,
            env=env,
            capture_output=True,
            text=True,
            timeout=900,
        )
        if not report.is_file():
            raise AssertionError(
                "pytest produced no JUnit report; it likely failed to collect.\n"
                f"stdout:\n{completed.stdout}\nstderr:\n{completed.stderr}"
            )
        root = ElementTree.parse(report).getroot()

    return {
        f"{case.get('classname')}::{case.get('name')}": outcome_of(case)
        for case in root.iter("testcase")
    }


def divergent_outcomes(
    env: dict[str, str], *, selector: str | None = None
) -> tuple[dict[str, str], dict[str, str], dict[str, tuple[str, str]]]:
    """Compare a clean run against an agent-session run of the same selection."""

    clean = run_guarded_modules(env, selector=selector)
    with_session = run_guarded_modules(
        {**env, **AGENT_SESSION_ENV}, selector=selector
    )
    divergent = {
        test_id: (clean[test_id], with_session[test_id])
        for test_id in clean.keys() & with_session.keys()
        if clean[test_id] != with_session[test_id]
    }
    return clean, with_session, divergent


def method_name(test_id: str) -> str:
    """The bare method name from a ``classname::name`` JUnit id."""

    return test_id.rpartition("::")[2]


class EnvironmentHermeticityTests(unittest.TestCase):
    maxDiff = None

    def test_guarded_modules_ignore_agent_session_environment(self) -> None:
        base = ambient_free_environ()

        clean, with_session, divergent = divergent_outcomes(base)

        self.assertTrue(clean, "the clean run collected no tests")
        # Collection is settled before any test runs, so unlike an outcome this
        # cannot be a load flake: a difference here means the environment
        # decided which tests exist at all.
        self.assertEqual(
            sorted(clean),
            sorted(with_session),
            "the two runs collected different tests",
        )

        if divergent:
            # Env sensitivity is deterministic; a couple of the guarded tests
            # bound a subprocess at two seconds and time out when the machine is
            # loaded -- and a whole-module run under this guard is exactly that.
            # Re-run only the candidates, where they are not competing with 80
            # other tests, and keep the ones that still diverge. Without this a
            # load flake reports as an isolation regression, which is the same
            # false signal this guard exists to prevent.
            confirmable = sorted(
                {
                    name
                    for name in map(method_name, divergent)
                    if name.isidentifier()
                }
            )
            unconfirmable = {
                test_id: outcomes
                for test_id, outcomes in divergent.items()
                if not method_name(test_id).isidentifier()
            }
            reconfirmed: dict[str, tuple[str, str]] = {}
            if confirmable:
                _, _, reconfirmed = divergent_outcomes(
                    base, selector=" or ".join(confirmable)
                )
            divergent = {
                test_id: outcomes
                for test_id, outcomes in divergent.items()
                if test_id in reconfirmed
            }
            divergent.update(unconfirmable)

        self.assertEqual(
            divergent,
            {},
            "these tests changed outcome when an agent session's environment was "
            "present, so they inherit os.environ instead of building an explicit "
            "one (clean outcome, agent-session outcome shown):\n"
            + "\n".join(
                f"  {test_id}: {before} -> {after}"
                for test_id, (before, after) in sorted(divergent.items())
            ),
        )


if __name__ == "__main__":
    unittest.main()
