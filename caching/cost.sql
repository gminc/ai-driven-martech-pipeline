-- Day 10：呼叫 Gemini 之前先數 Token、估最壞情況的費用
-- 單價（gemini-3.5-flash-lite，global，美元／百萬 Token）：輸入 0.30、快取命中 0.03、輸出 2.50、快取儲存每小時 1.00
-- 最壞情況的假設：
--   old、new 都不命中（全部照原價）
--   explicit 每題命中整段固定內容，另外加建立一次與存活 30 分鐘的儲存費
--   每題都把 max_output_tokens 512 用滿；每題再多算 150 Token 給 response_schema
-- 三種做法 × 3 輪 × 4 題 ＝ 36 次呼叫
-- 新台幣以 1 美元約 32 元換算

WITH t AS (
  SELECT
    (SELECT AI.COUNT_TOKENS(context, endpoint => 'gemini-3.5-flash-lite').result FROM martech_dw.cache_context) AS ctx,
    (SELECT COUNT(*) FROM martech_dw.cache_prompt) AS n,
    (SELECT SUM(AI.COUNT_TOKENS(question, endpoint => 'gemini-3.5-flash-lite').result) FROM martech_dw.cache_prompt) AS q_sum
),
c AS (
  SELECT
    ctx, n, q_sum,
    3 * (n * ctx + q_sum + 150 * n) * 0.30 / 1e6 AS old_in,
    3 * (n * ctx + q_sum + 150 * n) * 0.30 / 1e6 AS new_in,
    (3 * n * ctx * 0.03 + 3 * (q_sum + 150 * n) * 0.30 + ctx * 0.30 + ctx * 1.00 * 0.5) / 1e6 AS explicit_in,
    3 * n * 512 * 2.50 / 1e6 AS out_each
  FROM t
)
SELECT 'old' AS scenario, ctx AS context_tokens, 3 * n AS calls, ROUND((old_in + out_each) * 32, 2) AS worst_twd FROM c
UNION ALL SELECT 'new', ctx, 3 * n, ROUND((new_in + out_each) * 32, 2) FROM c
UNION ALL SELECT 'explicit', ctx, 3 * n, ROUND((explicit_in + out_each) * 32, 2) FROM c
UNION ALL SELECT 'total', ctx, 9 * n, ROUND((old_in + new_in + explicit_in + 3 * out_each) * 32, 2) FROM c
ORDER BY CASE scenario WHEN 'old' THEN 1 WHEN 'new' THEN 2 WHEN 'explicit' THEN 3 ELSE 4 END;
