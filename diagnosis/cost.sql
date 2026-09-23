-- Day 09：呼叫 Gemini 之前先數 Token、估最壞情況的費用
-- AI.COUNT_TOKENS 只數題目本身，實測每次呼叫還會多約 150 個 token（response_schema 也算輸入）
-- diagnose.sql 會跑兩個模型，這裡兩個都算：
--   gemini-3.5-flash-lite 每百萬 token 輸入 0.30、輸出 2.50 美元
--   gemini-3.6-flash      每百萬 token 輸入 0.75、輸出 3.75 美元（2026/12/31 前的優惠價）
--   （2026-09 官方價目表，global 區域；us 多區域端點略高）
-- 最壞情況＝每一題都把 max_output_tokens 512 用滿

WITH t AS (
  SELECT COUNT(*) AS calls, SUM(n) + 150 * COUNT(*) AS input_tokens, 512 * COUNT(*) AS output_tokens
  FROM (
    SELECT AI.COUNT_TOKENS(prompt, endpoint => 'gemini-3.5-flash-lite').result AS n
    FROM martech_dw.diag_prompt
  )
),
price AS (
  SELECT 'gemini-3.5-flash-lite' AS model, 0.30 AS in_usd, 2.50 AS out_usd
  UNION ALL SELECT 'gemini-3.6-flash', 0.75, 3.75
)
SELECT
  p.model, t.calls, t.input_tokens, t.output_tokens,
  ROUND(t.input_tokens * p.in_usd / 1e6 + t.output_tokens * p.out_usd / 1e6, 4) AS worst_case_usd
FROM t CROSS JOIN price p
ORDER BY p.model DESC;
