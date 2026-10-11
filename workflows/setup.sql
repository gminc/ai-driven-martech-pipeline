-- Day 27：日報表與讀日報用的 view（部署腳本會先跑這一段，流程本身只寫入、不建表）
-- 一列＝某一次執行的某一題，只加不刪，同一天可以有好幾次執行（手動重跑、測試）
-- 回答的原文會留在這張表，要給誰看由 BigQuery 的權限決定
-- trigger_source 是啟動流程的人自己填的標記，方便查閱用，要當證據請對照 Workflows 的執行紀錄
-- 建表與建 view 不收費

CREATE TABLE IF NOT EXISTS martech_dw.daily_reports (
  report_date DATE,
  execution_id STRING,
  trigger_source STRING,
  section_no INT64,
  section_title STRING,
  question STRING,
  answer STRING,
  status STRING,
  detail STRING,
  session_id STRING,
  created_at TIMESTAMP
)
PARTITION BY report_date
OPTIONS (description = 'Day 27 行銷日報：一列＝某一次執行的某一題，status 是 ok、failed 或 skipped，只加不刪');

-- 一天只給一份日報：答完最多題的那一次執行，一樣多就取最新的
-- 所以後來重跑的那一次如果答得比較少，不會把原本比較完整的日報蓋掉
-- 同一次執行的同一題萬一被寫進兩列（寫入被重試），只取最早的一列
CREATE OR REPLACE VIEW martech_dw.v_daily_report AS
WITH one_row AS (
  SELECT * FROM martech_dw.daily_reports
  QUALIFY ROW_NUMBER() OVER (PARTITION BY execution_id, section_no ORDER BY created_at) = 1
),
runs AS (
  SELECT report_date, execution_id, COUNTIF(status = 'ok') AS ok_sections, MAX(created_at) AS finished_at
  FROM one_row
  GROUP BY report_date, execution_id
),
best AS (
  SELECT * FROM runs
  QUALIFY ROW_NUMBER() OVER (PARTITION BY report_date ORDER BY ok_sections DESC, finished_at DESC) = 1
)
SELECT
  r.report_date,
  r.section_no,
  r.section_title,
  r.question,
  IF(r.status = 'ok', r.answer, CONCAT('（這一題沒有答案：', r.detail, '）')) AS answer,
  r.status,
  r.detail,
  b.ok_sections,
  r.trigger_source,
  r.execution_id,
  r.session_id,
  r.created_at
FROM one_row r
JOIN best b USING (report_date, execution_id);
