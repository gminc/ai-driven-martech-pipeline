#!/usr/bin/env python3
"""Day 06：雙邊對帳。本機從 CSV 算一份指標，BigQuery 用 verify.sql 算同一份，逐項比對。

    python3 bigquery/reconcile.py ./out                 # 在 synthesizer/ 目錄執行
    python3 bigquery/reconcile.py ./out --dataset martech_dw

整數與字串必須完全相同，浮點數容許 1e-9 相對誤差，任何一項不符就以結束碼 1 離開。
只用 Python 標準函式庫，BigQuery 端透過 bq 指令執行（Cloud Shell 內建）。
"""
from __future__ import annotations

import argparse
import csv
import json
import math
import subprocess
import sys
from collections import Counter, defaultdict
from datetime import date, datetime, timedelta, timezone
from decimal import Decimal
from pathlib import Path

HERE = Path(__file__).resolve().parent
TAIPEI = timezone(timedelta(hours=8))


def read(out: Path, name: str) -> list[dict]:
    with open(out / f"{name}.csv", encoding="utf-8", newline="") as f:
        return list(csv.DictReader(f))


def ctr(rows) -> float | None:
    imp = sum(int(r["impressions"]) for r in rows)
    return sum(int(r["clicks"]) for r in rows) / imp if imp else None


def div(a, b):
    return a / b if b else None


def local_metrics(out: Path, gt: dict) -> dict[str, object]:
    cr, ad, ev = read(out, "raw_creatives"), read(out, "raw_ad_daily"), read(out, "raw_events")
    od, cu = read(out, "raw_orders"), read(out, "raw_customers")
    m: dict[str, object] = {}
    for name, rows in [("raw_creatives", cr), ("raw_ad_daily", ad), ("raw_events", ev),
                       ("raw_orders", od), ("raw_customers", cu)]:
        m[f"rows.{name}"] = len(rows)
    m["ad.impressions"] = sum(int(r["impressions"]) for r in ad)
    m["ad.clicks"] = sum(int(r["clicks"]) for r in ad)
    m["ad.cost"] = f"{sum(Decimal(r['cost']) for r in ad):.2f}"
    m["orders.revenue"] = sum(int(o["revenue"]) for o in od)
    m["orders.quantity"] = sum(int(o["quantity"]) for o in od)
    m["orders.customers"] = len({o["customer_id"] for o in od})
    m["events.users"] = len({e["user_pseudo_id"] for e in ev})
    sessions = {(e["user_pseudo_id"], e["ga_session_id"]) for e in ev if e["event_name"] == "session_start"}
    m["events.sessions"] = len(sessions)
    m["events.purchase_value"] = f"{sum(Decimal(e['value']) for e in ev if e['event_name'] == 'purchase'):.2f}"
    for name, n in Counter(e["event_name"] for e in ev).items():
        m[f"events.{name}"] = n

    m["events.min_date"] = min(e["event_date"] for e in ev)
    m["events.max_date"] = max(e["event_date"] for e in ev)
    m["orders.min_date"] = min(o["order_date"] for o in od)
    m["orders.max_date"] = max(o["order_date"] for o in od)
    m["check.event_date_mismatch"] = sum(
        datetime.fromtimestamp(int(e["event_timestamp"]) / 1e6, TAIPEI).strftime("%Y%m%d") != e["event_date"]
        for e in ev)
    m["check.order_date_mismatch"] = sum(
        datetime.fromisoformat(o["order_ts"]).astimezone(TAIPEI).date().isoformat() != o["order_date"] for o in od)
    m["check.phone_leading_zero"] = sum(c["phone"].startswith("0") for c in cu)
    m["check.user_id_with_dot"] = sum("." in e["user_pseudo_id"] for e in ev)
    m["check.image_has_person_null"] = sum(c["format"] == "image" and c["has_person"] == "" for c in cr)

    by_ch = defaultdict(list)
    for r in ad:
        by_ch[r["channel"]].append(r)
    for ch, rows in by_ch.items():
        m[f"ctr.{ch}"] = ctr(rows)
    m["cvr.session"] = div(len(od), len(sessions))
    m["aov"] = div(sum(int(o["revenue"]) for o in od), len(od))

    # S1
    s1 = gt["S1_cpc_spike"]
    g = [r for r in ad if r["ad_group_id"] == s1["ad_group_id"]]

    def cpc(rows):
        return div(float(sum(Decimal(r["cost"]) for r in rows)), sum(int(r["clicks"]) for r in rows))
    m["s1.cpc_before"] = cpc([r for r in g if r["date"] < s1["start_date"]])
    m["s1.cpc_after"] = cpc([r for r in g if r["date"] >= s1["start_date"]])
    # S2
    d2 = gt["S2_tracking_outage"]["date"]
    m["s2.purchase_events"] = sum(e["event_name"] == "purchase" and e["event_date"] == d2.replace("-", "") for e in ev)
    m["s2.orders"] = sum(o["order_date"] == d2 for o in od)
    tx_ev = {e["transaction_id"] for e in ev if e["event_name"] == "purchase" and e["transaction_id"]}
    m["s2.orders_without_event_elsewhere"] = sum(o["order_date"] != d2 and o["transaction_id"] not in tx_ev for o in od)
    # S3
    s3 = gt["S3_creative_fatigue"]
    rows = [r for r in ad if r["creative_id"] == s3["creative_id"] and int(r["clicks"]) > 0
            and r["date"] >= s3["anchor_date"]]
    xs = [(date.fromisoformat(r["date"]) - date.fromisoformat(s3["anchor_date"])).days / 7 for r in rows]
    ys = [math.log(int(r["clicks"]) / int(r["impressions"])) for r in rows]
    m["s3.weekly_decay"] = None
    if len(xs) >= 2:
        mx, my = sum(xs) / len(xs), sum(ys) / len(ys)
        slope = div(sum((x - mx) * (y - my) for x, y in zip(xs, ys)), sum((x - mx) ** 2 for x in xs))
        m["s3.weekly_decay"] = None if slope is None else 1 - math.exp(slope)
    # S4
    crs = {c["creative_id"]: c for c in cr}
    per = defaultdict(list)
    for r in ad:
        if crs[r["creative_id"]]["format"] == "image" and r["creative_id"] != s3["creative_id"]:
            per[r["creative_id"]].append(r)
    c_ctr = {k: ctr(v) for k, v in per.items() if ctr(v)}
    for attr, key, val in [("person", "has_person", "True"), ("cta", "cta_position", "bottom_right"),
                           ("warm", "dominant_color", "warm")]:
        num = den = 0.0
        for stratum in {(crs[k]["channel"], crs[k]["audience"]) for k in c_ctr}:
            ks = [k for k in c_ctr if (crs[k]["channel"], crs[k]["audience"]) == stratum]
            yes = [c_ctr[k] for k in ks if crs[k][key] == val]
            no = [c_ctr[k] for k in ks if crs[k][key] != val]
            if yes and no:
                gy = math.exp(sum(math.log(x) for x in yes) / len(yes))
                gn = math.exp(sum(math.log(x) for x in no) / len(no))
                w = len(yes) * len(no) / (len(yes) + len(no))
                num += math.log(gy / gn) * w
                den += w
        if den:
            m[f"s4.{attr}"] = math.exp(num / den)
    # S5
    n_orders = Counter(o["customer_id"] for o in od)
    hist = Counter(min(n, 3) for n in n_orders.values())
    for n, c in hist.items():
        m[f"s5.customers_with_{n}{'_plus' if n == 3 else ''}_orders"] = c
    # S6
    by_user = defaultdict(list)
    for e in ev:
        if e["event_name"] == "session_start":
            by_user[e["user_pseudo_id"]].append((int(e["event_timestamp"]), e["utm_source"] + "/" + e["utm_medium"]))
    first_tx = {}
    for o in sorted(od, key=lambda r: (r["order_ts"], r["transaction_id"])):
        first_tx.setdefault(o["user_pseudo_id"], o["transaction_id"])
    buy = {e["user_pseudo_id"]: int(e["event_timestamp"]) for e in ev
           if e["event_name"] == "purchase" and first_tx.get(e["user_pseudo_id"]) == e["transaction_id"]}
    first, last = Counter(), Counter()
    for u, ts in buy.items():
        path = [x for x in sorted(by_user.get(u, [])) if x[0] <= ts]
        if len(path) >= 2:
            first[path[0][1]] += 1
            last[path[-1][1]] += 1
    m["s6.meta_first"], m["s6.meta_last"] = first["meta/paid_social"], last["meta/paid_social"]
    m["s6.google_cpc_first"], m["s6.google_cpc_last"] = first["google/cpc"], last["google/cpc"]
    # S7
    s7 = gt["S7_autumn_uplift"]
    s7_start = date.fromisoformat(s7["start_date"])
    pre_from = (s7_start - timedelta(days=21)).isoformat()

    def share(rs):
        q = sum(int(o["quantity"]) for o in rs)
        return div(sum(int(o["quantity"]) for o in rs if o["item_id"] in s7["product_ids"]), q)
    m["s7.share_window"] = share([o for o in od if s7["start_date"] <= o["order_date"] <= s7["end_date"]])
    m["s7.share_pre"] = share([o for o in od if pre_from <= o["order_date"] < s7["start_date"]])
    return m


def bq_metrics(gt: dict, project: str, dataset: str, location: str) -> dict[str, str | None]:
    s1, s2, s3, s7 = (gt["S1_cpc_spike"], gt["S2_tracking_outage"], gt["S3_creative_fatigue"],
                      gt["S7_autumn_uplift"])
    params = [
        f"s1_group:STRING:{s1['ad_group_id']}", f"s1_start:DATE:{s1['start_date']}",
        f"s2_date:DATE:{s2['date']}",
        f"s3_creative:STRING:{s3['creative_id']}", f"s3_anchor:DATE:{s3['anchor_date']}",
        f"s7_start:DATE:{s7['start_date']}", f"s7_end:DATE:{s7['end_date']}",
        f"s7_products:ARRAY<STRING>:{json.dumps(s7['product_ids'])}",
    ]
    cmd = ["bq", "--headless", "--quiet", f"--location={location}", f"--project_id={project}", "query",
           "--use_legacy_sql=false", "--format=json", "--max_rows=1000", f"--dataset_id={project}:{dataset}"]
    cmd += [f"--parameter={p}" for p in params]
    sql = (HERE / "verify.sql").read_text(encoding="utf-8")
    res = subprocess.run(cmd, input=sql, capture_output=True, text=True)
    if res.returncode != 0:
        sys.exit(f"❌ bq query 失敗：\n{res.stdout}\n{res.stderr}")
    body = res.stdout[res.stdout.find("["):]
    return {r["metric"]: r.get("value") for r in json.loads(body)}


def same(local: object, remote: str | None) -> bool:
    if local is None or remote is None:
        return local is None and remote is None
    if isinstance(local, float):
        r = float(remote)
        return math.isclose(local, r, rel_tol=1e-9, abs_tol=1e-12)
    return str(local) == remote


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("out", nargs="?", default="./out")
    ap.add_argument("--dataset", default="martech_dw")
    ap.add_argument("--location", default="US")
    ap.add_argument("--project", default=None, help="預設取 gcloud config 的專案")
    a = ap.parse_args()
    project = a.project or subprocess.run(["gcloud", "config", "get-value", "project"], capture_output=True,
                                          text=True).stdout.strip()
    if not project or project == "(unset)":
        sys.exit("❌ 尚未設定專案，請先 gcloud config set project <專案 ID>")
    gt = json.loads((HERE.parent / "ground_truth.json").read_text(encoding="utf-8"))
    local = local_metrics(Path(a.out), gt)
    remote = bq_metrics(gt, project, a.dataset, a.location)
    bad = 0
    for k in sorted(set(local) | set(remote)):
        lv, rv = local.get(k), remote.get(k)
        ok = k in local and k in remote and same(lv, rv)
        bad += not ok
        show = (lambda v: f"{v:.6g}" if isinstance(v, float) else str(v))
        rshow = rv if rv is None or not isinstance(lv, float) else f"{float(rv):.6g}"
        print(f"{'✅' if ok else '❌'} {k:<38} 本機 {show(lv) if lv is not None else '—':>12}   BigQuery {rshow or '—':>12}")
    print(f"\n{len(set(local) | set(remote)) - bad} 項一致、{bad} 項不一致")
    sys.exit(1 if bad else 0)


if __name__ == "__main__":
    main()
