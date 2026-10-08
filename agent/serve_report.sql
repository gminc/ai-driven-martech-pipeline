-- Day 26：服務上線後的報表，查詢在每月 1 TiB 免費額度內
-- 第 1 段：每一輪問了什麼、程式做了什麼、花了多少（問題與回答的原文在 serve_turns，這裡只印前 60 個字）
SELECT
  FORMAT_TIMESTAMP('%m-%d %H:%M', created_at, 'Asia/Taipei') AS at_taipei,
  SUBSTR(session_id, 1, 6) AS conversation,
  turn,
  SUBSTR(question, 1, 30) AS question,
  action,
  status,
  (SELECT STRING_AGG(CONCAT(JSON_VALUE(c, '$.name'), IF(IFNULL(JSON_VALUE(c, '$.error'), '') = '', '', '（被拒絕或失敗）')), '、')
   FROM UNNEST(JSON_QUERY_ARRAY(tools_called)) AS c) AS tools,
  model_calls,
  prompt_tokens,
  output_tokens,
  ROUND(cost_twd, 2) AS cost_twd,
  SUBSTR(REPLACE(final_answer, '\n', ' '), 1, 60) AS answer
FROM martech_dw.serve_turns
ORDER BY created_at;

-- 第 2 段：這個服務在 Day 25 的儀表板資料來源裡長什麼樣子（一天一列）
SELECT
  usage_date,
  day,
  model,
  endpoint_type,
  SUM(calls) AS calls,
  SUM(prompt_tokens) AS prompt_tokens,
  SUM(output_tokens) AS output_tokens,
  ROUND(SUM(cost_twd), 2) AS cost_twd,
  SUM(unpriced_calls) AS unpriced_calls
FROM martech_dw.v_llm_usage_daily
WHERE job = 'agent/serve.py'
GROUP BY usage_date, day, model, endpoint_type
ORDER BY usage_date;
