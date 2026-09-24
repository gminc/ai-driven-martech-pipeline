-- Day 11：K-means 分群（主表 k＝4，觀察 ≥ 30 天的顧客）
-- CREATE MODEL 沒有免費額度（312.5 美元／TiB），特徵表很小，照每張表最低 10 MB 計費
-- 特徵不放 first_order_date、observed_days（那是篩選條件，不是購買行為），也不放答案表
CREATE OR REPLACE MODEL martech_dw.seg_kmeans_k4
OPTIONS(
  model_type = 'KMEANS',
  num_clusters = 4,
  kmeans_init_method = 'KMEANS++',
  standardize_features = TRUE
) AS
SELECT
  order_count, total_qty, total_revenue, first_qty,
  share_sock, share_bath, share_face, share_set,
  avg_gap_days, recency_days
FROM martech_dw.seg_features
WHERE observed_30d;
