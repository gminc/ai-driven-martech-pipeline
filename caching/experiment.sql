-- Day 10 第三步：三種做法各跑三輪，每輪 4 題，結果寫進 martech_dw.cache_runs
--   old      ：Day 09 的排法，每題的數字在最前面、固定內容在後面
--   new      ：固定內容移到最前面，等 Gemini 自動命中（隱含式快取）
--   explicit ：固定內容先建成快取（cache.sh create），每題只送數字並帶上快取名稱（明確快取）
-- 每一輪在會變的那一段開頭加上「檢查批次：第 N 批」，模擬每次都是新的一批數字
--   （如果每輪送一模一樣的整段文字，連 old 也會整段命中，就看不出排順序的差別）
-- 三種做法都用 AI.GENERATE、同一個 global 端點與同一份輸出格式，差別只在題目怎麼排、有沒有帶快取
-- 注意：
--   1. gemini-3.5-flash-lite 沒有 us-central1 版本，快取建在 global，endpoint 要寫 global 的完整網址；
--      只寫模型名稱時會出現「Not found: cached content metadata」，看起來是 BigQuery 把請求送到了別的區域
--   2. endpoint 用變數會報錯（must be a string literal），model_params 也一併寫成常數，所以三段各寫一次
--   3. PROJECT_ID 與 CACHE_NAME 由 run.sh 代入（專案 ID、caching/.cache_name 記錄的快取名稱）
-- 這一步會產生 Token 費用：36 次呼叫，2026-09-24 實測約 0.062 美元（約新台幣 2 元）

DECLARE r INT64 DEFAULT 1;

DELETE FROM martech_dw.cache_runs WHERE scenario IN ('old', 'new', 'explicit');

WHILE r <= 3 DO

  -- old：數字在前、固定內容在後
  INSERT INTO martech_dw.cache_runs
  SELECT CURRENT_TIMESTAMP(), 'old', r, anomaly_id,
    JSON_VALUE(g.result, '$.cause'),
    CAST(JSON_VALUE(g.full_response, '$.usage_metadata.prompt_token_count') AS INT64),
    IFNULL(CAST(JSON_VALUE(g.full_response, '$.usage_metadata.cached_content_token_count') AS INT64), 0),
    CAST(JSON_VALUE(g.full_response, '$.usage_metadata.candidates_token_count') AS INT64),
    g.status, JSON_QUERY(g.full_response, '$.usage_metadata')
  FROM (
    SELECT anomaly_id,
      AI.GENERATE(
        CONCAT('檢查批次：第 ', CAST(r AS STRING), ' 批\n', question, '\n\n', c.context),
        endpoint => 'https://aiplatform.googleapis.com/v1/projects/PROJECT_ID/locations/global/publishers/google/models/gemini-3.5-flash-lite',
        connection_id => 'us.vertex_ai_conn',
        model_params => JSON '''{"generation_config": {"max_output_tokens": 512, "thinking_config": {"thinking_budget": 0}, "response_mime_type": "application/json", "response_schema": {"type": "OBJECT", "properties": {"cause": {"type": "STRING", "enum": ["競價變貴", "追蹤碼失效", "素材疲乏", "需求或季節變化", "其他", "資料不足"]}, "evidence": {"type": "STRING"}, "confidence": {"type": "NUMBER"}, "next_check": {"type": "STRING"}}, "required": ["cause", "evidence", "confidence", "next_check"]}}}'''
      ) AS g
    FROM martech_dw.cache_prompt
    CROSS JOIN martech_dw.cache_context c
  );

  -- new：固定內容在前，等隱含式快取自動命中
  INSERT INTO martech_dw.cache_runs
  SELECT CURRENT_TIMESTAMP(), 'new', r, anomaly_id,
    JSON_VALUE(g.result, '$.cause'),
    CAST(JSON_VALUE(g.full_response, '$.usage_metadata.prompt_token_count') AS INT64),
    IFNULL(CAST(JSON_VALUE(g.full_response, '$.usage_metadata.cached_content_token_count') AS INT64), 0),
    CAST(JSON_VALUE(g.full_response, '$.usage_metadata.candidates_token_count') AS INT64),
    g.status, JSON_QUERY(g.full_response, '$.usage_metadata')
  FROM (
    SELECT anomaly_id,
      AI.GENERATE(
        CONCAT(c.context, '\n\n', '檢查批次：第 ', CAST(r AS STRING), ' 批\n', question),
        endpoint => 'https://aiplatform.googleapis.com/v1/projects/PROJECT_ID/locations/global/publishers/google/models/gemini-3.5-flash-lite',
        connection_id => 'us.vertex_ai_conn',
        model_params => JSON '''{"generation_config": {"max_output_tokens": 512, "thinking_config": {"thinking_budget": 0}, "response_mime_type": "application/json", "response_schema": {"type": "OBJECT", "properties": {"cause": {"type": "STRING", "enum": ["競價變貴", "追蹤碼失效", "素材疲乏", "需求或季節變化", "其他", "資料不足"]}, "evidence": {"type": "STRING"}, "confidence": {"type": "NUMBER"}, "next_check": {"type": "STRING"}}, "required": ["cause", "evidence", "confidence", "next_check"]}}}'''
      ) AS g
    FROM martech_dw.cache_prompt
    CROSS JOIN martech_dw.cache_context c
  );

  -- explicit：只送數字，固定內容從明確快取拿
  INSERT INTO martech_dw.cache_runs
  SELECT CURRENT_TIMESTAMP(), 'explicit', r, anomaly_id,
    JSON_VALUE(g.result, '$.cause'),
    CAST(JSON_VALUE(g.full_response, '$.usage_metadata.prompt_token_count') AS INT64),
    IFNULL(CAST(JSON_VALUE(g.full_response, '$.usage_metadata.cached_content_token_count') AS INT64), 0),
    CAST(JSON_VALUE(g.full_response, '$.usage_metadata.candidates_token_count') AS INT64),
    g.status, JSON_QUERY(g.full_response, '$.usage_metadata')
  FROM (
    SELECT anomaly_id,
      AI.GENERATE(
        CONCAT('檢查批次：第 ', CAST(r AS STRING), ' 批\n', question),
        endpoint => 'https://aiplatform.googleapis.com/v1/projects/PROJECT_ID/locations/global/publishers/google/models/gemini-3.5-flash-lite',
        connection_id => 'us.vertex_ai_conn',
        model_params => JSON '''{"cachedContent": "CACHE_NAME", "generation_config": {"max_output_tokens": 512, "thinking_config": {"thinking_budget": 0}, "response_mime_type": "application/json", "response_schema": {"type": "OBJECT", "properties": {"cause": {"type": "STRING", "enum": ["競價變貴", "追蹤碼失效", "素材疲乏", "需求或季節變化", "其他", "資料不足"]}, "evidence": {"type": "STRING"}, "confidence": {"type": "NUMBER"}, "next_check": {"type": "STRING"}}, "required": ["cause", "evidence", "confidence", "next_check"]}}}'''
      ) AS g
    FROM martech_dw.cache_prompt
  );

  SET r = r + 1;
END WHILE;
