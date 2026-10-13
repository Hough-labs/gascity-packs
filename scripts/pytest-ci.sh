#!/usr/bin/env bash
# scripts/pytest-ci.sh — the Python pack test set, in one place.
#
# This is the set CI runs (.github/workflows/ci.yml, "Run Python pack tests")
# and the rig gate runs. The directory list lives only here, so the two cannot
# drift (gc-ch43y): add a pack's tests dir to this list and both pick it up.
#
# Usage: scripts/pytest-ci.sh [pytest args...]
#        Extra arguments pass through to pytest, e.g. --collect-only.
set -euo pipefail
cd "$(dirname "$0")/.."
exec python3 -m pytest tests contributing-to-gascity/tests gascity/tests discord/tests github/tests oversight-rig/tests slack-full/tests slack-channel/tests pr-pipeline/tests profiler/tests gauntlet-tdd/tests -q "$@"
