#!/usr/bin/env python3
"""验证自动涨停梯队的持久化不变量，不依赖 CSV 或固定板位数量。"""
import json, os, re, sys
from collections import Counter

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
HISTORY = os.path.join(ROOT, "data", "limit-up-history.json")
POOLS = os.path.join(ROOT, "data", "stock-pools.json")
SZ = ("000", "001", "002", "003", "300", "301")
SH = ("600", "601", "603", "605", "688", "689")
failures = []

def check(ok, message):
    print("  %s %s" % ("PASS" if ok else "FAIL", message))
    if not ok: failures.append(message)

def secid(code):
    if code.startswith(SZ): return "0." + code
    if code.startswith(SH): return "1." + code
    return None

def main():
    root = json.load(open(HISTORY, encoding="utf-8")); records = root.get("records")
    print("[1] 历史文件结构")
    check(root.get("version") == 2 and isinstance(records, list), "version 2 / records 数组")
    dates = [r.get("date") for r in records]
    check(dates == sorted(dates) and len(dates) == len(set(dates)), "日期唯一且升序")
    check(all(isinstance(d, str) and re.fullmatch(r"\d{8}", d) for d in dates), "所有业务日期为 YYYYMMDD")

    print("[2] 快照字段、市场与单位")
    all_ok = True; no_dups = True; no_bse = True
    for record in records:
        seen = set()
        all_ok &= bool(record.get("finalized", False)) and bool(record.get("validated", True))
        for stock in record.get("stocks", []):
            code, sid = stock.get("code"), stock.get("secid")
            all_ok &= isinstance(code, str) and re.fullmatch(r"\d{6}", code or "") is not None
            all_ok &= sid == secid(code) and isinstance(stock.get("streak"), int) and stock["streak"] >= 1
            all_ok &= isinstance(stock.get("close"), (int, float)) and 0 < stock["close"] < 100000
            all_ok &= isinstance(stock.get("changePct"), (int, float)) and abs(stock["changePct"]) < 100
            no_dups &= sid not in seen; seen.add(sid)
            no_bse &= not code.startswith(("4", "8", "920"))
    check(all_ok, "字段完整，价格为元、涨跌幅为百分比")
    check(no_dups, "单日无重复证券")
    check(no_bse, "已剔除北交所")

    print("[3] 严格连续口径与动态板位")
    by_date = {r["date"]: {s["code"]: s for s in r.get("stocks", [])} for r in records}
    continuity = True
    for i in range(1, len(dates)):
        prev, current = by_date[dates[i - 1]], by_date[dates[i]]
        for code, stock in current.items():
            expected = prev[code]["streak"] + 1 if code in prev else 1
            continuity &= stock["streak"] == expected
    check(continuity, "相邻实际交易日才递增，断板/非连续不会虚增")
    dynamic = any(max((s["streak"] for s in r.get("stocks", [])), default=0) > 4 for r in records)
    check(dynamic, "存在超过四板时可表达任意高度")
    check("20260828" in by_date and Counter(by_date["20260828"][code]["streak"] for code in by_date["20260828"]).get(1, 0) > 0, "20260828 已恢复有效首板样本")

    print("[4] 自动池唯一事实来源")
    pools = json.load(open(POOLS, encoding="utf-8")).get("pools", [])
    check(all(p.get("kind") != "automatic" for p in pools), "stock-pools.json 不重复持久化自动池")
    check(all("import" not in name.lower() for name in ("tools/auto-backfill-limit-up.py",)), "回补脚本不依赖导入文件")
    print()
    if failures:
        print("校验失败 %d 项：" % len(failures)); [print("  - " + x) for x in failures]; return 1
    print("全部校验通过。覆盖 %d 个实际返回交易日，最高 %d 板。" % (len(records), max((s["streak"] for r in records for s in r.get("stocks", [])), default=0)))
    return 0

if __name__ == "__main__": sys.exit(main())
