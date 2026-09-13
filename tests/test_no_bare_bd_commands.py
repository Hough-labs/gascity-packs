from __future__ import annotations

import ast
from pathlib import Path
import re
import shlex
import subprocess


REPO_ROOT = Path(__file__).resolve().parents[1]
THIS_FILE = Path(__file__).resolve()

BD_SUBCOMMANDS = (
    "admin",
    "ado",
    "assign",
    "audit",
    "backup",
    "batch",
    "blocked",
    "bootstrap",
    "branch",
    "children",
    "close",
    "comment",
    "comments",
    "compact",
    "completion",
    "config",
    "context",
    "cook",
    "count",
    "create",
    "create-form",
    "defer",
    "delete",
    "dep",
    "diff",
    "doctor",
    "dolt",
    "duplicate",
    "duplicates",
    "edit",
    "epic",
    "export",
    "federation",
    "find-duplicates",
    "flatten",
    "forget",
    "formula",
    "gate",
    "gc",
    "github",
    "gitlab",
    "graph",
    "heartbeat",
    "help",
    "history",
    "hooks",
    "human",
    "import",
    "info",
    "init",
    "init-safety",
    "jira",
    "kv",
    "label",
    "linear",
    "link",
    "list",
    "lint",
    "mail",
    "memories",
    "merge-slot",
    "meta",
    "metrics",
    "migrate",
    "migrate-personal",
    "mol",
    "note",
    "notion",
    "onboard",
    "orphans",
    "ping",
    "preflight",
    "prime",
    "priority",
    "promote",
    "prune",
    "purge",
    "q",
    "query",
    "quickstart",
    "ready",
    "recall",
    "reclaim",
    "recompute-blocked",
    "remember",
    "rename-prefix",
    "rename",
    "reopen",
    "repo",
    "restore",
    "rules",
    "search",
    "set-state",
    "setup",
    "show",
    "ship",
    "sql",
    "stale",
    "state",
    "status",
    "statuses",
    "supersede",
    "swarm",
    "sync",
    "tag",
    "todo",
    "type",
    "types",
    "unclaim",
    "undefer",
    "update",
    "upgrade",
    "vc",
    "version",
    "where",
    "worktree",
)
BD_SUBCOMMAND_PATTERN = "|".join(re.escape(command) for command in BD_SUBCOMMANDS)
BARE_BD_COMMAND = re.compile(rf"\bbd[ \t]+(?:{BD_SUBCOMMAND_PATTERN})\b")
BARE_BD_LEADING_FLAG = re.compile(r"\bbd[ \t]+-{1,2}[A-Za-z]")
BARE_BD_DYNAMIC_COMMAND = re.compile(r'''\bbd[ \t]+(?:["']?\$\{?[A-Za-z_]|\$\()''')
MULTILINE_BARE_BD_COMMAND = re.compile(
    rf"\bbd[ \t]*\r?\n[ \t]*(?:{BD_SUBCOMMAND_PATTERN})\b"
)
BARE_BD_GO_EXEC = re.compile(
    r'(?:exec\.Command(?:Context)?|dispatchExecCommand)\(\s*["\']bd["\']'
)
BARE_BD_PATH_CHECK = re.compile(r"\bcommand[ \t]+-v[ \t]+bd\b")
BARE_BD_SERIALIZED_ARGV = re.compile(
    rf'''(?:\[|\{{|=|:)\s*["']bd["']\s*,\s*["'](?:{BD_SUBCOMMAND_PATTERN})["']'''
)
# patches/ is the derived `git format-patch BASELINE..HEAD` export (see
# docs/fork-patches.md). Its diff hunks quote the pre-image of every line a fork
# commit changed, so a commit that REPLACES a bare `bd` call would ship a patch
# file still containing it. Skipping it loses no coverage: the shipped
# post-image of that same content is scanned directly.
DERIVED_PREFIXES = ("patches/",)
GC_BD_ARGV_TAIL_MARKER = "gc-bd-argv-tail"
# Lines that name a `bd` subcommand as DATA rather than invoking one: a fake
# `gc`'s case labels matching the wrapper's argv tail, an assertion on the tail
# it recorded, a failure message, and prose describing what a stub models.
# Every entry stays triple-locked -- an exact tracked path, the literal marker
# on the line, and an exact-line match -- so editing an exempted line re-fires
# the guard and a human re-confirms the line is still data. That is deliberate:
# excluding a content class instead (comments, quoted strings) would blind the
# guard to genuine invocation sites such as `eval "bd show ..."`.
GC_BD_ARGV_TAIL_ALLOWLIST: dict[Path, set[str]] = {
    Path("tests/test_gascity_pack_inference_gate.py"): {
        '*"bd show fi-root --json"*) # gc-bd-argv-tail: fake gc receives the wrapper\'s argv tail',
        '*"bd list --json --limit 1000"*) # gc-bd-argv-tail: fake gc receives the wrapper\'s argv tail',
        'assert "bd show fi-root --json" in args_path.read_text(encoding="utf-8")  # gc-bd-argv-tail',
    },
    Path("gastown/tests/test_merge_approval_gate.sh"): {
        '"bd show") # gc-bd-argv-tail: case label matching the fake gc\'s argv tail',
        '"bd update") # gc-bd-argv-tail: case label matching the fake gc\'s argv tail',
        'fail "producer must write the whole signal in a single bd update"'
        " # gc-bd-argv-tail: failure message, not an invocation",
    },
    Path("gastown/tests/test_polecat_live_owner_guard.sh"): {
        '"bd show") # gc-bd-argv-tail: case label matching the fake gc\'s argv tail',
        '"bd update") exit "${GC_UPDATE_EXIT:-0}" ;;'
        " # gc-bd-argv-tail: case label matching the fake gc's argv tail",
        "restore_call='bd update winnow-iaroy --assignee=gastown__polecat-gc-8a4d'"
        " # gc-bd-argv-tail: expected argv tail, not an invocation",
    },
    Path("gastown/tests/test_refinery_find_work.sh"): {
        "# Stub `gc` implementing just enough of `bd list` to answer the shipped"
        " query. # gc-bd-argv-tail: prose, not an invocation",
        "# `bd list` hides closed issues unless asked."
        " # gc-bd-argv-tail: prose, not an invocation",
    },
}


PINNED_STORE_BD_MARKER = "bd-pinned-store"
# The ONE shape of `bd` invocation this guard permits, and only at the exact
# lines named below.
#
# The rule this guard enforces is really about ROUTING, not about the binary: a
# pack asset must never read whichever store it happens to be standing in. A
# `bd -C <explicitly resolved rig root>` call does not do that -- `-C` pins the
# project to a named directory and FAILS CLOSED ("no beads project found",
# exit 1) rather than walking up to $PWD, which is the CWD resolution the guard
# exists to stop. `bd --dir /tmp/rig` stays a violation and is asserted as one
# below: an exemption that keyed on "has a directory flag" would let any path in,
# including one composed from ambient state.
#
# Why it is allowed HERE and nowhere else: polecat-worktree-reap.sh runs as the
# witness pre_start inside an 8s self-budget, and the `gc` wrapper costs ~2.4x
# the pinned call for the identical answer (~5x on a rig with an external Dolt).
# Two bead reads through the wrapper can spend the whole budget before the first
# `git status`, which is gcp-uzq0: the reaper starts, examines nothing, and
# reports a clean cycle. The script keeps `gc bd` as the fallback and discards
# any pinned answer that resolves none of the ids it asked for, so a wrong store
# cannot be acted on.
#
# Triple-locked exactly like GC_BD_ARGV_TAIL_ALLOWLIST above -- exact tracked
# path, the literal marker on the line, and an exact-line match -- so editing an
# exempted line re-fires the guard and a human re-confirms the call is still
# pinned.
PINNED_STORE_BD_ALLOWLIST: dict[Path, set[str]] = {
    Path("gastown/assets/scripts/polecat-worktree-reap.sh"): {
        'PINNED_BD=(bd -C "$RIG_ROOT" --readonly)'
        " # bd-pinned-store: -C pins the rig checkout, never $PWD",
    },
}


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


def python_argv_violations(path: Path, text: str) -> list[str]:
    if path.suffix != ".py":
        return []
    tree = ast.parse(text, filename=str(path))
    violations = []
    for node in ast.walk(tree):
        if not isinstance(node, (ast.List, ast.Tuple)) or not node.elts:
            continue
        first = node.elts[0]
        if isinstance(first, ast.Constant) and first.value == "bd":
            violations.append(f"{path.relative_to(REPO_ROOT)}:{node.lineno}: argv starts with bd")
    return violations


def gc_routes_bd(line: str, bd_start: int) -> bool:
    prefix = line[:bd_start]
    gc_tokens = list(re.finditer(r"(?<![A-Za-z0-9_=/.-])gc\b", prefix))
    if not gc_tokens:
        return False
    command_prefix = prefix[gc_tokens[-1].end() :].strip()
    try:
        tokens = shlex.split(command_prefix)
    except ValueError:
        return False

    index = 0
    while index < len(tokens):
        token = tokens[index]
        if token in {"--city", "--rig"}:
            if index + 1 >= len(tokens):
                return False
            index += 2
            continue
        if token.startswith("--city=") or token.startswith("--rig="):
            if token.endswith("="):
                return False
            index += 1
            continue
        return False
    return True


def intentional_gc_bd_argv_tail(relative: Path, line: str) -> bool:
    allowed = GC_BD_ARGV_TAIL_ALLOWLIST.get(relative)
    return (
        allowed is not None
        and GC_BD_ARGV_TAIL_MARKER in line
        and line.strip() in allowed
    )


def intentional_pinned_store_bd(relative: Path, line: str) -> bool:
    allowed = PINNED_STORE_BD_ALLOWLIST.get(relative)
    return (
        allowed is not None
        and PINNED_STORE_BD_MARKER in line
        and line.strip() in allowed
    )


def bare_bd_violations(path: Path, text: str) -> list[str]:
    violations = []
    relative = path.relative_to(REPO_ROOT)
    for line_number, line in enumerate(text.splitlines(), start=1):
        for pattern in (BARE_BD_COMMAND, BARE_BD_LEADING_FLAG, BARE_BD_DYNAMIC_COMMAND):
            for match in pattern.finditer(line):
                if gc_routes_bd(line, match.start()):
                    continue
                if intentional_gc_bd_argv_tail(relative, line):
                    continue
                if intentional_pinned_store_bd(relative, line):
                    continue
                violations.append(f"{relative}:{line_number}: {line.strip()}")
        if BARE_BD_GO_EXEC.search(line):
            violations.append(f"{relative}:{line_number}: direct bd argv")
        if BARE_BD_PATH_CHECK.search(line):
            violations.append(f"{relative}:{line_number}: checks bd instead of gc")
        if "BD_BIN" in line:
            violations.append(f"{relative}:{line_number}: BD_BIN bypasses gc bd routing")
    for match in MULTILINE_BARE_BD_COMMAND.finditer(text):
        line_start = text.rfind("\n", 0, match.start()) + 1
        first_line = text[line_start : text.find("\n", match.start())]
        if gc_routes_bd(first_line, match.start() - line_start):
            continue
        line_number = text.count("\n", 0, match.start()) + 1
        violations.append(f"{relative}:{line_number}: bd command is split across lines")
    for match in BARE_BD_SERIALIZED_ARGV.finditer(text):
        line_number = text.count("\n", 0, match.start()) + 1
        violations.append(f"{relative}:{line_number}: serialized argv starts with bd")
    violations.extend(python_argv_violations(path, text))
    return list(dict.fromkeys(violations))


def test_shipped_pack_assets_route_beads_commands_through_gc() -> None:
    violations = []
    for path in tracked_files():
        if path.resolve() == THIS_FILE:
            continue
        try:
            text = path.read_text(encoding="utf-8")
        except UnicodeDecodeError:
            continue
        violations.extend(bare_bd_violations(path, text))

    assert not violations, "bare bd commands bypass store-aware routing:\n" + "\n".join(violations)


def test_detector_covers_shell_multiline_and_serialized_argv_forms() -> None:
    fixture = REPO_ROOT / "fixture.txt"

    assert bare_bd_violations(fixture, 'command = ["bd", "show"]')
    assert bare_bd_violations(fixture, "value=$(bd\n  list --json)")
    assert bare_bd_violations(fixture, "bd --dir /tmp/rig list --json")
    assert bare_bd_violations(fixture, 'bd "$verb" --json')
    assert bare_bd_violations(fixture, 'command = ["bd",\n "show"]')
    assert bare_bd_violations(fixture, "bd show x  # gc-bd-argv-tail")
    assert bare_bd_violations(fixture, "echo gc; bd show x")
    assert bare_bd_violations(fixture, "GC_BIN=gc bd show x")
    assert not bare_bd_violations(fixture, 'command = ["gc", "bd", "show"]')
    assert not bare_bd_violations(fixture, "gc --city /tmp/city bd list --json")
    assert not bare_bd_violations(fixture, "gc --rig demo bd show demo-1")


def test_pinned_store_exemption_is_locked_to_its_exact_lines() -> None:
    # The reaper's pinned read is the only permitted `bd` invocation. Prove the
    # exemption cannot be reused: it needs the right FILE, the marker, and the
    # byte-exact line, so neither a copy elsewhere nor an edit in place inherits
    # it. Without all three locks this allowlist would be a general licence to
    # write bare `bd` with a comment attached.
    reaper = REPO_ROOT / "gastown/assets/scripts/polecat-worktree-reap.sh"
    exempt = 'PINNED_BD=(bd -C "$RIG_ROOT" --readonly)' \
        " # bd-pinned-store: -C pins the rig checkout, never $PWD"

    assert not bare_bd_violations(reaper, exempt)
    # Same line, wrong file.
    assert bare_bd_violations(REPO_ROOT / "fixture.sh", exempt)
    # Right file, marker removed.
    assert bare_bd_violations(reaper, 'PINNED_BD=(bd -C "$RIG_ROOT" --readonly)')
    # Right file and marker, but the line was edited -- a human re-confirms.
    assert bare_bd_violations(
        reaper,
        'PINNED_BD=(bd -C "$SOME_OTHER_DIR" --readonly) # bd-pinned-store',
    )
    # The marker never launders a DIFFERENT bare call in the same file.
    assert bare_bd_violations(reaper, "bd show gcp-1 --json # bd-pinned-store")
    # A directory flag alone is not the exemption; only the allowlisted line is.
    assert bare_bd_violations(reaper, "bd --dir /tmp/rig list --json")


def test_reaper_keeps_gc_bd_as_the_fallback_transport() -> None:
    # The exemption is justified by the pinned read being a FAST PATH, not a
    # replacement: `gc bd` must still be built and still be reachable, or a rig
    # the pinned read cannot serve loses its bead read entirely.
    reaper = (REPO_ROOT / "gastown/assets/scripts/polecat-worktree-reap.sh").read_text(
        encoding="utf-8"
    )

    assert 'GC_BD=(gc bd --rig "$RIG_NAME")' in reaper
    assert '"${GC_BD[@]}" show "${BEAD_IDS_ARGV[@]}" --json' in reaper
    # Every bead read goes through the one helper, so the gate read and the
    # point-of-use re-check cannot end up on different stores.
    assert reaper.count('"${PINNED_BD[@]}" show') == 1
    assert reaper.count('"${GC_BD[@]}" show') == 1
