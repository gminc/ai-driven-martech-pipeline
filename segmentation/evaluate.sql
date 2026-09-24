-- Day 11：比較不同分群數的 Davies-Bouldin 指標（越小代表群內越緊、群間越開）
-- ML.EVALUATE 屬於評估查詢，含在每月 1 TiB 免費額度內
SELECT 'k3_observed' AS model_name, 3 AS k, * FROM ML.EVALUATE(MODEL martech_dw.seg_kmeans_k3)
UNION ALL
SELECT 'k4_observed', 4, * FROM ML.EVALUATE(MODEL martech_dw.seg_kmeans_k4)
UNION ALL
SELECT 'k5_observed', 5, * FROM ML.EVALUATE(MODEL martech_dw.seg_kmeans_k5)
UNION ALL
SELECT 'k4_all', 4, * FROM ML.EVALUATE(MODEL martech_dw.seg_kmeans_k4_all)
ORDER BY model_name;
