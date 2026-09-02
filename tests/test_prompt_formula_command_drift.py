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
import tomllib


REPO_ROOT = Path(__file__).resolve().parents[1]
THIS_FILE = Path(__file__).resolve()
AGENT_PROMPT_GLOB = "gastown/agents/*/prompt.template.md"

FENCE_OPEN = re.compile(r"^\s*```(\w*)\s*$")
FENCE_CLOSE = re.compile(r"^\s*```\s*$")

POOL_RETURN_ASSIGNEE = re.compile(r"""--assignee=(?:""|'')""")

# `gc bd list ... --search`, with no backtick in between. The backtick clause is
# what separates an invocation from the prose warning against one: a sentence
# naming the broken flag puts `gc bd list` and `--search` in two different
# inline-code spans, while a real command — fenced, or quoted whole in a
# quick-reference table cell — has nothing but arguments between them.
BD_LIST_SEARCH = re.compile(r"\bbd\s+list\b[^`\n]*--search")

# `gc bd search ... --status <value>`, with the same no-backtick-in-between
# clause as BD_LIST_SEARCH: prose naming the flag splits the verb and the flag
# across two inline-code spans, a real invocation has only arguments between
# them. The `-s` alternation is guarded so it cannot match inside `--status`.
BD_SEARCH_STATUS = re.compile(
    r"\bbd\s+search\b[^`\n]*?(?:--status|(?<![-\w])-s)[=\s]+([\w,]+)"
)

REFINERY_PATROL = Path("gastown/formulas/mol-refinery-patrol.toml")
WITNESS_PATROL = Path("gastown/formulas/mol-witness-patrol.toml")

# A git command naming `main` as a branch. The no-backtick clause is the same
# one the detectors above use to separate an invocation from prose about one.
# `origin/main` and a bare `main` argument both match; `maintenance`,
# `domain/main-thing` and the like do not.
GIT_MAIN_REF = re.compile(r"\bgit\b[^`\n]*?(?<![\w/-])(?:origin/)?main(?![\w/-])")

SCANNED_SUFFIXES = frozenset({".md", ".toml", ".sh"})


def tracked_command_assets() -> list[Path]:
    """Every tracked file in the repo that can carry an agent-facing command."""
    result = subprocess.run(
        ["git", "ls-files", "-z"],
        cwd=REPO_ROOT,
        check=True,
        capture_output=True,
    )
    paths = [REPO_ROOT / part for part in result.stdout.decode().split("\0") if part]
    return [path for path in paths if path.suffix in SCANNED_SUFFIXES]


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


def bd_list_search_violations(path: Path, text: str) -> list[str]:
    """`gc bd list` has no `--search` flag, and the failure mode is invisible.

    `gc bd list --search "<query>"` does not search weakly — it never runs.
    It exits non-zero with ``unknown flag: --search``, and piped to jq or head
    that yields empty output, which the caller correctly reads as "nothing
    matched". Every duplicate check written this way reports a clean miss.

    That is not hypothetical either: mol-refinery-patrol's handle-failures step
    prescribed exactly this before filing a pre-existing-failure bead, so the
    dedup gate had never once searched anything. It produced six open beads for
    the same seven govulncheck stdlib vulns in the winnow rig, and ~10 open
    beads for the same test_no_bare_bd_commands failure in this one.

    The verbs that actually query titles are ``gc bd search "<keyword>"`` and
    ``gc bd list --title-contains "<keyword>"``.
    """
    violations = []
    for number, command in logical_commands(text):
        if not BD_LIST_SEARCH.search(command):
            continue
        violations.append(
            f"{path.relative_to(REPO_ROOT)}:{number}: gc bd list has no --search flag "
            "(use `gc bd search` or `gc bd list --title-contains`)"
        )
    return violations


def bd_search_status_violations(path: Path, text: str) -> list[str]:
    """`gc bd search` must not filter by `--status`. Both ways of doing it lie.

    `gc bd search` already excludes closed issues — its own help says so — so
    the default result set is exactly open + in_progress. Narrowing it is never
    a widening, and both available narrowings fail invisibly:

    ``--status=open`` drops in_progress. A duplicate that someone has already
    started is still a duplicate, so the check reports zero and the caller files
    the duplicate it was written to prevent. Nothing errors; there is no
    fail-closed branch to catch it, because the command succeeded.

    ``--status=open,in_progress`` looks like the fix and is worse. The
    comma-separated form is a ``gc bd list`` feature; ``gc bd search`` returns
    ``[]`` with exit 0 for it. Measured against this rig, on beads titled
    "mol-polecat-work" (4 open, 1 in_progress)::

        gc bd search "mol-polecat-work"                          -> 5
        gc bd search "mol-polecat-work" --status=open            -> 4
        gc bd search "mol-polecat-work" --status=in_progress     -> 1
        gc bd search "mol-polecat-work" --status=open,in_progress -> 0   <-- exit 0

    A check written that way is permanently blind and undetectable at runtime,
    the same shape as the ``--search`` flag above. Note the asymmetry that makes
    this worth a detector: ``gc bd list --status=open,in_progress`` *is* correct
    and is required elsewhere (gcp-s14g), so the comma form cannot simply be
    banned repo-wide — only on ``search``.

    ``--status all`` is left alone: it is the documented way to include closed
    issues, and it widens rather than narrows.
    """
    violations = []
    for number, command in logical_commands(text):
        match = BD_SEARCH_STATUS.search(command)
        if not match:
            continue
        value = match.group(1)
        location = f"{path.relative_to(REPO_ROOT)}:{number}"
        if "," in value:
            violations.append(
                f"{location}: gc bd search --status={value} returns [] with exit 0 "
                "(comma-separated status is a gc bd list feature — drop --status)"
            )
        elif value != "all":
            violations.append(
                f"{location}: gc bd search --status={value} hides in_progress beads "
                "(search already excludes closed — drop --status)"
            )
    return violations


def hardcoded_main_ref_violations(path: Path, text: str) -> list[str]:
    """An agent-executed git command must not assume the default branch is `main`.

    Rigs do not agree on a default branch: gauntlet is `master`, winnow is
    `dev`, gascity is `edge-integration`. Against any of them a command naming
    `origin/main` does not compare against the wrong branch — the ref does not
    resolve at all, so git exits 128 and the caller reads a bare non-zero.

    That is indistinguishable from an honest negative, which is what makes it
    worth a detector rather than a review note. `mol-witness-patrol`'s
    orphan-recovery guard asked `git merge-base --is-ancestor origin/$BRANCH
    origin/main` to decide whether an orphaned bead's work had already landed.
    On every non-`main` rig that check exited 128, read as "not merged", and
    fell through to the reset path — which force-removes the worktree and runs
    `gc workflow delete-source && gc workflow reopen-source`, putting completed,
    merged work back in the pool. All four closed gauntlet beads checked at the
    time would have been misjudged this way (gcp-5ddt).

    Resolve the branch instead — `git symbolic-ref refs/remotes/origin/HEAD`,
    falling back to `git ls-remote --symref origin HEAD` — and treat an
    unresolvable result as a reason to skip, never as a negative result.
    """
    violations = []
    for lang, start, body in fenced_blocks(text):
        if lang not in {"bash", "sh", ""}:
            continue
        for offset, command in logical_commands(body):
            if not GIT_MAIN_REF.search(command):
                continue
            violations.append(
                f"{path.relative_to(REPO_ROOT)}:{start + offset - 1}: "
                f"git command hardcodes `main`:\n    {command}"
            )
    return violations


def witness_orphan_recovery_step() -> str:
    """The `recover-orphaned-beads` step description, straight from the formula."""
    with (REPO_ROOT / WITNESS_PATROL).open("rb") as handle:
        formula = tomllib.load(handle)
    steps = [
        step
        for step in formula["steps"]
        if step.get("id") == "recover-orphaned-beads"
    ]
    assert len(steps) == 1, (
        f"expected exactly one recover-orphaned-beads step in {WITNESS_PATROL}, "
        f"found {len(steps)} — the assertions below no longer cover the guard"
    )
    return steps[0]["description"]


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


def test_no_asset_queries_beads_with_bd_list_search() -> None:
    violations = []
    for path in tracked_command_assets():
        if path.resolve() == THIS_FILE:
            continue
        try:
            text = path.read_text(encoding="utf-8")
        except UnicodeDecodeError:
            continue
        violations.extend(bd_list_search_violations(path, text))

    assert not violations, (
        "a duplicate check written with --search never runs: it errors, yields "
        "empty output, and the caller files a duplicate bead believing it "
        "checked:\n" + "\n".join(violations)
    )


def test_no_asset_filters_bd_search_by_status() -> None:
    violations = []
    for path in tracked_command_assets():
        if path.resolve() == THIS_FILE:
            continue
        try:
            text = path.read_text(encoding="utf-8")
        except UnicodeDecodeError:
            continue
        violations.extend(bd_search_status_violations(path, text))

    assert not violations, (
        "gc bd search already excludes closed issues, so every --status filter "
        "on it narrows: =open drops in_progress, and the comma form returns [] "
        "with exit 0. Both are invisible at runtime:\n" + "\n".join(violations)
    )


def test_refinery_duplicate_check_sees_in_progress_bugs() -> None:
    """The dedup gate must match a duplicate someone has already started.

    This is the specific instance the detector above generalises. The refinery
    files a pre-existing-failure bead only when the check returns zero, so a
    check blind to in_progress files a duplicate every time the original is
    being worked — the exact pile-up the fail-closed block was built to stop.
    """
    path = REPO_ROOT / REFINERY_PATROL
    text = path.read_text(encoding="utf-8")
    checks = [
        (number, command)
        for number, command in logical_commands(text)
        if "gc bd search" in command
        and "DUP_KEYWORD" in command
        and "--json" in command
    ]

    assert len(checks) == 1, (
        f"expected exactly one duplicate-check invocation in {REFINERY_PATROL}, "
        f"found {len(checks)} — the assertions below no longer cover the gate"
    )
    number, command = checks[0]
    assert not bd_search_status_violations(path, command), (
        f"{REFINERY_PATROL}:{number}: the duplicate check filters by --status, "
        "so an in_progress duplicate is invisible and the refinery files a "
        f"second bead for it:\n    {command}"
    )


def test_witness_orphan_recovery_resolves_the_rigs_default_branch() -> None:
    """The already-merged guard must compare against the rig's real default.

    This guard is the one thing standing between a crashed polecat's finished
    work and a re-dispatch, and its error path is the destructive one: anything
    it cannot prove merged goes back to the pool. So it has to resolve the
    branch rather than name one, and it has to skip the bead when it cannot.
    """
    step = witness_orphan_recovery_step()

    assert not hardcoded_main_ref_violations(REPO_ROOT / WITNESS_PATROL, step), (
        "orphan recovery must not name `main`: on a master/dev/edge-integration "
        "rig the ref does not resolve, git exits 128, and 'not merged' sends "
        "already-merged work back to the pool:\n"
        + "\n".join(hardcoded_main_ref_violations(REPO_ROOT / WITNESS_PATROL, step))
    )

    assert "git symbolic-ref --quiet refs/remotes/origin/HEAD" in step, (
        "orphan recovery must resolve the default branch from origin/HEAD"
    )
    assert "git ls-remote --symref origin HEAD" in step, (
        "origin/HEAD is unset in a worktree cut with --detach — orphan recovery "
        "needs the remote fallback, or it fails closed on healthy rigs"
    )
    assert (
        'git merge-base --is-ancestor "origin/$BRANCH" "origin/$DEFAULT_BRANCH"'
        in step
    ), "the already-merged check must compare the branch against the resolved default"

    # Fail closed: an unresolvable default branch skips the bead rather than
    # falling through to the reset. `git merge-base --is-ancestor` exits 1 for
    # "not an ancestor" and 128 for "no such ref", so the guard cannot tell an
    # unresolvable ref from a real negative once it reaches the comparison.
    assert 'git rev-parse --verify --quiet "origin/$DEFAULT_BRANCH"' in step, (
        "verify the resolved default branch before comparing against it"
    )
    assert "FAIL CLOSED" in step, (
        "an unresolvable default branch must skip recovery, not reset the bead"
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

    assert hardcoded_main_ref_violations(
        fixture,
        "```bash\ngit merge-base --is-ancestor origin/$BRANCH origin/main\n```",
    )
    assert hardcoded_main_ref_violations(fixture, "```bash\ngit log main --oneline\n```")
    assert hardcoded_main_ref_violations(
        fixture, "```bash\ngit log origin/main..HEAD --oneline\n```"
    )
    # The resolved form is what the detector is steering toward.
    assert not hardcoded_main_ref_violations(
        fixture,
        '```bash\ngit merge-base --is-ancestor "origin/$BRANCH" "origin/$DEFAULT_BRANCH"\n```',
    )
    # Only fenced shell is scanned, so prose explaining the bug — which every
    # fix for it has to write — is not itself a violation.
    assert not hardcoded_main_ref_violations(
        fixture, "Never run `git merge-base --is-ancestor origin/$BRANCH origin/main`."
    )
    # A branch whose name merely starts with "main" is not the default branch.
    assert not hardcoded_main_ref_violations(
        fixture, "```bash\ngit checkout maintenance-1.x\n```"
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

    # Built line-by-line for the same reason as the warrant fixtures above: a
    # literal backslash-n immediately before `gc` reads as a bare `bd`
    # invocation to tests/test_no_bare_bd_commands.py's line-based scanner.
    assert bd_list_search_violations(
        fixture, 'gc bd list --type=bug --status=open --search "<failure summary>"'
    )
    # Continuation-joined, the form a formula is most likely to grow into.
    assert bd_list_search_violations(
        fixture,
        "\n".join(
            [
                "gc bd list \\",
                "  --type=bug \\",
                '  --search "govulncheck"',
            ]
        ),
    )
    # The two verbs that actually query titles.
    assert not bd_list_search_violations(
        fixture, 'gc bd search "govulncheck" --type=bug --status=open --json'
    )
    assert not bd_list_search_violations(
        fixture, 'gc bd list --status=open --title-contains "govulncheck"'
    )
    # `gh` genuinely has --search; only the beads CLI is being constrained.
    assert not bd_list_search_violations(
        fixture, 'gh issue list --repo gastownhall/gascity --search "<keywords>"'
    )
    # A quick-reference table cell quotes the whole command, so it is caught...
    assert bd_list_search_violations(
        fixture, '| Dedup check | `gc bd list --type=bug --search "<summary>"` |'
    )
    # ...but prose warning against the flag names the two halves in separate
    # inline-code spans, and must stay writable.
    assert not bd_list_search_violations(
        fixture, "`gc bd list` has no `--search` flag; use `gc bd search` instead."
    )

    # Narrowing a search to open hides the in_progress duplicate...
    assert bd_search_status_violations(
        fixture, 'gc bd search "$DUP_KEYWORD" --type=bug --status=open --json'
    )
    # ...and the comma form that looks like the fix returns [] with exit 0.
    assert bd_search_status_violations(
        fixture,
        'gc bd search "$DUP_KEYWORD" --type=bug --status=open,in_progress --json',
    )
    # Both spellings of the flag, including the short form.
    assert bd_search_status_violations(fixture, 'gc bd search "x" --status open')
    assert bd_search_status_violations(fixture, 'gc bd search "x" -s open,in_progress')
    # Continuation-joined, the form a formula is most likely to grow into.
    assert bd_search_status_violations(
        fixture,
        "\n".join(
            [
                'gc bd search "$DUP_KEYWORD" \\',
                "  --type=bug \\",
                "  --status=open \\",
                "  --json",
            ]
        ),
    )
    # The fix: no --status at all. Search already excludes closed issues.
    assert not bd_search_status_violations(
        fixture, 'gc bd search "$DUP_KEYWORD" --type=bug --json'
    )
    # `--status all` widens to include closed and is the documented way to do
    # it, so it is not a narrowing and stays writable.
    assert not bd_search_status_violations(fixture, 'gc bd search "x" --status all')
    assert not bd_search_status_violations(fixture, 'gc bd search "x" --status=all')
    # The asymmetry this detector exists to preserve: the comma form is correct
    # on `gc bd list` (gcp-s14g requires it) and broken only on `gc bd search`.
    assert not bd_search_status_violations(
        fixture,
        'gc bd list --assignee="$GC_AGENT" --status=open,in_progress --json',
    )
    # Prose naming the flag splits verb and flag across inline-code spans.
    assert not bd_search_status_violations(
        fixture,
        "`gc bd search` takes no useful `--status=open` filter; drop the flag.",
    )
