#!/usr/bin/env bash
# Contract tests for the refinery patrol's acceptance-check wiring (gcp-s7j4.2, and
# reject mode, gcp-s7j4.4).
#
# acceptance-check.sh (gcp-s7j4.1) builds an evidence packet per bead and records a
# verdict on it, and was inert until `mol-refinery-patrol` called it. The formula
# now does, in a step between find-work and rebase, behind `acceptance_check`
# (default "off", so a rig that sets nothing sees one line and no read). The
# formula keeps no acceptance logic of its own beyond the mode case, the packet
# loop and the SKIP routing: the mechanics are the script's, and
# test_refinery_acceptance_check.sh is their proof. In reject mode `record` returns
# each MISS to the polecat pool, and one block after the last record trims the
# iteration to the beads the refinery still holds (case_reject_block).
#
# What this suite proves is the WIRING, so each case that runs the fence extracts
# the sentinel-delimited block of shipped formula text through tomllib, with the
# formula's [vars] defaults substituted and any `{{...}}` left over a hard error,
# and EXECUTES it under `env -i` in a real git clone of a bare origin (the fence's
# `git fetch --prune origin` runs for real). The one placeholder a case leaves
# literal is `{{acceptance_check}}`, on purpose: that is what the renderer leaves
# for a patrol poured root-only without the rig setting the var. A regression shows
# up as "the script was called in off mode" or "a SKIP code was recorded as a
# verdict", never as a grep for a command that merely appears in the text.
#
# Only gc and acceptance-check.sh are stubbed. gc answers `formula list` and
# journals every call as "gc <args>". The script lives in a staged pack tree, found
# the way the shipped block finds it (`gc formula list` names the formula's source,
# and the script is its sibling), and appends its argv, one line per call, to a
# log, then prints and exits as its env says.
#
# The suite fails unless all 16 cases ran.
set -uo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
FORMULA="${FORMULA:-$ROOT/gastown/formulas/mol-refinery-patrol.toml}"
EXPECTED_CASES=16

REFINERY_AGENT=testrig/gastown.refinery
HEAD_ID=wa-head
SECOND_ID=wa-second
THIRD_ID=wa-third
FAILURES=0
PASS_CASES=0
CASE=""
CASE_START_FAILURES=0
T=""

# The setup commits below need an identity, and no ambient git config.
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@example.invalid
export GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@example.invalid

fail() {
    echo "FAIL[$CASE]: $*" >&2
    FAILURES=$((FAILURES + 1))
}

assert_eq() {
    # assert_eq <what> <want> <got>
    [ "$2" = "$3" ] || fail "$1: want '$2', got '$3'"
}

# --- extracting the shipped blocks ------------------------------------------------

# extract_block <begin-name> <end-name> <outfile> [leave:VAR | set:VAR=value ...]
#
# The text from `# --- <begin-name>:begin ---` to `# --- <end-name>:end ---`, which
# is one block when the two names are the same. The begin sentinel must occur in
# exactly one step. Placeholders come from the formula's [vars] defaults. `set:`
# overrides one the way a rig's formula_vars would, and `leave:` keeps one literal,
# which is the only placeholder allowed to survive.
extract_block() {
    python3 - "$FORMULA" "$@" <<'PY'
import re
import sys
import tomllib

formula, begin_name, end_name, out, *options = sys.argv[1:]
leave = [o[len("leave:"):] for o in options if o.startswith("leave:")]
overrides = dict(o[len("set:"):].split("=", 1) for o in options if o.startswith("set:"))
begin = f"# --- {begin_name}:begin ---"
end = f"# --- {end_name}:end ---"

with open(formula, "rb") as handle:
    doc = tomllib.load(handle)

blocks = []
for step in doc["steps"]:
    text = step.get("description", "")
    if begin in text:
        rest = text.split(begin, 1)[1]
        if end not in rest:
            sys.exit(f"{begin_name}: no {end} after the begin sentinel")
        blocks.append(rest.split(end, 1)[0])
if len(blocks) != 1:
    sys.exit(f"expected exactly one {begin_name} block in {formula}, found {len(blocks)}")

values = {n: spec.get("default", "") for n, spec in (doc.get("vars") or {}).items()}
for name in leave:
    if name not in values:
        sys.exit(f"{name!r} is not a declared var of this formula")
for name in overrides:
    if name not in values and "{{%s}}" % name not in blocks[0]:
        sys.exit(f"{name!r} is neither a declared var nor used by {begin_name}")
values.update(overrides)
for name in leave:
    values.pop(name)
block = re.sub(r"\{\{\s*(\w+)\s*\}\}", lambda m: values.get(m.group(1), m.group(0)), blocks[0])
leftover = sorted(set(re.findall(r"\{\{[^}]*\}\}", block)) - {"{{%s}}" % n for n in leave})
if leftover:
    sys.exit(f"unsubstituted placeholders in {begin_name}: {leftover}")

with open(out, "w", encoding="utf-8") as handle:
    handle.write(block)
PY
}

# --- the fixture --------------------------------------------------------------------

write_gc_stub() {
    cat >"$1/gc" <<'STUB'
#!/usr/bin/env bash
printf 'gc %s\n' "$*" >>"${GC_STUB_LOG:?GC_STUB_LOG unset}"
case "${1:-}" in
formula)
    if [ "${2:-}" != list ]; then
        printf '%s\n' "$*" >>"${GC_STUB_UNEXPECTED:?}"
        exit 64
    fi
    printf '{"formulas":[{"name":"mol-refinery-patrol","source":"%s"}]}' "${GC_STUB_FORMULA_SOURCE:-}"
    ;;
bd)
    # gc bd show <id> --json, the read the reject block makes. GC_STUB_ASSIGNEES is
    # words of "<id>=<assignee>" ("<id>=" is an empty assignee), an id it does not
    # list is assigned to GC_AGENT, and the ids in GC_STUB_FAIL_SHOW fail the read.
    if [ "${2:-}" != show ] || [ "${4:-}" != --json ] || [ "$#" -ne 4 ]; then
        printf '%s\n' "$*" >>"${GC_STUB_UNEXPECTED:?}"
        exit 64
    fi
    case " ${GC_STUB_FAIL_SHOW:-} " in
    *" $3 "*)
        echo "stub gc: gc bd show $3 failed on request" >&2
        exit 1
        ;;
    esac
    assignee="${GC_AGENT:-}"
    for pair in ${GC_STUB_ASSIGNEES:-}; do
        [ "${pair%%=*}" = "$3" ] && assignee="${pair#*=}"
    done
    jq -n --arg id "$3" --arg a "$assignee" '[{id: $id, assignee: $a}]'
    ;;
*)
    printf '%s\n' "$*" >>"${GC_STUB_UNEXPECTED:?}"
    exit 64
    ;;
esac
STUB
    chmod +x "$1/gc"
}

# The stand-in for acceptance-check.sh: it logs its argv and exits as its env says.
# A packet exiting 0 prints the two-line packet for the bead it was asked about; any
# other status prints STUB_PACKET_OUT. A record logs whatever it was given on stdin.
write_ack_stub() {
    cat >"$1" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${STUB_ACK_LOG:?STUB_ACK_LOG unset}"
case "${1:-}" in
packet)
    if [ "${STUB_PACKET_STATUS:-0}" -eq 0 ]; then
        printf 'acceptance-check: PACKET %s\nbody\n' "${3:-}"
    else
        [ -z "${STUB_PACKET_OUT:-}" ] || printf '%b\n' "$STUB_PACKET_OUT"
    fi
    exit "${STUB_PACKET_STATUS:-0}"
    ;;
record)
    cat >>"${STUB_STDIN_LOG:?STUB_STDIN_LOG unset}"
    exit "${STUB_RECORD_STATUS:-0}"
    ;;
*) exit 64 ;;
esac
STUB
    chmod +x "$1"
}

# new_case <name> — a fresh clone of a bare origin, staged pack tree and logs.
new_case() {
    CASE="$1"
    CASE_START_FAILURES=$FAILURES
    T=$(mktemp -d)
    mkdir -p "$T/bin" "$T/home" "$T/pack/formulas" "$T/pack/assets/scripts/refinery"
    : >"$T/pack/formulas/mol-refinery-patrol.toml"
    write_gc_stub "$T/bin"
    ACK_STUB="$T/pack/assets/scripts/refinery/acceptance-check.sh"
    write_ack_stub "$ACK_STUB"
    : >"$T/gc.log"
    : >"$T/ack.log"
    : >"$T/ack-stdin.log"
    : >"$T/unexpected"
    git init -q --bare -b main "$T/origin.git"
    git init -q -b main "$T/repo"
    git -C "$T/repo" remote add origin "$T/origin.git"
    git -C "$T/repo" commit -q --allow-empty -m init
    git -C "$T/repo" push -q origin main
    GIT_DIR_PATH="$T/repo/.git"
    ACK_DIR_PATH="$GIT_DIR_PATH/acceptance"
    MANIFEST="$GIT_DIR_PATH/refinery-batch.json"
}

end_case() {
    [ ! -s "$T/unexpected" ] || fail "unmodelled stub call(s): $(tr '\n' ';' <"$T/unexpected")"
    if [ "$FAILURES" -ne "$CASE_START_FAILURES" ]; then
        {
            echo "--- $CASE: last run stdout ---"
            cat "$T/out" 2>/dev/null
            echo "--- $CASE: last run stderr ---"
            cat "$T/err" 2>/dev/null
            echo "--- $CASE: gc calls ---"
            cat "$T/gc.log"
        } >&2
    fi
    trash "$T" 2>/dev/null || rm -rf "$T"
    PASS_CASES=$((PASS_CASES + 1))
}

# run_block <file> [VAR=value ...] — run an extracted block in the refinery clone,
# as the patrol does, under `env -i` so no agent-session variable leaks in. The
# block's own status is returned; its stdout and stderr land in $T/out and $T/err.
run_block() {
    local file="$1"
    shift
    (
        cd "$T/repo" || exit 90
        env -i \
            PATH="$T/bin:$PATH" HOME="$T/home" \
            GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 \
            GC_AGENT="$REFINERY_AGENT" GC_RIG=testrig GC_BEAD_ID=wisp-current \
            GC_STUB_LOG="$T/gc.log" GC_STUB_UNEXPECTED="$T/unexpected" \
            GC_STUB_FORMULA_SOURCE="$T/pack/formulas/mol-refinery-patrol.toml" \
            STUB_ACK_LOG="$T/ack.log" STUB_STDIN_LOG="$T/ack-stdin.log" \
            "$@" \
            bash "$file"
    ) >"$T/out" 2>"$T/err"
}

# run_ack <mode-or-LITERAL> [VAR=value ...] — the whole acceptance-check fence in
# ONE shell, as the step says to run it, with WORK set to the head. LITERAL leaves
# {{acceptance_check}} unrendered, as a root-only pour without the rig's var does.
# The stub's logs are emptied first, so a case can run the fence more than once.
run_ack() {
    local mode="$1" opt
    shift
    if [ "$mode" = LITERAL ]; then opt=leave:acceptance_check; else opt="set:acceptance_check=$mode"; fi
    extract_block acceptance-check acceptance-check "$T/ack.sh" "$opt" ||
        { fail "could not extract the acceptance-check fence"; return 1; }
    : >"$T/ack.log"
    : >"$T/ack-stdin.log"
    run_block "$T/ack.sh" WORK="$HEAD_ID" "$@"
}

ack_calls() { cat "$T/ack.log"; }

# write_manifest — what find-work writes for a two-member batch.
write_manifest() {
    jq -n --arg head "$HEAD_ID" --arg second "$SECOND_ID" \
        '{head: $head, members: [{id: $head}, {id: $second}]}' >"$MANIFEST"
}

# write_manifest_of <id>... — what find-work and stack write for a batch: the head
# first, and the fields stack records beside the members.
write_manifest_of() {
    local members
    members=$(printf '%s\n' "$@" |
        jq -R '{id: ., branch: ("polecat/" + .), tip: "t1", commits: 1, patch_id: "p1"}' | jq -s .)
    jq -n --arg head "$1" --argjson members "$members" \
        '{head: $head, target: "main", base: "b0", members: $members}' >"$MANIFEST"
}

# run_rej <mode-or-LITERAL> [VAR=value ...] — the acceptance-reject block in ONE
# shell, with WORK set to the head. LITERAL leaves {{acceptance_check}} unrendered.
# The stub's journal is emptied first, so a case can run the block more than once.
run_rej() {
    local mode="$1" opt
    shift
    if [ "$mode" = LITERAL ]; then opt=leave:acceptance_check; else opt="set:acceptance_check=$mode"; fi
    extract_block acceptance-reject acceptance-reject "$T/rej.sh" "$opt" ||
        { fail "could not extract the acceptance-reject block"; return 1; }
    : >"$T/gc.log"
    run_block "$T/rej.sh" WORK="$HEAD_ID" "$@"
}

# --- reading the formula ------------------------------------------------------------

# formula_steps <formula> — "<id> <needs-json>" per step, in order.
formula_steps() {
    python3 - "$1" <<'PY'
import json
import sys
import tomllib

with open(sys.argv[1], "rb") as handle:
    for step in tomllib.load(handle)["steps"]:
        print(step["id"], json.dumps(step.get("needs")))
PY
}

# formula_var <formula> <var> <key> — [vars.<var>].<key>, read through tomllib.
formula_var() {
    python3 - "$@" <<'PY'
import sys
import tomllib

with open(sys.argv[1], "rb") as handle:
    print(tomllib.load(handle)["vars"][sys.argv[2]][sys.argv[3]])
PY
}

# rubric_in_formula <formula> <rubric-file> — true when the acceptance-check step's
# description holds the rubric byte for byte (the file's trailing newline aside).
rubric_in_formula() {
    python3 - "$@" <<'PY'
import sys
import tomllib

formula, rubric_file = sys.argv[1:]
with open(formula, "rb") as handle:
    steps = {s["id"]: s for s in tomllib.load(handle)["steps"]}
with open(rubric_file, encoding="utf-8") as handle:
    rubric = handle.read().rstrip("\n")
if not rubric:
    sys.exit("the rubric file is empty, so this check would pass vacuously")
sys.exit(0 if rubric in steps["acceptance-check"]["description"] else 1)
PY
}

# step_text_in_order <formula> <file>... — true when the acceptance-check step's
# description holds each file's text byte for byte, in the order given.
step_text_in_order() {
    python3 - "$@" <<'PY'
import sys
import tomllib

formula, *files = sys.argv[1:]
with open(formula, "rb") as handle:
    steps = {s["id"]: s for s in tomllib.load(handle)["steps"]}
desc = steps["acceptance-check"]["description"]
pos = -1
for name in files:
    with open(name, encoding="utf-8") as handle:
        text = handle.read().rstrip("\n")
    if not text:
        sys.exit(f"{name} is empty, so this check would pass vacuously")
    at = desc.find(text, pos + 1)
    if at < 0:
        sys.exit(f"{name}: not in the description after offset {pos}")
    pos = at
PY
}

# summary_bullet_follows <formula> — true when patrol-summary's description has the
# acceptance bullet immediately after its test-results bullet.
summary_bullet_follows() {
    python3 - "$1" <<'PY'
import sys
import tomllib

with open(sys.argv[1], "rb") as handle:
    steps = {s["id"]: s for s in tomllib.load(handle)["steps"]}
lines = steps["patrol-summary"]["description"].split("\n")
want = "- Acceptance check: each member's verdict (CONFORMS, DECLARED, MISS or SKIP), any WARN or record exit 1 or 2, and in reject mode each LEFT and HEAD LEFT line"
i = lines.index("- Test results (pass/fail, which checks ran)")
sys.exit(0 if lines[i + 1] == want else 1)
PY
}

# pour_copy_matches <formula> — true when the acceptance-check step's description
# holds, after the acceptance-reject:end sentinel, a fenced bash block byte for byte
# equal to the rebase step's conflict-path pour-and-burn block: the one whose first
# line is CURRENT_WISP=${GC_BEAD_ID:-}, from its ```bash line to its closing fence.
pour_copy_matches() {
    python3 - "$1" <<'PY'
import sys
import tomllib

with open(sys.argv[1], "rb") as handle:
    steps = {s["id"]: s for s in tomllib.load(handle)["steps"]}
opener = "```bash\nCURRENT_WISP=${GC_BEAD_ID:-}\n"


def fenced(text, start):
    at = text.find(opener, start)
    if at < 0:
        sys.exit("no pour block found")
    end = text.find("\n```", at + len(opener))
    if end < 0:
        sys.exit("the pour block has no closing fence")
    return text[at:end + len("\n```")]


rebase = steps["rebase"]["description"]
ack = steps["acceptance-check"]["description"]
if rebase.count(opener) != 1:
    sys.exit(f"want exactly one pour block in the rebase step, found {rebase.count(opener)}")
sentinel = "# --- acceptance-reject:end ---"
if ack.count(sentinel) != 1:
    sys.exit("want exactly one acceptance-reject:end sentinel in the acceptance-check step")
if ack.count(opener) != 1:
    sys.exit(f"want exactly one pour block in the acceptance-check step, found {ack.count(opener)}")
at = ack.index(sentinel)
if ack.index(opener) < at:
    sys.exit("the pour block sits before the acceptance-reject:end sentinel")
if fenced(ack, at) != fenced(rebase, 0):
    sys.exit("the acceptance-check step's pour block differs from the rebase step's")
PY
}

# --- the shipped text, to the byte -------------------------------------------------

# The rubric is DESIGN section 5 of gcp-s7j4, measured as written: changing a word
# means re-running the measurement, so a word changed in the formula is a failure
# here, not a refactor.
write_rubric() {
    cat >"$1" <<'EXPECTED_RUBRIC'
Acceptance read. For each packet, decide whether the branch delivers every acceptance item
that names test work, exactly as written.

For each AC item:
- SKIP an item that is only a command to run (exits 0, typecheck, lint), a red->green
  citation, a seat's post-merge check, or product code with no test named. The gate covers
  commands.
- For an item that names test work, find the added or changed test that does it and compare
  it LITERALLY with the AC: every named file; the named case; its SETUP (which call is failed
  or held: first vs second; which input value: 0 vs 47; what order); and its ASSERTION (what
  is asserted, at which moment).

Per-item verdicts:
- OK: the diff has it as written.
- MISSING: a named test, file or case is absent from the diff. A file the AC names only as
  one that must keep passing or stay unchanged ("existing X still passes") is NOT missing
  when it is absent. NOT-IN-DIFF in the packet is evidence, not a verdict: read the AC
  sentence that names the file.
- SUBSTITUTED: a test exists but its setup or assertion differs from what the AC names, even
  when it plausibly catches the same bug.
- DECLARED: MISSING or SUBSTITUTED, but the polecat's notes say so explicitly before handoff:
  they name the AC item, say what was done instead, and say why. A note that only describes
  what was done, without saying it departs from the AC, is NOT a declaration. A note claiming
  "all AC written / literal" is a claim to check, never evidence.

Bead verdict: MISS if any item is MISSING or SUBSTITUTED; else DECLARED if any item is
DECLARED; else CONFORMS. When unsure whether an item departs, read more of the diff before
deciding; do not guess MISS.

You may read more of the branch with `git diff <base> <tip> -- <path>` or
`git show <tip>:<path>`, using the base and tip on the packet's first line. Before you record
MISS for an item, read the bead's full notes (`gc bd show <id> --json | jq -r '.[0].notes'`)
for a declaration of that item.

Your per-item lines are record's stdin, one per AC item:
AC<n> <OK|MISSING|SUBSTITUTED|DECLARED|SKIP> — <the AC phrase> | <evidence: file:line, or "absent">
EXPECTED_RUBRIC
}

write_sentence() {
    cat >"$1" <<'EXPECTED_SENTENCE'
Run the fence in ONE shell, with `$WORK` set to the work bead find-work found.
EXPECTED_SENTENCE
}

write_fence() {
    cat >"$1" <<'EXPECTED_FENCE'
# --- acceptance-check:begin ---
ACK_MODE="{{acceptance_check}}"
case "$ACK_MODE" in
  off) echo "acceptance check: off" ;;
  warn | reject) ;;
  *)
    echo "INFO: acceptance_check='$ACK_MODE' is not off, warn or reject; check off."
    ACK_MODE=off
    ;;
esac
if [ "$ACK_MODE" != off ]; then
  ACK_DIR="$(git rev-parse --git-dir)/acceptance"
  mkdir -p "$ACK_DIR" && rm -f "${ACK_DIR:?}"/*.packet "${ACK_DIR:?}"/*.err "${ACK_DIR:?}/script.path"
  ACK_CITY="${GC_CITY:-${GC_CITY_PATH:-}}"
  if [ -n "$ACK_CITY" ]; then
    ACK_FORMULA_JSON=$(gc formula list --city "$ACK_CITY" --json 2>/dev/null)
  else
    ACK_FORMULA_JSON=$(gc formula list --json 2>/dev/null)
  fi
  ACK_FORMULA_SRC=$(printf '%s' "$ACK_FORMULA_JSON" \
    | jq -r '.formulas[]? | select(.name == "mol-refinery-patrol") | .source // empty' 2>/dev/null \
    | head -1)
  ACK=""
  if [ -n "$ACK_FORMULA_SRC" ]; then
    ACK="$(dirname "$(dirname "$ACK_FORMULA_SRC")")/assets/scripts/refinery/acceptance-check.sh"
  fi
  if [ ! -x "$ACK" ] && [ -n "${GC_PACK_DIR:-}" ]; then
    ACK="$GC_PACK_DIR/assets/scripts/refinery/acceptance-check.sh"
  fi
  if [ ! -x "$ACK" ]; then
    echo "WARN: acceptance-check.sh not runnable (resolved '$ACK'); acceptance check skipped this iteration."
  else
    printf '%s\n' "$ACK" >"$ACK_DIR/script.path"
    git fetch --prune origin
    ACK_IDS="$WORK"
    ACK_MANIFEST="$(git rev-parse --git-dir)/refinery-batch.json"
    if [ -f "$ACK_MANIFEST" ]; then
      ACK_MEMBERS=$(jq -r '.members | if type == "array" then .[].id else empty end' "$ACK_MANIFEST" 2>/dev/null)
      [ -n "$ACK_MEMBERS" ] && ACK_IDS="$ACK_MEMBERS"
    fi
    for ACK_ID in $ACK_IDS; do
      ACK_OUT=$("$ACK" packet --work "$ACK_ID" 2>"$ACK_DIR/$ACK_ID.err")
      ACK_RC=$?
      if [ "$ACK_RC" -eq 0 ]; then
        printf '%s\n' "$ACK_OUT" >"$ACK_DIR/$ACK_ID.packet"
        echo "READ $ACK_DIR/$ACK_ID.packet ($(wc -c <"$ACK_DIR/$ACK_ID.packet" | tr -d ' ') chars)"
      elif [ "$ACK_RC" -eq 3 ]; then
        printf '%s\n' "$ACK_OUT"
        ACK_CODE=$(printf '%s\n' "$ACK_OUT" | awk '{print $4}')
        ACK_TIP=$(printf '%s\n' "$ACK_OUT" | sed -n 's/.* tip=//p')
        case "$ACK_CODE" in
          no-ac | no-change) "$ACK" record --work "$ACK_ID" --verdict SKIP --tip "$ACK_TIP" --mode "$ACK_MODE" </dev/null ;;
          already-judged) ;;
          *) echo "WARN: acceptance check for $ACK_ID: $ACK_CODE; not checked." ;;
        esac
      else
        echo "WARN: acceptance check for $ACK_ID: packet exit $ACK_RC; not checked (see $ACK_DIR/$ACK_ID.err)."
      fi
    done
  fi
fi
# --- acceptance-check:end ---
EXPECTED_FENCE
}

# The prose after the fence, in the three pieces D11 gives it. The reject block
# (case_reject_block) and the pour-and-burn (case_head_left_pour) sit between them.
write_prose_before_block() {
    cat >"$1" <<'EXPECTED_PROSE'
For each `READ` line, in the order printed: read that packet in full (`cat` it, one packet per command), apply
the rubric below, then record your verdict with ONE command, the per-item lines as a quoted heredoc:
```bash
"$(cat "$(git rev-parse --git-dir)/acceptance/script.path")" record --work <id> --verdict <CONFORMS|DECLARED|MISS> --tip <the tip= value on the packet's PACKET line> --mode {{acceptance_check}} <<'ACK_ITEMS'
<one line per AC item, in the rubric's output format>
ACK_ITEMS
```
A `record` that exits 1 or 2 is a WARN: name it in patrol-summary and proceed. With no `READ` line, close this
step and proceed to rebase.

After the last `record`, run this block ONCE, in one shell, with `$WORK` set as above. Outside reject mode it
prints nothing and changes nothing. In reject mode `record` has already returned each MISS to the polecat pool,
and this block takes every bead no longer assigned to you out of this iteration:
```bash
EXPECTED_PROSE
}

write_prose_between() {
    cat >"$1" <<'EXPECTED_PROSE'
```
If it printed `HEAD LEFT: <id>`, this iteration has no head. Pour the next iteration and burn this one, exactly as
a rebase conflict does, then close this step:
```bash
EXPECTED_PROSE
}

write_prose_after_pour() {
    cat >"$1" <<'EXPECTED_PROSE'
```
Otherwise close this step and proceed to rebase, whatever the verdicts. `stack` takes the batch as the block
left it.
EXPECTED_PROSE
}

# --- cases --------------------------------------------------------------------------

case_steps_and_needs() {
    new_case steps_and_needs
    local want got
    want=$(printf '%s\n' \
        'validate-identity null' \
        'check-inbox ["validate-identity"]' \
        'find-work ["check-inbox"]' \
        'acceptance-check ["find-work"]' \
        'rebase ["acceptance-check"]' \
        'run-tests ["rebase"]' \
        'handle-failures ["run-tests"]' \
        'merge-push ["handle-failures"]' \
        'patrol-summary ["merge-push"]' \
        'next-iteration ["patrol-summary"]')
    got=$(formula_steps "$FORMULA") || fail "could not read the formula's steps"
    assert_eq "step ids and needs" "$want" "$got"
    end_case
}

case_var() {
    new_case var
    local desc word
    assert_eq "[vars.acceptance_check].default" off "$(formula_var "$FORMULA" acceptance_check default)"
    desc=$(formula_var "$FORMULA" acceptance_check description)
    for word in off warn reject; do
        case "$desc" in
        *"$word"*) ;;
        *) fail "[vars.acceptance_check].description does not contain '$word'" ;;
        esac
    done
    end_case
}

case_unrendered() {
    new_case unrendered
    run_ack LITERAL
    assert_eq "block status" 0 "$?"
    grep -q '{{acceptance_check}}' "$T/ack.sh" ||
        fail "harness bug: the fence has no {{acceptance_check}} to leave unrendered"
    assert_eq "stdout" "INFO: acceptance_check='{{acceptance_check}}' is not off, warn or reject; check off." "$(cat "$T/out")"
    ! grep -q 'WARN' "$T/err" || fail "an unrendered acceptance_check printed a WARN on stderr"
    assert_eq "script argv log" "" "$(ack_calls)"
    ! grep -q 'formula list' "$T/gc.log" || fail "an unrendered acceptance_check resolved the script"
    end_case
}

case_off() {
    new_case off
    run_ack off
    assert_eq "block status" 0 "$?"
    assert_eq "stdout" "acceptance check: off" "$(cat "$T/out")"
    assert_eq "script argv log" "" "$(ack_calls)"
    [ ! -e "$ACK_DIR_PATH" ] || fail "off mode created $ACK_DIR_PATH"
    end_case
}

case_warn_single() {
    new_case warn_single
    # A branch that reaches origin after the clone: only a fetch brings it in.
    git clone -q "$T/origin.git" "$T/other"
    git -C "$T/other" checkout -q -b polecat/wa-fetched
    git -C "$T/other" commit -q --allow-empty -m fetched
    git -C "$T/other" push -q origin polecat/wa-fetched
    git -C "$T/repo" rev-parse --verify -q refs/remotes/origin/polecat/wa-fetched >/dev/null &&
        fail "harness bug: the clone already has the branch the fence must fetch"

    run_ack warn
    assert_eq "block status" 0 "$?"
    assert_eq "script argv log" "packet --work $HEAD_ID" "$(ack_calls)"
    assert_eq "packet file" "$(printf 'acceptance-check: PACKET %s\nbody' "$HEAD_ID")" \
        "$(cat "$ACK_DIR_PATH/$HEAD_ID.packet" 2>/dev/null)"
    local n
    n=$(wc -c <"$ACK_DIR_PATH/$HEAD_ID.packet" 2>/dev/null | tr -d ' ')
    assert_eq "READ lines" 1 "$(grep -c '^READ ' "$T/out")"
    assert_eq "READ line" "READ .git/acceptance/$HEAD_ID.packet ($n chars)" "$(grep '^READ ' "$T/out")"
    assert_eq "script.path" "$ACK_STUB" "$(cat "$ACK_DIR_PATH/script.path" 2>/dev/null)"
    git -C "$T/repo" rev-parse --verify -q refs/remotes/origin/polecat/wa-fetched >/dev/null ||
        fail "the fence did not fetch: origin/polecat/wa-fetched is absent from the clone"
    end_case
}

case_warn_batch() {
    new_case warn_batch
    write_manifest
    local before after
    before=$(cksum <"$MANIFEST")
    run_ack warn
    assert_eq "block status" 0 "$?"
    assert_eq "script argv log" "$(printf 'packet --work %s\npacket --work %s' "$HEAD_ID" "$SECOND_ID")" "$(ack_calls)"
    assert_eq "READ lines" \
        "$(printf 'READ .git/acceptance/%s.packet\nREAD .git/acceptance/%s.packet' "$HEAD_ID" "$SECOND_ID")" \
        "$(grep '^READ ' "$T/out" | sed 's/ ([0-9]* chars)$//')"
    after=$(cksum <"$MANIFEST")
    assert_eq "refinery-batch.json checksum" "$before" "$after"
    end_case
}

case_skip_codes() {
    new_case skip_codes
    local code line
    for code in no-ac no-change; do
        line="acceptance-check: SKIP $HEAD_ID $code tip=abc123"
        run_ack warn STUB_PACKET_STATUS=3 STUB_PACKET_OUT="$line"
        assert_eq "$code: block status" 0 "$?"
        assert_eq "$code: script argv log" \
            "$(printf 'packet --work %s\nrecord --work %s --verdict SKIP --tip abc123 --mode warn' "$HEAD_ID" "$HEAD_ID")" "$(ack_calls)"
        assert_eq "$code: record stdin" 0 "$(wc -c <"$T/ack-stdin.log" | tr -d ' ')"
        [ ! -e "$ACK_DIR_PATH/$HEAD_ID.packet" ] || fail "$code: a packet file exists for a SKIP"
    done

    line="acceptance-check: SKIP $HEAD_ID already-judged tip=abc123"
    run_ack warn STUB_PACKET_STATUS=3 STUB_PACKET_OUT="$line"
    assert_eq "already-judged: block status" 0 "$?"
    assert_eq "already-judged: script argv log" "packet --work $HEAD_ID" "$(ack_calls)"
    grep -qxF "$line" "$T/out" || fail "already-judged: stdout lacks the SKIP line"
    ! grep -q 'WARN' "$T/out" || fail "already-judged: stdout has a WARN"
    [ ! -e "$ACK_DIR_PATH/$HEAD_ID.packet" ] || fail "already-judged: a packet file exists for a SKIP"

    line="acceptance-check: SKIP $HEAD_ID no-branch tip=none"
    run_ack warn STUB_PACKET_STATUS=3 STUB_PACKET_OUT="$line"
    assert_eq "no-branch: block status" 0 "$?"
    assert_eq "no-branch: script argv log" "packet --work $HEAD_ID" "$(ack_calls)"
    grep -qxF "WARN: acceptance check for $HEAD_ID: no-branch; not checked." "$T/out" ||
        fail "no-branch: stdout lacks the WARN line"
    [ ! -e "$ACK_DIR_PATH/$HEAD_ID.packet" ] || fail "no-branch: a packet file exists for a SKIP"
    end_case
}

case_packet_error() {
    new_case packet_error
    run_ack warn STUB_PACKET_STATUS=1
    assert_eq "block status" 0 "$?"
    assert_eq "script argv log" "packet --work $HEAD_ID" "$(ack_calls)"
    grep -qxF "WARN: acceptance check for $HEAD_ID: packet exit 1; not checked (see .git/acceptance/$HEAD_ID.err)." "$T/out" ||
        fail "stdout lacks the packet-exit WARN line"
    [ ! -e "$ACK_DIR_PATH/$HEAD_ID.packet" ] || fail "a packet file exists for a failed packet"
    end_case
}

case_reject_mode() {
    new_case reject_mode
    write_manifest
    local before after
    before=$(cksum <"$MANIFEST")
    run_ack reject
    assert_eq "block status" 0 "$?"
    ! grep -q 'not built yet' "$T/out" || fail "stdout still says reject is not built yet"
    assert_eq "script argv log" "$(printf 'packet --work %s\npacket --work %s' "$HEAD_ID" "$SECOND_ID")" "$(ack_calls)"
    assert_eq "READ lines" \
        "$(printf 'READ .git/acceptance/%s.packet\nREAD .git/acceptance/%s.packet' "$HEAD_ID" "$SECOND_ID")" \
        "$(grep '^READ ' "$T/out" | sed 's/ ([0-9]* chars)$//')"
    after=$(cksum <"$MANIFEST")
    assert_eq "refinery-batch.json checksum" "$before" "$after"

    # A SKIP is recorded with the mode the fence runs in.
    rm -f "$MANIFEST"
    run_ack reject STUB_PACKET_STATUS=3 STUB_PACKET_OUT="acceptance-check: SKIP $HEAD_ID no-ac tip=abc123"
    assert_eq "no-ac: block status" 0 "$?"
    assert_eq "no-ac: script argv log" \
        "$(printf 'packet --work %s\nrecord --work %s --verdict SKIP --tip abc123 --mode reject' "$HEAD_ID" "$HEAD_ID")" "$(ack_calls)"
    end_case
}

case_not_runnable() {
    new_case not_runnable
    rm -f "$ACK_STUB"
    run_ack warn
    assert_eq "block status" 0 "$?"
    grep -q "^WARN: acceptance-check.sh not runnable (resolved '" "$T/out" ||
        fail "stdout lacks the not-runnable WARN line"
    [ ! -e "$ACK_DIR_PATH/script.path" ] || fail "script.path exists with no runnable script"
    end_case
}

case_stale_files() {
    new_case stale_files
    mkdir -p "$ACK_DIR_PATH"
    : >"$ACK_DIR_PATH/old.packet"
    : >"$ACK_DIR_PATH/old.err"
    printf '%s\n' /nonexistent >"$ACK_DIR_PATH/script.path"
    run_ack warn
    assert_eq "block status" 0 "$?"
    [ ! -e "$ACK_DIR_PATH/old.packet" ] || fail "old.packet survived the run"
    [ ! -e "$ACK_DIR_PATH/old.err" ] || fail "old.err survived the run"
    assert_eq "script.path" "$ACK_STUB" "$(cat "$ACK_DIR_PATH/script.path" 2>/dev/null)"
    end_case
}

case_rubric_verbatim() {
    new_case rubric_verbatim
    write_rubric "$T/rubric.txt"
    rubric_in_formula "$FORMULA" "$T/rubric.txt" ||
        fail "the acceptance-check step's description does not hold the rubric byte for byte"

    # The check must be able to FAIL: change one word of a copy of the formula.
    [ "$(grep -c 'LITERALLY' "$FORMULA")" -eq 1 ] ||
        fail "harness bug: the formula must hold LITERALLY exactly once, in the rubric"
    sed 's/LITERALLY/loosely/' "$FORMULA" >"$T/formula-loosely.toml"
    cmp -s "$FORMULA" "$T/formula-loosely.toml" && fail "harness bug: the formula copy was not changed"
    ! rubric_in_formula "$T/formula-loosely.toml" "$T/rubric.txt" ||
        fail "the rubric check passed with LITERALLY changed to loosely"
    end_case
}

case_prose() {
    new_case prose
    write_sentence "$T/sentence.txt"
    write_fence "$T/fence.txt"
    write_prose_before_block "$T/prose-before.txt"
    write_prose_between "$T/prose-between.txt"
    write_prose_after_pour "$T/prose-after.txt"
    write_rubric "$T/rubric.txt"
    step_text_in_order "$FORMULA" "$T/sentence.txt" "$T/fence.txt" "$T/prose-before.txt" \
        "$T/prose-between.txt" "$T/prose-after.txt" "$T/rubric.txt" ||
        fail "the acceptance-check step lacks the sentence, fence, prose and rubric, byte for byte and in that order"
    summary_bullet_follows "$FORMULA" ||
        fail "patrol-summary lacks the acceptance bullet right after its test-results bullet"

    # The check must be able to FAIL: swap the order of the files it is given.
    ! step_text_in_order "$FORMULA" "$T/prose-before.txt" "$T/fence.txt" 2>/dev/null ||
        fail "the order check passed with the prose before the fence"
    end_case
}

# rm_unguarded <formula> — "<line>:<text>" for each rm command whose target starts with
# `"$` and then a letter, underscore or `(`: an unguarded variable or command
# substitution. Claude Code's built-in safety check denies such an rm unless a person
# approves it, and a refinery session has none, so a session hand-edits the fence
# before it runs (gcp-s7j4.6). `"${NAME:?}"` is the form the check exempts.
rm_unguarded() {
    grep -nE '(^|[;&|(]|then|do|else)[[:space:]]*rm[[:space:]][^;&|]*"\$[A-Za-z_(]' "$1"
}

case_rm_targets_guarded() {
    new_case rm_targets_guarded
    local found
    found=$(rm_unguarded "$FORMULA")
    if [ -n "$found" ]; then
        fail "rm commands with an unguarded target; write \"\${NAME:?}\" (line:text):
$found"
        end_case
        return
    fi

    # The check must be able to FAIL: unguard one target in a copy of the formula.
    local guarded="\"\${ACK_DIR:?}\"/*.packet" unguarded="\"\$ACK_DIR\"/*.packet" text
    text=$(<"$FORMULA")
    case "$text" in
        *"$guarded"*) ;;
        *) fail "harness bug: the acceptance-check fence's rm no longer holds $guarded" ;;
    esac
    printf '%s\n' "${text//"$guarded"/"$unguarded"}" >"$T/formula-unguarded.toml"
    cmp -s "$FORMULA" "$T/formula-unguarded.toml" && fail "harness bug: the formula copy was not changed"
    [ -n "$(rm_unguarded "$T/formula-unguarded.toml")" ] ||
        fail "the guard check passed with an rm target unguarded"
    end_case
}

# The acceptance-reject block: after the last record it takes every bead the
# refinery no longer holds out of the iteration. R is the refinery agent.
case_reject_block() {
    new_case reject_block
    local R="$REFINERY_AGENT" before members other_before

    # a. Not reject: nothing is read, said or changed.
    write_manifest_of "$HEAD_ID" "$SECOND_ID" "$THIRD_ID"
    before=$(cksum <"$MANIFEST")
    run_rej warn GC_STUB_ASSIGNEES="$SECOND_ID="
    assert_eq "a. block status" 0 "$?"
    assert_eq "a. stdout" "" "$(cat "$T/out")"
    ! grep -q 'bd show' "$T/gc.log" || fail "a. a warn run read a bead"
    assert_eq "a. the manifest" "$before" "$(cksum <"$MANIFEST")"
    run_rej LITERAL GC_STUB_ASSIGNEES="$SECOND_ID="
    assert_eq "a. unrendered: block status" 0 "$?"
    assert_eq "a. unrendered: stdout" "" "$(cat "$T/out")"
    assert_eq "a. unrendered: no gc call" "" "$(cat "$T/gc.log")"
    assert_eq "a. unrendered: the manifest" "$before" "$(cksum <"$MANIFEST")"

    # b. Reject, and every bead is still the refinery's.
    run_rej reject GC_STUB_ASSIGNEES="$HEAD_ID=$R $SECOND_ID=$R $THIRD_ID=$R"
    assert_eq "b. block status" 0 "$?"
    assert_eq "b. stdout" "" "$(cat "$T/out")"
    assert_eq "b. the manifest" "$before" "$(cksum <"$MANIFEST")"

    # c. A member left: it is cut from the manifest and nothing else changes.
    other_before=$(jq -cS 'del(.members)' "$MANIFEST")
    members=$(jq -cS --arg gone "$SECOND_ID" '[.members[] | select(.id != $gone)]' "$MANIFEST")
    run_rej reject GC_STUB_ASSIGNEES="$SECOND_ID="
    assert_eq "c. block status" 0 "$?"
    assert_eq "c. stdout" "LEFT: $SECOND_ID (assignee now '')
BATCH: $HEAD_ID $THIRD_ID" "$(cat "$T/out")"
    assert_eq "c. .head" "$HEAD_ID" "$(jq -r .head "$MANIFEST")"
    assert_eq "c. .members[].id" "$HEAD_ID
$THIRD_ID" "$(jq -r '.members[].id' "$MANIFEST")"
    assert_eq "c. every other field" "$other_before" "$(jq -cS 'del(.members)' "$MANIFEST")"
    assert_eq "c. the surviving members, whole" "$members" "$(jq -cS .members "$MANIFEST")"

    # d. Down to the head alone: the manifest goes.
    write_manifest
    run_rej reject GC_STUB_ASSIGNEES="$SECOND_ID="
    assert_eq "d. block status" 0 "$?"
    [ ! -e "$MANIFEST" ] || fail "d. the manifest survived a batch of 1"
    assert_eq "d. the last line" "INFO: batch of 1." "$(tail -n 1 "$T/out")"

    # e. The head left: the manifest goes, and HEAD LEFT is the last line.
    write_manifest_of "$HEAD_ID" "$SECOND_ID" "$THIRD_ID"
    run_rej reject GC_STUB_ASSIGNEES="$HEAD_ID="
    assert_eq "e. block status" 0 "$?"
    [ ! -e "$MANIFEST" ] || fail "e. the manifest survived a head that left"
    assert_eq "e. the last line" "HEAD LEFT: $HEAD_ID" "$(tail -n 1 "$T/out")"
    grep -qxF "LEFT: $HEAD_ID (assignee now '')" "$T/out" || fail "e. stdout lacks the LEFT line for the head"

    # f. No manifest: the head is $WORK.
    run_rej reject GC_STUB_ASSIGNEES="$HEAD_ID="
    assert_eq "f. block status" 0 "$?"
    assert_eq "f. the last line" "HEAD LEFT: $HEAD_ID" "$(tail -n 1 "$T/out")"
    [ ! -e "$MANIFEST" ] || fail "f. a manifest appeared"

    # g. A read that fails keeps the bead in the iteration.
    write_manifest_of "$HEAD_ID" "$SECOND_ID" "$THIRD_ID"
    before=$(cksum <"$MANIFEST")
    run_rej reject GC_STUB_FAIL_SHOW="$SECOND_ID" GC_STUB_ASSIGNEES="$SECOND_ID="
    assert_eq "g. block status" 0 "$?"
    assert_eq "g. stdout" "WARN: could not read $SECOND_ID; it stays in this iteration." "$(cat "$T/out")"
    assert_eq "g. the manifest" "$before" "$(cksum <"$MANIFEST")"
    end_case
}

# The pour-and-burn for a head that left is the rebase conflict path's, byte for
# byte (D10), so the iteration advances the way a rebase conflict advances it.
case_head_left_pour() {
    new_case head_left_pour
    pour_copy_matches "$FORMULA" ||
        fail "the acceptance-check step lacks a pour-and-burn block equal to the rebase step's, after the acceptance-reject:end sentinel"

    # The check must be able to FAIL: change one character of the copy.
    python3 - "$FORMULA" "$T/formula-altered.toml" <<'PY' || fail "harness bug: could not alter the copy"
import sys

text = open(sys.argv[1], encoding="utf-8").read()
at = text.index("# --- acceptance-reject:end ---")
old = "gc bd mol burn"
cut = text.index(old, at)
open(sys.argv[2], "w", encoding="utf-8").write(text[:cut] + "gc bd mol bur_" + text[cut + len(old):])
PY
    cmp -s "$FORMULA" "$T/formula-altered.toml" && fail "harness bug: the formula copy was not changed"
    ! pour_copy_matches "$T/formula-altered.toml" 2>/dev/null ||
        fail "the pour-copy check passed with one character of the copy changed"
    end_case
}

case_steps_and_needs
case_var
case_unrendered
case_off
case_warn_single
case_warn_batch
case_skip_codes
case_packet_error
case_reject_mode
case_not_runnable
case_stale_files
case_rubric_verbatim
case_prose
case_rm_targets_guarded
case_reject_block
case_head_left_pour

if [ "$PASS_CASES" -ne "$EXPECTED_CASES" ]; then
    echo "FAIL: $PASS_CASES of $EXPECTED_CASES cases ran" >&2
    exit 1
fi
if [ "$FAILURES" -ne 0 ]; then
    echo "FAIL: $FAILURES assertion(s) failed across $PASS_CASES cases" >&2
    exit 1
fi
echo "OK: $PASS_CASES cases passed"
