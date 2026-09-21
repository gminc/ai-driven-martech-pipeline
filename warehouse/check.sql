-- Day 07：合併前後對帳
-- before 從 raw 表與 GA4 巢狀原始表直接算，after 從星狀綱要算，兩邊程式碼互不共用
-- 每列輸出 check、before、after、ok；浮點數先四捨五入再比，info. 開頭只列數字不判定
-- fct_events 設了 require_partition_filter，所以一律加上 event_dt >= '2000-01-01'
WITH
ga_all AS (
  SELECT * FROM `@@GA4_DATASET@@.events_2*` WHERE REGEXP_CONTAINS(_TABLE_SUFFIX, r'^\d{7}$')
),
ga AS (SELECT * FROM ga_all WHERE user_pseudo_id IS NOT NULL),
ga_s AS (
  SELECT *,
    (SELECT COALESCE(value.int_value, SAFE_CAST(value.string_value AS INT64))
       FROM UNNEST(event_params) WHERE key = 'ga_session_id') AS sid
  FROM ga
),
fe AS (SELECT * FROM martech_dw.fct_events WHERE event_dt >= DATE '2000-01-01'),
fe_syn AS (SELECT * FROM fe WHERE data_source = 'synthetic'),
fe_ga4 AS (SELECT * FROM fe WHERE data_source = 'ga4'),
-- 事件名稱逐項比對（合成、GA4 各一組）
name_before AS (
  SELECT 'synthetic' AS src, event_name, COUNT(*) AS n FROM martech_dw.raw_events GROUP BY event_name
  UNION ALL SELECT 'ga4', event_name, COUNT(*) FROM ga GROUP BY event_name
),
name_after AS (SELECT data_source AS src, event_name, COUNT(*) AS n FROM fe GROUP BY 1, 2),
names AS (
  SELECT CONCAT('events.', src, '.', event_name) AS check_name,
         CAST(IFNULL(b.n, 0) AS STRING) AS before, CAST(IFNULL(a.n, 0) AS STRING) AS after
  FROM name_before b FULL OUTER JOIN name_after a USING (src, event_name)
),
checks AS (
  -- ── 列數 ──
  SELECT 'rows.fct_events.synthetic' AS check_name,
    CAST((SELECT COUNT(*) FROM martech_dw.raw_events) AS STRING) AS before,
    CAST((SELECT COUNT(*) FROM fe_syn) AS STRING) AS after
  UNION ALL SELECT 'rows.fct_events.ga4',
    CAST((SELECT COUNT(*) FROM ga) AS STRING), CAST((SELECT COUNT(*) FROM fe_ga4) AS STRING)
  UNION ALL SELECT 'rows.fct_events.total',
    CAST((SELECT COUNT(*) FROM martech_dw.raw_events) + (SELECT COUNT(*) FROM ga) AS STRING),
    CAST((SELECT COUNT(*) FROM fe) AS STRING)
  UNION ALL SELECT 'rows.fct_ad_daily',
    CAST((SELECT COUNT(*) FROM martech_dw.raw_ad_daily) AS STRING),
    CAST((SELECT COUNT(*) FROM martech_dw.fct_ad_daily) AS STRING)
  UNION ALL SELECT 'rows.fct_orders',
    CAST((SELECT COUNT(*) FROM martech_dw.raw_orders) AS STRING),
    CAST((SELECT COUNT(*) FROM martech_dw.fct_orders) AS STRING)
  UNION ALL SELECT 'rows.dim_creative',
    CAST((SELECT COUNT(*) FROM martech_dw.raw_creatives) AS STRING),
    CAST((SELECT COUNT(*) FROM martech_dw.dim_creative) AS STRING)
  UNION ALL SELECT 'rows.dim_customer',
    CAST((SELECT COUNT(*) FROM martech_dw.raw_customers) AS STRING),
    CAST((SELECT COUNT(*) FROM martech_dw.dim_customer) AS STRING)
  UNION ALL SELECT 'rows.dim_product',
    CAST((SELECT COUNT(DISTINCT item_id) FROM (
        SELECT item_id FROM martech_dw.raw_events UNION ALL SELECT item_id FROM martech_dw.raw_orders
        UNION ALL SELECT product_focus FROM martech_dw.raw_creatives
        UNION ALL SELECT NULLIF(i.item_id, '(not set)') FROM ga, UNNEST(items) i WHERE ARRAY_LENGTH(ga.items) = 1)) AS STRING),
    CAST((SELECT COUNT(*) FROM martech_dw.dim_product) AS STRING)
  -- ── 合成資料關鍵指標（與 Day 06 對帳值同一套定義） ──
  UNION ALL SELECT 'ad.cost',
    CAST((SELECT SUM(cost) FROM martech_dw.raw_ad_daily) AS STRING),
    CAST((SELECT SUM(cost) FROM martech_dw.fct_ad_daily) AS STRING)
  UNION ALL SELECT 'ad.impressions',
    CAST((SELECT SUM(impressions) FROM martech_dw.raw_ad_daily) AS STRING),
    CAST((SELECT SUM(impressions) FROM martech_dw.fct_ad_daily) AS STRING)
  UNION ALL SELECT 'ad.clicks',
    CAST((SELECT SUM(clicks) FROM martech_dw.raw_ad_daily) AS STRING),
    CAST((SELECT SUM(clicks) FROM martech_dw.fct_ad_daily) AS STRING)
  UNION ALL SELECT 'orders.revenue',
    CAST((SELECT SUM(revenue) FROM martech_dw.raw_orders) AS STRING),
    CAST((SELECT SUM(revenue) FROM martech_dw.fct_orders) AS STRING)
  UNION ALL SELECT 'orders.distinct_transaction',
    CAST((SELECT COUNT(DISTINCT transaction_id) FROM martech_dw.raw_orders) AS STRING),
    CAST((SELECT COUNT(DISTINCT transaction_id) FROM martech_dw.fct_orders) AS STRING)
  UNION ALL SELECT 'synthetic.value_sum',
    FORMAT('%.2f', (SELECT ROUND(SUM(value), 2) FROM martech_dw.raw_events)),
    FORMAT('%.2f', (SELECT ROUND(SUM(value), 2) FROM fe_syn))
  UNION ALL SELECT 'synthetic.users',
    CAST((SELECT COUNT(DISTINCT user_pseudo_id) FROM martech_dw.raw_events) AS STRING),
    CAST((SELECT COUNT(DISTINCT user_pseudo_id) FROM fe_syn) AS STRING)
  UNION ALL SELECT 'synthetic.sessions',
    CAST((SELECT COUNT(DISTINCT CONCAT(user_pseudo_id, '.', IFNULL(CAST(ga_session_id AS STRING), 'null'))) FROM martech_dw.raw_events) AS STRING),
    CAST((SELECT COUNT(DISTINCT CONCAT(user_pseudo_id, '.', IFNULL(CAST(ga_session_id AS STRING), 'null'))) FROM fe_syn) AS STRING)
  UNION ALL SELECT 'synthetic.cvr_session',
    FORMAT('%.6f', (SELECT COUNT(*) FROM martech_dw.raw_orders)
      / (SELECT COUNT(DISTINCT CONCAT(user_pseudo_id, '.', IFNULL(CAST(ga_session_id AS STRING), 'null'))) FROM martech_dw.raw_events)),
    FORMAT('%.6f', (SELECT COUNT(*) FROM martech_dw.fct_orders)
      / (SELECT COUNT(DISTINCT CONCAT(user_pseudo_id, '.', IFNULL(CAST(ga_session_id AS STRING), 'null'))) FROM fe_syn))
  UNION ALL SELECT 'synthetic.aov',
    FORMAT('%.6f', (SELECT SUM(revenue) / COUNT(*) FROM martech_dw.raw_orders)),
    FORMAT('%.6f', (SELECT SUM(revenue) / COUNT(*) FROM martech_dw.fct_orders))
  -- ── GA4 攤平（before 直接讀巢狀欄位，after 讀攤平後的欄位） ──
  UNION ALL SELECT 'ga4.users',
    CAST((SELECT COUNT(DISTINCT user_pseudo_id) FROM ga) AS STRING),
    CAST((SELECT COUNT(DISTINCT user_pseudo_id) FROM fe_ga4) AS STRING)
  UNION ALL SELECT 'ga4.sessions',
    CAST((SELECT COUNT(DISTINCT CONCAT(user_pseudo_id, '.', IFNULL(CAST(sid AS STRING), 'null'))) FROM ga_s) AS STRING),
    CAST((SELECT COUNT(DISTINCT CONCAT(user_pseudo_id, '.', IFNULL(CAST(ga_session_id AS STRING), 'null'))) FROM fe_ga4) AS STRING)
  UNION ALL SELECT 'ga4.purchase_revenue',
    FORMAT('%.6f', (SELECT IFNULL(SUM(ecommerce.purchase_revenue), 0) FROM ga WHERE event_name = 'purchase')),
    FORMAT('%.6f', (SELECT IFNULL(SUM(value), 0) FROM fe_ga4 WHERE event_name = 'purchase'))
  UNION ALL SELECT 'ga4.transactions',
    CAST((SELECT COUNT(DISTINCT tx) FROM (
            SELECT COALESCE(NULLIF(ecommerce.transaction_id, '(not set)'),
              (SELECT value.string_value FROM UNNEST(event_params) WHERE key = 'transaction_id')) AS tx
            FROM ga)) AS STRING),
    CAST((SELECT COUNT(DISTINCT transaction_id) FROM fe_ga4) AS STRING)
  UNION ALL SELECT 'ga4.items',
    CAST((SELECT IFNULL(SUM(ARRAY_LENGTH(items)), 0) FROM ga) AS STRING),
    CAST((SELECT IFNULL(SUM(item_count), 0) FROM fe_ga4) AS STRING)
  UNION ALL SELECT 'ga4.events_with_value',
    CAST((SELECT COUNT(*) FROM ga WHERE EXISTS (SELECT 1 FROM UNNEST(event_params) WHERE key = 'value')) AS STRING),
    CAST((SELECT COUNTIF(value IS NOT NULL) FROM fe_ga4) AS STRING)
  UNION ALL SELECT 'info.ga4_rows_without_user_pseudo_id', '-',
    CAST((SELECT COUNTIF(user_pseudo_id IS NULL) FROM ga_all) AS STRING)
  UNION ALL SELECT 'info.ga4_creative_not_in_dim', '-',
    CAST((SELECT COUNT(*) FROM fe_ga4 f LEFT JOIN martech_dw.dim_creative d USING (creative_id)
          WHERE f.creative_id IS NOT NULL AND d.creative_id IS NULL) AS STRING)
  UNION ALL SELECT 'ga4.not_set_left', '0',
    CAST((SELECT COUNTIF(item_variant = '(not set)' OR transaction_id = '(not set)') FROM fe_ga4) AS STRING)
  UNION ALL SELECT 'info.ga4_null_session_id', '-',
    CAST((SELECT COUNTIF(ga_session_id IS NULL) FROM fe_ga4) AS STRING)
  UNION ALL SELECT 'ga4.null_utm_source', '0',
    CAST((SELECT COUNTIF(utm_source IS NULL) FROM fe_ga4) AS STRING)
  -- ── 型別、時區與參照完整性 ──
  UNION ALL SELECT 'check.event_dt_vs_taipei', '0',
    CAST((SELECT COUNTIF(event_dt != DATE(TIMESTAMP_MICROS(event_timestamp), 'Asia/Taipei')) FROM fe) AS STRING)
  UNION ALL SELECT 'check.orphan_ad_creative', '0',
    CAST((SELECT COUNT(*) FROM martech_dw.fct_ad_daily f LEFT JOIN martech_dw.dim_creative d USING (creative_id)
          WHERE d.creative_id IS NULL) AS STRING)
  UNION ALL SELECT 'check.orphan_synthetic_event_creative', '0',
    CAST((SELECT COUNT(*) FROM fe_syn f LEFT JOIN martech_dw.dim_creative d USING (creative_id)
          WHERE f.creative_id IS NOT NULL AND d.creative_id IS NULL) AS STRING)
  UNION ALL SELECT 'check.orphan_order_customer', '0',
    CAST((SELECT COUNT(*) FROM martech_dw.fct_orders f LEFT JOIN martech_dw.dim_customer d USING (customer_id)
          WHERE f.customer_id IS NOT NULL AND d.customer_id IS NULL) AS STRING)
  UNION ALL SELECT 'check.orphan_order_product', '0',
    CAST((SELECT COUNT(*) FROM martech_dw.fct_orders f LEFT JOIN martech_dw.dim_product d USING (item_id)
          WHERE f.item_id IS NOT NULL AND d.item_id IS NULL) AS STRING)
  UNION ALL SELECT 'check.fact_dates_missing_in_dim_date', '0',
    CAST((SELECT COUNT(*) FROM (
            SELECT DISTINCT event_dt AS d FROM fe
            UNION DISTINCT SELECT date FROM martech_dw.fct_ad_daily
            UNION DISTINCT SELECT order_date FROM martech_dw.fct_orders) x
          LEFT JOIN martech_dw.dim_date dd ON dd.date = x.d WHERE dd.date IS NULL) AS STRING)
  UNION ALL SELECT 'check.dim_customer_pii_columns', '0',
    CAST((SELECT COUNT(*) FROM martech_dw.INFORMATION_SCHEMA.COLUMNS
          WHERE table_name = 'dim_customer' AND column_name IN ('name', 'email', 'phone')) AS STRING)
  UNION ALL SELECT 'check.partition_columns', 'date,event_dt,order_date',
    (SELECT STRING_AGG(column_name ORDER BY column_name) FROM martech_dw.INFORMATION_SCHEMA.COLUMNS
     WHERE table_name IN ('fct_ad_daily', 'fct_events', 'fct_orders') AND is_partitioning_column = 'YES')
  UNION ALL SELECT 'check.cluster_columns', 'fct_ad_daily:channel,creative_id|fct_events:event_name,user_pseudo_id|fct_orders:customer_id',
    (SELECT STRING_AGG(CONCAT(table_name, ':', cols), '|' ORDER BY table_name) FROM (
       SELECT table_name, STRING_AGG(column_name, ',' ORDER BY clustering_ordinal_position) AS cols
       FROM martech_dw.INFORMATION_SCHEMA.COLUMNS
       WHERE table_name IN ('fct_ad_daily', 'fct_events', 'fct_orders') AND clustering_ordinal_position IS NOT NULL
       GROUP BY table_name))
  UNION ALL SELECT * FROM names
)
SELECT check_name, before, after,
  CASE WHEN STARTS_WITH(check_name, 'info.') THEN 'INFO' WHEN before = after THEN 'OK' ELSE 'DIFF' END AS ok
FROM checks
ORDER BY ok, check_name;
