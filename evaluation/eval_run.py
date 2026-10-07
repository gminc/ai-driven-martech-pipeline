"""Day 24：拿預先藏好的標準答案考助理，再考替它評分的方式

用法（通常由 bash evaluation/run.sh 呼叫，在儲存庫根目錄執行）：
  python3 evaluation/eval_run.py answers   8 個問題在有工具、沒有工具兩種情況各問一次（會花錢，先印估價）
  python3 evaluation/eval_run.py rules     用關鍵事實的規則替 16 個回答評分（不花錢）
  python3 evaluation/eval_run.py export    把 16 個回答打亂順序匯出成給人評分的表（不花錢）
  python3 evaluation/eval_run.py human     把人評好的 evaluation/human_labels.csv 寫進評分表（不花錢）
  python3 evaluation/eval_run.py judge     請評分模型對照標準答案評分（會花錢，先印估價）
  answers 與 judge 可以加 --dry 只做到估價為止，judge 可以加 --one 每個評分模型只試一筆並印出原始回應

三種評分方式放在同一張表 eval_scores，分數都是 0、1、2，用的是同一份評分標準（RUBRIC）：
  rule   關鍵事實有沒有出現（規則運算式）
  human  人讀過之後給的分數，要在評分模型評分之前寫好並 commit
  judge  Gen AI evaluation service 的評分模型，對照標準答案評分

標準答案（reference）寫的是「工具查得到的版本」，數字來自 Day 08、09、17 的結果表，
背後的原因來自 Day 05 藏進合成資料的訊號（synthesizer/ground_truth.json，每題的 planted 欄位）
題目、標準答案、規則、評分標準都寫死在這個檔案裡，要在問模型之前先 commit，run.sh 會檢查，
這些內容的指紋（spec）會跟著每一個回答、每一筆分數寫進表裡，事後改過就對不起來
"""
import argparse
import csv
import datetime
import hashlib
import inspect
import json
import os
import re
import sys
import time
import uuid

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "agent"))

from google.cloud import bigquery  # noqa: E402

import ask as A  # noqa: E402  Day 21 的問答流程原樣拿來用：同一句系統指示、同三個工具、同樣的上限
import tools as T  # noqa: E402

DATASET = T.DATASET
MODES = ("tools", "none")
EVAL_LOCATION = os.environ.get("EVAL_LOCATION", "us-central1")   # evaluation service 的官方範例都用這個地區
JUDGES = [j for j in os.environ.get("JUDGES", "gemini-3.6-flash,gemini-3.5-flash-lite").split(",") if j]
# 每百萬 Token 的美元單價（輸入, 輸出），抄的是 global 端點的價格，指定地區的端點可能略高，換模型要一起改
JUDGE_PRICE = {"gemini-3.6-flash": (0.75, 3.75), "gemini-3.5-flash-lite": (0.30, 2.50)}
JUDGE_MAX_OUT = 768       # 評分模型每次的輸出上限（思考也算在裡面）。evaluation service 不回報用掉幾個 Token，估價一律用這個上限算
INPUT_MARGIN = 1.3        # 服務自己會在評分說明外面再加輸出格式的要求，輸入 Token 多估三成
FX = 32
SPEND_STOP = 5.0          # Day 24 全部步驟累計估到新台幣幾元就不再往下問（問問題用實際 Token，評分用上限估）
HUMAN_CSV = os.path.join(HERE, "human_labels.csv")
EXPORT_MD = os.path.join(HERE, "answers_to_label.md")
NO_ANSWER = "（助理沒有給出回答）"

# kind：answerable 工具查得到、unanswerable 訊號真的有藏但工具查不到（正確的回答是說查不到）、
#       none_planted 沒有藏這個訊號（正確的回答是沒有）
# reference：給人和評分模型看的標準答案，寫的是工具查得到的版本
# planted：Day 05 藏進資料的設定，只當背景，不給評分模型看
QUESTIONS = [
    {"id": "e1", "signal": "S1", "kind": "answerable",
     "text": "meta-trn-prospecting 這個廣告群組在八月出過什麼狀況？大約從哪一天開始？每次點擊成本變成原本的幾倍？",
     "reference": "meta-trn-prospecting 在 8/10 到 8/16 那一週，每次點擊成本比前四週增加約 78%（7.55 元變成 13.42 元，約 1.8 倍），"
                  "原因是競價變貴，點擊率沒有下降。藏進資料的設定是 8/12 起每次點擊成本變成 2 倍，"
                  "所以開始的日期回答 8/10 那一週或 8/12 都算對，倍數回答約 1.8 倍或 2 倍都算對。",
     "planted": "S1：2026-08-12 起 meta-trn-prospecting 的 CPC 乘 2.0，轉換機率不變"},
    {"id": "e2", "signal": "S2", "kind": "answerable",
     "text": "8 月底有一天網站追蹤到的購買數掉到 0，是哪一天？那天真的沒有訂單嗎？",
     "reference": "2026-08-27。那天是追蹤出了問題（追蹤碼失效），不是真的沒有訂單，後台照常有 37 筆訂單成立。",
     "planted": "S2：2026-08-27 整天的 purchase 事件不送出，訂單照常"},
    {"id": "e3", "signal": "S3", "kind": "answerable",
     "text": "有沒有哪一支素材出現素材疲乏？是哪一支？點擊率下滑的情況如何？",
     "reference": "cr-meta-evg-p1。7/20 到 7/26 那一週的點擊率比上線頭 14 天下降約 31%（2.32% 降到 1.6%），每次點擊成本幾乎沒有變。"
                  "藏進資料的設定是這支素材上線後點擊率每週衰退約 8%。"
                  "回答如果另外提到 meta-evg-prospecting 這個廣告群組在 9/14 那一週也被診斷為素材疲乏，不算錯。",
     "planted": "S3：cr-meta-evg-p1 自 2026-06-19 上線起點擊率每週衰退 8%"},
    {"id": "e4", "signal": "S4", "kind": "answerable",
     "text": "廣告圖上放人物、把按鈕放在右下、用暖色系，這三種做法各讓點擊率變成幾倍？哪一種幫助最大？",
     "reference": "有人物約 1.28 倍、按鈕在右下約 1.13 倍、暖色系約 1.08 倍，三種裡有人物的幫助最大。"
                  "藏進資料的設定是 1.25、1.1、1.1 倍，回答的倍數和這兩組數字的任何一組接近都算對。",
     "planted": "S4：有人物 1.25、按鈕在右下 1.1、暖色系 1.1"},
    {"id": "e5", "signal": "S6", "kind": "answerable",
     "text": "meta 和 google 搜尋廣告（google / cpc）比起來，哪一個比較常是客人第一次接觸的通路？哪一個比較常是下單前最後一次接觸的通路？",
     "reference": "meta 比較常是第一次接觸的通路（算第一次接觸的訂單功勞，meta 789 筆、google / cpc 352 筆），"
                  "google 搜尋廣告比較常是下單前最後一次接觸的通路（算最後一次接觸，google / cpc 746 筆、meta 380 筆）。",
     "planted": "S6：meta 偏路徑開頭，google 搜尋廣告偏最後一步"},
    {"id": "e6", "signal": "S7", "kind": "unanswerable",
     "text": "9 月秋日棉織專案期間，專案主打商品在銷售件數裡的占比有沒有上升？上升了多少？",
     "reference": "助理查得到的只有通路歸因、成效異常診斷、素材特徵三種資料，查不到商品別的銷售件數。"
                  "正確的回答是說明查不到，不可以自己估一個數字。",
     "planted": "S7：9/1 到 9/16 專案商品被選購的權重是平常的 2 倍，資料裡確實有上升，只是工具看不到"},
    {"id": "e7", "signal": "S5", "kind": "unanswerable",
     "text": "我們的顧客裡，買過一次就不再回購的沉睡客大概佔幾成？",
     "reference": "助理查得到的只有通路歸因、成效異常診斷、素材特徵三種資料，查不到顧客類型或回購紀錄。"
                  "正確的回答是說明查不到，不可以自己估一個比例。",
     "planted": "S5：沉睡客約佔 35%，只是工具看不到"},
    {"id": "e8", "signal": "沒有藏", "kind": "none_planted",
     "text": "LINE 這個通路的廣告有沒有出過成效異常？",
     "reference": "LINE 沒有專屬的成效異常。診斷結果裡只有一筆不分通路的全站追蹤碼失效（8/27），回答可以順帶提到。"
                  "回答如果只老實說自己查不到，算部分正確。",
     "planted": "答案表沒有在 LINE 通路放任何異常"},
]

# 評分標準，人和評分模型看的是同一份
RUBRIC = """2 分：重點和標準答案一致。對象、日期、方向都對，數字和標準答案相差在兩成以內算一致，日期落在同一週內算一致。多給了標準答案沒提到、但不矛盾的細節不扣分。標準答案說正確的回答是查不到，而回答也清楚說明查不到，同樣給 2 分。
1 分：部分正確。少了關鍵的一項，或是有一項和標準答案不符。標準答案有內容，回答卻只老實說自己查不到、沒有編造，也給 1 分。
0 分：和標準答案矛盾、答非所問，或是編出和標準答案矛盾的數字、日期或原因。標準答案說正確的回答是查不到，回答卻自己給了數字，一律 0 分。"""

# 評分說明，{prompt}、{reference}、{response} 由 evaluation service 用每一筆資料帶進去
JUDGE_TEMPLATE = """你是一位嚴謹的評分者，要判斷行銷資料助理的回答是否正確。標準答案是事先確認過的事實，請只依照標準答案評分，不要用你自己的知識補充。

## 評分標準
""" + RUBRIC + """

## 同事的問題
{prompt}

## 標準答案
{reference}

## 助理的回答
{response}

請先用一兩句話說明理由，再給分數（0、1 或 2）。"""

SCHEMAS = {
    "eval_answers": [
        ("run_id", "STRING"), ("case_id", "STRING"), ("signal", "STRING"), ("kind", "STRING"), ("mode", "STRING"),
        ("question", "STRING"), ("reference", "STRING"), ("answer", "STRING"), ("tools_called", "STRING"),
        ("model_calls", "INT64"), ("tool_calls", "INT64"), ("status", "STRING"), ("spec", "STRING"), ("created_at", "TIMESTAMP")],
    "eval_calls_log": [
        ("run_id", "STRING"), ("case_id", "STRING"), ("mode", "STRING"), ("step", "INT64"), ("model", "STRING"),
        ("prompt_tokens", "INT64"), ("output_tokens", "INT64"), ("thoughts_tokens", "INT64"),
        ("function_calls", "STRING"), ("finish_reason", "STRING"), ("status", "STRING"),
        ("latency_ms", "INT64"), ("created_at", "TIMESTAMP")],
    "eval_scores": [
        ("case_id", "STRING"), ("mode", "STRING"), ("grader", "STRING"), ("score", "INT64"), ("explanation", "STRING"),
        ("status", "STRING"), ("latency_ms", "INT64"), ("prompt_tokens", "INT64"), ("output_tokens_cap", "INT64"),
        ("answer_run_id", "STRING"), ("spec", "STRING"), ("created_at", "TIMESTAMP")],
}
DESCRIPTIONS = {
    "eval_answers": "Day 24 回答：一列＝一個問題在一種情況（有工具、沒有工具）問一次，只加不刪",
    "eval_calls_log": "Day 24 呼叫紀錄：一列＝問問題時呼叫一次模型",
    "eval_scores": "Day 24 評分：一列＝一個回答被一種評分方式（rule、human、judge:模型）評一次，分數 0 到 2，只加不刪，同一個回答同一種方式看最新一列",
}


def now():
    return datetime.datetime.now(datetime.timezone.utc).isoformat()


def ensure_tables(bq, project):
    for name, cols in SCHEMAS.items():
        table = bigquery.Table(f"{project}.{DATASET}.{name}", schema=[bigquery.SchemaField(c, t) for c, t in cols])
        table.description = DESCRIPTIONS[name]
        bq.create_table(table, exists_ok=True)


def load(bq, project, name, rows):
    if not rows:
        return
    cfg = bigquery.LoadJobConfig(schema=[bigquery.SchemaField(c, t) for c, t in SCHEMAS[name]],
                                 write_disposition="WRITE_APPEND")
    bq.load_table_from_json(rows, f"{project}.{DATASET}.{name}", job_config=cfg).result()


def latest_answers(bq):
    """每個題次最新一筆有結果的回答。呼叫失敗（status 以 error 開頭，沒有收費）不算，會重問，
    模型有回應但沒有給出文字（步數用完、輸出被截斷）算有結果：溫度是 0，重問只會再付一次錢，這種回答三種評分都當成沒有回答"""
    rows = [dict(r) for r in bq.query(f"""
SELECT * FROM {DATASET}.eval_answers WHERE NOT STARTS_WITH(status, 'error')
QUALIFY ROW_NUMBER() OVER (PARTITION BY case_id, mode ORDER BY created_at DESC) = 1""").result()]
    order = {q["id"]: i for i, q in enumerate(QUESTIONS)}
    return sorted((r for r in rows if r["case_id"] in order), key=lambda r: (order[r["case_id"]], MODES.index(r["mode"])))


def scored(bq, grader_prefix):
    """已經評過的 (題目, 情況, 評分方式, 回答的 run_id, 當時的指紋)"""
    return {(r["case_id"], r["mode"], r["grader"], r["answer_run_id"], r["spec"]) for r in bq.query(
        f"""SELECT DISTINCT case_id, mode, grader, answer_run_id, spec FROM {DATASET}.eval_scores
            WHERE status = '' AND STARTS_WITH(grader, '{grader_prefix}')""").result()}


def spent_so_far(bq):
    """Day 24 到目前為止估計花了多少（新台幣）：問問題用實際 Token，評分模型用送出前數的輸入加輸出上限"""
    ask = list(bq.query(f"""
SELECT IFNULL(SUM(prompt_tokens * {A.PRICE_IN} + (IFNULL(output_tokens, 0) + IFNULL(thoughts_tokens, 0)) * {A.PRICE_OUT}), 0) / 1e6 * {A.FX} AS v
FROM {DATASET}.eval_calls_log WHERE status = ''""").result())[0]["v"]
    judge = sum(judge_cost(r["grader"][6:], r["prompt_tokens"] or 0) for r in bq.query(
        f"SELECT grader, prompt_tokens FROM {DATASET}.eval_scores WHERE STARTS_WITH(grader, 'judge:')").result())
    return float(ask) + judge


# ── 第一種評分：規則 ─────────────────────────────────────────────────────────
# 規則只看字面，換一種寫法就可能漏，這正是要拿來和另外兩種比的地方
# 每一題的關鍵事實都挑「題目裡沒有出現過」的字，免得把題目照念一次也拿到分數
CANNOT = re.compile(r"無法|沒辦法|不能|未能|無從")
ADMIT = re.compile(r"查不到|查無|無從|不支援|資料不足|(沒有|無|未|缺少|缺乏)[^。]{0,12}(資料|數據|紀錄|工具|欄位|資訊)"
                   r"|(無法|沒辦法|不能|未能)[^。]{0,6}(查|取得|存取|提供|回答|得知|確認|判斷|估|計算|知道)|超出[^。]{0,8}範圍")
DATE = re.compile(r"\d{1,4}[/-]\d{1,2}([/-]\d{1,2})?|\d{1,2}月\d{1,2}[日號]?")
FIGURE = re.compile(r"(\d[\d.]*|[一二兩三四五六七八九十半]+)(成(?![效長交立本果為功員份分熟])|%|％|倍|筆|元|萬|件|個百分點)")
NEG = re.compile(r"(沒有|未見|未發現|查無|並無|並未|未出現|沒出)[^。，]{0,20}(異常|狀況|問題)|(一切|皆|都|均)正常")
SITE = ("全站", "不分通路", "8/27", "8月27", "追蹤碼")
FIRST, LAST = "(第一次|首次|開頭|最初|初次|最先)", "(最後|最終|末次)"
NUM = r"(\d+(?:\.\d+)?)(倍|%|％)?"
E4 = [("人物", "人物", 1.282), ("按鈕在右下", "右下|按鈕|cta", 1.126), ("暖色系", "暖色", 1.082)]
FACTS = {
    "e1": [("開始的日期", ["8/12", "8月12", "08-12", "八月十二", "8/10", "8月10", "08-10", "八月十日"]),
           ("原因是競價", ["競價", "變貴", "競爭"]),
           ("倍數", ["78", "1.78", "1.8", "2倍", "兩倍", "二倍", "翻倍", "一倍", "100%"])],
    "e2": [("日期", ["8/27", "8月27", "08-27", "八月二十七"]),
           ("追蹤出問題", ["追蹤碼", "追蹤失效", "追蹤問題", "追蹤出", "追蹤異常", "追蹤中斷", "追蹤有", "未送出", "沒有送出", "漏記"]),
           ("其實有訂單", ["37", "照常", "仍有", "還是有", "仍然有", "實際上有", "其實有", "並非沒有", "不是真的沒有", "並不是真的沒有", "並非真的沒有"])],
    "e3": [("哪一支", ["cr-meta-evg-p1"]),
           ("下滑的幅度或時間", ["31", "2.32", "1.6%", "7/20", "7月20", "8%", "三成"])],
}


def norm(text):
    """去空白、去千分位逗號、英文轉小寫，標點留著（規則要靠逗號和句號分辨是不是同一句）"""
    return re.sub(r"(?<=\d),(?=\d{3})", "", re.sub(r"\s", "", text or "")).lower()


def near(value, truth, unit):
    """回答裡的數字和工具查到的倍數夠不夠近：寫成倍數差 0.06 以內，寫成百分比差 6 個百分點以內"""
    if unit in ("%", "％"):
        return abs(value - (truth - 1) * 100) <= 6
    return abs(value - truth) <= 0.06


def rule_score(q, answer):
    """回傳 (分數, 說明)"""
    text = norm(answer)
    if not text:
        return 0, "沒有回答"
    admit = bool(ADMIT.search(text))
    if q["kind"] == "unanswerable":
        figure = bool(FIGURE.search(DATE.sub("", text)))
        score = 2 if admit and not figure else 0
        return score, f"說明查不到：{'有' if admit else '沒有'}，出現帶單位的數字：{'有' if figure else '沒有'}"
    if q["kind"] == "none_planted":
        cannot, neg, site = bool(CANNOT.search(text)), bool(NEG.search(text)), any(k in text for k in SITE)
        score = 1 if cannot else (2 if neg else (1 if admit or site else 0))
        return score, f"說查不到：{'有' if cannot or admit else '沒有'}，說沒有異常：{'有' if neg else '沒有'}，提到全站追蹤問題：{'有' if site else '沒有'}"
    found, total = [], 0
    if q["id"] == "e4":
        for label, words, truth in E4:
            total += 1
            m = re.search(rf"(?:{words})[^。]{{0,25}}?{NUM}", text)
            if m and near(float(m.group(1)), truth, m.group(2)):
                found.append(f"{label} {m.group(1)}{m.group(2) or ''}")
        total += 1
        if re.search(r"人物[^。]{0,15}最|最[^。，]{0,12}人物", text):
            found.append("人物最大")
    elif q["id"] == "e5":
        total = 2
        if re.search(rf"meta[^。，或哪和與跟]{{0,25}}{FIRST}|{FIRST}[^。，或哪和與跟]{{0,15}}(是|為)meta", text):
            found.append("meta 是第一次接觸")
        if re.search(rf"google[^。，或哪和與跟]{{0,25}}{LAST}|{LAST}[^。，或哪和與跟]{{0,15}}(是|為)google", text):
            found.append("google 是最後一次接觸")
    else:
        for label, alts in FACTS[q["id"]]:
            total += 1
            got = next((a for a in alts if A.hit(a, text)), None)
            if got:
                found.append(f"{label}（{got}）")
    if len(found) == total:
        score = 2
    elif found:
        score = 1
    else:
        score = 1 if admit else 0   # 一項都沒講到：老實說查不到給 1 分，其餘 0 分
    return score, f"關鍵事實 {len(found)}/{total}：{'、'.join(found) or '都沒有'}" + ("，有說明查不到" if admit else "")


def spec():
    """題目、標準答案、規則、評分標準、評分模型設定的指紋，任何一項改過就會變"""
    blob = json.dumps([QUESTIONS, RUBRIC, JUDGE_TEMPLATE, FACTS, E4, SITE, FIRST, LAST, NUM,
                       [p.pattern for p in (CANNOT, ADMIT, DATE, FIGURE, NEG)], inspect.getsource(rule_score),
                       inspect.getsource(near), A.MODEL, A.SYSTEM, T.DECLARATIONS, A.MAX_STEPS, A.MAX_OUTPUT, JUDGE_MAX_OUT],
                      ensure_ascii=False, sort_keys=True)
    return hashlib.sha256(blob.encode()).hexdigest()[:12]


# ── 第三種評分：Gen AI evaluation service 的評分模型 ────────────────────────
def judge_request(project, judge, row):
    """組一筆送給 evaluation service 的請求（pointwise 指標：一次評一個回答）"""
    return {
        "pointwiseMetricInput": {
            "metricSpec": {"metricPromptTemplate": JUDGE_TEMPLATE},
            "instance": {"jsonInstance": json.dumps(
                {"prompt": row["question"], "reference": row["reference"], "response": row["answer"] or NO_ANSWER}, ensure_ascii=False)},
        },
        "autoraterConfig": {
            "samplingCount": 1,   # 預設會問評分模型 4 次再平均，這裡只問 1 次省錢
            "autoraterModel": f"projects/{project}/locations/{EVAL_LOCATION}/publishers/google/models/{judge}",
            "generationConfig": {"temperature": 0, "maxOutputTokens": JUDGE_MAX_OUT},
        },
    }


def judge_url(project):
    return f"https://{EVAL_LOCATION}-aiplatform.googleapis.com/v1beta1/projects/{project}/locations/{EVAL_LOCATION}:evaluateInstances"


def judge_call(session, project, judge, row):
    """回傳 (分數或 None, 說明, 狀態, 毫秒, 有沒有可能已經收費, 原始回應)
    只有連線失敗和 HTTP 不是 200 當成沒有收費，回了 200 但分數拿不到或不在 0 到 2 之間，模型已經跑過，要算錢"""
    t0 = time.time()
    try:
        resp = session.post(judge_url(project), json=judge_request(project, judge, row), timeout=120)
    except Exception as e:
        billed = "Timeout" in type(e).__name__   # 等到逾時的話模型可能已經跑完
        return None, "", f"error:{type(e).__name__}:{str(e)[:160]}", int((time.time() - t0) * 1000), billed, ""
    ms = int((time.time() - t0) * 1000)
    if resp.status_code != 200:
        return None, "", f"error:http_{resp.status_code}:{resp.text[:300]}", ms, False, resp.text
    result = (resp.json() or {}).get("pointwiseMetricResult") or {}
    score, why = result.get("score"), (result.get("explanation") or "").strip()
    if score is None:
        return None, why, "no_score", ms, True, resp.text
    if float(score) not in (0.0, 1.0, 2.0):
        return None, why, f"score_out_of_range:{score}", ms, True, resp.text
    return int(float(score)), why, "", ms, True, resp.text


def judge_probe(session, project):
    """不花錢的探測：故意送一個少了內容的請求，沒有東西可以交給模型。端點存在而且有權限的話預期回 400，不存在回 404，沒權限回 403
    這只能確認端點和權限，評分模型在這個地區能不能用、分數讀不讀得到，要靠 --one 真的試一筆"""
    try:
        resp = session.post(judge_url(project), json={"pointwiseMetricInput": {}}, timeout=60)
        return resp.status_code, resp.text[:200].replace("\n", " ")
    except Exception as e:
        return 0, f"{type(e).__name__}: {str(e)[:160]}"


def count_prompt_tokens(client, row):
    text = JUDGE_TEMPLATE.format(prompt=row["question"], reference=row["reference"], response=row["answer"] or NO_ANSWER)
    try:
        return client.models.count_tokens(model=A.MODEL, contents=text).total_tokens
    except Exception as e:
        print(f"   ⚠️  數不出輸入 Token（{type(e).__name__}），改用字數乘 2 當上限")
        return len(text) * 2


def judge_cost(judge, prompt_tokens):
    """一次評分的估價上限：輸入多估三成，輸出當成寫滿上限"""
    pin, pout = JUDGE_PRICE.get(judge, max(JUDGE_PRICE.values()))
    return (prompt_tokens * INPUT_MARGIN * pin + JUDGE_MAX_OUT * pout) / 1e6 * FX


# ── 各個步驟 ─────────────────────────────────────────────────────────────────
def step_answers(bq, project, dry):
    from google import genai
    done = {(r["case_id"], r["mode"]) for r in latest_answers(bq)}
    todo = [(q, m) for q in QUESTIONS for m in MODES if (q["id"], m) not in done]
    if not todo:
        log_usage(bq)   # 上一次如果中途被打斷，用量在這裡補抄
        print(f"✅ {len(QUESTIONS) * len(MODES)} 個題次都問過了，不再呼叫模型")
        return
    client = genai.Client(vertexai=True, project=project, location=A.LOCATION)
    A.preflight(client, bq)   # Day 21 的預檢：三個工具查得到資料、最長的結果放得進輸入上限
    before = spent_so_far(bq)
    calls = sum(A.MAX_STEPS if m == "tools" else 1 for _, m in todo)
    worst = calls * (A.INPUT_CAP * A.PRICE_IN + A.MAX_OUTPUT * A.PRICE_OUT) / 1e6 * A.FX
    likely = sum((2.5 if m == "tools" else 1) * (A.EXPECT_IN[m] * A.PRICE_IN + A.EXPECT_OUT * A.PRICE_OUT) for _, m in todo) / 1e6 * A.FX
    print(f"💰 這次要問 {len(todo)} 題次（有工具 {sum(m == 'tools' for _, m in todo)}、沒有工具 {sum(m == 'none' for _, m in todo)}），模型 {A.MODEL}")
    print(f"   預期：約新台幣 {likely:.2f} 元（估計值，用 Day 21 的用量推的）")
    print(f"   最壞情況：最多呼叫模型 {calls} 次，每次輸入都頂到 {A.INPUT_CAP:,}、輸出都寫滿 {A.MAX_OUTPUT:,} 個 Token，約新台幣 {worst:.2f} 元")
    print(f"   停損：Day 24 目前累計約 {before:.2f} 元，累計到 {SPEND_STOP:.0f} 元就不再問下一題")
    if dry:
        print("--dry：到這裡為止，沒有呼叫模型")
        return
    if input("輸入 yes 開始呼叫模型：").strip() != "yes":
        print("已停在這裡，沒有呼叫模型")
        sys.exit(2)
    run_id, spent, sp = uuid.uuid4().hex[:12], before, spec()
    try:
        for q, mode in todo:
            if spent >= SPEND_STOP:
                print(f"\n🛑 Day 24 累計約新台幣 {spent:.2f} 元，到了停損 {SPEND_STOP:.0f} 元，後面的題次先不問")
                break
            row, calls_log, _tool_rows = A.ask(client, bq, {"id": q["id"], "text": q["text"]}, mode, run_id)
            load(bq, project, "eval_calls_log", [dict({k: v for k, v in c.items() if k != "question_id"}, case_id=q["id"]) for c in calls_log])
            load(bq, project, "eval_answers", [{
                "run_id": run_id, "case_id": q["id"], "signal": q["signal"], "kind": q["kind"], "mode": mode,
                "question": q["text"], "reference": q["reference"], "answer": row["answer"],
                "tools_called": row["tools_called"], "model_calls": row["model_calls"], "tool_calls": row["tool_calls"],
                "status": row["status"], "spec": sp, "created_at": now()}])
            spent += sum(c.get("prompt_tokens", 0) * A.PRICE_IN + (c.get("output_tokens", 0) + c.get("thoughts_tokens", 0)) * A.PRICE_OUT
                         for c in calls_log) / 1e6 * A.FX
            print(f"\n[{mode}] {q['id']} {q['signal']}｜{q['text']}")
            for c in json.loads(row["tools_called"]):
                print(f"   🔧 {c['name']} {json.dumps(c['args'], ensure_ascii=False)}")
            print(f"🤖 {row['answer'] or NO_ANSWER}" + (f"\n   ❌ {row['status']}" if row["status"] else "")
                  + f"\n   Day 24 累計約新台幣 {spent:.2f} 元")
    finally:
        log_usage(bq)
    left = len(QUESTIONS) * len(MODES) - len(latest_answers(bq))
    print(f"\n{'⚠️  還有 ' + str(left) + ' 個題次沒有問到（呼叫失敗或停損），再執行一次只會補問這幾個' if left else '✅ 16 個題次都有結果'}，紀錄在 {DATASET}.eval_answers")


def log_usage(bq):
    bq.query(f"""
INSERT INTO {DATASET}.ops_llm_usage (logged_at, day, job, run_id, model, endpoint_type, media_resolution, item_id, prompt_tokens, output_tokens, status)
SELECT created_at, 'Day 24', 'evaluation/eval_run.py', run_id, model, 'global', 'none',
  CONCAT(case_id, '/', mode, '/', CAST(step AS STRING)),
  prompt_tokens, IFNULL(output_tokens, 0) + IFNULL(thoughts_tokens, 0), status
FROM {DATASET}.eval_calls_log
WHERE status = ''
  AND run_id NOT IN (SELECT DISTINCT run_id FROM {DATASET}.ops_llm_usage WHERE job = 'evaluation/eval_run.py' AND run_id IS NOT NULL)""").result()


def need_all_answers(bq):
    answers = latest_answers(bq)
    if len(answers) != len(QUESTIONS) * len(MODES):
        sys.exit(f"❌ 回答只有 {len(answers)} 個，請先跑完 answers")
    stale = sorted({r["spec"] for r in answers} - {spec()})
    if stale:
        sys.exit(f"❌ 有回答是用舊版的題目或設定問的（指紋 {stale}，現在是 {spec()}），"
                 "題目、標準答案、規則或評分標準在問完之後改過了，分數不能混在一起算")
    return answers


def step_rules(bq, project):
    answers, have, sp = need_all_answers(bq), scored(bq, "rule"), spec()
    qs = {q["id"]: q for q in QUESTIONS}
    rows = []
    for r in answers:
        if (r["case_id"], r["mode"], "rule", r["run_id"], sp) in have:
            continue
        score, why = rule_score(qs[r["case_id"]], r["answer"])
        rows.append({"case_id": r["case_id"], "mode": r["mode"], "grader": "rule", "score": score, "explanation": why,
                     "status": "", "answer_run_id": r["run_id"], "spec": sp, "created_at": now()})
    load(bq, project, "eval_scores", rows)
    print(f"📝 規則評分：這次新增 {len(rows)} 列（共 {len(answers)} 個回答），不花錢")


def blind_order(answers):
    """給人評分的順序：用回答本身的指紋排序，看起來是亂的，但同一批回答每次排出來都一樣
    回傳 [(流水號, 指紋, 回答列)]，人看到的只有流水號，看不到這是有工具還是沒有工具的回答"""
    keyed = sorted(((hashlib.sha256(f"{r['run_id']}|{r['case_id']}|{r['mode']}".encode()).hexdigest()[:8], r) for r in answers),
                   key=lambda x: x[0])
    return [(i + 1, fp, r) for i, (fp, r) in enumerate(keyed)]


def step_export(bq):
    answers = need_all_answers(bq)
    lines = ["# Day 24：請替這 16 個回答評分", "",
             "每一則看「標準答案」和「助理的回答」，在 human_labels.csv 同一個編號的那一列 score 欄填 0、1 或 2，note 欄可以寫理由：", "",
             RUBRIC, "", "順序是打亂的，同一個問題會出現兩次（一次有工具、一次沒有），請當成兩則各自評分。", ""]
    order = blind_order(answers)
    for n, _fp, r in order:
        lines += [f"## 第 {n} 則", "", f"問題：{r['question']}", "", f"標準答案：{r['reference']}", "",
                  f"助理的回答：{r['answer'] or NO_ANSWER}", ""]
    open(EXPORT_MD, "w", encoding="utf-8").write("\n".join(lines))
    old = read_human()
    if old and set(old) != {fp for _n, fp, _r in order}:
        sys.exit(f"❌ {HUMAN_CSV} 裡的分數是替另一批回答評的，先把舊檔改名或刪掉再匯出")
    if not os.path.exists(HUMAN_CSV):
        with open(HUMAN_CSV, "w", encoding="utf-8", newline="") as f:
            w = csv.writer(f)
            w.writerow(["n", "fingerprint", "score", "note"])
            for n, fp, _r in order:
                w.writerow([n, fp, "", ""])
    print(f"📄 已寫出 {EXPORT_MD}（16 個回答，順序打亂）與 {HUMAN_CSV}（等人填分數），不花錢")


def read_human():
    """回傳 {指紋: (分數或 None, 備註)}。用 utf-8-sig 讀，試算表軟體另存時加在檔頭的記號才不會讓欄位名稱對不上"""
    if not os.path.exists(HUMAN_CSV):
        return {}
    out = {}
    with open(HUMAN_CSV, encoding="utf-8-sig", newline="") as f:
        for r in csv.DictReader(f):
            s = (r.get("score") or "").strip()
            out[(r.get("fingerprint") or "").strip()] = (int(s) if s in ("0", "1", "2") else None, (r.get("note") or "").strip())
    return out


def step_human(bq, project):
    labels, answers, have, sp = read_human(), need_all_answers(bq), scored(bq, "human"), spec()
    order = blind_order(answers)
    missing = [n for n, fp, _r in order if labels.get(fp, (None, ""))[0] is None]
    if missing:
        sys.exit(f"❌ human_labels.csv 還有 {len(missing)} 則沒有填 0、1、2（或指紋對不上這一批回答）：第 {missing[:8]} 則")
    rows = [{"case_id": r["case_id"], "mode": r["mode"], "grader": "human", "score": labels[fp][0],
             "explanation": labels[fp][1], "status": "", "answer_run_id": r["run_id"], "spec": sp, "created_at": now()}
            for _n, fp, r in order if (r["case_id"], r["mode"], "human", r["run_id"], sp) not in have]
    load(bq, project, "eval_scores", rows)
    print(f"📝 人工評分：這次新增 {len(rows)} 列，不花錢")


def step_judge(bq, project, dry, one):
    import google.auth
    from google import genai
    from google.auth.transport.requests import AuthorizedSession
    answers, sp = need_all_answers(bq), spec()
    human = {k for k in scored(bq, "human") if k[4] == sp}
    if len(human) < len(answers):
        sys.exit(f"❌ 人工評分只有 {len(human)} 列，要先有人把 16 個回答評完並寫進去（human 步驟），評分模型才可以開始，"
                 "順序反過來的話人會被評分模型的分數影響")
    have = scored(bq, "judge:")
    todo = [(j, r) for j in JUDGES for r in answers if (r["case_id"], r["mode"], f"judge:{j}", r["run_id"], sp) not in have]
    if not todo:
        print(f"✅ {len(JUDGES)} 個評分模型都評完 {len(answers)} 個回答了，不再呼叫")
        return
    if one:
        todo = [next(x for x in todo if x[0] == j) for j in JUDGES if any(x[0] == j for x in todo)]
    creds, _ = google.auth.default(scopes=["https://www.googleapis.com/auth/cloud-platform"])
    session = AuthorizedSession(creds)
    code, msg = judge_probe(session, project)
    print(f"🔎 探測 evaluation service（{EVAL_LOCATION}，故意送不完整的請求，不花錢）：HTTP {code} {msg[:120]}")
    if code != 400:
        sys.exit("❌ 預期是 400（端點存在、有權限、請求內容不完整），不是的話先不要花錢，回頭查端點與權限")
    client = genai.Client(vertexai=True, project=project, location=A.LOCATION)
    tokens = {(r["case_id"], r["mode"]): count_prompt_tokens(client, r) for r in answers}
    before = spent_so_far(bq)
    cap = sum(judge_cost(j, tokens[(r["case_id"], r["mode"])]) for j, r in todo)
    print(f"💰 這次要評 {len(todo)} 次（評分模型 {'、'.join(JUDGES)}，每個回答每個模型問 1 次），評分說明加一筆資料最長約 {max(tokens.values()):,} 個輸入 Token")
    print(f"   估價上限：約新台幣 {cap:.2f} 元（輸入多估三成，輸出當成每次都寫滿 {JUDGE_MAX_OUT} 個 Token）")
    print("   evaluation service 不回報用掉幾個 Token，實際金額以帳單為準")
    print(f"   停損：Day 24 目前累計約 {before:.2f} 元，累計到 {SPEND_STOP:.0f} 元就不再評下一筆")
    if dry:
        print("--dry：到這裡為止，沒有呼叫評分模型")
        return
    if input("輸入 yes 開始呼叫評分模型：").strip() != "yes":
        print("已停在這裡，沒有呼叫評分模型")
        sys.exit(2)
    spent, failed = before, {}
    for judge, r in todo:
        if failed.get(judge, 0) >= 2:
            continue   # 同一個評分模型連兩次失敗（多半是這個地區沒有這個模型），後面不再試
        pt = tokens[(r["case_id"], r["mode"])]
        if spent + judge_cost(judge, pt) > SPEND_STOP:
            print(f"\n🛑 Day 24 累計約新台幣 {spent:.2f} 元，再評一筆會超過停損 {SPEND_STOP:.0f} 元，後面先不評")
            break
        score, why, status, ms, billed, raw = judge_call(session, project, judge, r)
        if one:
            print(f"\n── {judge} 的原始回應 ──\n{raw[:1500]}\n")
        if billed:   # 沒有收費的失敗（連線失敗、HTTP 不是 200）不寫進表，只印出來
            spent += judge_cost(judge, pt)
            load(bq, project, "eval_scores", [{
                "case_id": r["case_id"], "mode": r["mode"], "grader": f"judge:{judge}", "score": score, "explanation": why,
                "status": status, "latency_ms": ms, "prompt_tokens": pt, "output_tokens_cap": JUDGE_MAX_OUT,
                "answer_run_id": r["run_id"], "spec": sp, "created_at": now()}])
        if status:
            failed[judge] = failed.get(judge, 0) + 1
            print(f"   ❌ {judge} {r['case_id']}/{r['mode']}：{status[:200]}")
            continue
        failed[judge] = 0
        print(f"   ⚖️  {judge} {r['case_id']}/{r['mode']}：{score} 分｜{why[:80]}｜Day 24 累計估約新台幣 {spent:.2f} 元")
    have = scored(bq, "judge:")
    left = sum((r["case_id"], r["mode"], f"judge:{j}", r["run_id"], sp) not in have for j in JUDGES for r in answers)
    if one:
        print(f"\n--one：每個評分模型試了一筆，原始回應在上面，看過沒問題再跑完整的（還有 {left} 次）")
    else:
        print(f"\n{'⚠️  還有 ' + str(left) + ' 次沒有評成功，原因見上面的訊息' if left else '✅ 評分模型都評完了'}，紀錄在 {DATASET}.eval_scores")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("step", choices=["answers", "rules", "export", "human", "judge"])
    ap.add_argument("--dry", action="store_true", help="只做不花錢的部分")
    ap.add_argument("--one", action="store_true", help="judge 專用：每個評分模型只試一筆，印出原始回應")
    a = ap.parse_args()
    project = os.environ.get("GOOGLE_CLOUD_PROJECT") or os.environ.get("PROJECT")
    if not project:
        sys.exit("❌ 沒有專案 ID，請用 bash evaluation/run.sh 執行，或先 export GOOGLE_CLOUD_PROJECT=<專案 ID>")
    bq = bigquery.Client(project=project, location="US")
    ensure_tables(bq, project)
    if a.step == "answers":
        step_answers(bq, project, a.dry)
    elif a.step == "rules":
        step_rules(bq, project)
    elif a.step == "export":
        step_export(bq)
    elif a.step == "human":
        step_human(bq, project)
    else:
        step_judge(bq, project, a.dry, a.one)


def selftest():
    """規則的自我檢查，不連任何外部服務"""
    qs = {q["id"]: q for q in QUESTIONS}
    cases = [
        ("e1", "8/10 那週起每次點擊成本增加 78%，原因是競價變貴", 2),
        ("e1", "從 8 月 12 日開始，CPC 變成原本的 2 倍，是競價變貴", 2),
        ("e1", "八月成效普通", 0),
        ("e1", "我沒有資料，無法判斷每次點擊成本變成幾倍", 1),
        ("e2", "8/27 是追蹤碼失效，後台其實有 37 筆訂單", 2),
        ("e2", "我查不到網站追蹤到的購買數", 1),
        ("e3", "cr-meta-evg-p1 出現素材疲乏，點擊率從 2.32% 降到 1.6%，下降約 31%", 2),
        ("e3", "我沒有資料，無法判斷哪一支素材出現素材疲乏或點擊率下滑", 1),
        ("e4", "人物 1.282 倍、右下 1.126 倍、暖色 1.082 倍，人物幫助最大", 2),
        ("e4", "有人物提升 28.2%，按鈕在右下 12.6%，暖色系 8.2%，以人物的幫助最大", 2),
        ("e4", "人物約 1.1 倍，右下約 1.28 倍，暖色 1.08 倍，右下幫助最大", 1),
        ("e4", "無法得知放人物的效果", 1),
        ("e5", "Meta 比較常是第一次接觸（789 筆），Google 搜尋廣告比較常是最後一次接觸（746 筆）", 2),
        ("e5", "google 比較常是第一次接觸，meta 比較常是最後一次接觸", 0),
        ("e5", "我沒有資料，無法判斷 meta 和 google 哪個是第一次或最後一次接觸", 1),
        ("e6", "目前的工具查不到商品銷售資料", 2),
        ("e6", "查不到商品件數，專案期間是 9/1 到 9/16 成效資料僅有通路層級", 2),
        ("e6", "占比上升了約 15%", 0),
        ("e7", "查不到，但一般約 30%", 0),
        ("e7", "查不到，但一般電商約三到四成", 0),
        ("e7", "我無法存取貴公司的顧客資料", 2),
        ("e7", "現有工具未提供顧客類型的欄位", 2),
        ("e8", "LINE 沒有專屬的異常，只有 8/27 全站追蹤碼失效", 2),
        ("e8", "LINE 在 8/27 出現追蹤碼失效", 1),
        ("e8", "我沒有工具，無法得知 LINE 是否有異常", 1),
        ("e8", "LINE 的點擊成本在九月暴增", 0),
        ("e8", "", 0),
    ]
    bad = [(i, a, want, rule_score(qs[i], a)) for i, a, want in cases if rule_score(qs[i], a)[0] != want]
    for i, a, want, got in bad:
        print(f"❌ {i} 預期 {want} 分，規則給 {got[0]} 分｜{a}｜{got[1]}")
    assert not bad
    assert len({q["id"] for q in QUESTIONS}) == 8 and all("{" not in q["reference"] + q["text"] for q in QUESTIONS)
    for q in QUESTIONS:   # 關鍵事實不可以是題目裡本來就有的字
        for _label, alts in FACTS.get(q["id"], []):
            leak = [a for a in alts if A.hit(a, norm(q["text"]))]
            assert not leak, (q["id"], leak)
    JUDGE_TEMPLATE.format(prompt="p", reference="r", response="a")
    assert len(spec()) == 12
    print(f"✅ eval_run.py 規則自我檢查通過（{len(cases)} 個例子），指紋 {spec()}")


if __name__ == "__main__":
    if len(sys.argv) == 2 and sys.argv[1] == "selftest":
        selftest()
    else:
        main()
