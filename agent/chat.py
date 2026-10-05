"""Day 22：把 Day 21 的工具接成可以連續對話的行銷助理

用法：python3 agent/chat.py            （照固定的五句話問一輪，文章用的就是這一輪）
      python3 agent/chat.py --talk     （自己打字聊，輸入空白行結束）
通常由 bash agent/chat.sh 呼叫

和 Day 21 的差別只有三件事：
- 對話紀錄留著：每一輪的問題、模型的工具要求、工具結果和回答都接在同一份 contents 後面，下一輪整份再送一次
- 告訴模型今天是哪一天：模型不知道今天的日期，「上週」要靠系統指示裡的日期才換算得出來
- 多一個查廣告花費的工具
對話越長每一輪的輸入越多，所以設了輪數上限和輸入上限，超過就請使用者開新對話
"""
import argparse
import datetime
import json
import os
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
MAX_STEPS = 4            # 一輪最多呼叫模型幾次（含最後作答那一次）
MAX_TURNS = 8            # 一場對話最多幾輪
MAX_OUTPUT = 2048        # 每次呼叫的輸出上限，思考 Token 也算在裡面
INPUT_CAP = 8000         # 每次呼叫的輸入上限，對話紀錄也算在裡面，送出前先數，超過就不送
PRICE_IN, PRICE_OUT, FX = 0.75, 3.75, 32
# 資料只到 AD_END，把隔天當成今天，使用者說的「上週」才對得到有資料的日期
TODAY = (datetime.date.fromisoformat(T.AD_END) + datetime.timedelta(days=1)).isoformat()
WEEKDAY = "一二三四五六日"[datetime.date.fromisoformat(TODAY).weekday()]

SYSTEM = (
    "你是電商品牌的行銷資料助理，用繁體中文回答同事的問題，回答控制在四句話以內。"
    "回答裡的數字只能來自工具查到的結果，工具查不到的就直接說查不到，不要自己估。"
    f"今天是 {TODAY}（星期{WEEKDAY}），資料最新到 {T.AD_END}。"
    "使用者說的今天、上週、上個月都以這個日期換算，一週從星期一算到星期日，上週指的是今天所在那一週的前一週。"
    "同一場對話裡已經查過的資料可以直接用，不用重查。"
)

# 文章用的固定腳本：後面幾句都要靠前面的對話才聽得懂
SCRIPT = [
    "上週哪支廣告花最多錢？",
    "它的點擊率跟其他幾支比起來怎麼樣？",
    "那再前一週呢？一樣是它最貴嗎？",
    "上週花最多錢的通路是哪個？它在同一週用時間衰減算的訂單功勞排第幾？",
    "幫我把剛剛聊到的整理成三點，我要貼給主管",
]

SCHEMAS = {
    "chat_calls_log": [
        ("session_id", "STRING"), ("turn", "INT64"), ("step", "INT64"), ("model", "STRING"),
        ("prompt_tokens", "INT64"), ("output_tokens", "INT64"), ("thoughts_tokens", "INT64"),
        ("function_calls", "STRING"), ("finish_reason", "STRING"), ("status", "STRING"),
        ("latency_ms", "INT64"), ("created_at", "TIMESTAMP")],
    "chat_tool_log": [
        ("session_id", "STRING"), ("turn", "INT64"), ("step", "INT64"), ("tool", "STRING"), ("args", "STRING"),
        ("result_rows", "INT64"), ("error", "STRING"), ("bytes_billed", "INT64"), ("created_at", "TIMESTAMP")],
    "chat_turns": [
        ("session_id", "STRING"), ("mode", "STRING"), ("turn", "INT64"), ("question", "STRING"), ("answer", "STRING"),
        ("tools_called", "STRING"), ("model_calls", "INT64"), ("tool_calls", "INT64"),
        ("status", "STRING"), ("created_at", "TIMESTAMP")],
}
DESCRIPTIONS = {
    "chat_calls_log": "Day 22 呼叫紀錄：一列＝呼叫一次模型",
    "chat_tool_log": "Day 22 工具紀錄：一列＝程式替模型執行一次工具",
    "chat_turns": "Day 22 對話：一列＝一輪問答，只加不刪",
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


def make_config():
    return types.GenerateContentConfig(
        system_instruction=SYSTEM, tools=[types.Tool(function_declarations=T.DECLARATIONS_V2)],
        temperature=0, max_output_tokens=MAX_OUTPUT,
        thinking_config=types.ThinkingConfig(thinking_level="LOW"),
        automatic_function_calling=types.AutomaticFunctionCallingConfig(disable=True))


def count_input(client, contents, config):
    try:
        return client.models.count_tokens(model=MODEL, contents=contents, config=types.CountTokensConfig(
            system_instruction=config.system_instruction, tools=config.tools)).total_tokens
    except Exception as e:
        print(f"   ⚠️  數不出輸入 Token：{type(e).__name__}: {str(e)[:120]}")
        return None


def one_turn(client, bq, contents, config, question, session_id, turn):
    """問一輪。contents 是整場對話的紀錄，這一輪成功才會把新的內容留在裡面，失敗就還原"""
    keep = len(contents)
    contents.append(types.Content(role="user", parts=[types.Part(text=question)]))
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
        except Exception as e:
            status = f"error:{type(e).__name__}:{str(e)[:200]}"
            calls.append({"session_id": session_id, "turn": turn, "step": step, "model": MODEL, "status": status,
                          "latency_ms": int((time.time() - t0) * 1000), "created_at": now()})
            break
        u = resp.usage_metadata or types.GenerateContentResponseUsageMetadata()
        cand = resp.candidates[0] if resp.candidates else None
        fcs = list(resp.function_calls or [])
        finish = str(cand.finish_reason.name if cand and cand.finish_reason else "")
        calls.append({
            "session_id": session_id, "turn": turn, "step": step, "model": MODEL,
            "prompt_tokens": u.prompt_token_count or 0, "output_tokens": u.candidates_token_count or 0,
            "thoughts_tokens": u.thoughts_token_count or 0,
            "function_calls": json.dumps([{"name": f.name, "args": dict(f.args or {})} for f in fcs], ensure_ascii=False),
            "finish_reason": finish, "status": "", "latency_ms": int((time.time() - t0) * 1000), "created_at": now()})
        if cand is None or cand.content is None:
            status = "empty"
            break
        if not fcs:
            answer = (resp.text or "").strip()
            if finish == "MAX_TOKENS":
                status = "max_tokens"
            elif not answer:
                status = "empty"
            else:
                contents.append(cand.content)   # 回答也要留在紀錄裡，下一輪才知道自己說過什麼
            break
        if step == MAX_STEPS:
            status = "max_steps"
            break
        contents.append(cand.content)
        parts = []
        for f in fcs:
            args = dict(f.args or {})
            result, billed = T.run_tool(bq, f.name, args)
            called.append({"name": f.name, "args": args})
            tool_rows.append({"session_id": session_id, "turn": turn, "step": step, "tool": f.name,
                              "args": json.dumps(args, ensure_ascii=False), "result_rows": len(result.get("rows", [])),
                              "error": result.get("error", ""), "bytes_billed": billed, "created_at": now()})
            parts.append(types.Part.from_function_response(name=f.name, response=result))
        contents.append(types.Content(role="user", parts=parts))
    if status:
        del contents[keep:]   # 這一輪沒成功，不要把半套的內容留在紀錄裡
    row = {"session_id": session_id, "turn": turn, "question": question, "answer": answer,
           "tools_called": json.dumps(called, ensure_ascii=False), "model_calls": len(calls),
           "tool_calls": len(called), "status": status, "created_at": now()}
    return row, calls, tool_rows


def log_usage(bq):
    """抄一份進共用的 Token 用量表（Day 25 用），抄過的 session 不再抄"""
    bq.query(f"""
INSERT INTO {DATASET}.ops_llm_usage (logged_at, day, job, run_id, model, endpoint_type, media_resolution, item_id, prompt_tokens, output_tokens, status)
SELECT created_at, 'Day 22', 'agent/chat.py', session_id, model, 'global', 'none',
  CONCAT('turn', CAST(turn AS STRING), '/', CAST(step AS STRING)),
  prompt_tokens, IFNULL(output_tokens, 0) + IFNULL(thoughts_tokens, 0), status
FROM {DATASET}.chat_calls_log
WHERE status = ''
  AND session_id NOT IN (SELECT DISTINCT run_id FROM {DATASET}.ops_llm_usage WHERE job = 'agent/chat.py' AND run_id IS NOT NULL)""").result()


def cost(calls):
    return sum(c.get("prompt_tokens", 0) * PRICE_IN + (c.get("output_tokens", 0) + c.get("thoughts_tokens", 0)) * PRICE_OUT
               for c in calls) / 1e6 * FX


def worst(turns):
    return turns * MAX_STEPS * (INPUT_CAP * PRICE_IN + MAX_OUTPUT * PRICE_OUT) / 1e6 * FX


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--talk", action="store_true", help="自己打字聊，不跑固定腳本")
    a = ap.parse_args()
    project = os.environ.get("GOOGLE_CLOUD_PROJECT") or os.environ.get("PROJECT")
    if not project:
        sys.exit("❌ 沒有專案 ID，請用 bash agent/chat.sh 執行，或先 export GOOGLE_CLOUD_PROJECT=<專案 ID>")
    bq = bigquery.Client(project=project, location="US")
    ensure_tables(bq, project)
    mode = "talk" if a.talk else "script"
    if mode == "script":
        done = list(bq.query(f"""
SELECT session_id FROM {DATASET}.chat_turns WHERE mode = 'script'
GROUP BY 1 HAVING COUNTIF(status = '') = {len(SCRIPT)} LIMIT 1""").result())
        if done:
            print(f"✅ 固定腳本已經完整跑過一次（session {done[0]['session_id']}），不再呼叫模型，要重跑請用 --talk 自己問")
            return
    # 花錢之前先確認花費工具查得到上週的資料（不收費的查詢）
    today = datetime.date.fromisoformat(TODAY)
    monday = today - datetime.timedelta(days=today.weekday() + 7)
    probe, _ = T.run_tool(bq, "get_ad_spend", {"start_date": monday.isoformat(),
                                               "end_date": (monday + datetime.timedelta(days=6)).isoformat(),
                                               "group_by": "creative"})
    if "error" in probe or not probe.get("rows"):
        sys.exit(f"❌ 預檢：上週（{monday} 起七天）查不到廣告花費（{probe.get('error', '0 列')}），沒有呼叫模型")
    print(f"🔎 預檢：把 {TODAY} 當成今天，上週是 {monday} 到 {monday + datetime.timedelta(days=6)}，查得到 {len(probe['rows'])} 支廣告的花費")
    turns = len(SCRIPT) if mode == "script" else MAX_TURNS
    print(f"💰 模型 {MODEL}，最多 {turns} 輪、每輪最多呼叫模型 {MAX_STEPS} 次")
    print(f"   最壞情況：每次輸入都頂到 {INPUT_CAP:,}、輸出都寫滿 {MAX_OUTPUT:,} 個 Token，約新台幣 {worst(turns):.2f} 元")
    print(f"   預期：五輪約新台幣 1 元上下（估計值，對話越長每一輪的輸入越多）")
    if input("輸入 yes 開始呼叫模型：").strip() != "yes":
        print("已停在這裡，沒有呼叫模型")
        sys.exit(2)
    client = genai.Client(vertexai=True, project=project, location=LOCATION)
    config, contents, session_id, spent = make_config(), [], uuid.uuid4().hex[:12], 0.0
    try:
        for turn in range(1, turns + 1):
            if mode == "script":
                question = SCRIPT[turn - 1]
                print(f"\n🙋 {question}")
            else:
                question = input("\n🙋 ").strip()
                if not question:
                    break
            row, calls, tool_rows = one_turn(client, bq, contents, config, question, session_id, turn)
            row["mode"] = mode
            load(bq, project, "chat_calls_log", calls)
            load(bq, project, "chat_tool_log", tool_rows)
            load(bq, project, "chat_turns", [row])
            spent += cost(calls)
            for t in tool_rows:
                print(f"   🔧 {t['tool']} {t['args']}" + (f" ❌ {t['error']}" if t["error"] else f" → {t['result_rows']} 列"))
            print(f"🤖 {row['answer'] or '（這一輪沒有成功：' + row['status'] + '）'}")
            print(f"   第 {turn} 輪：呼叫模型 {len(calls)} 次，輸入 {sum(c.get('prompt_tokens', 0) for c in calls):,}、"
                  f"輸出含思考 {sum(c.get('output_tokens', 0) + c.get('thoughts_tokens', 0) for c in calls):,} 個 Token，累計約新台幣 {spent:.2f} 元")
            if row["status"].startswith("input_cap"):
                print("   對話紀錄已經超過輸入上限，請開一場新的對話")
                break
            if mode == "script" and row["status"]:
                print("   固定腳本有一輪沒成功，後面幾輪要靠它的內容，先停下來")
                break
        else:
            if mode == "talk":
                print(f"\n已經聊了 {MAX_TURNS} 輪，這場對話到這裡，要繼續請再執行一次")
    finally:
        log_usage(bq)   # 中途出錯或按 Ctrl+C 也要把已經花掉的用量抄進去
    print(f"\n✅ 對話結束：session {session_id}，紀錄在 {DATASET}.chat_turns、chat_calls_log、chat_tool_log")


if __name__ == "__main__":
    main()
