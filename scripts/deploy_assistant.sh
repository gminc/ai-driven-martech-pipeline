#!/usr/bin/env bash
# ==============================================================================
# 2026 iThome 鐵人賽 Day 26 - 把行銷助理部署成 Cloud Run 服務（只開給指定的 Google 帳號）
#
# 用法（在 Cloud Shell 專案根目錄）：
#   bash scripts/deploy_assistant.sh                                   # 只開給你自己（gcloud 目前登入的帳號）
#   INVOKERS=amy@example.com,bob@example.com bash scripts/deploy_assistant.sh   # 第一次部署就一起加同事，逗號分隔
#   DAILY_CAP_TWD=5 bash scripts/deploy_assistant.sh                   # 調整這個服務一天最多花新台幣幾元（預設 3）
#
# 每跑一次都會重新建置並換一個新版本，正在進行的對話會被重新開始
# 所以部署好之後要再加同事，用結尾印出來的那一行 gcloud 指令就好，不用重跑這支腳本
# 這支腳本只會加人不會減人，要移除某個帳號請用 gcloud run services remove-iam-policy-binding
#
# 這支腳本本身不呼叫模型，建置與部署都在免費額度內，部署好之後有人發問才會產生 Token 費用
# 需要 Day 25 之後的 Terraform 已經套用（映像檔存放區 martech、服務帳號 martech-assistant）
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
APP_DIR="${REPO_DIR}/agent"

SERVICE_NAME="martech-assistant"
# 和 Terraform 建的映像檔存放區同一個區域，us-central1 屬於 Cloud Run 第 1 級定價區域
REGION="${REGION:-us-central1}"
IMAGE_REPO="martech"
DATASET="${DATASET:-martech_dw}"
DAILY_CAP_TWD="${DAILY_CAP_TWD:-3}"

PROJECT_ID="$(gcloud config get-value project 2>/dev/null || true)"
if [[ -z "${PROJECT_ID}" || "${PROJECT_ID}" == "(unset)" ]]; then
  echo "❌ 尚未設定 gcloud 預設專案，請先執行: gcloud config set project YOUR_PROJECT_ID"
  exit 1
fi
ACTIVE="$(gcloud auth list --filter=status:ACTIVE --format='value(account)' 2>/dev/null || true)"
if [[ -z "${ACTIVE}" ]]; then
  echo "❌ gcloud 沒有 active account，請先 gcloud config set account <帳號>"
  exit 1
fi
if [[ ! "${DAILY_CAP_TWD}" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
  echo "❌ DAILY_CAP_TWD 要是數字（新台幣元），拿到「${DAILY_CAP_TWD}」"
  exit 1
fi
# 部署的人自己一定加進去，不然部署完連自己都連不上、也驗不了
INVOKERS="${ACTIVE}${INVOKERS:+,${INVOKERS}}"
IFS=',' read -r -a INVOKER_LIST <<< "${INVOKERS}"
for EMAIL in "${INVOKER_LIST[@]}"; do
  if [[ ! "${EMAIL}" =~ ^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$ ]]; then
    echo "❌ INVOKERS 裡的「${EMAIL}」不像 email，請用逗號分隔、不要有空白"
    exit 1
  fi
done

ASSISTANT_SA="martech-assistant@${PROJECT_ID}.iam.gserviceaccount.com"
PIPELINE_SA="martech-pipeline-runner@${PROJECT_ID}.iam.gserviceaccount.com"
IMAGE="${REGION}-docker.pkg.dev/${PROJECT_ID}/${IMAGE_REPO}/${SERVICE_NAME}"
echo "🔍 專案：${PROJECT_ID}｜區域：${REGION}｜服務：${SERVICE_NAME}｜每日上限：新台幣 ${DAILY_CAP_TWD} 元"
echo "   可以連的帳號：${INVOKERS}"

# ------------------------------------------------------------------------------
# 1. 事前檢查：缺什麼就停，不會做到一半
# ------------------------------------------------------------------------------
gcloud iam service-accounts describe "${ASSISTANT_SA}" --project "${PROJECT_ID}" >/dev/null 2>&1 || {
  echo "❌ 找不到服務帳號 ${ASSISTANT_SA}，請先套用 Terraform（bash scripts/quickstart.sh）"
  exit 1
}
gcloud artifacts repositories describe "${IMAGE_REPO}" --project "${PROJECT_ID}" --location "${REGION}" >/dev/null 2>&1 || {
  echo "❌ 找不到映像檔存放區 ${IMAGE_REPO}（${REGION}），請先套用 Terraform（bash scripts/quickstart.sh）"
  exit 1
}
for T in "fct_ad_daily:Day 07（bash warehouse/build.sh）" "fct_orders:Day 07" "raw_customers:Day 06（bash synthesizer/bigquery/load.sh）" \
         "mart_attribution:Day 08（bash attribution/run.sh）" "diag_summary:Day 09（bash diagnosis/run.sh）" "mart_diagnosis:Day 09" \
         "mart_creative_lift:Day 17（bash lift/run.sh）" "ref_claim_terms:Day 18（bash drafts/run.sh）" \
         "ref_claim_terms_d23:Day 23（bash agent/guard.sh --dry）" "ref_campaign_notes:Day 23" \
         "ops_llm_usage:Day 16（bash features/run.sh）" "ref_llm_price:Day 25（bash monitoring/run.sh）"; do
  bq --headless show --format=none "${PROJECT_ID}:${DATASET}.${T%%:*}" >/dev/null 2>&1 || {
    echo "❌ 找不到 ${DATASET}.${T%%:*}，請先完成 ${T#*:}"
    exit 1
  }
done

echo "── 不花錢的自我檢查 ──"
python3 "${APP_DIR}/guard.py"
if python3 -c "import flask; from google import genai; from google.cloud import bigquery" 2>/dev/null; then
  python3 "${APP_DIR}/serve_selftest.py"
else
  echo "⚠️ 這台機器沒有 flask 或 google-genai，略過 serve_selftest.py（映像檔裡會照 requirements.txt 安裝）"
fi

echo "── 建立問答紀錄表（已經有就不動） ──"
sed -e "s/martech_dw\./${DATASET}./g" "${APP_DIR}/serve_setup.sql" | bq --headless --location=US query --nouse_legacy_sql --quiet >/dev/null

# ------------------------------------------------------------------------------
# 2. 原始碼部署由 Cloud Build 以 Compute Engine 預設服務帳號建置，需要 Cloud Run Builder 角色（Day 04 給過就不會再給）
# ------------------------------------------------------------------------------
PROJECT_NUMBER="$(gcloud projects describe "${PROJECT_ID}" --format='value(projectNumber)')"
BUILD_SA="${PROJECT_NUMBER}-compute@developer.gserviceaccount.com"
EXISTING_ROLE="$(gcloud projects get-iam-policy "${PROJECT_ID}" \
  --flatten='bindings[].members' \
  --filter="bindings.role:roles/run.builder AND bindings.members:serviceAccount:${BUILD_SA}" \
  --format='value(bindings.role)' 2>/dev/null || true)"
if [[ "${EXISTING_ROLE}" != *"roles/run.builder"* ]]; then
  echo "🔑 授予 ${BUILD_SA} roles/run.builder"
  gcloud projects add-iam-policy-binding "${PROJECT_ID}" \
    --member="serviceAccount:${BUILD_SA}" --role="roles/run.builder" --condition=None --quiet >/dev/null
  echo "⏳ 等待 90 秒讓 IAM 權限生效..."
  sleep 90
fi

# ------------------------------------------------------------------------------
# 3. 建置並部署
#    --image 明確指到 Terraform 建的 martech 存放區（那裡有只留最新 2 版的清理規則），
#    不寫的話映像檔會進 cloud-run-source-deploy，那個存放區在這個區域沒有清理規則
#    --no-allow-unauthenticated：沒有 run.invoker 的請求在進到程式之前就被擋掉，也不計費
#    --max 1 與 --max-instances 1：對話紀錄與每日花費記在記憶體裡，所以整個服務、每個版本都只給一個執行個體
#      這不是絕對的保證：重新部署換版的那一小段時間、或流量突然變大時，Cloud Run 可能短暫同時有兩個，
#      那段時間兩邊各算各的額度，對話也可能被重新開始
#    --min-instances 0：沒人用就縮到 0，不收閒置費用，代價是隔一陣子的第一句要等冷啟動
#    --service-account：服務用 martech-assistant 的身分查資料與呼叫 Gemini，映像檔與環境變數裡都沒有金鑰
# ------------------------------------------------------------------------------
gcloud run deploy "${SERVICE_NAME}" \
  --source "${APP_DIR}" \
  --image "${IMAGE}" \
  --project "${PROJECT_ID}" \
  --region "${REGION}" \
  --no-allow-unauthenticated \
  --service-account "${ASSISTANT_SA}" \
  --min-instances 0 \
  --max 1 \
  --max-instances 1 \
  --concurrency 4 \
  --cpu 1 \
  --memory 512Mi \
  --timeout 300 \
  --set-env-vars "GOOGLE_CLOUD_PROJECT=${PROJECT_ID},DATASET=${DATASET},DAILY_CAP_TWD=${DAILY_CAP_TWD}" \
  --quiet

# ------------------------------------------------------------------------------
# 4. 誰可以連：一個一個加，重跑不會重複
#    martech-pipeline-runner 是 Day 27 排程用的身分，先綁好，不然明天排程來呼叫會收到 403
# ------------------------------------------------------------------------------
for EMAIL in "${INVOKER_LIST[@]}"; do
  gcloud run services add-iam-policy-binding "${SERVICE_NAME}" --project "${PROJECT_ID}" --region "${REGION}" \
    --member="user:${EMAIL}" --role="roles/run.invoker" --quiet >/dev/null
  echo "🔑 ${EMAIL} 可以連了"
done
if gcloud iam service-accounts describe "${PIPELINE_SA}" --project "${PROJECT_ID}" >/dev/null 2>&1; then
  gcloud run services add-iam-policy-binding "${SERVICE_NAME}" --project "${PROJECT_ID}" --region "${REGION}" \
    --member="serviceAccount:${PIPELINE_SA}" --role="roles/run.invoker" --quiet >/dev/null
  echo "🔑 ${PIPELINE_SA} 可以連了（Day 27 排程用）"
else
  echo "⚠️ 找不到 ${PIPELINE_SA}，Day 27 的排程要呼叫這個服務之前，記得替它補上 roles/run.invoker"
fi

# ------------------------------------------------------------------------------
# 5. 部署完自己驗一次：不能有任何「所有人」的綁定，不帶身分的請求一定要被擋
# ------------------------------------------------------------------------------
POLICY="$(gcloud run services get-iam-policy "${SERVICE_NAME}" --project "${PROJECT_ID}" --region "${REGION}" --format=json)"
if grep -q -E '"all(Authenticated)?Users"' <<< "${POLICY}"; then
  echo "❌ 這個服務被開放給所有人了（allUsers 或 allAuthenticatedUsers），請立刻移除："
  echo "   gcloud run services remove-iam-policy-binding ${SERVICE_NAME} --region ${REGION} --member=allUsers --role=roles/run.invoker"
  exit 1
fi
SERVICE_URL="$(gcloud run services describe "${SERVICE_NAME}" --project "${PROJECT_ID}" --region "${REGION}" --format=json \
  | python3 -c 'import json,sys
try:
    s = json.load(sys.stdin)
except Exception:
    sys.exit(0)
fallback = (s.get("status") or {}).get("url", "")
try:
    urls = json.loads((s.get("metadata") or {}).get("annotations", {}).get("run.googleapis.com/urls", "[]"))
except Exception:
    urls = []
print(next((u for u in urls if isinstance(u, str) and u.endswith(".a.run.app")), fallback))' || true)"
CODE="$(curl -s -o /dev/null -w '%{http_code}' --max-time 30 "${SERVICE_URL}/health" || true)"
if [[ "${CODE}" != "403" && "${CODE}" != "401" ]]; then
  echo "❌ 不帶身分連 ${SERVICE_URL}/health 拿到 ${CODE}，預期是 403，請檢查服務的驗證設定"
  exit 1
fi
echo "========================================================"
echo "✅ 行銷助理已上線：${SERVICE_URL}"
echo "   不帶身分的請求：HTTP ${CODE}（被 Cloud Run 擋下，沒有進到程式）"
echo "   目前可以連的身分（含以前加過的，不該在名單上的請移除）："
python3 -c 'import json,sys
for b in json.load(sys.stdin).get("bindings", []):
    if b.get("role") == "roles/run.invoker":
        for m in b.get("members", []):
            print("     -", m)' <<< "${POLICY}"
echo "   在瀏覽器使用：gcloud run services proxy ${SERVICE_NAME} --region ${REGION} --port 8080"
echo "                 然後開 http://localhost:8080（Cloud Shell 用右上角的網頁預覽，通訊埠 8080）"
echo "   實際問幾句：  python3 agent/serve_try.py（會先印估價，輸入 yes 才問）"
echo "   加一位同事：  gcloud run services add-iam-policy-binding ${SERVICE_NAME} --region ${REGION} --member=user:同事的帳號 --role=roles/run.invoker"
echo "   不用了：      gcloud run services delete ${SERVICE_NAME} --region ${REGION}"
echo "========================================================"
