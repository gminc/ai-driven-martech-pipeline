-- Day 18：把草稿整理成 mart_creative_drafts，一列＝一份草稿（圖 × 題目版本 × 第幾次），順便算好三件要檢查的事
--   1. 照成效改了沒：原圖沒有、草稿加上的特徵（人物、右下按鈕、暖色）
--   2. 引用的倍數對不對：cited_ratio 和倍數表四捨五入到小數兩位比，對到點擊率、對到轉換率，或都對不到
--   3. 有沒有寫出不能寫的詞：標題、副標、標籤、按鈕這四個會出現在廣告上的欄位，比對 ref_claim_terms
-- 另外標出 expected_effect 有沒有提到轉換、成交、銷售（只是標記，報表會印原文給人看，因為「不會提升轉換率」也會被標到）
-- 來源是 mm_drafts_log 的成功紀錄（定義和 generate.sql 一樣，值不在選項裡的不算成功），同一個組合有好幾筆時取最新的，只讀 martech_dw，整張重建，可以重複執行

CREATE OR REPLACE TABLE martech_dw.mart_creative_drafts
OPTIONS (description = 'Day 18 素材改版草稿：一列＝一份草稿（圖 × 題目版本 free／rules × 第幾次），附照成效改了沒、引用倍數對不對、不能寫的詞')
AS
WITH
ok AS (
  SELECT *
  FROM martech_dw.mm_drafts_log
  WHERE status = '' AND headline IS NOT NULL AND headline != '' AND cta_text IS NOT NULL
    AND has_person IS NOT NULL AND cited_ratio IS NOT NULL
    AND cta_position IN ('center', 'bottom_right', 'none') AND dominant_color IN ('warm', 'cool', 'neutral')
    AND text_density IN ('low', 'high') AND cited_feature IN ('person', 'cta', 'warm', 'text')
    AND method = 'response_schema'
  QUALIFY ROW_NUMBER() OVER (PARTITION BY creative_id, version, sample ORDER BY created_at DESC) = 1
),
lift AS (
  SELECT attr,
    ROUND(MAX(IF(metric = 'ctr', stratified, NULL)), 2) AS ctr2,
    ROUND(MAX(IF(metric = 'cvr', stratified, NULL)), 2) AS cvr2
  FROM martech_dw.mart_creative_lift
  GROUP BY attr
),
hits AS (
  SELECT k.creative_id, k.version, k.sample,
    ARRAY_AGG(DISTINCT c.term IGNORE NULLS ORDER BY c.term) AS claim_terms,
    ARRAY_AGG(DISTINCT c.kind IGNORE NULLS ORDER BY c.kind) AS claim_kinds
  FROM ok k
  JOIN martech_dw.ref_claim_terms c
    ON STRPOS(CONCAT(k.headline, ' ', IFNULL(k.subhead, ''), ' ', IFNULL(k.badge, ''), ' ', k.cta_text), c.term) > 0
  GROUP BY 1, 2, 3
)
SELECT
  k.creative_id, k.version, k.sample,
  k.headline, k.subhead, k.badge, k.cta_text,
  k.cta_position, k.has_person, k.dominant_color, k.text_density,
  k.composition, k.image_prompt, k.changes,
  k.cited_feature, k.cited_ratio, k.expected_effect,
  -- 原圖（Day 16 AI 讀出來的特徵）
  f.has_person     AS old_has_person,
  f.cta_position   AS old_cta_position,
  f.dominant_color AS old_dominant_color,
  f.text_density   AS old_text_density,
  f.headline       AS old_headline,
  -- 1. 照成效改了沒
  k.has_person AND NOT f.has_person                                         AS added_person,
  k.cta_position = 'bottom_right' AND f.cta_position != 'bottom_right'      AS moved_cta,
  k.dominant_color = 'warm' AND f.dominant_color != 'warm'                  AS turned_warm,
  IFNULL(k.cta_position IN ('center', 'bottom_right', 'none')
    AND k.dominant_color IN ('warm', 'cool', 'neutral')
    AND k.text_density IN ('low', 'high')
    AND k.cited_feature IN ('person', 'cta', 'warm', 'text'), FALSE)         AS in_option,
  -- 2. 引用的倍數對不對（四捨五入到小數兩位比）
  CASE
    WHEN l.attr IS NULL THEN 'unknown_feature'
    WHEN ROUND(k.cited_ratio, 2) = l.ctr2 THEN 'ctr'
    WHEN ROUND(k.cited_ratio, 2) = l.cvr2 THEN 'cvr'
    ELSE 'none'
  END AS cited_match,
  l.ctr2 AS table_ctr,
  -- 3. 不能寫的詞
  IFNULL(h.claim_terms, ARRAY<STRING>[]) AS claim_terms,
  IFNULL(h.claim_kinds, ARRAY<STRING>[]) AS claim_kinds,
  REGEXP_CONTAINS(IFNULL(k.expected_effect, ''), r'轉換|成交|銷售|銷量|業績|營收|下單|購買|訂單|回購|買氣') AS mentions_sales,
  k.prompt_tokens, k.output_tokens, k.thoughts_tokens,
  k.created_at AS drafted_at
FROM ok k
JOIN martech_dw.mart_creative_features f USING (creative_id)
LEFT JOIN lift l ON l.attr = k.cited_feature
LEFT JOIN hits h USING (creative_id, version, sample);

SELECT version,
  COUNT(*) AS drafts,
  COUNTIF(ARRAY_LENGTH(claim_terms) > 0) AS with_claims,
  COUNTIF(cited_match = 'ctr') AS cited_ctr_ok
FROM martech_dw.mart_creative_drafts
GROUP BY version
ORDER BY version;
