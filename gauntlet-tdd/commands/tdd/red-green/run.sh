#!/bin/sh
# gc <binding> tdd red-green — sling a coding agent the mol-tdd-red-green formula.
#
# Usage:
#   gc <binding> tdd red-green <bead-id> [--rig <name>] [--agent <name>]
#                              [--implementer <role>] [--contracts-dir <path>]
#
# Environment (set by gc):
#   GC_CITY_PATH   absolute city root
#   GC_PACK_DIR    absolute pack directory
#   GC_PACK_NAME   pack name ("gauntlet-tdd")
#   GC_CITY_NAME   city workspace name
#   GC_RIG         current rig (when running inside a rig session)

set -eu

if [ -z "${GC_PACK_DIR:-}" ]; then
    echo "gc gauntlet-tdd tdd red-green: missing Gas City pack context" >&2
    exit 1
fi

if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ] || [ -z "${1:-}" ]; then
    cat "$GC_PACK_DIR/commands/tdd/red-green/help.md"
    [ -z "${1:-}" ] && exit 2 || exit 0
fi

BEAD="$1"
shift

# A bead id, not a bare number: the formula scaffolds from that bead's
# acceptance criteria, and `bd` fuzzy-matches a partial id onto whatever it
# happens to resolve to. Require the `<prefix>-<suffix>` shape so a typo fails
# here rather than scaffolding a contract from somebody else's bead.
case "$BEAD" in
    *-*) ;;
    *)
        echo "gc gauntlet-tdd tdd red-green: <bead-id> must look like <prefix>-<id> (got: $BEAD)" >&2
        exit 2
        ;;
esac

RIG=""
AGENT="polecat"
IMPLEMENTER=""
CONTRACTS_DIR=""

while [ $# -gt 0 ]; do
    case "$1" in
        --rig)              RIG="$2"; shift 2 ;;
        --rig=*)            RIG="${1#--rig=}"; shift ;;
        --agent)            AGENT="$2"; shift 2 ;;
        --agent=*)          AGENT="${1#--agent=}"; shift ;;
        --implementer)      IMPLEMENTER="$2"; shift 2 ;;
        --implementer=*)    IMPLEMENTER="${1#--implementer=}"; shift ;;
        --contracts-dir)    CONTRACTS_DIR="$2"; shift 2 ;;
        --contracts-dir=*)  CONTRACTS_DIR="${1#--contracts-dir=}"; shift ;;
        *)
            echo "gc gauntlet-tdd tdd red-green: unknown argument: $1" >&2
            exit 2
            ;;
    esac
done

if [ -z "$RIG" ]; then
    RIG="${GC_RIG:-}"
fi

if [ -z "$RIG" ]; then
    cat >&2 <<'USAGE'
gc gauntlet-tdd tdd red-green: rig is required.

Pass --rig <name> or run inside a rig session where GC_RIG is set.

The loop needs to run inside a rig's git worktree: it scaffolds the contract
into that repo's contracts directory and resolves the bead through the store
the worktree points at. Pick the rig whose repository the bead describes.
USAGE
    exit 2
fi

if ! command -v gc >/dev/null 2>&1; then
    echo "gc gauntlet-tdd tdd red-green: gc binary not in PATH" >&2
    exit 1
fi

set -- gc sling "$RIG/$AGENT" mol-tdd-red-green --formula --var "contract_bead=$BEAD"
if [ -n "$IMPLEMENTER" ]; then
    set -- "$@" --var "implementer_target=$IMPLEMENTER"
fi
if [ -n "$CONTRACTS_DIR" ]; then
    set -- "$@" --var "contracts_dir=$CONTRACTS_DIR"
fi

exec "$@"
