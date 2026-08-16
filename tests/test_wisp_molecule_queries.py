"""Guard: every shipped wisp query passes --include-infra and covers both live statuses.

Patrol wisp roots (`gc bd mol wisp ... --root-only`) are ephemeral beads that
live in the wisps table. `gc bd list` sets `SkipWisps` whenever `--include-infra`
is absent and the requested `--type` is not a configured infra type; `molecule`
never is, so a `--type=molecule` query without `--include-infra` silently
returns zero rows instead of erroring.

That silence is the whole bug class this guard exists for: the agent reads
"no wisps" as "nothing to reconcile", pours a fresh wisp, and never burns the
prior one — witness, refinery, and deacon each leak one wisp per patrol cycle,
with no failure signal anywhere. The queries are prose in prompt templates and
formula TOML, so nothing else type-checks them.

The status filter is the second, independently-sufficient facet of the same bug
(gcp-ah8h). A live patrol wisp is `open` OR `in_progress`: wisps are poured
`open` and nothing transitions them, so an `--status=in_progress` resolver
matches nothing on a normal cycle. `CURRENT_WISP` then comes back empty, the
surplus exclusion `select(.id != $cur)` excludes nothing, the wisp being
executed lands in its own surplus set, and the loop stops advancing — again with
every command exiting 0. gcp-xbl fixed `--include-infra` at every site and left
this facet unfixed at every site, which is precisely why the manual re-grep it
relied on is replaced here by a test.
"""

from __future__ import annotations

from pathlib import Path
import re
import subprocess


REPO_ROOT = Path(__file__).resolve().parents[1]
THIS_FILE = Path(__file__).resolve()

# patches/ is the derived `git format-patch BASELINE..HEAD` export (see
# docs/fork-patches.md). Its diff hunks quote the pre-image of every line a fork
# commit changed, so a commit that FIXES a query here would ship a patch file
# still containing the broken form. Skipping it loses no coverage: the shipped
# post-image of that same content is scanned directly.
DERIVED_PREFIXES = ("patches/",)

# Match the flag form only (`--type=molecule` / `--type molecule`), never the
# prose spelling `issue_type=molecule` that documents what a wisp root is.
MOLECULE_TYPE_FLAG = re.compile(r"(?<!issue_type)(?<!\w)--type[= ]molecule\b")
INCLUDE_INFRA_FLAG = "--include-infra"
STATUS_FLAG = re.compile(r"--status[= ]([a-z_,]+)")
LIMIT_FLAG = re.compile(r"--limit[= ](\d+)")
# Shell continuations split a single command over several source lines; join
# them before checking so a flag on the continuation line still counts.
LINE_CONTINUATION = re.compile(r"\\\r?\n[ \t]*")


def tracked_files() -> list[Path]:
    result = subprocess.run(
        ["git", "ls-files", "-z"],
        cwd=REPO_ROOT,
        check=True,
        capture_output=True,
    )
    return [
        REPO_ROOT / path
        for path in result.stdout.decode().split("\0")
        if path and not path.startswith(DERIVED_PREFIXES)
    ]


def molecule_query_violations(path: Path, text: str) -> list[str]:
    violations = []
    relative = path.relative_to(REPO_ROOT) if path.is_absolute() else path
    joined = LINE_CONTINUATION.sub(" ", text)
    for line_number, line in enumerate(joined.splitlines(), start=1):
        if MOLECULE_TYPE_FLAG.search(line) and INCLUDE_INFRA_FLAG not in line:
            violations.append(f"{relative}:{line_number}: {line.strip()}")
    return violations


def _statuses(line: str) -> set[str]:
    match = STATUS_FLAG.search(line)
    return set(match.group(1).split(",")) if match else set()


def live_wisp_status_violations(path: Path, text: str) -> list[str]:
    """Flag molecule queries that resolve a live wisp from the wrong row set.

    Two shapes are wrong, and both fail silently rather than erroring:

    * `--status=in_progress` alone — matches no wisp on a normal cycle, because
      wisps are poured `open` and nothing transitions them.
    * `--status=open,in_progress --limit=1` — server-side truncation can return
      a different row than the unlimited sibling query that computes the surplus
      set, so `select(.id != $cur)` fails to exclude the wisp being executed.

    The witness startup protocol deliberately unions two adjacent queries
    (`--status=in_progress` then `--status=open`) to express an in_progress-first
    preference the single-query form cannot. That idiom is recognised here by
    adjacency, so it is not flagged and does not need a magic comment.
    """
    violations = []
    relative = path.relative_to(REPO_ROOT) if path.is_absolute() else path
    lines = LINE_CONTINUATION.sub(" ", text).splitlines()
    molecule = [bool(MOLECULE_TYPE_FLAG.search(line)) for line in lines]

    for index, line in enumerate(lines):
        if not molecule[index]:
            continue
        statuses = _statuses(line)
        if "in_progress" not in statuses:
            continue  # not a live-wisp resolver (e.g. --status=closed)

        if "open" not in statuses:
            neighbours = (index - 1, index + 1)
            unioned = any(
                0 <= n < len(lines) and molecule[n] and "open" in _statuses(lines[n])
                for n in neighbours
            )
            if not unioned:
                violations.append(
                    f"{relative}:{index + 1}: --status must cover open,in_progress: {line.strip()}"
                )
            continue

        limit = LIMIT_FLAG.search(line)
        if limit and limit.group(1) != "0":
            violations.append(
                f"{relative}:{index + 1}: live-wisp query must use --limit=0: {line.strip()}"
            )
    return violations


def test_shipped_molecule_queries_include_infra() -> None:
    violations = []
    for path in tracked_files():
        if path.resolve() == THIS_FILE:
            continue
        try:
            text = path.read_text(encoding="utf-8")
        except UnicodeDecodeError:
            continue
        violations.extend(molecule_query_violations(path, text))

    assert not violations, (
        "wisp queries without --include-infra silently return zero rows:\n"
        + "\n".join(violations)
    )


def test_shipped_live_wisp_queries_cover_open_and_in_progress() -> None:
    violations = []
    for path in tracked_files():
        if path.resolve() == THIS_FILE:
            continue
        try:
            text = path.read_text(encoding="utf-8")
        except UnicodeDecodeError:
            continue
        violations.extend(live_wisp_status_violations(path, text))

    assert not violations, (
        "live-wisp queries that cannot see the wisp they are running:\n"
        + "\n".join(violations)
    )


def test_live_wisp_detector_flags_the_gcp_ah8h_shape() -> None:
    fixture = Path("fixture.txt")
    broken = (
        'gc bd list --assignee="$GC_AGENT" --status=in_progress --type=molecule '
        "--include-infra --limit=1 --json"
    )
    fixed = (
        'gc bd list --assignee="$GC_AGENT" --status=open,in_progress --type=molecule '
        "--include-infra --limit=0 --json"
    )

    assert live_wisp_status_violations(fixture, broken)
    assert not live_wisp_status_violations(fixture, fixed)

    # Truncating a live-wisp query desynchronises it from the surplus query.
    assert live_wisp_status_violations(
        fixture,
        'gc bd list --status=open,in_progress --type=molecule --include-infra --limit=1 --json',
    )

    # A closed-wisp lookup is a different question and stays untouched.
    assert not live_wisp_status_violations(
        fixture, "gc bd list --type=molecule --include-infra --status=closed --limit=5"
    )

    # The witness startup protocol's deliberate two-query union.
    assert not live_wisp_status_violations(fixture, f"{broken}\n{fixed.replace('open,in_progress', 'open')}")

    # Prose describing wisp roots carries no status filter.
    assert not live_wisp_status_violations(
        fixture, "Wisp roots are `issue_type=molecule` and live in the wisps table."
    )


def test_detector_covers_flag_forms_and_prose() -> None:
    fixture = Path("fixture.txt")

    assert molecule_query_violations(fixture, "gc bd list --type=molecule --limit=0")
    assert molecule_query_violations(fixture, "gc bd list --type molecule --limit=0")
    assert molecule_query_violations(
        fixture, "gc bd list --type=molecule \\\n  --status=open --json"
    )
    assert not molecule_query_violations(
        fixture, "gc bd list --type=molecule --include-infra --limit=0"
    )
    assert not molecule_query_violations(
        fixture, "gc bd list --type=molecule \\\n  --include-infra --json"
    )
    # Prose describing wisp roots is not a query.
    assert not molecule_query_violations(fixture, "Wisp roots are `issue_type=molecule`.")
