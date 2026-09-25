-- Day 11：把每位顧客分到最近的群，寫進 mart_customer_segment（Day 13 驗收、Day 21 查資料庫會用）
-- 模型只用觀察 ≥ 30 天的顧客訓練，但所有顧客都可以依特徵分到最近的群，observed_30d 欄位標出哪些人觀察還不夠久
-- 注意：分群用了回購紀錄，Day 12 預測長期價值時不能拿 segment 當特徵
CREATE OR REPLACE TABLE martech_dw.mart_customer_segment
OPTIONS(description = 'Day 11 K-means（k＝4）分群結果，一位顧客一列；分群編號每次重建模型都可能不同，請對照 profile.sql 的輪廓認群') AS
SELECT
  p.customer_id,
  p.CENTROID_ID AS centroid_id,
  p.NEAREST_CENTROIDS_DISTANCE[OFFSET(0)].DISTANCE AS distance,
  p.observed_30d,
  p.first_order_date,
  p.order_count,
  p.total_revenue
FROM ML.PREDICT(MODEL martech_dw.seg_kmeans_k4, TABLE martech_dw.seg_features) AS p;
