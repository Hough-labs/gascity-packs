"""Guard: every shipped wisp query passes --include-infra.

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
