-- Day 13：呼叫 Gemini 之前先數 Token、估最壞情況的費用
-- AI.COUNT_TOKENS 只數題目本身，實測每次呼叫還會多約 150–200 個 token（response_schema 也算輸入），這裡多算 200
-- blind.sql 會跑兩個模型、每個各三次，共 6 次：
--   gemini-3.5-flash-lite 每百萬 token 輸入 0.30、輸出 2.50 美元
--   gemini-3.6-flash      每百萬 token 輸入 0.75、輸出 3.75 美元（2026/12/31 前的優惠價）
--   （2026-09 官方價目表，global 區域；us 多區域端點略高；和 Day 09 cost.sql 同一組單價）
-- 最壞情況＝每一次都把 max_output_tokens 4096 用滿；新台幣以 1 美元 32 元換算

WITH t AS (
  SELECT AI.COUNT_TOKENS(prompt, endpoint => 'gemini-3.5-flash-lite').result AS prompt_tokens
  FROM martech_dw.blind_prompt
  WHERE run_no = 1
),
runs AS (
  SELECT COUNT(*) AS calls FROM martech_dw.blind_prompt
),
price AS (
  SELECT 'gemini-3.5-flash-lite' AS model, 0.30 AS in_usd, 2.50 AS out_usd
  UNION ALL SELECT 'gemini-3.6-flash', 0.75, 3.75
),
per_model AS (
  SELECT
    p.model, r.calls, t.prompt_tokens,
    (t.prompt_tokens + 200) * r.calls AS input_tokens,
    4096 * r.calls AS output_tokens_worst,
    ((t.prompt_tokens + 200) * r.calls * p.in_usd + 4096 * r.calls * p.out_usd) / 1e6 AS worst_usd
  FROM t CROSS JOIN runs r CROSS JOIN price p
),
rows_out AS (
  SELECT model, calls, prompt_tokens, input_tokens, output_tokens_worst,
    ROUND(worst_usd, 4) AS worst_case_usd, ROUND(worst_usd * 32, 2) AS worst_case_twd
  FROM per_model
  UNION ALL
  SELECT '合計', SUM(calls), MAX(prompt_tokens), SUM(input_tokens), SUM(output_tokens_worst),
    ROUND(SUM(worst_usd), 4), ROUND(SUM(worst_usd) * 32, 2)
  FROM per_model
)
SELECT * FROM rows_out
ORDER BY IF(model = '合計', 1, 0), model DESC;
