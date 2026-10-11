-- Day 27、28：日報流程跑過之後的檢查，一列＝一項，ok 欄位是 OK 或 DIFF
-- 看的是日報表 daily_reports、Day 26 的問答紀錄 serve_turns 與 Day 28 的通知紀錄 ops_notifications，不經過流程自己的判斷
-- 只看昨天與今天（台北時間）的列：表是只加不刪的，以前某一次中途停掉的執行不該讓之後每一次檢查都不通過
-- 查詢在每月 1 TiB 免費額度內

WITH
rows_all AS (
  SELECT * FROM martech_dw.daily_reports
  WHERE report_date >= DATE_SUB(CURRENT_DATE('Asia/Taipei'), INTERVAL 1 DAY)
),
per_run AS (
  SELECT report_date, execution_id, COUNT(*) AS n_rows, COUNT(DISTINCT section_no) AS n_sections,
    COUNTIF(status = 'ok') AS n_ok
  FROM rows_all GROUP BY report_date, execution_id
),
asked AS (   -- 有對話編號的列，代表助理真的處理過這一題
  SELECT d.*, t.caller, t.action, t.turn, t.model_calls
  FROM rows_all d LEFT JOIN martech_dw.serve_turns t ON t.session_id = d.session_id
  WHERE d.session_id != ''
),
notes AS (
  SELECT * FROM martech_dw.ops_notifications
  WHERE report_date >= DATE_SUB(CURRENT_DATE('Asia/Taipei'), INTERVAL 1 DAY)
),
complete_runs AS (   -- 同一天「三題都答完」的執行有幾次，沒有帶 force 的話最多一次
  SELECT report_date, COUNT(*) AS n FROM per_run WHERE n_ok = 3 GROUP BY report_date
),
checks AS (
  SELECT '01 report rows recorded' AS check_name, '> 0' AS expected,
    IF((SELECT COUNT(*) FROM rows_all) > 0, '> 0', '0') AS actual
  UNION ALL SELECT '02 executions that did not write exactly 3 rows (one per question)', '0',
    CAST((SELECT COUNT(*) FROM per_run WHERE n_rows != 3 OR n_sections != 3) AS STRING)
  UNION ALL SELECT '03 rows with a status other than ok / failed / skipped', '0',
    CAST((SELECT COUNT(*) FROM rows_all WHERE status NOT IN ('ok', 'failed', 'skipped')) AS STRING)
  UNION ALL SELECT '04 ok rows with an empty answer', '0',
    CAST((SELECT COUNT(*) FROM rows_all WHERE status = 'ok' AND IFNULL(answer, '') = '') AS STRING)
  UNION ALL SELECT '05 ok rows whose assistant status is not a passing one', '0',
    CAST((SELECT COUNT(*) FROM rows_all WHERE status = 'ok'
          AND detail NOT IN ('passed', 'claims_flagged', 'exits_sealed', 'claims_flagged,exits_sealed')) AS STRING)
  UNION ALL SELECT '06 failed or skipped rows that still carry an answer', '0',
    CAST((SELECT COUNT(*) FROM rows_all WHERE status != 'ok' AND detail NOT IN
          ('input_blocked', 'output_blocked', 'safety_blocked', 'daily_cap', 'max_turns', 'input_cap', 'incomplete', 'error', 'unavailable')
          AND IFNULL(answer, '') != '') AS STRING)
  UNION ALL SELECT '07 asked rows not found in serve_turns (the assistant keeps its own record)', '0',
    CAST((SELECT COUNT(*) FROM asked WHERE caller IS NULL) AS STRING)
  UNION ALL SELECT '08 asked rows whose caller is not the pipeline service account', '0',
    CAST((SELECT COUNT(*) FROM asked WHERE caller IS NOT NULL AND NOT STARTS_WITH(caller, 'martech-pipeline-runner@')) AS STRING)
  UNION ALL SELECT '09 asked rows that were not the first turn of their own conversation', '0',
    CAST((SELECT COUNT(*) FROM asked WHERE turn IS NOT NULL AND turn != 1) AS STRING)
  UNION ALL SELECT '10 conversations used by more than one report row', '0',
    CAST((SELECT COUNT(*) FROM (SELECT session_id FROM asked GROUP BY session_id HAVING COUNT(*) > 1)) AS STRING)
  UNION ALL SELECT '11 days with more than one row per section in v_daily_report', '0',
    CAST((SELECT COUNT(*) FROM (SELECT report_date, section_no FROM martech_dw.v_daily_report WHERE report_date >= DATE_SUB(CURRENT_DATE('Asia/Taipei'), INTERVAL 1 DAY) GROUP BY 1, 2 HAVING COUNT(*) > 1)) AS STRING)
  UNION ALL SELECT '12 days where v_daily_report does not show the execution with the most answered questions', '0',
    CAST((SELECT COUNT(*) FROM (SELECT report_date, MAX(n_ok) AS best FROM per_run GROUP BY 1) p
          JOIN (SELECT report_date, ANY_VALUE(ok_sections) AS shown FROM martech_dw.v_daily_report GROUP BY 1) v USING (report_date)
          WHERE p.best != v.shown) AS STRING)
  UNION ALL SELECT '13 rows with a trigger_source other than scheduler / manual', '0',
    CAST((SELECT COUNT(*) FROM rows_all WHERE trigger_source NOT IN ('scheduler', 'manual')) AS STRING)
  -- 14 只是提醒：同一天有兩次以上完整的日報，代表有人帶 force 重跑（多花一次錢），不是錯
  UNION ALL SELECT '14 (info) days with more than one complete report (only happens with force)', '0',
    CAST((SELECT COUNT(*) FROM complete_runs WHERE n > 1) AS STRING)
  UNION ALL SELECT '15 notifications with a status other than sent / failed', '0',
    CAST((SELECT COUNT(*) FROM notes WHERE status NOT IN ('sent', 'failed')) AS STRING)
  UNION ALL SELECT '16 notifications with a kind other than anomaly / daily_report / report_incomplete / flow_error', '0',
    CAST((SELECT COUNT(*) FROM notes WHERE kind NOT IN ('anomaly', 'daily_report', 'report_incomplete', 'flow_error')) AS STRING)
  UNION ALL SELECT '17 notifications that were not delivered', '0',
    CAST((SELECT COUNT(*) FROM notes WHERE status = 'failed') AS STRING)
  UNION ALL SELECT '18 anomaly notifications whose anomaly is not in diag_summary', '0',
    CAST((SELECT COUNT(*) FROM notes n WHERE kind = 'anomaly'
          AND REPLACE(dedupe_key, 'anomaly:', '') NOT IN (SELECT anomaly_id FROM martech_dw.diag_summary)) AS STRING)
  -- 19 是底線：Slack 的網址不可以出現在任何一張表裡，這裡查通知紀錄與日報表
  UNION ALL SELECT '19 rows that contain a Slack webhook address', '0',
    CAST((SELECT COUNT(*) FROM martech_dw.ops_notifications WHERE REGEXP_CONTAINS(CONCAT(IFNULL(message, ''), ' ', IFNULL(detail, '')), r'hooks\.slack\.com'))
       + (SELECT COUNT(*) FROM martech_dw.daily_reports WHERE REGEXP_CONTAINS(CONCAT(IFNULL(answer, ''), ' ', IFNULL(detail, '')), r'hooks\.slack\.com')) AS STRING)
  UNION ALL SELECT '20 (info) daily reports sent to Slack more than once on the same day (only happens with force or renotify)', '0',
    CAST((SELECT COUNT(*) FROM (SELECT dedupe_key FROM notes WHERE kind = 'daily_report' AND status = 'sent' GROUP BY dedupe_key HAVING COUNT(*) > 1)) AS STRING)
  -- 21 只是提醒：同一筆異常送成功超過一次，代表有人帶 renotify 重送，不是錯
  UNION ALL SELECT '21 (info) anomalies notified more than once (only happens with renotify)', '0',
    CAST((SELECT COUNT(*) FROM (SELECT dedupe_key FROM martech_dw.ops_notifications WHERE kind = 'anomaly' AND status = 'sent' GROUP BY dedupe_key HAVING COUNT(*) > 1)) AS STRING)
)
SELECT check_name, expected, actual, IF(expected = actual, 'OK', 'DIFF') AS ok
FROM checks
ORDER BY check_name;
