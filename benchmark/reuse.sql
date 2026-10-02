-- Day 20：建立評測的呼叫紀錄表 mm_bench_log，再把前幾天已經問過、可以直接拿來比的結果抄進來（不呼叫 Gemini，免費）
--   簡單題（看圖填五個欄位）× gemini-3.5-flash-lite：Day 16 預設解析度那一輪（mm_features_log）
--   難題（廣告圖對頁面文字找落差）× gemini-3.6-flash：Day 19 給文字那一輪（mm_gaps_log，mode = 'text'）
-- 抄進來的列保留原本的 run_id 與 created_at，source 記 day16／day19，之後 bench.sql 新問的記 day20
-- 已經抄過的不會再抄，可以重複執行，只讀 martech_dw，不讀答案表，查詢在每月 1 TiB 免費額度內

CREATE TABLE IF NOT EXISTS martech_dw.mm_bench_log (
  run_id          STRING,
  task            STRING,
  model           STRING,
  creative_id     STRING,
  page_id         STRING,
  result          STRING,
  prompt_tokens   INT64,
  output_tokens   INT64,
  thoughts_tokens INT64,
  finish_reason   STRING,
  status          STRING,
  created_at      TIMESTAMP,
  source          STRING,
  prompt_version  STRING,
  ok              BOOL
)
OPTIONS (description = 'Day 20 模型評測的呼叫紀錄：一列＝一次呼叫（題目 features／gaps × 模型 × 廣告圖），result 是模型回的 JSON，ok 是這次呼叫算不算成功，source 是 day16／day19（沿用舊紀錄）或 day20（這次新問的）');

-- 簡單題 × flash-lite：每張圖取 Day 16 預設解析度、output_schema 那一輪最新的一筆成功紀錄
-- Day 16 的紀錄表沒有存題目的指紋，這裡填的是 features/extract.sql 現在那一版 prompt_b 的指紋（run.sh 會確認三個檔案裡的題目一字不差）
INSERT INTO martech_dw.mm_bench_log (run_id, task, model, creative_id, page_id, result,
  prompt_tokens, output_tokens, thoughts_tokens, finish_reason, status, created_at, source, prompt_version, ok)
SELECT run_id, 'features', model, creative_id, CAST(NULL AS STRING),
  TO_JSON_STRING(STRUCT(has_person, cta_position, dominant_color, text_density, headline)),
  prompt_tokens, output_tokens, CAST(NULL AS INT64), CAST(NULL AS STRING), status, created_at,
  'day16', 'd53bb63969eaa3a6febf02caaacdeb6a', TRUE
FROM martech_dw.mm_features_log
WHERE resolution = 'default' AND method = 'output_schema' AND model = 'gemini-3.5-flash-lite'
  AND status = '' AND has_person IS NOT NULL AND cta_position IS NOT NULL AND dominant_color IS NOT NULL
  AND text_density IS NOT NULL AND headline IS NOT NULL AND headline != ''
  AND creative_id NOT IN (
    SELECT creative_id FROM martech_dw.mm_bench_log
    WHERE task = 'features' AND model = 'gemini-3.5-flash-lite' AND ok)
QUALIFY ROW_NUMBER() OVER (PARTITION BY creative_id ORDER BY created_at DESC) = 1;

-- 難題 × 3.6-flash：每張圖取 Day 19 給文字那一輪最新的一筆成功紀錄，題目指紋要和 bench.sql 的一樣
INSERT INTO martech_dw.mm_bench_log (run_id, task, model, creative_id, page_id, result,
  prompt_tokens, output_tokens, thoughts_tokens, finish_reason, status, created_at, source, prompt_version, ok)
SELECT run_id, 'gaps', model, creative_id, page_id, result,
  prompt_tokens, output_tokens, thoughts_tokens, finish_reason, status, created_at,
  'day19', prompt_version, TRUE
FROM martech_dw.mm_gaps_log
WHERE mode = 'text' AND model = 'gemini-3.6-flash'
  AND prompt_version = '9a7497b1ba445523991489428b9b0af3'
  AND status = '' AND IFNULL(finish_reason, '') != 'MAX_TOKENS'
  AND JSON_QUERY_ARRAY(SAFE.PARSE_JSON(result), '$.gaps') IS NOT NULL
  AND creative_id NOT IN (
    SELECT creative_id FROM martech_dw.mm_bench_log
    WHERE task = 'gaps' AND model = 'gemini-3.6-flash' AND ok)
QUALIFY ROW_NUMBER() OVER (PARTITION BY creative_id ORDER BY created_at DESC) = 1;

SELECT task, model, source, COUNT(*) AS call_rows, COUNTIF(ok) AS ok_rows
FROM martech_dw.mm_bench_log
GROUP BY 1, 2, 3
ORDER BY 1, 2, 3;
