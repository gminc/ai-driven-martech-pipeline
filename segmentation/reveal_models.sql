-- Day 11 揭曉（比較用）：同一批觀察 ≥ 30 天的顧客，換不同模型分群後和植入類型對照
-- 用法：sed 把 MODEL_NAME 換成 seg_kmeans_k3／k5／k4_all 再執行；這份也讀答案表 martech_gt
SELECT
  'MODEL_NAME' AS model_name,
  p.CENTROID_ID AS centroid_id,
  COUNT(*) AS customers,
  ROUND(AVG(p.order_count), 2) AS avg_orders,
  ROUND(AVG(p.share_sock), 2) AS sock,
  ROUND(AVG(p.share_bath), 2) AS bath,
  ROUND(AVG(p.share_face), 2) AS face,
  ROUND(AVG(p.share_set), 2) AS set_share,
  COUNTIF(g.segment = 'sock_regular') AS sock_regular,
  COUNTIF(g.segment = 'bath_bulk') AS bath_bulk,
  COUNTIF(g.segment = 'starter_new') AS starter_new,
  COUNTIF(g.segment = 'dormant') AS dormant
FROM ML.PREDICT(MODEL martech_dw.MODEL_NAME,
                (SELECT * FROM martech_dw.seg_features WHERE observed_30d)) AS p
JOIN martech_gt.gt_customer_segment g USING (customer_id)
GROUP BY centroid_id
ORDER BY centroid_id;
