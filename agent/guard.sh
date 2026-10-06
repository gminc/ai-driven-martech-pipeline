#!/usr/bin/env bash
# Day 23：護欄測試，同一批 12 個問題在沒有護欄和有護欄兩種情況各問一次
# 用法：bash agent/guard.sh          （建測試用的小表 → 草稿過濾 → 估價 → 輸入 yes → 25 題次 → 檢查 → 報表）
#       bash agent/guard.sh --dry    （只做不花錢的部分，到估價為止）
# 呼叫模型會產生 Token 費用，開始前會先印出最壞估價，輸入 yes 才會開始，已經成功的題次不會重問
set -euo pipefail

cd "$(dirname "$0")"
export DATASET="${DATASET:-martech_dw}"

ACTIVE="$(gcloud auth list --filter=status:ACTIVE --format='value(account)' 2>/dev/null || true)"
if [[ -z "${ACTIVE}" ]]; then
  echo "❌ gcloud 沒有 active account，請先 gcloud config set account <帳號>"
  exit 1
fi
PROJECT="$(gcloud config get-value project 2>/dev/null || true)"
if [[ -z "${PROJECT}" || "${PROJECT}" == "(unset)" ]]; then
  echo "❌ 尚未設定專案，請先 gcloud config set project <專案 ID>"
  exit 1
fi
export GOOGLE_CLOUD_PROJECT="${PROJECT}"
for T in "raw_customers:Day 06（bash synthesizer/bigquery/load.sh）" "fct_orders:Day 07（bash warehouse/build.sh）" \
         "fct_ad_daily:Day 07" "mart_attribution:Day 08（bash attribution/run.sh）" \
         "diag_summary:Day 09（bash diagnosis/run.sh）" "mart_diagnosis:Day 09" \
         "mart_creative_lift:Day 17（bash lift/run.sh）" "ref_claim_terms:Day 18（bash drafts/run.sh）" \
         "mart_creative_drafts:Day 18" "ops_llm_usage:Day 16（bash features/run.sh）"; do
  bq --headless show --format=none "${PROJECT}:${DATASET}.${T%%:*}" >/dev/null 2>&1 || {
    echo "❌ 找不到 ${DATASET}.${T%%:*}，請先完成 ${T#*:}"
    exit 1
  }
done
python3 -c "from google import genai; from google.cloud import bigquery" 2>/dev/null || {
  echo "❌ 缺少 Python 套件，請先 pip install --user google-genai google-cloud-bigquery"
  exit 1
}

run_sql() {
  sed -e "s/martech_dw\./${DATASET}./g" "$1" | bq --headless --location=US query --nouse_legacy_sql --quiet "${@:2}"
}

python3 guard.py
echo "── 建立測試用的小表（活動備註、Day 23 補的四個詞） ──"
run_sql guard_setup.sql
echo "── Day 18 的 12 份草稿過一次宣稱用語檢查（不呼叫模型） ──"
run_sql guard_drafts.sql

set +e
python3 guard_test.py "$@"
RC=$?
set -e
if [[ ${RC} -ne 0 ]]; then
  exit ${RC}
fi
if [[ " $* " == *" --dry "* ]]; then
  exit 0
fi
echo "── 檢查 ──"
run_sql guard_check.sql
echo "── 報表 ──"
run_sql guard_report.sql
