-- Day 09 ① AI 的診斷，兩個模型並排
SELECT
  entity,
  period_start,
  MAX(IF(model = 'gemini-3.5-flash-lite', FORMAT('%s（%.2f）', cause, confidence), NULL)) AS flash_lite,
  MAX(IF(model = 'gemini-3.6-flash', FORMAT('%s（%.2f）', cause, confidence), NULL)) AS flash,
  SUM(CAST(JSON_VALUE(statistics, '$.prompt_token_count') AS INT64)) AS input_tokens,
  SUM(CAST(JSON_VALUE(statistics, '$.candidates_token_count') AS INT64)) AS output_tokens
FROM martech_dw.mart_diagnosis
GROUP BY entity, period_start
ORDER BY period_start;

-- Day 09 ② flash-lite 的判斷理由與下一步
SELECT entity, cause, evidence, next_check
FROM martech_dw.mart_diagnosis
WHERE model = 'gemini-3.5-flash-lite'
ORDER BY period_start;
