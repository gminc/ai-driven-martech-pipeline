-- Day 15：讓 Gemini 看一張圖交出固定欄位，六張樣本圖各跑五輪，共 30 次呼叫
-- 兩種鎖格式的寫法：
--   output_schema    ：AI.GENERATE 的參數，回來直接是欄位（BOOL、STRING），可以馬上 GROUP BY，但只能鎖型別，不能限定 STRING 只能填哪幾個值
--   response_schema  ：model_params 裡的 Gemini 設定，可以用 enum 限定選項，回來是一段 JSON 字串，要再用 JSON_VALUE 解析
-- 五輪：
--   A  output_schema、題目只列欄位與選項                     gemini-3.5-flash-lite
--   B1 output_schema、題目加上判斷標準                        gemini-3.5-flash-lite（和 A 只差題目，看判斷標準有沒有用）
--   B2 同 B1 再跑一次                                          gemini-3.5-flash-lite（同一張圖問兩次，看答案一不一樣）
--   C  response_schema（enum）、題目同 B                       gemini-3.5-flash-lite（和 B 只差鎖法，看 enum 有沒有用）
--   D  同 C 換模型                                             gemini-3.6-flash
-- endpoint 與 model_params 只能寫常數，所以每輪各寫一段
-- 這一步會產生 Token 費用，run.sh 會先印出最壞情況的費用再問要不要繼續，只讀 martech_dw，不讀答案表，對答案在 report.sql

DECLARE prompt_a STRING DEFAULT '''這是一張電商廣告圖，請看圖回答下面五個欄位：
has_person：圖中有沒有真人，true 或 false
cta_position：行動按鈕的位置，只能填 center、bottom_right、none 其中一個
dominant_color：整張圖的主色調，只能填 warm、cool、neutral 其中一個
text_density：圖上文字的多寡，只能填 low、high 其中一個
headline：圖上最大的一行標題文字，照原文抄''';

DECLARE prompt_b STRING DEFAULT CONCAT(prompt_a, '''
判斷標準：
cta_position 看有沒有寫著「立即選購」的深色按鈕，按鈕在畫面下方正中間填 center，在右下角填 bottom_right，沒有按鈕填 none
dominant_color 看背景和大面積的顏色，橘、磚紅、赤陶、奶茶這類填 warm，藍、灰藍、青這類填 cool，白、米白、亞麻、淺灰、黑這類填 neutral，商品本身的顏色不算
text_density 圖上只有一行標題（有沒有按鈕都不算）填 low，標題之外還有賣點文字或圓形標籤填 high
headline 只抄最大的那一行標題，不含賣點、標籤與按鈕上的字''');

CREATE OR REPLACE TABLE martech_dw.mm_structured (
  round STRING,
  method STRING,
  model STRING,
  run_no INT64,
  creative_id STRING,
  has_person BOOL,
  cta_position STRING,
  dominant_color STRING,
  text_density STRING,
  headline STRING,
  raw_output STRING,
  prompt_tokens INT64,
  output_tokens INT64,
  status STRING,
  created_at TIMESTAMP
)
OPTIONS (description = 'Day 15 Gemini 看圖結構化抽取：一列＝輪 × 一張圖，四個設計欄位加標題，raw_output 是模型原始回覆');

-- A：output_schema、題目只列欄位與選項
INSERT INTO martech_dw.mm_structured
SELECT 'A', 'output_schema', 'gemini-3.5-flash-lite', 1, creative_id,
  g.has_person, g.cta_position, g.dominant_color, g.text_density, g.headline,
  TO_JSON_STRING(STRUCT(g.has_person, g.cta_position, g.dominant_color, g.text_density, g.headline)),
  CAST(JSON_VALUE(g.full_response, '$.usage_metadata.prompt_token_count') AS INT64),
  CAST(JSON_VALUE(g.full_response, '$.usage_metadata.candidates_token_count') AS INT64),
  g.status, CURRENT_TIMESTAMP()
FROM (
  SELECT s.creative_id,
    AI.GENERATE(
      (prompt_a, o.ref),
      connection_id => 'us.vertex_ai_conn',
      endpoint => 'gemini-3.5-flash-lite',
      output_schema => 'has_person BOOL, cta_position STRING, dominant_color STRING, text_density STRING, headline STRING',
      model_params => JSON '{"generation_config": {"max_output_tokens": 256, "thinking_config": {"thinking_budget": 0}}}'
    ) AS g
  FROM martech_dw.obj_creatives o
  JOIN martech_dw.mm_sample s USING (uri)
);

-- B1、B2：output_schema、題目加判斷標準，同一張圖問兩次
INSERT INTO martech_dw.mm_structured
SELECT CONCAT('B', run_no), 'output_schema', 'gemini-3.5-flash-lite', run_no, creative_id,
  g.has_person, g.cta_position, g.dominant_color, g.text_density, g.headline,
  TO_JSON_STRING(STRUCT(g.has_person, g.cta_position, g.dominant_color, g.text_density, g.headline)),
  CAST(JSON_VALUE(g.full_response, '$.usage_metadata.prompt_token_count') AS INT64),
  CAST(JSON_VALUE(g.full_response, '$.usage_metadata.candidates_token_count') AS INT64),
  g.status, CURRENT_TIMESTAMP()
FROM (
  SELECT run_no, s.creative_id,
    AI.GENERATE(
      (prompt_b, o.ref),
      connection_id => 'us.vertex_ai_conn',
      endpoint => 'gemini-3.5-flash-lite',
      output_schema => 'has_person BOOL, cta_position STRING, dominant_color STRING, text_density STRING, headline STRING',
      model_params => JSON '{"generation_config": {"max_output_tokens": 256, "thinking_config": {"thinking_budget": 0}}}'
    ) AS g
  FROM martech_dw.obj_creatives o
  JOIN martech_dw.mm_sample s USING (uri)
  CROSS JOIN UNNEST([1, 2]) AS run_no
);

-- C：response_schema 用 enum 鎖選項、題目同 B，回來是 JSON 字串
INSERT INTO martech_dw.mm_structured
SELECT 'C', 'response_schema', 'gemini-3.5-flash-lite', 1, creative_id,
  SAFE_CAST(JSON_VALUE(g.result, '$.has_person') AS BOOL),
  JSON_VALUE(g.result, '$.cta_position'),
  JSON_VALUE(g.result, '$.dominant_color'),
  JSON_VALUE(g.result, '$.text_density'),
  JSON_VALUE(g.result, '$.headline'),
  g.result,
  CAST(JSON_VALUE(g.full_response, '$.usage_metadata.prompt_token_count') AS INT64),
  CAST(JSON_VALUE(g.full_response, '$.usage_metadata.candidates_token_count') AS INT64),
  g.status, CURRENT_TIMESTAMP()
FROM (
  SELECT s.creative_id,
    AI.GENERATE(
      (prompt_b, o.ref),
      connection_id => 'us.vertex_ai_conn',
      endpoint => 'gemini-3.5-flash-lite',
      model_params => JSON '''{"generation_config": {
        "max_output_tokens": 256,
        "thinking_config": {"thinking_budget": 0},
        "response_mime_type": "application/json",
        "response_schema": {"type": "OBJECT", "properties": {
          "has_person": {"type": "BOOLEAN"},
          "cta_position": {"type": "STRING", "enum": ["center", "bottom_right", "none"]},
          "dominant_color": {"type": "STRING", "enum": ["warm", "cool", "neutral"]},
          "text_density": {"type": "STRING", "enum": ["low", "high"]},
          "headline": {"type": "STRING"}
        }, "required": ["has_person", "cta_position", "dominant_color", "text_density", "headline"]}
      }}'''
    ) AS g
  FROM martech_dw.obj_creatives o
  JOIN martech_dw.mm_sample s USING (uri)
);

-- D：同 C 換 gemini-3.6-flash
INSERT INTO martech_dw.mm_structured
SELECT 'D', 'response_schema', 'gemini-3.6-flash', 1, creative_id,
  SAFE_CAST(JSON_VALUE(g.result, '$.has_person') AS BOOL),
  JSON_VALUE(g.result, '$.cta_position'),
  JSON_VALUE(g.result, '$.dominant_color'),
  JSON_VALUE(g.result, '$.text_density'),
  JSON_VALUE(g.result, '$.headline'),
  g.result,
  CAST(JSON_VALUE(g.full_response, '$.usage_metadata.prompt_token_count') AS INT64),
  CAST(JSON_VALUE(g.full_response, '$.usage_metadata.candidates_token_count') AS INT64),
  g.status, CURRENT_TIMESTAMP()
FROM (
  SELECT s.creative_id,
    AI.GENERATE(
      (prompt_b, o.ref),
      connection_id => 'us.vertex_ai_conn',
      endpoint => 'gemini-3.6-flash',
      model_params => JSON '''{"generation_config": {
        "max_output_tokens": 256,
        "thinking_config": {"thinking_budget": 0},
        "response_mime_type": "application/json",
        "response_schema": {"type": "OBJECT", "properties": {
          "has_person": {"type": "BOOLEAN"},
          "cta_position": {"type": "STRING", "enum": ["center", "bottom_right", "none"]},
          "dominant_color": {"type": "STRING", "enum": ["warm", "cool", "neutral"]},
          "text_density": {"type": "STRING", "enum": ["low", "high"]},
          "headline": {"type": "STRING"}
        }, "required": ["has_person", "cta_position", "dominant_color", "text_density", "headline"]}
      }}'''
    ) AS g
  FROM martech_dw.obj_creatives o
  JOIN martech_dw.mm_sample s USING (uri)
);

SELECT round, method, model,
  COUNT(*) AS images,
  COUNTIF(status = '') AS ok,
  SUM(prompt_tokens) AS input_tokens,
  SUM(output_tokens) AS output_tokens
FROM martech_dw.mm_structured
GROUP BY 1, 2, 3
ORDER BY 1;
