#!/usr/bin/env bash
# Day 22：可以連續對話的行銷助理
# 用法：bash agent/chat.sh           （照固定的五句話問一輪）
#       bash agent/chat.sh --talk    （自己打字聊，輸入空白行結束）
# 呼叫模型會產生 Token 費用，開始前會先印出最壞估價，輸入 yes 才會開始
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
for T in "fct_ad_daily:Day 07（bash warehouse/build.sh）" "mart_attribution:Day 08（bash attribution/run.sh）" \
         "diag_summary:Day 09（bash diagnosis/run.sh）" "mart_diagnosis:Day 09" \
         "mart_creative_lift:Day 17（bash lift/run.sh）" "ops_llm_usage:Day 16（bash features/run.sh）"; do
  bq --headless show --format=none "${PROJECT}:${DATASET}.${T%%:*}" >/dev/null 2>&1 || {
    echo "❌ 找不到 ${DATASET}.${T%%:*}，請先完成 ${T#*:}"
    exit 1
  }
done
python3 -c "from google import genai; from google.cloud import bigquery" 2>/dev/null || {
  echo "❌ 缺少 Python 套件，請先 pip install --user google-genai google-cloud-bigquery"
  exit 1
}

python3 chat.py "$@"
