-- Day 19：流程檢查，一列＝一項，ok 欄位是 OK 或 DIFF（run.sh 再補第 13、14 項，共 14 項）
-- 檢查的是「流程有沒有照設計跑完」，Gemini 抓到幾成在 report.sql 看
-- 會讀答案表（第 04、11、12 項），查詢在每月 1 TiB 免費額度內

WITH
ok_log AS (
  SELECT DISTINCT creative_id, mode
  FROM martech_dw.mm_gaps_log
  WHERE status = '' AND IFNULL(finish_reason, '') != 'MAX_TOKENS'
    AND JSON_QUERY_ARRAY(SAFE.PARSE_JSON(result), '$.gaps') IS NOT NULL
),
listed AS (
  SELECT JSON_VALUE(g, '$.gap_type') AS gap_type
  FROM martech_dw.mm_gaps_log l, UNNEST(JSON_QUERY_ARRAY(SAFE.PARSE_JSON(l.result), '$.gaps')) AS g
  WHERE l.status = ''
),
checks AS (
  SELECT '01 landing pages (text)' AS check_name, '3' AS expected,
    CAST((SELECT COUNT(*) FROM martech_dw.ref_landing_pages) AS STRING) AS actual
  UNION ALL SELECT '02 landing screenshots (object table)', '3',
    CAST((SELECT COUNT(*) FROM martech_dw.obj_landing) AS STRING)
  UNION ALL SELECT '03 creatives mapped to a page', '24',
    CAST((SELECT COUNT(*) FROM martech_dw.map_creative_landing m
          JOIN martech_dw.ref_landing_pages p USING (page_id)) AS STRING)
  UNION ALL SELECT '04 answer rows scored/disputed', '21/1',
    CONCAT(CAST((SELECT COUNTIF(NOT disputed) FROM martech_gt.gt_ad_page_gaps) AS STRING), '/',
           CAST((SELECT COUNTIF(disputed) FROM martech_gt.gt_ad_page_gaps) AS STRING))
  UNION ALL SELECT '05 successful combos in log', '48',
    CAST((SELECT COUNT(*) FROM ok_log) AS STRING)
  UNION ALL SELECT '06 combos per mode (image/text)', '24/24',
    CONCAT(CAST((SELECT COUNTIF(mode = 'image') FROM ok_log) AS STRING), '/',
           CAST((SELECT COUNTIF(mode = 'text') FROM ok_log) AS STRING))
  UNION ALL SELECT '07 token counts recorded', '0',
    CAST((SELECT COUNT(*) FROM martech_dw.mm_gaps_log
          WHERE status = '' AND (prompt_tokens IS NULL OR output_tokens IS NULL)) AS STRING)
  UNION ALL SELECT '08 usage rows = log rows', 'true',
    CAST((SELECT COUNT(*) FROM martech_dw.ops_llm_usage WHERE job = 'consistency/compare.sql'
            AND run_id IN (SELECT DISTINCT run_id FROM martech_dw.mm_gaps_log))
       = (SELECT COUNT(*) FROM martech_dw.mm_gaps_log) AS STRING)
  -- 被輸出上限截斷、而且後來沒有補成功的組合
  UNION ALL SELECT '09 cut by output cap and never fixed', '0',
    CAST((SELECT COUNT(DISTINCT CONCAT(l.creative_id, l.mode))
          FROM martech_dw.mm_gaps_log l
          LEFT JOIN ok_log o USING (creative_id, mode)
          WHERE l.finish_reason = 'MAX_TOKENS' AND o.creative_id IS NULL) AS STRING)
  UNION ALL SELECT '10 gap types outside options', '0',
    CAST((SELECT COUNT(*) FROM listed
          WHERE IFNULL(gap_type, '') NOT IN ('limited_offer', 'special_price', 'free_shipping', 'product_name', 'product_option', 'other')) AS STRING)
  -- 計分的 21 列 × 兩種給法，每一格都要有 hit 或 miss
  UNION ALL SELECT '11 scored answers judged (21 x 2)', '42',
    CAST((SELECT COUNT(*) FROM martech_dw.mart_ad_page_gaps WHERE verdict IN ('hit', 'miss')) AS STRING)
  -- 每次評分當下的答案表指紋都一樣，而且和現在的答案表一樣（評分之後答案沒有被改過）
  UNION ALL SELECT '12 answer table unchanged since scoring', '1',
    CAST((SELECT COUNT(DISTINCT fp) FROM (
      SELECT answer_fingerprint AS fp FROM martech_gt.ad_page_gaps_runs
      UNION ALL
      SELECT TO_HEX(SHA256(STRING_AGG(CONCAT(creative_id, '|', gap_type, '|', ad_keyword, '|', page_fact, '|', CAST(disputed AS STRING)), '\n' ORDER BY creative_id, gap_type)))
      FROM martech_gt.gt_ad_page_gaps)) AS STRING)
)
SELECT check_name, expected, actual, IF(expected = actual, 'OK', 'DIFF') AS ok
FROM checks
ORDER BY check_name;
