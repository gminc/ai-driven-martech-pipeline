variable "project_id" {
  description = "Google Cloud 專案 ID (例如: martech-ai-2026-12598)"
  type        = string
  default     = "martech-ai-2026-12598"
}

variable "region" {
  description = "GCP 核心資源部署區域 (預設 us-central1 愛荷華，Vertex AI Gemini 支援最完整且享有每月 5GB 免費儲存)"
  type        = string
  default     = "us-central1"
}

variable "dataset_id" {
  description = "BigQuery 資料倉儲 Dataset ID"
  type        = string
  default     = "martech_dw"
}

variable "dataset_description" {
  description = "BigQuery 資料倉儲說明文字"
  type        = string
  default     = "AI-Driven MarTech 資料倉儲：廣告日誌、多觸點歸因分析與多模態素材特徵庫"
}

variable "storage_bucket_name" {
  description = "Cloud Storage 素材儲存庫名稱 (留空時自動以專案 ID 為前綴動態命名，避免全域重名衝突)"
  type        = string
  default     = ""
}

variable "billing_account_id" {
  description = "Cloud Billing 帳單帳戶 ID (用於自動配置預算警報，若無帳單管理員權限可留空)"
  type        = string
  default     = ""
}

variable "budget_amount_twd" {
  description = "每月預算硬性防護上限基準 (新台幣 TWD，預設 NT$ 300 約合 US$ 10)"
  type        = number
  default     = 300
}

variable "budget_currency" {
  description = "預算幣別 (必須與 Cloud Billing 帳戶幣別一致，例如 TWD 或 USD)"
  type        = string
  default     = "TWD"
}
