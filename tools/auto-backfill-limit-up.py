#!/usr/bin/env python3
"""使用东方财富 getTopicZTPool 受保护地回补涨停梯队历史。

仅使用东方财富；非交易日、日期不匹配、分页不完整或字段异常均不写入。
"""
import json, os, re, ssl, tempfile, time, urllib.parse, urllib.request
from datetime import date, timedelta

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PATH = os.path.join(ROOT, "data", "limit-up-history.json")
POOLS_PATH = os.path.join(ROOT, "data", "stock-pools.json")
ENDPOINT = "https://push2ex.eastmoney.com/getTopicZTPool"
UT = "7eea3edcaed734bea9cbfc24409ed989"
SZ = ("000", "001", "002", "003", "300", "301")
SH = ("600", "601", "603", "605", "688", "689")

def secid(code):
    if code.startswith(SZ): return "0." + code
    if code.startswith(SH): return "1." + code
    return None

def fetch(day):
    params = {"ut": UT, "dpt": "wz.ztzt", "Pageindex": 0, "pagesize": 10000, "sort": "fbt:asc", "date": day}
    url = ENDPOINT + "?" + urllib.parse.urlencode(params)
    req = urllib.request.Request(url, headers={"User-Agent": "Mozilla/5.0", "Referer": "https://quote.eastmoney.com/ztb/"})
    # 当前运行环境的系统 CA 链缺少东财证书链；应用本身使用 URLSession 校验证书。
    with urllib.request.urlopen(req, context=ssl._create_unverified_context(), timeout=15) as response:
        root = json.loads(response.read())
    data = root.get("data")
    if root.get("rc") != 0 or not isinstance(data, dict):
        return None
    qdate = str(data.get("qdate", ""))
    pool, total = data.get("pool"), data.get("tc")
    if int(day) > int(qdate): return None
    if not isinstance(pool, list) or not isinstance(total, int) or len(pool) != total:
        raise ValueError("分页不完整：声明 %s，采集 %s" % (total, len(pool) if isinstance(pool, list) else "非数组"))
    if total == 0: return None
    stocks, seen = [], set()
    for row in pool:
        code, market, name = str(row.get("c", "")), row.get("m"), str(row.get("n", ""))
        sid = secid(code)
        if code.startswith(("4", "8", "920")): continue
        if not re.fullmatch(r"\d{6}", code) or market not in (0, 1) or not name or sid != "%s.%s" % (market, code):
            raise ValueError("字段或市场映射异常：%r" % row)
        if sid in seen: raise ValueError("重复证券：" + sid)
        price, pct, upstream = row.get("p"), row.get("zdp"), row.get("lbc")
        if not isinstance(price, (int, float)) or price <= 0 or not isinstance(pct, (int, float)) or not isinstance(upstream, int) or upstream < 1:
            raise ValueError("价格/涨跌幅/板位字段异常：%r" % row)
        seen.add(sid)
        stocks.append({"code": code, "name": name, "secid": sid, "market": market, "dataDate": day,
                       "close": price / 1000.0, "changePct": float(pct), "streak": upstream})
    return stocks

def atomic_write(root):
    directory = os.path.dirname(PATH)
    fd, tmp = tempfile.mkstemp(prefix=".limit-up-history.", suffix=".tmp", dir=directory)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f: json.dump(root, f, ensure_ascii=False, indent=2, sort_keys=True); f.write("\n"); f.flush(); os.fsync(f.fileno())
        os.replace(tmp, PATH)
    finally:
        if os.path.exists(tmp): os.unlink(tmp)

def migrate_pools():
    """旧版自动池是重复投影，迁移时只去掉 automatic，不触碰用户池。"""
    with open(POOLS_PATH, encoding="utf-8") as f: root = json.load(f)
    pools = root.get("pools", [])
    manual = [p for p in pools if p.get("kind") != "automatic"]
    if len(manual) == len(pools): return False
    root["pools"] = manual
    directory = os.path.dirname(POOLS_PATH); fd, tmp = tempfile.mkstemp(prefix=".stock-pools.", suffix=".tmp", dir=directory)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f: json.dump(root, f, ensure_ascii=False, indent=2, sort_keys=True); f.write("\n"); f.flush(); os.fsync(f.fileno())
        os.replace(tmp, POOLS_PATH)
    finally:
        if os.path.exists(tmp): os.unlink(tmp)
    return True

def main():
    migrated = migrate_pools()
    with open(PATH, encoding="utf-8") as f: root = json.load(f)
    records = {r["date"]: r for r in root.get("records", []) if isinstance(r, dict) and re.fullmatch(r"\d{8}", str(r.get("date", "")))}
    rebuilt, failures, previous = [], [], None
    start, end = date(2026, 8, 10), date.today()
    day = start
    while day <= end:
        day_text = day.strftime("%Y%m%d")
        if day.weekday() >= 5:
            records.pop(day_text, None)
            day += timedelta(days=1)
            continue
        try:
            stocks = fetch(day_text)
            if stocks is not None:
                if previous:
                    prior = {s["code"]: s["streak"] for s in previous["stocks"]}
                    for stock in stocks: stock["streak"] = prior.get(stock["code"], 0) + 1
                record = {"date": day_text, "source": "东方财富", "generatedAt": int(time.time() * 1000), "finalized": True, "validated": True, "stocks": sorted(stocks, key=lambda s: (-s["streak"], s["code"]))}
                records[day_text] = record; previous = record; rebuilt.append(day_text)
        except Exception as exc:
            failures.append("%s: %s" % (day_text, exc))
        day += timedelta(days=1)
    root["version"] = 2; root["updatedAt"] = int(time.time() * 1000); root["records"] = [records[k] for k in sorted(records)]
    if rebuilt: atomic_write(root)
    print("回补成功 %d 日：%s" % (len(rebuilt), ",".join(rebuilt)))
    if migrated: print("已迁移 stock-pools.json：保留自定义池，移除旧自动池重复记录")
    if failures: print("待重试 %d 项：%s" % (len(failures), "；".join(failures)))
    return 0

if __name__ == "__main__": raise SystemExit(main())
