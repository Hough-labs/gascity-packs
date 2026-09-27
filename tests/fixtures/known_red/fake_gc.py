#!/usr/bin/env python3
"""A stand-in `gc` for known-red's tests. It never touches a real ledger.

It is installed on PATH as `gc` and answers only `gc bd ...`: any other first
argument is logged and refused, so a test sees a call that was not routed
through `gc bd`. Past that it models the ledger verbs known-red uses.

State lives in $FAKE_GC_DB (JSON); every call is appended to $FAKE_GC_LOG as a
JSON argv line (including the leading "bd"), so tests can assert on exactly
what known-red asked for.

  FAKE_GC_FAIL=1             every call exits 1 (ledger unreachable)
  FAKE_GC_FAIL_ON=<cmd>      only calls to that ledger verb exit 1
  FAKE_GC_CORRUPT_METADATA=1 update stores metadata as a JSON *string*, the
                             shape that freezes a rig's pool creates
"""
import json
import os
import sys
from datetime import datetime, timezone

with open(os.environ["FAKE_GC_LOG"], "a") as fh:
    fh.write(json.dumps(sys.argv[1:]) + "\n")
if len(sys.argv) < 2 or sys.argv[1] != "bd":
    print(f"fake gc: known-red must call `gc bd ...`, got {sys.argv[1:]}", file=sys.stderr)
    sys.exit(64)
argv = sys.argv[2:]
if os.environ.get("FAKE_GC_FAIL") or (argv and argv[0] == os.environ.get("FAKE_GC_FAIL_ON")):
    print("Error: failed to connect to dolt server at 127.0.0.1:3307", file=sys.stderr)
    sys.exit(1)

DB = os.environ["FAKE_GC_DB"]
with open(DB) as fh:
    db = json.load(fh)


def save():
    with open(DB, "w") as fh:
        json.dump(db, fh, indent=1)


def opt(name, default=None):
    """Last occurrence wins, as in the real ledger CLI (a repeated --status is NOT a union)."""
    val = default
    for i, a in enumerate(argv):
        if a == name and i + 1 < len(argv):
            val = argv[i + 1]
        elif a.startswith(name + "="):
            val = a.split("=", 1)[1]
    return val


def opts(name):
    return [argv[i + 1] for i, a in enumerate(argv) if a == name and i + 1 < len(argv)]


def to_json_value(s):
    """toJSONValue: numbers, booleans and null lose their string type."""
    if s in ("null", "true", "false"):
        return json.loads(s)
    try:
        return json.loads(s) if isinstance(json.loads(s), (int, float)) else s
    except ValueError:
        return s


def ts(s):
    return datetime.fromisoformat(s.replace("Z", "+00:00"))


cmd = argv[0] if argv else ""
if cmd == "config" and argv[1:3] == ["get", "issue_prefix"]:
    print(db.get("prefix", "winnow"))
elif cmd == "list":
    label, status = opt("--label"), opt("--status")
    after = opt("--closed-after")
    rows = []
    for b in db["beads"].values():
        if label and label not in (b.get("labels") or []):
            continue
        if status and b["status"] not in status.split(","):
            continue
        if after and not (b.get("closed_at") and ts(b["closed_at"]) > ts(after)):
            continue
        rows.append(b)
    print(json.dumps(rows))
elif cmd == "show":
    b = db["beads"].get(argv[1])
    if not b:
        print(f"Error: no issue found matching {argv[1]!r}", file=sys.stderr)
        sys.exit(1)
    print(json.dumps([b]))
elif cmd == "create":
    db["next"] = db.get("next", 0) + 1
    bid = f"{db.get('prefix', 'winnow')}-fk{db['next']}"
    body = ""
    if opt("--body-file"):
        with open(opt("--body-file")) as fh:
            body = fh.read()
    db["beads"][bid] = {
        "id": bid, "title": opt("--title"), "status": "open",
        "priority": int(opt("-p", "2")), "issue_type": opt("--type", "task"),
        "labels": [x for x in (opt("--labels") or "").split(",") if x],
        "metadata": None, "description": body,
        "created_at": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    }
    save()
    print(bid if "--silent" in argv else f"✓ Created issue: {bid}")
elif cmd == "update":
    b = db["beads"].get(argv[1])
    if not b:
        print(f"Error: no issue found matching {argv[1]!r}", file=sys.stderr)
        sys.exit(1)
    if "--metadata" in argv:
        print("Error: known-red must never write whole-object --metadata", file=sys.stderr)
        sys.exit(3)
    md = b.get("metadata")
    if isinstance(md, str):
        print(f"Error: metadata edit failed for {argv[1]}: existing metadata is not a JSON object", file=sys.stderr)
        sys.exit(1)
    md = dict(md or {})
    for kv in opts("--set-metadata"):
        k, v = kv.split("=", 1)
        md[k] = to_json_value(v)
    b["metadata"] = json.dumps(md) if os.environ.get("FAKE_GC_CORRUPT_METADATA") else md
    for lab in opts("--add-label"):
        b["labels"] = sorted(set((b.get("labels") or []) + [lab]))
    save()
    print(f"✓ Updated issue: {argv[1]}")
else:
    print(f"fake gc: unsupported ledger call {argv}", file=sys.stderr)
    sys.exit(64)
