-- Day 20：流程檢查，一列＝一項，ok 欄位是 OK 或 DIFF（run.sh 再補第 16、17、18 項，共 18 項）
-- 檢查的是「評測有沒有照設計跑完、比的是不是同一份題目和答案」，各模型答對幾成在 report.sql 看
-- 會讀答案表，查詢在每月 1 TiB 免費額度內

WITH
ok_log AS (
  SELECT DISTINCT task, model, creative_id FROM martech_dw.mm_bench_log WHERE ok
),
listed AS (
  SELECT JSON_VALUE(g, '$.gap_type') AS gap_type
  FROM martech_dw.mm_bench_log l, UNNEST(JSON_QUERY_ARRAY(SAFE.PARSE_JSON(l.result), '$.gaps')) AS g
  WHERE l.task = 'gaps' AND l.status = ''
),
checks AS (
  SELECT '01 creatives mapped to a page' AS check_name, '24' AS expected,
    CAST((SELECT COUNT(*) FROM martech_dw.map_creative_landing m
          JOIN martech_dw.ref_landing_pages p USING (page_id)) AS STRING) AS actual
  UNION ALL SELECT '02 features done (lite/flash)', '24/24',
    CONCAT(CAST((SELECT COUNT(*) FROM ok_log WHERE task = 'features' AND model = 'gemini-3.5-flash-lite') AS STRING), '/',
           CAST((SELECT COUNT(*) FROM ok_log WHERE task = 'features' AND model = 'gemini-3.6-flash') AS STRING))
  UNION ALL SELECT '03 gaps done (lite/flash/pro)', '24/24/24',
    CONCAT(CAST((SELECT COUNT(*) FROM ok_log WHERE task = 'gaps' AND model = 'gemini-3.5-flash-lite') AS STRING), '/',
           CAST((SELECT COUNT(*) FROM ok_log WHERE task = 'gaps' AND model = 'gemini-3.6-flash') AS STRING), '/',
           CAST((SELECT COUNT(*) FROM ok_log WHERE task = 'gaps' AND model = 'gemini-3.1-pro-preview') AS STRING))
  -- 沿用的舊紀錄：Day 16 的簡單題 × flash-lite 與 Day 19 的難題 × 3.6-flash，各 24 筆
  UNION ALL SELECT '04 reused rows (day16/day19)', '24/24',
    CONCAT(CAST((SELECT COUNT(*) FROM martech_dw.mm_bench_log WHERE source = 'day16' AND task = 'features' AND model = 'gemini-3.5-flash-lite') AS STRING), '/',
           CAST((SELECT COUNT(*) FROM martech_dw.mm_bench_log WHERE source = 'day19' AND task = 'gaps' AND model = 'gemini-3.6-flash') AS STRING))
  -- 同一種題目只有一版題目（指紋只有一個）
  UNION ALL SELECT '05 prompt versions (features/gaps)', '1/1',
    CONCAT(CAST((SELECT COUNT(DISTINCT IFNULL(prompt_version, 'none')) FROM martech_dw.mm_bench_log WHERE task = 'features') AS STRING), '/',
           CAST((SELECT COUNT(DISTINCT IFNULL(prompt_version, 'none')) FROM martech_dw.mm_bench_log WHERE task = 'gaps') AS STRING))
  UNION ALL SELECT '06 token counts recorded', '0',
    CAST((SELECT COUNT(*) FROM martech_dw.mm_bench_log
          WHERE ok AND (prompt_tokens IS NULL OR output_tokens IS NULL)) AS STRING)
  UNION ALL SELECT '07 usage rows = new call rows', 'true',
    CAST((SELECT COUNT(*) FROM martech_dw.ops_llm_usage WHERE job = 'benchmark/bench.sql')
       = (SELECT COUNT(*) FROM martech_dw.mm_bench_log WHERE source = 'day20') AS STRING)
  -- 被輸出上限截斷、而且後來沒有補成功的組合
  UNION ALL SELECT '08 cut by output cap and never fixed', '0',
    CAST((SELECT COUNT(DISTINCT CONCAT(l.task, l.model, l.creative_id))
          FROM martech_dw.mm_bench_log l
          LEFT JOIN ok_log o USING (task, model, creative_id)
          WHERE l.finish_reason = 'MAX_TOKENS' AND o.creative_id IS NULL) AS STRING)
  UNION ALL SELECT '09 gap types outside options', '0',
    CAST((SELECT COUNT(*) FROM listed
          WHERE IFNULL(gap_type, '') NOT IN ('limited_offer', 'special_price', 'free_shipping', 'gift', 'warranty', 'product_name', 'product_option', 'other')) AS STRING)
  -- 簡單題：2 個模型 × 24 張 × 5 欄，每一格都要有 correct 或 wrong
  UNION ALL SELECT '10 feature cells judged (2 x 24 x 5)', '240',
    CAST((SELECT COUNT(*) FROM martech_dw.mart_bench_features
          WHERE verdict IN ('correct', 'wrong') AND model IN ('gemini-3.5-flash-lite', 'gemini-3.6-flash')) AS STRING)
  -- 簡單題計分的格子：每個模型 95 格（96 格扣掉 disagree 的 1 格）
  UNION ALL SELECT '11 counted cells per model (lite/flash)', '95/95',
    CONCAT(CAST((SELECT COUNTIF(counted) FROM martech_dw.mart_bench_features WHERE model = 'gemini-3.5-flash-lite') AS STRING), '/',
           CAST((SELECT COUNTIF(counted) FROM martech_dw.mart_bench_features WHERE model = 'gemini-3.6-flash') AS STRING))
  -- 難題：計分的 21 列 × 3 個模型，每一格都要有 hit 或 miss
  UNION ALL SELECT '12 gap answers judged (21 x 3)', '63',
    CAST((SELECT COUNT(*) FROM martech_dw.mart_bench_gaps
          WHERE verdict IN ('hit', 'miss')
            AND model IN ('gemini-3.5-flash-lite', 'gemini-3.6-flash', 'gemini-3.1-pro-preview')) AS STRING)
  -- 沿用 Day 19 的那一組，在這裡重新評分的結果要和 Day 19 的成績表一樣
  UNION ALL SELECT '13 flash gaps same as day 19 (hit/extra)', 'true',
    CAST((SELECT COUNTIF(verdict = 'hit') = (SELECT COUNTIF(verdict = 'hit') FROM martech_dw.mart_ad_page_gaps WHERE mode = 'text')
             AND COUNTIF(verdict = 'extra') = (SELECT COUNTIF(verdict = 'extra') FROM martech_dw.mart_ad_page_gaps WHERE mode = 'text')
          FROM martech_dw.mart_bench_gaps WHERE model = 'gemini-3.6-flash') AS STRING)
  -- 每次評分當下三張答案表的指紋都一樣、和現在的答案表一樣，難題的指紋也和 Day 19 評分時的一樣
  UNION ALL SELECT '14 answer tables unchanged', '1',
    CAST((SELECT COUNT(DISTINCT fp) FROM (
      SELECT CONCAT(design_fingerprint, review_fingerprint, gaps_fingerprint) AS fp FROM martech_gt.bench_runs
      UNION ALL
      SELECT CONCAT(
        (SELECT TO_HEX(SHA256(STRING_AGG(CONCAT(creative_id, '|', CAST(has_person AS STRING), '|', cta_position, '|', dominant_color, '|', text_density, '|', headline), '\n' ORDER BY creative_id))) FROM martech_gt.gt_creative_design),
        (SELECT TO_HEX(SHA256(STRING_AGG(CONCAT(creative_id, '|', field, '|', verdict), '\n' ORDER BY creative_id, field))) FROM martech_gt.gt_creative_review),
        IFNULL((SELECT ANY_VALUE(answer_fingerprint) FROM martech_gt.ad_page_gaps_runs
                HAVING COUNT(DISTINCT answer_fingerprint) = 1), 'day19 fingerprint missing or not unique')))) AS STRING)
  -- 成功過之後同一個組合又被呼叫：跑過的不重跑，應該是 0
  UNION ALL SELECT '15 no repeat call after success', '0',
    CAST((SELECT COUNT(*) FROM martech_dw.mm_bench_log later
          WHERE later.source = 'day20' AND EXISTS (
            SELECT 1 FROM martech_dw.mm_bench_log earlier
            WHERE earlier.task = later.task AND earlier.model = later.model AND earlier.creative_id = later.creative_id
              AND earlier.ok AND earlier.created_at < later.created_at)) AS STRING)
)
SELECT check_name, expected, actual, IF(expected = actual, 'OK', 'DIFF') AS ok
FROM checks
ORDER BY check_name;
