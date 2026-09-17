#!/usr/bin/env bash
# ==============================================================================
# 2026 iThome 鐵人賽 Day 04 - Live Demo 站一鍵部署到 Cloud Run（單一服務）
#
# 用法（在 Cloud Shell 專案根目錄）：
#   bash scripts/deploy_live_demo.sh
#   GA_MEASUREMENT_ID=G-XXXXXXXXXX bash scripts/deploy_live_demo.sh   # 有 GA4 評估 ID 時
#   PAYMENT_MODE=simulate bash scripts/deploy_live_demo.sh            # 綠界測試環境不可用時改用模擬結帳
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
APP_DIR="${REPO_DIR}/live-demo"

SERVICE_NAME="${SERVICE_NAME:-martech-live-demo}"
# asia-east1（彰化）離台灣訪客最近，屬 Cloud Run 第 1 級定價區域（超出免費額度後單價較低）
REGION="${REGION:-asia-east1}"
GA_MEASUREMENT_ID="${GA_MEASUREMENT_ID:-}"
PAYMENT_MODE="${PAYMENT_MODE:-ecpay}"

PROJECT_ID="$(gcloud config get-value project 2>/dev/null || true)"
if [[ -z "${PROJECT_ID}" || "${PROJECT_ID}" == "(unset)" ]]; then
  echo "❌ 尚未設定 gcloud 預設專案，請先執行: gcloud config set project YOUR_PROJECT_ID"
  exit 1
fi
if [[ -n "${GA_MEASUREMENT_ID}" && ! "${GA_MEASUREMENT_ID}" =~ ^G-[A-Z0-9]{4,}$ ]]; then
  echo "❌ GA_MEASUREMENT_ID 格式應為 G-XXXXXXXXXX"
  exit 1
fi
if [[ "${PAYMENT_MODE}" != "ecpay" && "${PAYMENT_MODE}" != "simulate" ]]; then
  echo "❌ PAYMENT_MODE 只接受 ecpay 或 simulate"
  exit 1
fi

echo "🔍 專案：${PROJECT_ID}｜區域：${REGION}｜服務：${SERVICE_NAME}｜付款模式：${PAYMENT_MODE}"

# ------------------------------------------------------------------------------
# 1. 啟用 API（Day 03 Terraform 已啟用 run / cloudbuild，這裡補上 artifactregistry，重複執行無副作用）
# ------------------------------------------------------------------------------
gcloud services enable run.googleapis.com cloudbuild.googleapis.com artifactregistry.googleapis.com \
  --project "${PROJECT_ID}" --quiet

# ------------------------------------------------------------------------------
# 2. 原始碼部署由 Cloud Build 以 Compute Engine 預設服務帳號建置，需要 Cloud Run Builder 角色
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
  # IAM 權限生效需要一點時間，剛授予就建置會出現 PERMISSION_DENIED
  echo "⏳ 等待 90 秒讓 IAM 權限生效..."
  sleep 90
fi

# ------------------------------------------------------------------------------
# 3. 部署：最少 0 個執行個體（沒人造訪就不計費）、最多 2 個（避免被灌流量燒錢）
#    用 --update-env-vars 只更新有指定的變數，重跑時不會清掉之前設定好的 GA_MEASUREMENT_ID
# ------------------------------------------------------------------------------
ENV_VARS="PAYMENT_MODE=${PAYMENT_MODE}"
if [[ -n "${GA_MEASUREMENT_ID}" ]]; then
  ENV_VARS="${ENV_VARS},GA_MEASUREMENT_ID=${GA_MEASUREMENT_ID}"
fi

gcloud run deploy "${SERVICE_NAME}" \
  --source "${APP_DIR}" \
  --project "${PROJECT_ID}" \
  --region "${REGION}" \
  --allow-unauthenticated \
  --min-instances 0 \
  --max-instances 2 \
  --cpu 1 \
  --memory 512Mi \
  --update-env-vars "${ENV_VARS}" \
  --quiet

# ------------------------------------------------------------------------------
# 4. 每次部署都會在 cloud-run-source-deploy 儲存庫留下一份映像檔
#    設定清理政策：只保留最新 2 版，其餘超過 1 天由背景作業刪除（非立即生效），守住每月 0.5 GB 免費儲存
# ------------------------------------------------------------------------------
POLICY_FILE="$(mktemp)"
trap 'rm -f "${POLICY_FILE}"' EXIT
cat > "${POLICY_FILE}" << 'POLICY_EOF'
[
  {"name": "delete-old-images", "action": {"type": "Delete"}, "condition": {"tagState": "any", "olderThan": "1d"}},
  {"name": "keep-latest-2", "action": {"type": "Keep"}, "mostRecentVersions": {"keepCount": 2}}
]
POLICY_EOF
gcloud artifacts repositories set-cleanup-policies cloud-run-source-deploy \
  --project "${PROJECT_ID}" --location "${REGION}" \
  --policy "${POLICY_FILE}" --no-dry-run --quiet >/dev/null \
  && echo "🧹 已設定 Artifact Registry 映像檔清理政策" \
  || echo "⚠️ 清理政策設定失敗，請到 Artifact Registry 手動刪除舊映像檔"

# Cloud Run 會同時提供兩種網址；優先顯示不含專案編號的 *.a.run.app 網址，避免在文章中公開專案編號
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
echo "========================================================"
echo "✅ Live Demo 已上線：${SERVICE_URL}"
echo "   健康檢查：curl -s ${SERVICE_URL}/health"
echo "   付款通知紀錄：gcloud logging read 'resource.type=\"cloud_run_revision\" AND jsonPayload.event=\"ecpay_payment_notify\"' --project ${PROJECT_ID} --limit 5"
echo "========================================================"
