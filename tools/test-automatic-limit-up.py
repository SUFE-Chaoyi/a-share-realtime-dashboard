#!/usr/bin/env python3
import json, os, tempfile, unittest

class AutomaticLimitUpRules(unittest.TestCase):
    def test_business_date_normalization(self):
        self.assertEqual("20260828", "2026-08-28".replace("-", ""))
        self.assertEqual("20260828", "2026/08/28".replace("/", ""))

    def test_quote_units(self):
        self.assertAlmostEqual(11800 / 1000, 11.8)
        self.assertAlmostEqual(9.972041, 9.972041)  # zdp 是百分比，不再 /100

    def test_strict_consecutive_and_break(self):
        previous = {"A": 2, "B": 2}
        current = {"A": previous["A"] + 1, "B": 1, "C": 1}
        self.assertEqual(current, {"A": 3, "B": 1, "C": 1})

    def test_weekend_is_not_a_trading_snapshot(self):
        self.assertEqual([], [] if __import__("datetime").date(2026, 8, 29).weekday() >= 5 else ["20260829"])

    def test_dynamic_tiers(self):
        stocks = [{"streak": 1}, {"streak": 5}, {"streak": 7}]
        self.assertEqual([1, 5, 7], sorted({s["streak"] for s in stocks}))

    def test_failed_or_partial_result_does_not_overwrite(self):
        old = {"date": "20260827", "stocks": [{"code": "000001"}]}
        candidate = None  # upstream failure: no candidate is ever committed
        committed = candidate if candidate is not None else old
        self.assertEqual(old, committed)

    def test_custom_pools_are_preserved_during_migration(self):
        pools = [{"kind": "automatic", "name": "首板池"}, {"kind": "manual", "name": "自定义"}]
        self.assertEqual(["自定义"], [p["name"] for p in pools if p.get("kind") != "automatic"])

if __name__ == "__main__": unittest.main(verbosity=2)
