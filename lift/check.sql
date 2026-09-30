-- Day 17：檢查流程本身有沒有跑完整（ok 欄位：OK／DIFF），不看倍數是多少
-- 第 13–16 項讀 martech_gt（判準、成績、答案表讀不讀得到、判準有沒有在評分之後被改過），run.sh 另外補一項：lift.sql 沒有讀答案表

WITH
feat AS (SELECT COUNT(*) AS n FROM martech_dw.mart_creative_features),
perf AS (
  SELECT
    COUNT(*) AS n,
    COUNTIF(creative_id = 'cr-meta-evg-p1') AS s3_in,
    COUNTIF(impressions IS NULL OR impressions = 0 OR clicks IS NULL OR clicks = 0) AS no_ad,
    COUNTIF(sessions IS NULL OR sessions = 0) AS no_sessions,
    COUNTIF(sessions > clicks) AS sessions_over_clicks,
    COUNTIF(f_person IS NULL OR f_cta IS NULL OR f_warm IS NULL OR f_text IS NULL) AS null_flag
  FROM martech_dw.mart_creative_perf
),
lift AS (
  SELECT
    COUNT(*) AS n,
    COUNTIF(stratified IS NULL) AS null_est,
    MIN(strata_used) AS min_strata,
    SUM(strata_skipped) AS skipped
  FROM martech_dw.mart_creative_lift
),
cols AS (
  SELECT COUNT(*) AS n
  FROM martech_dw.INFORMATION_SCHEMA.COLUMNS
  WHERE table_name = 'dim_creative'
    AND column_name IN ('has_person', 'cta_position', 'dominant_color', 'text_density')
),
v1_changed AS (
  SELECT COUNT(*) AS n FROM (
    (SELECT signal_id, check_id, rule, lower_bound, upper_bound FROM martech_gt.acceptance_criteria WHERE signal_id != 'S4'
     EXCEPT DISTINCT
     SELECT signal_id, check_id, rule, lower_bound, upper_bound FROM martech_gt.acceptance_criteria_v2 WHERE signal_id != 'S4')
    UNION ALL
    (SELECT signal_id, check_id, rule, lower_bound, upper_bound FROM martech_gt.acceptance_criteria_v2 WHERE signal_id != 'S4'
     EXCEPT DISTINCT
     SELECT signal_id, check_id, rule, lower_bound, upper_bound FROM martech_gt.acceptance_criteria WHERE signal_id != 'S4')
  )
),
s4 AS (
  SELECT COUNT(*) AS n, COUNTIF(verdict = '沒有資料') AS no_data
  FROM martech_gt.acceptance_scorecard_s4
),
-- report.sql 第 6 段要從 gt_signals 讀答案的乘數，spec 是 JSON 字串或物件都要讀得到，讀不到會安靜地變 NULL
answer AS (
  SELECT COUNTIF(SAFE_CAST(JSON_VALUE(COALESCE(SAFE.PARSE_JSON(JSON_VALUE(spec)), spec), '$.has_person') AS FLOAT64) IS NOT NULL) AS n
  FROM martech_gt.gt_signals
  WHERE signal_id = 'S4'
),
fp AS (
  SELECT
    COUNT(DISTINCT r.criteria_fp) AS kinds,
    LOGICAL_AND(r.criteria_fp = cur.fp) AS same_as_now
  FROM martech_gt.acceptance_s4_runs r
  CROSS JOIN (
    SELECT FARM_FINGERPRINT(STRING_AGG(TO_JSON_STRING(c), '|' ORDER BY c.check_id)) AS fp
    FROM martech_gt.acceptance_criteria_v2 c
  ) cur
),
checks AS (
  SELECT 1 AS id, 'features table has 24 images' AS check_name, '24' AS expected, CAST(n AS STRING) AS actual FROM feat
  UNION ALL SELECT 2, 'perf has 23 images (S3 creative excluded)', '23', CAST(n AS STRING) FROM perf
  UNION ALL SELECT 3, 'cr-meta-evg-p1 not in perf', '0', CAST(s3_in AS STRING) FROM perf
  UNION ALL SELECT 4, 'every image has impressions and clicks', '0', CAST(no_ad AS STRING) FROM perf
  UNION ALL SELECT 5, 'every image has sessions', '0', CAST(no_sessions AS STRING) FROM perf
  UNION ALL SELECT 6, 'sessions never exceed clicks', '0', CAST(sessions_over_clicks AS STRING) FROM perf
  UNION ALL SELECT 7, 'no NULL feature flag', '0', CAST(null_flag AS STRING) FROM perf
  UNION ALL SELECT 8, 'lift has 8 rows (4 features x 2 metrics)', '8', CAST(n AS STRING) FROM lift
  UNION ALL SELECT 9, 'no NULL stratified estimate', '0', CAST(null_est AS STRING) FROM lift
  UNION ALL SELECT 10, 'each estimate uses all 4 strata', '4', CAST(min_strata AS STRING) FROM lift
  UNION ALL SELECT 11, 'no stratum skipped for zero conversions', '0', CAST(skipped AS STRING) FROM lift
  UNION ALL SELECT 12, 'dim_creative has no design columns', '0', CAST(n AS STRING) FROM cols
  UNION ALL SELECT 13, 'criteria_v2 keeps v1 rows unchanged', '0', CAST(n AS STRING) FROM v1_changed
  UNION ALL SELECT 14, 'S4 scorecard has 5 checks with data', '5/0', CONCAT(CAST(n AS STRING), '/', CAST(no_data AS STRING)) FROM s4
  UNION ALL SELECT 15, 'S4 answer readable from gt_signals', '1', CAST(n AS STRING) FROM answer
  UNION ALL SELECT 16, 'criteria unchanged since first scoring', '1/true', CONCAT(CAST(kinds AS STRING), '/', IFNULL(CAST(same_as_now AS STRING), 'null')) FROM fp
)
SELECT id, check_name, expected, actual, IF(expected = actual, 'OK', 'DIFF') AS ok
FROM checks
ORDER BY id;
