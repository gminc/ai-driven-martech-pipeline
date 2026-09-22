-- Day 08：歸因結果檢查，每一項印出 expected、actual 與 OK／DIFF／INFO
-- 功勞守恆：六個功勞欄位各自加總必須等於訂單數，營收加總必須等於訂單表營收
-- 守恆只抓得到漏算或重複算，所以另外檢查第一次／最後接觸的位置與回購路徑的起點
-- 改了 build.sql 的 lookback_days，下面 max_days_before_order 的 30 也要一起改

WITH
o AS (
  SELECT COUNT(*) AS orders, SUM(revenue) AS revenue
  FROM martech_dw.fct_orders WHERE data_source = 'synthetic'
),
per_order AS (
  SELECT
    transaction_id, ANY_VALUE(revenue) AS revenue,
    SUM(credit_first) AS f, SUM(credit_last) AS l, SUM(credit_decay) AS d,
    SUM(credit_first_nd) AS fn, SUM(credit_last_nd) AS ln, SUM(credit_decay_nd) AS dn,
    COUNT(*) AS touches, MAX(touch_ts > order_ts) AS has_future,
    MAX(days_before_order) AS max_days, ANY_VALUE(path_len) AS path_len
  FROM martech_dw.mart_attribution
  WHERE order_date >= DATE '2000-01-01'
  GROUP BY transaction_id
),
prev AS (
  SELECT transaction_id,
    LAG(order_ts) OVER (PARTITION BY user_pseudo_id ORDER BY order_ts, transaction_id) AS prev_ts
  FROM martech_dw.fct_orders WHERE data_source = 'synthetic'
),
pos AS (
  SELECT
    COUNTIF(credit_first = 1 AND touch_seq != 1) + COUNTIF(credit_first = 0 AND touch_seq = 1) AS bad_first_pos,
    COUNTIF(credit_last = 1 AND touch_seq != path_len) + COUNTIF(credit_last = 0 AND touch_seq = path_len) AS bad_last_pos,
    COUNTIF(m.touch_ts <= p.prev_ts) AS cross_prev
  FROM martech_dw.mart_attribution m JOIN prev p USING (transaction_id)
  WHERE m.order_date >= DATE '2000-01-01'
),
a AS (
  SELECT
    COUNT(*) AS orders,
    SUM(revenue) AS revenue,
    COUNTIF(ABS(f - 1) > 1e-9) AS bad_f, COUNTIF(ABS(l - 1) > 1e-9) AS bad_l, COUNTIF(ABS(d - 1) > 1e-9) AS bad_d,
    COUNTIF(ABS(fn - 1) > 1e-9) AS bad_fn, COUNTIF(ABS(ln - 1) > 1e-9) AS bad_ln, COUNTIF(ABS(dn - 1) > 1e-9) AS bad_dn,
    COUNTIF(has_future) AS future, MAX(max_days) AS max_days,
    COUNTIF(touches != path_len) AS bad_len,
    SUM(touches) AS touch_rows
  FROM per_order
)
SELECT 'orders_covered' AS check_name, CAST(o.orders AS STRING) AS expected, CAST(a.orders AS STRING) AS actual,
       IF(o.orders = a.orders, 'OK', 'DIFF') AS ok FROM o, a
UNION ALL SELECT 'revenue_covered', CAST(o.revenue AS STRING), CAST(a.revenue AS STRING), IF(o.revenue = a.revenue, 'OK', 'DIFF') FROM o, a
UNION ALL SELECT 'credit_first_sum_ne_1', '0', CAST(bad_f AS STRING), IF(bad_f = 0, 'OK', 'DIFF') FROM a
UNION ALL SELECT 'credit_last_sum_ne_1', '0', CAST(bad_l AS STRING), IF(bad_l = 0, 'OK', 'DIFF') FROM a
UNION ALL SELECT 'credit_decay_sum_ne_1', '0', CAST(bad_d AS STRING), IF(bad_d = 0, 'OK', 'DIFF') FROM a
UNION ALL SELECT 'credit_first_nd_sum_ne_1', '0', CAST(bad_fn AS STRING), IF(bad_fn = 0, 'OK', 'DIFF') FROM a
UNION ALL SELECT 'credit_last_nd_sum_ne_1', '0', CAST(bad_ln AS STRING), IF(bad_ln = 0, 'OK', 'DIFF') FROM a
UNION ALL SELECT 'credit_decay_nd_sum_ne_1', '0', CAST(bad_dn AS STRING), IF(bad_dn = 0, 'OK', 'DIFF') FROM a
UNION ALL SELECT 'touch_after_order', '0', CAST(future AS STRING), IF(future = 0, 'OK', 'DIFF') FROM a
UNION ALL SELECT 'max_days_before_order_le_30', '<= 30', CAST(max_days AS STRING), IF(max_days <= 30, 'OK', 'DIFF') FROM a
UNION ALL SELECT 'path_len_consistent', '0', CAST(bad_len AS STRING), IF(bad_len = 0, 'OK', 'DIFF') FROM a
UNION ALL SELECT 'first_touch_position', '0', CAST(bad_first_pos AS STRING), IF(bad_first_pos = 0, 'OK', 'DIFF') FROM pos
UNION ALL SELECT 'last_touch_position', '0', CAST(bad_last_pos AS STRING), IF(bad_last_pos = 0, 'OK', 'DIFF') FROM pos
UNION ALL SELECT 'touch_before_prev_order', '0', CAST(cross_prev AS STRING), IF(cross_prev = 0, 'OK', 'DIFF') FROM pos
UNION ALL SELECT 'touch_rows', '', CAST(touch_rows AS STRING), 'INFO' FROM a
ORDER BY check_name
