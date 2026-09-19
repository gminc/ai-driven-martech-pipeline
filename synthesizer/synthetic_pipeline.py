#!/usr/bin/env python3
"""織日常 電商大數據合成器（雙軌資料架構的軌道 B）

只用 Python 標準函式庫，Cloud Shell 內建的 python3 就能直接執行：

    python3 synthetic_pipeline.py --days 7 --out ./sample     # 先跑一週看看
    python3 synthetic_pipeline.py --out ./out                 # 完整 90 天

商品、價格與尺寸直接讀 live-demo/products.json，素材規格讀 creatives.json，
植入的訊號讀 ground_truth.json，三份檔案就是這個合成器的資料契約。
同一個 --seed 一定產生一模一樣的資料。
"""
from __future__ import annotations

import argparse
import csv
import json
import math
import random
from collections import Counter, defaultdict
from datetime import date, datetime, timedelta, timezone
from pathlib import Path

HERE = Path(__file__).resolve().parent
PRODUCTS_FILE = HERE.parent / "live-demo" / "products.json"
CREATIVES_FILE = HERE / "creatives.json"
GROUND_TRUTH_FILE = HERE / "ground_truth.json"

TAIPEI = timezone(timedelta(hours=8))
DEFAULT_START = date(2026, 6, 19)
DEFAULT_DAYS = 90
DEFAULT_SEED = 20260919

# 通路定義：utm 三欄沿用 Live Demo 的 utm_source|utm_medium|utm_campaign
CHANNELS = {
    "google_cpc": {"source": "google", "medium": "cpc"},
    "meta": {"source": "meta", "medium": "paid_social"},
    "line": {"source": "line", "medium": "display"},
    "email": {"source": "newsletter", "medium": "email"},
    "organic": {"source": "google", "medium": "organic"},
    "direct": {"source": "(direct)", "medium": "(none)"},
}

# 付費通路的每日基準：每張素材的曝光、點擊率、單次點擊成本（新台幣）
PAID_BASE = {
    "google_cpc": {"impressions": 2200, "ctr": 0.030, "cpc": 12.0, "weekend": 0.90},
    "meta": {"impressions": 4600, "ctr": 0.017, "cpc": 8.0, "weekend": 1.15},
    "line": {"impressions": 4000, "ctr": 0.0165, "cpc": 6.0, "weekend": 1.10},
}
LANDING_RATE = 0.90          # 點擊後真的載入頁面的比例（其餘在載入前就離開）
ORGANIC_PER_DAY = 260
DIRECT_PER_DAY = 140
NEWSLETTER_CLICKS_PER_DAY = 40
WARM_DAYS = 14               # 訪客最後一次造訪後幾天內仍算「還在考慮」

# 一天 24 小時的造訪權重（台北時間）：午休與晚上是高峰
HOUR_WEIGHTS = [2, 1, 1, 1, 1, 1, 2, 3, 4, 5, 6, 7, 9, 8, 6, 6, 6, 6, 7, 8, 10, 11, 10, 6]

CITIES = [("新北市", 17), ("臺中市", 12), ("高雄市", 12), ("臺北市", 11), ("桃園市", 10),
          ("臺南市", 8), ("彰化縣", 5), ("屏東縣", 3), ("新竹縣", 3), ("新竹市", 2),
          ("苗栗縣", 2), ("雲林縣", 3), ("嘉義縣", 2), ("嘉義市", 1), ("南投縣", 2),
          ("宜蘭縣", 2), ("基隆市", 2), ("花蓮縣", 1), ("臺東縣", 1), ("澎湖縣", 1)]
SURNAMES = "陳林黃張李王吳劉蔡楊許鄭謝洪郭邱曾廖賴徐周葉蘇莊呂江何蕭羅高"
GIVEN = "怡君雅婷志明俊傑家豪淑芬美玲建宏宗翰佳穎冠宇詩涵承恩品妍子晴宥廷思妤柏翰欣怡"

EVENT_FIELDS = ["event_date", "event_timestamp", "event_name", "user_pseudo_id", "ga_session_id",
                "customer_id", "utm_source", "utm_medium", "utm_campaign", "creative_id",
                "promotion_id", "item_id", "item_variant", "quantity", "value", "transaction_id",
                "data_source"]
AD_FIELDS = ["date", "creative_id", "ad_group_id", "channel", "utm_campaign", "impressions",
             "clicks", "cost"]
ORDER_FIELDS = ["transaction_id", "order_ts", "order_date", "customer_id", "user_pseudo_id",
                "item_id", "item_variant", "quantity", "unit_price", "revenue", "utm_source",
                "utm_medium", "utm_campaign", "payment_status"]
CUSTOMER_FIELDS = ["customer_id", "name", "email", "phone", "city", "first_order_date"]
CREATIVE_FIELDS = ["creative_id", "channel", "utm_campaign", "promotion_id", "ad_group_id",
                   "audience", "format", "start_date", "end_date", "product_focus", "has_person",
                   "cta_position", "dominant_color", "text_density", "image_file"]


def load_json(path: Path) -> dict:
    with open(path, encoding="utf-8") as f:
        return json.load(f)


def parse_day(s: str | None) -> date | None:
    return date.fromisoformat(s) if s else None


class Synthesizer:
    def __init__(self, start: date, days: int, seed: int):
        self.start, self.days = start, days
        self.end = start + timedelta(days=days - 1)
        self.rng = random.Random(seed)
        catalog = load_json(PRODUCTS_FILE)
        self.products = {p["id"]: p for p in catalog["products"]}
        self.creatives = load_json(CREATIVES_FILE)["creatives"]
        self.gt = load_json(GROUND_TRUTH_FILE)
        self.campaign_products = {c["slug"]: c["product_ids"] for c in catalog["campaigns"]}
        self.campaign_products["evergreen"] = list(self.products)
        self.promotion_of = {c["slug"]: c["promotion_id"] for c in catalog["campaigns"]}
        self._check_contract()
        # 每張素材固定的個體差異（同樣屬性的兩張圖成效也不會完全一樣）
        self.creative_noise = {c["creative_id"]: self.rng.lognormvariate(0, 0.04) for c in self.creatives}
        self.adgroup_cpc = {c["ad_group_id"]: self.rng.lognormvariate(0, 0.08) for c in self.creatives}
        # 輸出
        self.ad_rows, self.events, self.orders, self.customers = [], [], [], []
        self.segments = {}
        # 狀態
        self.users = {}                     # user_pseudo_id -> {"sessions", "last", "customer_id"}
        self.warm = []                      # 還在考慮、尚未購買的訪客
        self.customer_user = {}             # customer_id -> user_pseudo_id
        self.planned = defaultdict(list)    # date -> [(customer_id, channel_key)] 預定回購
        self.used_ids = set()

    # ── 契約檢查：素材與商品必須對得上 Live Demo ─────────────────────────────
    def _check_contract(self):
        for c in self.creatives:
            if c["product_focus"] not in self.products:
                raise ValueError(f"素材 {c['creative_id']} 的商品 {c['product_focus']} 不在 products.json")
            if c["utm_campaign"] not in self.campaign_products:
                raise ValueError(f"素材 {c['creative_id']} 的活動 {c['utm_campaign']} 不存在")
        for pid in self.gt["S7_autumn_uplift"]["product_ids"]:
            if pid not in self.products:
                raise ValueError(f"S7 商品 {pid} 不在 products.json")
        if self.gt["S1_cpc_spike"]["ad_group_id"] not in {c["ad_group_id"] for c in self.creatives}:
            raise ValueError("S1 的廣告群組不在 creatives.json")
        if self.gt["S3_creative_fatigue"]["creative_id"] not in {c["creative_id"] for c in self.creatives}:
            raise ValueError("S3 的素材不在 creatives.json")
        if self.gt["S2_tracking_outage"]["dropped_event"] != "purchase":
            raise ValueError("S2 目前只支援刪除 purchase 事件")

    # ── 小工具 ──────────────────────────────────────────────────────────────
    def count(self, mean: float) -> int:
        """近似二項／卜瓦松的整數抽樣，平均為 mean。"""
        if mean <= 0:
            return 0
        if mean < 30:
            # 卜瓦松（Knuth），小樣本時精確
            limit, k, p = math.exp(-mean), 0, 1.0
            while True:
                p *= self.rng.random()
                if p <= limit:
                    return k
                k += 1
        return max(0, round(self.rng.gauss(mean, math.sqrt(mean))))

    def weighted(self, pairs):
        items, weights = zip(*pairs)
        return self.rng.choices(items, weights=weights, k=1)[0]

    def day_factor(self, d: date) -> float:
        t = (d - self.start).days / max(self.days - 1, 1)
        return 1.0 + 0.10 * t      # 90 天內自然成長約 10%

    def timestamp(self, d: date) -> datetime:
        hour = self.rng.choices(range(24), weights=HOUR_WEIGHTS, k=1)[0]
        return datetime(d.year, d.month, d.day, hour, self.rng.randrange(60),
                        self.rng.randrange(60), self.rng.randrange(1_000_000), tzinfo=TAIPEI)

    def creative_active(self, c: dict, d: date) -> bool:
        s, e = parse_day(c.get("start_date")), parse_day(c.get("end_date"))
        return (s is None or d >= s) and (e is None or d <= e)

    # ── 第一步：廣告每日成效 ────────────────────────────────────────────────
    def visual_multiplier(self, c: dict) -> float:
        if c["format"] != "image":
            return 1.0
        s4 = self.gt["S4_visual_effects"]
        m = 1.0
        if c["has_person"]:
            m *= s4["has_person"]
        if c["cta_position"] == "bottom_right":
            m *= s4["cta_bottom_right"]
        if c["dominant_color"] == "warm":
            m *= s4["dominant_color_warm"]
        return m

    def fatigue(self, c: dict, d: date) -> float:
        s3 = self.gt["S3_creative_fatigue"]
        if c["creative_id"] != s3["creative_id"]:
            return 1.0
        weeks = max(0, (d - parse_day(s3["anchor_date"])).days) / 7
        return (1 - s3["weekly_ctr_decay"]) ** weeks

    def cpc_multiplier(self, c: dict, d: date) -> float:
        s1 = self.gt["S1_cpc_spike"]
        if c["ad_group_id"] == s1["ad_group_id"] and d >= parse_day(s1["start_date"]):
            return s1["cpc_multiplier"]
        return 1.0

    def ad_day(self, d: date) -> list[tuple[dict, int]]:
        """回傳當天每張素材帶來的工作階段數。"""
        sessions = []
        weekend = d.weekday() >= 5
        for c in self.creatives:
            if not self.creative_active(c, d):
                continue
            base = PAID_BASE[c["channel"]]
            imp_mean = base["impressions"] * self.day_factor(d) * (base["weekend"] if weekend else 1.0)
            conf = self.gt["S4_visual_effects"]["confounders"]
            if c["audience"] == "retargeting":
                imp_mean *= conf["retargeting_impression_multiplier"]   # 再行銷名單小，曝光少
            impressions = max(0, round(imp_mean * self.rng.lognormvariate(0, 0.12)))
            ctr = (base["ctr"] * self.visual_multiplier(c) * self.creative_noise[c["creative_id"]]
                   * self.fatigue(c, d) * self.rng.lognormvariate(0, 0.05))
            if c["audience"] == "retargeting":
                ctr *= conf["retargeting_ctr"]   # 看過網站的人點擊率較高（和設計屬性無關的混淆因素）
            clicks = min(impressions, self.count(impressions * ctr))
            cpc = base["cpc"] * self.adgroup_cpc[c["ad_group_id"]] * self.cpc_multiplier(c, d)
            cost = round(clicks * cpc * self.rng.lognormvariate(0, 0.05), 2)
            self.ad_rows.append({
                "date": d.isoformat(), "creative_id": c["creative_id"], "ad_group_id": c["ad_group_id"],
                "channel": c["channel"], "utm_campaign": c["utm_campaign"],
                "impressions": impressions, "clicks": clicks, "cost": f"{cost:.2f}",
            })
            landed = sum(1 for _ in range(clicks) if self.rng.random() < LANDING_RATE)
            sessions.append((c, landed))
        return sessions

    # ── 第二步：訪客與旅程 ──────────────────────────────────────────────────
    def new_user(self, d: date, ts: datetime) -> str:
        # GA4 的 user_pseudo_id 格式：隨機數字.首次造訪秒數
        first = int(ts.timestamp())
        while True:
            uid = f"{self.rng.randrange(1, 2**31)}.{first}"
            if uid not in self.users:
                self.users[uid] = {"sessions": 0, "last": d, "customer_id": None}
                return uid

    def prune_warm(self, d: date):
        """每天開始前整理一次：只留近 WARM_DAYS 天來過、還沒買的人（去重並維持造訪先後）。"""
        cutoff = d - timedelta(days=WARM_DAYS)
        seen, kept = set(), []
        for u in reversed(self.warm):
            if u in seen:
                continue
            seen.add(u)
            info = self.users[u]
            if info["last"] >= cutoff and info["customer_id"] is None:
                kept.append(u)
        self.warm = kept[::-1]

    def returning_user(self, d: date) -> str | None:
        # 越近期來過的人越可能回訪：從最近的 400 人裡挑
        for _ in range(5):
            if not self.warm:
                return None
            uid = self.rng.choice(self.warm[-400:])
            if self.users[uid]["customer_id"] is None:
                return uid
        return None

    def pick_user(self, channel: str, audience: str | None, d: date, ts: datetime) -> str:
        s6 = self.gt["S6_channel_roles"]
        share = s6["retargeting_new_user_share"] if audience == "retargeting" else s6["new_user_share"][channel]
        if self.rng.random() >= share:
            uid = self.returning_user(d)
            if uid:
                return uid
        return self.new_user(d, ts)

    def conversion_prob(self, channel: str, touch: int) -> float:
        s6 = self.gt["S6_channel_roles"]
        mult = s6["touch_multiplier"][min(touch, len(s6["touch_multiplier"])) - 1]
        return s6["base_cvr"][channel] * mult

    # ── 第三步：顧客類型與品項 ──────────────────────────────────────────────
    def choose_segment(self, campaign: str) -> str:
        s5 = self.gt["S5_customer_segments"]
        mix = dict(s5["base_mix"])
        for seg, boost in s5["campaign_boost"].get(campaign, {}).items():
            mix[seg] *= boost
        return self.weighted(mix.items())

    def autumn_weight(self, pid: str, d: date) -> float:
        s7 = self.gt["S7_autumn_uplift"]
        if parse_day(s7["start_date"]) <= d <= parse_day(s7["end_date"]) and pid in s7["product_ids"]:
            return s7["weight_multiplier"]
        return 1.0

    def choose_item(self, segment: str, repeat: bool, campaign: str, d: date) -> tuple[str, int]:
        if segment == "sock_regular":
            pid = self.weighted([("sock-crew-daily", 0.6 * self.autumn_weight("sock-crew-daily", d)),
                                 ("sock-towel-training", 0.4)])
            qty = self.weighted([(1, 0.5), (2, 0.35), (3, 0.15)])
        elif segment == "bath_bulk" and not repeat:
            pid, qty = "towel-bath-cotton", self.weighted([(2, 0.5), (3, 0.3), (4, 0.2)])
        elif segment == "starter_new" and not repeat:
            pid, qty = "set-starter", 1
        elif segment == "starter_new":
            pid = self.weighted([("sock-crew-daily", 0.6), ("towel-face-cotton", 0.4)])
            qty = self.weighted([(1, 0.7), (2, 0.3)])
        else:
            pool = self.campaign_products.get(campaign, list(self.products))
            pid = self.weighted([(p, self.autumn_weight(p, d)) for p in pool])
            qty = self.weighted([(1, 0.75), (2, 0.2), (3, 0.05)])
        return pid, qty

    def variant(self, pid: str) -> str:
        opts = self.products[pid]["size_options"]
        weights = [2 if "M" in o or "標準" in o else 1 for o in opts]
        return self.rng.choices(opts, weights=weights, k=1)[0]

    def new_customer(self, uid: str, d: date) -> str:
        """d 是第一筆訂單成立的日期（台北時間）。"""
        cid = f"C{len(self.customers) + 1:06d}"
        name = self.rng.choice(SURNAMES) + self.rng.choice(GIVEN[0::2]) + self.rng.choice(GIVEN[1::2])
        local = "".join(self.rng.choice("abcdefghijklmnopqrstuvwxyz") for _ in range(6))
        self.customers.append({
            "customer_id": cid, "name": name,
            "email": f"{local}{self.rng.randrange(100)}@example.com",   # example.com 是保留網域，不會寄到真人
            "phone": f"09{self.rng.randrange(10**8):08d}",
            "city": self.weighted(CITIES), "first_order_date": d.isoformat(),
        })
        self.users[uid]["customer_id"] = cid
        self.customer_user[cid] = uid
        return cid

    def schedule_repeat(self, cid: str, segment: str, d: date):
        cfg = self.gt["S5_customer_segments"][segment]
        if self.rng.random() >= cfg.get("repeat_prob", 0):
            return
        gap = max(3, round(self.rng.gauss(cfg["interval_days_mean"], cfg["interval_days_sd"])))
        when = d + timedelta(days=gap)
        if when <= self.end:
            self.planned[when].append((cid, "email" if self.rng.random() < 0.55 else "direct"))

    # ── 第四步：把一次造訪展開成事件 ────────────────────────────────────────
    def trade_no(self, ts: datetime) -> str:
        while True:
            t = f"SY{ts:%Y%m%d%H%M%S}{self.rng.randrange(16**4):04X}"   # SY 開頭，和 Live Demo 的 DM 分開
            if t not in self.used_ids:
                self.used_ids.add(t)
                return t

    def session(self, d: date, channel: str, uid: str, campaign: str, creative: dict | None,
                convert: bool, segment_hint: str | None = None, repeat: bool = False,
                ts: datetime | None = None):
        user = self.users[uid]
        user["sessions"] += 1
        user["last"] = d
        ts = ts or self.timestamp(d)
        if user.get("until") and ts <= user["until"] + timedelta(minutes=30):
            # 同一人前一次造訪的事件還沒結束，這次往後挪，確保每個人的事件時間不交錯
            # 間隔超過 30 分鐘，GA4 才會算成新的工作階段
            ts = user["until"] + timedelta(minutes=self.rng.randint(31, 90))
        sid = int(ts.timestamp())
        while sid in user.setdefault("sids", set()):   # 同一人同一秒開兩次工作階段時錯開
            sid += 1
        user["sids"].add(sid)
        src = CHANNELS[channel]
        base = {"user_pseudo_id": uid, "ga_session_id": sid, "customer_id": user["customer_id"] or "",
                "utm_source": src["source"], "utm_medium": src["medium"], "utm_campaign": campaign,
                "creative_id": creative["creative_id"] if creative else "", "promotion_id": "",
                "item_id": "", "item_variant": "", "quantity": "", "value": "", "transaction_id": "",
                "data_source": "synthetic"}
        clock = [ts]

        def emit(name, at=None, **kw):
            if at is None:
                clock[0] += timedelta(seconds=self.rng.randint(3, 90))
            else:
                clock[0] = at
            row = dict(base, event_name=name, **kw)
            row["event_date"] = clock[0].strftime("%Y%m%d")
            row["event_timestamp"] = int(clock[0].timestamp() * 1_000_000)
            self.events.append(row)
            user["until"] = clock[0]

        # first_visit、session_start 和工作階段開始時間相同，和 GA4 一致
        if user["sessions"] == 1:
            emit("first_visit", at=ts)
        emit("session_start", at=ts)

        # 決定這次造訪看的商品
        segment = item = qty = None
        if convert:
            segment = segment_hint or self.choose_segment(campaign)
            item, qty = self.choose_item(segment, repeat, campaign, d)
        elif creative:
            item = creative["product_focus"]
        else:
            pool = self.campaign_products.get(campaign, list(self.products))
            item = self.rng.choice(pool)

        promo = self.promotion_of.get(campaign)
        if promo and creative:
            emit("view_promotion", promotion_id=promo)
            if not (convert or self.rng.random() < 0.55):
                return
            emit("select_promotion", promotion_id=promo)
        else:
            emit("view_item_list")
            if not (convert or self.rng.random() < 0.50):
                return
            emit("select_item", item_id=item)
        price = self.products[item]["price"]
        emit("view_item", item_id=item, item_variant=self.products[item]["size_options"][0], value=price)
        if not convert:
            if self.rng.random() < 0.035:
                emit("begin_checkout", item_id=item, item_variant=self.variant(item), quantity=1, value=price)
            return

        var = self.variant(item)
        amount = price * qty
        emit("begin_checkout", item_id=item, item_variant=var, quantity=qty, value=amount)
        order_ts = clock[0] + timedelta(seconds=self.rng.randint(40, 240))
        cid = user["customer_id"] or self.new_customer(uid, order_ts.date())
        base["customer_id"] = cid
        tno = self.trade_no(order_ts)
        self.orders.append({
            "transaction_id": tno, "order_ts": order_ts.isoformat(sep=" ", timespec="seconds"),
            "order_date": order_ts.date().isoformat(), "customer_id": cid, "user_pseudo_id": uid,
            "item_id": item, "item_variant": var, "quantity": qty, "unit_price": price,
            "revenue": amount, "utm_source": src["source"], "utm_medium": src["medium"],
            "utm_campaign": campaign, "payment_status": "paid",
        })
        outage = self.gt["S2_tracking_outage"]
        # purchase 事件時間就是訂單成立時間，S2 當天（台北時間）的 purchase 事件不寫入
        if order_ts.date() != parse_day(outage["date"]):
            emit("purchase", at=order_ts, item_id=item, item_variant=var, quantity=qty, value=amount,
                 transaction_id=tno)
        if not repeat:
            self.segments[cid] = segment
        self.schedule_repeat(cid, self.segments[cid], order_ts.date())

    def visit(self, d: date, channel: str, campaign: str, creative: dict | None, ts: datetime):
        uid = self.pick_user(channel, creative["audience"] if creative else None, d, ts)
        until = self.users[uid].get("until")
        if until and ts <= until + timedelta(minutes=30) and (until + timedelta(minutes=90)).date() != d:
            # 這個人要往後挪才不會和上一次造訪重疊，但會挪到隔天，這次點擊改給新訪客
            uid = self.new_user(d, ts)
        touch = self.users[uid]["sessions"] + 1
        convert = self.rng.random() < self.conversion_prob(channel, touch)
        self.session(d, channel, uid, campaign, creative, convert, ts=ts)
        if self.users[uid]["customer_id"] is None:
            self.warm.append(uid)

    # ── 主流程 ──────────────────────────────────────────────────────────────
    def run(self):
        for n in range(self.days):
            d = self.start + timedelta(days=n)
            self.prune_warm(d)
            slots = []
            for c, landed in self.ad_day(d):
                slots += [(c["channel"], c["utm_campaign"], c)] * landed
            f = self.day_factor(d)
            slots += [("organic", "(organic)", None)] * self.count(ORGANIC_PER_DAY * f)
            slots += [("direct", "(direct)", None)] * self.count(DIRECT_PER_DAY * f)
            # 先替每次造訪抽好時間再依時間先後處理，回訪者一定是更早來過的人
            timed = sorted(((self.timestamp(d), i) for i in range(len(slots))))
            for ts, i in timed:
                channel, campaign, creative = slots[i]
                self.visit(d, channel, campaign, creative, ts)
            # 電子報：寄給既有顧客，部分人點進來逛逛
            # 只寄給昨天以前就成為顧客的人
            known = [c["customer_id"] for c in self.customers if c["first_order_date"] < d.isoformat()]
            if known:
                for _ in range(self.count(NEWSLETTER_CLICKS_PER_DAY * min(1.0, len(known) / 800))):
                    cid = self.rng.choice(known)
                    uid = self.customer_user[cid]
                    touch = self.users[uid]["sessions"] + 1
                    buy = (self.segments[cid] != "dormant"
                           and self.rng.random() < self.conversion_prob("email", touch))
                    self.session(d, "email", uid, "newsletter", None, buy,
                                 segment_hint=self.segments[cid], repeat=True)
            # 預定回購
            for cid, channel in self.planned.pop(d, []):
                camp = "newsletter" if channel == "email" else "(direct)"
                self.session(d, channel, self.customer_user[cid], camp, None, True,
                             segment_hint=self.segments[cid], repeat=True)
        self._clip_to_period()
        self.events.sort(key=lambda r: r["event_timestamp"])
        self.orders.sort(key=lambda r: r["order_ts"])
        return self

    def _clip_to_period(self):
        """最後一天深夜的造訪可能跨到隔天，超出期間的事件、訂單與只有這些訂單的顧客一律丟掉。"""
        last = self.end.strftime("%Y%m%d")
        self.events = [e for e in self.events if e["event_date"] <= last]
        self.orders = [o for o in self.orders if o["order_date"] <= self.end.isoformat()]
        buyers = {o["customer_id"] for o in self.orders}
        self.customers = [c for c in self.customers if c["customer_id"] in buyers]
        self.segments = {k: v for k, v in self.segments.items() if k in buyers}
        for e in self.events:
            if e["customer_id"] and e["customer_id"] not in buyers:
                e["customer_id"] = ""

    # ── 輸出 ────────────────────────────────────────────────────────────────
    def write(self, out: Path):
        out.mkdir(parents=True, exist_ok=True)
        creative_rows = [{k: ("" if c.get(k) is None else c.get(k)) for k in CREATIVE_FIELDS}
                         for c in self.creatives]
        tables = {
            "raw_creatives.csv": (CREATIVE_FIELDS, creative_rows),
            "raw_ad_daily.csv": (AD_FIELDS, self.ad_rows),
            "raw_events.csv": (EVENT_FIELDS, self.events),
            "raw_orders.csv": (ORDER_FIELDS, self.orders),
            "raw_customers.csv": (CUSTOMER_FIELDS, self.customers),
        }
        for name, (fields, rows) in tables.items():
            with open(out / name, "w", newline="", encoding="utf-8") as f:
                w = csv.DictWriter(f, fieldnames=fields)
                w.writeheader()
                w.writerows(rows)
        # 答案另外放，分析時不要去讀
        gt_dir = out / "ground_truth"
        gt_dir.mkdir(exist_ok=True)
        with open(gt_dir / "customer_segments.csv", "w", newline="", encoding="utf-8") as f:
            w = csv.writer(f)
            w.writerow(["customer_id", "segment"])
            w.writerows(sorted(self.segments.items()))

    def summary(self) -> dict:
        imp = defaultdict(int)
        clk = defaultdict(int)
        for r in self.ad_rows:
            imp[r["channel"]] += r["impressions"]
            clk[r["channel"]] += r["clicks"]
        sessions = {(e["user_pseudo_id"], e["ga_session_id"]) for e in self.events
                    if e["event_name"] == "session_start"}
        revenue = [o["revenue"] for o in self.orders]
        return {
            "period": f"{self.start} ~ {self.end}",
            "rows": {"raw_ad_daily": len(self.ad_rows), "raw_events": len(self.events),
                     "raw_orders": len(self.orders), "raw_customers": len(self.customers)},
            "ctr_by_channel": {k: round(clk[k] / imp[k], 4) for k in imp if imp[k]},
            "sessions": len(sessions),
            "cvr_session": round(len(self.orders) / max(len(sessions), 1), 4),
            "aov": round(sum(revenue) / max(len(revenue), 1), 1),
            "event_names": dict(Counter(e["event_name"] for e in self.events)),
        }


def main(argv=None):
    ap = argparse.ArgumentParser(description="織日常 電商大數據合成器")
    ap.add_argument("--start", default=DEFAULT_START.isoformat(), help="起始日（預設 2026-06-19）")
    ap.add_argument("--days", type=int, default=DEFAULT_DAYS, help="天數（預設 90）")
    ap.add_argument("--seed", type=int, default=DEFAULT_SEED, help="亂數種子，同一個種子結果完全相同")
    ap.add_argument("--out", default="./out", help="輸出資料夾")
    args = ap.parse_args(argv)
    if args.days < 1:
        ap.error("--days 至少要 1")
    syn = Synthesizer(date.fromisoformat(args.start), args.days, args.seed).run()
    syn.write(Path(args.out))
    print(json.dumps(syn.summary(), ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
