#!/usr/bin/env bash
# Day 15：設計規格搬進答案表 → 挑六張樣本圖 →（確認費用）→ Gemini 看圖交出固定欄位 → 檢查 → 報表
# 用法：bash structured/run.sh            （在儲存庫根目錄執行，需先完成 Day 14 的物件表）
#       AUTO_YES=1 bash structured/run.sh （跳過確認，排程用）
# 搬家與查詢在每月 1 TiB 免費額度內，看圖 30 次會產生 Token 費用，呼叫前會先印出最壞情況
set -euo pipefail

cd "$(dirname "$0")"
DATASET="${DATASET:-martech_dw}"
GT_DATASET="${GT_DATASET:-martech_gt}"

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
for T in raw_creatives dim_creative obj_creatives; do
  bq --headless show --format=none "${PROJECT}:${DATASET}.${T}" >/dev/null 2>&1 || {
    echo "❌ 找不到 ${DATASET}.${T}，請先完成 Day 07 與 Day 14"
    exit 1
  }
done
bq --headless show --format=none "${PROJECT}:${GT_DATASET}" >/dev/null 2>&1 || {
  echo "❌ 找不到答案資料集 ${GT_DATASET}，請先完成 Day 13"
  exit 1
}

TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

run_sql() {
  if ! sed -e "s/martech_dw\./${DATASET}./g" -e "s/martech_gt\./${GT_DATASET}./g" "$1" \
      | bq --headless --location=US query --nouse_legacy_sql --quiet "${@:2}" \
        > "${TMP}/out" 2> "${TMP}/err"; then
    echo "❌ $1 執行失敗" >&2
    tail -n 20 "${TMP}/out" "${TMP}/err" >&2
    exit 1
  fi
  cat "${TMP}/out"
}

echo "📦 設計規格搬進答案表、dim_creative 拿掉四欄（move_design.sql）"
run_sql move_design.sql --format=pretty

echo "🖼️  挑六張樣本圖（sample.sql）"
run_sql sample.sql --format=pretty

# 最壞情況：30 次呼叫，每次輸入以 IMAGE_TOKENS_MAX 計（一張圖 1,104 個 Token、題目與判斷標準約 300、response_schema 約 150，取 1,600 當上限）
# 輸出以 max_output_tokens 256 計，單價用非 global 端點（endpoint 只寫模型名稱時 BigQuery 送到非 global，比 global 高一成）
IMAGE_TOKENS_MAX="${IMAGE_TOKENS_MAX:-1600}"
python3 - "${IMAGE_TOKENS_MAX}" <<'PYCOST'
import sys
tin, tout, fx = int(sys.argv[1]), 256, 32
lite = 24 * (tin * 0.33 + tout * 2.75) / 1e6
flash = 6 * (tin * 0.825 + tout * 4.125) / 1e6
print(f"💰 將呼叫 Gemini 30 次（3.5-flash-lite 24 次、3.6-flash 6 次）")
print(f"   最壞情況約 US$ {lite + flash:.4f} ≈ 新台幣 {(lite + flash) * fx:.2f} 元（每次輸入 {tin:,}、輸出 {tout:,} Token 計）")
PYCOST
if [[ "${AUTO_YES:-0}" != "1" ]]; then
  read -r -p "要呼叫 Gemini 看圖嗎？輸入 yes 繼續：" ANSWER || ANSWER=""
  [[ "${ANSWER}" == "yes" ]] || { echo "已取消，沒有呼叫 Gemini"; exit 0; }
fi

echo "👀 Gemini 看圖交出固定欄位（extract.sql）"
run_sql extract.sql --format=pretty

echo "🧾 檢查（check.sql ＋ 一項腳本檢查）"
run_sql check.sql --format=csv --max_rows=100 > "${TMP}/check.csv"
LEAK="$(grep -lE 'martech_gt|gt_creative_design' sample.sql extract.sql 2>/dev/null | tr '\n' ' ' || true)"
python3 - "${TMP}/check.csv" "${LEAK}" <<'PYCHECK'
import csv, sys
rows = list(csv.DictReader(open(sys.argv[1])))
leak = sys.argv[2].strip()
rows.append({"check_name": "11 no answer table in extract SQL", "expected": "none",
             "actual": leak or "none", "ok": "OK" if not leak else "DIFF"})
bad = 0
for r in rows:
    flag = "✅" if r["ok"] == "OK" else "❌"
    bad += r["ok"] != "OK"
    print(f"  {flag} {r['check_name']:<40} {r['expected']:>7}  {r['actual']:>7}")
print(f"\n{len(rows) - bad} 項通過、{bad} 項不通過")
sys.exit(1 if bad else 0)
PYCHECK

echo "📊 報表（report.sql，第 3、4 段對答案）"
run_sql report.sql --format=pretty --max_rows=100

echo "✅ Day 15 完成：抽取結果在 ${DATASET}.mm_structured，答案表在 ${GT_DATASET}.gt_creative_design"
