#!/usr/bin/env python3
# Day 20（選配）：在 Colab 的 GPU 上用開源的 Gemma 4 做同一份簡單題（看一張廣告圖填五個欄位）
# 由 run_gemma_colab.sh 透過 colab run 送到 Colab 的 VM 上執行，不是在自己的電腦上跑
# 題目和 features/extract.sql 的 prompt_b 一字不差，後面多加一句請它只回 JSON（Gemini 那邊是用 output_schema 鎖的，這裡沒有）
# 圖片直接從公開的 GitHub 儲存庫下載，這支腳本不讀答案，結果印在標準輸出（每張圖一行 RESULT 開頭的 JSON）
# 目前只到「跑得動、量得到速度」這一步：回來的是模型的原文，還沒有接上對答案的流程，試跑成功之後再補
# 用法：python gemma_bench.py [模型 ID] [要跑幾張]     預設 google/gemma-4-E2B-it、24 張
import json, os, subprocess, sys, threading, time

MODEL = sys.argv[1] if len(sys.argv) > 1 else "google/gemma-4-E2B-it"
LIMIT = int(sys.argv[2]) if len(sys.argv) > 2 else 24
RAW = "https://raw.githubusercontent.com/gminc/ai-driven-martech-pipeline/main/creatives/images/"
IDS = [f"cr-{ch}-{camp}-{v}" for ch in ("line", "meta") for camp in ("aut", "evg", "trn") for v in ("p1", "p2", "r1", "r2")]

PROMPT_B = '''這是一張電商廣告圖，請看圖回答下面五個欄位：
has_person：圖中有沒有真人，true 或 false
cta_position：行動按鈕的位置，只能填 center、bottom_right、none 其中一個
dominant_color：整張圖的主色調，只能填 warm、cool、neutral 其中一個
text_density：圖上文字的多寡，只能填 low、high 其中一個
headline：圖上最大的一行標題文字，照原文抄
判斷標準：
cta_position 看有沒有寫著「立即選購」的深色按鈕，按鈕在畫面下方正中間填 center，在右下角填 bottom_right，沒有按鈕填 none
dominant_color 看背景和大面積的顏色，橘、磚紅、赤陶、奶茶這類填 warm，藍、灰藍、青這類填 cool，白、米白、亞麻、淺灰、黑這類填 neutral，商品本身的顏色不算
text_density 圖上只有一行標題（有沒有按鈕都不算）填 low，標題之外還有賣點文字或圓形標籤填 high
headline 只抄最大的那一行標題，不含賣點、標籤與按鈕上的字'''
SUFFIX = "\n只輸出一個 JSON 物件，鍵是 has_person、cta_position、dominant_color、text_density、headline，不要加任何說明"

DEADLINE = 1500   # 這支腳本在 VM 上最多跑幾秒，超過就自己結束，免得外面的電腦睡著或斷線時 VM 一直開著

# 兩條執行緒都會印東西，一次寫一整行並上鎖，RESULT 那幾行才不會被插進別的字
LOCK = threading.Lock()
def say(*a):
    with LOCK:
        sys.stdout.write(" ".join(str(x) for x in a) + "\n")
        sys.stdout.flush()

def give_up():
    say(f"⏰ 超過 {DEADLINE} 秒，腳本自己結束")
    os._exit(3)
killer = threading.Timer(DEADLINE, give_up)
killer.daemon = True
killer.start()

# colab run 的 --timeout 預設 30 秒（run_gemma_colab.sh 會設成 1,500 秒），它算的是總時間還是多久沒有輸出還沒確認過，
# 下載模型時可能好幾分鐘沒有輸出，所以每 15 秒印一行
ALIVE = True
def heartbeat():
    t0 = time.time()
    while ALIVE:
        time.sleep(15)
        if ALIVE:
            say(f"… 還在跑（{int(time.time() - t0)} 秒）")
threading.Thread(target=heartbeat, daemon=True).start()

T_START = time.time()
say("== GPU ==")
say(subprocess.run(["nvidia-smi", "--query-gpu=name,memory.total,memory.used", "--format=csv"],
                   capture_output=True, text=True).stdout.strip() or "找不到 nvidia-smi")

say("== 安裝套件 ==")
subprocess.run([sys.executable, "-m", "pip", "install", "-q", "-U", "transformers", "accelerate", "pillow"], check=True)

import torch
from transformers import AutoModelForImageTextToText, AutoProcessor
import transformers
say(f"transformers {transformers.__version__}｜torch {torch.__version__}｜cuda {torch.cuda.is_available()}")
if not torch.cuda.is_available():
    say("❌ 這台 VM 沒有 GPU，不跑了（在 CPU 上跑會一直耗運算單元）")
    sys.exit(2)

say(f"== 載入 {MODEL} ==")
t0 = time.time()
# T4 不支援 bf16，用 fp16
processor = AutoProcessor.from_pretrained(MODEL)
model = AutoModelForImageTextToText.from_pretrained(MODEL, device_map="auto", torch_dtype=torch.float16)
load_seconds = time.time() - t0
say(f"載入 {load_seconds:.1f} 秒｜GPU 記憶體 {torch.cuda.memory_allocated() / 2**30:.1f} GB")

say(f"== 開始看圖：{min(LIMIT, len(IDS))} 張 ==")
rows = []
for cid in IDS[:LIMIT]:
    messages = [{"role": "user", "content": [
        {"type": "image", "url": RAW + cid + ".jpg"},
        {"type": "text", "text": PROMPT_B + SUFFIX},
    ]}]
    row = {"creative_id": cid, "model": MODEL}
    try:
        inputs = processor.apply_chat_template(messages, tokenize=True, return_dict=True, return_tensors="pt",
                                               add_generation_prompt=True).to(model.device)
        n_in = inputs["input_ids"].shape[-1]
        t0 = time.time()
        with torch.inference_mode():
            out = model.generate(**inputs, max_new_tokens=256, do_sample=False)
        row["seconds"] = round(time.time() - t0, 2)
        row["prompt_tokens"] = int(n_in)
        row["output_tokens"] = int(out.shape[-1] - n_in)
        row["text"] = processor.decode(out[0][n_in:], skip_special_tokens=True)
        row["status"] = ""
    except Exception as e:  # 一張失敗不要讓整批停掉
        row["status"] = f"{type(e).__name__}: {e}"[:300]
    rows.append(row)
    say("RESULT\t" + json.dumps(row, ensure_ascii=False))

ALIVE = False
ok = [r for r in rows if r["status"] == ""]
summary = {
    "model": MODEL, "images": len(rows), "ok": len(ok),
    "load_seconds": round(load_seconds, 1),
    "generate_seconds": round(sum(r["seconds"] for r in ok), 1),
    "seconds_per_image": round(sum(r["seconds"] for r in ok) / len(ok), 2) if ok else None,
    "total_seconds": round(time.time() - T_START, 1),
    "peak_vram_gb": round(torch.cuda.max_memory_allocated() / 2**30, 2),
}
say("SUMMARY\t" + json.dumps(summary, ensure_ascii=False))
killer.cancel()
sys.exit(0 if ok else 1)
