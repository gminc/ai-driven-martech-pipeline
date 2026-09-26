-- Day 12：對「首購還不滿 30 天」的顧客預測接下來 30 天的回購營收，寫進 mart_customer_ltv
-- 同時保留驗證集的預測值，方便 3.3 揭曉與 Day 13 驗收
CREATE OR REPLACE TABLE martech_dw.mart_customer_ltv
OPTIONS(description = 'Day 12 線性迴歸預測的 30 天回購營收（新台幣），一位顧客一列') AS
SELECT
  customer_id,
  first_order_date,
  first_item_id,
  first_source,
  first_medium,
  first_campaign,
  IF(label_complete, 'eval', 'new') AS scope,
  ROUND(GREATEST(predicted_future_revenue_30d, 0), 1) AS predicted_revenue_30d,
  IF(label_complete, future_revenue_30d, NULL) AS actual_revenue_30d
FROM ML.PREDICT(
  MODEL martech_dw.ltv_linreg,
  (SELECT * FROM martech_dw.ltv_features WHERE is_eval OR NOT label_complete)
);
