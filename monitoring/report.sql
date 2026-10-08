-- Day 25：報表，四段，都讀 view
-- 查詢在每月 1 TiB 免費額度內

-- 1. 每一篇花了多少：呼叫次數、Token、費用
SELECT day, SUM(calls) AS calls, SUM(failed_calls) AS failed_calls,
  SUM(prompt_tokens) AS prompt_tokens, SUM(output_tokens) AS output_tokens,
  ROUND(SUM(cost_twd), 2) AS cost_twd, SUM(unpriced_calls) AS unpriced_calls
FROM martech_dw.v_llm_usage_daily
GROUP BY day
ORDER BY day;

-- 2. 每一天（台北時間）花了多少
SELECT usage_date, SUM(calls) AS calls,
  SUM(total_tokens) AS total_tokens, ROUND(SUM(cost_twd), 2) AS cost_twd, SUM(unpriced_calls) AS unpriced_calls
FROM martech_dw.v_llm_usage_daily
GROUP BY usage_date
ORDER BY usage_date;

-- 3. 每個模型、每種端點：輸出佔 Token 幾成、佔費用幾成
SELECT model, endpoint_type, SUM(calls) AS calls,
  SUM(prompt_tokens) AS prompt_tokens, SUM(output_tokens) AS output_tokens,
  ROUND(SUM(cost_twd), 2) AS cost_twd,
  ROUND(SAFE_DIVIDE(SUM(output_tokens), SUM(total_tokens)), 3) AS output_share_of_tokens,
  ROUND(SAFE_DIVIDE(SUM(cost_out_twd), SUM(cost_twd)), 3) AS output_share_of_cost
FROM martech_dw.v_llm_usage_daily
GROUP BY model, endpoint_type
ORDER BY cost_twd DESC;

-- 4. 對不到單價的呼叫（儀表板的費用合計不含這些）
SELECT day, job, model, endpoint_type, SUM(calls) AS calls,
  SUM(prompt_tokens) AS prompt_tokens, SUM(output_tokens) AS output_tokens
FROM martech_dw.v_llm_usage_daily
WHERE NOT priced
GROUP BY day, job, model, endpoint_type
ORDER BY day, job;
