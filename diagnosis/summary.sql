-- Day 09 第一步：把「哪裡變了」算成一張精簡的異常摘要表
-- 廣告群組與素材只留「第一次超過門檻的那一週」，全站則是每一天各自判斷
--   adgroup_week：廣告群組每週的點擊成本與點擊率，和前四週比
--   creative_week：素材每週的點擊率，和素材上線頭 14 天比
--   site_day：全站每天網站追蹤到的購買，和後台訂單對帳
-- 這裡只做數字，不呼叫 AI，也不讀 ground_truth.json
-- 用法：bash diagnosis/run.sh（或單獨貼進 BigQuery 主控台執行）

CREATE OR REPLACE TABLE martech_dw.diag_summary
OPTIONS(description = 'Day 09 異常摘要：群組與素材取第一次超過門檻的那週，全站逐日判斷，交給 Gemini 判讀原因')
AS
WITH
-- ── 通路每週的網站追蹤 ROAS（和廣告後台看到的一樣，只算得到有送出 purchase 事件的訂單）──
ch_rev AS (
  SELECT
    CASE
      WHEN utm_source = 'meta'   AND utm_medium = 'paid_social' THEN 'meta'
      WHEN utm_source = 'line'   AND utm_medium = 'display'     THEN 'line'
      WHEN utm_source = 'google' AND utm_medium = 'cpc'         THEN 'google_cpc'
    END AS channel,
    DATE_TRUNC(event_dt, WEEK(MONDAY)) AS wk,
    SUM(value) AS rev
  FROM martech_dw.fct_events
  WHERE event_dt BETWEEN '2026-06-01' AND '2026-09-30'
    AND event_name = 'purchase' AND data_source = 'synthetic'
  GROUP BY 1, 2
),
ch_week AS (
  SELECT a.channel, DATE_TRUNC(a.date, WEEK(MONDAY)) AS wk, SUM(a.cost) AS cost
  FROM martech_dw.fct_ad_daily a
  WHERE a.date BETWEEN '2026-06-01' AND '2026-09-30'
  GROUP BY 1, 2
),
ch_roas AS (
  SELECT c.channel, c.wk,
    SAFE_DIVIDE(r.rev, CAST(c.cost AS FLOAT64)) AS roas,
    SAFE_DIVIDE(SUM(r.rev) OVER w4, SUM(CAST(c.cost AS FLOAT64)) OVER w4) AS roas_base
  FROM ch_week c LEFT JOIN ch_rev r USING (channel, wk)
  WINDOW w4 AS (PARTITION BY c.channel ORDER BY c.wk ROWS BETWEEN 4 PRECEDING AND 1 PRECEDING)
),

-- ── 1. 廣告群組 × 週 ───────────────────────────────────
ag_week AS (
  SELECT ad_group_id, ANY_VALUE(channel) AS channel,
    DATE_TRUNC(date, WEEK(MONDAY)) AS wk, COUNT(DISTINCT date) AS days,
    SUM(impressions) AS imp, SUM(clicks) AS clk, CAST(SUM(cost) AS FLOAT64) AS cost
  FROM martech_dw.fct_ad_daily
  WHERE date BETWEEN '2026-06-01' AND '2026-09-30'
  GROUP BY 1, 3
),
ag AS (
  SELECT *,
    SAFE_DIVIDE(clk, imp) AS ctr,
    SAFE_DIVIDE(cost, clk) AS cpc,
    SAFE_DIVIDE(SUM(clk) OVER w4, SUM(imp) OVER w4) AS ctr_base,
    SAFE_DIVIDE(SUM(cost) OVER w4, SUM(clk) OVER w4) AS cpc_base,
    SAFE_DIVIDE(SUM(clk) OVER w4, SUM(days) OVER w4) AS clk_per_day_base,
    COUNT(*) OVER w4 AS base_weeks
  FROM ag_week
  WINDOW w4 AS (PARTITION BY ad_group_id ORDER BY wk ROWS BETWEEN 4 PRECEDING AND 1 PRECEDING)
),
ag_flag AS (
  SELECT
    'adgroup_week' AS level,
    ag.ad_group_id AS entity,
    ag.channel,
    ag.wk AS period_start,
    DATE_ADD(ag.wk, INTERVAL 6 DAY) AS period_end,
    STRUCT(
      ag.days, ag.imp, ag.clk, ROUND(ag.cost) AS cost,
      ROUND(100 * ag.ctr, 2) AS ctr_pct, ROUND(100 * ag.ctr_base, 2) AS ctr_base_pct,
      ROUND(ag.cpc, 2) AS cpc, ROUND(ag.cpc_base, 2) AS cpc_base,
      ROUND(ag.clk / ag.days, 1) AS clk_per_day, ROUND(ag.clk_per_day_base, 1) AS clk_per_day_base,
      ROUND(r.roas, 2) AS channel_roas, ROUND(r.roas_base, 2) AS channel_roas_base
    ) AS m,
    ROUND(100 * (ag.cpc / ag.cpc_base - 1)) AS cpc_chg_pct,
    ROUND(100 * (ag.ctr / ag.ctr_base - 1)) AS ctr_chg_pct
  FROM ag
  LEFT JOIN ch_roas r ON r.channel = ag.channel AND r.wk = ag.wk
  WHERE ag.base_weeks >= 2 AND ag.days >= 3
    AND (ABS(SAFE_DIVIDE(ag.cpc, ag.cpc_base) - 1) >= 0.30 OR SAFE_DIVIDE(ag.ctr, ag.ctr_base) - 1 <= -0.20)
  QUALIFY ROW_NUMBER() OVER (PARTITION BY ag.ad_group_id ORDER BY ag.wk) = 1
),

-- ── 2. 素材 × 週（和素材自己上線頭 14 天比）──────────────
cr_day AS (
  SELECT a.*, MIN(a.date) OVER (PARTITION BY a.creative_id) AS launch
  FROM martech_dw.fct_ad_daily a
  WHERE a.date BETWEEN '2026-06-01' AND '2026-09-30'
),
cr_base AS (
  SELECT creative_id,
    SAFE_DIVIDE(SUM(clicks), SUM(impressions)) AS ctr_base,
    SAFE_DIVIDE(CAST(SUM(cost) AS FLOAT64), SUM(clicks)) AS cpc_base
  FROM cr_day WHERE date < DATE_ADD(launch, INTERVAL 14 DAY)
  GROUP BY 1
),
cr_week AS (
  SELECT creative_id, ANY_VALUE(channel) AS channel, ANY_VALUE(launch) AS launch,
    DATE_TRUNC(date, WEEK(MONDAY)) AS wk, COUNT(DISTINCT date) AS days,
    SUM(impressions) AS imp, SUM(clicks) AS clk, CAST(SUM(cost) AS FLOAT64) AS cost
  FROM cr_day
  GROUP BY 1, 4
),
cr_flag AS (
  SELECT
    'creative_week' AS level,
    w.creative_id AS entity,
    w.channel,
    w.wk AS period_start,
    DATE_ADD(w.wk, INTERVAL 6 DAY) AS period_end,
    STRUCT(
      w.days, w.imp, w.clk, ROUND(w.cost) AS cost,
      ROUND(100 * SAFE_DIVIDE(w.clk, w.imp), 2) AS ctr_pct, ROUND(100 * b.ctr_base, 2) AS ctr_base_pct,
      ROUND(SAFE_DIVIDE(w.cost, w.clk), 2) AS cpc, ROUND(b.cpc_base, 2) AS cpc_base,
      DATE_DIFF(w.wk, w.launch, DAY) AS days_since_launch
    ) AS m,
    ROUND(100 * (SAFE_DIVIDE(w.cost, w.clk) / b.cpc_base - 1)) AS cpc_chg_pct,
    ROUND(100 * (SAFE_DIVIDE(w.clk, w.imp) / b.ctr_base - 1)) AS ctr_chg_pct
  FROM cr_week w JOIN cr_base b USING (creative_id)
  WHERE w.wk >= DATE_ADD(w.launch, INTERVAL 14 DAY) AND w.days >= 3
    AND SAFE_DIVIDE(SAFE_DIVIDE(w.clk, w.imp), b.ctr_base) - 1 <= -0.25
  QUALIFY ROW_NUMBER() OVER (PARTITION BY w.creative_id ORDER BY w.wk) = 1
),

-- ── 3. 全站 × 日：網站追蹤到的購買 vs 後台訂單（每一天各自判斷）──
ev_day AS (
  SELECT event_dt AS d, COUNT(*) AS tracked, SUM(value) AS tracked_rev
  FROM martech_dw.fct_events
  WHERE event_dt BETWEEN '2026-06-01' AND '2026-09-30'
    AND event_name = 'purchase' AND data_source = 'synthetic'
  GROUP BY 1
),
od_day AS (
  SELECT order_date AS d, COUNT(*) AS orders, SUM(revenue) AS order_rev
  FROM martech_dw.fct_orders
  WHERE order_date BETWEEN '2026-06-01' AND '2026-09-30'
  GROUP BY 1
),
ad_day AS (
  SELECT date AS d, CAST(SUM(cost) AS FLOAT64) AS cost, SUM(clicks) AS clk
  FROM martech_dw.fct_ad_daily
  WHERE date BETWEEN '2026-06-01' AND '2026-09-30'
  GROUP BY 1
),
-- 以有投廣告的日子為主表，後台一筆訂單都沒有的日子也會留下來
site AS (
  SELECT a.d, IFNULL(e.tracked, 0) AS tracked, IFNULL(e.tracked_rev, 0) AS tracked_rev,
    IFNULL(o.orders, 0) AS orders, IFNULL(o.order_rev, 0) AS order_rev, a.cost, a.clk,
    AVG(IFNULL(e.tracked, 0)) OVER w7 AS tracked_base,
    AVG(IFNULL(o.orders, 0)) OVER w7 AS orders_base,
    AVG(a.clk) OVER w7 AS clk_base,
    COUNT(*) OVER w7 AS base_days
  FROM ad_day a
  LEFT JOIN ev_day e USING (d)
  LEFT JOIN od_day o USING (d)
  WINDOW w7 AS (ORDER BY a.d ROWS BETWEEN 7 PRECEDING AND 1 PRECEDING)
),
site_flag AS (
  SELECT
    'site_day' AS level,
    'all_site' AS entity,
    CAST(NULL AS STRING) AS channel,
    d AS period_start,
    d AS period_end,
    STRUCT(
      tracked, ROUND(tracked_base, 1) AS tracked_base,
      orders, ROUND(orders_base, 1) AS orders_base,
      ROUND(SAFE_DIVIDE(tracked_rev, cost), 2) AS tracked_roas,
      ROUND(SAFE_DIVIDE(order_rev, cost), 2) AS order_roas,
      clk, ROUND(clk_base) AS clk_base
    ) AS m,
    CAST(NULL AS FLOAT64) AS cpc_chg_pct,
    CAST(NULL AS FLOAT64) AS ctr_chg_pct
  FROM site
  WHERE base_days >= 5
    AND (tracked <= 0.5 * tracked_base OR orders <= 0.5 * orders_base)
)

SELECT
  FORMAT('%s|%s|%t', level, entity, period_start) AS anomaly_id,
  level, entity, channel, period_start, period_end,
  TO_JSON_STRING(m) AS metrics_json,
  cpc_chg_pct, ctr_chg_pct
FROM (
  SELECT level, entity, channel, period_start, period_end, TO_JSON(m) AS m, cpc_chg_pct, ctr_chg_pct FROM ag_flag
  UNION ALL
  SELECT level, entity, channel, period_start, period_end, TO_JSON(m), cpc_chg_pct, ctr_chg_pct FROM cr_flag
  UNION ALL
  SELECT level, entity, channel, period_start, period_end, TO_JSON(m), cpc_chg_pct, ctr_chg_pct FROM site_flag
);
