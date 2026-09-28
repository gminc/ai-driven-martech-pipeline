-- Day 15：五段報表，第 3、4 段會讀答案表 martech_gt.gt_creative_design，整個目錄只有這個檔案讀答案表
-- 六張圖是抽查，不是正式評測，正式正確率留給 Day 20 的 24 張

-- 1. 能不能 GROUP BY：output_schema 回來直接是欄位，不用解析就能分組
SELECT round, dominant_color, COUNT(*) AS images
FROM martech_dw.mm_structured
WHERE round = 'A'
GROUP BY 1, 2
ORDER BY 1, 2;

-- 2. 每一輪的值有沒有超出選項、欄位有沒有空、同一張圖兩次答案一不一樣
SELECT round, method, model,
  COUNT(*) AS calls,
  COUNTIF(cta_position NOT IN ('center', 'bottom_right', 'none')) AS cta_off_option,
  COUNTIF(dominant_color NOT IN ('warm', 'cool', 'neutral')) AS color_off_option,
  COUNTIF(text_density NOT IN ('low', 'high')) AS density_off_option,
  COUNTIF(has_person IS NULL OR cta_position IS NULL OR dominant_color IS NULL
          OR text_density IS NULL OR headline IS NULL OR headline = '') AS missing_field,
  MIN(output_tokens) AS min_out, MAX(output_tokens) AS max_out
FROM martech_dw.mm_structured
GROUP BY 1, 2, 3
ORDER BY 1;

-- 3. 逐張對答案：每一輪每張圖五個欄位各對不對（標題逐字比，去掉空白）
SELECT m.round, m.creative_id,
  m.has_person = g.has_person AS person_ok,
  m.cta_position = g.cta_position AS cta_ok,
  m.dominant_color = g.dominant_color AS color_ok,
  m.text_density = g.text_density AS density_ok,
  REGEXP_REPLACE(m.headline, r'\s', '') = REGEXP_REPLACE(g.headline, r'\s', '') AS headline_ok,
  m.dominant_color AS said_color, g.dominant_color AS spec_color,
  m.headline AS said_headline
FROM martech_dw.mm_structured m
JOIN martech_gt.gt_creative_design g USING (creative_id)
ORDER BY m.round, m.creative_id;

-- 4. 每一輪各欄位答對幾張（滿分 6），B1 對 A 看判斷標準的效果，C 對 B 看 enum 的效果，B1 對 B2 看兩次一不一樣
SELECT m.round, m.method, m.model,
  COUNTIF(m.has_person = g.has_person) AS person_ok,
  COUNTIF(m.cta_position = g.cta_position) AS cta_ok,
  COUNTIF(m.dominant_color = g.dominant_color) AS color_ok,
  COUNTIF(m.text_density = g.text_density) AS density_ok,
  COUNTIF(REGEXP_REPLACE(m.headline, r'\s', '') = REGEXP_REPLACE(g.headline, r'\s', '')) AS headline_ok,
  COUNTIF(m.has_person = g.has_person AND m.cta_position = g.cta_position
          AND m.dominant_color = g.dominant_color AND m.text_density = g.text_density) AS all_four_ok
FROM martech_dw.mm_structured m
JOIN martech_gt.gt_creative_design g USING (creative_id)
GROUP BY 1, 2, 3
ORDER BY 1;

-- 5. B1 與 B2 同一張圖兩次答案是否一致（不看對錯，只看一不一樣）
SELECT b1.creative_id,
  b1.has_person = b2.has_person AS person_same,
  b1.cta_position = b2.cta_position AS cta_same,
  b1.dominant_color = b2.dominant_color AS color_same,
  b1.text_density = b2.text_density AS density_same,
  REGEXP_REPLACE(b1.headline, r'\s', '') = REGEXP_REPLACE(b2.headline, r'\s', '') AS headline_same
FROM martech_dw.mm_structured b1
JOIN martech_dw.mm_structured b2 USING (creative_id)
WHERE b1.round = 'B1' AND b2.round = 'B2'
ORDER BY 1;

-- 6. 實際費用（輸入、輸出 Token 單價：3.5-flash-lite 0.33／2.75、3.6-flash 0.825／4.125 美元每百萬）
--    extract.sql 的 endpoint 只寫模型名稱，BigQuery 會送到非 global 端點，單價比 global 高一成（Day 10 實測，見 caching/README.md）
--    新台幣以 1 美元 32 元換算
SELECT round, model,
  COUNT(*) AS calls,
  SUM(prompt_tokens) AS input_tokens,
  SUM(output_tokens) AS output_tokens,
  ROUND(SUM(prompt_tokens * IF(model = 'gemini-3.6-flash', 0.825, 0.33)
          + output_tokens * IF(model = 'gemini-3.6-flash', 4.125, 2.75)) / 1e6, 5) AS usd,
  ROUND(SUM(prompt_tokens * IF(model = 'gemini-3.6-flash', 0.825, 0.33)
          + output_tokens * IF(model = 'gemini-3.6-flash', 4.125, 2.75)) / 1e6 * 32, 3) AS twd
FROM martech_dw.mm_structured
GROUP BY 1, 2
ORDER BY 1;
