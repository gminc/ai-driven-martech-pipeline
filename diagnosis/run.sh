#!/usr/bin/env bash
# Day 09：算出異常摘要 → 數 Token 估費用 → 確認後才呼叫 Gemini → 檢查回答 → 印報表
# 用法：bash diagnosis/run.sh             （在儲存庫根目錄執行，需先完成 Day 07 warehouse/build.sh）
#       AUTO_YES=1 bash diagnosis/run.sh  （跳過確認，排程用）
# 會呼叫 Gemini 8 次（4 列 × 2 個模型），實測約 US$0.005；BigQuery 處理量約 30 MB，在每月 1 TiB 免費額度內
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
for t in fct_ad_daily fct_events fct_orders; do
  bq --headless show --format=none "${PROJECT}:${DATASET}.${t}" >/dev/null 2>&1 || {
    echo "❌ 找不到 ${DATASET}.${t}，請先完成 Day 07 的 warehouse/build.sh"
    exit 1
  }
done
bq --headless show --format=none --connection "${PROJECT}.us.vertex_ai_conn" >/dev/null 2>&1 || {
  echo "❌ 找不到連線 us.vertex_ai_conn，請先完成 Day 03 的 Terraform"
  exit 1
}

TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

run_sql() {
  if ! sed "s/martech_dw\./${DATASET}./g" "$1" \
      | bq --headless --location=US query --nouse_legacy_sql --quiet "${@:2}" \
        > "${TMP}/out" 2> "${TMP}/err"; then
    echo "❌ $1 執行失敗" >&2
    tail -n 20 "${TMP}/out" "${TMP}/err" >&2
    exit 1
  fi
  cat "${TMP}/out"
}

echo "🔎 算出異常摘要（summary.sql）"
run_sql summary.sql > /dev/null
echo "📝 把異常寫成題目（prompt.sql）"
run_sql prompt.sql > /dev/null

echo "💰 呼叫前先數 Token（cost.sql，兩個模型各一輪的最壞情況）"
run_sql cost.sql --format=pretty

if [[ "${AUTO_YES:-0}" != "1" ]]; then
  read -r -p "要呼叫 Gemini 嗎？會跑 flash-lite 與 3.6-flash 各一輪，輸入 yes 繼續：" ANSWER || ANSWER=""
  [[ "${ANSWER}" == "yes" ]] || { echo "已取消，沒有呼叫 Gemini"; exit 0; }
fi

echo "🤖 呼叫 Gemini（diagnose.sql）"
run_sql diagnose.sql > /dev/null

echo "🧾 檢查回答（check.sql）"
run_sql check.sql --format=csv --max_rows=100 > "${TMP}/check.csv"
python3 - "${TMP}/check.csv" <<'PYCHECK'
import csv, sys
rows = list(csv.DictReader(open(sys.argv[1], encoding="utf-8")))
for r in rows:
    flag = "✅" if r["ok"] == "OK" else "❌"
    print(f"  {flag} {r['check_name']:<40} {r['expected']:>6}  {r['actual']:>6}")
bad = sum(r["ok"] != "OK" for r in rows)
print(f"\n{len(rows) - bad} 項通過、{bad} 項不通過")
sys.exit(1 if bad or not rows else 0)
PYCHECK

echo "📊 診斷結果（report.sql）"
python3 - report.sql "${TMP}" <<'PYSPLIT'
import re, sys
text = open(sys.argv[1], encoding="utf-8").read()
parts = [p.strip() for p in re.split(r";\s*\n", text) if re.search(r"(?im)^\s*SELECT", p)]
for i, p in enumerate(parts, 1):
    open(f"{sys.argv[2]}/report_{i}.sql", "w", encoding="utf-8").write(p + "\n")
PYSPLIT
for f in "${TMP}"/report_*.sql; do
  head -n 1 "${f}"
  run_sql "${f}" --format=pretty --max_rows=100
  echo
done
