#!/usr/bin/env bash
# Day 14：物件表 →（確認）→ 挑三張示範圖 →（確認費用）→ Gemini 看圖自由描述 → 檢查 → 報表
# 用法：bash multimodal/run.sh            （在儲存庫根目錄執行，需先完成 Day 07 與 Terraform 的素材 bucket）
#       AUTO_YES=1 bash multimodal/run.sh （跳過確認，排程用）
# 物件表與查詢在每月 1 TiB 免費額度內，看圖 12 次會產生 Token 費用，呼叫前會先印出最壞情況
set -euo pipefail

cd "$(dirname "$0")"
DATASET="${DATASET:-martech_dw}"

ACTIVE="$(gcloud auth list --filter=status:ACTIVE --format='value(account)' 2>/dev/null || true)"
if [[ -z "${ACTIVE}" ]]; then
  echo "❌ gcloud 沒有 active account，bq 會安靜地回傳空結果，請先 gcloud config set account <帳號>"
  exit 1
fi
PROJECT="$(gcloud config get-value project 2>/dev/null || true)"
if [[ -z "${PROJECT}" || "${PROJECT}" == "(unset)" ]]; then
  echo "❌ 尚未設定專案，請先 gcloud config set project <專案 ID>"
  exit 1
fi
for T in fct_ad_daily dim_creative; do
  bq --headless show --format=none "${PROJECT}:${DATASET}.${T}" >/dev/null 2>&1 || {
    echo "❌ 找不到 ${DATASET}.${T}，請先完成 Day 07"
    exit 1
  }
done
BUCKET="gs://${PROJECT}-martech-assets/creatives"
IMAGES="$(gcloud storage ls "${BUCKET}/*.jpg" 2>/dev/null | wc -l | tr -d ' ')"
if [[ "${IMAGES}" != "24" ]]; then
  echo "❌ ${BUCKET} 應該有 24 張 jpg，現在是 ${IMAGES} 張，請先用 terraform 建 bucket，再上傳 creatives/images/*.jpg"
  exit 1
fi

# 2026-09-29 起 report.sql 第 4 段讀答案表 martech_gt.gt_creative_design（Day 15 搬家），沒有這張表就在呼叫 Gemini 之前先停下來
if ! bq --headless show --format=none "${PROJECT}:martech_gt.gt_creative_design" >/dev/null 2>&1; then
  echo "❌ 找不到答案表 martech_gt.gt_creative_design，請先執行 Day 15 的搬家（免費、不呼叫 Gemini）："
  echo "   bq query --nouse_legacy_sql < structured/move_design.sql"
  exit 1
fi

TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

run_sql() {
  if ! sed -e "s/martech_dw\./${DATASET}./g" -e "s/PROJECT_ID/${PROJECT}/g" "$1" \
      | bq --headless --location=US query --nouse_legacy_sql --quiet "${@:2}" \
        > "${TMP}/out" 2> "${TMP}/err"; then
    echo "❌ $1 執行失敗" >&2
    tail -n 20 "${TMP}/out" "${TMP}/err" >&2
    exit 1
  fi
  cat "${TMP}/out"
}

if bq --headless show --format=none "${PROJECT}:${DATASET}.obj_creatives" >/dev/null 2>&1; then
  echo "🗂️  物件表 ${DATASET}.obj_creatives 已存在，沿用（只查中繼資料，不重建）"
  sed -n '/^SELECT/,$p' object_table.sql > "${TMP}/object_count.sql"
  run_sql "${TMP}/object_count.sql" --format=pretty
else
  echo "🗂️  建立物件表（object_table.sql）"
  run_sql object_table.sql --format=pretty
fi

echo "🖼️  挑三張示範圖（demo.sql）"
run_sql demo.sql --format=pretty

# 最壞情況：12 次呼叫，每次輸入以 IMAGE_TOKENS_MAX（一張圖加一句題目的上限）計、輸出以 max_output_tokens 1,024 計
# 9/27 實測 1200×628 的圖：預設解析度 1,104 個圖片 Token、低解析度 276 個，加上題目取 1,200 當上限
# 單價用非 global 端點（endpoint 只寫模型名稱時 BigQuery 送到非 global，比 global 高一成）
IMAGE_TOKENS_MAX="${IMAGE_TOKENS_MAX:-1200}"
python3 - "${IMAGE_TOKENS_MAX}" <<'PYCOST'
import sys
tin, tout, fx = int(sys.argv[1]), 1024, 32
lite = 9 * (tin * 0.33 + tout * 2.75) / 1e6
flash = 3 * (tin * 0.825 + tout * 4.125) / 1e6
print(f"💰 將呼叫 Gemini 12 次（3.5-flash-lite 9 次、3.6-flash 3 次）")
print(f"   最壞情況約 US$ {lite + flash:.4f} ≈ 新台幣 {(lite + flash) * fx:.2f} 元（每次輸入 {tin:,}、輸出 {tout:,} Token 計）")
PYCOST
if [[ "${AUTO_YES:-0}" != "1" ]]; then
  read -r -p "要呼叫 Gemini 看圖嗎？輸入 yes 繼續：" ANSWER || ANSWER=""
  [[ "${ANSWER}" == "yes" ]] || { echo "已取消，沒有呼叫 Gemini"; exit 0; }
fi

echo "👀 Gemini 看圖自由描述（describe.sql）"
run_sql describe.sql --format=pretty

echo "🧾 檢查（check.sql ＋ 一項腳本檢查）"
run_sql check.sql --format=csv --max_rows=100 > "${TMP}/check.csv"
LEAK="$(grep -l 'martech_gt' object_table.sql demo.sql describe.sql 2>/dev/null | tr '\n' ' ' || true)"
python3 - "${TMP}/check.csv" "${LEAK}" <<'PYCHECK'
import csv, sys
rows = list(csv.DictReader(open(sys.argv[1])))
leak = sys.argv[2].strip()
rows.append({"check_name": "11 no answer table in describe SQL", "expected": "none",
             "actual": leak or "none", "ok": "OK" if not leak else "DIFF"})
bad = 0
for r in rows:
    flag = "✅" if r["ok"] == "OK" else "❌"
    bad += r["ok"] != "OK"
    print(f"  {flag} {r['check_name']:<36} {r['expected']:>7}  {r['actual']:>7}")
print(f"\n{len(rows) - bad} 項通過、{bad} 項不通過")
sys.exit(1 if bad else 0)
PYCHECK

echo "📊 報表（report.sql，第 4 段讀答案表）"
run_sql report.sql --format=pretty --max_rows=100

echo "✅ Day 14 完成：描述在 ${DATASET}.mm_describe"
