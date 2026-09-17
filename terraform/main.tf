terraform {
  required_version = ">= 1.5.0"
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 6.0"
    }
    google-beta = {
      source  = "hashicorp/google-beta"
      version = "~> 6.0"
    }
  }
}

provider "google" {
  project = var.project_id
  region  = var.region
}

provider "google-beta" {
  project = var.project_id
  region  = var.region
}

# ==============================================================================
# 1. 批次啟用專案核心必要 Google Cloud API 服務 (共 10 項)
# ==============================================================================
locals {
  services = [
    "bigquery.googleapis.com",           # BigQuery API
    "bigqueryconnection.googleapis.com", # BigQuery Connection API (SQL 呼叫遠端模型關鍵)
    "aiplatform.googleapis.com",         # Vertex AI API (Gemini 多模態推論)
    "storage.googleapis.com",            # Cloud Storage API (素材與中繼檔案存放)
    "run.googleapis.com",                # Cloud Run API (無伺服器 Agent 與 Live Demo 服務)
    "workflows.googleapis.com",          # Cloud Workflows API (全自動巡檢排程編排)
    "cloudbuild.googleapis.com",         # Cloud Build API (容器映像檔建置)
    "monitoring.googleapis.com",         # Cloud Monitoring API (指標監控與警報)
    "billingbudgets.googleapis.com",     # Cloud Billing Budget API (預算防爆警報)
    "iam.googleapis.com"                 # Identity and Access Management (IAM) API
  ]
}

resource "google_project_service" "enabled_apis" {
  for_each                   = toset(locals.services)
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
  force_destroy               = false
  uniform_bucket_level_access = true

  versioning {
    enabled = true
  }

  lifecycle_rule {
    action {
      type = "Delete"
    }
    condition {
      age = 90 # 廣告素材與暫存日誌 90 天後自動清除，貫徹 FinOps 成本極簡原則
    }
  }

  depends_on = [google_project_service.enabled_apis]
}

# ==============================================================================
# 3. BigQuery 現代資料倉儲：星狀綱要與歸因運算核心
# ==============================================================================
resource "google_bigquery_dataset" "martech_dw" {
  dataset_id                  = var.dataset_id
  friendly_name               = "MarTech Analytics Data Warehouse"
  description                 = var.dataset_description
  location                    = var.region
  project                     = var.project_id
  delete_contents_on_destroy  = false

  labels = {
    environment = "production"
    competition = "ithome-ironman-2026"
    track       = "build-on-google-ai"
  }

  depends_on = [google_project_service.enabled_apis]
}

# ==============================================================================
# 4. BigQuery 遠端連線 (Remote Connection)：SQL 呼叫 Vertex AI 零金鑰橋樑
# ==============================================================================
resource "google_bigquery_connection" "vertex_ai_connection" {
  connection_id = "vertex_ai_conn"
  project       = var.project_id
  location      = var.region
  friendly_name = "BigQuery to Vertex AI Remote Connection"
  description   = "提供 BigQuery ML.GENERATE_TEXT 於 Google 內部專用骨幹網路就地呼叫 Vertex AI Gemini 模型"

  cloud_resource {}

  depends_on = [google_project_service.enabled_apis]
}

# 為 BigQuery 自動配發的託管服務帳號賦予 Vertex AI 使用者權限
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
  description  = "專用於執行日常資料合成、BigQuery 批次載入與 Vertex AI 特徵工程之專屬服務帳號"
  project      = var.project_id

  depends_on = [google_project_service.enabled_apis]
}

locals {
  pipeline_roles = [
    "roles/bigquery.dataEditor", # 具備資料表讀寫權限
    "roles/bigquery.jobUser",    # 具備提交查詢工作權限
    "roles/storage.objectAdmin", # 具備素材物件上傳與存取權限
    "roles/aiplatform.user"      # 具備呼叫 Vertex AI Gemini API 權限
  ]
}

resource "google_project_iam_member" "pipeline_runner_roles" {
  for_each = toset(locals.pipeline_roles)
  project  = var.project_id
  role     = each.value
  member   = "serviceAccount:${google_service_account.pipeline_runner.email}"
}

# ==============================================================================
# 6. Cloud Billing 階梯式預算警報 (NT$ 300 預算防護，未設定帳單帳號時自動跳過)
# ==============================================================================
resource "google_billing_budget" "budget_alert" {
  count           = var.billing_account_id != "" ? 1 : 0
  billing_account = var.billing_account_id
  display_name    = "MarTech-2026-Ironman-Defense-Budget"

  budget_filter {
    projects               = ["projects/${var.project_id}"]
    credit_types_treatment = "INCLUDE_ALL_CREDITS"
  }

  amount {
    specified_amount {
      currency_code = var.budget_currency
      units         = tostring(var.budget_amount_twd)
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
