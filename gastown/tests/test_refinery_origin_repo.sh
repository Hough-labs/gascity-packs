#!/usr/bin/env bash
# Contract tests for the refinery mr lane's origin-repository resolution.
#
# A fork-based rig pushes its branches to `origin` while an `upstream` remote
# points at the parent. `gh repo view` answers with gh's base-repo heuristic,
# which picks the parent — so a lane that trusted it created and looked up pull
# requests in a repository its branches never reached. These tests pin both
# halves of the fix: resolution reads the origin remote, and every `gh pr` call
# is scoped to what resolution produced.
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
FORMULA="$ROOT/gastown/formulas/mol-refinery-patrol.toml"

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

# The block under test is the shipped formula text, extracted between its
# sentinels — not a transcription that could drift from what the refinery runs.
extract_resolution() {
    python3 - "$FORMULA" "$1" <<'PY'
import sys
import tomllib

formula, out = sys.argv[1], sys.argv[2]
begin = "# --- origin-repo-resolution:begin ---"
end = "# --- origin-repo-resolution:end ---"

with open(formula, "rb") as handle:
    doc = tomllib.load(handle)

blocks = [
    text.split(begin, 1)[1].split(end, 1)[0]
    for text in (step.get("description", "") for step in doc["steps"])
    if begin in text and end in text
]
if len(blocks) != 1:
    sys.exit(f"expected exactly one origin-repo-resolution block, found {len(blocks)}")

with open(out, "w") as handle:
    handle.write(blocks[0])
PY
}

# A hermetic PATH. The "no gh installed" cases are only meaningful if the real
# gh on the developer's machine cannot leak in, so the resolution runs against
# exactly the tools named here.
make_bin() {
    local bin="$1" gh_repo="${2-}"
    mkdir -p "$bin"
    local tool
    for tool in git sed; do
        ln -sf "$(command -v "$tool")" "$bin/$tool"
    done
    if [ -n "$gh_repo" ]; then
        # Absolute interpreter: $bin is the whole PATH the stub runs under, so
        # a `/usr/bin/env` shebang would have nothing to look bash up in.
        cat >"$bin/gh" <<SH
#!/bin/sh
# Only \`gh repo view --json nameWithOwner\` is exercised here. It answers with
# the parent, exactly as real gh does in a fork clone carrying an upstream.
if [ "\${1:-}" = "repo" ] && [ "\${2:-}" = "view" ]; then
    printf '%s\n' "$gh_repo"
    exit 0
fi
echo "gh: unexpected invocation: \$*" >&2
exit 1
SH
        chmod +x "$bin/gh"
    fi
}

make_repo() {
    local repo="$1"
    shift
    mkdir -p "$repo"
    git -C "$repo" init -q
    while [ "$#" -gt 0 ]; do
        git -C "$repo" remote add "$1" "$2"
        shift 2
    done
}

# Echoes "<ORIGIN_REPO>|<ORIGIN_REPO_ERROR>" after running the extracted block.
resolve() {
    local repo="$1" bin="$2"
    (
        cd "$repo"
        # Absolute bash: $bin deliberately has no shell in it, and the PATH
        # assignment below is what the interpreter lookup would otherwise use.
        # The body stays single-quoted on purpose — $ORIGIN_REPO must expand in
        # the inner shell, after the block runs, not in this one.
        # shellcheck disable=SC2016
        PATH="$bin" HOME="$repo" "$BASH" -c '
            . "$1"
            printf "%s|%s\n" "$ORIGIN_REPO" "$ORIGIN_REPO_ERROR"
        ' _ "$BLOCK"
    )
}

test_fork_with_upstream_resolves_origin_not_parent() {
    local tmp repo bin got
    tmp=$(mktemp -d)
    repo="$tmp/rig"
    bin="$tmp/bin"
    make_repo "$repo" \
        origin git@github.com:Hough-labs/gascity-packs.git \
        upstream git@github.com:gastownhall/gascity-packs.git
    make_bin "$bin" "gastownhall/gascity-packs"

    got=$(resolve "$repo" "$bin")
    [ "$got" = "Hough-labs/gascity-packs|" ] ||
        fail "fork rig resolved '$got', want 'Hough-labs/gascity-packs|' (gh's parent answer must not win)"
    rm -rf "$tmp"
}

test_single_remote_rig_is_unchanged() {
    local tmp repo bin got
    tmp=$(mktemp -d)
    repo="$tmp/rig"
    bin="$tmp/bin"
    make_repo "$repo" origin https://github.com/gastownhall/gascity.git
    make_bin "$bin" "gastownhall/gascity"

    got=$(resolve "$repo" "$bin")
    [ "$got" = "gastownhall/gascity|" ] ||
        fail "single-remote rig resolved '$got', want 'gastownhall/gascity|'"
    rm -rf "$tmp"
}

test_rest_path_matches_gh_path() {
    # No gh on PATH: the REST fallback must reach the same answer from the same
    # remote, so the two paths cannot disagree about which repo owns the PR.
    local tmp repo bin got
    tmp=$(mktemp -d)
    repo="$tmp/rig"
    bin="$tmp/bin"
    make_repo "$repo" \
        origin git@github.com:Hough-labs/gascity-packs.git \
        upstream git@github.com:gastownhall/gascity-packs.git
    make_bin "$bin"

    got=$(resolve "$repo" "$bin")
    [ "$got" = "Hough-labs/gascity-packs|" ] ||
        fail "REST path resolved '$got', want 'Hough-labs/gascity-packs|' (must match the gh path)"
    rm -rf "$tmp"
}

test_ssh_scheme_origin_is_parsed() {
    local tmp repo bin got
    tmp=$(mktemp -d)
    repo="$tmp/rig"
    bin="$tmp/bin"
    make_repo "$repo" origin ssh://git@github.com/Hough-labs/gascity-packs.git
    make_bin "$bin" "gastownhall/gascity-packs"

    got=$(resolve "$repo" "$bin")
    [ "$got" = "Hough-labs/gascity-packs|" ] ||
        fail "ssh:// origin resolved '$got', want 'Hough-labs/gascity-packs|'"
    rm -rf "$tmp"
}

test_non_github_origin_falls_back_to_gh() {
    local tmp repo bin got
    tmp=$(mktemp -d)
    repo="$tmp/rig"
    bin="$tmp/bin"
    make_repo "$repo" origin git@git.example.com:team/rig.git
    make_bin "$bin" "team/rig"

    got=$(resolve "$repo" "$bin")
    [ "$got" = "team/rig|" ] ||
        fail "non-github origin resolved '$got', want gh's answer 'team/rig|'"
    rm -rf "$tmp"
}

test_non_github_origin_without_gh_reports_an_error() {
    local tmp repo bin got
    tmp=$(mktemp -d)
    repo="$tmp/rig"
    bin="$tmp/bin"
    make_repo "$repo" origin git@git.example.com:team/rig.git
    make_bin "$bin"

    got=$(resolve "$repo" "$bin")
    [ "${got%%|*}" = "" ] ||
        fail "non-github origin without gh resolved '${got%%|*}', want empty"
    case "${got#*|}" in
        *"supports only github.com origin remotes"*) : ;;
        *) fail "non-github origin without gh reported '${got#*|}', want a github.com-only diagnostic" ;;
    esac
    rm -rf "$tmp"
}

test_missing_origin_remote_reports_an_error() {
    local tmp repo bin got
    tmp=$(mktemp -d)
    repo="$tmp/rig"
    bin="$tmp/bin"
    make_repo "$repo"
    make_bin "$bin"

    got=$(resolve "$repo" "$bin")
    [ "${got%%|*}" = "" ] ||
        fail "missing origin resolved '${got%%|*}', want empty"
    case "${got#*|}" in
        *"Could not read the origin remote"*) : ;;
        *) fail "missing origin reported '${got#*|}', want a missing-remote diagnostic" ;;
    esac
    rm -rf "$tmp"
}

test_every_gh_pr_call_is_repo_scoped() {
    python3 - "$FORMULA" <<'PY' || fail "mol-refinery-patrol has an unscoped gh pr call"
import sys
import tomllib

with open(sys.argv[1], "rb") as handle:
    doc = tomllib.load(handle)

unscoped = []
for step in doc["steps"]:
    in_code = False
    for line in step.get("description", "").splitlines():
        if line.lstrip().startswith("```"):
            in_code = not in_code
            continue
        if not in_code or line.lstrip().startswith("#"):
            continue
        if "gh pr " in line and '--repo "$ORIGIN_REPO"' not in line:
            unscoped.append((step["id"], line.strip()))

for step_id, line in unscoped:
    print(f"unscoped gh pr call in step {step_id}: {line}")
sys.exit(1 if unscoped else 0)
PY
}

BLOCK=$(mktemp)
trap 'rm -f "$BLOCK"' EXIT
extract_resolution "$BLOCK"
export BLOCK

test_fork_with_upstream_resolves_origin_not_parent
test_single_remote_rig_is_unchanged
test_rest_path_matches_gh_path
test_ssh_scheme_origin_is_parsed
test_non_github_origin_falls_back_to_gh
test_non_github_origin_without_gh_reports_an_error
test_missing_origin_remote_reports_an_error
test_every_gh_pr_call_is_repo_scoped

echo "refinery origin repo resolution tests passed"
