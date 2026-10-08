#!/usr/bin/env bash
# Day 25：單價表 → 兩個 view → 檢查 → 報表，全程不呼叫模型
# 用法：bash monitoring/run.sh   （在儲存庫根目錄執行，需先有 Day 16 起累積的共用用量表 ops_llm_usage）
# 查詢在每月 1 TiB 免費額度內，view 不存資料，單價表只有幾列，儲存在每月 10 GiB 免費額度內
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
bq --headless show --format=none "${PROJECT}:${DATASET}.ops_llm_usage" >/dev/null 2>&1 || {
  echo "❌ 找不到 ${DATASET}.ops_llm_usage，這張表從 Day 16 開始累積，至少要跑過 Day 16 之後任何一天的 run.sh"
  exit 1
}

TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

run_sql() {
  if ! sed -e "s/martech_dw\./${DATASET}./g" "$1" \
      | bq --headless --location=US query --nouse_legacy_sql --quiet "${@:2}" \
        > "${TMP}/out" 2> "${TMP}/err"; then
    echo "❌ $1 執行失敗" >&2
    tail -n 20 "${TMP}/out" "${TMP}/err" >&2
    exit 1
  fi
  cat "${TMP}/out"
}

echo "💲 單價對照表（price.sql）"
run_sql price.sql >/dev/null
echo "🪟 兩個 view（views.sql）"
run_sql views.sql >/dev/null

echo "🧾 檢查（check.sql）"
run_sql check.sql --format=csv --max_rows=100 > "${TMP}/check.csv"
python3 - "${TMP}/check.csv" <<'PYCHECK'
import csv, sys
rows = list(csv.DictReader(open(sys.argv[1])))
if not rows:
    sys.exit("❌ check.sql 沒有回傳任何一列")
bad = [r for r in rows if r["ok"] != "OK"]
for r in rows:
    print(f"  {'✅' if r['ok'] == 'OK' else '❌'} {r['check_name']}（預期 {r['expected']}，實際 {r['actual']}）")
print(f"{len(rows) - len(bad)} 項通過、{len(bad)} 項不通過")
open(sys.argv[1] + ".bad", "w").write(str(len(bad)))
PYCHECK
BAD="$(cat "${TMP}/check.csv.bad")"

echo "📊 報表（report.sql）"
for N in 1 2 3 4; do
  sed -n "/^-- ${N}\. /,/;/p" report.sql > "${TMP}/part.sql"
  head -n 1 "${TMP}/part.sql" | sed 's/^-- //'
  run_sql "${TMP}/part.sql" --format=pretty --max_rows=200
done
# 檢查沒過也先把報表印出來（第 4 段會列出對不到單價的呼叫），最後才回報失敗
if [[ "${BAD}" != "0" ]]; then
  echo "❌ 有 ${BAD} 項檢查不通過，報表的數字先不要用，照上面的項目修正後再跑一次"
  exit 1
fi
echo "✅ 完成，儀表板的資料來源請接 ${PROJECT}.${DATASET}.v_llm_usage_daily"
