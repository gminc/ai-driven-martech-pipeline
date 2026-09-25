-- Day 12：模型自己的評估（評估類查詢，含在每月 1 TiB 免費額度內）
-- ML.EVALUATE 不給資料時，用 CUSTOM 切出來的驗證集（is_eval = TRUE）計算

SELECT
  ROUND(mean_absolute_error, 1) AS mae,
  ROUND(SQRT(mean_squared_error), 1) AS rmse,
  ROUND(median_absolute_error, 1) AS median_ae,
  ROUND(r2_score, 3) AS r2
FROM ML.EVALUATE(MODEL martech_dw.ltv_linreg);
