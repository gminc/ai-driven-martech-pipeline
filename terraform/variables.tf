variable "project_id" {
  description = "Google Cloud 專案 ID（必填，請於 terraform.tfvars 填入自己的專案 ID）"
  type        = string
}

variable "region" {
  description = "Cloud Storage 等區域型資源的部署區域（預設 us-central1 愛荷華，適用 Cloud Storage 每月 5 GB 免費額度）"
  type        = string
  default     = "us-central1"
}

variable "bq_location" {
  description = "BigQuery Dataset 與遠端連線的位置（預設 US 多區域；BigQuery 生成式 AI 函式對 Gemini 3.x 模型的支援以 US / EU 多區域為準）"
  type        = string
  default     = "US"
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
  description = "Cloud Billing 帳單帳戶 ID (用於自動配置預算警報，若無建立預算的權限可留空)"
  type        = string
  default     = ""
}

variable "budget_amount" {
  description = "每月預算警報基準金額（幣別由 budget_currency 決定；TWD 建議 300，USD 建議 10）"
  type        = number
  default     = 300
}

variable "budget_currency" {
  description = "預算幣別 (必須與 Cloud Billing 帳戶幣別一致，例如 TWD 或 USD)"
  type        = string
  default     = "TWD"
}

variable "allow_destroy_with_data" {
  description = "terraform destroy 時是否連同儲存庫物件與資料表一併刪除（教學環境預設 true；正式環境請設為 false）"
  type        = bool
  default     = true
}
