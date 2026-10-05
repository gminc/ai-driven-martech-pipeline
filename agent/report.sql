-- Day 21：報表，五段
-- 查詢在每月 1 TiB 免費額度內

-- 1. 每一題：有沒有選對工具、參數對不對、標準答案裡的數字與原因講到幾個
SELECT question_id, kind, mode, tools_expected, tools_called,
  IFNULL(CAST(tools_ok AS STRING), '-') AS tools_ok, IFNULL(CAST(args_ok AS STRING), '-') AS args_ok,
  CONCAT(CAST(facts_found AS STRING), '/', CAST(facts_total AS STRING)) AS facts,
  has_figure, model_calls, tool_calls
FROM martech_dw.mart_fc_score
ORDER BY question_id, mode DESC;

-- 2. 模型每一次要求的工具與參數
SELECT t.question_id, t.step, t.tool, t.args, t.result_rows, t.error, t.bytes_billed
FROM martech_dw.fc_tool_log t
JOIN (SELECT DISTINCT run_id, question_id FROM martech_dw.mart_fc_score WHERE mode = 'tools') s USING (run_id, question_id)
ORDER BY t.question_id, t.step, t.created_at;

-- 3. 回答原文
SELECT question_id, mode, question, answer
FROM martech_dw.mart_fc_score
ORDER BY question_id, mode DESC;

-- 4. 標準答案（對答案時直接查表算出來的，每一組只要講到其中一種寫法就算有）
SELECT DISTINCT question_id, facts_expected
FROM martech_dw.mart_fc_score
ORDER BY question_id;

-- 5. Token 與費用：gemini-3.6-flash global 端點每百萬 Token 輸入 0.75、輸出 3.75 美元，匯率 32
SELECT s.mode,
  COUNT(DISTINCT s.question_id) AS questions,
  COUNT(*) AS model_calls,
  SUM(c.prompt_tokens) AS prompt_tokens,
  SUM(c.output_tokens) AS output_tokens,
  SUM(c.thoughts_tokens) AS thoughts_tokens,
  ROUND(SUM(c.prompt_tokens * 0.75 + (c.output_tokens + c.thoughts_tokens) * 3.75) / 1e6 * 32, 3) AS cost_twd,
  ROUND(SUM(c.prompt_tokens * 0.75 + (c.output_tokens + c.thoughts_tokens) * 3.75) / 1e6 * 32
        / COUNT(DISTINCT s.question_id) * 1000, 1) AS cost_twd_per_1000_questions,
  ROUND(AVG(c.latency_ms)) AS avg_latency_ms
FROM martech_dw.mart_fc_score s
JOIN martech_dw.fc_calls_log c USING (run_id, question_id, mode)
WHERE c.status = ''
GROUP BY 1
ORDER BY 1 DESC;
