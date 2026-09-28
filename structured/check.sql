-- Day 15：檢查結構化抽取流程本身有沒有跑完整（ok 欄位：OK／DIFF）
-- 這裡不對答案，只檢查搬家有沒有做完、次數、有沒有錯誤、欄位有沒有填、值有沒有超出選項，答案在 report.sql 才會出現
-- run.sh 另外會補一項：挑圖與看圖用的 SQL 沒有讀答案表，第 1 項確認分析資料集裡已經沒有設計欄位可以 JOIN

WITH
cols AS (
  SELECT COUNT(*) AS n
  FROM martech_dw.INFORMATION_SCHEMA.COLUMNS
  WHERE table_name = 'dim_creative'
    AND column_name IN ('has_person', 'cta_position', 'dominant_color', 'text_density')
),
s AS (SELECT COUNT(*) AS n, COUNT(DISTINCT uri) AS uris FROM martech_dw.mm_sample),
m AS (
  SELECT COUNT(*) AS n,
    COUNT(DISTINCT round) AS rounds,
    COUNTIF(status != '') AS api_error,
    COUNTIF(has_person IS NULL OR cta_position IS NULL OR dominant_color IS NULL
            OR text_density IS NULL OR headline IS NULL OR headline = '') AS missing_field,
    COUNTIF(prompt_tokens IS NULL) AS no_usage,
    COUNTIF(output_tokens >= 256) AS hit_output_cap
  FROM martech_dw.mm_structured
),
per_round AS (
  SELECT COUNTIF(images != 6) AS bad_rounds
  FROM (SELECT round, COUNT(DISTINCT creative_id) AS images FROM martech_dw.mm_structured GROUP BY 1)
),
enum_rounds AS (
  SELECT COUNTIF(cta_position NOT IN ('center', 'bottom_right', 'none')
                 OR dominant_color NOT IN ('warm', 'cool', 'neutral')
                 OR text_density NOT IN ('low', 'high')) AS off_option
  FROM martech_dw.mm_structured
  WHERE method = 'response_schema'
)
SELECT '1 design columns left in dim_creative' AS check_name, '0' AS expected, CAST(n AS STRING) AS actual, IF(n = 0, 'OK', 'DIFF') AS ok FROM cols
UNION ALL SELECT '2 sample images', '6', CAST(uris AS STRING), IF(n = 6 AND uris = 6, 'OK', 'DIFF') FROM s
UNION ALL SELECT '3 structured rows', '30', CAST(n AS STRING), IF(n = 30, 'OK', 'DIFF') FROM m
UNION ALL SELECT '4 rounds', '5', CAST(rounds AS STRING), IF(rounds = 5, 'OK', 'DIFF') FROM m
UNION ALL SELECT '5 every round 6 images', '0', CAST(bad_rounds AS STRING), IF(bad_rounds = 0, 'OK', 'DIFF') FROM per_round
UNION ALL SELECT '6 api_error', '0', CAST(api_error AS STRING), IF(api_error = 0, 'OK', 'DIFF') FROM m
UNION ALL SELECT '7 missing field', '0', CAST(missing_field AS STRING), IF(missing_field = 0, 'OK', 'DIFF') FROM m
UNION ALL SELECT '8 off-option (enum rounds)', '0', CAST(off_option AS STRING), IF(off_option = 0, 'OK', 'DIFF') FROM enum_rounds
UNION ALL SELECT '9 missing token usage', '0', CAST(no_usage AS STRING), IF(no_usage = 0, 'OK', 'DIFF') FROM m
UNION ALL SELECT '10 hit output cap 256', '0', CAST(hit_output_cap AS STRING), IF(hit_output_cap = 0, 'OK', 'DIFF') FROM m;
