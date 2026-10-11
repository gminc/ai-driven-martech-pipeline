-- Day 27：讀日報與執行紀錄，查詢在每月 1 TiB 免費額度內
-- 第 1 段：最新一天的日報（每天只取答完最多題的那一次執行）
SELECT
  report_date,
  section_no,
  section_title,
  status,
  answer
FROM martech_dw.v_daily_report
WHERE report_date = (SELECT MAX(report_date) FROM martech_dw.v_daily_report)
ORDER BY section_no;

-- 第 2 段：每一次執行各答完幾題（一列＝一次執行）
SELECT
  report_date,
  FORMAT_TIMESTAMP('%m-%d %H:%M', MIN(created_at), 'Asia/Taipei') AS started_taipei,
  SUBSTR(execution_id, 1, 8) AS execution,
  ANY_VALUE(trigger_source) AS trigger_source,
  COUNTIF(status = 'ok') AS ok,
  COUNTIF(status = 'failed') AS failed,
  COUNTIF(status = 'skipped') AS skipped,
  STRING_AGG(CONCAT(CAST(section_no AS STRING), ':', detail), '  ' ORDER BY section_no) AS detail
FROM martech_dw.daily_reports
GROUP BY report_date, execution_id
ORDER BY MIN(created_at);

-- 第 3 段：日報這幾題在助理那一邊花了多少（用對話編號對回 Day 26 的問答紀錄）
SELECT
  d.report_date,
  SUBSTR(d.execution_id, 1, 8) AS execution,
  d.section_no,
  t.action,
  (SELECT STRING_AGG(JSON_VALUE(c, '$.name'), '、') FROM UNNEST(JSON_QUERY_ARRAY(t.tools_called)) AS c) AS tools,
  t.model_calls,
  t.prompt_tokens,
  t.output_tokens,
  ROUND(t.cost_twd, 4) AS cost_twd,
  t.caller
FROM martech_dw.daily_reports d
JOIN martech_dw.serve_turns t ON t.session_id = d.session_id
WHERE d.session_id != ''
ORDER BY d.created_at;

-- 第 4 段：合計
SELECT
  COUNT(DISTINCT d.execution_id) AS executions_that_asked,
  COUNT(*) AS turns,
  SUM(t.model_calls) AS model_calls,
  SUM(t.prompt_tokens) AS prompt_tokens,
  SUM(t.output_tokens) AS output_tokens,
  ROUND(SUM(t.cost_twd), 4) AS cost_twd
FROM martech_dw.daily_reports d
JOIN martech_dw.serve_turns t ON t.session_id = d.session_id
WHERE d.session_id != '';
