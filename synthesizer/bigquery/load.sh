#!/usr/bin/env bash
# Day 06：產生 90 天合成資料，本機驗證通過後用批次載入工作灌進 BigQuery 的五張 raw 表
# 用法：bash bigquery/load.sh            （在 synthesizer/ 目錄執行）
#       OUT=./out DATASET=martech_dw bash bigquery/load.sh
# 批次載入不收費，同一個種子每次產生的資料完全相同，--replace 讓重跑結果一致
set -euo pipefail

cd "$(dirname "$0")/.."
DATASET="${DATASET:-martech_dw}"
OUT="${OUT:-./out}"
LOCATION="${LOCATION:-US}"
TABLES=(raw_creatives raw_ad_daily raw_events raw_orders raw_customers)

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
echo "🔍 專案 ${PROJECT}／資料集 ${DATASET}（${LOCATION}）"

bq --headless show --format=none "${PROJECT}:${DATASET}" >/dev/null 2>&1 || {
  echo "❌ 找不到資料集 ${DATASET}，請先完成 Day 03 的 terraform apply"
  exit 1
}

if [[ ! -f "${OUT}/raw_events.csv" ]]; then
  echo "📦 產生 90 天合成資料到 ${OUT}"
  python3 synthetic_pipeline.py --out "${OUT}" >/dev/null
fi

echo "🧪 本機驗證（validate.py）"
if ! python3 validate.py "${OUT}" > "${OUT}/validate_local.txt"; then
  grep -E '^FAIL' "${OUT}/validate_local.txt" || true
  echo "❌ 本機驗證沒有通過，不載入"
  exit 1
fi
echo "   $(grep -c '^PASS' "${OUT}/validate_local.txt") 項 PASS"

echo "🧾 核對 CSV 標題與綱要欄位順序（依位置載入，順序錯了不會報錯）"
for t in "${TABLES[@]}"; do
  python3 - "${OUT}/${t}.csv" "bigquery/schemas/${t}.json" <<'PYCHECK'
import csv, json, sys
head = next(csv.reader(open(sys.argv[1], encoding="utf-8", newline="")))
cols = [c["name"] for c in json.load(open(sys.argv[2], encoding="utf-8"))]
if head != cols:
    sys.exit(f"❌ {sys.argv[1]} 標題與綱要不一致\n  CSV    {head}\n  schema {cols}")
PYCHECK
done

for t in "${TABLES[@]}"; do
  echo "⬆️  載入 ${t}（$(du -h "${OUT}/${t}.csv" | cut -f1)）"
  bq --headless --location="${LOCATION}" load --quiet --replace \
    --source_format=CSV --skip_leading_rows=1 --encoding=UTF-8 \
    --max_bad_records=0 \
    "${PROJECT}:${DATASET}.${t}" "${OUT}/${t}.csv" "bigquery/schemas/${t}.json"
done

echo ""
echo "📊 各表列數（CSV 列數不含標題）"
rc=0
for t in "${TABLES[@]}"; do
  csv_rows=$(( $(wc -l < "${OUT}/${t}.csv") - 1 ))
  bq_rows="$(bq --headless show --format=json "${PROJECT}:${DATASET}.${t}" \
    | python3 -c 'import sys,json;print(json.load(sys.stdin)["numRows"])')"
  flag="✅"; [[ "${csv_rows}" == "${bq_rows}" ]] || { flag="❌"; rc=1; }
  printf '  %s %-14s CSV %8s  BigQuery %8s\n' "${flag}" "${t}" "${csv_rows}" "${bq_rows}"
done
echo ""
if [[ "${rc}" != 0 ]]; then
  echo "❌ 列數對不上，請檢查載入工作"
  exit 1
fi
echo "下一步：python3 bigquery/reconcile.py ${OUT}"
