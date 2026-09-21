#!/usr/bin/env bash
# Day 07：把 martech_dw 的五張 raw 表與 GA4 每日匯出表整理成星狀綱要，並做合併前後對帳
# 用法：bash warehouse/build.sh           （在儲存庫根目錄執行）
#       DATASET=martech_dw GA4_DATASET=analytics_xxx bash warehouse/build.sh
# DDL 不收費，INSERT 與對帳查詢依處理量計費，整段約 0.2 GB，在每月 1 TiB 免費額度內
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

for t in raw_creatives raw_ad_daily raw_events raw_orders raw_customers; do
  bq --headless show --format=none "${PROJECT}:${DATASET}.${t}" >/dev/null 2>&1 || {
    echo "❌ 找不到 ${DATASET}.${t}，請先完成 Day 06 的 load.sh"
    exit 1
  }
done

# GA4 匯出資料集名稱是 analytics_<資源 ID>，自動偵測，不寫進儲存庫
if [[ -z "${GA4_DATASET:-}" ]]; then
  GA4_DATASET="$(bq --headless ls --format=json --max_results=1000 "${PROJECT}:" \
    | python3 -c 'import sys,json;print("\n".join(d["datasetReference"]["datasetId"] for d in json.load(sys.stdin)))' \
    | grep '^analytics_' | head -n1 || true)"
fi
if [[ -z "${GA4_DATASET}" ]]; then
  echo "❌ 找不到 GA4 匯出資料集（analytics_*），請先完成 Day 04 的 BigQuery 連結"
  exit 1
fi
DAILY="$(bq --headless ls --format=json --max_results=1000 "${PROJECT}:${GA4_DATASET}" \
  | python3 -c 'import sys,json,re;print(sum(1 for t in json.load(sys.stdin) if re.fullmatch(r"events_\d{8}", t["tableReference"]["tableId"])))')"
if [[ "${DAILY}" == "0" ]]; then
  echo "❌ ${GA4_DATASET} 還沒有 events_YYYYMMDD 每日表，每日匯出通常隔天下午才會出現"
  exit 1
fi

# 兩個資料集必須在同一個位置，BigQuery 不能跨區域查詢
loc() { bq --headless show --format=json "${PROJECT}:$1" | python3 -c 'import sys,json;print(json.load(sys.stdin)["location"])'; }
LOCATION="$(loc "${DATASET}")"
GA4_LOCATION="$(loc "${GA4_DATASET}")"
if [[ "${LOCATION}" != "${GA4_LOCATION}" ]]; then
  echo "❌ ${DATASET} 在 ${LOCATION}、GA4 匯出資料集在 ${GA4_LOCATION}，位置不同無法合併"
  exit 1
fi
echo "🔍 資料集 ${DATASET}（${LOCATION}），GA4 每日表 ${DAILY} 張"

TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

run_sql() {
  # 結果寫到標準輸出，bq 的警告與錯誤另外收，避免混進 CSV；失敗時兩邊都印出來
  if ! sed "s/@@GA4_DATASET@@/${GA4_DATASET}/g" "$1" \
      | bq --headless --location="${LOCATION}" query --nouse_legacy_sql --quiet "${@:2}" \
        > "${TMP}/out" 2> "${TMP}/err"; then
    echo "❌ $1 執行失敗" >&2
    tail -n 20 "${TMP}/out" "${TMP}/err" >&2
    exit 1
  fi
  cat "${TMP}/out"
}

echo "🧱 建立星狀綱要（ddl.sql）"
run_sql ddl.sql >/dev/null
echo "🔄 轉換與合併（build.sql）"
run_sql build.sql >/dev/null

echo "🧾 合併前後對帳（check.sql）"
REPORT="${TMP}/report.csv"
run_sql check.sql --format=csv --max_rows=1000 > "${REPORT}"
python3 - "${REPORT}" <<'PYREPORT'
import csv, sys
rows = list(csv.DictReader(open(sys.argv[1], encoding="utf-8")))
for r in rows:
    flag = {"OK": "✅", "INFO": "ℹ️ "}.get(r["ok"], "❌")
    print(f"  {flag} {r['check_name']:<44} {r['before']:>18}  {r['after']:>18}")
bad = sum(r["ok"] == "DIFF" for r in rows)
ok = sum(r["ok"] == "OK" for r in rows)
print(f"\n{ok} 項一致、{bad} 項不一致（另有 {len(rows) - ok - bad} 項僅供參考）")
sys.exit(1 if bad or not rows else 0)
PYREPORT
