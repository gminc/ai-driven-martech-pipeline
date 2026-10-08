output "project_id" {
  description = "已配置之 GCP 專案 ID"
  value       = var.project_id
}

output "region" {
  description = "Cloud Storage 等區域型資源的部署區域"
  value       = var.region
}

output "bq_location" {
  description = "BigQuery Dataset 與遠端連線的位置"
  value       = var.bq_location
}

output "bigquery_dataset_id" {
  description = "已建立之 BigQuery 資料倉儲 Dataset ID"
  value       = google_bigquery_dataset.martech_dw.dataset_id
}

output "storage_bucket_name" {
  description = "已建立之 Cloud Storage 素材儲存庫名稱"
  value       = google_storage_bucket.martech_assets.name
}

output "vertex_ai_connection_id" {
  description = "BigQuery 遠端連線識別碼"
  value       = google_bigquery_connection.vertex_ai_connection.connection_id
}

output "bq_connection_service_account" {
  description = "GCP 自動託管之 BigQuery 連線服務帳號 (已賦予 roles/aiplatform.user 與素材儲存庫的 roles/storage.objectViewer)"
  value       = google_bigquery_connection.vertex_ai_connection.cloud_resource[0].service_account_id
}

output "pipeline_runner_service_account" {
  description = "資料處理流程專用服務帳號 Email"
  value       = google_service_account.pipeline_runner.email
}

output "assistant_service_account" {
  description = "Day 26：行銷助理在 Cloud Run 上執行時用的服務帳號"
  value       = google_service_account.assistant.email
}

output "assistant_image_repository" {
  description = "Day 26：助理容器映像檔的存放位置"
  value       = "${var.region}-docker.pkg.dev/${var.project_id}/${google_artifact_registry_repository.assistant.repository_id}"
}

output "scheduler_service_account" {
  description = "Day 27：Cloud Scheduler 啟動日報流程用的服務帳號"
  value       = google_service_account.scheduler.email
}

output "slack_webhook_secret" {
  description = "Day 28：Slack Webhook 網址存放的密鑰名稱（內容要自己貼）"
  value       = google_secret_manager_secret.slack_webhook.secret_id
}
