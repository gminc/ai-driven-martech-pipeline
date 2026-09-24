-- Day 12：每位顧客一列，只放「第一筆訂單當下就知道」的資訊，加上首購後 30 天內的回購營收（標籤）
-- 只讀 martech_dw.fct_orders；不讀 Day 11 的 mart_customer_segment（分群用了回購紀錄，會偷看答案）
-- label_complete：首購後已滿 30 天，標籤才算完整，只有這些人可以拿來訓練與驗證
-- is_eval：label_complete 的顧客依首購日期排序，最晚約 20% 當驗證集（依時間切、同一天不拆開，不隨機切）

CREATE OR REPLACE TABLE martech_dw.ltv_features
OPTIONS(description = 'Day 12 首購特徵與 30 天回購營收，一位顧客一列') AS
WITH as_of AS (
  SELECT MAX(order_date) AS as_of_date
  FROM martech_dw.fct_orders
  WHERE data_source = 'synthetic'
),
orders AS (
  SELECT
    *,
    ROW_NUMBER() OVER (PARTITION BY customer_id ORDER BY order_ts, transaction_id) AS seq
  FROM martech_dw.fct_orders
  WHERE data_source = 'synthetic' AND payment_status = 'paid'
),
first_order AS (
  SELECT
    customer_id,
    order_date AS first_order_date,
    item_id AS first_item_id,
    quantity AS first_qty,
    revenue AS first_revenue,
    utm_source AS first_source,
    utm_medium AS first_medium,
    utm_campaign AS first_campaign
  FROM orders
  WHERE seq = 1
),
labeled AS (
  SELECT
    f.*,
    DATE_DIFF(a.as_of_date, f.first_order_date, DAY) >= 30 AS label_complete,
    (
      SELECT IFNULL(SUM(o.revenue), 0)
      FROM orders o
      WHERE o.customer_id = f.customer_id
        AND o.seq > 1
        AND o.order_date <= DATE_ADD(f.first_order_date, INTERVAL 30 DAY)
    ) AS future_revenue_30d
  FROM first_order f
  CROSS JOIN as_of a
)
SELECT
  *,
  IF(label_complete,
     PERCENT_RANK() OVER (PARTITION BY label_complete ORDER BY first_order_date) > 0.8,
     NULL) AS is_eval
FROM labeled;

SELECT
  COUNTIF(label_complete) AS labeled,
  COUNTIF(is_eval) AS eval_rows,
  COUNTIF(NOT label_complete) AS to_predict,
  MAX(IF(is_eval = FALSE, first_order_date, NULL)) AS train_until,
  MIN(IF(is_eval, first_order_date, NULL)) AS eval_from,
  ROUND(AVG(IF(label_complete, future_revenue_30d, NULL)), 1) AS avg_label,
  ROUND(COUNTIF(label_complete AND future_revenue_30d > 0) / COUNTIF(label_complete), 3) AS repeat_30d_rate
FROM martech_dw.ltv_features;
