-- Day 13：成績單，把各篇的結果表對照 criteria.sql 寫死的門檻
-- 讀 martech_dw 的結果表算實測值，只在最後 JOIN martech_gt.acceptance_criteria 判定
-- 全部是查詢（含在每月 1 TiB 免費額度內），不呼叫 Gemini

CREATE OR REPLACE TABLE martech_gt.acceptance_scorecard
OPTIONS(description = 'Day 13 驗收成績單，一列＝一個檢查項目') AS
WITH
-- S1a：meta-trn-prospecting 8/12 前後的點擊成本
s1a AS (
  SELECT 'S1a' AS check_id,
    SAFE_DIVIDE(SUM(IF(date >= '2026-08-12', cost, 0)) / NULLIF(SUM(IF(date >= '2026-08-12', clicks, 0)), 0),
                SUM(IF(date <  '2026-08-12', cost, 0)) / NULLIF(SUM(IF(date <  '2026-08-12', clicks, 0)), 0)) AS actual
  FROM martech_dw.fct_ad_daily
  WHERE ad_group_id = 'meta-trn-prospecting' AND date BETWEEN '2026-07-15' AND '2026-09-16'
),
diag AS (
  SELECT entity, period_start, cause
  FROM martech_dw.mart_diagnosis
  WHERE model = 'gemini-3.5-flash-lite'
),
s1b AS (SELECT 'S1b' AS check_id, IF(LOGICAL_OR(entity = 'meta-trn-prospecting' AND cause = '競價變貴'), 1.0, 0.0) AS actual FROM diag),
s2b AS (SELECT 'S2b', IF(LOGICAL_OR(entity = 'all_site' AND period_start = '2026-08-27' AND cause = '追蹤碼失效'), 1.0, 0.0) FROM diag),
s3b AS (SELECT 'S3b', IF(LOGICAL_OR(entity = 'cr-meta-evg-p1' AND cause = '素材疲乏'), 1.0, 0.0) FROM diag),
-- S2a：8/27 的 purchase 事件 vs 後台訂單
s2a AS (
  SELECT 'S2a',
    SAFE_DIVIDE(
      (SELECT COUNT(*) FROM martech_dw.fct_events
       WHERE event_dt = '2026-08-27' AND event_name = 'purchase' AND data_source = 'synthetic'),
      (SELECT COUNT(*) FROM martech_dw.fct_orders WHERE order_date = '2026-08-27' AND data_source = 'synthetic'))
),
-- S3a：cr-meta-evg-p1 每週 CTR 的對數線性迴歸斜率 → 每週倍數
s3_week AS (
  SELECT DATE_DIFF(date, '2026-06-19', WEEK) AS wk, SAFE_DIVIDE(SUM(clicks), SUM(impressions)) AS ctr
  FROM martech_dw.fct_ad_daily
  WHERE creative_id = 'cr-meta-evg-p1'
  GROUP BY wk
  HAVING COUNT(*) = 7
),
s3a AS (SELECT 'S3a', EXP(COVAR_POP(wk, LN(ctr)) / VAR_POP(wk)) FROM s3_week),
-- S5a：分群後，每種類型落在「自己是多數」的群的比例，取最低
seg AS (
  SELECT s.centroid_id, g.segment
  FROM martech_dw.mart_customer_segment s
  JOIN martech_gt.gt_customer_segment g USING (customer_id)
  WHERE s.observed_30d
),
cluster_major AS (
  SELECT centroid_id, ARRAY_AGG(segment ORDER BY n DESC LIMIT 1)[OFFSET(0)] AS major
  FROM (SELECT centroid_id, segment, COUNT(*) AS n FROM seg GROUP BY 1, 2)
  GROUP BY centroid_id
),
seg_recall AS (
  SELECT seg.segment, COUNTIF(seg.segment = m.major) / COUNT(*) AS recall
  FROM seg JOIN cluster_major m USING (centroid_id)
  GROUP BY seg.segment
),
s5a AS (SELECT 'S5a', MIN(recall) FROM seg_recall),
-- S5b：驗證集裡高頻買襪客的平均預測 ÷ 其他類型
ltv AS (
  SELECT g.segment, l.predicted_revenue_30d
  FROM martech_dw.mart_customer_ltv l
  JOIN martech_gt.gt_customer_segment g USING (customer_id)
  WHERE l.scope = 'eval'
),
s5b AS (
  SELECT 'S5b', SAFE_DIVIDE(AVG(IF(segment = 'sock_regular', predicted_revenue_30d, NULL)),
                            AVG(IF(segment != 'sock_regular', predicted_revenue_30d, NULL)))
  FROM ltv
),
-- S6：首購、回溯完整、direct 不算觸點的第一次／最後接觸功勞
attr AS (
  SELECT channel, SUM(credit_first_nd) AS first_credit, SUM(credit_last_nd) AS last_credit
  FROM martech_dw.mart_attribution
  WHERE NOT is_repeat AND NOT window_truncated
  GROUP BY channel
),
s6a AS (SELECT 'S6a', SAFE_DIVIDE(first_credit, last_credit) FROM attr WHERE channel = 'meta / paid_social'),
s6b AS (SELECT 'S6b', SAFE_DIVIDE(last_credit, first_credit) FROM attr WHERE channel = 'google / cpc'),
-- S7a：專案商品件數占比（沿用 Day 09 promo.sql 的口徑）
promo AS (
  SELECT
    IF(o.order_date >= '2026-09-01', 'during', 'before') AS period,
    SUM(IF('AUTUMN2026' IN UNNEST(p.promotion_ids), o.quantity, 0)) / SUM(o.quantity) AS share
  FROM martech_dw.fct_orders o
  JOIN martech_dw.dim_product p USING (item_id)
  WHERE o.order_date BETWEEN '2026-08-11' AND '2026-09-16'
  GROUP BY period
),
s7a AS (
  SELECT 'S7a', 100 * (MAX(IF(period = 'during', share, NULL)) - MAX(IF(period = 'before', share, NULL)))
  FROM promo
),
measured AS (
  SELECT * FROM s1a UNION ALL SELECT * FROM s1b UNION ALL SELECT * FROM s2a UNION ALL SELECT * FROM s2b
  UNION ALL SELECT * FROM s3a UNION ALL SELECT * FROM s3b UNION ALL SELECT * FROM s5a UNION ALL SELECT * FROM s5b
  UNION ALL SELECT * FROM s6a UNION ALL SELECT * FROM s6b UNION ALL SELECT * FROM s7a
)
SELECT
  c.signal_id, c.check_id, c.found_by_day, c.method, c.rule,
  c.lower_bound, c.upper_bound,
  ROUND(m.actual, 3) AS actual,
  CASE
    WHEN c.lower_bound IS NULL THEN '待考'
    WHEN m.actual IS NULL THEN '沒有資料'
    WHEN m.actual BETWEEN c.lower_bound AND c.upper_bound THEN '找到'
    ELSE '沒找到'
  END AS verdict,
  CURRENT_TIMESTAMP() AS scored_at
FROM martech_gt.acceptance_criteria c
LEFT JOIN measured m USING (check_id);

SELECT check_id, method, found_by_day, lower_bound, upper_bound, actual, verdict
FROM martech_gt.acceptance_scorecard
ORDER BY check_id;
