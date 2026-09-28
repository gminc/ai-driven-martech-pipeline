-- Day 14：第一次讓 Gemini 看圖，三張示範圖各自由描述
-- 題目只有一句話加上圖片本身（物件表的 ref 欄），不給格式、不給選項，看它自己會寫什麼
-- 四輪、每輪三張，共 12 次呼叫：
--   1. gemini-3.5-flash-lite、預設解析度，第 1 次
--   2. gemini-3.5-flash-lite、預設解析度，第 2 次（同一張圖問兩次，看措辭一不一樣）
--   3. gemini-3.6-flash、預設解析度（對照一次）
--   4. gemini-3.5-flash-lite、低解析度 MEDIA_RESOLUTION_LOW（看一張圖少算多少 Token、描述少了什麼）
-- endpoint 與 model_params 只能寫常數，所以四輪各寫一段
-- 這一步會產生 Token 費用，run.sh 會先印出最壞情況的費用再問要不要繼續，只讀 martech_dw，不讀答案表

DECLARE prompt_text STRING DEFAULT
  '這是一張電商廣告圖，請用繁體中文描述它，讓沒看過這張圖的行銷同事知道它長什麼樣子，150 字以內。';

CREATE OR REPLACE TABLE martech_dw.mm_describe (
  model STRING,
  resolution STRING,
  run_no INT64,
  creative_id STRING,
  description STRING,
  prompt_tokens INT64,
  output_tokens INT64,
  status STRING,
  created_at TIMESTAMP
)
OPTIONS (description = 'Day 14 Gemini 看圖自由描述：一列＝模型 × 解析度 × 第幾次 × 一張圖');

-- 第 1、2 輪：gemini-3.5-flash-lite、預設解析度，同一個題目問兩次
INSERT INTO martech_dw.mm_describe
SELECT 'gemini-3.5-flash-lite', 'default', run_no, creative_id,
  g.result,
  CAST(JSON_VALUE(g.full_response, '$.usage_metadata.prompt_token_count') AS INT64),
  CAST(JSON_VALUE(g.full_response, '$.usage_metadata.candidates_token_count') AS INT64),
  g.status, CURRENT_TIMESTAMP()
FROM (
  SELECT run_no, d.creative_id,
    AI.GENERATE(
      (prompt_text, o.ref),
      connection_id => 'us.vertex_ai_conn',
      endpoint => 'gemini-3.5-flash-lite',
      model_params => JSON '{"generation_config": {"max_output_tokens": 1024, "thinking_config": {"thinking_budget": 0}}}'
    ) AS g
  FROM martech_dw.obj_creatives o
  JOIN martech_dw.mm_demo d USING (uri)
  CROSS JOIN UNNEST([1, 2]) AS run_no
);

-- 第 3 輪：gemini-3.6-flash、預設解析度，對照一次
INSERT INTO martech_dw.mm_describe
SELECT 'gemini-3.6-flash', 'default', 1, creative_id,
  g.result,
  CAST(JSON_VALUE(g.full_response, '$.usage_metadata.prompt_token_count') AS INT64),
  CAST(JSON_VALUE(g.full_response, '$.usage_metadata.candidates_token_count') AS INT64),
  g.status, CURRENT_TIMESTAMP()
FROM (
  SELECT d.creative_id,
    AI.GENERATE(
      (prompt_text, o.ref),
      connection_id => 'us.vertex_ai_conn',
      endpoint => 'gemini-3.6-flash',
      model_params => JSON '{"generation_config": {"max_output_tokens": 1024, "thinking_config": {"thinking_budget": 0}}}'
    ) AS g
  FROM martech_dw.obj_creatives o
  JOIN martech_dw.mm_demo d USING (uri)
);

-- 第 4 輪：gemini-3.5-flash-lite、低解析度
INSERT INTO martech_dw.mm_describe
SELECT 'gemini-3.5-flash-lite', 'low', 1, creative_id,
  g.result,
  CAST(JSON_VALUE(g.full_response, '$.usage_metadata.prompt_token_count') AS INT64),
  CAST(JSON_VALUE(g.full_response, '$.usage_metadata.candidates_token_count') AS INT64),
  g.status, CURRENT_TIMESTAMP()
FROM (
  SELECT d.creative_id,
    AI.GENERATE(
      (prompt_text, o.ref),
      connection_id => 'us.vertex_ai_conn',
      endpoint => 'gemini-3.5-flash-lite',
      model_params => JSON '{"generation_config": {"max_output_tokens": 1024, "media_resolution": "MEDIA_RESOLUTION_LOW", "thinking_config": {"thinking_budget": 0}}}'
    ) AS g
  FROM martech_dw.obj_creatives o
  JOIN martech_dw.mm_demo d USING (uri)
);

SELECT model, resolution, run_no,
  COUNT(*) AS images,
  COUNTIF(status = '') AS ok,
  SUM(prompt_tokens) AS input_tokens,
  SUM(output_tokens) AS output_tokens
FROM martech_dw.mm_describe
GROUP BY 1, 2, 3
ORDER BY 1, 2, 3;
