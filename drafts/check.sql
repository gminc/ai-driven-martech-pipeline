-- Day 18：流程檢查，一列＝一項，ok 欄位是 OK 或 DIFF（run.sh 再補第 12、13 項，共 14 項）
-- 檢查的是「流程有沒有照設計跑完」，草稿好不好、規則有沒有用在 report.sql 看
-- 只讀 martech_dw，查詢在每月 1 TiB 免費額度內

WITH
d AS (SELECT * FROM martech_dw.mart_creative_drafts),
expected_targets AS (
  SELECT creative_id
  FROM martech_dw.mart_creative_perf
  WHERE audience = 'prospecting'
  QUALIFY ROW_NUMBER() OVER (ORDER BY ctr, creative_id) <= 3
),
ok_log AS (
  SELECT DISTINCT creative_id, version, sample
  FROM martech_dw.mm_drafts_log
  WHERE status = '' AND headline IS NOT NULL AND headline != '' AND cta_text IS NOT NULL
    AND has_person IS NOT NULL AND cited_ratio IS NOT NULL
    AND cta_position IN ('center', 'bottom_right', 'none') AND dominant_color IN ('warm', 'cool', 'neutral')
    AND text_density IN ('low', 'high') AND cited_feature IN ('person', 'cta', 'warm', 'text')
    AND method = 'response_schema'
),
checks AS (
  SELECT '01 lift table rows (Day 17 input)' AS check_name, '8' AS expected,
    CAST((SELECT COUNT(*) FROM martech_dw.mart_creative_lift) AS STRING) AS actual
  UNION ALL SELECT '02 product facts rows', '5',
    CAST((SELECT COUNT(*) FROM martech_dw.ref_product_facts) AS STRING)
  UNION ALL SELECT '03 claim terms rows', '38',
    CAST((SELECT COUNT(*) FROM martech_dw.ref_claim_terms) AS STRING)
  UNION ALL SELECT '04 target images in drafts', '3',
    CAST((SELECT COUNT(DISTINCT creative_id) FROM d) AS STRING)
  UNION ALL SELECT '05 targets = 3 lowest-CTR prospecting', '0',
    CAST((SELECT COUNT(*) FROM (
      SELECT creative_id FROM expected_targets
      EXCEPT DISTINCT SELECT DISTINCT creative_id FROM d)) AS STRING)
  UNION ALL SELECT '06 successful combos in log', '12',
    CAST((SELECT COUNT(*) FROM ok_log) AS STRING)
  UNION ALL SELECT '07 drafts rows', '12',
    CAST((SELECT COUNT(*) FROM d) AS STRING)
  UNION ALL SELECT '08 drafts per version (free/rules)', '6/6',
    CONCAT(CAST((SELECT COUNTIF(version = 'free') FROM d) AS STRING), '/',
           CAST((SELECT COUNTIF(version = 'rules') FROM d) AS STRING))
  -- 有回答但值不在選項裡、而且後來沒有補成功的組合（補成功的不算，報表第 2 段只列成功的草稿）
  UNION ALL SELECT '09 out of options and never fixed', '0',
    CAST((SELECT COUNT(*) FROM martech_dw.mm_drafts_log l
          LEFT JOIN ok_log o USING (creative_id, version, sample)
          WHERE o.creative_id IS NULL AND l.status = '' AND l.headline IS NOT NULL
            AND NOT IFNULL(l.cta_position IN ('center', 'bottom_right', 'none') AND l.dominant_color IN ('warm', 'cool', 'neutral')
              AND l.text_density IN ('low', 'high') AND l.cited_feature IN ('person', 'cta', 'warm', 'text'), FALSE)) AS STRING)
  UNION ALL SELECT '10 token counts recorded', '0',
    CAST((SELECT COUNT(*) FROM d WHERE prompt_tokens IS NULL OR output_tokens IS NULL) AS STRING)
  UNION ALL SELECT '11 usage rows = log rows', 'true',
    CAST((SELECT COUNT(*) FROM martech_dw.ops_llm_usage WHERE job = 'drafts/generate.sql'
            AND run_id IN (SELECT DISTINCT run_id FROM martech_dw.mm_drafts_log))
       = (SELECT COUNT(*) FROM martech_dw.mm_drafts_log) AS STRING)
  -- 被輸出上限截斷、而且後來沒有補成功的組合（補成功的不算，第一次截斷的次數在報表第 7 段）
  UNION ALL SELECT '14 cut by output cap and never fixed', '0',
    CAST((SELECT COUNT(DISTINCT CONCAT(l.creative_id, l.version, CAST(l.sample AS STRING)))
          FROM martech_dw.mm_drafts_log l
          LEFT JOIN ok_log o USING (creative_id, version, sample)
          WHERE l.finish_reason = 'MAX_TOKENS' AND o.creative_id IS NULL) AS STRING)
)
SELECT check_name, expected, actual, IF(expected = actual, 'OK', 'DIFF') AS ok
FROM checks
ORDER BY check_name;
