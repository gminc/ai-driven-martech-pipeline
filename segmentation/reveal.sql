-- Day 11 揭曉：分群結果 × 合成器植入的顧客類型
-- 整個 segmentation/ 只有這一份 SQL 讀答案表 martech_gt，分群與特徵都沒有碰
WITH joined AS (
  SELECT s.centroid_id, s.observed_30d, g.segment
  FROM martech_dw.mart_customer_segment s
  JOIN martech_gt.gt_customer_segment g USING (customer_id)
)
SELECT
  IF(observed_30d, '觀察 ≥ 30 天', '觀察 < 30 天') AS cohort,
  centroid_id,
  COUNT(*) AS customers,
  COUNTIF(segment = 'sock_regular') AS sock_regular,
  COUNTIF(segment = 'bath_bulk') AS bath_bulk,
  COUNTIF(segment = 'starter_new') AS starter_new,
  COUNTIF(segment = 'dormant') AS dormant
FROM joined
GROUP BY cohort, centroid_id
ORDER BY cohort, centroid_id;
