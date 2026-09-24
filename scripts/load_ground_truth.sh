#!/usr/bin/env bash
# 把合成器植入的答案載進獨立資料集 martech_gt（Day 11、12 揭曉與 Day 13 驗收用）
# 用法：bash scripts/load_ground_truth.sh   （在儲存庫根目錄執行，需先跑過 Day 05 合成器，產生 synthesizer/out/ground_truth/）
#
# 為什麼要獨立資料集：分析與訓練只讀 martech_dw，答案只放在 martech_gt，
# 只有揭曉對照與驗收查詢會 JOIN 這裡，看 SQL 裡有沒有出現 martech_gt 就知道有沒有偷看答案
# 載入（bq load）不收費，兩張表合計不到 100 KB
set -euo pipefail
cd "$(dirname "$0")/.."

GT="${GT_DATASET:-martech_gt}"
SEG_CSV="synthesizer/out/ground_truth/customer_segments.csv"
SPEC_JSON="synthesizer/ground_truth.json"

[[ -f "${SEG_CSV}" ]] || { echo "❌ 找不到 ${SEG_CSV}，請先執行 Day 05 的合成器（固定種子重跑會得到同一份）"; exit 1; }

PROJECT="$(gcloud config get-value project 2>/dev/null || true)"
if ! bq --headless show --format=none "${PROJECT}:${GT}" >/dev/null 2>&1; then
  echo "📁 建立資料集 ${GT}（US）"
  bq --headless --location=US mk --dataset \
    --description "答案表：合成器植入的訊號與顧客類型，只給揭曉對照與驗收查詢使用，分析與訓練不得讀取" \
    --label purpose:ground_truth "${PROJECT}:${GT}" >/dev/null
fi

echo "👥 載入 ${GT}.gt_customer_segment"
bq --headless --location=US load --replace --source_format=CSV --skip_leading_rows=1 \
  "${GT}.gt_customer_segment" "${SEG_CSV}" customer_id:STRING,segment:STRING >/dev/null

echo "🧪 載入 ${GT}.gt_signals"
TMP="$(mktemp)"
trap 'rm -f "${TMP}"' EXIT
python3 - "${SPEC_JSON}" > "${TMP}" <<'PY'
import json, sys
spec = json.load(open(sys.argv[1], encoding="utf-8"))
for key, value in spec.items():
    if key.startswith("_"):
        continue
    signal_id = key.split("_", 1)[0]          # S1_cpc_spike → S1
    print(json.dumps({
        "signal_id": signal_id,
        "signal_key": key,
        "description": value.get("description", ""),
        "spec": json.dumps({k: v for k, v in value.items() if k != "description"}, ensure_ascii=False),
    }, ensure_ascii=False))
PY
bq --headless --location=US load --replace --source_format=NEWLINE_DELIMITED_JSON \
  "${GT}.gt_signals" "${TMP}" signal_id:STRING,signal_key:STRING,description:STRING,spec:JSON >/dev/null

bq --headless --location=US query --nouse_legacy_sql --format=pretty \
  "SELECT 'gt_customer_segment' AS table_name, COUNT(*) AS row_count FROM ${GT}.gt_customer_segment
   UNION ALL SELECT 'gt_signals', COUNT(*) FROM ${GT}.gt_signals"
