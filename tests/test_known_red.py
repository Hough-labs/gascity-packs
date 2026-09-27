"""Tests for gastown/assets/scripts/known-red, the vendored base-red matcher.

Ported from the mill suite (dotmill d674c68, library/skills/gascity/known-red/
tests/test_known_red.py). Every ledger call goes to fixtures/known_red/fake_gc.py
through a `gc` shim on PATH; no test touches a real bead. A second shim named
`bd` sits beside it and logs any call that reaches it: the vendored script must
route every ledger call through `gc bd`, so that log stays empty for the whole
module.

Fixtures (tests/fixtures/known_red/) are real gate output where it exists:
  lqft1-gate-all-test.txt  the GATE_ALL receipt log behind winnow-lqft1 (19 bats ids)
  playwright-contrast.txt  a real red contrast lane (winnow-re3fw.2's receipt)
  green-typecheck.txt      a real green receipt log
  vn65m-go-timeout.txt, go-mixed.txt, vitest-web.txt, jest-mobile.txt, lint.txt
                           real go test / vitest / jest / golangci-lint / shellcheck
                           output, wrapped in the gate.sh lane lines that carry it
  masked-by-lane.txt       a known bats red, then a lane that is red with no id
  pytest-short-summary.txt four pytest FAILED lines seen on this rig, and a footer
  pytest-gcp-98gh.txt      this rig's tracked pytest base red (gcp-98gh) in a gate lane

KNOWN_RED_SCRIPT overrides the script under test (the red-check points it at the
verbatim provenance copy).
"""
import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from datetime import datetime, timedelta, timezone

HERE = os.path.dirname(os.path.abspath(__file__))
REPO_ROOT = os.path.dirname(HERE)
FIX = os.path.join(HERE, "fixtures", "known_red")
SCRIPT = os.environ.get("KNOWN_RED_SCRIPT") or os.path.join(
    REPO_ROOT, "gastown", "assets", "scripts", "known-red")
NOW = datetime.now(timezone.utc)

PYTEST_IDS = [
    ("pytest:gascity/tests/test_formula_assets.py::FormulaAssetTests::"
     "test_city_claim_command_bounds_ambiguous_hook_failures_without_drain_ack"),
    ("pytest:gascity/tests/test_formula_assets.py::FormulaAssetTests::"
     "test_city_claim_command_preserves_unreadable_claim_after_bounded_retries"),
    ("pytest:tests/test_env_hermeticity.py::EnvironmentHermeticityTests::"
     "test_guarded_modules_ignore_agent_session_environment"),
    "pytest:tests/test_no_bare_bd_commands.py::test_shipped_pack_assets_route_beads_commands_through_gc",
]
GCP_98GH_ID = PYTEST_IDS[3]


def z(dt):
    return dt.strftime("%Y-%m-%dT%H:%M:%SZ")


def hermetic_environ():
    """os.environ without the agent-session namespace (see test_env_hermeticity)."""
    return {k: v for k, v in os.environ.items() if not k.startswith(("GC_", "BEADS_"))}


def lqft1_ids():
    """The 19 ids, derived independently of known-red: each `not ok` line plus
    the first `in test file` in the comment lines under it."""
    with open(os.path.join(FIX, "lqft1-gate-all-test.txt")) as fh:
        lines = fh.read().splitlines()
    ids = []
    for i, line in enumerate(lines):
        if line.startswith("not ok "):
            name = line.split(" ", 3)[3]
            j = i + 1
            while "in test file" not in lines[j]:
                j += 1
            f = lines[j].split("in test file ", 1)[1].split(",")[0]
            ids.append(f"bats:{f}::{name}")
    return ids


def bead(bid, sigs=(), status="open", phase="test", last_seen=None, closed_at=None, labels=("base-red",)):
    md = {"gc.routed_to": ""}
    if sigs:
        md["base_red_sigs"] = "\n".join(sigs)
        md["base_red_phase"] = phase
    if last_seen:
        md["base_red_last_seen"] = last_seen
    b = {"id": bid, "title": f"Pre-existing failure: {bid}", "status": status, "priority": 1,
         "labels": list(labels), "metadata": md, "created_at": z(NOW - timedelta(hours=1))}
    if closed_at:
        b["closed_at"] = closed_at
    return b


class KnownRed(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.mkdtemp(prefix="known-red-test.")
        cls.repo = os.path.join(cls.tmp, "repo")
        os.makedirs(os.path.join(cls.repo, "client/apps/web/features/auth"))
        open(os.path.join(cls.repo, "client/apps/web/features/auth/use-sign-out.ts"), "w").close()
        git = ["git", "-C", cls.repo, "-c", "user.name=t", "-c", "user.email=t@t", "-c", "commit.gpgsign=false"]
        subprocess.run(["git", "init", "-q", cls.repo], check=True, env=hermetic_environ())
        subprocess.run(git + ["add", "-A"], check=True, env=hermetic_environ())
        for msg in ("feat(api): ground replies (winnow-re3fw.2)",
                    "fix(api): count suppressed calls under contention (winnow-fx1)",
                    "fix(gate): child bead only (winnow-fx3.1)"):
            subprocess.run(git + ["commit", "-q", "--allow-empty", "-m", msg], check=True, env=hermetic_environ())
        cls.bin = os.path.join(cls.tmp, "bin")
        os.makedirs(cls.bin)
        shim = os.path.join(cls.bin, "gc")
        with open(shim, "w") as fh:
            fh.write(f'#!/bin/sh\nexec "{sys.executable}" "{os.path.join(FIX, "fake_gc.py")}" "$@"\n')
        os.chmod(shim, 0o755)
        # A bare-binary ledger call would bypass gc's store routing. Record it
        # and fail it, so it can never succeed quietly against a real ledger.
        cls.bare_log = os.path.join(cls.tmp, "bare-ledger-calls.log")
        open(cls.bare_log, "w").close()
        bare = os.path.join(cls.bin, "bd")
        with open(bare, "w") as fh:
            fh.write(f'#!/bin/sh\necho "$*" >> "{cls.bare_log}"\nexit 99\n')
        os.chmod(bare, 0o755)

    @classmethod
    def tearDownClass(cls):
        with open(cls.bare_log) as fh:
            bare = fh.read()
        shutil.rmtree(cls.tmp, ignore_errors=True)
        if bare:
            raise AssertionError(f"known-red called the ledger without gc during this module:\n{bare}")

    def setUp(self):
        self.db = os.path.join(self.tmp, f"db-{self._testMethodName}.json")
        self.log = os.path.join(self.tmp, f"calls-{self._testMethodName}.jsonl")
        open(self.log, "w").close()
        self.seed([])

    def seed(self, beads):
        with open(self.db, "w") as fh:
            json.dump({"prefix": "winnow", "beads": {b["id"]: b for b in beads}}, fh)

    def state(self):
        with open(self.db) as fh:
            return json.load(fh)["beads"]

    def gc_calls(self):
        """Every argv the fake gc received, as given (the leading "bd" included)."""
        with open(self.log) as fh:
            return [json.loads(x) for x in fh if x.strip()]

    def calls(self):
        """The ledger verbs: each routed call with its leading "bd" dropped."""
        return [c[1:] for c in self.gc_calls() if c and c[0] == "bd"]

    def run_kr(self, *args, stdin=None, **env):
        e = dict(hermetic_environ(), PATH=self.bin + os.pathsep + os.environ["PATH"],
                 FAKE_GC_DB=self.db, FAKE_GC_LOG=self.log)
        e.update({k: str(v) for k, v in env.items()})
        r = subprocess.run([sys.executable, SCRIPT, *args], cwd=self.repo, env=e, input=stdin,
                           capture_output=True, text=True, timeout=120, check=False)
        return r.returncode, r.stdout, r.stderr

    def lines(self, out, cls):
        return [ln for ln in out.splitlines() if ln.startswith(cls + " ")]

    # ---- extraction -------------------------------------------------------

    def sigs(self, fixture):
        rc, out, _ = self.run_kr("sigs", os.path.join(FIX, fixture))
        return rc, out.splitlines()

    def test_lqft1_log_gives_its_19_bats_ids(self):
        rc, got = self.sigs("lqft1-gate-all-test.txt")
        self.assertEqual(rc, 0)
        self.assertEqual(len(lqft1_ids()), 19)
        self.assertEqual(got, lqft1_ids())
        self.assertFalse(any("gate(" in s for s in got), "a lane line must never be a signature")

    def test_vn65m_log_gives_the_package_timeout(self):
        self.assertEqual(self.sigs("vn65m-go-timeout.txt"), (0, ["go-timeout:internal/ingest/entityres"]))

    def test_go_tests_subtests_and_unparsed_package_failures(self):
        self.assertEqual(self.sigs("go-mixed.txt")[1], [
            "go:api.TestLogThrottle_ConcurrentCallersAdmitOne",
            "go:api.TestGroundingMap",
            "go:api.TestGroundingMap/drops_citation",
            "raw:FAIL github.com/ferth-ai/winnow/internal/broken [build failed]",
            "go-timeout:internal/ingest/entityres",
        ])

    def test_vitest_ids_are_repo_relative_through_the_lane_dir(self):
        self.assertEqual(self.sigs("vitest-web.txt")[1], [
            "js:client/apps/web/src/reader.test.ts::reader header > lands the cross-ref on its verse",
            "js:client/apps/web/src/reader.test.ts::top-level contrast floor",
        ])

    def test_jest_ids_skip_console_blocks(self):
        self.assertEqual(self.sigs("jest-mobile.txt")[1], [
            "js:client/apps/mobile/features/reader/header.test.js::reader header > lands the cross-ref on its verse",
            "js:client/apps/mobile/features/reader/header.test.js::top-level contrast floor",
        ])

    def test_playwright_id_from_a_real_red_contrast_lane(self):
        self.assertEqual(self.sigs("playwright-contrast.txt")[1], [
            ("js:client/apps/mobile/e2e/verse-landing.spec.ts::landing a link on its verse > "
             "a cross-ref into the chapter already showing scrolls to its verse and banks no history"),
        ])

    def test_lint_ids_errors_only_worktree_paths_made_relative(self):
        self.assertEqual(self.sigs("lint.txt")[1], [
            "lint:errcheck:internal/store/store.go",
            "lint-timeout:golangci-lint",
            "lint:eslint:client/apps/web/features/auth/use-sign-out.ts",   # the warning-only file is absent
            "lint:shellcheck:scripts/prune.sh",
        ])

    def test_green_log_has_no_ids_and_match_is_not_vacuously_known(self):
        self.assertEqual(self.sigs("green-typecheck.txt"), (1, []))
        rc, out, _ = self.run_kr("match", os.path.join(FIX, "green-typecheck.txt"))
        self.assertEqual(rc, 1)
        self.assertIn("no failure id found", out)

    # ---- pytest -----------------------------------------------------------

    def test_pytest_short_summary_gives_one_id_per_failed_line(self):
        self.assertEqual(self.sigs("pytest-short-summary.txt"), (0, PYTEST_IDS))

    def test_pytest_message_suffix_does_not_change_the_id(self):
        node = "tests/test_x.py::XTests::test_y"
        _, bare, _ = self.run_kr("sigs", "-", stdin=f"FAILED {node}\n")
        _, suffixed, _ = self.run_kr("sigs", "-", stdin=f"FAILED {node} - AssertionError: x\n")
        self.assertEqual(bare.splitlines(), [f"pytest:{node}"])
        self.assertEqual(suffixed.splitlines(), bare.splitlines())
        rc, both, _ = self.run_kr("sigs", "-", stdin=f"FAILED {node}\nFAILED {node} - AssertionError: x\n")
        self.assertEqual((rc, both.splitlines()), (0, [f"pytest:{node}"]), "dedup by id")

    def test_pytest_collection_error_without_a_nodeid_stays_raw_and_new(self):
        err = "ERROR tests/x.py - ImportError: y"
        rc, out, _ = self.run_kr("sigs", "-", stdin=err + "\n")
        self.assertEqual((rc, out.splitlines()), (0, [f"raw:{err}"]))
        rc, out, _ = self.run_kr("match", "-", stdin=err + "\n")
        self.assertEqual(rc, 1)
        self.assertEqual(len(self.lines(out, "NEW")), 1)
        self.assertIn(f"raw:{err}", self.lines(out, "NEW")[0])
        # A pytest id in the same segment must not hide it.
        self.seed([bead("gcp-98gh", [GCP_98GH_ID])])
        rc, out, _ = self.run_kr("match", "-", stdin=f"FAILED {GCP_98GH_ID[len('pytest:'):]}\n{err}\n")
        self.assertEqual(rc, 1)
        self.assertEqual(len(self.lines(out, "KNOWN")), 1)
        self.assertIn(f"raw:{err}", self.lines(out, "NEW")[0])

    def test_every_ledger_call_is_routed_through_gc_bd(self):
        # Exercise every subcommand that reaches the ledger, then check both
        # sides: the bare shim saw nothing, and every call gc saw was `gc bd`.
        self.seed([bead("winnow-vn65m", ["go-timeout:internal/ingest/entityres"])])
        self.run_kr("list")
        self.run_kr("match", os.path.join(FIX, "go-mixed.txt"))
        self.run_kr("file", os.path.join(FIX, "go-mixed.txt"), "--summary", "x", "--sha", "a" * 40)
        with open(self.bare_log) as fh:
            self.assertEqual(fh.read(), "", "a ledger call bypassed gc")
        routed = self.gc_calls()
        self.assertTrue(routed, "known-red made no ledger call at all")
        self.assertTrue(all(c and c[0] == "bd" for c in routed), routed)
        self.assertIn("create", [c[0] for c in self.calls()])

    def test_match_the_rigs_tracked_pytest_base_red_is_known(self):
        self.seed([bead("gcp-98gh", [GCP_98GH_ID])])
        rc, out, err = self.run_kr("match", os.path.join(FIX, "pytest-gcp-98gh.txt"))
        self.assertEqual(rc, 0, out + err)
        self.assertEqual(self.lines(out, "KNOWN"), [f"{'KNOWN':<15} {'gcp-98gh':<14} {GCP_98GH_ID}"])
        self.assertEqual(self.lines(out, "NEW"), [])

    # ---- match ------------------------------------------------------------

    def test_match_lqft1_all_19_known(self):
        self.seed([bead("winnow-lqft1", lqft1_ids())])
        rc, out, err = self.run_kr("match", os.path.join(FIX, "lqft1-gate-all-test.txt"))
        self.assertEqual(rc, 0, err)
        known = self.lines(out, "KNOWN")
        self.assertEqual(len(known), 19)
        self.assertTrue(all(" winnow-lqft1 " in ln for ln in known))
        self.assertEqual(self.lines(out, "NEW"), [])

    def test_match_names_exactly_the_one_id_missing_from_the_bead(self):
        ids = lqft1_ids()
        dropped = ids[6]
        self.seed([bead("winnow-lqft1", [i for i in ids if i != dropped])])
        rc, out, _ = self.run_kr("match", os.path.join(FIX, "lqft1-gate-all-test.txt"))
        self.assertEqual(rc, 1)
        new = self.lines(out, "NEW")
        self.assertEqual(len(new), 1)
        self.assertTrue(new[0].endswith(dropped), new[0])
        self.assertEqual(len(self.lines(out, "KNOWN")), 18)

    def test_a_known_red_cannot_mask_an_unparsed_red_lane(self):
        self.seed([bead("winnow-jhyik", [
            "bats:.gauntlet/winnow-13dg-gate-matches.bats::lane-prereq: a selected lane whose tool is missing FAILS, it does not skip"])])
        rc, out, _ = self.run_kr("match", os.path.join(FIX, "masked-by-lane.txt"))
        self.assertEqual(rc, 1)
        self.assertEqual(len(self.lines(out, "KNOWN")), 1)
        self.assertIn("raw:gate(test): FATAL — the contrast lane could not bind port", self.lines(out, "NEW")[0])

    def test_a_raw_id_is_new_even_if_a_bead_carries_it(self):
        raw = "raw:FAIL github.com/ferth-ai/winnow/internal/broken [build failed]"
        self.seed([bead("winnow-b1", [raw, "go:api.TestLogThrottle_ConcurrentCallersAdmitOne", "go:api.TestGroundingMap",
                                      "go:api.TestGroundingMap/drops_citation", "go-timeout:internal/ingest/entityres"])])
        rc, out, _ = self.run_kr("match", os.path.join(FIX, "go-mixed.txt"))
        self.assertEqual(rc, 1)
        self.assertEqual(len(self.lines(out, "KNOWN")), 4)
        self.assertEqual(len(self.lines(out, "NEW")), 1)
        self.assertIn(raw, self.lines(out, "NEW")[0])

    def test_ledger_unreachable_fails_closed(self):
        rc, out, err = self.run_kr("match", os.path.join(FIX, "lqft1-gate-all-test.txt"), FAKE_GC_FAIL=1)
        self.assertEqual(rc, 2)
        self.assertEqual(len(self.lines(out, "NEW")), 19)
        self.assertEqual(self.lines(out, "KNOWN"), [])
        self.assertIn("LOOKUP FAILED", err)

    def test_a_failed_list_fails_closed_even_when_the_ledger_answers_config(self):
        self.seed([bead("winnow-vn65m", ["go-timeout:internal/ingest/entityres"])])
        rc, out, _ = self.run_kr("match", os.path.join(FIX, "vn65m-go-timeout.txt"), FAKE_GC_FAIL_ON="list")
        self.assertEqual(rc, 2)
        self.assertEqual(self.lines(out, "KNOWN"), [])
        rc, _, _ = self.run_kr("file", os.path.join(FIX, "vn65m-go-timeout.txt"), "--summary", "x",
                               FAKE_GC_FAIL_ON="list")
        self.assertEqual(rc, 2)
        self.assertEqual([c for c in self.calls() if c[0] in ("create", "update")], [])

    def test_gc_missing_from_path_fails_closed(self):
        e = dict(hermetic_environ(), PATH="/usr/bin:/bin")
        r = subprocess.run([sys.executable, SCRIPT, "match", os.path.join(FIX, "vn65m-go-timeout.txt")],
                           cwd=self.repo, env=e, capture_output=True, text=True, check=False)
        self.assertEqual(r.returncode, 2, r.stderr)

    def test_closed_bead_fixed_upstream_unless_the_fix_is_on_head(self):
        recent = z(NOW - timedelta(days=2))
        ids = lqft1_ids()
        self.seed([bead("winnow-fx1", ids[0:1], status="closed", closed_at=recent),   # fix commit on HEAD
                   bead("winnow-fx2", ids[1:2], status="closed", closed_at=recent),   # no fix commit
                   bead("winnow-fx3", ids[2:3], status="closed", closed_at=recent),   # only winnow-fx3.1 cited
                   bead("winnow-old", ids[3:4], status="closed", closed_at=z(NOW - timedelta(days=9))),
                   bead("winnow-open", ids[4:], status="open")])
        rc, out, _ = self.run_kr("match", os.path.join(FIX, "lqft1-gate-all-test.txt"))
        by_sig = {ln.split("   [")[0].split(None, 2)[2]: ln for ln in out.splitlines() if ln.strip()}
        self.assertTrue(by_sig[ids[0]].startswith("NEW "), by_sig[ids[0]])          # regression
        self.assertIn("regression", by_sig[ids[0]])
        self.assertTrue(by_sig[ids[1]].startswith("FIXED-UPSTREAM  winnow-fx2"), by_sig[ids[1]])
        self.assertTrue(by_sig[ids[2]].startswith("FIXED-UPSTREAM  winnow-fx3"), by_sig[ids[2]])
        self.assertTrue(by_sig[ids[3]].startswith("NEW "), "closed >7 days ago is out of the window")
        self.assertEqual(rc, 1)
        # Without the NEW ones, FIXED-UPSTREAM alone exits 3 (rebase).
        self.seed([bead("winnow-fx2", ids[1:2], status="closed", closed_at=recent),
                   bead("winnow-open", ids[:1] + ids[2:], status="open")])
        rc, out, _ = self.run_kr("match", os.path.join(FIX, "lqft1-gate-all-test.txt"))
        self.assertEqual(rc, 3)

    def test_one_status_per_list_call(self):
        self.run_kr("match", os.path.join(FIX, "lqft1-gate-all-test.txt"))
        lists = [c for c in self.calls() if c[0] == "list"]
        statuses = []
        for c in lists:
            self.assertEqual(c.count("--status"), 1, c)
            st = c[c.index("--status") + 1]
            self.assertNotIn(",", st, c)
            self.assertEqual(c[c.index("--limit") + 1], "0", "the default limit of 50 would truncate")
            self.assertEqual(c[c.index("--label") + 1], "base-red")
            statuses.append(st)
            if st == "closed":
                self.assertIn("--closed-after", c)
        self.assertEqual(sorted(statuses), sorted(["open", "in_progress", "blocked", "deferred", "closed"]))

    # ---- file -------------------------------------------------------------

    def test_file_twice_leaves_one_bead_and_moves_last_seen(self):
        d = tempfile.mkdtemp(dir=self.tmp)
        log = os.path.join(d, "test-50ec6fa2-f8a0.log")
        shutil.copy(os.path.join(FIX, "lqft1-gate-all-test.txt"), log)
        with open(log[:-4] + ".receipt", "w") as fh:
            fh.write("phase=test\nstatus=1\nhead=29a8ca154820e4ea5fdbe82dadffa68ab14da6c8\n"
                     f"finished={z(NOW - timedelta(hours=5))}\n")
        rc, out, err = self.run_kr("file", log, "--summary", "gate self-tests inherit GATE_ALL", "--from", "winnow-9rd6s")
        self.assertEqual(rc, 0, err)
        beads = [b for b in self.state().values() if "base-red" in b["labels"]]
        self.assertEqual(len(beads), 1)
        b = beads[0]
        self.assertIsInstance(b["metadata"], dict)
        self.assertEqual(b["metadata"]["base_red_sigs"].split("\n"), lqft1_ids())
        self.assertEqual(b["metadata"]["base_red_phase"], "test")
        self.assertEqual(b["metadata"]["base_red_first_sha"], "29a8ca154820e4ea5fdbe82dadffa68ab14da6c8")
        self.assertEqual(b["metadata"]["base_red_from"], "winnow-9rd6s")
        self.assertTrue(b["title"].startswith("Pre-existing failure: bats:.gauntlet/winnow-13dg-gate-matches.bats::"))
        self.assertIn("(+18 more) — gate self-tests inherit GATE_ALL", b["title"])
        self.assertEqual((b["issue_type"], b["priority"]), ("bug", 1))
        first_seen = b["metadata"]["base_red_last_seen"]
        self.assertEqual(first_seen, "29a8ca154820e4ea5fdbe82dadffa68ab14da6c8@" + z(NOW - timedelta(hours=5)),
                         "sha and time come from the receipt beside the log")

        n_before = len(self.calls())
        rc, out, err = self.run_kr("file", os.path.join(FIX, "lqft1-gate-all-test.txt"),
                                   "--summary", "again", "--sha", "b" * 40)
        self.assertEqual(rc, 0, err)
        beads = [x for x in self.state().values() if "base-red" in x["labels"]]
        self.assertEqual(len(beads), 1, "the second file must not create a duplicate")
        self.assertNotIn("create", [c[0] for c in self.calls()[n_before:]])
        seen = beads[0]["metadata"]["base_red_last_seen"]
        self.assertTrue(seen.startswith("b" * 40 + "@"), seen)
        self.assertGreater(seen.split("@")[1], first_seen.split("@")[1])
        self.assertEqual(len(self.lines(out, "KNOWN")), 19)

        # An older sighting never moves last-seen back.
        rc, out, err = self.run_kr("file", os.path.join(FIX, "lqft1-gate-all-test.txt"), "--summary", "old",
                                   "--sha", "d" * 40, "--seen-at", z(NOW - timedelta(days=3)))
        self.assertEqual(rc, 0, err)
        self.assertEqual(self.state()[beads[0]["id"]]["metadata"]["base_red_last_seen"], seen)
        self.assertIn("not moving last-seen back", out)

    def test_file_never_writes_whole_object_metadata(self):
        self.run_kr("file", os.path.join(FIX, "vn65m-go-timeout.txt"), "--summary", "entityres overruns 30m")
        writes = [c for c in self.calls() if c[0] in ("update", "create")]
        self.assertTrue(writes)
        self.assertFalse(any("--metadata" in c for c in writes), writes)

    def test_file_with_the_ledger_unreachable_writes_nothing(self):
        rc, _, err = self.run_kr("file", os.path.join(FIX, "vn65m-go-timeout.txt"),
                                 "--summary", "x", FAKE_GC_FAIL=1)
        self.assertEqual(rc, 2)
        self.assertIn("filed nothing", err)
        self.assertEqual([c for c in self.calls() if c[0] in ("create", "update")], [])
        self.assertEqual(self.state(), {})

    def test_file_detects_metadata_that_is_not_an_object(self):
        self.seed([bead("winnow-vn65m", ["go-timeout:internal/ingest/entityres"])])
        rc, _, err = self.run_kr("file", os.path.join(FIX, "vn65m-go-timeout.txt"), "--summary", "x",
                                 FAKE_GC_CORRUPT_METADATA=1)
        self.assertEqual(rc, 2)
        self.assertIn("not an object", err)

    def test_file_does_not_file_raw_lines(self):
        rc, _, err = self.run_kr("file", os.path.join(FIX, "masked-by-lane.txt"), "--summary", "lane-prereq flake")
        self.assertEqual(rc, 1)
        self.assertIn("no stable id", err)
        beads = list(self.state().values())
        self.assertEqual(len(beads), 1)
        self.assertEqual(beads[0]["metadata"]["base_red_sigs"],
                         "bats:.gauntlet/winnow-13dg-gate-matches.bats::lane-prereq: a selected lane whose tool is missing FAILS, it does not skip")

    def test_file_into_an_existing_bead_labels_it_and_then_it_matches(self):
        self.seed([bead("winnow-vn65m", labels=())])
        rc, _, err = self.run_kr("file", os.path.join(FIX, "vn65m-go-timeout.txt"), "--summary", "x",
                                 "--into", "winnow-vn65m", "--sha", "c" * 40)
        self.assertEqual(rc, 0, err)
        b = self.state()["winnow-vn65m"]
        self.assertIn("base-red", b["labels"])
        self.assertEqual(b["metadata"]["base_red_sigs"], "go-timeout:internal/ingest/entityres")
        self.assertEqual(b["metadata"]["gc.routed_to"], "", "--set-metadata must keep existing keys")
        self.assertEqual(len(self.state()), 1)
        rc, out, _ = self.run_kr("match", os.path.join(FIX, "vn65m-go-timeout.txt"))
        self.assertEqual(rc, 0)
        self.assertIn("KNOWN           winnow-vn65m", out)

    def test_file_into_a_closed_bead_refuses(self):
        self.seed([bead("winnow-done", status="closed", closed_at=z(NOW - timedelta(days=30)))])
        rc, _, _ = self.run_kr("file", os.path.join(FIX, "vn65m-go-timeout.txt"), "--summary", "x", "--into", "winnow-done")
        self.assertEqual(rc, 2)
        self.assertEqual([c for c in self.calls() if c[0] in ("create", "update")], [])

    def test_dry_run_writes_nothing(self):
        rc, out, _ = self.run_kr("file", os.path.join(FIX, "lqft1-gate-all-test.txt"), "--summary", "x", "--dry-run")
        self.assertEqual(rc, 0)
        self.assertIn("(dry-run) gc bd create", out)
        self.assertEqual([c for c in self.calls() if c[0] in ("create", "update")], [])

    # ---- list -------------------------------------------------------------

    def test_list_marks_stale_and_filters_by_phase(self):
        self.seed([bead("winnow-a", ["go:api.TestA"], last_seen="abcdef1234@" + z(NOW - timedelta(hours=100))),
                   bead("winnow-b", ["go:api.TestB"], last_seen="1234abcdef@" + z(NOW - timedelta(hours=2))),
                   bead("winnow-c", ["lint:errcheck:x.go"], phase="lint", status="in_progress",
                        last_seen="99@" + z(NOW - timedelta(hours=1))),
                   bead("winnow-d", [], status="deferred")])
        rc, out, _ = self.run_kr("list")
        self.assertEqual(rc, 0)
        rows = {ln.split()[0]: ln for ln in out.splitlines() if ln.startswith("winnow-")}
        self.assertEqual(sorted(rows), ["winnow-a", "winnow-b", "winnow-c", "winnow-d"])
        self.assertTrue(rows["winnow-a"].endswith("STALE"))
        self.assertFalse(rows["winnow-b"].endswith("STALE"))
        self.assertIn("no base_red_sigs", out)
        rc, out, _ = self.run_kr("list", "--phase", "lint")
        self.assertEqual([ln.split()[0] for ln in out.splitlines() if ln.startswith("winnow-")], ["winnow-c"])
        rc, out, _ = self.run_kr("list", "--stale")
        self.assertEqual([ln.split()[0] for ln in out.splitlines() if ln.startswith("winnow-")], ["winnow-a"])
        self.assertIn("1 STALE", out)

    def test_list_fails_closed(self):
        rc, _, err = self.run_kr("list", FAKE_GC_FAIL=1)
        self.assertEqual(rc, 2)
        self.assertIn("LOOKUP FAILED", err)


if __name__ == "__main__":
    unittest.main(verbosity=2)
