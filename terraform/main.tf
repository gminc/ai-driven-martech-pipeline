terraform {
  required_version = ">= 1.5.0"
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 6.0"
    }
  }
}

provider "google" {
  project = var.project_id
  region  = var.region
}

# 預算警報專用 Provider：Cloud Shell 以使用者身分（User ADC）呼叫 Billing Budget API 時，
# 必須指定 billing_project 並開啟 user_project_override，否則會出現 quota project 相關錯誤。
provider "google" {
  alias                 = "billing"
  project               = var.project_id
  region                = var.region
  billing_project       = var.project_id
  user_project_override = true
}

# ==============================================================================
# 1. 批次啟用專案核心必要 Google Cloud API 服務 (共 10 項)
# ==============================================================================
locals {
  services = [
    "bigquery.googleapis.com",           # BigQuery API
    "bigqueryconnection.googleapis.com", # BigQuery Connection API (SQL 呼叫遠端模型關鍵)
    "aiplatform.googleapis.com",         # Agent Platform（原 Vertex AI）API：Gemini 多模態推論，服務名稱不變
    "storage.googleapis.com",            # Cloud Storage API (素材與中繼檔案存放)
    "run.googleapis.com",                # Cloud Run API (無伺服器 AI 代理與 Live Demo 服務)
    "workflows.googleapis.com",          # Cloud Workflows API (全自動巡檢排程編排)
    "cloudbuild.googleapis.com",         # Cloud Build API (容器映像檔建置)
    "monitoring.googleapis.com",         # Cloud Monitoring API (指標監控與警報)
    "billingbudgets.googleapis.com",     # Cloud Billing Budget API (預算防爆警報)
    "iam.googleapis.com"                 # Identity and Access Management (IAM) API
  ]

  pipeline_project_roles = [
    "roles/bigquery.jobUser", # 提交查詢作業（僅能授予於專案層級）
    "roles/aiplatform.user"   # 呼叫 Gemini 模型
  ]
}

resource "google_project_service" "enabled_apis" {
  for_each                   = toset(local.services)
  project                    = var.project_id
  service                    = each.value
  disable_dependent_services = false
  disable_on_destroy         = false
}

# ==============================================================================
# 2. Cloud Storage 素材儲存庫：存放廣告圖文素材與日誌 (含 90 天自動清理生命週期)
# ==============================================================================
resource "google_storage_bucket" "martech_assets" {
  name                        = var.storage_bucket_name != "" ? var.storage_bucket_name : "${var.project_id}-martech-assets"
  location                    = var.region
  project                     = var.project_id
  force_destroy               = var.allow_destroy_with_data
  uniform_bucket_level_access = true

  versioning {
    enabled = true
  }

  # 關閉預設 7 天虛刪除保留：已有版本控管保護，避免已刪除物件再多計 7 天儲存費
  soft_delete_policy {
    retention_duration_seconds = 0
  }

  # 規則 1：現行物件 90 天後刪除（刪除後會轉為「非現行版本」）
  lifecycle_rule {
    action {
      type = "Delete"
    }
    condition {
      age = 90
    }
  }

  # 規則 2：非現行版本 7 天後永久刪除，避免舊版本持續佔用儲存空間與費用
  lifecycle_rule {
    action {
      type = "Delete"
    }
    condition {
      days_since_noncurrent_time = 7
    }
  }

  depends_on = [google_project_service.enabled_apis]
}

# ==============================================================================
# 3. BigQuery 現代資料倉儲：星狀綱要與歸因運算核心
# ==============================================================================
resource "google_bigquery_dataset" "martech_dw" {
  dataset_id                 = var.dataset_id
  friendly_name              = "MarTech Analytics Data Warehouse"
  description                = var.dataset_description
  location                   = var.bq_location
  project                    = var.project_id
  delete_contents_on_destroy = var.allow_destroy_with_data

  labels = {
    environment = "tutorial"
    competition = "ithome-ironman-2026"
    track       = "build-on-google-ai"
  }

  depends_on = [google_project_service.enabled_apis]
}

# ==============================================================================
# 4. BigQuery 遠端連線 (Remote Connection)：SQL 呼叫 Gemini 的零金鑰橋樑
#    連線必須與 Dataset 位於同一位置 (var.bq_location)
# ==============================================================================
resource "google_bigquery_connection" "vertex_ai_connection" {
  connection_id = "vertex_ai_conn"
  project       = var.project_id
  location      = var.bq_location
  friendly_name = "BigQuery to Gemini Remote Connection"
  description   = "提供 BigQuery 生成式 AI 函式（AI.GENERATE_TEXT 等）呼叫 Gemini 模型"

  cloud_resource {}

  depends_on = [google_project_service.enabled_apis]
}

# 為 BigQuery 自動配發的託管服務帳號賦予 Agent Platform User (roles/aiplatform.user) 權限
resource "google_project_iam_member" "bq_connection_ai_user" {
  project = var.project_id
  role    = "roles/aiplatform.user"
  member  = "serviceAccount:${google_bigquery_connection.vertex_ai_connection.cloud_resource[0].service_account_id}"
}

# ==============================================================================
# 5. 資料管線專用服務帳號 (Service Account) 與最小權限 (Least Privilege) 綁定
# ==============================================================================
resource "google_service_account" "pipeline_runner" {
  account_id   = "martech-pipeline-runner"
  display_name = "MarTech Data Pipeline Runner Service Account"
  description  = "專用於執行日常資料合成、BigQuery 批次載入與 Gemini 特徵工程之專屬服務帳號"
  project      = var.project_id

  depends_on = [google_project_service.enabled_apis]
}

# 專案層級：僅保留無法縮小範圍的角色
resource "google_project_iam_member" "pipeline_runner_project_roles" {
  for_each = toset(local.pipeline_project_roles)
  project  = var.project_id
  role     = each.value
  member   = "serviceAccount:${google_service_account.pipeline_runner.email}"
}

# 資料集層級：只能讀寫 martech_dw，不影響專案內其他資料集
resource "google_bigquery_dataset_iam_member" "pipeline_runner_data_editor" {
  project    = var.project_id
  dataset_id = google_bigquery_dataset.martech_dw.dataset_id
  role       = "roles/bigquery.dataEditor"
  member     = "serviceAccount:${google_service_account.pipeline_runner.email}"
}

# 儲存庫層級：只能存取素材儲存庫，不影響專案內其他 bucket
resource "google_storage_bucket_iam_member" "pipeline_runner_object_admin" {
  bucket = google_storage_bucket.martech_assets.name
  role   = "roles/storage.objectAdmin"
  member = "serviceAccount:${google_service_account.pipeline_runner.email}"
}

# ==============================================================================
# 6. Cloud Billing 階梯式預算警報 (未設定帳單帳戶 ID 時自動跳過)
# ==============================================================================
# Budget API 會以「專案編號」儲存篩選條件，使用編號可避免每次 plan 都出現差異
data "google_project" "current" {
  project_id = var.project_id
}

resource "google_billing_budget" "budget_alert" {
  count           = var.billing_account_id != "" ? 1 : 0
  provider        = google.billing
  billing_account = var.billing_account_id
  display_name    = "MarTech-2026-Ironman-Defense-Budget"

  budget_filter {
    projects               = ["projects/${data.google_project.current.number}"]
    credit_types_treatment = "INCLUDE_ALL_CREDITS"
  }

  amount {
    specified_amount {
      currency_code = var.budget_currency
      units         = tostring(var.budget_amount)
    }
  }

  threshold_rules {
    threshold_percent = 0.5
    spend_basis       = "CURRENT_SPEND"
  }

  threshold_rules {
    threshold_percent = 0.8
    spend_basis       = "CURRENT_SPEND"
  }

  threshold_rules {
    threshold_percent = 1.0
    spend_basis       = "CURRENT_SPEND"
  }

  depends_on = [google_project_service.enabled_apis]
}
