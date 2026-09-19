#!/usr/bin/env python3
"""讀合成器輸出的 CSV，檢查資料完整性、統計目標與七個植入訊號（Day 06／Day 13 共用）。

    python3 validate.py ./out

每一項會印出 PASS、FAIL 或 SKIP，SKIP 代表這份資料的期間不涵蓋該訊號，不算失敗。
"""
from __future__ import annotations

import csv
import json
import math
import sys
from collections import Counter, defaultdict
from datetime import date, datetime, timedelta, timezone
from pathlib import Path

HERE = Path(__file__).resolve().parent
TAIPEI = timezone(timedelta(hours=8))
PASS, FAIL, SKIP = "PASS", "FAIL", "SKIP"


def read(out: Path, name: str) -> list[dict]:
    with open(out / name, encoding="utf-8") as f:
        return list(csv.DictReader(f))


def ctr(rows) -> float:
    imp = sum(int(r["impressions"]) for r in rows)
    return sum(int(r["clicks"]) for r in rows) / imp if imp else 0.0


def check(out: Path) -> list[tuple[str, str, str]]:
    gt = json.loads((HERE / "ground_truth.json").read_text(encoding="utf-8"))
    products = {p["id"]: p for p in json.loads(
        (HERE.parent / "live-demo" / "products.json").read_text(encoding="utf-8"))["products"]}
    ads, events = read(out, "raw_ad_daily.csv"), read(out, "raw_events.csv")
    orders, customers = read(out, "raw_orders.csv"), read(out, "raw_customers.csv")
    creatives = {c["creative_id"]: c for c in read(out, "raw_creatives.csv")}
    res: list[tuple[str, str, str]] = []

    def add(name, ok, detail=""):
        res.append((name, PASS if ok else FAIL, detail))

    def skip(name, why):
        res.append((name, SKIP, why))

    ad_dates = sorted({r["date"] for r in ads})
    start, end = date.fromisoformat(ad_dates[0]), date.fromisoformat(ad_dates[-1])
    days = (end - start).days + 1

    def covers(d: str, before: int = 0, after: int = 0) -> bool:
        x = date.fromisoformat(d)
        return start + timedelta(days=before) <= x <= end - timedelta(days=after)

    # ── 參照完整性與格式 ──
    add("item_id 都在 products.json", all(e["item_id"] in products for e in events if e["item_id"])
        and all(o["item_id"] in products for o in orders))
    add("item_variant 都是原字串",
        all(o["item_variant"] in products[o["item_id"]]["size_options"] for o in orders)
        and all(e["item_variant"] in products[e["item_id"]]["size_options"] for e in events if e["item_variant"]))
    add("金額 = 定價 × 數量", all(int(o["revenue"]) == products[o["item_id"]]["price"] * int(o["quantity"])
                              for o in orders))
    tx_orders = {o["transaction_id"] for o in orders}
    tx_events = [e["transaction_id"] for e in events if e["event_name"] == "purchase"]
    add("purchase 事件都對得到訂單", set(tx_events) <= tx_orders and len(tx_events) == len(set(tx_events)))
    add("訂單編號唯一且不超過 20 碼", len(tx_orders) == len(orders) and all(len(t) <= 20 for t in tx_orders))
    cust = {c["customer_id"]: c for c in customers}
    add("訂單顧客都在顧客表", {o["customer_id"] for o in orders} <= set(cust))
    first_order = {}
    for o in sorted(orders, key=lambda r: r["order_ts"]):
        first_order.setdefault(o["customer_id"], o["order_date"])
    add("顧客首購日 = 第一筆訂單日期", all(first_order.get(k) == c["first_order_date"] for k, c in cust.items()))
    add("素材 ID 都在素材表", {r["creative_id"] for r in ads} <= set(creatives)
        and {e["creative_id"] for e in events if e["creative_id"]} <= set(creatives))
    add("點擊不超過曝光、花費不為負",
        all(0 <= int(r["clicks"]) <= int(r["impressions"]) and float(r["cost"]) >= 0 for r in ads))
    first, last = start.strftime("%Y%m%d"), end.strftime("%Y%m%d")
    add("事件與訂單都在期間內",
        all(first <= e["event_date"] <= last for e in events)
        and all(start.isoformat() <= o["order_date"] <= end.isoformat() for o in orders))
    add("event_date = event_timestamp 的台北日期",
        all(datetime.fromtimestamp(int(e["event_timestamp"]) / 1e6, TAIPEI).strftime("%Y%m%d") == e["event_date"]
            for e in events))
    first_event = {}
    for e in sorted(events, key=lambda r: int(r["event_timestamp"])):
        first_event.setdefault(e["user_pseudo_id"], e)
    add("每位訪客的第一個事件都是 first_visit",
        all(e["event_name"] == "first_visit" for e in first_event.values()), f"{len(first_event)} 位訪客")
    add("user_pseudo_id 後綴為首次造訪時間",
        all(int(e["event_timestamp"]) // 10**6 == int(u.split(".")[1]) for u, e in first_event.items()))
    sess = Counter((e["user_pseudo_id"], e["ga_session_id"]) for e in events if e["event_name"] == "session_start")
    add("工作階段不重複", not sess or max(sess.values()) == 1, f"{len(sess)} 個工作階段")
    starts = defaultdict(list)
    for (u, sid) in sess:
        starts[u].append(int(sid))
    gap_ok = all(b - a > 30 * 60 for v in starts.values() for a, b in zip(sorted(v), sorted(v)[1:]))
    add("同一人兩次工作階段間隔超過 30 分鐘", gap_ok)

    # ── 統計目標 ──
    by_ch = defaultdict(list)
    for r in ads:
        by_ch[r["channel"]].append(r)
    for ch in sorted(by_ch):
        v = ctr(by_ch[ch])
        add(f"CTR {ch} 在 1.5–3.5%", 0.015 <= v <= 0.035, f"{v:.2%}")
    if days == 90:
        cvr = len(orders) / max(len(sess), 1)
        add("CVR 在 1.8–2.5%", 0.018 <= cvr <= 0.025, f"{cvr:.2%}")
    else:
        skip("CVR 在 1.8–2.5%", f"期間 {days} 天，回訪比例不同，只有 90 天時檢查")
    if days == 90:
        add("事件量約 50 萬筆", 400_000 <= len(events) <= 600_000, f"{len(events):,}")
    else:
        skip("事件量約 50 萬筆", f"期間 {days} 天，只有 90 天時檢查")

    # ── S1 CPC 翻倍 ──
    s1 = gt["S1_cpc_spike"]
    if covers(s1["start_date"], before=7, after=6):
        g = [r for r in ads if r["ad_group_id"] == s1["ad_group_id"]]

        def cpc(rows):
            c = sum(int(r["clicks"]) for r in rows)
            return sum(float(r["cost"]) for r in rows) / c if c else 0.0
        before = cpc([r for r in g if r["date"] < s1["start_date"]])
        after = cpc([r for r in g if r["date"] >= s1["start_date"]])
        m = s1["cpc_multiplier"]
        add("S1 CPC 前後比接近設定值", before and 0.85 * m <= after / before <= 1.15 * m,
            f"{before:.1f} → {after:.1f}（設定 ×{m}）")
    else:
        skip("S1 CPC 前後比接近設定值", "期間不涵蓋異常前後")

    # ── S2 purchase 事件整天消失，訂單還在 ──
    d2 = gt["S2_tracking_outage"]["date"]
    if covers(d2):
        ev = sum(1 for e in events if e["event_name"] == "purchase" and e["event_date"] == d2.replace("-", ""))
        od = sum(1 for o in orders if o["order_date"] == d2)
        add("S2 當天 purchase 事件 0、訂單 > 0", ev == 0 and od > 0, f"事件 {ev}、訂單 {od}")
    else:
        skip("S2 當天 purchase 事件 0、訂單 > 0", "期間不涵蓋該日")
    tx_event_set = set(tx_events)
    add("S2 以外的日子每筆訂單都有 purchase 事件",
        all(o["transaction_id"] in tx_event_set for o in orders if o["order_date"] != d2))

    # ── S3 素材疲乏：用每日 CTR 取對數做線性迴歸估每週衰退率 ──
    s3 = gt["S3_creative_fatigue"]
    rows = [r for r in ads if r["creative_id"] == s3["creative_id"] and int(r["clicks"]) > 0
            and r["date"] >= s3["anchor_date"]]
    if len(rows) >= 42:
        xs = [(date.fromisoformat(r["date"]) - date.fromisoformat(s3["anchor_date"])).days / 7 for r in rows]
        ys = [math.log(int(r["clicks"]) / int(r["impressions"])) for r in rows]
        mx, my = sum(xs) / len(xs), sum(ys) / len(ys)
        slope = sum((x - mx) * (y - my) for x, y in zip(xs, ys)) / sum((x - mx) ** 2 for x in xs)
        decay = 1 - math.exp(slope)
        want = s3["weekly_ctr_decay"]
        add("S3 每週衰退率接近設定值", abs(decay - want) <= 0.025, f"估計 {decay:.1%}（設定 {want:.0%}）")
    else:
        skip("S3 每週衰退率接近設定值", "資料少於 6 週")

    # ── S4 視覺屬性：同通路同受眾內比較素材層級 CTR，排除 S3 素材 ──
    s4 = gt["S4_visual_effects"]
    per_creative = defaultdict(list)
    for r in ads:
        c = creatives[r["creative_id"]]
        if c["format"] == "image" and r["creative_id"] != s3["creative_id"]:
            per_creative[r["creative_id"]].append(r)
    c_ctr = {k: ctr(v) for k, v in per_creative.items()}
    tests = [("有人物", "has_person", "True", s4["has_person"]),
             ("CTA 在右下", "cta_position", "bottom_right", s4["cta_bottom_right"]),
             ("暖色系", "dominant_color", "warm", s4["dominant_color_warm"])]
    for label, key, val, want in tests:
        if days < 60:
            skip(f"S4 {label}的 CTR 較高", "期間少於 60 天，素材層級樣本不足")
            continue
        logs, weights = [], []
        for stratum in sorted({(creatives[k]["channel"], creatives[k]["audience"]) for k in c_ctr}):
            ks = [k for k in c_ctr if (creatives[k]["channel"], creatives[k]["audience"]) == stratum]
            yes = [c_ctr[k] for k in ks if creatives[k][key] == val]
            no = [c_ctr[k] for k in ks if creatives[k][key] != val]
            if yes and no:
                gy = math.exp(sum(math.log(x) for x in yes) / len(yes))
                gn = math.exp(sum(math.log(x) for x in no) / len(no))
                logs.append(math.log(gy / gn))
                weights.append(len(yes) * len(no) / (len(yes) + len(no)))
        if weights:
            est = math.exp(sum(l * w for l, w in zip(logs, weights)) / sum(weights))
            add(f"S4 {label}的 CTR 較高", est > 1 + (want - 1) * 0.4, f"估計 ×{est:.2f}（設定 ×{want}）")
        else:
            skip(f"S4 {label}的 CTR 較高", "素材不足")

    # ── S5 顧客類型：回購集中在 sock_regular，dormant 幾乎不回購 ──
    seg = {r["customer_id"]: r["segment"] for r in read(out / "ground_truth", "customer_segments.csv")}
    n_orders = Counter(o["customer_id"] for o in orders)
    avg = {}
    for s in sorted(set(seg.values())):
        v = [n_orders[c] for c in seg if seg[c] == s]
        avg[s] = round(sum(v) / len(v), 2)
    if days >= 60 and avg:
        add("S5 高頻買襪客平均訂單數最高", max(avg, key=avg.get) == "sock_regular", json.dumps(avg))
        add("S5 沉睡客不回購", avg.get("dormant", 1.0) == 1.0, f"dormant 平均 {avg.get('dormant')}")
    else:
        skip("S5 顧客類型", "期間少於 60 天，回購還來不及發生")

    # ── S6 路徑位置：只看第一次購買之前的路徑 ──
    by_user = defaultdict(list)
    for e in events:
        if e["event_name"] == "session_start":
            by_user[e["user_pseudo_id"]].append((int(e["event_timestamp"]), e["utm_source"] + "/" + e["utm_medium"]))
    first_tx = {}
    for o in sorted(orders, key=lambda r: r["order_ts"]):
        first_tx.setdefault(o["user_pseudo_id"], o["transaction_id"])
    buy_ts = {e["user_pseudo_id"]: int(e["event_timestamp"]) for e in events
              if e["event_name"] == "purchase" and first_tx.get(e["user_pseudo_id"]) == e["transaction_id"]}
    first_touch, last_touch = Counter(), Counter()
    for u, ts in buy_ts.items():
        path = [x for x in sorted(by_user.get(u, [])) if x[0] <= ts]
        if len(path) >= 2:
            first_touch[path[0][1]] += 1
            last_touch[path[-1][1]] += 1
    if days >= 60 and sum(first_touch.values()) >= 100:
        add("S6 meta 當第一觸點多於最後觸點", first_touch["meta/paid_social"] > 1.5 * last_touch["meta/paid_social"],
            f"第一 {first_touch['meta/paid_social']}、最後 {last_touch['meta/paid_social']}")
        add("S6 google cpc 當最後觸點多於第一觸點", last_touch["google/cpc"] > 1.5 * first_touch["google/cpc"],
            f"第一 {first_touch['google/cpc']}、最後 {last_touch['google/cpc']}")
    else:
        skip("S6 路徑位置", "期間少於 60 天或多觸點購買路徑少於 100 條")

    # ── S7 秋日專案商品占比上升 ──
    s7 = gt["S7_autumn_uplift"]
    s7_start = date.fromisoformat(s7["start_date"])
    if covers(s7["start_date"], before=21) and covers(s7["start_date"], after=6):
        def share(rs):
            q = sum(int(o["quantity"]) for o in rs)
            return sum(int(o["quantity"]) for o in rs if o["item_id"] in s7["product_ids"]) / q if q else 0.0
        win = [o for o in orders if s7["start_date"] <= o["order_date"] <= s7["end_date"]]
        pre = [o for o in orders if (s7_start - timedelta(days=21)).isoformat() <= o["order_date"] < s7["start_date"]]
        add("S7 專案期間專案商品占比高於前三週", share(win) > share(pre) * 1.1, f"{share(pre):.1%} → {share(win):.1%}")
    else:
        skip("S7 專案期間專案商品占比高於前三週", "期間不涵蓋專案前後")
    return res


def main():
    out = Path(sys.argv[1] if len(sys.argv) > 1 else "./out")
    results = check(out)
    for name, status, detail in results:
        print(f"{status}  {name}  {detail}")
    sys.exit(1 if any(s == FAIL for _, s, _ in results) else 0)


if __name__ == "__main__":
    main()
