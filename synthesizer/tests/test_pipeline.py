"""python3 -m unittest discover -s tests -v（只用標準函式庫）"""
import filecmp
import sys
import tempfile
import unittest
from datetime import date
from pathlib import Path

HERE = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(HERE))

import synthetic_pipeline as sp  # noqa: E402
import validate  # noqa: E402


def run_to(out: Path, seed: int, start=sp.DEFAULT_START, days=sp.DEFAULT_DAYS):
    sp.Synthesizer(start, days, seed).run().write(out)
    return validate.check(out)


class DefaultPeriod(unittest.TestCase):
    """預設 90 天：所有檢查都要 PASS，不能有 SKIP（SKIP 代表訊號被移出期間）。"""

    def test_two_seeds_all_pass(self):
        for seed in (sp.DEFAULT_SEED, 113):   # 113 曾經讓 S2 在午夜邊界漏一筆
            with self.subTest(seed=seed), tempfile.TemporaryDirectory() as d:
                res = run_to(Path(d), seed)
                bad = [(n, s, x) for n, s, x in res if s != validate.PASS]
                self.assertEqual(bad, [])
                for name in ["raw_creatives.csv", "raw_ad_daily.csv", "raw_events.csv", "raw_orders.csv",
                             "raw_customers.csv", "ground_truth/customer_segments.csv"]:
                    self.assertTrue((Path(d) / name).exists(), name)


class OtherPeriods(unittest.TestCase):
    """非預設期間：不涵蓋的訊號要 SKIP，但不能 FAIL，資料也不能超出期間。"""

    def test_short_and_shifted(self):
        for start, days in ((sp.DEFAULT_START, 7), (date(2026, 7, 1), 30)):
            with self.subTest(start=start, days=days), tempfile.TemporaryDirectory() as d:
                res = run_to(Path(d), 7, start, days)
                self.assertEqual([r for r in res if r[1] == validate.FAIL], [])


class Deterministic(unittest.TestCase):
    def test_same_seed_same_files(self):
        with tempfile.TemporaryDirectory() as a, tempfile.TemporaryDirectory() as b:
            for d in (a, b):
                sp.main(["--days", "14", "--out", d])
            cmp = filecmp.dircmp(a, b)
            self.assertEqual(cmp.diff_files, [])
            for name in cmp.common_files:
                self.assertTrue(filecmp.cmp(Path(a) / name, Path(b) / name, shallow=False), name)

    def test_different_seed_differs(self):
        x = sp.Synthesizer(date(2026, 6, 19), 3, 1).run()
        y = sp.Synthesizer(date(2026, 6, 19), 3, 2).run()
        self.assertNotEqual(x.ad_rows, y.ad_rows)


class Contract(unittest.TestCase):
    def syn(self):
        return sp.Synthesizer(date(2026, 6, 19), 1, 1)

    def test_bad_product_rejected(self):
        s = self.syn()
        s.creatives[0]["product_focus"] = "not-a-product"
        with self.assertRaises(ValueError):
            s._check_contract()

    def test_unknown_signal_targets_rejected(self):
        for key, field in (("S1_cpc_spike", "ad_group_id"), ("S3_creative_fatigue", "creative_id"),
                           ("S2_tracking_outage", "dropped_event")):
            with self.subTest(key=key):
                s = self.syn()
                s.gt[key][field] = "nope"
                with self.assertRaises(ValueError):
                    s._check_contract()

    def test_days_must_be_positive(self):
        with self.assertRaises(SystemExit):
            sp.main(["--days", "0", "--out", tempfile.gettempdir()])

    def test_emails_use_reserved_domain(self):
        s = sp.Synthesizer(date(2026, 6, 19), 3, 1).run()
        self.assertTrue(all(c["email"].endswith("@example.com") for c in s.customers))


if __name__ == "__main__":
    unittest.main()
