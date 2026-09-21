-- Day 07：raw 表 → 星狀綱要（先跑 ddl.sql 建空表，再跑這份灌資料）
-- @@GA4_DATASET@@ 由 build.sh 自動換成 analytics_<資源 ID>，儲存庫裡不寫死
-- 整份是一個多陳述式指令碼，每張表先 TRUNCATE 再 INSERT，重跑結果相同

-- ── GA4 攤平（events_2* 只會對到 events_YYYYMMDD 每日表，排除 events_intraday_*） ──
CREATE TEMP TABLE ga4_flat AS
WITH src AS (
  SELECT
    e.*,
    (SELECT COALESCE(p.value.int_value, SAFE_CAST(p.value.string_value AS INT64))
       FROM UNNEST(e.event_params) p WHERE p.key = 'ga_session_id') AS sid,
    -- UTM：優先用 collected_traffic_source，沒有再看事件參數
    COALESCE(e.collected_traffic_source.manual_source,
      (SELECT p.value.string_value FROM UNNEST(e.event_params) p WHERE p.key = 'source')) AS ev_source,
    COALESCE(e.collected_traffic_source.manual_medium,
      (SELECT p.value.string_value FROM UNNEST(e.event_params) p WHERE p.key = 'medium')) AS ev_medium,
    COALESCE(e.collected_traffic_source.manual_campaign_name,
      (SELECT p.value.string_value FROM UNNEST(e.event_params) p WHERE p.key = 'campaign')) AS ev_campaign
  FROM `@@GA4_DATASET@@.events_2*` AS e
  WHERE REGEXP_CONTAINS(_TABLE_SUFFIX, r'^\d{7}$')
    -- consent mode 的無 Cookie 事件沒有訪客 ID，不進事實表，check.sql 會列出筆數
    AND e.user_pseudo_id IS NOT NULL
),
utm AS (
  -- 來源、媒介、活動取自同一個事件，避免同一個工作階段拼出不存在的組合
  SELECT
    src.*,
    FIRST_VALUE(IF(ev_source IS NULL AND ev_medium IS NULL AND ev_campaign IS NULL, NULL,
      STRUCT(ev_source AS s, ev_medium AS m, ev_campaign AS c)) IGNORE NULLS) OVER w AS first_utm
  FROM src
  WINDOW w AS (
    PARTITION BY user_pseudo_id, COALESCE(sid, event_timestamp) ORDER BY event_timestamp
    ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING
  )
)
SELECT
  PARSE_DATE('%Y%m%d', event_date) AS event_dt,
  event_date,
  event_timestamp,
  event_name,
  user_pseudo_id,
  sid AS ga_session_id,
  user_id AS customer_id,
  -- GA4 只在帶 UTM 的那一個事件記來源，合成資料是整個工作階段都帶，這裡補齊成工作階段層級
  COALESCE(first_utm.s, '(direct)') AS utm_source,
  COALESCE(first_utm.m, '(none)') AS utm_medium,
  COALESCE(first_utm.c, '(direct)') AS utm_campaign,
  (SELECT p.value.string_value FROM UNNEST(event_params) p WHERE p.key = 'creative_name') AS creative_id,
  (SELECT p.value.string_value FROM UNNEST(event_params) p WHERE p.key = 'promotion_id') AS promotion_id,
  IF(ARRAY_LENGTH(items) = 1, NULLIF(items[SAFE_OFFSET(0)].item_id, '(not set)'), NULL) AS item_id,
  IF(ARRAY_LENGTH(items) = 1, NULLIF(items[SAFE_OFFSET(0)].item_variant, '(not set)'), NULL) AS item_variant,
  IF(ARRAY_LENGTH(items) = 1, items[SAFE_OFFSET(0)].quantity, NULL) AS quantity,
  ARRAY_LENGTH(items) AS item_count,
  -- value 參數送整數時存在 int_value，送小數時存在 double_value，三種都要看
  (SELECT COALESCE(CAST(p.value.int_value AS FLOAT64), p.value.double_value, CAST(p.value.float_value AS FLOAT64))
     FROM UNNEST(event_params) p WHERE p.key = 'value') AS value,
  COALESCE(NULLIF(ecommerce.transaction_id, '(not set)'),
    (SELECT p.value.string_value FROM UNNEST(event_params) p WHERE p.key = 'transaction_id')) AS transaction_id,
  'ga4' AS data_source
FROM utm;

-- ── fct_events：合成資料＋GA4 ──
TRUNCATE TABLE martech_dw.fct_events;
INSERT INTO martech_dw.fct_events (
  event_dt, event_date, event_timestamp, event_name, user_pseudo_id, ga_session_id,
  customer_id, utm_source, utm_medium, utm_campaign, creative_id, promotion_id,
  item_id, item_variant, quantity, item_count, value, transaction_id, data_source)
SELECT
  PARSE_DATE('%Y%m%d', event_date), event_date, event_timestamp, event_name, user_pseudo_id, ga_session_id,
  customer_id, utm_source, utm_medium, utm_campaign, creative_id, promotion_id,
  item_id, item_variant, quantity, IF(item_id IS NULL, 0, 1), value, transaction_id,
  COALESCE(data_source, 'synthetic')
FROM martech_dw.raw_events
UNION ALL
SELECT
  event_dt, event_date, event_timestamp, event_name, user_pseudo_id, ga_session_id,
  customer_id, utm_source, utm_medium, utm_campaign, creative_id, promotion_id,
  item_id, item_variant, quantity, item_count, value, transaction_id, data_source
FROM ga4_flat;

-- ── fct_ad_daily ──
TRUNCATE TABLE martech_dw.fct_ad_daily;
INSERT INTO martech_dw.fct_ad_daily
  (date, creative_id, channel, ad_group_id, utm_campaign, impressions, clicks, cost, data_source)
SELECT date, creative_id, channel, ad_group_id, utm_campaign, impressions, clicks, cost, 'synthetic'
FROM martech_dw.raw_ad_daily;

-- ── fct_orders（Live Demo 站沒有訂單資料庫，真實成交只在 fct_events 的 purchase） ──
TRUNCATE TABLE martech_dw.fct_orders;
INSERT INTO martech_dw.fct_orders
  (order_date, transaction_id, order_ts, customer_id, user_pseudo_id, item_id, item_variant,
   quantity, unit_price, revenue, utm_source, utm_medium, utm_campaign, payment_status, data_source)
SELECT order_date, transaction_id, order_ts, customer_id, user_pseudo_id, item_id, item_variant,
   quantity, unit_price, revenue, utm_source, utm_medium, utm_campaign, payment_status, 'synthetic'
FROM martech_dw.raw_orders;

-- ── dim_creative ──
TRUNCATE TABLE martech_dw.dim_creative;
INSERT INTO martech_dw.dim_creative
SELECT creative_id, channel, utm_campaign, promotion_id, ad_group_id, audience, format,
  start_date, end_date, product_focus, has_person, cta_position, dominant_color, text_density, image_file
FROM martech_dw.raw_creatives;

-- ── dim_customer（不帶個資） ──
TRUNCATE TABLE martech_dw.dim_customer;
INSERT INTO martech_dw.dim_customer (customer_id, city, first_order_date)
SELECT customer_id, city, first_order_date FROM martech_dw.raw_customers;

-- ── dim_product ──
TRUNCATE TABLE martech_dw.dim_product;
INSERT INTO martech_dw.dim_product (item_id, unit_price, promotion_ids, first_seen_date)
WITH seen AS (
  SELECT item_id, MIN(d) AS first_seen_date FROM (
    SELECT item_id, event_dt AS d FROM martech_dw.fct_events
    WHERE event_dt >= DATE '2000-01-01' AND item_id IS NOT NULL
    UNION ALL
    SELECT item_id, order_date FROM martech_dw.fct_orders WHERE item_id IS NOT NULL
    UNION ALL
    -- 素材主打但從未出現在事件或訂單的商品也要有一列，日期取素材上線日
    SELECT product_focus, start_date FROM martech_dw.raw_creatives WHERE product_focus IS NOT NULL)
  GROUP BY item_id
),
price AS (
  SELECT item_id, APPROX_TOP_COUNT(unit_price, 1)[OFFSET(0)].value AS unit_price
  FROM martech_dw.fct_orders WHERE item_id IS NOT NULL GROUP BY item_id
),
promo AS (
  SELECT product_focus AS item_id, ARRAY_AGG(DISTINCT promotion_id ORDER BY promotion_id) AS promotion_ids
  FROM martech_dw.raw_creatives WHERE promotion_id IS NOT NULL AND product_focus IS NOT NULL
  GROUP BY product_focus
)
SELECT s.item_id, p.unit_price, IFNULL(pr.promotion_ids, []), s.first_seen_date
FROM seen s LEFT JOIN price p USING (item_id) LEFT JOIN promo pr USING (item_id);

-- ── dim_date（涵蓋三張事實表的完整期間） ──
TRUNCATE TABLE martech_dw.dim_date;
INSERT INTO martech_dw.dim_date (date, event_date, week_start, day_of_week, is_weekend, promotion_ids)
WITH bounds AS (
  SELECT MIN(d) AS lo, MAX(d) AS hi FROM (
    SELECT MIN(event_dt) AS d FROM martech_dw.fct_events WHERE event_dt >= DATE '2000-01-01'
    UNION ALL SELECT MAX(event_dt) FROM martech_dw.fct_events WHERE event_dt >= DATE '2000-01-01'
    UNION ALL SELECT MIN(date) FROM martech_dw.fct_ad_daily
    UNION ALL SELECT MAX(date) FROM martech_dw.fct_ad_daily
    UNION ALL SELECT MIN(order_date) FROM martech_dw.fct_orders
    UNION ALL SELECT MAX(order_date) FROM martech_dw.fct_orders)
),
days AS (
  SELECT d FROM bounds, UNNEST(GENERATE_DATE_ARRAY(lo, hi)) AS d
),
promo_days AS (
  SELECT days.d, ARRAY_AGG(DISTINCT c.promotion_id ORDER BY c.promotion_id) AS ids
  FROM days JOIN martech_dw.raw_creatives c
    ON c.promotion_id IS NOT NULL AND days.d BETWEEN c.start_date AND c.end_date
  GROUP BY days.d
)
SELECT
  days.d,
  FORMAT_DATE('%Y%m%d', days.d),
  DATE_TRUNC(days.d, WEEK(MONDAY)),
  EXTRACT(DAYOFWEEK FROM days.d),
  EXTRACT(DAYOFWEEK FROM days.d) IN (1, 7),
  IFNULL(p.ids, [])
FROM days LEFT JOIN promo_days p USING (d);
