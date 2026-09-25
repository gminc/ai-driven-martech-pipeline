-- Day 11：檢查分群結果（ok 欄位：OK／DIFF）
-- 群的編號、甚至分法每次重建模型都可能不同（KMEANS++ 仍有隨機成分），所以只檢查每次都穩定的項目
-- 高頻買襪客是否集中、沉睡客是否分散、Davies-Bouldin 大小會隨分法改變，不列入檢查
-- 這份會讀答案表 martech_gt，只在分群完成後執行

WITH f AS (
  SELECT
    COUNT(*) AS n,
    COUNTIF(observed_30d) AS n30,
    COUNTIF(first_qty IS NULL OR share_sock IS NULL OR avg_gap_days IS NULL OR recency_days IS NULL) AS null_rows
  FROM martech_dw.seg_features
),
m AS (
  SELECT COUNT(*) AS n, COUNT(DISTINCT centroid_id) AS k FROM martech_dw.mart_customer_segment
),
j AS (
  SELECT g.segment, s.centroid_id, COUNT(*) AS c
  FROM martech_dw.mart_customer_segment s
  JOIN martech_gt.gt_customer_segment g USING (customer_id)
  WHERE s.observed_30d
  GROUP BY g.segment, s.centroid_id
),
seg AS (
  SELECT segment, ROUND(MAX(c) / SUM(c), 3) AS top_share, COUNT(*) AS clusters
  FROM j GROUP BY segment
)
SELECT '1 seg_features rows' AS check_name, '2461' AS expected, CAST(n AS STRING) AS actual, IF(n = 2461, 'OK', 'DIFF') AS ok FROM f
UNION ALL SELECT '2 observed_30d', '1458', CAST(n30 AS STRING), IF(n30 = 1458, 'OK', 'DIFF') FROM f
UNION ALL SELECT '3 feature nulls', '0', CAST(null_rows AS STRING), IF(null_rows = 0, 'OK', 'DIFF') FROM f
UNION ALL SELECT '4 mart rows', '2461', CAST(n AS STRING), IF(n = 2461, 'OK', 'DIFF') FROM m
UNION ALL SELECT '5 clusters', '4', CAST(k AS STRING), IF(k = 4, 'OK', 'DIFF') FROM m
UNION ALL SELECT '6 bath_bulk in one cluster', '>=0.95', CAST(top_share AS STRING), IF(top_share >= 0.95, 'OK', 'DIFF') FROM seg WHERE segment = 'bath_bulk'
UNION ALL SELECT '7 starter_new in one cluster', '>=0.6', CAST(top_share AS STRING), IF(top_share >= 0.6, 'OK', 'DIFF') FROM seg WHERE segment = 'starter_new'
ORDER BY SAFE_CAST(SPLIT(check_name, ' ')[OFFSET(0)] AS INT64);
