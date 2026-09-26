#!/usr/bin/env bash
# Day 12：首購特徵 →（確認）→ 建線性迴歸 → 評估與基準線 → 預測落表 → 檢查 → 通路／活動價值 → 揭曉
# 用法：bash ltv/run.sh               （在儲存庫根目錄執行，需先完成 Day 07 與 Day 05 合成器）
#       bash ltv/run.sh --unseen      （另外建「活動代號也當特徵」的對照模型，示範沒看過的類別，約多新台幣 0.1 元）
#       AUTO_YES=1 bash ltv/run.sh    （跳過確認，排程用）
# CREATE MODEL 沒有免費額度，每個模型照最低 10 MB 計費，約新台幣 0.1 元；其他查詢在每月 1 TiB 免費額度內
set -euo pipefail

cd "$(dirname "$0")"
DATASET="${DATASET:-martech_dw}"
GT="${GT_DATASET:-martech_gt}"
UNSEEN=0
[[ "${1:-}" == "--unseen" ]] && UNSEEN=1

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
for T in fct_orders fct_ad_daily; do
  bq --headless show --format=none "${PROJECT}:${DATASET}.${T}" >/dev/null 2>&1 || {
    echo "❌ 找不到 ${DATASET}.${T}，請先完成 Day 07"
    exit 1
  }
done
if ! bq --headless show --format=none "${PROJECT}:${GT}.gt_customer_segment" >/dev/null 2>&1; then
  echo "📥 找不到答案表，先載入（scripts/load_ground_truth.sh）"
  GT_DATASET="${GT}" bash ../scripts/load_ground_truth.sh
fi

TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

run_sql() {
  if ! sed -e "s/martech_dw\./${DATASET}./g" -e "s/martech_gt\./${GT}./g" "$1" \
      | bq --headless --location=US query --nouse_legacy_sql --quiet "${@:2}" \
        > "${TMP}/out" 2> "${TMP}/err"; then
    echo "❌ $1 執行失敗" >&2
    tail -n 20 "${TMP}/out" "${TMP}/err" >&2
    exit 1
  fi
  cat "${TMP}/out"
}

echo "🧮 整理首購特徵與 30 天回購營收（features.sql）"
run_sql features.sql --format=pretty

MODELS=1
[[ "${UNSEEN}" == "1" ]] && MODELS=2
echo "💰 將建立 ${MODELS} 個線性迴歸模型，每個照最低 10 MB 計費，約新台幣 $(python3 -c "print(f'{${MODELS}*0.1:.1f}')") 元"
if [[ "${AUTO_YES:-0}" != "1" ]]; then
  read -r -p "要建立模型嗎？輸入 yes 繼續：" ANSWER || ANSWER=""
  [[ "${ANSWER}" == "yes" ]] || { echo "已取消，沒有建立模型"; exit 0; }
fi

echo "🤖 建立模型 ltv_linreg（model.sql，一分鐘上下，大多在排隊）"
run_sql model.sql > /dev/null
echo "📐 模型評估（evaluate.sql，驗證集 275 人）"
run_sql evaluate.sql --format=pretty
echo "📏 和兩條基準線比較（baseline.sql）"
run_sql baseline.sql --format=pretty
echo "🔮 預測並落表 mart_customer_ltv（predict.sql）"
run_sql predict.sql > /dev/null

echo "🧾 檢查結果（check.sql）"
run_sql check.sql --format=csv --max_rows=100 > "${TMP}/check.csv"
# 另外確認只有揭曉與檢查的 SQL 讀答案表：特徵、模型、預測、價值表都不能出現 martech_gt
LEAK=""
for F in features.sql model.sql model_campaign.sql evaluate.sql baseline.sql predict.sql value.sql unseen.sql; do
  # 註解裡提到 martech_gt 不算，只看真正執行的 SQL
  if grep -v '^[[:space:]]*--' "${F}" | grep -q 'martech_gt'; then LEAK="${LEAK}${F} "; fi
done
python3 - "${TMP}/check.csv" "${LEAK}" <<'PYCHECK'
import csv, sys
rows = list(csv.DictReader(open(sys.argv[1], encoding="utf-8")))
leak = sys.argv[2].strip()
rows.append({"check_name": "10 no answer table in features/model", "expected": "none",
             "actual": leak or "none", "ok": "DIFF" if leak else "OK"})
for r in rows:
    flag = "✅" if r["ok"] == "OK" else "❌"
    print(f"  {flag} {r['check_name']:<38} {r['expected']:>7}  {r['actual']:>7}")
bad = sum(r["ok"] != "OK" for r in rows)
print(f"\n{len(rows) - bad} 項通過、{bad} 項不通過")
if len(rows) != 10:
    print(f"❌ 檢查項目應該有 10 項，實際只有 {len(rows)} 項")
sys.exit(1 if bad or len(rows) != 10 else 0)
PYCHECK

echo "💹 每位新客的預期 30 天價值 ÷ 取得成本（value.sql，8/18–9/16）"
run_sql value.sql --format=pretty --max_rows=100

echo "🔓 揭曉（reveal.sql，預測值 × 答案表）"
run_sql reveal.sql --format=pretty --max_rows=100

if [[ "${UNSEEN}" == "1" ]]; then
  echo "🤖 建立對照模型 ltv_linreg_campaign（model_campaign.sql，活動代號也當特徵）"
  run_sql model_campaign.sql > /dev/null
  echo "🧪 沒看過的活動會怎樣（unseen.sql）"
  run_sql unseen.sql --format=pretty --max_rows=100
fi
