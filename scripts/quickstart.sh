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

CURRENT_PROJECT="$(gcloud config get-value project 2>/dev/null || echo "")"
if [[ -z "${CURRENT_PROJECT}" ]]; then
  echo "❌ 偵測到尚未設定 gcloud 預設專案！"
  echo "請先執行: gcloud config set project YOUR_PROJECT_ID"
  exit 1
fi

echo "🔍 目前鎖定之 Google Cloud 專案 ID: ${CURRENT_PROJECT}"

BILLING_ACCOUNT="$(gcloud beta billing projects describe "${CURRENT_PROJECT}" --format="value(billingAccountName)" 2>/dev/null || echo "")"
BILLING_ID=""
if [[ -n "${BILLING_ACCOUNT}" ]]; then
  BILLING_ID="$(basename "${BILLING_ACCOUNT}")"
  echo "💳 偵測到已連結帳單帳戶 ID: ${BILLING_ID}"
else
  echo "⚠️ 尚未偵測到帳單帳戶或無管理員權限，預算警報模組將自動優雅跳過。"
fi

cd "${TF_DIR}"

cat << 'VAR_EOF' > terraform.tfvars
project_id          = "${CURRENT_PROJECT}"
region              = "us-central1"
dataset_id          = "martech_dw"
storage_bucket_name = ""
billing_account_id  = "${BILLING_ID}"
budget_amount_twd   = 300
budget_currency     = "TWD"
VAR_EOF

echo "📝 已自動產生 terraform.tfvars 設定檔"

echo "⚙️ 正在初始化 Terraform Provider 外掛..."
terraform init -upgrade

echo "📋 正在產出雲端資源執行計畫 (Plan)..."
terraform plan -out=tfplan

echo ""
read -p "❓ 是否確認立即部署上述所有 GCP 資源？(yes/no): " CONFIRM
if [[ "${CONFIRM}" != "yes" ]]; then
  echo "🛑 使用者已取消建置。"
  exit 0
fi

echo "🚀 開始執行自動化部署 (Apply)..."
if ! terraform apply tfplan; then
  echo "⚠️ 首次部署若遇 API 啟用非同步生效中，正在自動等待 60 秒後重試一次..."
  sleep 60
  terraform apply -auto-approve
fi

echo ""
echo "========================================================"
echo "🎉 恭喜！GCP 基礎架構已全自動建置就緒！"
echo "========================================================"
terraform output

echo ""
echo "🔍 驗證 BigQuery 遠端連線狀態："
bq show --connection "${CURRENT_PROJECT}.us-central1.vertex_ai_conn" || true

