-- Day 12 避坑：訓練資料沒出現過的類別
-- ltv_linreg_campaign 是把活動代號也放進特徵的版本（首購 8/08 以前沒有 autumn-cotton）
-- 同一批新顧客，兩個模型的預測並排：沒看過的活動，預測值會被推高到 700 以上
SELECT
  a.first_campaign,
  a.first_item_id,
  COUNT(*) AS customers,
  ROUND(AVG(a.predicted_future_revenue_30d)) AS with_campaign,
  ROUND(AVG(b.predicted_future_revenue_30d)) AS without_campaign
FROM ML.PREDICT(MODEL martech_dw.ltv_linreg_campaign,
                (SELECT * FROM martech_dw.ltv_features WHERE NOT label_complete)) AS a
JOIN ML.PREDICT(MODEL martech_dw.ltv_linreg,
                (SELECT * FROM martech_dw.ltv_features WHERE NOT label_complete)) AS b
  USING (customer_id, first_campaign, first_item_id)
GROUP BY a.first_campaign, a.first_item_id
ORDER BY a.first_campaign, a.first_item_id;
