-- Day 12：模型要贏過的兩條基準線，全部用驗證集（最晚 20% 首購的顧客）計算誤差
-- ① 全體平均：每個人都猜訓練集的平均回購營收
-- ② 依首購商品平均：買同一項商品的人猜同一個數字
-- ③ 線性迴歸：ML.PREDICT（評估類查詢，含在免費額度內）
WITH train AS (
  SELECT * FROM martech_dw.ltv_features WHERE label_complete AND NOT is_eval
),
eval AS (
  SELECT * FROM martech_dw.ltv_features WHERE is_eval
),
global_mean AS (SELECT AVG(future_revenue_30d) AS pred FROM train),
item_mean AS (SELECT first_item_id, AVG(future_revenue_30d) AS pred FROM train GROUP BY 1),
preds AS (
  SELECT '① 全體平均' AS method, e.future_revenue_30d AS actual, g.pred
  FROM eval e CROSS JOIN global_mean g
  UNION ALL
  SELECT '② 依首購商品平均', e.future_revenue_30d, IFNULL(i.pred, g.pred)
  FROM eval e CROSS JOIN global_mean g LEFT JOIN item_mean i USING (first_item_id)
  UNION ALL
  SELECT '③ 線性迴歸', future_revenue_30d, predicted_future_revenue_30d
  FROM ML.PREDICT(MODEL martech_dw.ltv_linreg, (SELECT * FROM eval))
)
SELECT
  method,
  COUNT(*) AS customers,
  ROUND(AVG(ABS(actual - pred)), 1) AS mae,
  ROUND(SQRT(AVG(POW(actual - pred, 2))), 1) AS rmse,
  ROUND(AVG(pred), 1) AS avg_pred,
  ROUND(AVG(actual), 1) AS avg_actual
FROM preds
GROUP BY method
ORDER BY method;
