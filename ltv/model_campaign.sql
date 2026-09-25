-- Day 12 避坑示範：把活動代號也放進特徵的版本（正式模型 ltv_linreg 不放）
-- 訓練資料是首購 8/08 以前的顧客，還沒有 9/1 才開始的 autumn-cotton，預測時碰到會怎樣見 unseen.sql
-- 只在 run.sh --unseen 時建立，多一個模型約新台幣 0.1 元
CREATE OR REPLACE MODEL martech_dw.ltv_linreg_campaign
OPTIONS(
  model_type = 'LINEAR_REG',
  input_label_cols = ['future_revenue_30d'],
  data_split_method = 'CUSTOM',
  data_split_col = 'is_eval'
) AS
SELECT
  first_item_id, first_qty, first_revenue,
  first_source, first_medium, first_campaign,
  future_revenue_30d, is_eval
FROM martech_dw.ltv_features
WHERE label_complete;
