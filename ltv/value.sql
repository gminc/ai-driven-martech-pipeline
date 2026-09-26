-- Day 12：把每位新顧客的預測值加總到通路 × 活動，和同期廣告花費對照
-- 期間：8/18–9/16（首購還不滿 30 天、用模型預測的那批新顧客）
-- 取得成本＝同期該通路該活動的廣告花費 ÷ 首購來自那裡的新顧客數（粗略算法：假設花費都花在帶新客）
-- 預期 30 天價值＝首單金額＋模型預測的 30 天回購營收
-- 模型（ltv_linreg）沒有用活動代號當特徵，所以 autumn-cotton 這種訓練資料沒出現過的活動也能正常預測
-- 新顧客的通路與活動取首購訂單的 utm，等於「最後接觸」：google 搜尋常收割 meta 開頭的路徑（Day 08），這張表會高估 google_cpc
WITH new_customers AS (
  SELECT
    CASE l.first_source WHEN 'google' THEN IF(l.first_medium = 'cpc', 'google_cpc', NULL) ELSE l.first_source END AS channel,
    l.first_campaign AS utm_campaign,
    f.first_revenue,
    l.predicted_revenue_30d
  FROM martech_dw.mart_customer_ltv l
  JOIN martech_dw.ltv_features f USING (customer_id)
  WHERE l.scope = 'new'
),
per_group AS (
  SELECT
    channel,
    utm_campaign,
    COUNT(*) AS new_customers,
    ROUND(AVG(first_revenue)) AS avg_first_order,
    ROUND(AVG(predicted_revenue_30d)) AS avg_pred_30d
  FROM new_customers
  WHERE channel IN ('meta', 'line', 'google_cpc')
  GROUP BY channel, utm_campaign
),
spend AS (
  SELECT channel, utm_campaign, SUM(cost) AS cost
  FROM martech_dw.fct_ad_daily
  WHERE date BETWEEN '2026-08-18' AND '2026-09-16'
  GROUP BY channel, utm_campaign
)
SELECT
  p.channel,
  p.utm_campaign,
  p.new_customers,
  ROUND(s.cost) AS ad_cost,
  ROUND(s.cost / p.new_customers) AS cost_per_new,
  p.avg_first_order,
  p.avg_pred_30d,
  p.avg_first_order + p.avg_pred_30d AS expected_value_30d,
  ROUND((p.avg_first_order + p.avg_pred_30d) / (s.cost / p.new_customers), 2) AS value_to_cost
FROM per_group p
JOIN spend s USING (channel, utm_campaign)
ORDER BY value_to_cost DESC;
