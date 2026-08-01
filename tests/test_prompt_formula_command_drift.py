"""Guards against role-prompt / formula command drift.

A role prompt template is injected into an agent's context at spawn and reads as
authoritative operating instructions. A formula step has to be opened
deliberately. When a template restates a formula-owned command and silently
drops a flag, the agent runs the lossy copy: it executes cleanly, reports
success, and the dropped behaviour is simply gone.

That is not hypothetical. A refinery rejection followed the role prompt's
condensed "Rejection Flow", which restated the formula's pool-return
`gc bd update` without `--set-metadata gc.routed_to=...`. Nothing spawns for a
bead with no routing, so the rejected bead sat open and unassigned forever while
every status surface stayed green — and an unassigned pool bead is
indistinguishable by inspection from a healthy one.

These checks encode the invariants that were lost, so the drift cannot silently
reappear the next time a formula is edited. The convention the templates follow
is documented in ``gastown/README.md`` ("Role prompts point at formulas").
"""

from __future__ import annotations

from pathlib import Path
import re
import subprocess


REPO_ROOT = Path(__file__).resolve().parents[1]
AGENT_PROMPT_GLOB = "gastown/agents/*/prompt.template.md"

FENCE_OPEN = re.compile(r"^\s*```(\w*)\s*$")
FENCE_CLOSE = re.compile(r"^\s*```\s*$")

POOL_RETURN_ASSIGNEE = re.compile(r"""--assignee=(?:""|'')""")


def gastown_assets() -> list[Path]:
    """Every tracked pack asset that can carry an agent-facing command."""
    result = subprocess.run(
        ["git", "ls-files", "-z", "gastown"],
        cwd=REPO_ROOT,
        check=True,
        capture_output=True,
    )
    paths = [REPO_ROOT / part for part in result.stdout.decode().split("\0") if part]
    return [path for path in paths if path.suffix in {".md", ".toml", ".sh"}]


def agent_prompts() -> list[Path]:
    prompts = sorted(REPO_ROOT.glob(AGENT_PROMPT_GLOB))
    assert prompts, "no role prompt templates found — glob is wrong"
    return prompts


def logical_commands(text: str) -> list[tuple[int, str]]:
    """Yield (start line number, command) with backslash continuations joined.

    Formula and prompt commands are routinely spread over several lines with
    trailing backslashes; a per-line scan would see `--status=open` and the
    `gc.routed_to` flag as unrelated lines and miss the pairing entirely.
    """
    commands: list[tuple[int, str]] = []
    pending: list[str] = []
    start = 0
    for number, raw in enumerate(text.split("\n"), start=1):
        if not pending:
            start = number
        stripped = raw.rstrip()
        if stripped.endswith("\\"):
            pending.append(stripped[:-1].strip())
            continue
        pending.append(stripped.strip())
        commands.append((start, " ".join(part for part in pending if part)))
        pending = []
    if pending:
        commands.append((start, " ".join(part for part in pending if part)))
    return commands


def fenced_blocks(text: str) -> list[tuple[str, int, str]]:
    """Return (language, first body line number, body) for each fenced block."""
    lines = text.split("\n")
    blocks: list[tuple[str, int, str]] = []
    index = 0
    while index < len(lines):
        opener = FENCE_OPEN.match(lines[index])
        if not opener:
            index += 1
            continue
        start = index + 1
        end = start
        while end < len(lines) and not FENCE_CLOSE.match(lines[end]):
            end += 1
        blocks.append((opener.group(1), start + 1, "\n".join(lines[start:end])))
        index = end + 1
    return blocks


def pool_return_violations(path: Path, text: str) -> list[str]:
    """Pool-returning updates must state where the bead is routed next."""
    violations = []
    for number, command in logical_commands(text):
        if "gc bd update" not in command:
            continue
        if "--status=open" not in command:
            continue
        if not POOL_RETURN_ASSIGNEE.search(command):
            continue
        if "gc.routed_to" in command:
            continue
        violations.append(
            f"{path.relative_to(REPO_ROOT)}:{number}: returns a bead to the pool without gc.routed_to"
        )
    return violations


def warrant_dedup_violations(path: Path, text: str) -> list[str]:
    """Warrant creation in injected context must carry the dedup guard.

    Every formula that files a warrant first checks for an open warrant against
    the same target — a duplicate spawns a second shutdown dance racing the
    first. A prompt template that restates the create without the guard hands
    the agent a command that looks complete and is not. Templates should point
    at the owning formula step instead; where a role has no formula to point at
    (boot), the inline command has to carry the guard itself.
    """
    violations = []
    guarded = {
        number
        for _lang, start, body in fenced_blocks(text)
        if "EXISTING_WARRANT" in body
        for number in range(start, start + body.count("\n") + 1)
    }
    for number, command in logical_commands(text):
        if "gc bd create" not in command or "--label=warrant" not in command:
            continue
        if number in guarded:
            continue
        violations.append(
            f"{path.relative_to(REPO_ROOT)}:{number}: warrant creation restated without the dedup guard"
        )
    return violations


def bail_without_drain_violations(path: Path, text: str) -> list[str]:
    """A prompt block that gives up must drain-ack, as the formula does.

    `exit 1` without `gc runtime drain-ack` leaves the reconciler believing the
    session is still live, so it is never recycled. Every formula bail-out path
    acks first; a prompt copy that drops the ack is the same lossy-restatement
    class as the missing routing flag.
    """
    violations = []
    for lang, start, body in fenced_blocks(text):
        if lang not in {"bash", "sh", ""}:
            continue
        if "exit 1" not in body:
            continue
        if "gc runtime drain-ack" in body:
            continue
        violations.append(
            f"{path.relative_to(REPO_ROOT)}:{start}: bash block exits 1 without gc runtime drain-ack"
        )
    return violations


def test_pool_returning_updates_declare_routing() -> None:
    violations = []
    for path in gastown_assets():
        violations.extend(pool_return_violations(path, path.read_text(encoding="utf-8")))

    assert not violations, (
        "a bead returned to the pool without gc.routed_to is silently orphaned "
        "— nothing spawns for it and every status surface stays green:\n"
        + "\n".join(violations)
    )


def test_prompt_templates_do_not_restate_warrant_creation_unguarded() -> None:
    violations = []
    for path in agent_prompts():
        violations.extend(
            warrant_dedup_violations(path, path.read_text(encoding="utf-8"))
        )

    assert not violations, (
        "point at the owning formula step instead of restating the warrant "
        "command, or carry the dedup guard inline:\n" + "\n".join(violations)
    )


def test_prompt_template_bail_paths_drain_ack() -> None:
    violations = []
    for path in agent_prompts():
        violations.extend(
            bail_without_drain_violations(path, path.read_text(encoding="utf-8"))
        )

    assert not violations, (
        "a session that exits without drain-ack is never recycled:\n"
        + "\n".join(violations)
    )


def test_detectors_catch_the_drift_they_are_named_for() -> None:
    fixture = REPO_ROOT / "fixture.md"

    lossy_reject = 'gc bd update $WORK --status=open --assignee="" --set-metadata rejection_reason="..."'
    assert pool_return_violations(fixture, lossy_reject)
    assert pool_return_violations(
        fixture,
        'gc bd update $WORK \\\n  --status=open \\\n  --assignee="" \\\n'
        '  --set-metadata rejection_reason="..."',
    )
    assert not pool_return_violations(
        fixture,
        'gc bd update $WORK \\\n  --status=open \\\n  --assignee="" \\\n'
        '  --set-metadata gc.routed_to="$RIG/gastown.polecat"',
    )
    # Handing a bead to a named assignee is not a pool return.
    assert not pool_return_violations(
        fixture, 'gc bd update $WORK --status=open --assignee="$REFINERY_TARGET"'
    )

    # Built line-by-line rather than with embedded "\n" escapes: a literal
    # backslash-n immediately before `gc` reads as a bare `bd` invocation to
    # tests/test_no_bare_bd_commands.py, whose gc-prefix check is line-based.
    unguarded_warrant = "\n".join(
        [
            "```bash",
            "gc bd create --type=task --label=warrant --metadata '{\"target\":\"x\"}'",
            "```",
        ]
    )
    assert warrant_dedup_violations(fixture, unguarded_warrant)
    guarded_warrant = "\n".join(
        [
            "```bash",
            "EXISTING_WARRANT=$(gc bd list --label=warrant --json)",
            'if [ "$EXISTING_WARRANT" -gt 0 ]; then',
            "  echo skip",
            "else",
            "  gc bd create --type=task --label=warrant --metadata '{\"target\":\"x\"}'",
            "fi",
            "```",
        ]
    )
    assert not warrant_dedup_violations(fixture, guarded_warrant)
    # A quick-reference table row is outside any fenced block, so it can never
    # carry the guard — it has to point at the formula instead.
    assert warrant_dedup_violations(
        fixture, "| File warrant | `gc bd create --type=task --label=warrant ...` |"
    )

    assert bail_without_drain_violations(fixture, "```bash\necho no\nexit 1\n```")
    assert not bail_without_drain_violations(
        fixture, "```bash\necho no\ngc runtime drain-ack\nexit 1\n```"
    )
