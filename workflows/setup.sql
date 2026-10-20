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
  WHERE TRUE
  QUALIFY ROW_NUMBER() OVER (PARTITION BY execution_id, section_no ORDER BY created_at) = 1
),
runs AS (
  SELECT report_date, execution_id, COUNTIF(status = 'ok') AS ok_sections, MAX(created_at) AS finished_at
  FROM one_row
  GROUP BY report_date, execution_id
),
best AS (
  SELECT * FROM runs
  WHERE TRUE
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

-- ── Day 28：通知紀錄與異常警報的文字 ─────────────────────────────────────────────
-- 一列＝一次要送 Slack 的通知，送成功、沒送出去都留一列，只加不刪
-- 同一件事只通知一次靠的就是這張表：送之前先查 dedupe_key 有沒有 status = 'sent' 的列
-- message 是送出去之前的原文（還沒換掉 & < >），Slack 的網址不在這張表裡
CREATE TABLE IF NOT EXISTS martech_dw.ops_notifications (
  sent_at TIMESTAMP,
  report_date DATE,
  execution_id STRING,
  kind STRING,
  dedupe_key STRING,
  status STRING,
  detail STRING,
  message STRING
)
PARTITION BY report_date
OPTIONS (description = 'Day 28 Slack 通知紀錄：kind 是 anomaly、daily_report、report_incomplete 或 flow_error，status 是 sent 或 failed，只加不刪');

-- 異常警報的文字在這裡組好，流程只負責挑出該送的列再送出去
-- 異常是 Day 09 的 diag_summary，判讀取 Flash 那一輪（model LIKE 'gemini-%-flash'，不含 flash-lite，和助理的查異常工具用同一個條件，換模型前後存的判讀都讀得到）
-- data_through 是廣告資料最新的一天，流程沒有帶 as_of 的時候就拿它當今天
CREATE OR REPLACE VIEW martech_dw.v_anomaly_alerts AS
SELECT
  s.anomaly_id,
  s.level,
  s.entity,
  s.period_start,
  s.period_end,
  (SELECT MAX(date) FROM martech_dw.fct_ad_daily) AS data_through,
  d.cause,
  d.confidence,
  CONCAT(
    -- 收尾的 * 後面要接空白或換行 Slack 才會顯示粗體，接全形標點會把星號原樣印出來（Day 28 實測）
    '*成效異常*\n',
    CASE s.level
      WHEN 'site_day' THEN CONCAT('全站 ', CAST(s.period_start AS STRING))
      WHEN 'adgroup_week' THEN CONCAT('廣告群組 ', s.entity, '，', CAST(s.period_start AS STRING), ' 到 ', CAST(s.period_end AS STRING), ' 這一週')
      WHEN 'creative_week' THEN CONCAT('廣告素材 ', s.entity, '，', CAST(s.period_start AS STRING), ' 到 ', CAST(s.period_end AS STRING), ' 這一週')
      ELSE CONCAT(s.level, ' ', s.entity, ' ', CAST(s.period_start AS STRING))
    END,
    '\n判讀：', IFNULL(d.cause, '還沒有判讀'),
    IF(d.confidence IS NULL, '', CONCAT('（信心 ', FORMAT('%.2f', d.confidence), '）')),
    IF(IFNULL(d.evidence, '') = '', '', CONCAT('\n依據：', d.evidence)),
    IF(IFNULL(d.next_check, '') = '', '', CONCAT('\n建議先查：', d.next_check)),
    '\n判讀是 Day 09 請 Gemini 做的，數字在 martech_dw.diag_summary'
  ) AS message
FROM martech_dw.diag_summary s
LEFT JOIN martech_dw.mart_diagnosis d
  ON d.anomaly_id = s.anomaly_id AND d.model LIKE 'gemini-%-flash';
