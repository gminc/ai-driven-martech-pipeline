-- Day 25 前置：先看用量表裡實際有哪些值，再決定單價表要列哪些模型（不靠記憶）
SELECT day, job, model, endpoint_type,
  COUNT(*) AS calls, COUNTIF(status != '') AS failed,
  COUNTIF(prompt_tokens IS NULL) AS null_in, COUNTIF(output_tokens IS NULL) AS null_out,
  SUM(prompt_tokens) AS prompt_tokens, SUM(output_tokens) AS output_tokens,
  MIN(DATE(logged_at, 'Asia/Taipei')) AS first_date, MAX(DATE(logged_at, 'Asia/Taipei')) AS last_date
FROM martech_dw.ops_llm_usage
GROUP BY day, job, model, endpoint_type
ORDER BY day, job, model;
