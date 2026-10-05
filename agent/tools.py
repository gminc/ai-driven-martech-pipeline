"""Day 21：交給 Gemini 的三個查詢工具

每個工具有兩個部分：
- 宣告（DECLARATIONS）：名稱、說明、參數，這是模型唯一看得到的東西
- 實作（run_tool）：真正去查 BigQuery 的程式，模型看不到也碰不到

SQL 是寫死的，模型只能填參數，參數先過白名單與日期格式檢查，再用查詢參數帶進 SQL，不做字串拼接
三個工具都只有 SELECT，每次查詢設了掃描量上限
"""
import datetime
import os
import re

from google.cloud import bigquery

DATASET = os.environ.get("DATASET", "martech_dw")
MAX_BYTES = 100 * 1024 * 1024   # 單次查詢最多掃 100 MB，超過就失敗、不收費
MAX_ROWS = 20                   # 回給模型的列數上限，結果越長下一輪的輸入 Token 越多
DATA_START, DATA_END = "2026-06-19", "2026-09-16"

ATTRIBUTION_MODELS = {"first_touch": "credit_first", "last_touch": "credit_last", "time_decay": "credit_decay"}
CHANNELS = ("meta", "line", "google_cpc", "all")
METRICS = ("ctr", "cvr")
# Day 22 新增：廣告花費
AD_START, AD_END = "2026-06-19", "2026-09-16"
SPEND_GROUPS = {"creative": "creative_id", "ad_group": "ad_group_id", "campaign": "utm_campaign", "channel": "channel"}
AD_CHANNELS = ("meta", "line", "google_cpc", "all")

# ── 宣告：寫給模型看的，說明文字決定它什麼時候會選這個工具 ──────────────────
DECLARATIONS = [
    {
        "name": "get_channel_attribution",
        "description": (
            "查各個流量來源（通路）在一段期間內分到多少訂單功勞與營收，用來回答「哪個通路帶來最多訂單」"
            "「某個通路的功勞有多少」這類問題。資料期間是 2026-06-19 到 2026-09-16。"
            "通路名稱的格式是「來源 / 媒介」，例如 meta / paid_social、google / cpc、line / display、"
            "newsletter / email、google / organic、(direct) / (none)。"
        ),
        "parameters": {
            "type": "OBJECT",
            "properties": {
                "attribution_model": {
                    "type": "STRING",
                    "enum": list(ATTRIBUTION_MODELS),
                    "description": "功勞怎麼分：first_touch 全部算給第一次接觸、last_touch 全部算給下單前最後一次接觸、time_decay 越接近下單分到越多（半衰期 7 天）。使用者沒有指定時用 time_decay",
                },
                "start_date": {"type": "STRING", "description": "訂單日期起，格式 YYYY-MM-DD，沒有指定時用 2026-06-19"},
                "end_date": {"type": "STRING", "description": "訂單日期迄，格式 YYYY-MM-DD，沒有指定時用 2026-09-16"},
                "exclude_direct": {
                    "type": "BOOLEAN",
                    "description": "true 表示不把功勞分給直接流量 (direct)，改分給路徑上的其他通路，沒有指定時用 false",
                },
            },
            "required": ["attribution_model"],
        },
    },
    {
        "name": "get_anomaly_diagnosis",
        "description": (
            "查廣告成效曾經出現過哪些異常，以及每一筆異常判讀出來的原因與依據，"
            "用來回答「成效有沒有出過狀況」「為什麼某一週成效變差」這類問題。"
            "異常分三個層級：廣告群組、單一素材、全站，全站層級的異常不分通路都會回傳。"
        ),
        "parameters": {
            "type": "OBJECT",
            "properties": {
                "channel": {
                    "type": "STRING",
                    "enum": list(CHANNELS),
                    "description": "廣告通路：meta、line、google_cpc，要看全部通路時用 all",
                },
            },
            "required": ["channel"],
        },
    },
    {
        "name": "get_creative_feature_lift",
        "description": (
            "查廣告圖的四種視覺特徵（有人物、按鈕在右下、暖色系、文字多）各自對成效的影響，"
            "回傳「有這個特徵的圖」相對於「沒有的圖」的倍數，大於 1 表示有這個特徵的圖比較好，"
            "用來回答「什麼樣的廣告圖比較會賣」「放人物有沒有用」這類問題。"
            "轉換率的倍數附 95% 信賴區間，區間包含 1 表示差異還不能確定。"
        ),
        "parameters": {
            "type": "OBJECT",
            "properties": {
                "metric": {
                    "type": "STRING",
                    "enum": list(METRICS),
                    "description": "要看哪個指標：ctr 是點擊率（看到廣告的人有多少點進來）、cvr 是轉換率（點進來的人有多少下單）",
                },
            },
            "required": ["metric"],
        },
    },
]

# Day 22 的助理多一個查廣告花費的工具，另外組一份清單，上面那份 Day 21 的實驗還在用所以不動
SPEND_DECLARATION = {
    "name": "get_ad_spend",
    "description": (
        "查一段期間內的廣告花費、曝光、點擊、點擊率與每次點擊成本，可以依素材（單支廣告）、廣告群組、活動或通路彙總，"
        "依花費由高到低排序，用來回答「哪支廣告最貴」「某個通路花了多少」「上週的廣告費是多少」這類問題。"
        f"資料期間是 {AD_START} 到 {AD_END}，金額是新台幣，通路只有 meta、line、google_cpc。"
    ),
    "parameters": {
        "type": "OBJECT",
        "properties": {
            "start_date": {"type": "STRING", "description": "起始日，格式 YYYY-MM-DD"},
            "end_date": {"type": "STRING", "description": "結束日（含當天），格式 YYYY-MM-DD"},
            "group_by": {
                "type": "STRING",
                "enum": list(SPEND_GROUPS),
                "description": "彙總的單位：creative 是單支廣告素材、ad_group 是廣告群組、campaign 是活動、channel 是通路。使用者說「哪支廣告」時用 creative",
            },
            "channel": {
                "type": "STRING",
                "enum": list(AD_CHANNELS),
                "description": "只看某一個通路時填 meta、line 或 google_cpc，沒有指定時用 all",
            },
        },
        "required": ["start_date", "end_date", "group_by"],
    },
}
DECLARATIONS_V2 = DECLARATIONS + [SPEND_DECLARATION]

FEATURE_LABELS = {"person": "有人物", "cta": "按鈕在右下", "warm": "暖色系", "text": "文字多"}


class BadArgs(ValueError):
    """模型給的參數不在允許的範圍內"""


def _date(value, default, name):
    value = default if value in (None, "") else value
    if not isinstance(value, str) or not re.fullmatch(r"\d{4}-\d{2}-\d{2}", value):
        raise BadArgs(f"{name} 要是 YYYY-MM-DD，拿到「{value}」")
    try:
        return datetime.date.fromisoformat(value).isoformat()
    except ValueError:
        raise BadArgs(f"{name} 不是存在的日期，拿到「{value}」")


def _only(args, allowed, tool):
    extra = sorted(set(args) - set(allowed))
    if extra:
        raise BadArgs(f"{tool} 沒有這些參數：{', '.join(extra)}")


def _query(client, sql, params):
    job = client.query(sql, job_config=bigquery.QueryJobConfig(
        query_parameters=params, maximum_bytes_billed=MAX_BYTES, use_query_cache=True))
    rows = [dict(r) for r in job.result(max_results=MAX_ROWS)]
    for r in rows:
        for k, v in r.items():
            if isinstance(v, (datetime.date, datetime.datetime)):
                r[k] = v.isoformat()
    return rows, job.total_bytes_billed or 0


def get_channel_attribution(client, args):
    _only(args, ("attribution_model", "start_date", "end_date", "exclude_direct"), "get_channel_attribution")
    model = args.get("attribution_model")
    if not isinstance(model, str) or model not in ATTRIBUTION_MODELS:
        raise BadArgs(f"attribution_model 只能是 {', '.join(ATTRIBUTION_MODELS)}，拿到「{model}」")
    start = _date(args.get("start_date"), DATA_START, "start_date")
    end = _date(args.get("end_date"), DATA_END, "end_date")
    if start > end:
        raise BadArgs("start_date 不能晚於 end_date")
    exclude_direct = args.get("exclude_direct", False)
    if not isinstance(exclude_direct, bool):
        raise BadArgs("exclude_direct 只能是 true 或 false")
    # 欄位名稱來自上面的白名單對照表，不是模型給的字串
    column = ATTRIBUTION_MODELS[model] + ("_nd" if exclude_direct else "")
    sql = f"""
SELECT channel,
  ROUND(SUM({column}), 1) AS credited_orders,
  CAST(ROUND(SUM({column} * revenue)) AS INT64) AS credited_revenue_twd,
  ROUND(SAFE_DIVIDE(SUM({column}), SUM(SUM({column})) OVER ()), 4) AS share_of_orders
FROM {DATASET}.mart_attribution
WHERE order_date BETWEEN @start_date AND @end_date
GROUP BY channel
ORDER BY credited_orders DESC"""
    rows, billed = _query(client, sql, [
        bigquery.ScalarQueryParameter("start_date", "DATE", start),
        bigquery.ScalarQueryParameter("end_date", "DATE", end)])
    return {"attribution_model": model, "start_date": start, "end_date": end,
            "exclude_direct": exclude_direct, "rows": rows}, billed


def get_anomaly_diagnosis(client, args):
    _only(args, ("channel",), "get_anomaly_diagnosis")
    channel = args.get("channel")
    if not isinstance(channel, str) or channel not in CHANNELS:
        raise BadArgs(f"channel 只能是 {', '.join(CHANNELS)}，拿到「{channel}」")
    sql = f"""
SELECT s.level, s.entity, IFNULL(NULLIF(s.channel, ''), 'all_site') AS channel, s.period_start, s.period_end,
  s.cpc_chg_pct, s.ctr_chg_pct, SUBSTR(d.cause, 1, 40) AS cause, SUBSTR(d.evidence, 1, 120) AS evidence, d.confidence
FROM {DATASET}.diag_summary s
LEFT JOIN {DATASET}.mart_diagnosis d
  ON d.anomaly_id = s.anomaly_id AND d.model = 'gemini-3.6-flash'
WHERE @channel = 'all' OR s.channel = @channel OR IFNULL(s.channel, '') = ''
ORDER BY s.period_start"""
    rows, billed = _query(client, sql, [bigquery.ScalarQueryParameter("channel", "STRING", channel)])
    return {"channel": channel, "rows": rows}, billed


def get_creative_feature_lift(client, args):
    _only(args, ("metric",), "get_creative_feature_lift")
    metric = args.get("metric")
    if not isinstance(metric, str) or metric not in METRICS:
        raise BadArgs(f"metric 只能是 {', '.join(METRICS)}，拿到「{metric}」")
    sql = f"""
SELECT attr AS feature, ROUND(stratified, 3) AS lift, ROUND(ci95_low, 2) AS ci95_low, ROUND(ci95_high, 2) AS ci95_high,
  images_yes AS images_with_feature, images_no AS images_without_feature
FROM {DATASET}.mart_creative_lift
WHERE metric = @metric
ORDER BY lift DESC"""
    rows, billed = _query(client, sql, [bigquery.ScalarQueryParameter("metric", "STRING", metric)])
    for r in rows:
        r["feature_label"] = FEATURE_LABELS.get(r["feature"], r["feature"])
    return {"metric": metric, "rows": rows}, billed


def get_ad_spend(client, args):
    _only(args, ("start_date", "end_date", "group_by", "channel"), "get_ad_spend")
    group_by = args.get("group_by")
    if not isinstance(group_by, str) or group_by not in SPEND_GROUPS:
        raise BadArgs(f"group_by 只能是 {', '.join(SPEND_GROUPS)}，拿到「{group_by}」")
    channel = args.get("channel", "all")
    if not isinstance(channel, str) or channel not in AD_CHANNELS:
        raise BadArgs(f"channel 只能是 {', '.join(AD_CHANNELS)}，拿到「{channel}」")
    if not args.get("start_date") or not args.get("end_date"):
        raise BadArgs("start_date 和 end_date 都要給")
    start = _date(args.get("start_date"), AD_START, "start_date")
    end = _date(args.get("end_date"), AD_END, "end_date")
    if start > end:
        raise BadArgs("start_date 不能晚於 end_date")
    if end < AD_START or start > AD_END:
        raise BadArgs(f"資料期間是 {AD_START} 到 {AD_END}，{start} 到 {end} 沒有資料")
    column = SPEND_GROUPS[group_by]   # 欄位名稱來自白名單對照表
    sql = f"""
SELECT {column} AS {group_by},
  STRING_AGG(DISTINCT channel ORDER BY channel) AS channel,
  CAST(ROUND(SUM(cost)) AS INT64) AS cost_twd,
  SUM(impressions) AS impressions,
  SUM(clicks) AS clicks,
  ROUND(SAFE_DIVIDE(SUM(clicks), SUM(impressions)), 4) AS ctr,
  ROUND(SAFE_DIVIDE(CAST(SUM(cost) AS FLOAT64), SUM(clicks)), 2) AS cpc_twd,
  COUNT(DISTINCT date) AS days_with_data
FROM {DATASET}.fct_ad_daily
WHERE date BETWEEN @start_date AND @end_date
  AND (@channel = 'all' OR channel = @channel)
GROUP BY {column}
ORDER BY cost_twd DESC, {group_by}"""
    rows, billed = _query(client, sql, [
        bigquery.ScalarQueryParameter("start_date", "DATE", start),
        bigquery.ScalarQueryParameter("end_date", "DATE", end),
        bigquery.ScalarQueryParameter("channel", "STRING", channel)])
    return {"start_date": start, "end_date": end, "group_by": group_by, "channel": channel,
            "rows_returned": len(rows), "max_rows": MAX_ROWS, "rows": rows}, billed


TOOLS = {
    "get_ad_spend": get_ad_spend,
    "get_channel_attribution": get_channel_attribution,
    "get_anomaly_diagnosis": get_anomaly_diagnosis,
    "get_creative_feature_lift": get_creative_feature_lift,
}


def run_tool(client, name, args):
    """執行模型要求的工具，回傳 (給模型的結果, 計費位元組)

    工具名稱不在清單裡、參數不合規定，都不會碰到 BigQuery，只把錯誤訊息回給模型
    """
    if name not in TOOLS:
        return {"error": f"沒有 {name} 這個工具"}, 0
    try:
        return TOOLS[name](client, dict(args or {}))
    except BadArgs as e:
        return {"error": str(e)}, 0
    except Exception as e:  # 查詢本身失敗（例如超過掃描量上限）也只回錯誤訊息，不讓整個流程中斷
        return {"error": f"查詢失敗：{type(e).__name__}"}, 0
