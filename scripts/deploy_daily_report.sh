#!/usr/bin/env bash
# ==============================================================================
# 2026 iThome 鐵人賽 Day 27 - 部署行銷日報流程（Cloud Workflows）與每天早上的排程（Cloud Scheduler）
#
# 用法（在 Cloud Shell 專案根目錄）：
#   bash scripts/deploy_daily_report.sh                 # 部署流程，第一次建排程時先暫停（不會自己花錢），排程已經存在就維持它原本的狀態
#   SCHEDULE_STATE=on bash scripts/deploy_daily_report.sh       # 排程啟用，之後每天早上自己跑
#   SCHEDULE_STATE=paused bash scripts/deploy_daily_report.sh   # 排程暫停
#   SCHEDULE="0 9 * * 1-5" bash scripts/deploy_daily_report.sh   # 改排程時間（預設每天 08:30，時區見 TIME_ZONE）
#
# 這支腳本本身不啟動流程、不呼叫模型，Workflows 與 Cloud Scheduler 都在免費額度內
# 流程每跑一次會向助理問三題，約新台幣 0.5 到 0.9 元，要實際跑請用 bash workflows/run.sh（會先印估價）
# 需要：Day 25 之後的 Terraform 已經套用（服務帳號 martech-scheduler、Workflows 與 Cloud Scheduler 的 API），
#       Day 26 的助理服務已經部署（bash scripts/deploy_assistant.sh）
# 重跑是安全的：流程會換成新的版本，排程已經存在就更新設定，沒有指定 SCHEDULE_STATE 時不會改動它是啟用還是暫停
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
FLOW_DIR="${REPO_DIR}/workflows"

WORKFLOW="martech-daily-report"
JOB="martech-daily-report-morning"
SERVICE_NAME="martech-assistant"
REGION="${REGION:-us-central1}"
DATASET="${DATASET:-martech_dw}"
SCHEDULE="${SCHEDULE:-30 8 * * *}"
TIME_ZONE="${TIME_ZONE:-Asia/Taipei}"
SCHEDULE_STATE="${SCHEDULE_STATE:-}"

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
if [[ ! "${DATASET}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
  echo "❌ DATASET 只能是英數字與底線，拿到「${DATASET}」"
  exit 1
fi
if [[ -n "${SCHEDULE_STATE}" && "${SCHEDULE_STATE}" != "paused" && "${SCHEDULE_STATE}" != "on" ]]; then
  echo "❌ SCHEDULE_STATE 只能是 paused 或 on（不寫就維持現況），拿到「${SCHEDULE_STATE}」"
  exit 1
fi
if [[ ! "${SCHEDULE}" =~ ^[0-9*/,-]+( [0-9*/,-]+){4}$ ]]; then
  echo "❌ SCHEDULE 要是五個欄位的 cron 寫法而且只用數字，例如 \"30 8 * * *\" 或 \"0 9 * * 1-5\"，拿到「${SCHEDULE}」"
  exit 1
fi

PIPELINE_SA="martech-pipeline-runner@${PROJECT_ID}.iam.gserviceaccount.com"
SCHEDULER_SA="martech-scheduler@${PROJECT_ID}.iam.gserviceaccount.com"
echo "🔍 專案：${PROJECT_ID}｜區域：${REGION}｜流程：${WORKFLOW}｜排程：${SCHEDULE}（${TIME_ZONE}）"

# ------------------------------------------------------------------------------
# 1. 事前檢查：缺什麼就停，不會做到一半
# ------------------------------------------------------------------------------
for SA in "${PIPELINE_SA}" "${SCHEDULER_SA}"; do
  gcloud iam service-accounts describe "${SA}" --project "${PROJECT_ID}" >/dev/null 2>&1 || {
    echo "❌ 找不到服務帳號 ${SA}，請先套用 Terraform（bash scripts/quickstart.sh）"
    exit 1
  }
done
# workflowexecutions 是「啟動流程」用的 API，Terraform 沒有單獨列它，所以沒啟用時直接給指令
for API in workflows.googleapis.com workflowexecutions.googleapis.com cloudscheduler.googleapis.com; do
  if [[ -z "$(gcloud services list --enabled --project "${PROJECT_ID}" --filter="config.name=${API}" --format='value(config.name)' 2>/dev/null)" ]]; then
    echo "❌ ${API} 還沒啟用，請先執行（啟用 API 不收費）："
    echo "   gcloud services enable ${API} --project ${PROJECT_ID}"
    exit 1
  fi
done
bq --headless show --format=none "${PROJECT_ID}:${DATASET}.serve_turns" >/dev/null 2>&1 || {
  echo "❌ 找不到 ${DATASET}.serve_turns，請先完成 Day 26（bash scripts/deploy_assistant.sh）"
  exit 1
}
# 助理的網址取 a.run.app 那一個（和 Day 26 的部署腳本相同），結尾不帶斜線，流程的身分權杖就是簽給這個網址
SERVICE_URL="$(gcloud run services describe "${SERVICE_NAME}" --project "${PROJECT_ID}" --region "${REGION}" --format=json 2>/dev/null \
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
print(next((u for u in urls if isinstance(u, str) and u.endswith(".a.run.app")), fallback).rstrip("/"))' || true)"
if [[ ! "${SERVICE_URL}" =~ ^https://[a-z0-9-]+(\.[a-z0-9-]+)*\.run\.app$ ]]; then
  echo "❌ 找不到助理服務 ${SERVICE_NAME} 的網址（拿到「${SERVICE_URL}」），請先 bash scripts/deploy_assistant.sh"
  exit 1
fi
# 流程用 martech-pipeline-runner 的身分呼叫助理，少了 run.invoker 每一題都會是 403
POLICY="$(gcloud run services get-iam-policy "${SERVICE_NAME}" --project "${PROJECT_ID}" --region "${REGION}" --format=json)"
if ! PIPELINE_SA="${PIPELINE_SA}" python3 -c 'import json,os,sys
want = "serviceaccount:" + os.environ["PIPELINE_SA"].lower()
ok = any(b.get("role") == "roles/run.invoker" and want in [m.lower() for m in b.get("members", [])]
         for b in json.load(sys.stdin).get("bindings", []))
sys.exit(0 if ok else 1)' <<< "${POLICY}"; then
  echo "❌ ${PIPELINE_SA} 沒有助理服務的 roles/run.invoker，請先執行："
  echo "   gcloud run services add-iam-policy-binding ${SERVICE_NAME} --project ${PROJECT_ID} --region ${REGION} --member=serviceAccount:${PIPELINE_SA} --role=roles/run.invoker"
  exit 1
fi

# ------------------------------------------------------------------------------
# 2. 日報表與 view（已經有就不動資料，view 會換成最新的定義）
# ------------------------------------------------------------------------------
echo "── 建立日報表與 view ──"
SETUP_OUT="$(mktemp)"
trap 'rm -f "${SETUP_OUT}"' EXIT
if ! sed -e "s/martech_dw\./${DATASET}./g" "${FLOW_DIR}/setup.sql" \
    | bq --headless --location=US query --nouse_legacy_sql --quiet > "${SETUP_OUT}" 2>&1; then
  echo "❌ workflows/setup.sql 執行失敗："
  tail -n 20 "${SETUP_OUT}"
  exit 1
fi

# ------------------------------------------------------------------------------
# 3. 部署流程
#    --service-account：流程用 martech-pipeline-runner 的身分呼叫助理與寫 BigQuery，流程定義裡沒有任何金鑰
#    --set-env-vars：助理的網址與資料集在這裡寫死，啟動流程的人不能用參數改掉（原因寫在 daily_report.yaml 開頭）
#    沒有開 call logging：開了會把每一步的請求與回應寫進 Cloud Logging，助理的回答原文也會跟著進去
# ------------------------------------------------------------------------------
echo "── 部署流程 ${WORKFLOW} ──"
gcloud workflows deploy "${WORKFLOW}" \
  --project "${PROJECT_ID}" \
  --location "${REGION}" \
  --source "${FLOW_DIR}/daily_report.yaml" \
  --service-account "${PIPELINE_SA}" \
  --set-env-vars "ASSISTANT_URL=${SERVICE_URL},DATASET=${DATASET}" \
  --description "Day 27 行銷日報：向助理問三題並寫進 ${DATASET}.daily_reports" \
  --quiet >/dev/null

# ------------------------------------------------------------------------------
# 4. 排程
#    --oauth-service-account-email：排程用 martech-scheduler 的身分啟動流程，它只有 roles/workflows.invoker
#    --time-zone：不寫就是 UTC，08:30 會變成台北時間下午四點半
#    --max-retry-attempts 0：啟動失敗不自動重試，重試可能讓同一個早上啟動兩次流程
#    網址是 Workflows 的「建立一次執行」，參數要包成字串放在 argument 裡
# ------------------------------------------------------------------------------
URI="https://workflowexecutions.googleapis.com/v1/projects/${PROJECT_ID}/locations/${REGION}/workflows/${WORKFLOW}/executions"
BODY='{"argument": "{\"trigger\": \"scheduler\"}"}'
CURRENT="$(gcloud scheduler jobs describe "${JOB}" --project "${PROJECT_ID}" --location "${REGION}" --format='value(state)' 2>/dev/null || true)"
if [[ -n "${CURRENT}" ]]; then
  VERB="update"
else
  VERB="create"
fi
# 沒有指定就維持現況：已經啟用的排程不會因為重新部署被悄悄暫停，第一次建立則先暫停
if [[ -z "${SCHEDULE_STATE}" ]]; then
  if [[ "${CURRENT}" == "ENABLED" ]]; then SCHEDULE_STATE="on"; else SCHEDULE_STATE="paused"; fi
fi
echo "── 排程 ${JOB}（${VERB}，${SCHEDULE_STATE}） ──"
gcloud scheduler jobs "${VERB}" http "${JOB}" \
  --project "${PROJECT_ID}" \
  --location "${REGION}" \
  --schedule "${SCHEDULE}" \
  --time-zone "${TIME_ZONE}" \
  --uri "${URI}" \
  --http-method POST \
  --message-body "${BODY}" \
  --oauth-service-account-email "${SCHEDULER_SA}" \
  --max-retry-attempts 0 \
  --description "Day 27：每天早上啟動行銷日報流程" \
  --quiet >/dev/null
# 新建的排程一建好就是啟用的，沒有「建立時就暫停」的選項，所以緊接著暫停，再讀回來確認
# 建立和暫停之間有幾秒的空窗，剛好落在排程時間的話流程會自己跑一次
if [[ "${SCHEDULE_STATE}" == "on" ]]; then
  gcloud scheduler jobs resume "${JOB}" --project "${PROJECT_ID}" --location "${REGION}" --quiet >/dev/null 2>&1 || true
  WANT="ENABLED"
else
  gcloud scheduler jobs pause "${JOB}" --project "${PROJECT_ID}" --location "${REGION}" --quiet >/dev/null 2>&1 || true
  WANT="PAUSED"
fi
STATE="$(gcloud scheduler jobs describe "${JOB}" --project "${PROJECT_ID}" --location "${REGION}" --format='value(state)')"
if [[ "${STATE}" != "${WANT}" ]]; then
  echo "❌ 排程應該是 ${WANT}，實際是 ${STATE}，請手動處理："
  echo "   暫停：gcloud scheduler jobs pause ${JOB} --project ${PROJECT_ID} --location ${REGION}"
  echo "   啟用：gcloud scheduler jobs resume ${JOB} --project ${PROJECT_ID} --location ${REGION}"
  exit 1
fi

echo "========================================================"
echo "✅ 日報流程已部署：${WORKFLOW}（${REGION}），用 ${PIPELINE_SA} 的身分執行"
echo "   助理的網址（部署時寫死）：${SERVICE_URL}"
echo "   排程：${JOB}｜${SCHEDULE}（${TIME_ZONE}）｜目前狀態 ${STATE}｜用 ${SCHEDULER_SA} 的身分啟動"
echo "   不花錢的測試：bash workflows/run.sh --free      （三題都改打不存在的路徑，看失敗有沒有被記下來）"
echo "   實際跑一次：  bash workflows/run.sh             （會先印估價，輸入 yes 才問，約新台幣 0.5 到 0.9 元）"
echo "   看日報：      bash workflows/run.sh --report"
echo "   啟用排程：    gcloud scheduler jobs resume ${JOB} --project ${PROJECT_ID} --location ${REGION}"
echo "   暫停排程：    gcloud scheduler jobs pause ${JOB} --project ${PROJECT_ID} --location ${REGION}"
echo "   （暫停的排程還是算一個工作，佔每個帳單帳戶 3 個的免費額度，確定不用了請刪掉）"
echo "   不用了：      gcloud scheduler jobs delete ${JOB} --project ${PROJECT_ID} --location ${REGION}"
echo "                 gcloud workflows delete ${WORKFLOW} --project ${PROJECT_ID} --location ${REGION}"
echo "========================================================"
