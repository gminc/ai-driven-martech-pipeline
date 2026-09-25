-- Day 11：每一群的輪廓（不看答案表），行銷人員靠這張表替每一群取名字
SELECT
  s.centroid_id,
  COUNT(*) AS customers,
  ROUND(AVG(f.order_count), 2) AS avg_orders,
  ROUND(COUNTIF(f.order_count > 1) / COUNT(*), 3) AS repeat_rate,
  ROUND(AVG(f.first_qty), 2) AS avg_first_qty,
  ROUND(AVG(f.total_revenue)) AS avg_revenue,
  ROUND(AVG(f.share_sock), 2) AS sock,
  ROUND(AVG(f.share_bath), 2) AS bath,
  ROUND(AVG(f.share_face), 2) AS face,
  ROUND(AVG(f.share_set), 2) AS set_share,
  ROUND(AVG(f.avg_gap_days)) AS avg_gap_days,
  ROUND(AVG(f.recency_days)) AS recency_days
FROM martech_dw.mart_customer_segment s
JOIN martech_dw.seg_features f USING (customer_id)
WHERE s.observed_30d
GROUP BY s.centroid_id
ORDER BY s.centroid_id;

-- 群中心（標準化後的數值，正值代表高於平均）
SELECT centroid_id, feature, ROUND(numerical_value, 2) AS value
FROM ML.CENTROIDS(MODEL martech_dw.seg_kmeans_k4, STRUCT(TRUE AS standardize))
ORDER BY centroid_id, feature;
