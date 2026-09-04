#!/usr/bin/env bash
# install-gascity-archive.sh — install `gc` from a published release archive.
#
# `go install github.com/gastownhall/gascity/cmd/gc@REF` compiles Gas City, and
# Gas City links Dolt. Measured cold on linux/amd64 (gcp-m0ei), that build costs
#
#     GOMODCACHE   2.32 GiB
#     GOCACHE      1.89 GiB
#     gc binary    252 MiB
#     ------------------------
#     total        4.46 GiB
#
# on a runner container whose ephemeral-storage limit is 4Gi. The build alone
# does not fit, which is why every `Install Gas City` step evicted the pod
# ("Container runner exceeded its local ephemeral storage limit \"4Gi\"") and
# GitHub rendered the corpse as exit 130 / "The operation was canceled".
#
# The same release the module proxy serves is also published as a prebuilt
# archive: 44 MiB compressed, a 125 MiB stripped binary, ~170 MiB peak. That is
# the footprint this script pays, and it is the footprint dolt, bd and claude
# already pay via their own install-*-archive.sh siblings in gastownhall/gascity.
# Bringing `gc` onto that footing also drops a multi-minute Dolt compile from
# every job.
#
# Usage: install-gascity-archive.sh REF [--cache]
#
# REF matches the workflows' GASCITY_REF input:
#   main | edge     the rolling `edge` pre-release built from gascity main
#   latest          the newest stable release
#   v1.4.1 | 1.4.1  that exact release tag
#   anything else   no archive exists for it (a branch, a commit sha), so the
#                   script falls back to `go install` and says so loudly. That
#                   path costs the 4.46 GiB above; it exists only so a manual
#                   workflow_dispatch against an unreleased gascity ref keeps
#                   working, and it is never taken by a scheduled run.
#
# --cache installs under RUNNER_TOOL_CACHE and appends the bin directory to
# GITHUB_PATH, as the sibling installers do. Either way the resolved binary path
# is exported as GC_BIN via GITHUB_ENV so workflow steps can name it without
# going through `go env GOPATH`.

set -euo pipefail

REPO="gastownhall/gascity"

usage() {
  cat >&2 <<'USAGE'
Usage: install-gascity-archive.sh REF [--cache]

Downloads a Gas City release tarball, verifies its SHA-256, and installs gc.
REF is main/edge, latest, or a release version such as v1.4.1. Use --cache on
self-hosted runners to install under RUNNER_TOOL_CACHE and add that bin
directory to GITHUB_PATH.
USAGE
}

ref="${1:-}"
if [[ -z "$ref" ]]; then
  usage
  exit 2
fi
shift || true

use_cache=false
while (($#)); do
  case "$1" in
    --cache) use_cache=true ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage
      exit 2
      ;;
  esac
  shift
done

case "$(uname -s)" in
  Darwin) os=darwin ;;
  Linux) os=linux ;;
  *)
    echo "Unsupported OS: $(uname -s)" >&2
    exit 1
    ;;
esac

case "$(uname -m)" in
  arm64|aarch64) arch=arm64 ;;
  x86_64|amd64) arch=amd64 ;;
  *)
    echo "Unsupported architecture: $(uname -m)" >&2
    exit 1
    ;;
esac

platform_tuple="${os}_${arch}"

fetch() {
  curl -fsSL --retry 5 --retry-delay 2 --retry-all-errors --retry-connrefused "$@"
}

# Auth is confined to api.github.com. A release download redirects to
# objects.githubusercontent.com, and curl -L replays custom headers on the
# redirect target, so attaching the bearer to every fetch would hand the token
# to a different host. Everything this script downloads is public; the token is
# only ever a rate-limit courtesy on the API call.
fetch_api() {
  local auth=()
  if [[ -n "${GITHUB_TOKEN:-}" ]]; then
    auth=(-H "Authorization: Bearer ${GITHUB_TOKEN}")
  fi
  fetch "${auth[@]}" -H "Accept: application/vnd.github+json" "$@"
}

export_gc_bin() {
  local target="$1"
  if [[ -n "${GITHUB_ENV:-}" ]]; then
    echo "GC_BIN=${target}" >> "$GITHUB_ENV"
  fi
}

# `go install` is the escape hatch for a ref with no published archive. It is
# the pre-gcp-m0ei behaviour, disk cost included, so it warns rather than
# failing silently into a 4.46 GiB build on a 4Gi budget.
install_from_source() {
  local reason="$1"
  echo "WARNING: ${reason}" >&2
  echo "WARNING: falling back to 'go install ...@${ref}', which needs ~4.46 GiB of" >&2
  echo "WARNING: ephemeral storage (GOMODCACHE + GOCACHE + binary) and may evict the runner." >&2
  go install "github.com/${REPO}/cmd/gc@${ref}"
  local bin_dir
  bin_dir="$(go env GOPATH)/bin"
  if [[ -n "${GITHUB_PATH:-}" ]]; then
    echo "$bin_dir" >> "$GITHUB_PATH"
  fi
  export_gc_bin "${bin_dir}/gc"
  "${bin_dir}/gc" version
  exit 0
}

# Resolve REF to a release tag and to the version token goreleaser embeds in the
# asset name (the tag without its leading `v`, or `edge` for the rolling build).
resolve_latest_tag() {
  # The /releases/latest redirect is unauthenticated and not subject to the API
  # rate limit, so it stays reliable on a runner with no token; the API is the
  # fallback for the case where the redirect is unavailable.
  local url tag
  url="$(curl -fsSL -o /dev/null -w '%{url_effective}' --retry 5 --retry-delay 2 --retry-all-errors \
    "https://github.com/${REPO}/releases/latest" 2>/dev/null || true)"
  tag="${url##*/}"
  if [[ -n "$tag" && "$tag" != "latest" ]]; then
    printf '%s' "$tag"
    return 0
  fi
  fetch_api "https://api.github.com/repos/${REPO}/releases/latest" 2>/dev/null |
    jq -r '.tag_name // empty'
}

case "$ref" in
  main|edge)
    tag="edge"
    version="edge"
    ;;
  latest)
    tag="$(resolve_latest_tag)"
    if [[ -z "$tag" ]]; then
      install_from_source "could not resolve the latest ${REPO} release tag"
    fi
    version="${tag#v}"
    ;;
  v[0-9]*)
    tag="$ref"
    version="${ref#v}"
    ;;
  [0-9]*)
    tag="v${ref}"
    version="$ref"
    ;;
  *)
    install_from_source "${REPO} publishes no release archive for ref '${ref}'"
    ;;
esac

archive="gascity_${version}_${platform_tuple}.tar.gz"
download_base="https://github.com/${REPO}/releases/download/${tag}"

# Prefer the checksum GitHub computes server-side for the asset; fall back to the
# checksums.txt goreleaser publishes alongside it when the API is unreachable or
# rate-limited. Both are logged so a mismatch is diagnosable from the job output.
release_asset_sha() {
  if command -v jq >/dev/null 2>&1; then
    local digest
    digest="$(fetch_api "https://api.github.com/repos/${REPO}/releases/tags/${tag}" 2>/dev/null |
      jq -r --arg asset "$archive" '.assets[] | select(.name == $asset) | .digest // empty' |
      sed 's/^sha256://')"
    if [[ -n "$digest" ]]; then
      printf '%s' "$digest"
      return 0
    fi
  fi
  fetch "${download_base}/gascity_${version}_checksums.txt" 2>/dev/null |
    awk -v asset="$archive" '$2 == asset { print $1; exit }'
}

expected_sha="$(release_asset_sha)"
if [[ -z "$expected_sha" ]]; then
  echo "No Gas City checksum found for ${tag}/${platform_tuple} (asset ${archive})" >&2
  exit 1
fi

sha256_file() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | cut -d ' ' -f 1
  else
    shasum -a 256 "$1" | cut -d ' ' -f 1
  fi
}

install_binary() {
  local src="$1"
  local dst="$2"
  mkdir -p "$(dirname "$dst")"
  install -m 0755 "$src" "$dst"
}

install_binary_with_sudo_fallback() {
  local src="$1"
  local dst="$2"
  local dst_dir
  dst_dir="$(dirname "$dst")"
  mkdir -p "$dst_dir"
  if [[ -w "$dst_dir" ]]; then
    install_binary "$src" "$dst"
  elif command -v sudo >/dev/null 2>&1; then
    sudo install -m 0755 "$src" "$dst"
  else
    echo "Cannot write $dst and sudo is unavailable" >&2
    exit 1
  fi
}

if $use_cache; then
  cache_root="${RUNNER_TOOL_CACHE:-$HOME/.local}"
  # Keyed on the checksum, not the tag alone: `edge` is a rolling pre-release
  # whose asset is replaced whenever gascity main moves, so a tag-only key would
  # happily serve a stale gc for the rest of the runner's life.
  bin_dir="${cache_root}/gascity-gc/${tag}/${expected_sha:0:16}/${platform_tuple}/bin"
else
  bin_dir="${GASCITY_INSTALL_BIN_DIR:-/usr/local/bin}"
fi

target="${bin_dir}/gc"
if $use_cache && [[ -x "$target" ]]; then
  echo "Reusing cached Gas City ${tag} at ${target}"
else
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' EXIT
  fetch -o "${tmp}/${archive}" "${download_base}/${archive}"
  actual_sha="$(sha256_file "${tmp}/${archive}")"
  if [[ "$actual_sha" != "$expected_sha" ]]; then
    echo "Gas City checksum mismatch for ${tag}/${platform_tuple}" >&2
    echo "expected: $expected_sha" >&2
    echo "actual:   $actual_sha" >&2
    exit 1
  fi
  tar -xzf "${tmp}/${archive}" -C "$tmp" gc
  if $use_cache; then
    install_binary "${tmp}/gc" "$target"
  else
    install_binary_with_sudo_fallback "${tmp}/gc" "$target"
  fi
  # The tarball is the largest transient on disk; drop it before the caller's
  # next step rather than at job teardown.
  rm -rf "$tmp"
  trap - EXIT
fi

if $use_cache && [[ -n "${GITHUB_PATH:-}" ]]; then
  echo "$bin_dir" >> "$GITHUB_PATH"
fi
export_gc_bin "$target"

"$target" version
