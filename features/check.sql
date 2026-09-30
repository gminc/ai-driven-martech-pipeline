-- Day 16：檢查整批看圖流程本身有沒有跑完整（ok 欄位：OK／DIFF）
-- 這裡不對答案，只檢查張數、有沒有成功、欄位有沒有填、值有沒有超出選項、用量有沒有記下來，答案在 report.sql 才會出現
-- mm_features_log 會跨次累積（失敗的也留著），所以這裡看的是「每張圖 × 解析度有沒有至少一筆成功」，成功的定義和 extract.sql 一樣
-- 第 12 項確認成功過的組合沒有被再呼叫一次，run.sh 另外補一項：看圖與建表的 SQL 沒有讀答案表

WITH
cols AS (
  SELECT COUNT(*) AS n
  FROM martech_dw.INFORMATION_SCHEMA.COLUMNS
  WHERE table_name = 'dim_creative'
    AND column_name IN ('has_person', 'cta_position', 'dominant_color', 'text_density')
),
o AS (SELECT COUNT(*) AS n FROM martech_dw.obj_creatives),
ok AS (
  SELECT
    COUNT(DISTINCT IF(resolution = 'default', creative_id, NULL)) AS default_ok,
    COUNT(DISTINCT IF(resolution = 'low', creative_id, NULL)) AS low_ok
  FROM martech_dw.mm_features_log
  WHERE status = '' AND has_person IS NOT NULL AND cta_position IS NOT NULL AND dominant_color IS NOT NULL
    AND text_density IS NOT NULL AND headline IS NOT NULL AND headline != ''
),
l AS (
  SELECT
    COUNTIF(status = '' AND (has_person IS NULL OR cta_position IS NULL OR dominant_color IS NULL
            OR text_density IS NULL OR headline IS NULL OR headline = '')) AS missing_field,
    COUNTIF(output_tokens >= 256) AS hit_output_cap,
    COUNTIF(status = '' AND prompt_tokens IS NULL) AS no_usage
  FROM martech_dw.mm_features_log
),
f AS (
  SELECT COUNT(*) AS n, COUNT(DISTINCT creative_id) AS ids, COUNTIF(NOT in_option) AS off_option
  FROM martech_dw.mart_creative_features
),
u AS (
  SELECT
    (SELECT COUNT(*) FROM martech_dw.mm_features_log) AS log_rows,
    (SELECT COUNT(*) FROM martech_dw.ops_llm_usage
      WHERE job = 'features/extract.sql'
        AND run_id IN (SELECT DISTINCT run_id FROM martech_dw.mm_features_log)) AS usage_rows
),
-- 成功過之後又被呼叫了同一張圖 × 解析度 × 鎖法：跑過的不重跑，應該是 0
rep AS (
  SELECT COUNT(*) AS repeat_calls
  FROM martech_dw.mm_features_log later
  WHERE EXISTS (
    SELECT 1 FROM martech_dw.mm_features_log earlier
    WHERE earlier.creative_id = later.creative_id
      AND earlier.resolution = later.resolution
      AND earlier.method = later.method
      AND earlier.run_id != later.run_id
      AND earlier.created_at < later.created_at
      AND earlier.status = '' AND earlier.has_person IS NOT NULL AND earlier.cta_position IS NOT NULL
      AND earlier.dominant_color IS NOT NULL AND earlier.text_density IS NOT NULL
      AND earlier.headline IS NOT NULL AND earlier.headline != ''
  )
),
res AS (
  SELECT COUNT(*) AS pairs, COUNTIF(lo.prompt_tokens < hi.prompt_tokens) AS low_cheaper
  FROM (SELECT creative_id, MIN(prompt_tokens) AS prompt_tokens FROM martech_dw.mm_features_log
        WHERE resolution = 'low' AND status = '' AND prompt_tokens IS NOT NULL GROUP BY 1) lo
  JOIN (SELECT creative_id, MIN(prompt_tokens) AS prompt_tokens FROM martech_dw.mm_features_log
        WHERE resolution = 'default' AND method = 'output_schema' AND status = '' GROUP BY 1) hi
  USING (creative_id)
)
SELECT '1 design columns left in dim_creative' AS check_name, '0' AS expected, CAST(n AS STRING) AS actual, IF(n = 0, 'OK', 'DIFF') AS ok FROM cols
UNION ALL SELECT '2 object table images', '24', CAST(n AS STRING), IF(n = 24, 'OK', 'DIFF') FROM o
UNION ALL SELECT '3 default resolution done', '24', CAST(default_ok AS STRING), IF(default_ok = 24, 'OK', 'DIFF') FROM ok
UNION ALL SELECT '4 low resolution done', '24', CAST(low_ok AS STRING), IF(low_ok = 24, 'OK', 'DIFF') FROM ok
UNION ALL SELECT '5 feature table one row per image', '24', CAST(n AS STRING), IF(n = 24 AND ids = 24, 'OK', 'DIFF') FROM f
UNION ALL SELECT '6 feature table off-option', '0', CAST(off_option AS STRING), IF(off_option = 0, 'OK', 'DIFF') FROM f
UNION ALL SELECT '7 missing field in success rows', '0', CAST(missing_field AS STRING), IF(missing_field = 0, 'OK', 'DIFF') FROM l
UNION ALL SELECT '8 hit output cap 256', '0', CAST(hit_output_cap AS STRING), IF(hit_output_cap = 0, 'OK', 'DIFF') FROM l
UNION ALL SELECT '9 missing token usage', '0', CAST(no_usage AS STRING), IF(no_usage = 0, 'OK', 'DIFF') FROM l
UNION ALL SELECT '10 every call in ops_llm_usage', CAST(log_rows AS STRING), CAST(usage_rows AS STRING), IF(log_rows = usage_rows, 'OK', 'DIFF') FROM u
UNION ALL SELECT '11 low resolution cheaper', '24', CAST(low_cheaper AS STRING), IF(pairs = 24 AND low_cheaper = 24, 'OK', 'DIFF') FROM res
UNION ALL SELECT '12 no repeat call after success', '0', CAST(repeat_calls AS STRING), IF(repeat_calls = 0, 'OK', 'DIFF') FROM rep;
