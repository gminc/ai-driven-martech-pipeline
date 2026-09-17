#!/usr/bin/env bash
# ==============================================================================
# 2026 iThome 鐵人賽 Day 03 - 5 分鐘 Cloud Shell 一鍵自動化建置腳本
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
TF_DIR="${REPO_DIR}/terraform"

echo "========================================================"
echo "🚀 歡迎使用 AI-Driven MarTech GCP 基礎建設一鍵建置精靈"
echo "========================================================"

# ------------------------------------------------------------------------------
# 1. 偵測目前專案
# ------------------------------------------------------------------------------
CURRENT_PROJECT="$(gcloud config get-value project 2>/dev/null || true)"
if [[ -z "${CURRENT_PROJECT}" || "${CURRENT_PROJECT}" == "(unset)" ]]; then
  echo "❌ 偵測到尚未設定 gcloud 預設專案！"
  echo "請先執行: gcloud config set project YOUR_PROJECT_ID"
  exit 1
fi
echo "🔍 目前鎖定之 Google Cloud 專案 ID: ${CURRENT_PROJECT}"

# 帳單偵測需要 Cloud Billing API（啟用本身不收費）
gcloud services enable cloudbilling.googleapis.com billingbudgets.googleapis.com \
  --project "${CURRENT_PROJECT}" --quiet >/dev/null 2>&1 || true

# ------------------------------------------------------------------------------
# 2. 偵測帳單狀態、建立預算的權限與帳戶幣別
# ------------------------------------------------------------------------------
BILLING_ENABLED="$(gcloud billing projects describe "${CURRENT_PROJECT}" --format="value(billingEnabled)" 2>/dev/null || true)"
if [[ "${BILLING_ENABLED,,}" != "true" ]]; then
  echo "❌ 此專案尚未連結帳單帳戶（或無法讀取帳單狀態）。"
  echo "   請先到 Console「帳單」為專案連結帳單帳戶後再執行本腳本。"
  exit 1
fi

BILLING_ACCOUNT_NAME="$(gcloud billing projects describe "${CURRENT_PROJECT}" --format="value(billingAccountName)" 2>/dev/null || true)"
BILLING_ID=""
BUDGET_CURRENCY="TWD"
BUDGET_AMOUNT=300

if [[ -n "${BILLING_ACCOUNT_NAME}" ]]; then
  CANDIDATE_ID="$(basename "${BILLING_ACCOUNT_NAME}")"
  echo "💳 偵測到已連結帳單帳戶 ID: ${CANDIDATE_ID}"

  # 以 testIamPermissions 確認目前帳號是否具備建立預算的權限
  ACCESS_TOKEN="$(gcloud auth print-access-token 2>/dev/null || true)"
  # Cloud Billing API 剛啟用時可能尚未生效，最多嘗試 3 次
  PERM_RESP=""
  for attempt in 1 2 3; do
    PERM_RESP="$(curl -s -X POST \
      -H "Authorization: Bearer ${ACCESS_TOKEN}" \
      -H "x-goog-user-project: ${CURRENT_PROJECT}" \
      -H "Content-Type: application/json" \
      -d '{"permissions":["billing.budgets.create"]}' \
      "https://cloudbilling.googleapis.com/v1/billingAccounts/${CANDIDATE_ID}:testIamPermissions" 2>/dev/null || true)"
    if ! grep -q '"error"' <<< "${PERM_RESP}"; then
      break
    fi
    [[ "${attempt}" -lt 3 ]] && sleep 10
  done

  if ! grep -q '"error"' <<< "${PERM_RESP}" && grep -q '"billing.budgets.create"' <<< "${PERM_RESP}"; then
    CURRENCY_CODE="$(gcloud billing accounts describe "${CANDIDATE_ID}" --format="value(currencyCode)" 2>/dev/null || true)"
    case "${CURRENCY_CODE}" in
      TWD) BILLING_ID="${CANDIDATE_ID}"; BUDGET_CURRENCY="TWD"; BUDGET_AMOUNT=300 ;;
      USD) BILLING_ID="${CANDIDATE_ID}"; BUDGET_CURRENCY="USD"; BUDGET_AMOUNT=10 ;;
      *)   echo "⚠️ 帳單帳戶幣別為「${CURRENCY_CODE:-無法讀取}」，非 TWD / USD，預算警報將略過，請自行於 Console 建立。" ;;
    esac
    [[ -n "${BILLING_ID}" ]] && echo "✅ 具備建立預算權限，將建立 ${BUDGET_CURRENCY} ${BUDGET_AMOUNT} 預算警報"
  else
    echo "⚠️ 目前帳號沒有建立預算的權限（billing.budgets.create），預算警報模組將自動略過。"
  fi
else
  echo "⚠️ 無法讀取帳單帳戶 ID，預算警報模組將自動略過。"
fi

# ------------------------------------------------------------------------------
# 3. 產生 terraform.tfvars（heredoc 不加引號，變數才會被展開）
# ------------------------------------------------------------------------------
cd "${TF_DIR}"

cat << VAR_EOF > terraform.tfvars
project_id              = "${CURRENT_PROJECT}"
region                  = "us-central1"
bq_location             = "US"
dataset_id              = "martech_dw"
storage_bucket_name     = ""
billing_account_id      = "${BILLING_ID}"
budget_amount           = ${BUDGET_AMOUNT}
budget_currency         = "${BUDGET_CURRENCY}"
allow_destroy_with_data = true
VAR_EOF

echo "📝 已自動產生 terraform.tfvars 設定檔"

# ------------------------------------------------------------------------------
# 4. 初始化、預覽、確認後部署
# ------------------------------------------------------------------------------
echo "⚙️ 正在初始化 Terraform Provider 外掛..."
terraform init

echo "📋 正在產出雲端資源執行計畫 (Plan)..."
terraform plan -out=tfplan

echo ""
read -r -p "❓ 是否確認立即部署上述所有 GCP 資源？(yes/no): " CONFIRM
if [[ "${CONFIRM}" != "yes" ]]; then
  echo "🛑 使用者已取消建置。"
  rm -f tfplan
  exit 0
fi

echo "🚀 開始執行自動化部署 (Apply)..."
if ! terraform apply tfplan; then
  echo "⚠️ 首次部署若遇 API 或服務帳號尚在生效中，正在自動等待 60 秒後重試一次..."
  sleep 60
  terraform apply -auto-approve
fi
rm -f tfplan

# ------------------------------------------------------------------------------
# 5. 驗證與輸出
# ------------------------------------------------------------------------------
echo ""
echo "🔍 驗證 BigQuery 遠端連線狀態："
BQ_LOCATION="$(terraform output -raw bq_location)"
bq show --connection "${CURRENT_PROJECT}.${BQ_LOCATION,,}.vertex_ai_conn" || true

echo ""
terraform output

echo ""
echo "========================================================"
echo "🎉 建置完成！"
echo "========================================================"
