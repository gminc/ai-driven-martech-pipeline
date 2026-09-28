-- Day 14：把看圖結果整理成五段，文章裡的數字都從這裡來
-- 1. 報表眼中的三張圖：只有編號與數字
-- 2. 並排讀描述：同一張圖、不同模型與不同次數
-- 3. 一張圖算多少 Token：預設解析度與低解析度
-- 4. 自由描述能不能直接分組：試著用關鍵字把描述歸類，對照後台素材資料
-- 5. 實際費用（新台幣，1 美元＝32 元）
-- 查詢在每月 1 TiB 免費額度內

-- 1. 報表眼中的三張圖
SELECT d.pick_no, d.creative_id, d.ad_group_id,
  SUM(f.impressions) AS impressions,
  SUM(f.clicks) AS clicks,
  ROUND(SAFE_DIVIDE(SUM(f.clicks), SUM(f.impressions)) * 100, 2) AS ctr_pct,
  ROUND(SUM(f.cost)) AS cost_twd
FROM martech_dw.mm_demo d
JOIN martech_dw.fct_ad_daily f USING (creative_id)
GROUP BY 1, 2, 3
ORDER BY 1;

-- 2. 並排讀描述
SELECT d.pick_no, m.creative_id, m.model, m.resolution, m.run_no,
  CHAR_LENGTH(m.description) AS chars,
  m.description
FROM martech_dw.mm_describe m
JOIN martech_dw.mm_demo d USING (creative_id)
ORDER BY d.pick_no, m.model, m.resolution, m.run_no;

-- 3. 一張圖算多少 Token
SELECT model, resolution,
  MIN(prompt_tokens) AS min_input,
  MAX(prompt_tokens) AS max_input,
  ROUND(AVG(output_tokens)) AS avg_output,
  ROUND(AVG(CHAR_LENGTH(description))) AS avg_chars
FROM martech_dw.mm_describe
GROUP BY 1, 2
ORDER BY 1, 2;

-- 4. 自由描述能不能直接分組
--    直接 GROUP BY 描述：12 段文字就是 12 組
--    改用關鍵字硬分：「有沒有提到人」「有沒有提到暖色系的字」，再和後台素材資料 dim_creative 對照
SELECT
  COUNT(*) AS descriptions,
  COUNT(DISTINCT description) AS distinct_descriptions
FROM martech_dw.mm_describe;

SELECT m.creative_id, m.model, m.resolution, m.run_no,
  c.has_person,
  REGEXP_CONTAINS(m.description, r'人物|男性|女性|男子|女子|男生|女生|模特|年輕人|一位|一名') AS says_person,
  c.dominant_color,
  REGEXP_CONTAINS(m.description, r'暖色|暖調|橘|橙|磚紅|赤陶|陶土|米色|大地色|奶茶') AS says_warm,
  c.text_density,
  ARRAY_LENGTH(REGEXP_EXTRACT_ALL(m.description, r'「[^」]+」')) AS quoted_texts
FROM martech_dw.mm_describe m
JOIN martech_dw.dim_creative c USING (creative_id)
ORDER BY m.creative_id, m.model, m.resolution, m.run_no;

-- 5. 實際費用（輸入、輸出 Token 單價：3.5-flash-lite 0.33／2.75、3.6-flash 0.825／4.125 美元每百萬）
--    describe.sql 的 endpoint 只寫模型名稱，BigQuery 會送到非 global 端點，單價比 global 高一成（Day 10 實測，見 caching/README.md）
SELECT model, resolution,
  COUNT(*) AS calls,
  SUM(prompt_tokens) AS input_tokens,
  SUM(output_tokens) AS output_tokens,
  ROUND(SUM(prompt_tokens * IF(model = 'gemini-3.6-flash', 0.825, 0.33)
          + output_tokens * IF(model = 'gemini-3.6-flash', 4.125, 2.75)) / 1e6 * 32, 3) AS cost_twd
FROM martech_dw.mm_describe
GROUP BY ROLLUP (model, resolution)
ORDER BY model NULLS LAST, resolution NULLS LAST;
