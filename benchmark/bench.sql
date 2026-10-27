-- Day 20：同一份題目、同一份答案，換不同等級的模型各做一次，看便宜的輕量模型夠不夠用
-- 兩種題目 × 三個模型，其中 Pro 只做難題，所以是五個組合，每個組合 24 張廣告圖：
--   features（簡單題）：看一張廣告圖填五個固定欄位，題目、鎖法與參數和 Day 16 的 features/extract.sql 預設解析度那一輪一模一樣
--   gaps（難題）    ：廣告圖加上頁面文字，列出對不上的地方，題目、鎖法與參數和 Day 19 的 consistency/compare.sql 給文字那一輪一模一樣
--   模型：gemini-3.5-flash-lite、gemini-3.8-flash、gemini-3.1-pro-preview（只做難題）
-- 每個組合換的只有 endpoint，題目、response_schema、輸出上限與思考設定都不動
-- Pro 是預覽版，us 這個位置沒有，只寫模型名稱會被 BigQuery 擋下（Unsupported endpoint），所以 endpoint 寫成 global 端點的完整網址，
-- 網址裡的 PROJECT_ID 由 run.sh 換成專案 ID，另外兩個模型只寫名稱，走的是非 global 端點
--   簡單題：output_schema、max_output_tokens 256、thinking_budget 0；Flash 有回答但欄位是空值或不在選項裡的，
--           下一次執行時比照 Day 16 的補救段改用 response_schema 的 enum 再問一次（method 記 response_schema，題目不變），
--           計分用的是補問之後的回答；flash-lite 沿用 Day 16 主要那一輪（Day 16 那一輪全部在選項裡，features/check.sql 第 6 項），
--           所以兩個模型都是「output_schema 的回答在選項裡就用，不在才看 enum」，報表 ① 會列出哪幾張是補問來的
--   難題  ：response_schema（gap_type 用 enum 鎖）、max_output_tokens 2,048（思考 Token 也算在裡面）、thinking_level LOW
-- 前幾天問過的不重問：reuse.sql 已經把 Day 16（簡單題 × flash-lite）與 Day 19（難題 × 3.8-flash）的成功紀錄抄進 mm_bench_log，
-- 這裡六段都寫（五個組合加上簡單題 × Flash 的 enum 補問），但只會呼叫「還沒有成功紀錄」的，所以第一次執行實際上只呼叫三個組合，
-- 全部成功時執行第二次是 0 次；簡單題 × Flash 有回答但不算成功的那幾張，第二次執行會改用 enum 補問
-- 直接用 bq query 執行時，要先把 PROJECT_ID 換成自己的專案 ID
-- @batch_limit：每個組合這次最多呼叫幾張，run.sh 先用 1 試一張（確認模型叫得動、看實際用掉多少 Token），再用 24 跑完
-- 這一步會產生 Token 費用，run.sh 會先印出估價再問要不要繼續
-- 只讀 martech_dw，不讀答案表，對答案在 score.sql，run.sh 會在呼叫之前檢查
-- endpoint 與 model_params 只能寫常數，所以五個組合各寫一段

DECLARE this_run STRING DEFAULT GENERATE_UUID();
DECLARE batch_limit INT64 DEFAULT @batch_limit;  -- 直接用 bq query 執行時要加 --parameter=batch_limit:INT64:24

-- 簡單題的題目：和 features/extract.sql 的 prompt_b 一字不差
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

-- 難題的題目：和 consistency/compare.sql 的 task_text 一字不差
DECLARE task_text STRING DEFAULT '''請找出「廣告上有寫，但頁面上找不到或說法不同」的地方，客人看了廣告點進來會覺得對不上的那種。

先把廣告圖上看得到的每一段文字照原文抄進 ad_texts，再把落差一項一項列在 gaps 裡，每一項三個欄位：
gap_type：落差的種類，只能填下面八個其中一個
  limited_offer：廣告寫限定、限量或限時，頁面沒有對應的說明
  special_price：廣告寫專案價、優惠價或折扣，頁面沒有對應的優惠
  free_shipping：廣告寫免運，頁面沒有寫，或頁面寫的條件和廣告不同
  gift：廣告寫贈品或加贈，頁面沒有對應的說明
  warranty：廣告寫保固、鑑賞期或退換貨承諾，頁面沒有對應的說明
  product_name：廣告上的商品名稱或款式，和頁面上的商品對不上
  product_option：廣告寫了顏色或尺寸可以選，頁面沒有提到
  other：不屬於上面七種的落差
ad_text：廣告上的那幾個字，照原文抄
page_evidence：頁面上相關的原文，頁面完全沒有提到就填「頁面沒有提到」

只列有落差的地方，廣告和頁面一致就不用列，都一致時 gaps 回空陣列
形容觸感、質感或使用感受的文案不用列''';

DECLARE features_version STRING DEFAULT TO_HEX(MD5(prompt_b));
DECLARE gaps_version STRING DEFAULT TO_HEX(MD5(task_text));

-- 題目只要被動到一個字，指紋就會不同，在呼叫之前就停下來
ASSERT features_version = 'd53bb63969eaa3a6febf02caaacdeb6a' AS '簡單題的題目和 Day 16 的 features/extract.sql 不一樣';
ASSERT gaps_version = '9a7497b1ba445523991489428b9b0af3' AS '難題的題目和 Day 19 的 consistency/compare.sql 不一樣';

-- method：這次呼叫的鎖法，空值是主要那一輪（簡單題 output_schema、難題 response_schema），response_schema 是簡單題用 enum 補問的那一次
ALTER TABLE martech_dw.mm_bench_log ADD COLUMN IF NOT EXISTS method STRING
  OPTIONS (description = '空值＝主要那一輪；response_schema＝簡單題 × Flash 主要那一輪有回答但有欄位是空值或不在選項裡，改用 enum 補問的那一次');

-- 這次要問的：五個組合 × 24 張廣告圖，扣掉已經有成功紀錄的與不再問的，每個組合最多取 batch_limit 張
CREATE TEMP TABLE todo AS
SELECT task, model, creative_id, page_id, page_text, intro
FROM (
  SELECT c.task, c.model, m.creative_id, m.page_id, p.page_text,
    FORMAT('你是電商品牌「織日常」的廣告審查員。客人在 %s 看到附上的廣告圖，點下去之後會到官網的「%s」。', m.channel, p.title) AS intro,
    ROW_NUMBER() OVER (PARTITION BY c.task, c.model ORDER BY m.creative_id) AS rn
  FROM UNNEST([
    STRUCT('features' AS task, 'gemini-3.5-flash-lite' AS model),
    STRUCT('features', 'gemini-3.8-flash'),
    STRUCT('gaps', 'gemini-3.5-flash-lite'),
    STRUCT('gaps', 'gemini-3.8-flash'),
    STRUCT('gaps', 'gemini-3.1-pro-preview')
  ]) AS c
  CROSS JOIN martech_dw.map_creative_landing m
  JOIN martech_dw.ref_landing_pages p USING (page_id)
  LEFT JOIN (SELECT DISTINCT task, model, creative_id FROM martech_dw.mm_bench_log WHERE ok) d
    ON d.task = c.task AND d.model = c.model AND d.creative_id = m.creative_id
  -- 同一張圖在同一個組合已經有兩次「模型有回答、但不算成功」（例如每次都被輸出上限截斷）就不再問，免得每跑一次就再付一次錢，
  -- check.sql 會顯示這個組合沒有做完，呼叫本身出錯的（status 不是空字串，例如沒有權限或被限流，這種不收費）不算在內，下次照樣重問
  LEFT JOIN (SELECT task, model, creative_id FROM martech_dw.mm_bench_log
             WHERE source = 'day20' AND NOT ok AND status = '' GROUP BY 1, 2, 3 HAVING COUNT(*) >= 2) x
    ON x.task = c.task AND x.model = c.model AND x.creative_id = m.creative_id
  -- 簡單題 × Flash：主要那一輪已經有回答、但不算成功的圖，不再用 output_schema 問，改由下面的 enum_todo 補問
  LEFT JOIN (SELECT DISTINCT creative_id FROM martech_dw.mm_bench_log
             WHERE source = 'day20' AND task = 'features' AND model = 'gemini-3.8-flash'
               AND NOT ok AND status = '' AND method IS NULL) a
    ON c.task = 'features' AND c.model = 'gemini-3.8-flash' AND a.creative_id = m.creative_id
  WHERE d.creative_id IS NULL AND x.creative_id IS NULL AND a.creative_id IS NULL
)
WHERE rn <= batch_limit;

-- 簡單題 × Flash 要用 enum 補問的圖（和 Day 16 features/extract.sql 的補救段同一個做法、同一段 response_schema）：
-- 主要那一輪（output_schema）有回答、但有欄位是空值或不在選項裡，還沒有成功紀錄，也還沒有用 enum 問到回答的
-- 在任何呼叫之前就算好，所以一次執行裡每張圖只會被呼叫一次（主要那一輪或 enum 其中一個），run.sh 的估價與第 18 項檢查都照這個算
-- enum 呼叫本身出錯（status 不是空字串，例如被限流，這種不收費）的下次照樣重問；enum 有回答但還是不算成功的就不再問
-- 2026-10-25 實測 gemini-3.8-flash 用 output_schema 時，24 張有 16 張把 cta_position、dominant_color 回成空值（flash-lite 沒有這個情況）
CREATE TEMP TABLE enum_todo AS
SELECT creative_id
FROM (
  SELECT l.creative_id, ROW_NUMBER() OVER (ORDER BY l.creative_id) AS rn
  FROM (SELECT DISTINCT creative_id FROM martech_dw.mm_bench_log
        WHERE source = 'day20' AND task = 'features' AND model = 'gemini-3.8-flash'
          AND NOT ok AND status = '' AND method IS NULL) l
  JOIN martech_dw.map_creative_landing m ON m.creative_id = l.creative_id
  JOIN martech_dw.ref_landing_pages p ON p.page_id = m.page_id
  WHERE NOT EXISTS (
    SELECT 1 FROM martech_dw.mm_bench_log k
    WHERE k.task = 'features' AND k.model = 'gemini-3.8-flash' AND k.creative_id = l.creative_id
      AND (k.ok OR (k.method = 'response_schema' AND k.status = '')))
)
WHERE rn <= batch_limit;

-- 簡單題 × gemini-3.5-flash-lite
INSERT INTO martech_dw.mm_bench_log (run_id, task, model, creative_id, page_id, result,
  prompt_tokens, output_tokens, thoughts_tokens, finish_reason, status, created_at, source, prompt_version, ok)
SELECT this_run, 'features', 'gemini-3.5-flash-lite', creative_id, CAST(NULL AS STRING),
  TO_JSON_STRING(STRUCT(g.has_person AS has_person, g.cta_position AS cta_position, g.dominant_color AS dominant_color,
    g.text_density AS text_density, g.headline AS headline)),
  SAFE_CAST(JSON_VALUE(g.full_response, '$.usage_metadata.prompt_token_count') AS INT64),
  SAFE_CAST(JSON_VALUE(g.full_response, '$.usage_metadata.candidates_token_count') AS INT64),
  SAFE_CAST(JSON_VALUE(g.full_response, '$.usage_metadata.thoughts_token_count') AS INT64),
  JSON_VALUE(g.full_response, '$.candidates[0].finish_reason'),
  g.status, CURRENT_TIMESTAMP(), 'day20', features_version,
  IFNULL(g.status = '' AND g.has_person IS NOT NULL AND g.cta_position IN ('center', 'bottom_right', 'none')
    AND g.dominant_color IN ('warm', 'cool', 'neutral') AND g.text_density IN ('low', 'high')
    AND g.headline IS NOT NULL AND g.headline != '', FALSE)
FROM (
  SELECT t.creative_id,
    AI.GENERATE(
      (prompt_b, o.ref),
      connection_id => 'us.vertex_ai_conn',
      endpoint => 'gemini-3.5-flash-lite',
      output_schema => 'has_person BOOL, cta_position STRING, dominant_color STRING, text_density STRING, headline STRING',
      model_params => JSON '{"generation_config": {"max_output_tokens": 256, "thinking_config": {"thinking_budget": 0}}}'
    ) AS g
  FROM todo t
  JOIN martech_dw.obj_creatives o ON o.uri LIKE CONCAT('%/', t.creative_id, '.jpg')
  WHERE t.task = 'features' AND t.model = 'gemini-3.5-flash-lite'
);

-- 簡單題 × gemini-3.8-flash
INSERT INTO martech_dw.mm_bench_log (run_id, task, model, creative_id, page_id, result,
  prompt_tokens, output_tokens, thoughts_tokens, finish_reason, status, created_at, source, prompt_version, ok)
SELECT this_run, 'features', 'gemini-3.8-flash', creative_id, CAST(NULL AS STRING),
  TO_JSON_STRING(STRUCT(g.has_person AS has_person, g.cta_position AS cta_position, g.dominant_color AS dominant_color,
    g.text_density AS text_density, g.headline AS headline)),
  SAFE_CAST(JSON_VALUE(g.full_response, '$.usage_metadata.prompt_token_count') AS INT64),
  SAFE_CAST(JSON_VALUE(g.full_response, '$.usage_metadata.candidates_token_count') AS INT64),
  SAFE_CAST(JSON_VALUE(g.full_response, '$.usage_metadata.thoughts_token_count') AS INT64),
  JSON_VALUE(g.full_response, '$.candidates[0].finish_reason'),
  g.status, CURRENT_TIMESTAMP(), 'day20', features_version,
  IFNULL(g.status = '' AND g.has_person IS NOT NULL AND g.cta_position IN ('center', 'bottom_right', 'none')
    AND g.dominant_color IN ('warm', 'cool', 'neutral') AND g.text_density IN ('low', 'high')
    AND g.headline IS NOT NULL AND g.headline != '', FALSE)
FROM (
  SELECT t.creative_id,
    AI.GENERATE(
      (prompt_b, o.ref),
      connection_id => 'us.vertex_ai_conn',
      endpoint => 'gemini-3.8-flash',
      output_schema => 'has_person BOOL, cta_position STRING, dominant_color STRING, text_density STRING, headline STRING',
      model_params => JSON '{"generation_config": {"max_output_tokens": 256, "thinking_config": {"thinking_budget": 0}}}'
    ) AS g
  FROM todo t
  JOIN martech_dw.obj_creatives o ON o.uri LIKE CONCAT('%/', t.creative_id, '.jpg')
  WHERE t.task = 'features' AND t.model = 'gemini-3.8-flash'
);

-- 簡單題 × Flash 的 enum 補問（要問哪幾張在上面的 enum_todo，呼叫之前就算好了）
INSERT INTO martech_dw.mm_bench_log (run_id, task, model, creative_id, page_id, result,
  prompt_tokens, output_tokens, thoughts_tokens, finish_reason, status, created_at, source, prompt_version, ok, method)
SELECT this_run, 'features', 'gemini-3.8-flash', creative_id, CAST(NULL AS STRING),
  TO_JSON_STRING(STRUCT(has_person, cta_position, dominant_color, text_density, headline)),
  prompt_tokens, output_tokens, thoughts_tokens, finish_reason, status, CURRENT_TIMESTAMP(), 'day20', features_version,
  IFNULL(status = '' AND has_person IS NOT NULL
    AND cta_position IN ('center', 'bottom_right', 'none')
    AND dominant_color IN ('warm', 'cool', 'neutral')
    AND text_density IN ('low', 'high')
    AND headline IS NOT NULL AND headline != '', FALSE),
  'response_schema'
FROM (
  SELECT x.creative_id,
    SAFE_CAST(JSON_VALUE(x.g.result, '$.has_person') AS BOOL) AS has_person,
    JSON_VALUE(x.g.result, '$.cta_position') AS cta_position,
    JSON_VALUE(x.g.result, '$.dominant_color') AS dominant_color,
    JSON_VALUE(x.g.result, '$.text_density') AS text_density,
    JSON_VALUE(x.g.result, '$.headline') AS headline,
    SAFE_CAST(JSON_VALUE(x.g.full_response, '$.usage_metadata.prompt_token_count') AS INT64) AS prompt_tokens,
    SAFE_CAST(JSON_VALUE(x.g.full_response, '$.usage_metadata.candidates_token_count') AS INT64) AS output_tokens,
    SAFE_CAST(JSON_VALUE(x.g.full_response, '$.usage_metadata.thoughts_token_count') AS INT64) AS thoughts_tokens,
    JSON_VALUE(x.g.full_response, '$.candidates[0].finish_reason') AS finish_reason,
    x.g.status AS status
  FROM (
    SELECT e.creative_id,
      AI.GENERATE(
        (prompt_b, o.ref),
        connection_id => 'us.vertex_ai_conn',
        endpoint => 'gemini-3.8-flash',
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
    FROM enum_todo e
    JOIN martech_dw.obj_creatives o ON o.uri LIKE CONCAT('%/', e.creative_id, '.jpg')
  ) x
);

-- 難題 × gemini-3.5-flash-lite
INSERT INTO martech_dw.mm_bench_log (run_id, task, model, creative_id, page_id, result,
  prompt_tokens, output_tokens, thoughts_tokens, finish_reason, status, created_at, source, prompt_version, ok)
SELECT this_run, 'gaps', 'gemini-3.5-flash-lite', creative_id, page_id, g.result,
  SAFE_CAST(JSON_VALUE(g.full_response, '$.usage_metadata.prompt_token_count') AS INT64),
  SAFE_CAST(JSON_VALUE(g.full_response, '$.usage_metadata.candidates_token_count') AS INT64),
  SAFE_CAST(JSON_VALUE(g.full_response, '$.usage_metadata.thoughts_token_count') AS INT64),
  JSON_VALUE(g.full_response, '$.candidates[0].finish_reason'),
  g.status, CURRENT_TIMESTAMP(), 'day20', gaps_version,
  IFNULL(g.status = '' AND IFNULL(JSON_VALUE(g.full_response, '$.candidates[0].finish_reason'), '') != 'MAX_TOKENS'
    AND JSON_QUERY_ARRAY(SAFE.PARSE_JSON(g.result), '$.gaps') IS NOT NULL, FALSE)
FROM (
  SELECT t.creative_id, t.page_id,
    AI.GENERATE(
      (CONCAT(t.intro, '附上的圖是廣告圖，那個頁面上看得到的文字放在最後面。\n\n', task_text,
        '\n\n頁面上的文字（由上到下）：\n', t.page_text), a.ref),
      connection_id => 'us.vertex_ai_conn',
      endpoint => 'gemini-3.5-flash-lite',
      model_params => JSON '''{"generation_config": {
        "max_output_tokens": 2048,
        "thinking_config": {"thinking_level": "LOW"},
        "response_mime_type": "application/json",
        "response_schema": {"type": "OBJECT", "properties": {
          "ad_texts": {"type": "ARRAY", "items": {"type": "STRING"}},
          "gaps": {"type": "ARRAY", "items": {"type": "OBJECT", "properties": {
            "gap_type": {"type": "STRING", "enum": ["limited_offer", "special_price", "free_shipping", "gift", "warranty", "product_name", "product_option", "other"]},
            "ad_text": {"type": "STRING"},
            "page_evidence": {"type": "STRING"}
          }, "required": ["gap_type", "ad_text", "page_evidence"]}}
        }, "required": ["ad_texts", "gaps"]}
      }}'''
    ) AS g
  FROM todo t
  JOIN martech_dw.obj_creatives a ON a.uri LIKE CONCAT('%/', t.creative_id, '.jpg')
  WHERE t.task = 'gaps' AND t.model = 'gemini-3.5-flash-lite'
);

-- 難題 × gemini-3.8-flash
INSERT INTO martech_dw.mm_bench_log (run_id, task, model, creative_id, page_id, result,
  prompt_tokens, output_tokens, thoughts_tokens, finish_reason, status, created_at, source, prompt_version, ok)
SELECT this_run, 'gaps', 'gemini-3.8-flash', creative_id, page_id, g.result,
  SAFE_CAST(JSON_VALUE(g.full_response, '$.usage_metadata.prompt_token_count') AS INT64),
  SAFE_CAST(JSON_VALUE(g.full_response, '$.usage_metadata.candidates_token_count') AS INT64),
  SAFE_CAST(JSON_VALUE(g.full_response, '$.usage_metadata.thoughts_token_count') AS INT64),
  JSON_VALUE(g.full_response, '$.candidates[0].finish_reason'),
  g.status, CURRENT_TIMESTAMP(), 'day20', gaps_version,
  IFNULL(g.status = '' AND IFNULL(JSON_VALUE(g.full_response, '$.candidates[0].finish_reason'), '') != 'MAX_TOKENS'
    AND JSON_QUERY_ARRAY(SAFE.PARSE_JSON(g.result), '$.gaps') IS NOT NULL, FALSE)
FROM (
  SELECT t.creative_id, t.page_id,
    AI.GENERATE(
      (CONCAT(t.intro, '附上的圖是廣告圖，那個頁面上看得到的文字放在最後面。\n\n', task_text,
        '\n\n頁面上的文字（由上到下）：\n', t.page_text), a.ref),
      connection_id => 'us.vertex_ai_conn',
      endpoint => 'gemini-3.8-flash',
      model_params => JSON '''{"generation_config": {
        "max_output_tokens": 2048,
        "thinking_config": {"thinking_level": "LOW"},
        "response_mime_type": "application/json",
        "response_schema": {"type": "OBJECT", "properties": {
          "ad_texts": {"type": "ARRAY", "items": {"type": "STRING"}},
          "gaps": {"type": "ARRAY", "items": {"type": "OBJECT", "properties": {
            "gap_type": {"type": "STRING", "enum": ["limited_offer", "special_price", "free_shipping", "gift", "warranty", "product_name", "product_option", "other"]},
            "ad_text": {"type": "STRING"},
            "page_evidence": {"type": "STRING"}
          }, "required": ["gap_type", "ad_text", "page_evidence"]}}
        }, "required": ["ad_texts", "gaps"]}
      }}'''
    ) AS g
  FROM todo t
  JOIN martech_dw.obj_creatives a ON a.uri LIKE CONCAT('%/', t.creative_id, '.jpg')
  WHERE t.task = 'gaps' AND t.model = 'gemini-3.8-flash'
);

-- 難題 × gemini-3.1-pro-preview
INSERT INTO martech_dw.mm_bench_log (run_id, task, model, creative_id, page_id, result,
  prompt_tokens, output_tokens, thoughts_tokens, finish_reason, status, created_at, source, prompt_version, ok)
SELECT this_run, 'gaps', 'gemini-3.1-pro-preview', creative_id, page_id, g.result,
  SAFE_CAST(JSON_VALUE(g.full_response, '$.usage_metadata.prompt_token_count') AS INT64),
  SAFE_CAST(JSON_VALUE(g.full_response, '$.usage_metadata.candidates_token_count') AS INT64),
  SAFE_CAST(JSON_VALUE(g.full_response, '$.usage_metadata.thoughts_token_count') AS INT64),
  JSON_VALUE(g.full_response, '$.candidates[0].finish_reason'),
  g.status, CURRENT_TIMESTAMP(), 'day20', gaps_version,
  IFNULL(g.status = '' AND IFNULL(JSON_VALUE(g.full_response, '$.candidates[0].finish_reason'), '') != 'MAX_TOKENS'
    AND JSON_QUERY_ARRAY(SAFE.PARSE_JSON(g.result), '$.gaps') IS NOT NULL, FALSE)
FROM (
  SELECT t.creative_id, t.page_id,
    AI.GENERATE(
      (CONCAT(t.intro, '附上的圖是廣告圖，那個頁面上看得到的文字放在最後面。\n\n', task_text,
        '\n\n頁面上的文字（由上到下）：\n', t.page_text), a.ref),
      connection_id => 'us.vertex_ai_conn',
      endpoint => 'https://aiplatform.googleapis.com/v1/projects/PROJECT_ID/locations/global/publishers/google/models/gemini-3.1-pro-preview',
      model_params => JSON '''{"generation_config": {
        "max_output_tokens": 2048,
        "thinking_config": {"thinking_level": "LOW"},
        "response_mime_type": "application/json",
        "response_schema": {"type": "OBJECT", "properties": {
          "ad_texts": {"type": "ARRAY", "items": {"type": "STRING"}},
          "gaps": {"type": "ARRAY", "items": {"type": "OBJECT", "properties": {
            "gap_type": {"type": "STRING", "enum": ["limited_offer", "special_price", "free_shipping", "gift", "warranty", "product_name", "product_option", "other"]},
            "ad_text": {"type": "STRING"},
            "page_evidence": {"type": "STRING"}
          }, "required": ["gap_type", "ad_text", "page_evidence"]}}
        }, "required": ["ad_texts", "gaps"]}
      }}'''
    ) AS g
  FROM todo t
  JOIN martech_dw.obj_creatives a ON a.uri LIKE CONCAT('%/', t.creative_id, '.jpg')
  WHERE t.task = 'gaps' AND t.model = 'gemini-3.1-pro-preview'
);

-- 這次新問的抄一份進共用用量表（沿用舊紀錄的那些，Day 16、Day 19 當天已經抄過，不再抄）
-- 思考 Token 也按輸出計費，所以 output_tokens 存「輸出＋思考」
INSERT INTO martech_dw.ops_llm_usage (logged_at, day, job, run_id, model, endpoint_type, media_resolution, item_id, prompt_tokens, output_tokens, status)
SELECT created_at, 'Day 20', 'benchmark/bench.sql', run_id, model,
  IF(model = 'gemini-3.1-pro-preview', 'global', 'non-global'), 'default',
  CONCAT(creative_id, '/', task),
  prompt_tokens, IFNULL(output_tokens, 0) + IFNULL(thoughts_tokens, 0), status
FROM martech_dw.mm_bench_log
WHERE source = 'day20'
  AND run_id NOT IN (
    SELECT DISTINCT run_id FROM martech_dw.ops_llm_usage
    WHERE job = 'benchmark/bench.sql' AND run_id IS NOT NULL
  );

-- 這次執行呼叫了幾次，失敗的附一筆錯誤訊息
SELECT task, model,
  COUNT(*) AS calls,
  COUNTIF(ok) AS ok,
  COUNTIF(NOT ok) AS failed,
  COUNTIF(finish_reason = 'MAX_TOKENS') AS cut_by_cap,
  CAST(ROUND(AVG(prompt_tokens)) AS INT64) AS avg_input,
  CAST(ROUND(AVG(output_tokens)) AS INT64) AS avg_output,
  CAST(ROUND(AVG(thoughts_tokens)) AS INT64) AS avg_thoughts,
  MAX(IFNULL(output_tokens, 0) + IFNULL(thoughts_tokens, 0)) AS max_output_and_thoughts,
  SUBSTR(ANY_VALUE(IF(status != '', status, NULL)), 1, 200) AS error_sample
FROM martech_dw.mm_bench_log
WHERE run_id = this_run
GROUP BY 1, 2
ORDER BY 1, 2;
