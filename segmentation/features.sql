-- Day 11：把每位顧客整理成一列購買行為特徵（seg_features）
-- 只讀 martech_dw.fct_orders，不讀答案表 martech_gt
-- 基準日 as_of 取訂單最後一天（合成資料是 2026-09-16），觀察天數＝基準日 − 首購日
-- observed_30d：首購後至少觀察 30 天，才有機會看到第一次回購，K-means 主表只用這群人

CREATE OR REPLACE TABLE martech_dw.seg_features
OPTIONS(description = 'Day 11 顧客行為特徵，一位顧客一列，K-means 分群的輸入') AS
WITH as_of AS (
  SELECT MAX(order_date) AS as_of_date
  FROM martech_dw.fct_orders
  WHERE data_source = 'synthetic'
),
orders AS (
  SELECT
    customer_id,
    order_date,
    order_ts,
    quantity,
    revenue,
    CASE
      WHEN item_id LIKE 'sock-%' THEN 'sock'
      WHEN item_id = 'towel-bath-cotton' THEN 'bath'
      WHEN item_id = 'towel-face-cotton' THEN 'face'
      WHEN item_id LIKE 'set-%' THEN 'set'
    END AS category,
    ROW_NUMBER() OVER (PARTITION BY customer_id ORDER BY order_ts, transaction_id) AS seq,
    LAG(order_date) OVER (PARTITION BY customer_id ORDER BY order_ts, transaction_id) AS prev_date
  FROM martech_dw.fct_orders
  WHERE data_source = 'synthetic' AND payment_status = 'paid'
),
per_customer AS (
  SELECT
    customer_id,
    MIN(order_date) AS first_order_date,
    MAX(order_date) AS last_order_date,
    COUNT(*) AS order_count,
    SUM(quantity) AS total_qty,
    SUM(revenue) AS total_revenue,
    MAX(IF(seq = 1, quantity, NULL)) AS first_qty,
    MAX(IF(seq = 1, category, NULL)) AS first_category,
    SAFE_DIVIDE(SUM(IF(category = 'sock', quantity, 0)), SUM(quantity)) AS share_sock,
    SAFE_DIVIDE(SUM(IF(category = 'bath', quantity, 0)), SUM(quantity)) AS share_bath,
    SAFE_DIVIDE(SUM(IF(category = 'face', quantity, 0)), SUM(quantity)) AS share_face,
    SAFE_DIVIDE(SUM(IF(category = 'set', quantity, 0)), SUM(quantity)) AS share_set,
    AVG(DATE_DIFF(order_date, prev_date, DAY)) AS avg_gap_raw
  FROM orders
  GROUP BY customer_id
)
SELECT
  p.customer_id,
  p.first_order_date,
  p.first_category,
  DATE_DIFF(a.as_of_date, p.first_order_date, DAY) AS observed_days,
  DATE_DIFF(a.as_of_date, p.first_order_date, DAY) >= 30 AS observed_30d,
  p.order_count,
  p.total_qty,
  p.total_revenue,
  p.first_qty,
  p.share_sock,
  p.share_bath,
  p.share_face,
  p.share_set,
  -- 只買一次的人沒有回購間隔，補上「已經等了幾天還沒回來」
  -- 不能留 NULL：BigQuery ML 會用平均值補空值，沒回購的人會看起來像有回購
  COALESCE(p.avg_gap_raw, DATE_DIFF(a.as_of_date, p.first_order_date, DAY)) AS avg_gap_days,
  DATE_DIFF(a.as_of_date, p.last_order_date, DAY) AS recency_days
FROM per_customer p
CROSS JOIN as_of a;

SELECT
  COUNT(*) AS customers,
  COUNTIF(observed_30d) AS observed_30d,
  ROUND(AVG(order_count), 3) AS avg_orders,
  COUNTIF(first_qty IS NULL OR share_sock IS NULL) AS null_rows
FROM martech_dw.seg_features;
