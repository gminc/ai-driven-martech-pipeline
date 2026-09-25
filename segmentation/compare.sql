-- Day 11 對照模型（run.sh --compare 才會建）：3 群、5 群，以及用全部顧客訓練的 4 群
-- 每個 CREATE MODEL 照最低 10 MB 計費，約新台幣 0.1 元，三個約 0.3 元
-- 特徵與正式模型 model.sql 相同，只改分群數或訓練對象

CREATE OR REPLACE MODEL martech_dw.seg_kmeans_k3
OPTIONS(model_type = 'KMEANS', num_clusters = 3, kmeans_init_method = 'KMEANS++', standardize_features = TRUE) AS
SELECT order_count, total_qty, total_revenue, first_qty,
       share_sock, share_bath, share_face, share_set,
       avg_gap_days, recency_days
FROM martech_dw.seg_features
WHERE observed_30d;

CREATE OR REPLACE MODEL martech_dw.seg_kmeans_k5
OPTIONS(model_type = 'KMEANS', num_clusters = 5, kmeans_init_method = 'KMEANS++', standardize_features = TRUE) AS
SELECT order_count, total_qty, total_revenue, first_qty,
       share_sock, share_bath, share_face, share_set,
       avg_gap_days, recency_days
FROM martech_dw.seg_features
WHERE observed_30d;

-- 用全部 2,461 人訓練（包含觀察未滿 30 天的新顧客），當 3.4 的對照
CREATE OR REPLACE MODEL martech_dw.seg_kmeans_k4_all
OPTIONS(model_type = 'KMEANS', num_clusters = 4, kmeans_init_method = 'KMEANS++', standardize_features = TRUE) AS
SELECT order_count, total_qty, total_revenue, first_qty,
       share_sock, share_bath, share_face, share_set,
       avg_gap_days, recency_days
FROM martech_dw.seg_features;
