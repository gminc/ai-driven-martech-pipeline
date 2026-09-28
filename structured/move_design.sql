-- Day 15：把素材的四個設計規格欄位從分析資料集搬進答案資料集
-- has_person、cta_position、dominant_color、text_density 是合成器畫圖時照的規格，等於「這張圖長什麼樣子」的標準答案，
-- Day 07 建 dim_creative 時把它們一起放進了 martech_dw，分析用的 SQL 只要 JOIN 一下就能拿到答案，
-- 和 Day 11 到 Day 13 建立的「答案只放在 martech_gt」原則不一致，今天先搬家再開始抽特徵
-- headline 是 creatives/compose.py 依主打商品畫上去的標題文字，一起放進答案表，之後可以逐字對
-- 可以重複執行：答案表整張重建，dim_creative 的欄位用 DROP COLUMN IF EXISTS 拿掉，第二次執行不會出錯
-- 查詢在每月 1 TiB 免費額度內，raw_creatives 是 Day 06 原樣載入的檔案，不動

CREATE OR REPLACE TABLE martech_gt.gt_creative_design
OPTIONS (description = 'Day 15 素材設計規格（答案表）：一列＝一張圖片素材，四個設計欄位加圖上標題，來源 synthesizer/creatives.json 與 creatives/compose.py') AS
SELECT
  r.creative_id,
  r.has_person,
  r.cta_position,
  r.dominant_color,
  r.text_density,
  CASE r.product_focus
    WHEN 'sock-crew-daily' THEN '天天穿的純棉短襪'
    WHEN 'sock-towel-training' THEN '重訓日的厚底毛巾襪'
    WHEN 'towel-bath-cotton' THEN '一條包得住的大浴巾'
    WHEN 'towel-face-cotton' THEN '每天洗臉的純棉毛巾'
    WHEN 'set-starter' THEN '襪子＋毛巾新手組'
  END AS headline
FROM martech_dw.raw_creatives r
WHERE r.format = 'image';

ALTER TABLE martech_dw.dim_creative DROP COLUMN IF EXISTS has_person;
ALTER TABLE martech_dw.dim_creative DROP COLUMN IF EXISTS cta_position;
ALTER TABLE martech_dw.dim_creative DROP COLUMN IF EXISTS dominant_color;
ALTER TABLE martech_dw.dim_creative DROP COLUMN IF EXISTS text_density;

SELECT
  (SELECT COUNT(*) FROM martech_gt.gt_creative_design) AS design_rows,
  (SELECT COUNT(*) FROM martech_gt.gt_creative_design WHERE headline IS NULL) AS missing_headline,
  (SELECT COUNT(*) FROM martech_dw.INFORMATION_SCHEMA.COLUMNS
    WHERE table_name = 'dim_creative'
      AND column_name IN ('has_person', 'cta_position', 'dominant_color', 'text_density')) AS design_columns_left_in_dim;
