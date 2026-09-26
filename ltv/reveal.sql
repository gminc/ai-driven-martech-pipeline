-- Day 12 揭曉：預測值 × 合成器藏的四種顧客類型
-- 這份會讀答案表 martech_gt，只在預測完成（predict.sql）之後執行
-- scope：eval＝驗證集（首購 8/09–8/17，已知實際 30 天回購營收）；new＝首購 8/18 之後，只有預測值

-- ① 依真實類型：平均預測 vs 平均實際
SELECT
  l.scope,
  g.segment,
  COUNT(*) AS customers,
  ROUND(AVG(l.predicted_revenue_30d), 1) AS avg_pred,
  ROUND(AVG(l.actual_revenue_30d), 1) AS avg_actual,
  ROUND(SAFE_DIVIDE(COUNTIF(l.actual_revenue_30d > 0), COUNTIF(l.actual_revenue_30d IS NOT NULL)), 3) AS repeat_rate
FROM martech_dw.mart_customer_ltv l
JOIN martech_gt.gt_customer_segment g USING (customer_id)
GROUP BY l.scope, g.segment
ORDER BY l.scope, g.segment;

-- ② 首購同一項商品的人，高頻買襪客和沉睡客拿到的預測值幾乎一樣：模型只看得到第一筆訂單
SELECT
  l.first_item_id,
  g.segment,
  COUNT(*) AS customers,
  ROUND(AVG(l.predicted_revenue_30d), 1) AS avg_pred
FROM martech_dw.mart_customer_ltv l
JOIN martech_gt.gt_customer_segment g USING (customer_id)
GROUP BY l.first_item_id, g.segment
ORDER BY l.first_item_id, g.segment;
