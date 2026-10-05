"""Day 21：同一批問題，有工具和沒有工具各問一次 Gemini

用法：python3 agent/ask.py            （在儲存庫根目錄執行，通常由 bash agent/run.sh 呼叫）
      python3 agent/ask.py --score    （只重新對答案，不呼叫模型）

流程：列出還沒問過的 →  印出最壞估價 → 輸入 yes → 逐題問 → 記錄 → 對答案
- 有工具：模型回傳「我要呼叫哪個工具、參數是什麼」，由這支程式去查 BigQuery，把結果交回去，直到模型給出文字回答
- 沒有工具：同一句系統指示、同一個問題，只是不給工具
SDK 的「自動執行函式」關掉了，每一步都自己處理，這樣才看得到也記得下模型每一輪要求了什麼
問過而且成功的不會再問，重跑不會重複收費
"""
import argparse
import datetime
import hashlib
import json
import os
import re
import sys
import time
import uuid

from google import genai
from google.cloud import bigquery
from google.genai import types

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import tools as T  # noqa: E402

MODEL = "gemini-3.6-flash"   # 換模型要連下面的單價一起改
LOCATION = "global"
DATASET = T.DATASET
MAX_STEPS = 4            # 一個問題最多呼叫模型幾次（含最後作答那一次）
MAX_OUTPUT = 2048        # 每次呼叫的輸出上限，思考 Token 也算在裡面
INPUT_CAP = 4000         # 每次呼叫的輸入上限，送出前先數，超過就不送
PRICE_IN, PRICE_OUT, FX = 0.75, 3.75, 32   # gemini-3.6-flash global 端點每百萬 Token 的美元單價、匯率
EXPECT_IN = {"tools": 1300, "none": 80}    # 估「預期費用」用的每次輸入 Token（估計值）
EXPECT_OUT = 150

SYSTEM = "你是電商品牌的行銷資料助理，用繁體中文、三句話以內回答同事的問題。"

QUESTIONS = [
    {"id": "q1", "kind": "一個工具",
     "text": "6 月 19 日到 9 月 16 日這段期間，用時間衰減的算法，哪個通路分到的訂單功勞最多？大概多少筆？",
     "tools": ["get_channel_attribution"], "args": {"get_channel_attribution": {"attribution_model": ["time_decay"]}}},
    {"id": "q2", "kind": "一個工具",
     "text": "meta 的廣告成效出過哪些狀況？原因各是什麼？",
     "tools": ["get_anomaly_diagnosis"], "args": {"get_anomaly_diagnosis": {"channel": ["meta"]}}},
    {"id": "q3", "kind": "一個工具",
     "text": "廣告圖上有人物，點擊率會比較高嗎？高多少？",
     "tools": ["get_creative_feature_lift"], "args": {"get_creative_feature_lift": {"metric": ["ctr"]}}},
    {"id": "q4", "kind": "兩個工具",
     "text": "meta 這個通路用最終點擊和用時間衰減算出來的訂單功勞各是多少筆？另外它出過的成效異常是什麼原因？",
     "tools": ["get_anomaly_diagnosis", "get_channel_attribution"],
     "args": {"get_channel_attribution": {"attribution_model": ["last_touch", "time_decay"]},
              "get_anomaly_diagnosis": {"channel": ["meta"]}}},
    {"id": "q5", "kind": "不需要查",
     "text": "多觸點歸因裡的「時間衰減」是什麼意思？用一兩句話說明就好",
     "tools": [], "args": {}},
    {"id": "q6", "kind": "查不到",
     "text": "上個月 TikTok 廣告總共花了多少錢？",
     "tools": None, "args": {}},   # 沒有工具答得了，呼叫不呼叫都不算錯，看的是有沒有編出金額
]
MODES = ("tools", "none")

SCHEMAS = {
    "fc_calls_log": [
        ("run_id", "STRING"), ("question_id", "STRING"), ("mode", "STRING"), ("step", "INT64"), ("model", "STRING"),
        ("prompt_tokens", "INT64"), ("output_tokens", "INT64"), ("thoughts_tokens", "INT64"),
        ("function_calls", "STRING"), ("finish_reason", "STRING"), ("status", "STRING"),
        ("latency_ms", "INT64"), ("created_at", "TIMESTAMP")],
    "fc_tool_log": [
        ("run_id", "STRING"), ("question_id", "STRING"), ("step", "INT64"), ("tool", "STRING"), ("args", "STRING"),
        ("result_rows", "INT64"), ("error", "STRING"), ("bytes_billed", "INT64"), ("created_at", "TIMESTAMP")],
    "fc_answers": [
        ("run_id", "STRING"), ("question_id", "STRING"), ("mode", "STRING"), ("question", "STRING"),
        ("answer", "STRING"), ("tools_called", "STRING"), ("model_calls", "INT64"), ("tool_calls", "INT64"),
        ("status", "STRING"), ("prompt_version", "STRING"), ("created_at", "TIMESTAMP")],
}
DESCRIPTIONS = {
    "fc_calls_log": "Day 21 呼叫紀錄：一列＝呼叫一次模型，成功失敗都保留",
    "fc_tool_log": "Day 21 工具紀錄：一列＝程式替模型執行一次工具",
    "fc_answers": "Day 21 回答：一列＝一個問題 × 有沒有給工具，只加不刪",
}


def now():
    return datetime.datetime.now(datetime.timezone.utc).isoformat()


def prompt_version(q):
    blob = json.dumps([MODEL, SYSTEM, T.DECLARATIONS, q["text"], MAX_STEPS, MAX_OUTPUT], ensure_ascii=False, sort_keys=True)
    return hashlib.sha256(blob.encode()).hexdigest()[:12]


def ensure_tables(bq, project):
    for name, cols in SCHEMAS.items():
        table = bigquery.Table(f"{project}.{DATASET}.{name}", schema=[bigquery.SchemaField(c, t) for c, t in cols])
        table.description = DESCRIPTIONS[name]
        bq.create_table(table, exists_ok=True)


def load(bq, project, name, rows):
    """用批次載入寫紀錄（免費，而且不會像串流寫入那樣有一段時間不能改）"""
    if not rows:
        return
    cfg = bigquery.LoadJobConfig(schema=[bigquery.SchemaField(c, t) for c, t in SCHEMAS[name]],
                                 write_disposition="WRITE_APPEND")
    bq.load_table_from_json(rows, f"{project}.{DATASET}.{name}", job_config=cfg).result()


def pending(bq):
    # 不再問的：成功過的，以及「模型有回應但不算成功」已經兩次的（溫度是 0，再問多半還是一樣）
    done = {(r["question_id"], r["mode"], r["prompt_version"]) for r in bq.query(f"""
SELECT question_id, mode, prompt_version FROM {DATASET}.fc_answers
GROUP BY 1, 2, 3
HAVING COUNTIF(status = '') > 0 OR COUNTIF(status != '' AND NOT STARTS_WITH(status, 'error')) >= 2""").result()}
    return [(q, m) for q in QUESTIONS for m in MODES if (q["id"], m, prompt_version(q)) not in done]


def estimate(todo):
    calls = sum(MAX_STEPS if m == "tools" else 1 for _, m in todo)
    worst = calls * (INPUT_CAP * PRICE_IN + MAX_OUTPUT * PRICE_OUT) / 1e6 * FX
    likely = sum((2.5 if m == "tools" else 1) * (EXPECT_IN[m] * PRICE_IN + EXPECT_OUT * PRICE_OUT) for _, m in todo) / 1e6 * FX
    print(f"💰 這次要問 {len(todo)} 題次（有工具 {sum(m == 'tools' for _, m in todo)}、沒有工具 {sum(m == 'none' for _, m in todo)}），模型 {MODEL}")
    print(f"   最多呼叫模型 {calls} 次（有工具每題最多 {MAX_STEPS} 次、沒有工具 1 次）")
    print(f"   最壞情況：每次輸入都頂到 {INPUT_CAP:,}、輸出都寫滿 {MAX_OUTPUT:,} 個 Token，約新台幣 {worst:.2f} 元")
    print(f"   預期：約新台幣 {likely:.2f} 元（估計值）")
    print(f"   BigQuery 查詢每次最多掃 {T.MAX_BYTES // 1024 // 1024} MB，在每月 1 TiB 免費額度內")


def count_input(client, contents, config):
    """送出前先數輸入 Token（數 Token 不收費），數不出來回傳 None，由呼叫的地方決定不送"""
    try:
        r = client.models.count_tokens(model=MODEL, contents=contents, config=types.CountTokensConfig(
            system_instruction=config.system_instruction, tools=config.tools))
        return r.total_tokens
    except Exception as e:
        print(f"   ⚠️  數不出輸入 Token：{type(e).__name__}: {str(e)[:120]}")
        return None


def make_config(mode):
    return types.GenerateContentConfig(
        system_instruction=SYSTEM,
        tools=[types.Tool(function_declarations=T.DECLARATIONS)] if mode == "tools" else None,
        temperature=0, max_output_tokens=MAX_OUTPUT,
        thinking_config=types.ThinkingConfig(thinking_level="LOW"),
        # 關掉自動執行：SDK 預設會自己把函式跑完再回來，中間每一步都看不到
        automatic_function_calling=types.AutomaticFunctionCallingConfig(disable=True))


def preflight(client, bq):
    """花錢之前先確認最長的那一題放得進輸入上限：照 q4 預期的三次工具呼叫實際查表，組出對話再數 Token（都不收費）"""
    q = next(x for x in QUESTIONS if x["id"] == "q4")
    wanted = [("get_channel_attribution", {"attribution_model": "last_touch"}),
              ("get_channel_attribution", {"attribution_model": "time_decay"}),
              ("get_anomaly_diagnosis", {"channel": "meta"})]
    contents = [types.Content(role="user", parts=[types.Part(text=q["text"])]),
                types.Content(role="model", parts=[types.Part(function_call=types.FunctionCall(name=n, args=a)) for n, a in wanted])]
    parts = []
    for n, a in wanted:
        result, _ = T.run_tool(bq, n, a)
        if "error" in result or not result.get("rows"):
            sys.exit(f"❌ 預檢：{n} {a} 查不到資料或失敗（{result.get('error', '0 列')}），沒有呼叫模型")
        parts.append(types.Part.from_function_response(name=n, response=result))
    contents.append(types.Content(role="user", parts=parts))
    n_in = count_input(client, contents, make_config("tools"))
    if n_in is None or n_in > INPUT_CAP * 0.85:
        sys.exit(f"❌ 預檢：最長的一題輸入 {n_in} 個 Token，太接近上限 {INPUT_CAP:,}，沒有呼叫模型")
    print(f"🔎 預檢：三個工具都查得到資料，最長的一題（q4 拿到三份結果之後）輸入 {n_in:,} 個 Token，上限 {INPUT_CAP:,}")


def ask(client, bq, q, mode, run_id):
    """問一題，回傳 (回答列, 呼叫紀錄, 工具紀錄)"""
    config = make_config(mode)
    contents = [types.Content(role="user", parts=[types.Part(text=q["text"])])]
    calls, tool_rows, called, answer, status = [], [], [], "", ""
    for step in range(1, MAX_STEPS + 1):
        n_in = count_input(client, contents, config)
        if n_in is None:
            status = "error:count_failed"
            break
        if n_in > INPUT_CAP:
            status = f"input_cap:{n_in}"
            break
        t0 = time.time()
        try:
            resp = client.models.generate_content(model=MODEL, contents=contents, config=config)
        except Exception as e:  # 呼叫失敗不收費，記下來換下一題
            status = f"error:{type(e).__name__}:{str(e)[:200]}"
            calls.append({"run_id": run_id, "question_id": q["id"], "mode": mode, "step": step, "model": MODEL,
                          "status": status, "latency_ms": int((time.time() - t0) * 1000), "created_at": now()})
            break
        u = resp.usage_metadata or types.GenerateContentResponseUsageMetadata()
        cand = resp.candidates[0] if resp.candidates else None
        fcs = list(resp.function_calls or [])
        finish = str(cand.finish_reason.name if cand and cand.finish_reason else "")
        calls.append({
            "run_id": run_id, "question_id": q["id"], "mode": mode, "step": step, "model": MODEL,
            "prompt_tokens": u.prompt_token_count or 0, "output_tokens": u.candidates_token_count or 0,
            "thoughts_tokens": u.thoughts_token_count or 0,
            "function_calls": json.dumps([{"name": f.name, "args": dict(f.args or {})} for f in fcs], ensure_ascii=False),
            "finish_reason": finish, "status": "", "latency_ms": int((time.time() - t0) * 1000), "created_at": now()})
        if not fcs:
            answer = (resp.text or "").strip()
            if finish == "MAX_TOKENS":
                status = "max_tokens"
            elif not answer:
                status = "empty"
            break
        if step == MAX_STEPS:   # 已經是最後一次，查了也沒有機會交回去
            status = "max_steps"
            break
        # 模型這一輪的內容要原封不動放回對話（裡面除了函式呼叫還有思考簽章），再接上每個工具的結果
        contents.append(cand.content)
        parts = []
        for f in fcs:
            args = dict(f.args or {})
            result, billed = T.run_tool(bq, f.name, args)
            called.append({"name": f.name, "args": args})
            tool_rows.append({"run_id": run_id, "question_id": q["id"], "step": step, "tool": f.name,
                              "args": json.dumps(args, ensure_ascii=False), "result_rows": len(result.get("rows", [])),
                              "error": result.get("error", ""), "bytes_billed": billed, "created_at": now()})
            parts.append(types.Part.from_function_response(name=f.name, response=result))
        contents.append(types.Content(role="user", parts=parts))
    row = {"run_id": run_id, "question_id": q["id"], "mode": mode, "question": q["text"], "answer": answer,
           "tools_called": json.dumps(called, ensure_ascii=False), "model_calls": len(calls), "tool_calls": len(called),
           "status": status, "prompt_version": prompt_version(q), "created_at": now()}
    return row, calls, tool_rows


def log_usage(bq):
    """抄一份進共用的 Token 用量表（Day 25 用），思考 Token 按輸出計費所以加在一起，抄過的 run_id 不再抄"""
    bq.query(f"""
INSERT INTO {DATASET}.ops_llm_usage (logged_at, day, job, run_id, model, endpoint_type, media_resolution, item_id, prompt_tokens, output_tokens, status)
SELECT created_at, 'Day 21', 'agent/ask.py', run_id, model, 'global', 'none',
  CONCAT(question_id, '/', mode, '/', CAST(step AS STRING)),
  prompt_tokens, IFNULL(output_tokens, 0) + IFNULL(thoughts_tokens, 0), status
FROM {DATASET}.fc_calls_log
WHERE status = ''
  AND run_id NOT IN (SELECT DISTINCT run_id FROM {DATASET}.ops_llm_usage WHERE job = 'agent/ask.py' AND run_id IS NOT NULL)""").result()


# ── 對答案：標準答案另外寫 SQL 直接查，不經過工具的程式 ────────────────────────
def clean(text):
    return re.sub(r"[,，\s]", "", text or "")


def hit(alt, text):
    """數字要整個數字對上（380 不能算在 1380 或 3800 裡），文字用包含"""
    if re.fullmatch(r"\d+(\.\d+)?[%％倍]?", alt):
        return re.search(rf"(?<![\d.]){re.escape(alt)}(?!\d)", text) is not None
    return alt in text


def truth(bq):
    def one(sql):
        rows = [dict(r) for r in bq.query(sql).result()]
        if not rows or any(v is None for v in rows[0].values()):
            sys.exit(f"❌ 標準答案查不到資料：{sql}")
        return rows
    top = one(f"SELECT channel, SUM(credit_decay) v FROM {DATASET}.mart_attribution GROUP BY 1 ORDER BY 2 DESC LIMIT 1")[0]
    meta = one(f"SELECT SUM(credit_last) l, SUM(credit_decay) d FROM {DATASET}.mart_attribution WHERE channel = 'meta / paid_social'")[0]
    causes = [clean(r["cause"]) for r in one(
        f"""SELECT DISTINCT d.cause FROM {DATASET}.diag_summary s JOIN {DATASET}.mart_diagnosis d USING (anomaly_id)
            WHERE s.channel = 'meta' AND d.model = 'gemini-3.6-flash' AND IFNULL(d.cause, '') != '' ORDER BY 1""")]
    person = one(f"SELECT stratified v FROM {DATASET}.mart_creative_lift WHERE attr = 'person' AND metric = 'ctr'")[0]["v"]

    def num(v):   # 620.4 → 寫 620、620.4 或四捨五入都算對
        return sorted({str(int(v)), str(round(v)), f"{v:.1f}"})
    pct = abs(round((person - 1) * 100))
    direct = ["direct", "直接流量", "直接造訪", "直接進站"] if "direct" in top["channel"] else [top["channel"].split(" / ")[0]]
    return {
        "q1": [direct, num(top["v"])],
        "q2": [[c] for c in causes],
        "q3": [[f"{person:.2f}", f"{person:.3f}", f"{person:.2f}倍", f"{person:.3f}倍", f"{pct}%", f"{pct}％"]],
        "q4": [num(meta["l"]), num(meta["d"]), causes],
        "q5": [], "q6": [],
    }


SCORE_COLS = [
    ("question_id", "STRING"), ("kind", "STRING"), ("mode", "STRING"), ("question", "STRING"), ("answer", "STRING"),
    ("tools_expected", "STRING"), ("tools_called", "STRING"), ("tools_ok", "BOOL"), ("args_ok", "BOOL"),
    ("facts_total", "INT64"), ("facts_found", "INT64"), ("facts_expected", "STRING"), ("has_figure", "BOOL"),
    ("model_calls", "INT64"), ("tool_calls", "INT64"), ("run_id", "STRING"), ("scored_at", "TIMESTAMP")]


def score(bq, project, facts):
    rows = [dict(r) for r in bq.query(f"""
SELECT * FROM {DATASET}.fc_answers WHERE status = ''
QUALIFY ROW_NUMBER() OVER (PARTITION BY question_id, mode ORDER BY created_at DESC) = 1""").result()]
    out = []
    for r in rows:
        q = next((x for x in QUESTIONS if x["id"] == r["question_id"]), None)
        if q is None or r["prompt_version"] != prompt_version(q):
            continue
        called = json.loads(r["tools_called"] or "[]")
        names = sorted({c["name"] for c in called})
        text = clean(r["answer"])
        need = facts[q["id"]]
        found = sum(any(hit(alt, text) for alt in alts) for alts in need)
        tools_ok = args_ok = None
        if r["mode"] == "tools" and q["tools"] is not None:
            tools_ok = names == sorted(q["tools"])
            args_ok = all(
                any(c["name"] == tool and c["args"].get(key) == want for c in called)
                for tool, spec in q["args"].items() for key, wants in spec.items() for want in wants)
            # 歸因工具另外看：日期沒有被填成資料期間以外、沒有自己決定排除直接流量
            for c in called:
                if c["name"] == "get_channel_attribution":
                    a = c["args"]
                    args_ok = args_ok and a.get("start_date", T.DATA_START) == T.DATA_START \
                        and a.get("end_date", T.DATA_END) == T.DATA_END and a.get("exclude_direct", False) is False
        out.append({
            "question_id": q["id"], "kind": q["kind"], "mode": r["mode"], "question": q["text"], "answer": r["answer"],
            "tools_expected": "不計" if q["tools"] is None else (",".join(sorted(q["tools"])) or "不呼叫"),
            "tools_called": ",".join(names) or "不呼叫", "tools_ok": tools_ok, "args_ok": args_ok,
            "facts_total": len(need), "facts_found": found,
            "facts_expected": json.dumps(need, ensure_ascii=False),
            # 回答裡有沒有帶單位的數字（筆、元、倍、%），沒有工具時出現就是編的，要人工看原文確認
            "has_figure": bool(re.search(r"\d[\d.]*(筆|元|萬|倍|%|％|個百分點)", text)),
            "model_calls": r["model_calls"], "tool_calls": r["tool_calls"], "run_id": r["run_id"], "scored_at": now()})
    schema = [bigquery.SchemaField(c, t) for c, t in SCORE_COLS]
    bq.load_table_from_json(out, f"{project}.{DATASET}.mart_fc_score", job_config=bigquery.LoadJobConfig(
        schema=schema, write_disposition="WRITE_TRUNCATE")).result()
    print(f"📝 對完答案：{len(out)} 列寫進 {DATASET}.mart_fc_score")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--score", action="store_true", help="只重新對答案，不呼叫模型")
    a = ap.parse_args()
    project = os.environ.get("GOOGLE_CLOUD_PROJECT") or os.environ.get("PROJECT")
    if not project:
        sys.exit("❌ 沒有專案 ID，請用 bash agent/run.sh 執行，或先 export GOOGLE_CLOUD_PROJECT=<專案 ID>")
    bq = bigquery.Client(project=project, location="US")
    ensure_tables(bq, project)
    facts = truth(bq)   # 標準答案先查好，查不到就在花錢之前停下來
    if not a.score:
        todo = pending(bq)
        if not todo:
            print("✅ 12 題次都問過了，不再呼叫模型")
        else:
            client = genai.Client(vertexai=True, project=project, location=LOCATION)
            preflight(client, bq)
            estimate(todo)
            if input("輸入 yes 開始呼叫模型：").strip() != "yes":
                print("已停在這裡，沒有呼叫模型")
                sys.exit(2)
            run_id = uuid.uuid4().hex[:12]
            try:
                for q, mode in todo:
                    row, calls, tool_rows = ask(client, bq, q, mode, run_id)
                    load(bq, project, "fc_calls_log", calls)
                    load(bq, project, "fc_tool_log", tool_rows)
                    load(bq, project, "fc_answers", [row])
                    used = sum(c.get("prompt_tokens", 0) for c in calls), sum(
                        c.get("output_tokens", 0) + c.get("thoughts_tokens", 0) for c in calls)
                    print(f"   {q['id']} {mode:<5} 呼叫模型 {len(calls)} 次、工具 {len(tool_rows)} 次，"
                          f"輸入 {used[0]:,}、輸出含思考 {used[1]:,} 個 Token {'❌ ' + row['status'] if row['status'] else '✅'}")
            finally:
                log_usage(bq)   # 中途出錯也要把已經花掉的用量抄進去
    score(bq, project, facts)


if __name__ == "__main__":
    main()
