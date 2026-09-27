-- Day 14：挑三張示範圖，記下它們在物件表裡的位置
-- 前兩張是同一個廣告群組（LINE 重訓襪專案、開發新客）裡的兩張圖，同通路、同受眾、同期間，點擊率卻差了一截；
-- 第三張是 Meta 常態活動裡圖上文字最多的一張，用來看 Gemini 會不會把圖上的字讀出來
-- 只讀 martech_dw（dim_creative 是廣告後台本來就有的素材資料，obj_creatives 是 Day 14 建的物件表），不讀答案表
-- 查詢在每月 1 TiB 免費額度內

CREATE OR REPLACE TABLE martech_dw.mm_demo
OPTIONS (description = 'Day 14 看圖示範用的三張素材圖')
AS
SELECT
  d.pick_no,
  d.creative_id,
  d.why,
  c.channel,
  c.ad_group_id,
  c.product_focus,
  o.uri,
  o.size
FROM UNNEST([
  STRUCT(1 AS pick_no, 'cr-line-trn-p1' AS creative_id, '同群組 A：點擊率較低' AS why),
  STRUCT(2, 'cr-line-trn-p2', '同群組 B：點擊率較高'),
  STRUCT(3, 'cr-meta-evg-r2', '圖上文字最多')
]) AS d
JOIN martech_dw.dim_creative c USING (creative_id)
JOIN martech_dw.obj_creatives o
  ON o.uri LIKE CONCAT('%/', d.creative_id, '.jpg');

SELECT pick_no, creative_id, why, ad_group_id, product_focus, size
FROM martech_dw.mm_demo
ORDER BY pick_no;
