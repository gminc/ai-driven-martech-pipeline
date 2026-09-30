-- Day 16：把看圖結果整理成特徵表 mart_creative_features，一列＝一張圖，Day 17 用 creative_id 和廣告成效 JOIN
-- 來源是 mm_features_log 預設解析度的成功紀錄（成功的定義和 extract.sql 一樣：status 空字串、五個欄位都有值），同一張圖有好幾筆時，先挑值都在選項裡的，再挑最新的
-- （超出選項後用 enum 補問的那一筆會被挑中，低解析度只拿來對照，不進特徵表）
-- 只讀 martech_dw，不讀答案表，查詢在每月 1 TiB 免費額度內，整張重建，可以重複執行

CREATE OR REPLACE TABLE martech_dw.mart_creative_features
OPTIONS (description = 'Day 16 素材視覺特徵表：Gemini 看圖抽出的五個欄位，一列＝一張圖片素材，Day 17 與 fct_ad_daily 用 creative_id JOIN')
AS
SELECT
  creative_id,
  has_person,
  cta_position,
  dominant_color,
  text_density,
  headline,
  in_option,
  model,
  method,
  resolution,
  created_at AS extracted_at
FROM (
  SELECT l.*,
    IFNULL(l.cta_position IN ('center', 'bottom_right', 'none')
      AND l.dominant_color IN ('warm', 'cool', 'neutral')
      AND l.text_density IN ('low', 'high'), FALSE) AS in_option
  FROM martech_dw.mm_features_log l
  WHERE l.resolution = 'default'
    AND l.status = '' AND l.has_person IS NOT NULL AND l.cta_position IS NOT NULL AND l.dominant_color IS NOT NULL
    AND l.text_density IS NOT NULL AND l.headline IS NOT NULL AND l.headline != ''
)
WHERE TRUE
QUALIFY ROW_NUMBER() OVER (PARTITION BY creative_id ORDER BY in_option DESC, created_at DESC) = 1;

-- 特徵表建好之後，不用解析任何東西就能直接分組
SELECT dominant_color, has_person, COUNT(*) AS images
FROM martech_dw.mart_creative_features
GROUP BY 1, 2
ORDER BY 1, 2;
