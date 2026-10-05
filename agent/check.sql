-- Day 21：流程檢查，一列＝一項，ok 欄位是 OK 或 DIFF
-- 檢查的是「實驗有沒有照設計跑完、工具有沒有守住範圍」，模型答得對不對在 report.sql 看
-- 查詢在每月 1 TiB 免費額度內

WITH
latest AS (
  SELECT * FROM martech_dw.fc_answers WHERE status = ''
  QUALIFY ROW_NUMBER() OVER (PARTITION BY question_id, mode ORDER BY created_at DESC) = 1
),
calls AS (
  SELECT c.* FROM martech_dw.fc_calls_log c JOIN latest l USING (run_id, question_id, mode)
),
tool_rows AS (
  SELECT t.* FROM martech_dw.fc_tool_log t JOIN latest l USING (run_id, question_id) WHERE l.mode = 'tools'
),
checks AS (
  SELECT '01 answered (tools/none)' AS check_name, '6/6' AS expected,
    CONCAT(CAST((SELECT COUNT(*) FROM latest WHERE mode = 'tools') AS STRING), '/',
           CAST((SELECT COUNT(*) FROM latest WHERE mode = 'none') AS STRING)) AS actual
  UNION ALL SELECT '02 tool calls without tools', '0',
    CAST((SELECT IFNULL(SUM(tool_calls), 0) FROM latest WHERE mode = 'none') AS STRING)
  -- 模型要求的工具都在清單裡（不在清單裡的不會被執行，但會留下紀錄）
  UNION ALL SELECT '03 tool names outside the list', '0',
    CAST((SELECT COUNT(*) FROM tool_rows
          WHERE tool NOT IN ('get_channel_attribution', 'get_anomaly_diagnosis', 'get_creative_feature_lift')) AS STRING)
  UNION ALL SELECT '04 model calls per question <= 4', 'true',
    CAST((SELECT IFNULL(MAX(model_calls), 0) <= 4 FROM latest) AS STRING)
  UNION ALL SELECT '05 input tokens per call <= 4000', 'true',
    CAST((SELECT IFNULL(MAX(prompt_tokens), 0) <= 4000 FROM calls) AS STRING)
  UNION ALL SELECT '06 token counts recorded', '0',
    CAST((SELECT COUNT(*) FROM calls WHERE status = '' AND (IFNULL(prompt_tokens, 0) = 0)) AS STRING)
  UNION ALL SELECT '07 bytes billed per tool call <= 100 MB', 'true',
    CAST((SELECT IFNULL(MAX(bytes_billed), 0) <= 100 * 1024 * 1024 FROM tool_rows) AS STRING)
  UNION ALL SELECT '08 usage rows = successful call rows', 'true',
    CAST((SELECT COUNT(*) FROM martech_dw.ops_llm_usage WHERE job = 'agent/ask.py')
       = (SELECT COUNT(*) FROM martech_dw.fc_calls_log WHERE status = '') AS STRING)
  UNION ALL SELECT '09 score rows', '12',
    CAST((SELECT COUNT(*) FROM martech_dw.mart_fc_score) AS STRING)
  -- 同一題的有工具與沒有工具，題目指紋要相同
  UNION ALL SELECT '10 questions with two prompt versions', '0',
    CAST((SELECT COUNT(*) FROM (SELECT question_id FROM latest GROUP BY 1 HAVING COUNT(DISTINCT prompt_version) > 1)) AS STRING)
)
SELECT check_name, expected, actual, IF(expected = actual, 'OK', 'DIFF') AS ok
FROM checks
ORDER BY check_name;
