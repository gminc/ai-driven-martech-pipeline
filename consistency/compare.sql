-- Day 19：把廣告圖和它導去的頁面一起交給 Gemini，請它列出「廣告有寫、頁面找不到或說法不同」的地方
-- 24 張廣告圖 × 兩種給頁面的方式，各問一次，共 48 次：
--   image：一次給四張圖，第一張是廣告圖，後面三張是頁面截圖由上到下切成的三段（obj_landing）
--   text ：給廣告圖，再把頁面上的文字貼在題目裡（ref_landing_pages.page_text）
-- 兩種給法的題目一字不差，只差頁面是圖還是文字
-- 每個組合只問一次，24 張圖其實只有五種落差在重複，兩種給法差一兩格可能只是運氣，要看的是整種落差都抓不到這類大差別
-- 題目是一份檢查清單：把要查的落差種類直接列給 Gemini，量到的是「照清單查能查出幾成」，不是「它自己會不會發現」
-- 清單裡另外放了兩種答案表完全沒有的落差（gift、warranty），用來看它會不會因為清單上有就硬填
--
-- 寫法沿用 Day 18：AI.GENERATE 搭配 response_schema（gap_type 用 enum 鎖在八個選項裡），跑過的不重跑（只補還沒成功的組合），
-- 每次呼叫都記進 mm_gaps_log，再抄一份進共用的 Token 用量表 ops_llm_usage（Day 25 用）
-- 模型用 gemini-3.6-flash，thinking_level 設 LOW，思考 Token 也算在 max_output_tokens 裡，上限 2,048
-- 這一步會產生 Token 費用，run.sh 會先印出估價再問要不要繼續
-- 只讀 martech_dw（對照表、頁面文字、兩張物件表），不讀答案表，對答案在 score.sql，run.sh 會用 grep 確認
-- endpoint 與 model_params 只能寫常數、兩種給法傳進去的東西也不一樣，所以各寫一段

DECLARE this_run STRING DEFAULT GENERATE_UUID();

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

-- 題目的指紋（只涵蓋 task_text 這一段，開頭那兩句、選項的 enum、頁面文字與截圖改了不會變），跟著每一次呼叫記進紀錄表，之後看得出哪一筆是用哪一版題目問的
-- 題目改過之後要重問，請先把 mm_gaps_log 改名留存再執行，成功過的組合不會因為題目變了就自動重問
DECLARE this_prompt STRING DEFAULT TO_HEX(MD5(task_text));

-- 呼叫紀錄：每一次呼叫一列，成功失敗都留著，result 是模型回的 JSON 原文
CREATE TABLE IF NOT EXISTS martech_dw.mm_gaps_log (
  run_id          STRING,
  mode            STRING,
  creative_id     STRING,
  page_id         STRING,
  model           STRING,
  result          STRING,
  gaps            INT64,
  prompt_tokens   INT64,
  output_tokens   INT64,
  thoughts_tokens INT64,
  finish_reason   STRING,
  status          STRING,
  created_at      TIMESTAMP,
  prompt_version  STRING
)
OPTIONS (description = 'Day 19 廣告與頁面比對的呼叫紀錄：一列＝一次呼叫（廣告圖 × 給頁面的方式 image／text），成功失敗都保留，compare.sql 只補沒有成功紀錄的組合');
ALTER TABLE martech_dw.mm_gaps_log ADD COLUMN IF NOT EXISTS prompt_version STRING;  -- 萬一舊版的表已經建過

-- 共用的 Token 用量表（Day 16 建立，這裡 IF NOT EXISTS 只是保險）
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

-- 「成功」的定義（compare、score、check 與 run.sh 都用同一條）：status 是空字串、沒有被輸出上限截斷、回來的 JSON 解析得開而且有 gaps 陣列
CREATE TEMP TABLE done AS
SELECT DISTINCT creative_id, mode
FROM martech_dw.mm_gaps_log
WHERE status = '' AND IFNULL(finish_reason, '') != 'MAX_TOKENS'
  AND JSON_QUERY_ARRAY(SAFE.PARSE_JSON(result), '$.gaps') IS NOT NULL;

CREATE TEMP TABLE todo AS
SELECT m.creative_id, m.page_id, md AS mode, p.page_text,
  FORMAT('你是電商品牌「織日常」的廣告審查員。客人在 %s 看到附上的廣告圖，點下去之後會到官網的「%s」。', m.channel, p.title) AS intro
FROM martech_dw.map_creative_landing m
JOIN martech_dw.ref_landing_pages p USING (page_id)
CROSS JOIN UNNEST(['image', 'text']) AS md
LEFT JOIN done d ON d.creative_id = m.creative_id AND d.mode = md
WHERE d.creative_id IS NULL;

-- image：廣告圖＋頁面截圖三段
INSERT INTO martech_dw.mm_gaps_log (run_id, mode, creative_id, page_id, model, result, gaps,
  prompt_tokens, output_tokens, thoughts_tokens, finish_reason, status, created_at, prompt_version)
SELECT this_run, 'image', creative_id, page_id, 'gemini-3.6-flash', g.result,
  ARRAY_LENGTH(JSON_QUERY_ARRAY(SAFE.PARSE_JSON(g.result), '$.gaps')),
  CAST(JSON_VALUE(g.full_response, '$.usage_metadata.prompt_token_count') AS INT64),
  CAST(JSON_VALUE(g.full_response, '$.usage_metadata.candidates_token_count') AS INT64),
  CAST(JSON_VALUE(g.full_response, '$.usage_metadata.thoughts_token_count') AS INT64),
  JSON_VALUE(g.full_response, '$.candidates[0].finish_reason'),
  g.status, CURRENT_TIMESTAMP(), this_prompt
FROM (
  SELECT t.creative_id, t.page_id,
    AI.GENERATE(
      (CONCAT(t.intro, '第一張圖是廣告圖，後面三張圖是那個頁面的截圖，由上到下切成三段，相鄰兩段有一小部分重疊。\n\n', task_text), a.ref, l1.ref, l2.ref, l3.ref),
      connection_id => 'us.vertex_ai_conn',
      endpoint => 'gemini-3.6-flash',
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
  JOIN martech_dw.obj_landing l1 ON l1.uri LIKE CONCAT('%/', t.page_id, '-1.jpg')
  JOIN martech_dw.obj_landing l2 ON l2.uri LIKE CONCAT('%/', t.page_id, '-2.jpg')
  JOIN martech_dw.obj_landing l3 ON l3.uri LIKE CONCAT('%/', t.page_id, '-3.jpg')
  WHERE t.mode = 'image'
);

-- text：廣告圖＋頁面文字
INSERT INTO martech_dw.mm_gaps_log (run_id, mode, creative_id, page_id, model, result, gaps,
  prompt_tokens, output_tokens, thoughts_tokens, finish_reason, status, created_at, prompt_version)
SELECT this_run, 'text', creative_id, page_id, 'gemini-3.6-flash', g.result,
  ARRAY_LENGTH(JSON_QUERY_ARRAY(SAFE.PARSE_JSON(g.result), '$.gaps')),
  CAST(JSON_VALUE(g.full_response, '$.usage_metadata.prompt_token_count') AS INT64),
  CAST(JSON_VALUE(g.full_response, '$.usage_metadata.candidates_token_count') AS INT64),
  CAST(JSON_VALUE(g.full_response, '$.usage_metadata.thoughts_token_count') AS INT64),
  JSON_VALUE(g.full_response, '$.candidates[0].finish_reason'),
  g.status, CURRENT_TIMESTAMP(), this_prompt
FROM (
  SELECT t.creative_id, t.page_id,
    AI.GENERATE(
      (CONCAT(t.intro, '附上的圖是廣告圖，那個頁面上看得到的文字放在最後面。\n\n', task_text,
        '\n\n頁面上的文字（由上到下）：\n', t.page_text), a.ref),
      connection_id => 'us.vertex_ai_conn',
      endpoint => 'gemini-3.6-flash',
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
  WHERE t.mode = 'text'
);

-- 抄一份進共用用量表：思考 Token 也按輸出計費，所以 output_tokens 存「輸出＋思考」
-- 抄所有還沒抄過的執行，萬一上一次中途出錯沒抄到，這一次會補上
INSERT INTO martech_dw.ops_llm_usage (logged_at, day, job, run_id, model, endpoint_type, media_resolution, item_id, prompt_tokens, output_tokens, status)
SELECT created_at, 'Day 19', 'consistency/compare.sql', run_id, model, 'non-global', 'default',
  CONCAT(creative_id, '/', mode),
  prompt_tokens, IFNULL(output_tokens, 0) + IFNULL(thoughts_tokens, 0), status
FROM martech_dw.mm_gaps_log
WHERE run_id NOT IN (
  SELECT DISTINCT run_id FROM martech_dw.ops_llm_usage
  WHERE job = 'consistency/compare.sql' AND run_id IS NOT NULL
);

-- 這次執行呼叫了幾次（第二次執行時，成功過的組合不會再呼叫）
SELECT run_id, mode,
  COUNT(*) AS calls,
  COUNTIF(status = '') AS ok,
  COUNTIF(status != '') AS failed,
  COUNTIF(finish_reason = 'MAX_TOKENS') AS cut_by_cap,
  SUM(prompt_tokens) AS input_tokens,
  SUM(output_tokens) AS output_tokens,
  SUM(thoughts_tokens) AS thoughts_tokens
FROM martech_dw.mm_gaps_log
WHERE run_id = this_run
GROUP BY 1, 2
ORDER BY 2;
