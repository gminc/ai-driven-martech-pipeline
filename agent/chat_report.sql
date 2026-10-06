-- Day 22：報表，三段，只看固定腳本完整跑完的那一場
-- 查詢在每月 1 TiB 免費額度內

-- 1. 每一輪：問了什麼、查了哪些工具、回答
SELECT t.turn, t.question, t.tools_called, t.answer
FROM martech_dw.chat_turns t
WHERE t.session_id IN (SELECT session_id FROM martech_dw.chat_turns WHERE mode = 'script' GROUP BY 1 HAVING COUNTIF(status = '') = 5)
ORDER BY t.turn;

-- 2. 每一次呼叫模型的輸入 Token：對話越長，同一份紀錄重送的部分越多
SELECT c.turn, c.step, c.prompt_tokens, c.output_tokens, c.thoughts_tokens, c.latency_ms,
  ROUND((c.prompt_tokens * 0.75 + (c.output_tokens + c.thoughts_tokens) * 3.75) / 1e6 * 32, 3) AS cost_twd
FROM martech_dw.chat_calls_log c
WHERE c.status = ''
  AND c.session_id IN (SELECT session_id FROM martech_dw.chat_turns WHERE mode = 'script' GROUP BY 1 HAVING COUNTIF(status = '') = 5)
ORDER BY c.turn, c.step;

-- 3. 合計：gemini-3.6-flash global 端點每百萬 Token 輸入 0.75、輸出 3.75 美元，匯率 32
SELECT COUNT(DISTINCT c.turn) AS turns, COUNT(*) AS model_calls,
  SUM(c.prompt_tokens) AS prompt_tokens, SUM(c.output_tokens) AS output_tokens, SUM(c.thoughts_tokens) AS thoughts_tokens,
  ROUND(SUM(c.prompt_tokens * 0.75 + (c.output_tokens + c.thoughts_tokens) * 3.75) / 1e6 * 32, 3) AS cost_twd,
  ROUND(SUM(c.prompt_tokens * 0.75) / SUM(c.prompt_tokens * 0.75 + (c.output_tokens + c.thoughts_tokens) * 3.75), 3) AS input_share_of_cost
FROM martech_dw.chat_calls_log c
WHERE c.status = ''
  AND c.session_id IN (SELECT session_id FROM martech_dw.chat_turns WHERE mode = 'script' GROUP BY 1 HAVING COUNTIF(status = '') = 5);
