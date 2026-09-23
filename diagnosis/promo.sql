-- Day 09 補充：秋日專案（AUTUMN2026，9/1–9/16）前後，專案商品占比有沒有變高
-- 這題答案用 SQL 就算得出來，不需要交給 AI
-- 口徑沿用 Day 06：用件數算占比，對照專案開始前三週（8/11–8/31）

WITH o AS (
  SELECT
    o.quantity, o.revenue,
    'AUTUMN2026' IN UNNEST(p.promotion_ids) AS is_promo_item,
    IF(o.order_date >= '2026-09-01', '2_during', '1_before') AS period
  FROM martech_dw.fct_orders o
  JOIN martech_dw.dim_product p USING (item_id)
  WHERE o.order_date BETWEEN '2026-08-11' AND '2026-09-16'
)
SELECT
  period,
  SUM(quantity) AS qty,
  SUM(IF(is_promo_item, quantity, 0)) AS promo_qty,
  ROUND(100 * SUM(IF(is_promo_item, quantity, 0)) / SUM(quantity), 1) AS promo_qty_share_pct,
  ROUND(100 * SUM(IF(is_promo_item, revenue, 0)) / SUM(revenue), 1) AS promo_rev_share_pct
FROM o
GROUP BY period
ORDER BY period;
-- 實測（2026-09-23）：專案前 1,415 件中 761 件（53.8%）→ 專案期間 1,470 件中 979 件（66.6%），營收占比 47.7% → 56.8%
