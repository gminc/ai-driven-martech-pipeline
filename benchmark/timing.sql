-- Day 20：一批跑多久，從 INFORMATION_SCHEMA.JOBS 找每一段 INSERT（一個組合的一批呼叫）在 BigQuery 的執行秒數
-- 量到的是「BigQuery 把這一批平行送出去、等全部回來」的時間，不是單次呼叫的延遲
-- 每個組合只看張數最多的那一批：沿用的兩個組合是一批 24 張，新問的三個組合先試了 1 張、其餘 23 張一批，看的是 23 張那一批
-- 每個組合只有一批的樣本，批次大小也差 1 張，只能看出差幾倍這種大差別
-- 對應方式：呼叫紀錄的 created_at 是那一段 INSERT 開始的時間，落在哪一筆工作的建立到結束之間就是哪一筆，對不到時 seconds 是空的
-- 需要看得到專案工作紀錄的權限（bigquery.jobs.listAll），沒有權限時 run.sh 會跳過這一段，不影響其他報表
-- 不呼叫模型、不讀答案表，查詢在每月 1 TiB 免費額度內

WITH batches AS (
  SELECT task, model, source, created_at, COUNT(*) AS calls
  FROM martech_dw.mm_bench_log
  GROUP BY 1, 2, 3, 4
  QUALIFY ROW_NUMBER() OVER (PARTITION BY task, model ORDER BY COUNT(*) DESC, created_at DESC) = 1
)
SELECT b.task, b.model, b.source, b.calls,
  COUNT(j.job_id) AS jobs_matched,
  ROUND(MAX(TIMESTAMP_DIFF(j.end_time, j.start_time, MILLISECOND)) / 1000, 1) AS seconds,
  b.created_at
FROM batches b
LEFT JOIN `region-us`.INFORMATION_SCHEMA.JOBS_BY_PROJECT j
  ON j.creation_time >= TIMESTAMP '2026-09-28'
 AND j.statement_type = 'INSERT'
 AND j.destination_table.table_id IN ('mm_bench_log', 'mm_features_log', 'mm_gaps_log')
 AND b.created_at BETWEEN j.creation_time AND j.end_time
GROUP BY b.task, b.model, b.source, b.calls, b.created_at
ORDER BY b.task, b.model;
