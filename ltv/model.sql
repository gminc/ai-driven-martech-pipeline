-- Day 12：線性迴歸預測首購後 30 天的回購營收
-- 線性迴歸是 BigQuery 內建模型（312.5 美元／TiB，沒有免費額度），提升樹要另付 Vertex AI 訓練費，這裡不用
-- 字串欄位（首購商品、來源、媒介）會自動做 one-hot 編碼
-- 不放活動代號：autumn-cotton 9/1 才開始，訓練資料沒有這個值，模型碰到沒看過的活動會把預測推高到 700 以上（見 unseen.sql）
CREATE OR REPLACE MODEL martech_dw.ltv_linreg
OPTIONS(
  model_type = 'LINEAR_REG',
  input_label_cols = ['future_revenue_30d'],
  data_split_method = 'CUSTOM',
  data_split_col = 'is_eval'
) AS
SELECT
  first_item_id, first_qty, first_revenue,
  first_source, first_medium,
  future_revenue_30d, is_eval
FROM martech_dw.ltv_features
WHERE label_complete;
