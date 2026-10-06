-- Day 22：流程檢查，一列＝一項，ok 欄位是 OK 或 DIFF
-- 只看固定腳本完整跑完的那一場（五輪都成功的 session），自己聊的不在檢查範圍
-- 查詢在每月 1 TiB 免費額度內

WITH
done AS (
  SELECT session_id FROM martech_dw.chat_turns WHERE mode = 'script'
  GROUP BY 1 HAVING COUNTIF(status = '') = 5
),
turns AS (SELECT t.* FROM martech_dw.chat_turns t JOIN done USING (session_id)),
calls AS (SELECT c.* FROM martech_dw.chat_calls_log c JOIN done USING (session_id)),
tool_rows AS (SELECT t.* FROM martech_dw.chat_tool_log t JOIN done USING (session_id)),
checks AS (
  SELECT '01 complete script sessions' AS check_name, '1' AS expected,
    CAST((SELECT COUNT(*) FROM done) AS STRING) AS actual
  UNION ALL SELECT '02 turns answered', '5',
    CAST((SELECT COUNT(*) FROM turns WHERE status = '' AND answer != '') AS STRING)
  UNION ALL SELECT '03 tool names outside the list', '0',
    CAST((SELECT COUNT(*) FROM tool_rows WHERE tool NOT IN
      ('get_ad_spend', 'get_channel_attribution', 'get_anomaly_diagnosis', 'get_creative_feature_lift')) AS STRING)
  UNION ALL SELECT '04 tool errors', '0',
    CAST((SELECT COUNT(*) FROM tool_rows WHERE error != '') AS STRING)
  UNION ALL SELECT '05 model calls per turn <= 4', 'true',
    CAST((SELECT IFNULL(MAX(model_calls), 0) <= 4 FROM turns) AS STRING)
  UNION ALL SELECT '06 input tokens per call <= 8000', 'true',
    CAST((SELECT IFNULL(MAX(prompt_tokens), 0) <= 8000 FROM calls) AS STRING)
  UNION ALL SELECT '07 output tokens per call <= 2048', 'true',
    CAST((SELECT IFNULL(MAX(output_tokens + thoughts_tokens), 0) <= 2048 FROM calls) AS STRING)
  -- 對話紀錄有留著的話，最後一輪的輸入會比第一輪第一次呼叫多
  UNION ALL SELECT '08 input grows with the conversation', 'true',
    CAST((SELECT MAX(IF(turn = 5, prompt_tokens, NULL)) > MIN(IF(turn = 1 AND step = 1, prompt_tokens, NULL)) FROM calls) AS STRING)
  UNION ALL SELECT '09 usage rows = successful call rows', 'true',
    CAST((SELECT COUNT(*) FROM martech_dw.ops_llm_usage WHERE job = 'agent/chat.py')
       = (SELECT COUNT(*) FROM martech_dw.chat_calls_log WHERE status = '') AS STRING)
)
SELECT check_name, expected, actual, IF(expected = actual, 'OK', 'DIFF') AS ok
FROM checks
ORDER BY check_name;
