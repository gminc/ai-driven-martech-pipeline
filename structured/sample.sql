-- Day 15：挑六張樣本圖，記下它們在物件表裡的位置
-- 六張是照「四個設計欄位的每一個值都至少出現一次」挑的，人物有無各 3 張、按鈕位置三種各 2 張、主色三種各 2 張、文字多寡各 3 張
-- 含 Day 14 的三張示範圖（cr-line-trn-p1、cr-line-trn-p2、cr-meta-evg-r2），可以和自由描述的結果對照
-- 挑圖時看了設計規格（在答案表裡），所以這一步不在 SQL 裡查答案表，六個 ID 直接寫死，why 欄只寫來源不寫規格
-- 只讀 martech_dw（dim_creative 是廣告後台本來就有的素材資料，obj_creatives 是 Day 14 建的物件表）
-- 查詢在每月 1 TiB 免費額度內

CREATE OR REPLACE TABLE martech_dw.mm_sample
OPTIONS (description = 'Day 15 結構化抽取用的六張樣本圖')
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
  STRUCT(1 AS pick_no, 'cr-line-trn-p1' AS creative_id, 'Day 14 示範圖 A' AS why),
  STRUCT(2, 'cr-line-trn-p2', 'Day 14 示範圖 B'),
  STRUCT(3, 'cr-meta-evg-r2', 'Day 14 示範圖 C，圖上文字最多'),
  STRUCT(4, 'cr-meta-trn-p1', 'Meta 重訓襪專案、開發新客'),
  STRUCT(5, 'cr-meta-aut-r2', 'Meta 秋日活動、再行銷'),
  STRUCT(6, 'cr-meta-trn-r1', 'Meta 重訓襪專案、再行銷')
]) AS d
JOIN martech_dw.dim_creative c USING (creative_id)
JOIN martech_dw.obj_creatives o
  ON o.uri LIKE CONCAT('%/', d.creative_id, '.jpg');

SELECT pick_no, creative_id, why, channel, ad_group_id, product_focus, size
FROM martech_dw.mm_sample
ORDER BY pick_no;
