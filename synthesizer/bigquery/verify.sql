-- Day 06：在 BigQuery 端重算一份指標，由 reconcile.py 和本機 CSV 算出的同一份指標逐項對帳
-- 參數由 reconcile.py 從 ground_truth.json 帶入，資料表用 --dataset_id 指定的預設資料集
-- 每一列是 (metric, value)，value 一律轉成字串，浮點數由 reconcile.py 容許 1e-9 相對誤差

WITH
ev AS (SELECT * FROM raw_events),
od AS (SELECT * FROM raw_orders),
ad AS (SELECT * FROM raw_ad_daily),
cr AS (SELECT * FROM raw_creatives),
cu AS (SELECT * FROM raw_customers),

sessions AS (
  SELECT DISTINCT user_pseudo_id, ga_session_id FROM ev WHERE event_name = 'session_start'
),

-- S3：每日 CTR 取對數，對週數做線性迴歸
s3 AS (
  SELECT DATE_DIFF(date, @s3_anchor, DAY) / 7 AS x, LN(clicks / impressions) AS y
  FROM ad
  WHERE creative_id = @s3_creative AND clicks > 0 AND date >= @s3_anchor
),

-- S4：圖片素材（排除 S3 素材）的素材層級 CTR，在同通路同受眾內比較幾何平均
per_creative AS (
  SELECT c.creative_id, c.channel, c.audience,
         IFNULL(c.has_person, FALSE) AS f_person,
         IFNULL(c.cta_position = 'bottom_right', FALSE) AS f_cta,
         IFNULL(c.dominant_color = 'warm', FALSE) AS f_warm,
         SUM(a.clicks) / SUM(a.impressions) AS ctr
  FROM ad a JOIN cr c USING (creative_id)
  WHERE c.format = 'image' AND a.creative_id != @s3_creative
  GROUP BY 1, 2, 3, 4, 5, 6
),
s4_long AS (
  SELECT channel, audience, 'person' AS attr, f_person AS flag, ctr FROM per_creative
  UNION ALL SELECT channel, audience, 'cta', f_cta, ctr FROM per_creative
  UNION ALL SELECT channel, audience, 'warm', f_warm, ctr FROM per_creative
),
s4_strata AS (
  SELECT attr, channel, audience,
         EXP(AVG(IF(flag, LN(ctr), NULL))) AS gy,
         EXP(AVG(IF(NOT flag, LN(ctr), NULL))) AS gn,
         COUNTIF(flag) AS ny, COUNTIF(NOT flag) AS nn
  FROM s4_long GROUP BY 1, 2, 3
  HAVING COUNTIF(flag) > 0 AND COUNTIF(NOT flag) > 0
),
s4 AS (
  SELECT attr, EXP(SUM(LN(gy / gn) * ny * nn / (ny + nn)) / SUM(ny * nn / (ny + nn))) AS est
  FROM s4_strata GROUP BY attr
),

-- S5：每位顧客的訂單數分佈（答案表不進倉儲，類型對應只在本機檢查）
s5 AS (
  SELECT n, COUNT(*) AS customers
  FROM (SELECT customer_id, LEAST(COUNT(*), 3) AS n FROM od GROUP BY customer_id)
  GROUP BY n
),

-- S6：第一次購買之前、至少兩次造訪的路徑，第一與最後一個觸點
first_tx AS (
  SELECT user_pseudo_id, ARRAY_AGG(transaction_id ORDER BY order_ts, transaction_id LIMIT 1)[OFFSET(0)] AS tx
  FROM od GROUP BY user_pseudo_id
),
buy AS (
  SELECT e.user_pseudo_id, e.event_timestamp AS ts
  FROM ev e JOIN first_tx f ON e.user_pseudo_id = f.user_pseudo_id AND e.transaction_id = f.tx
  WHERE e.event_name = 'purchase'
),
paths AS (
  SELECT b.user_pseudo_id,
         ARRAY_AGG(STRUCT(e.event_timestamp AS ts,
                          CONCAT(IFNULL(e.utm_source, ''), '/', IFNULL(e.utm_medium, '')) AS src)
                   ORDER BY e.event_timestamp, CONCAT(IFNULL(e.utm_source, ''), '/', IFNULL(e.utm_medium, ''))) AS p
  FROM buy b JOIN ev e
    ON e.user_pseudo_id = b.user_pseudo_id AND e.event_name = 'session_start' AND e.event_timestamp <= b.ts
  GROUP BY b.user_pseudo_id
),
touch AS (
  SELECT p[OFFSET(0)].src AS first_src, p[OFFSET(ARRAY_LENGTH(p) - 1)].src AS last_src
  FROM paths WHERE ARRAY_LENGTH(p) >= 2
),

-- S7：專案期間與前三週的專案商品件數占比
s7 AS (
  SELECT
    SAFE_DIVIDE(SUM(IF(order_date BETWEEN @s7_start AND @s7_end AND item_id IN UNNEST(@s7_products), quantity, 0)),
                SUM(IF(order_date BETWEEN @s7_start AND @s7_end, quantity, 0))) AS win,
    SAFE_DIVIDE(SUM(IF(order_date >= DATE_SUB(@s7_start, INTERVAL 21 DAY) AND order_date < @s7_start
                       AND item_id IN UNNEST(@s7_products), quantity, 0)),
                SUM(IF(order_date >= DATE_SUB(@s7_start, INTERVAL 21 DAY) AND order_date < @s7_start, quantity, 0))) AS pre
  FROM od
)

-- ── 列數與總量 ──
SELECT 'rows.raw_creatives' AS metric, CAST((SELECT COUNT(*) FROM cr) AS STRING) AS value
UNION ALL SELECT 'rows.raw_ad_daily', CAST((SELECT COUNT(*) FROM ad) AS STRING)
UNION ALL SELECT 'rows.raw_events', CAST((SELECT COUNT(*) FROM ev) AS STRING)
UNION ALL SELECT 'rows.raw_orders', CAST((SELECT COUNT(*) FROM od) AS STRING)
UNION ALL SELECT 'rows.raw_customers', CAST((SELECT COUNT(*) FROM cu) AS STRING)
UNION ALL SELECT 'ad.impressions', CAST((SELECT SUM(impressions) FROM ad) AS STRING)
UNION ALL SELECT 'ad.clicks', CAST((SELECT SUM(clicks) FROM ad) AS STRING)
UNION ALL SELECT 'ad.cost', FORMAT('%.2f', (SELECT CAST(SUM(cost) AS FLOAT64) FROM ad))
UNION ALL SELECT 'orders.revenue', CAST((SELECT SUM(revenue) FROM od) AS STRING)
UNION ALL SELECT 'orders.quantity', CAST((SELECT SUM(quantity) FROM od) AS STRING)
UNION ALL SELECT 'orders.customers', CAST((SELECT COUNT(DISTINCT customer_id) FROM od) AS STRING)
UNION ALL SELECT 'events.users', CAST((SELECT COUNT(DISTINCT user_pseudo_id) FROM ev) AS STRING)
UNION ALL SELECT 'events.sessions', CAST((SELECT COUNT(*) FROM sessions) AS STRING)
UNION ALL SELECT 'events.purchase_value', FORMAT('%.2f', (SELECT SUM(value) FROM ev WHERE event_name = 'purchase'))
UNION ALL SELECT CONCAT('events.', event_name), CAST(COUNT(*) AS STRING) FROM ev GROUP BY event_name
-- ── 期間與型別檢查 ──
UNION ALL SELECT 'events.min_date', (SELECT MIN(event_date) FROM ev)
UNION ALL SELECT 'events.max_date', (SELECT MAX(event_date) FROM ev)
UNION ALL SELECT 'orders.min_date', CAST((SELECT MIN(order_date) FROM od) AS STRING)
UNION ALL SELECT 'orders.max_date', CAST((SELECT MAX(order_date) FROM od) AS STRING)
UNION ALL SELECT 'check.event_date_mismatch', CAST((SELECT COUNTIF(event_date != FORMAT_DATE('%Y%m%d',
    DATE(TIMESTAMP_MICROS(event_timestamp), 'Asia/Taipei'))) FROM ev) AS STRING)
UNION ALL SELECT 'check.order_date_mismatch', CAST((SELECT COUNTIF(order_date != DATE(order_ts, 'Asia/Taipei')) FROM od) AS STRING)
UNION ALL SELECT 'check.phone_leading_zero', CAST((SELECT COUNTIF(STARTS_WITH(phone, '0')) FROM cu) AS STRING)
UNION ALL SELECT 'check.user_id_with_dot', CAST((SELECT COUNTIF(STRPOS(user_pseudo_id, '.') > 0) FROM ev) AS STRING)
UNION ALL SELECT 'check.image_has_person_null', CAST((SELECT COUNTIF(format = 'image' AND has_person IS NULL) FROM cr) AS STRING)
-- ── 統計分佈 ──
UNION ALL SELECT CONCAT('ctr.', channel), CAST(SUM(clicks) / SUM(impressions) AS STRING) FROM ad GROUP BY channel
UNION ALL SELECT 'cvr.session', CAST((SELECT COUNT(*) FROM od) / (SELECT COUNT(*) FROM sessions) AS STRING)
UNION ALL SELECT 'aov', CAST((SELECT SUM(revenue) / COUNT(*) FROM od) AS STRING)
-- ── 七個訊號 ──
UNION ALL SELECT 's1.cpc_before', CAST((SELECT CAST(SUM(cost) AS FLOAT64) / SUM(clicks) FROM ad
    WHERE ad_group_id = @s1_group AND date < @s1_start) AS STRING)
UNION ALL SELECT 's1.cpc_after', CAST((SELECT CAST(SUM(cost) AS FLOAT64) / SUM(clicks) FROM ad
    WHERE ad_group_id = @s1_group AND date >= @s1_start) AS STRING)
UNION ALL SELECT 's2.purchase_events', CAST((SELECT COUNT(*) FROM ev
    WHERE event_name = 'purchase' AND event_date = FORMAT_DATE('%Y%m%d', @s2_date)) AS STRING)
UNION ALL SELECT 's2.orders', CAST((SELECT COUNT(*) FROM od WHERE order_date = @s2_date) AS STRING)
UNION ALL SELECT 's2.orders_without_event_elsewhere', CAST((SELECT COUNT(*) FROM od
    WHERE order_date != @s2_date AND transaction_id NOT IN
      (SELECT transaction_id FROM ev WHERE event_name = 'purchase' AND transaction_id IS NOT NULL)) AS STRING)
UNION ALL SELECT 's3.weekly_decay', CAST((SELECT 1 - EXP(COVAR_POP(x, y) / VAR_POP(x)) FROM s3) AS STRING)
UNION ALL SELECT CONCAT('s4.', attr), CAST(est AS STRING) FROM s4
UNION ALL SELECT CONCAT('s5.customers_with_', CAST(n AS STRING), IF(n = 3, '_plus', ''), '_orders'), CAST(customers AS STRING) FROM s5
UNION ALL SELECT 's6.meta_first', CAST((SELECT COUNTIF(first_src = 'meta/paid_social') FROM touch) AS STRING)
UNION ALL SELECT 's6.meta_last', CAST((SELECT COUNTIF(last_src = 'meta/paid_social') FROM touch) AS STRING)
UNION ALL SELECT 's6.google_cpc_first', CAST((SELECT COUNTIF(first_src = 'google/cpc') FROM touch) AS STRING)
UNION ALL SELECT 's6.google_cpc_last', CAST((SELECT COUNTIF(last_src = 'google/cpc') FROM touch) AS STRING)
UNION ALL SELECT 's7.share_pre', CAST((SELECT pre FROM s7) AS STRING)
UNION ALL SELECT 's7.share_window', CAST((SELECT win FROM s7) AS STRING)
