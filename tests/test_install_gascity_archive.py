"""Behavioural tests for .github/scripts/install-gascity-archive.sh.

The installer resolves a release checksum and downloads the archive in two
separate requests. For the rolling `edge` pre-release those two requests can
name two different builds, because goreleaser replaces that release's assets in
place whenever gascity main moves -- which is what turned the Supported Pack
Nightly's bmad job red on 2026-09-10 with a checksum mismatch that was not
corruption (gcp-kinb).

Asserting on the script's text cannot tell a rotation apart from a corrupt
download, so these tests run the script for real against a scripted stand-in for
the release: a `curl` on PATH that serves a release whose asset rotates exactly
when a test says it does. Nothing here touches the network.

The same race decides which gascity source the inference gates check out. The
installer names it (GASCITY_SOURCE_REF) from the build info of the gc it
installed, so a `go` stand-in reads that build info out of the fake gc itself:
each build records its own vcs.revision, and a rotation that changes the
installed build changes the revision with it.
"""

from __future__ import annotations

import gzip
import hashlib
import io
import os
import platform
import subprocess
import tarfile
from pathlib import Path

import pytest

REPO_ROOT = Path(__file__).resolve().parents[1]
INSTALLER = REPO_ROOT / ".github" / "scripts" / "install-gascity-archive.sh"

# The stand-in for curl. It serves one scripted view of
# repos/gastownhall/gascity/releases/tags/edge: a build index in `current`
# selects which build's digest the API reports and which build's bytes the
# archive download returns, and the ROTATE_BEFORE_* variables say on which
# request ordinals the release rolls forward to the next build. That is the
# whole race, made deterministic -- a rotation between the digest request and
# the archive request is the failure the installer has to absorb, and a rotation
# on every request is the pathological case its retry bound exists for.
FAKE_CURL = '''#!/usr/bin/env python3
import json
import os
import sys
from pathlib import Path

fixture = Path(os.environ["INSTALLER_FIXTURE"])


def current() -> int:
    return int((fixture / "current").read_text())


def rotate() -> None:
    (fixture / "current").write_text(str(current() + 1))


def count(kind: str) -> int:
    path = fixture / f"{kind}_requests"
    seen = int(path.read_text()) if path.exists() else 0
    seen += 1
    path.write_text(str(seen))
    return seen


def rotates_before(kind: str, ordinal: int) -> bool:
    spec = os.environ.get(f"ROTATE_BEFORE_{kind}", "")
    if spec == "all":
        return True
    return str(ordinal) in [part for part in spec.split(",") if part]


url = None
out = None
args = sys.argv[1:]
for index, arg in enumerate(args):
    if arg == "-o":
        out = args[index + 1]
    elif arg.startswith("http"):
        url = arg
if url is None:
    sys.stderr.write("fake curl: no URL in %r\\n" % (args,))
    sys.exit(2)

asset = (fixture / "asset").read_text().strip()

if url.endswith(".tar.gz"):
    if rotates_before("ARCHIVE", count("archive")):
        rotate()
    if os.environ.get("CORRUPT_ARCHIVE") == "1":
        body = b"these are not the bytes the release published"
    else:
        body = (fixture / f"build_{current()}.tar.gz").read_bytes()
elif url.endswith("_checksums.txt") or "/releases/tags/" in url:
    # One resolve issues one of these two: the API digest when jq is available,
    # the published checksums.txt otherwise. Both count as the same request so
    # the rotation schedule reads the same either way.
    if rotates_before("DIGEST", count("digest")):
        rotate()
    digest = (fixture / f"build_{current()}.sha").read_text().strip()
    if url.endswith("_checksums.txt"):
        body = f"{digest}  {asset}\\n".encode()
    else:
        body = json.dumps(
            {"assets": [{"name": asset, "digest": f"sha256:{digest}"}]}
        ).encode()
else:
    sys.stderr.write(f"fake curl: unexpected URL {url}\\n")
    sys.exit(22)

with (fixture / "requests.log").open("a") as handle:
    handle.write(f"{url}\\n")

if out:
    Path(out).write_bytes(body)
else:
    sys.stdout.buffer.write(body)
'''


# The stand-in for the Go toolchain, covering the three calls the installer
# makes. `go version -m` prints the build info of the binary it is given; a
# fake gc carries that build info as `# go-build-info<TAB>...` comment lines, so
# what is reported is a property of whichever build was actually installed.
# `go install pkg@ref` builds in module mode, which is what the real toolchain
# does for it: the binary records the module version and no vcs.* settings.
FAKE_GO = '''#!/usr/bin/env python3
import os
import sys
from pathlib import Path

args = sys.argv[1:]
if args[:2] == ["version", "-m"] and len(args) == 3:
    binary = Path(args[2])
    info = [
        line.split("\\t", 1)[1]
        for line in binary.read_text().splitlines()
        if line.startswith("# go-build-info\\t")
    ]
    if not info:
        sys.stderr.write(f"{binary}: could not read Go build info\\n")
        sys.exit(1)
    print(f"{binary}: go1.26.5")
    for line in info:
        print(f"\\t{line}")
elif args == ["env", "GOPATH"]:
    print(os.environ["GOPATH"])
elif args[:1] == ["install"] and len(args) == 2:
    bin_dir = Path(os.environ["GOPATH"]) / "bin"
    bin_dir.mkdir(parents=True, exist_ok=True)
    gc = bin_dir / "gc"
    gc.write_text(
        "#!/bin/sh\\n"
        "# go-build-info\\tpath\\tgithub.com/gastownhall/gascity/cmd/gc\\n"
        "# go-build-info\\tmod\\tgithub.com/gastownhall/gascity\\t"
        "v1.5.1-0.20261010000000-f66474617d2b\\th1:fake=\\n"
        "# go-build-info\\tbuild\\t-buildmode=exe\\n"
        "echo \\"gc version from-source\\"\\n"
    )
    gc.chmod(0o755)
else:
    sys.stderr.write(f"fake go: unexpected arguments {args!r}\\n")
    sys.exit(2)
'''


def platform_tuple() -> str:
    system = {"Darwin": "darwin", "Linux": "linux"}.get(platform.system())
    machine = {
        "arm64": "arm64",
        "aarch64": "arm64",
        "x86_64": "amd64",
        "amd64": "amd64",
    }.get(platform.machine())
    if system is None or machine is None:
        pytest.skip(f"installer supports no archive for {platform.system()}/{platform.machine()}")
    return f"{system}_{machine}"


def revision_of(build: int) -> str:
    """The full commit a build was made from, as vcs.revision records it."""
    return hashlib.sha1(f"gascity-build-{build}".encode()).hexdigest()


def build_archive(build: int, *, stamped: bool = True) -> bytes:
    """A release tarball whose gc identifies its build.

    `stamped` is a goreleaser build from a git checkout, which records the
    commit as vcs.revision; unstamped is a build that recorded none.
    """
    build_info = "# go-build-info\tpath\tgithub.com/gastownhall/gascity/cmd/gc\n"
    build_info += "# go-build-info\tbuild\t-buildmode=exe\n"
    if stamped:
        build_info += "# go-build-info\tbuild\tvcs=git\n"
        build_info += f"# go-build-info\tbuild\tvcs.revision={revision_of(build)}\n"
    script = f'#!/bin/sh\n{build_info}echo "gc version build-{build}"\n'.encode()
    raw = io.BytesIO()
    with tarfile.open(fileobj=raw, mode="w") as tar:
        info = tarfile.TarInfo("gc")
        info.size = len(script)
        info.mode = 0o755
        tar.addfile(info, io.BytesIO(script))
    packed = io.BytesIO()
    with gzip.GzipFile(fileobj=packed, mode="wb", mtime=0) as gz:
        gz.write(raw.getvalue())
    return packed.getvalue()


def make_release(tmp_path, *, version: str = "edge", stamped: bool = True) -> Path:
    """A fixture release with enough builds for the worst rotation schedule."""
    fixture = tmp_path / "release"
    fixture.mkdir()
    tuple_ = platform_tuple()
    (fixture / "asset").write_text(f"gascity_{version}_{tuple_}.tar.gz")
    (fixture / "current").write_text("0")
    # Three download attempts, each preceded by a digest request that may also
    # rotate, cannot consume more than eight builds.
    for build in range(12):
        archive = build_archive(build, stamped=stamped)
        (fixture / f"build_{build}.tar.gz").write_bytes(archive)
        (fixture / f"build_{build}.sha").write_text(hashlib.sha256(archive).hexdigest())
    return fixture


@pytest.fixture
def release(tmp_path):
    return make_release(tmp_path)


def sha_of(release: Path, build: int) -> str:
    return (release / f"build_{build}.sha").read_text().strip()


def run_installer(tmp_path, release: Path, cache: Path | None = None, ref: str = "edge", **scenario):
    bin_stub = tmp_path / "stub-bin"
    bin_stub.mkdir(exist_ok=True)
    for name, body in (("curl", FAKE_CURL), ("go", FAKE_GO)):
        stub = bin_stub / name
        stub.write_text(body)
        stub.chmod(0o755)

    cache = cache if cache is not None else tmp_path / "tool-cache"
    cache.mkdir(exist_ok=True)
    github_env = tmp_path / "github-env"
    github_path = tmp_path / "github-path"
    # Emptied per run, as each Actions step starts with fresh files, so a run
    # is judged on what it wrote and not on an earlier run's exports.
    github_env.write_text("")
    github_path.write_text("")

    env = dict(os.environ)
    env.pop("GITHUB_TOKEN", None)
    env.update(
        {
            "PATH": f"{bin_stub}{os.pathsep}{os.environ['PATH']}",
            "INSTALLER_FIXTURE": str(release),
            "RUNNER_TOOL_CACHE": str(cache),
            "GITHUB_ENV": str(github_env),
            "GITHUB_PATH": str(github_path),
            "GOPATH": str(tmp_path / "gopath"),
        }
    )
    env.update({name: str(value) for name, value in scenario.items()})

    completed = subprocess.run(
        [str(INSTALLER), ref, "--cache"],
        env=env,
        capture_output=True,
        text=True,
        check=False,
    )
    requests = (release / "requests.log").read_text().splitlines() if (release / "requests.log").exists() else []
    return completed, {
        "cache": cache,
        # The whole GITHUB_ENV file, not one variable of it: a failed install
        # must leave it empty, and a successful one writes exactly GC_BIN and
        # GASCITY_SOURCE_REF.
        "github_env": github_env.read_text().strip(),
        "github_path": github_path.read_text().strip(),
        "archive_requests": [url for url in requests if url.endswith(".tar.gz")],
    }


def test_installer_verifies_and_installs_the_published_archive(tmp_path, release):
    # The undisturbed path, and the control for every rotation test below: with
    # the release holding still, the archive whose checksum was resolved is the
    # archive that gets installed.
    completed, result = run_installer(tmp_path, release)

    assert completed.returncode == 0, completed.stderr
    assert "gc version build-0" in completed.stdout
    assert len(result["archive_requests"]) == 1
    # Keyed on the verified checksum, so a later `edge` cannot be served from
    # this entry.
    assert sha_of(release, 0)[:16] in result["github_env"]
    # Order-free, but sorted rather than a set so a doubled export still fails.
    # The source ref is the full commit the installed gc records, never the
    # rolling tag: resolving `edge` again can name a later build, and a
    # shallow `git fetch` resolves a full SHA where it cannot resolve a short one.
    assert sorted(result["github_env"].splitlines()) == sorted(
        [f"GC_BIN={result['github_path']}/gc", f"GASCITY_SOURCE_REF={revision_of(0)}"]
    )
    assert Path(result["github_path"], "gc").is_file()


def test_installer_reuses_the_cache_entry_for_an_already_verified_checksum(tmp_path, release):
    # A warm entry is why only a cache-missing job can lose the race at all:
    # this second run performs no download, so it has no window to lose.
    cache = tmp_path / "tool-cache"
    first, _ = run_installer(tmp_path, release, cache=cache)
    assert first.returncode == 0, first.stderr

    (release / "requests.log").unlink()
    second, result = run_installer(tmp_path, release, cache=cache)

    assert second.returncode == 0, second.stderr
    assert result["archive_requests"] == []
    assert "Reusing cached Gas City edge" in second.stdout
    assert "gc version build-0" in second.stdout
    # Read from the cached binary, so a cache hit names the build it serves.
    assert f"GASCITY_SOURCE_REF={revision_of(0)}" in result["github_env"].splitlines()


def test_installer_absorbs_an_edge_rotation_between_checksum_and_download(tmp_path, release):
    # gcp-kinb. The release rolls forward after the digest is resolved and
    # before the archive is served, so the bytes on disk are build 1 while the
    # expected checksum is build 0's -- the exact shape of the nightly failure.
    # Re-resolving shows the digest moved and now matches what was downloaded,
    # which is a rotation and not corruption: the install must succeed on the
    # build the release actually points at, and say so.
    completed, result = run_installer(tmp_path, release, ROTATE_BEFORE_ARCHIVE="1")

    assert completed.returncode == 0, completed.stderr
    assert "gc version build-1" in completed.stdout
    # Absorbed with no second download -- the bytes in hand were verified
    # against the digest the release publishes now.
    assert len(result["archive_requests"]) == 1
    assert "rotated while the archive was downloading" in completed.stderr
    assert sha_of(release, 0) in completed.stderr
    assert sha_of(release, 1) in completed.stderr
    # The cache entry is keyed on what was verified and installed (build 1),
    # never on the checksum that was resolved first.
    assert sha_of(release, 1)[:16] in result["github_env"]
    assert sha_of(release, 0)[:16] not in result["github_env"]
    # And the source ref names build 1 too. Resolving `edge` once for the
    # archive and again for the source is the race this rules out: the two
    # resolutions can land on different builds, the one checked out matching
    # neither the gc installed nor the other.
    assert f"GASCITY_SOURCE_REF={revision_of(1)}" in result["github_env"].splitlines()
    assert revision_of(0) not in result["github_env"]


def test_installer_bounds_its_retries_when_edge_will_not_hold_still(tmp_path, release):
    # A release rotating on every single request can never be verified, and the
    # retry must not become a spin. Three attempts, then a failure that names
    # the rotation rather than blaming the archive.
    completed, result = run_installer(
        tmp_path, release, ROTATE_BEFORE_ARCHIVE="all", ROTATE_BEFORE_DIGEST="all"
    )

    assert completed.returncode == 1
    assert len(result["archive_requests"]) == 3
    assert "rotated on every one of 3 download attempts" in completed.stderr
    assert "retrying against the new checksum (attempt 2/3)" in completed.stderr
    assert "retrying against the new checksum (attempt 3/3)" in completed.stderr
    # Nothing unverified is installed, and nothing is exported -- no GC_BIN,
    # no GASCITY_SOURCE_REF -- for a later step to trip over.
    assert result["github_env"] == ""
    assert list(result["cache"].rglob("gc")) == []


def test_installer_still_fails_loudly_on_a_real_checksum_mismatch(tmp_path, release):
    # The guarantee the retry must not erode. The digest never moves, so bytes
    # that do not match it are the archive's problem: fail, once, without a
    # second download, and without installing anything.
    completed, result = run_installer(tmp_path, release, CORRUPT_ARCHIVE="1")

    assert completed.returncode == 1
    assert "Gas City checksum mismatch for edge/" in completed.stderr
    assert f"expected: {sha_of(release, 0)}" in completed.stderr
    assert "re-resolves unchanged" in completed.stderr
    assert len(result["archive_requests"]) == 1
    assert result["github_env"] == ""
    assert list(result["cache"].rglob("gc")) == []


def test_installer_falls_back_to_the_release_tag_when_gc_records_no_revision(tmp_path):
    # A build with no vcs.revision in its build info. A version tag names one
    # commit, so it is the one ref that can still stand in -- loudly, because
    # the revision is then taken on the tag's word rather than read from gc.
    release = make_release(tmp_path, version="1.5.0", stamped=False)
    completed, result = run_installer(tmp_path, release, ref="v1.5.0")

    assert completed.returncode == 0, completed.stderr
    assert "gc version build-0" in completed.stdout
    assert sorted(result["github_env"].splitlines()) == sorted(
        [f"GC_BIN={result['github_path']}/gc", "GASCITY_SOURCE_REF=v1.5.0"]
    )
    assert "records no vcs.revision" in completed.stderr
    assert "release tag v1.5.0" in completed.stderr


def test_installer_fails_loudly_when_no_source_revision_can_be_named(tmp_path, release):
    # A short SHA has no release archive, so gc comes from `go install`, which
    # builds in module mode and records no vcs.revision -- and there is no
    # release tag to stand in. Exporting the ref as given would hand the
    # checkout step a short SHA that a shallow fetch cannot resolve; exporting
    # nothing and exiting 0 would push the failure to that step. The install
    # fails here instead, and like every failed install it exports nothing.
    completed, result = run_installer(tmp_path, release, ref="f66474617d2b")

    assert completed.returncode == 1
    assert "falling back to 'go install" in completed.stderr
    assert "records no vcs.revision" in completed.stderr
    assert "no release tag" in completed.stderr
    assert result["github_env"] == ""
    assert result["github_path"] == ""
