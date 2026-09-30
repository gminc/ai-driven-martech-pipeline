-- Day 16：讓 Gemini 一口氣看完物件表裡的全部素材圖，每張交出五個固定欄位
-- 寫法沿用 Day 15 的 B 輪：AI.GENERATE 的 output_schema 鎖型別，題目加判斷標準，gemini-3.5-flash-lite
-- 每張圖看兩次：預設解析度（寫進特徵表）與低解析度（只拿來對照能不能省錢）
--
-- 放大到整批時多做三件事：
--   1. 跑過的不重跑：每次呼叫都記進 mm_features_log，只挑「還沒有成功紀錄」的圖 × 解析度去呼叫，
--      同一段 SQL 執行第二次，成功過的圖不會再花錢，失敗的圖會自動補跑
--   2. 超出選項的只補那幾張：output_schema 只能鎖型別，萬一預設解析度回來的值不在選項裡，
--      只把那幾張改用 response_schema 的 enum 再問一次，沒有就是 0 次呼叫
--   3. 花了多少要記下來：每一次呼叫都抄一份進共用的 Token 用量表 ops_llm_usage，Day 25 的監控從這張表讀
--
-- 這一步會產生 Token 費用，run.sh 會先印出最壞情況的費用再問要不要繼續，只讀 martech_dw，不讀答案表，對答案在 report.sql
-- endpoint 與 model_params 只能寫常數，所以兩種解析度各寫一段

DECLARE this_run STRING DEFAULT GENERATE_UUID();  -- 變數名稱不能和欄位 run_id 同名，否則 WHERE 會比到欄位自己
DECLARE prompt_b STRING DEFAULT '''這是一張電商廣告圖，請看圖回答下面五個欄位：
has_person：圖中有沒有真人，true 或 false
cta_position：行動按鈕的位置，只能填 center、bottom_right、none 其中一個
dominant_color：整張圖的主色調，只能填 warm、cool、neutral 其中一個
text_density：圖上文字的多寡，只能填 low、high 其中一個
headline：圖上最大的一行標題文字，照原文抄
判斷標準：
cta_position 看有沒有寫著「立即選購」的深色按鈕，按鈕在畫面下方正中間填 center，在右下角填 bottom_right，沒有按鈕填 none
dominant_color 看背景和大面積的顏色，橘、磚紅、赤陶、奶茶這類填 warm，藍、灰藍、青這類填 cool，白、米白、亞麻、淺灰、黑這類填 neutral，商品本身的顏色不算
text_density 圖上只有一行標題（有沒有按鈕都不算）填 low，標題之外還有賣點文字或圓形標籤填 high
headline 只抄最大的那一行標題，不含賣點、標籤與按鈕上的字''';

-- 呼叫紀錄：每一次呼叫一列，成功失敗都留著，不會被重建（CREATE IF NOT EXISTS）
CREATE TABLE IF NOT EXISTS martech_dw.mm_features_log (
  run_id STRING,
  resolution STRING,
  method STRING,
  model STRING,
  creative_id STRING,
  has_person BOOL,
  cta_position STRING,
  dominant_color STRING,
  text_density STRING,
  headline STRING,
  prompt_tokens INT64,
  output_tokens INT64,
  status STRING,
  created_at TIMESTAMP
)
OPTIONS (description = 'Day 16 看圖呼叫紀錄：一列＝一次呼叫（圖 × 解析度），成功失敗都保留，extract.sql 只補沒有成功紀錄的圖');

-- 共用的 Token 用量表：之後每一天呼叫 Gemini 都寫一份進來，Day 25 做監控與成本儀表板
CREATE TABLE IF NOT EXISTS martech_dw.ops_llm_usage (
  logged_at TIMESTAMP,
  day STRING,
  job STRING,
  run_id STRING,
  model STRING,
  endpoint_type STRING,
  media_resolution STRING,
  item_id STRING,
  prompt_tokens INT64,
  output_tokens INT64,
  status STRING
)
PARTITION BY DATE(logged_at)
OPTIONS (description = '共用 Gemini Token 用量表：一列＝一次呼叫，Day 16 起累積，Day 25 監控與成本用，單價不存在這裡，計費時再依 model 與 endpoint_type 對照');

-- 「成功」的定義（extract、mart、check 與 run.sh 都用同一條）：
--   status 是空字串，而且五個欄位都有值、標題不是空字串
-- 這次要看的圖：物件表裡每一張圖 × 兩種解析度，扣掉已經有成功紀錄的
CREATE TEMP TABLE done AS
SELECT DISTINCT creative_id, resolution
FROM martech_dw.mm_features_log
WHERE status = '' AND has_person IS NOT NULL AND cta_position IS NOT NULL AND dominant_color IS NOT NULL
    AND text_density IS NOT NULL AND headline IS NOT NULL AND headline != '';

CREATE TEMP TABLE todo AS
SELECT a.uri, a.creative_id, a.resolution
FROM (
  SELECT o.uri, REGEXP_EXTRACT(o.uri, r'/([^/]+)\.jpg$') AS creative_id, res AS resolution
  FROM martech_dw.obj_creatives o
  CROSS JOIN UNNEST(['default', 'low']) AS res
) a
LEFT JOIN done d USING (creative_id, resolution)
WHERE d.creative_id IS NULL;

-- 預設解析度：這一輪的結果會寫進特徵表
INSERT INTO martech_dw.mm_features_log (run_id, resolution, method, model, creative_id, has_person, cta_position, dominant_color, text_density, headline, prompt_tokens, output_tokens, status, created_at)
SELECT this_run, 'default', 'output_schema', 'gemini-3.5-flash-lite', creative_id,
  g.has_person, g.cta_position, g.dominant_color, g.text_density, g.headline,
  CAST(JSON_VALUE(g.full_response, '$.usage_metadata.prompt_token_count') AS INT64),
  CAST(JSON_VALUE(g.full_response, '$.usage_metadata.candidates_token_count') AS INT64),
  g.status, CURRENT_TIMESTAMP()
FROM (
  SELECT t.creative_id,
    AI.GENERATE(
      (prompt_b, o.ref),
      connection_id => 'us.vertex_ai_conn',
      endpoint => 'gemini-3.5-flash-lite',
      output_schema => 'has_person BOOL, cta_position STRING, dominant_color STRING, text_density STRING, headline STRING',
      model_params => JSON '{"generation_config": {"max_output_tokens": 256, "thinking_config": {"thinking_budget": 0}}}'
    ) AS g
  FROM martech_dw.obj_creatives o
  JOIN todo t ON t.uri = o.uri AND t.resolution = 'default'
);

-- 低解析度：題目、鎖法、模型都一樣，只多一個 media_resolution，拿來和預設解析度對照
INSERT INTO martech_dw.mm_features_log (run_id, resolution, method, model, creative_id, has_person, cta_position, dominant_color, text_density, headline, prompt_tokens, output_tokens, status, created_at)
SELECT this_run, 'low', 'output_schema', 'gemini-3.5-flash-lite', creative_id,
  g.has_person, g.cta_position, g.dominant_color, g.text_density, g.headline,
  CAST(JSON_VALUE(g.full_response, '$.usage_metadata.prompt_token_count') AS INT64),
  CAST(JSON_VALUE(g.full_response, '$.usage_metadata.candidates_token_count') AS INT64),
  g.status, CURRENT_TIMESTAMP()
FROM (
  SELECT t.creative_id,
    AI.GENERATE(
      (prompt_b, o.ref),
      connection_id => 'us.vertex_ai_conn',
      endpoint => 'gemini-3.5-flash-lite',
      output_schema => 'has_person BOOL, cta_position STRING, dominant_color STRING, text_density STRING, headline STRING',
      model_params => JSON '{"generation_config": {"max_output_tokens": 256, "media_resolution": "MEDIA_RESOLUTION_LOW", "thinking_config": {"thinking_budget": 0}}}'
    ) AS g
  FROM martech_dw.obj_creatives o
  JOIN todo t ON t.uri = o.uri AND t.resolution = 'low'
);

-- 補救：預設解析度成功了、但有值不在選項裡的圖，改用 response_schema 的 enum 再問一次
-- 已經有 enum 成功紀錄的不再問，全部都在選項裡時這一段是 0 次呼叫
CREATE TEMP TABLE off_option AS
SELECT DISTINCT l.creative_id
FROM martech_dw.mm_features_log l
WHERE l.resolution = 'default' AND l.method = 'output_schema' AND l.status = ''
  AND (l.cta_position NOT IN ('center', 'bottom_right', 'none')
       OR l.dominant_color NOT IN ('warm', 'cool', 'neutral')
       OR l.text_density NOT IN ('low', 'high'))
  AND l.creative_id NOT IN (
    SELECT creative_id FROM martech_dw.mm_features_log
    WHERE resolution = 'default' AND method = 'response_schema'
      AND status = '' AND has_person IS NOT NULL AND cta_position IS NOT NULL AND dominant_color IS NOT NULL
    AND text_density IS NOT NULL AND headline IS NOT NULL AND headline != ''
  );

INSERT INTO martech_dw.mm_features_log (run_id, resolution, method, model, creative_id, has_person, cta_position, dominant_color, text_density, headline, prompt_tokens, output_tokens, status, created_at)
SELECT this_run, 'default', 'response_schema', 'gemini-3.5-flash-lite', creative_id,
  SAFE_CAST(JSON_VALUE(g.result, '$.has_person') AS BOOL),
  JSON_VALUE(g.result, '$.cta_position'),
  JSON_VALUE(g.result, '$.dominant_color'),
  JSON_VALUE(g.result, '$.text_density'),
  JSON_VALUE(g.result, '$.headline'),
  CAST(JSON_VALUE(g.full_response, '$.usage_metadata.prompt_token_count') AS INT64),
  CAST(JSON_VALUE(g.full_response, '$.usage_metadata.candidates_token_count') AS INT64),
  g.status, CURRENT_TIMESTAMP()
FROM (
  SELECT f.creative_id,
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
  JOIN off_option f ON o.uri LIKE CONCAT('%/', f.creative_id, '.jpg')
);

-- 呼叫紀錄抄一份進共用用量表：抄所有還沒抄過的執行，萬一上一次執行在中途出錯、沒抄到，這一次會補上
INSERT INTO martech_dw.ops_llm_usage (logged_at, day, job, run_id, model, endpoint_type, media_resolution, item_id, prompt_tokens, output_tokens, status)
SELECT created_at, 'Day 16', 'features/extract.sql', run_id, model, 'non-global',
  resolution, creative_id, prompt_tokens, output_tokens, status
FROM martech_dw.mm_features_log
WHERE run_id NOT IN (
  SELECT DISTINCT run_id FROM martech_dw.ops_llm_usage
  WHERE job = 'features/extract.sql' AND run_id IS NOT NULL
);

-- 這次執行呼叫了幾次（第二次執行時，成功過的圖不會再呼叫）
SELECT run_id, resolution, method,
  COUNT(*) AS calls,
  COUNTIF(status = '') AS ok,
  COUNTIF(status != '') AS failed,
  SUM(prompt_tokens) AS input_tokens,
  SUM(output_tokens) AS output_tokens
FROM martech_dw.mm_features_log
WHERE run_id = this_run
GROUP BY 1, 2, 3
ORDER BY 2, 3;
