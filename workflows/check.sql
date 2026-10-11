-- Day 27：日報流程跑過之後的檢查，一列＝一項，ok 欄位是 OK 或 DIFF
-- 看的是日報表 daily_reports 與 Day 26 的問答紀錄 serve_turns，不經過流程自己的判斷
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
)
SELECT check_name, expected, actual, IF(expected = actual, 'OK', 'DIFF') AS ok
FROM checks
ORDER BY check_name;
