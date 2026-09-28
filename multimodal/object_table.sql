-- Day 14：讓 BigQuery 看得到素材圖，建立物件表 obj_creatives
-- 物件表不複製圖片，只記錄 Cloud Storage 上每個檔案的中繼資料（路徑、大小、類型、更新時間），
-- 之後交給 Gemini 看圖時，BigQuery 透過同一個連線 us.vertex_ai_conn 去讀圖片
-- 前置：連線的服務帳號要有素材 bucket 的 roles/storage.objectViewer（Terraform 的 bq_connection_assets_viewer）
-- PROJECT_ID 由 run.sh 換成目前的專案 ID，單獨執行時用 sed 換掉（見 README）
-- 建表與查詢中繼資料不收費（含在每月 1 TiB 免費額度）

CREATE OR REPLACE EXTERNAL TABLE martech_dw.obj_creatives
WITH CONNECTION `us.vertex_ai_conn`
OPTIONS (
  object_metadata = 'SIMPLE',
  uris = ['gs://PROJECT_ID-martech-assets/creatives/*.jpg']
);

SELECT
  COUNT(*) AS images,
  SUM(size) AS total_bytes,
  MIN(content_type) AS content_type,
  MIN(updated) AS first_updated,
  MAX(updated) AS last_updated
FROM martech_dw.obj_creatives;
