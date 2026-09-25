-- Day 12：檢查 LTV 預測結果（ok 欄位：OK／DIFF）
-- 第 9 項會讀答案表 martech_gt，只在預測完成後執行
-- 線性迴歸在小資料上用正規方程式一次解出，同一份特徵重建模型結果相同，所以第 8、9 項可以檢查

WITH f AS (
  SELECT
    COUNT(*) AS n,
    COUNTIF(label_complete) AS labeled,
    COUNTIF(is_eval) AS eval_rows,
    COUNTIF(NOT label_complete) AS to_predict,
    MAX(IF(is_eval = FALSE, first_order_date, NULL)) < MIN(IF(is_eval, first_order_date, NULL)) AS time_split
  FROM martech_dw.ltv_features
),
m AS (
  SELECT
    COUNT(*) AS n,
    COUNTIF(predicted_revenue_30d IS NULL OR predicted_revenue_30d < 0) AS bad_pred
  FROM martech_dw.mart_customer_ltv
),
train AS (
  SELECT AVG(future_revenue_30d) AS mean_label
  FROM martech_dw.ltv_features
  WHERE label_complete AND NOT is_eval
),
mae AS (
  SELECT
    (SELECT mean_absolute_error FROM ML.EVALUATE(MODEL martech_dw.ltv_linreg)) AS linreg,
    (SELECT AVG(ABS(e.future_revenue_30d - t.mean_label))
     FROM martech_dw.ltv_features e CROSS JOIN train t
     WHERE e.is_eval) AS global_mean
),
seg AS (
  SELECT
    AVG(IF(g.segment = 'sock_regular', l.predicted_revenue_30d, NULL))
      / AVG(IF(g.segment != 'sock_regular', l.predicted_revenue_30d, NULL)) AS ratio
  FROM martech_dw.mart_customer_ltv l
  JOIN martech_gt.gt_customer_segment g USING (customer_id)
  WHERE l.scope = 'eval'
)
SELECT '1 ltv_features rows' AS check_name, '2461' AS expected, CAST(n AS STRING) AS actual, IF(n = 2461, 'OK', 'DIFF') AS ok FROM f
UNION ALL SELECT '2 label_complete', '1458', CAST(labeled AS STRING), IF(labeled = 1458, 'OK', 'DIFF') FROM f
UNION ALL SELECT '3 eval rows', '275', CAST(eval_rows AS STRING), IF(eval_rows = 275, 'OK', 'DIFF') FROM f
UNION ALL SELECT '4 to predict', '1003', CAST(to_predict AS STRING), IF(to_predict = 1003, 'OK', 'DIFF') FROM f
UNION ALL SELECT '5 train before eval', 'true', CAST(time_split AS STRING), IF(time_split, 'OK', 'DIFF') FROM f
UNION ALL SELECT '6 mart rows', '1278', CAST(n AS STRING), IF(n = 1278, 'OK', 'DIFF') FROM m
UNION ALL SELECT '7 null/negative preds', '0', CAST(bad_pred AS STRING), IF(bad_pred = 0, 'OK', 'DIFF') FROM m
UNION ALL SELECT '8 linreg MAE < global', CAST(ROUND(global_mean, 1) AS STRING), CAST(ROUND(linreg, 1) AS STRING), IF(linreg < global_mean, 'OK', 'DIFF') FROM mae
UNION ALL SELECT '9 sock_regular pred ratio', '>=1.5', CAST(ROUND(ratio, 2) AS STRING), IF(ratio >= 1.5, 'OK', 'DIFF') FROM seg
ORDER BY SAFE_CAST(SPLIT(check_name, ' ')[OFFSET(0)] AS INT64);
