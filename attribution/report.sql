-- Day 08：歸因報表，五段查詢，run.sh 會以分號切開逐段印出

-- ① 全部訂單，direct 也算觸點：看 direct 怎麼吃掉最後接觸
SELECT
  channel,
  ROUND(SUM(credit_first), 1) AS first_touch,
  ROUND(SUM(credit_last), 1)  AS last_touch,
  ROUND(SUM(credit_decay), 1) AS time_decay,
  ROUND(SUM(credit_last_nd), 1) AS last_touch_nd
FROM martech_dw.mart_attribution
WHERE order_date >= DATE '2000-01-01'
GROUP BY channel
ORDER BY first_touch DESC;

-- ② 主表：首購、回溯窗口完整、direct 不算觸點，三種規則分到的訂單數與營收
SELECT
  channel,
  ROUND(SUM(credit_first_nd), 1) AS first_touch,
  ROUND(SUM(credit_last_nd), 1)  AS last_touch,
  ROUND(SUM(credit_decay_nd), 1) AS time_decay,
  ROUND(SUM(credit_first_nd * revenue)) AS revenue_first,
  ROUND(SUM(credit_last_nd * revenue))  AS revenue_last,
  ROUND(SUM(credit_decay_nd * revenue)) AS revenue_decay
FROM martech_dw.mart_attribution
WHERE order_date >= DATE '2000-01-01' AND NOT is_repeat AND NOT window_truncated
GROUP BY channel
ORDER BY first_touch DESC;

-- ③ 路徑長度分佈：只有一個觸點的訂單，三種規則的答案都一樣
SELECT
  LEAST(path_len, 5) AS path_len_capped,
  COUNT(*) AS orders,
  COUNTIF(is_repeat) AS repeat_orders,
  COUNTIF(window_truncated) AS truncated_orders
FROM martech_dw.mart_attribution
WHERE order_date >= DATE '2000-01-01' AND touch_seq = 1
GROUP BY path_len_capped
ORDER BY path_len_capped;

-- ④ 路徑有多長（天）：回溯窗口完整的多觸點訂單，第一個觸點距離下單的天數分位數，決定半衰期設多少才有意義
SELECT
  is_repeat,
  COUNT(*) AS orders,
  APPROX_QUANTILES(days_before_order, 100)[OFFSET(50)] AS p50_days,
  APPROX_QUANTILES(days_before_order, 100)[OFFSET(90)] AS p90_days
FROM martech_dw.mart_attribution
WHERE order_date >= DATE '2000-01-01' AND touch_seq = 1 AND path_len >= 2 AND NOT window_truncated
GROUP BY is_repeat
ORDER BY is_repeat;

-- ⑤ 秋日專案期間（9/1–9/16）各活動分到的功勞，direct 不算觸點
SELECT
  utm_campaign,
  ROUND(SUM(credit_first_nd), 1) AS first_touch,
  ROUND(SUM(credit_last_nd), 1)  AS last_touch,
  ROUND(SUM(credit_decay_nd), 1) AS time_decay
FROM martech_dw.mart_attribution
WHERE order_date BETWEEN DATE '2026-09-01' AND DATE '2026-09-16'
GROUP BY utm_campaign
ORDER BY time_decay DESC;
