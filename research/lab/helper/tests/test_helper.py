"""Helper tests against a throwaway store (never the live one).

    uv run python -m unittest discover -s tests -v
"""
from __future__ import annotations

import json
import sqlite3
import sys
import tempfile
import textwrap
import threading
import unittest
import urllib.error
import urllib.request
from pathlib import Path

HERE = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(HERE))

import lab_registry  # noqa: E402
import server  # noqa: E402
from lab_store import CORE_DATA_EPOCH, Store  # noqa: E402

H5 = 5 * 3600.0
T0 = 1_752_000_000.0          # a cycle start, unix
ACCT = "acct-a"


def make_store(path: Path) -> sqlite3.Connection:
    conn = sqlite3.connect(path)
    conn.execute("PRAGMA journal_mode=WAL")
    conn.execute("CREATE TABLE ZRATELIMITSAMPLE (Z_PK INTEGER PRIMARY KEY, ZSAMPLEDAT REAL, "
                 "ZUSEDPERCENTAGE REAL, ZRESETSAT REAL, ZWINDOW TEXT, ZACCOUNTID TEXT)")
    conn.execute("CREATE TABLE ZACCOUNTUSAGEARCHIVE (Z_PK INTEGER PRIMARY KEY, ZKIND TEXT, ZSAMPLEDAT REAL, "
                 "ZUSEDPERCENTAGE REAL, ZRESETSAT REAL, ZWINDOW TEXT, ZIDENTITY TEXT, ZACCOUNTID TEXT)")
    conn.commit()
    return conn


def live(conn, t, pct, reset, window="five_hour", account=ACCT):
    conn.execute("INSERT INTO ZRATELIMITSAMPLE (ZSAMPLEDAT, ZUSEDPERCENTAGE, ZRESETSAT, ZWINDOW, ZACCOUNTID) "
                 "VALUES (?,?,?,?,?)", (t - CORE_DATA_EPOCH, pct, reset - CORE_DATA_EPOCH, window, account))


def archived(conn, t, pct, reset, window="five_hour", account=ACCT):
    conn.execute("INSERT INTO ZACCOUNTUSAGEARCHIVE (ZKIND, ZSAMPLEDAT, ZUSEDPERCENTAGE, ZRESETSAT, ZWINDOW, "
                 "ZACCOUNTID) VALUES ('rate_limit',?,?,?,?,?)",
                 (t - CORE_DATA_EPOCH, pct, reset - CORE_DATA_EPOCH, window, account))


def write_predictor(directory: Path, name: str, body: str) -> None:
    (directory / f"{name}.py").write_text(textwrap.dedent(body))


SPY = """
    ID = "lab-spy"
    DISPLAY_NAME = "Spy"
    SUMMARY = "Reports the latest reading it can see."
    HOW_IT_WORKS = "Test only."
    WINDOWS = ("*",)
    def predict(window, account, t_cut, cycle_start, resets_at, history):
        latest = max((r.t for r in history.readings), default=0.0)
        other = max((r.t for r in history.window_readings("seven_day")), default=0.0)
        return latest, float(len(history.readings)), other
"""


class Fixture(unittest.TestCase):
    """Two archived 5-hour cycles, one live completed cycle, a live cycle in
    progress, readings every 10 minutes; another account's rows; a 7-day
    window for `window_readings`."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        root = Path(self.tmp.name)
        self.db = root / "pacer.sqlite"
        conn = make_store(self.db)
        for c in range(4):
            start = T0 + c * H5
            reset = start + H5
            for k in range(30):
                t = start + k * 600
                if c == 3 and k > 15:          # the live cycle: half-way in
                    break
                pct = min(80.0, 160.0 * k / 30)
                (archived if c < 2 else live)(conn, t, pct, reset)
                live(conn, t - 1, 99.0, reset, account="acct-b")   # another login, polled a second apart
                live(conn, t, 10.0 + k, T0 + 7 * 86400, window="seven_day")
        conn.commit()
        conn.close()
        self.now = T0 + 3 * H5 + 15 * 600
        self.live_reset = T0 + 4 * H5
        self.predictors = root / "predictors"
        self.predictors.mkdir()

    def tearDown(self):
        self.tmp.cleanup()

    def helper(self, *bodies: tuple[str, str], top_up_s: float = 5.0) -> server.Helper:
        for name, body in bodies:
            write_predictor(self.predictors, name, body)
        return server.Helper(Store(self.db, top_up_s=top_up_s), self.predictors)


class HistoryTests(Fixture):

    def test_a_predictor_never_sees_past_the_cut(self):
        h = self.helper(("spy", SPY))
        cuts = [T0 + 2.5 * H5, T0 + 3 * H5 + 300, self.now]
        out = h.forecast({"window": "five_hour", "account": ACCT, "duration": H5,
                          "cycles": [{"cycleStart": T0 + 3 * H5, "resetsAt": self.live_reset, "cuts": cuts}]})
        entries = out["cycles"][0]["predictions"]["lab-spy"]
        for cut, e in zip(cuts, entries):
            self.assertLessEqual(e["final"], cut)      # latest reading seen
            self.assertLessEqual(e["q90"], cut)        # other window too
        # Archived and live rows of this account, none of the other's.
        self.assertEqual(entries[-1]["q10"], 2 * 30 + 30 + 16)

    def test_no_account_reads_every_account_and_no_archive(self):
        h = self.helper(("spy", SPY))
        out = h.forecast({"window": "five_hour", "account": None, "duration": H5,
                          "cycleStart": T0 + 3 * H5, "resetsAt": self.live_reset, "cuts": [self.now]})
        self.assertIn("predictions", out)              # the single-cycle form answers in kind
        self.assertEqual(out["predictions"]["lab-spy"][0]["q10"], (30 + 16) + (3 * 30 + 16))

    def test_new_live_rows_are_picked_up(self):
        h = self.helper(("spy", SPY), top_up_s=0)
        req = {"window": "five_hour", "account": ACCT, "duration": H5,
               "cycleStart": T0 + 3 * H5, "resetsAt": self.live_reset, "cuts": [self.now + 600]}
        before = h.forecast(req)["predictions"]["lab-spy"][0]["final"]
        conn = sqlite3.connect(self.db)
        live(conn, self.now + 600, 82.0, self.live_reset)
        conn.commit()
        conn.close()
        after = h.forecast(req)["predictions"]["lab-spy"][0]["final"]
        self.assertEqual(before, self.now)
        self.assertEqual(after, self.now + 600)


class RecentRateTests(Fixture):

    def test_matches_the_app_rule_by_hand(self):
        h = server.Helper(Store(self.db), lab_registry.DEFAULT_DIR.parent / "staging")
        self.assertIn("lab-recent-rate-py", [p.id for p in h.predictors])
        out = h.forecast({"window": "five_hour", "account": ACCT, "duration": H5,
                          "cycleStart": T0 + 3 * H5, "resetsAt": self.live_reset, "cuts": [self.now]})
        got = out["predictions"]["lab-recent-rate-py"][0]["final"]
        # Live cycle at k=15 (80% by k=15: 160·15/30 = 80); an hour back is k=9 (48%).
        # Rise 32 pp over 3600 s, held for the 2.5 h left from the last reading.
        expected = 80.0 + (80.0 - 48.0) / 3600 * (self.live_reset - self.now)
        self.assertAlmostEqual(got, expected, places=6)

    def test_declines_with_one_reading(self):
        h = server.Helper(Store(self.db), lab_registry.DEFAULT_DIR.parent / "staging")
        out = h.forecast({"window": "five_hour", "account": ACCT, "duration": H5,
                          "cycleStart": T0 + 3 * H5, "resetsAt": self.live_reset, "cuts": [T0 + 3 * H5 + 60]})
        self.assertIsNone(out["predictions"]["lab-recent-rate-py"][0])


class RegistryTests(Fixture):

    def test_broken_predictors_are_skipped_and_errors_are_declines(self):
        h = self.helper(
            ("bad_id", SPY.replace('"lab-spy"', '"recent-rate"')),
            ("no_windows", SPY.replace('ID = "lab-spy"', 'ID = "lab-nowin"').replace('WINDOWS = ("*",)', "WINDOWS = ()")),
            ("syntax", "this is not python ("),
            ("raises", SPY.replace('"lab-spy"', '"lab-raises"').replace("latest = max", "raise RuntimeError('boom'); latest = max")),
            ("nan", SPY.replace('"lab-spy"', '"lab-nan"').replace("return latest, float(len(history.readings)), other",
                                                               "return float('nan'), 1.0, float('inf')")),
            ("spy", SPY),
        )
        self.assertEqual(sorted(p.id for p in h.predictors), ["lab-nan", "lab-raises", "lab-spy"])
        out = h.forecast({"window": "five_hour", "account": ACCT, "duration": H5,
                          "cycleStart": T0 + 3 * H5, "resetsAt": self.live_reset, "cuts": [self.now]})
        self.assertIsNone(out["predictions"]["lab-raises"][0])
        self.assertIsNone(out["predictions"]["lab-nan"][0])
        self.assertIsNotNone(out["predictions"]["lab-spy"][0])
        self.assertEqual(h.health()["predictors"]["lab-raises"]["errors"], 1)
        json.dumps(out, allow_nan=False)                # the wire never carries NaN

    def test_the_deadline_leaves_the_rest_null(self):
        slow = SPY.replace('"lab-spy"', '"lab-slow"').replace(
            "latest = max", "import time; time.sleep(0.05); latest = max")
        h = self.helper(("slow", slow))
        cuts = [self.now - 600 * i for i in range(10)]
        out = h.forecast({"window": "five_hour", "account": ACCT, "duration": H5, "deadlineMs": 60,
                          "cycleStart": T0 + 3 * H5, "resetsAt": self.live_reset, "cuts": cuts})
        entries = out["predictions"]["lab-slow"]
        self.assertTrue(out["truncated"])
        self.assertIsNotNone(entries[0])
        self.assertIsNone(entries[-1])

    def test_only_the_models_asked_for_run(self):
        h = self.helper(("spy", SPY), ("spy2", SPY.replace('"lab-spy"', '"lab-spy2"')))
        out = h.forecast({"window": "five_hour", "account": ACCT, "duration": H5, "models": ["lab-spy2"],
                          "cycles": [{"cycleStart": T0 + 3 * H5, "resetsAt": self.live_reset, "cuts": [self.now]}]})
        self.assertEqual(list(out["cycles"][0]["predictions"]), ["lab-spy2"])


class HTTPTests(Fixture):

    def setUp(self):
        super().setUp()
        self.h = self.helper(("spy", SPY))
        self.server = server.serve("127.0.0.1", 0, self.h)
        self.port = self.server.server_address[1]
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()

    def tearDown(self):
        self.server.shutdown()
        self.server.server_close()
        super().tearDown()

    def call(self, path, body=None):
        data = None if body is None else json.dumps(body).encode()
        req = urllib.request.Request(f"http://127.0.0.1:{self.port}{path}", data=data,
                                     method="GET" if body is None else "POST",
                                     headers={"Content-Type": "application/json"})
        with urllib.request.urlopen(req, timeout=5) as r:
            return json.loads(r.read())

    def test_models_and_forecast_over_http(self):
        models = self.call("/v1/models")["models"]
        self.assertEqual(models, [{"id": "lab-spy", "displayName": "Spy",
                                   "summary": "Reports the latest reading it can see.",
                                   "howItWorks": "Test only.", "windows": ["*"], "complexity": 6}])
        out = self.call("/v1/forecast", {
            "window": "five_hour", "account": ACCT, "duration": H5, "deadlineMs": 1200, "models": ["lab-spy"],
            "cycles": [{"cycleStart": T0 + 3 * H5, "resetsAt": self.live_reset, "cuts": [self.now]},
                       {"cycleStart": T0 + 2 * H5, "resetsAt": T0 + 3 * H5,
                        "cuts": [T0 + 2 * H5 + H5 * f for f in (0.2, 0.5, 0.9)]}]})
        self.assertEqual([len(c["predictions"]["lab-spy"]) for c in out["cycles"]], [1, 3])
        self.assertTrue(self.call("/healthz")["ok"])

    def test_a_bad_request_is_a_400(self):
        with self.assertRaises(urllib.error.HTTPError) as ctx:
            self.call("/v1/forecast", {"window": "five_hour"})
        self.assertEqual(ctx.exception.code, 400)


if __name__ == "__main__":
    unittest.main()
