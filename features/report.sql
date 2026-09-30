-- Day 16：八段報表，第 3、4、5 段會讀答案資料集 martech_gt（gt_creative_design、gt_creative_review），整個目錄只有這個檔案和 review.sql 碰答案
-- 24 張是順手看答對率，正式評測（模型對比、單價、延遲）在 Day 20
-- 標題逐字比對時去掉空白

-- 1. 特徵表的分佈：四個欄位各有幾張，不用解析就能分組
SELECT 'has_person' AS field, CAST(has_person AS STRING) AS value, COUNT(*) AS images FROM martech_dw.mart_creative_features GROUP BY 1, 2
UNION ALL SELECT 'cta_position', cta_position, COUNT(*) FROM martech_dw.mart_creative_features GROUP BY 1, 2
UNION ALL SELECT 'dominant_color', dominant_color, COUNT(*) FROM martech_dw.mart_creative_features GROUP BY 1, 2
UNION ALL SELECT 'text_density', text_density, COUNT(*) FROM martech_dw.mart_creative_features GROUP BY 1, 2
ORDER BY 1, 2;

-- 2. 每次執行呼叫了幾次：第一次是整批，第二次成功過的圖不會再呼叫
SELECT run_id, MIN(created_at) AS started_at, resolution, method,
  COUNT(*) AS calls, COUNTIF(status = '') AS ok, COUNTIF(status != '') AS failed
FROM martech_dw.mm_features_log
GROUP BY 1, 3, 4
ORDER BY 2, 3, 4;

-- 3. 逐欄答對幾張（滿分 24）：預設解析度看特徵表，低解析度看每張圖最新一筆成功紀錄
WITH picked AS (
  SELECT 'default' AS resolution, creative_id, has_person, cta_position, dominant_color, text_density, headline
  FROM martech_dw.mart_creative_features
  UNION ALL
  SELECT 'low', creative_id, has_person, cta_position, dominant_color, text_density, headline
  FROM martech_dw.mm_features_log
  WHERE resolution = 'low'
    AND status = '' AND has_person IS NOT NULL AND cta_position IS NOT NULL AND dominant_color IS NOT NULL
    AND text_density IS NOT NULL AND headline IS NOT NULL AND headline != ''
  QUALIFY ROW_NUMBER() OVER (PARTITION BY creative_id ORDER BY created_at DESC) = 1
)
SELECT p.resolution,
  COUNT(*) AS images,
  COUNTIF(p.has_person = g.has_person) AS person_ok,
  COUNTIF(p.cta_position = g.cta_position) AS cta_ok,
  COUNTIF(p.dominant_color = g.dominant_color) AS color_ok,
  COUNTIF(p.text_density = g.text_density) AS density_ok,
  COUNTIF(REGEXP_REPLACE(p.headline, r'\s', '') = REGEXP_REPLACE(g.headline, r'\s', '')) AS headline_ok,
  COUNTIF(p.has_person = g.has_person AND p.cta_position = g.cta_position
          AND p.dominant_color = g.dominant_color AND p.text_density = g.text_density) AS all_four_ok
FROM picked p
JOIN martech_gt.gt_creative_design g USING (creative_id)
GROUP BY 1
ORDER BY 1;

-- 4. 答錯的格子逐一列出，附上判讀表的註記（disagree＝規格和畫面看起來不一致，borderline＝可能判得不一樣）
WITH picked AS (
  SELECT 'default' AS resolution, creative_id, has_person, cta_position, dominant_color, text_density, headline
  FROM martech_dw.mart_creative_features
  UNION ALL
  SELECT 'low', creative_id, has_person, cta_position, dominant_color, text_density, headline
  FROM martech_dw.mm_features_log
  WHERE resolution = 'low'
    AND status = '' AND has_person IS NOT NULL AND cta_position IS NOT NULL AND dominant_color IS NOT NULL
    AND text_density IS NOT NULL AND headline IS NOT NULL AND headline != ''
  QUALIFY ROW_NUMBER() OVER (PARTITION BY creative_id ORDER BY created_at DESC) = 1
),
cells AS (
  SELECT p.resolution, p.creative_id, f.field, f.said, f.spec
  FROM picked p
  JOIN martech_gt.gt_creative_design g USING (creative_id)
  CROSS JOIN UNNEST([
    STRUCT('has_person' AS field, CAST(p.has_person AS STRING) AS said, CAST(g.has_person AS STRING) AS spec),
    STRUCT('cta_position', p.cta_position, g.cta_position),
    STRUCT('dominant_color', p.dominant_color, g.dominant_color),
    STRUCT('text_density', p.text_density, g.text_density),
    STRUCT('headline', REGEXP_REPLACE(p.headline, r'\s', ''), REGEXP_REPLACE(g.headline, r'\s', ''))
  ]) AS f
)
SELECT c.resolution, c.creative_id, c.field, c.said, c.spec, r.verdict, r.eye_value
FROM cells c
LEFT JOIN martech_gt.gt_creative_review r USING (creative_id, field)
WHERE c.said IS DISTINCT FROM c.spec
ORDER BY c.field, c.creative_id, c.resolution;

-- 5. 兩種算法的主色答對率：全部 24 張，以及排除 disagree（規格和畫面不一致）的圖，Day 20 用後者
WITH picked AS (
  SELECT 'default' AS resolution, creative_id, dominant_color
  FROM martech_dw.mart_creative_features
  UNION ALL
  SELECT 'low', creative_id, dominant_color
  FROM martech_dw.mm_features_log
  WHERE resolution = 'low'
    AND status = '' AND has_person IS NOT NULL AND cta_position IS NOT NULL AND dominant_color IS NOT NULL
    AND text_density IS NOT NULL AND headline IS NOT NULL AND headline != ''
  QUALIFY ROW_NUMBER() OVER (PARTITION BY creative_id ORDER BY created_at DESC) = 1
)
SELECT p.resolution,
  COUNT(*) AS all_images,
  COUNTIF(p.dominant_color = g.dominant_color) AS all_ok,
  COUNTIF(r.verdict IS DISTINCT FROM 'disagree') AS clear_images,
  COUNTIF(r.verdict IS DISTINCT FROM 'disagree' AND p.dominant_color = g.dominant_color) AS clear_ok,
  COUNTIF(r.verdict = 'borderline') AS borderline_images,
  COUNTIF(r.verdict = 'borderline' AND p.dominant_color = g.dominant_color) AS borderline_ok
FROM picked p
JOIN martech_gt.gt_creative_design g USING (creative_id)
LEFT JOIN martech_gt.gt_creative_review r
  ON r.creative_id = p.creative_id AND r.field = 'dominant_color'
GROUP BY 1
ORDER BY 1;

-- 6. 同一張圖高、低解析度答得一不一樣（不看對錯）
WITH lo AS (
  SELECT * FROM martech_dw.mm_features_log
  WHERE resolution = 'low'
    AND status = '' AND has_person IS NOT NULL AND cta_position IS NOT NULL AND dominant_color IS NOT NULL
    AND text_density IS NOT NULL AND headline IS NOT NULL AND headline != ''
  QUALIFY ROW_NUMBER() OVER (PARTITION BY creative_id ORDER BY created_at DESC) = 1
)
SELECT
  COUNT(*) AS images,
  COUNTIF(f.has_person = lo.has_person) AS person_same,
  COUNTIF(f.cta_position = lo.cta_position) AS cta_same,
  COUNTIF(f.dominant_color = lo.dominant_color) AS color_same,
  COUNTIF(f.text_density = lo.text_density) AS density_same,
  COUNTIF(REGEXP_REPLACE(f.headline, r'\s', '') = REGEXP_REPLACE(lo.headline, r'\s', '')) AS headline_same
FROM martech_dw.mart_creative_features f
JOIN lo USING (creative_id);

-- 7. 實際費用（3.5-flash-lite 非 global 端點：輸入 0.33、輸出 2.75 美元每百萬 Token，新台幣以 1 美元 32 元換算）
--    extract.sql 的 endpoint 只寫模型名稱，BigQuery 會送到非 global 端點，單價比 global 高一成（Day 10 實測，見 caching/README.md）
SELECT resolution, method,
  COUNT(*) AS calls,
  MIN(prompt_tokens) AS min_input, MAX(prompt_tokens) AS max_input,
  MIN(output_tokens) AS min_output, MAX(output_tokens) AS max_output,
  SUM(prompt_tokens) AS input_tokens,
  SUM(output_tokens) AS output_tokens,
  ROUND(SUM(prompt_tokens * 0.33 + output_tokens * 2.75) / 1e6 * 32, 3) AS twd,
  ROUND(AVG(prompt_tokens * 0.33 + output_tokens * 2.75) / 1e6 * 32 * 1000, 1) AS twd_per_1000_calls
FROM martech_dw.mm_features_log
WHERE status = ''
GROUP BY ROLLUP (resolution, method)
ORDER BY resolution NULLS LAST, method NULLS LAST;

-- 8. 共用 Token 用量表目前累積了什麼（Day 25 從這張表做監控）
SELECT day, job, model, endpoint_type, media_resolution,
  COUNT(*) AS calls, SUM(prompt_tokens) AS input_tokens, SUM(output_tokens) AS output_tokens
FROM martech_dw.ops_llm_usage
GROUP BY 1, 2, 3, 4, 5
ORDER BY 1, 2, 5;
