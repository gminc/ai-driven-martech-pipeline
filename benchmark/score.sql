-- Day 20：對答案，兩種題目各一張成績表
--   mart_bench_features（簡單題）：一列＝模型 × 廣告圖 × 欄位，和設計規格 martech_gt.gt_creative_design 比
--   mart_bench_gaps    （難題）  ：一列＝模型 × 答案表的每一列，評分方式和 Day 19 的 consistency/score.sql 一模一樣，只是把「給頁面的方式」換成「模型」
-- 簡單題怎麼算：
--   四個分類欄位（has_person、cta_position、dominant_color、text_density）共 24 × 4 = 96 格，
--   Day 16 的判讀表 gt_creative_review 標成 disagree 的那 1 格（規格和畫面看起來不一致）不計分，所以滿分 95 格，borderline 的 6 格照算，報表另外列
--   headline 另外算（24 格），去掉空白後要和規格一字不差
--   verdict：correct／wrong／no_call（這個組合沒有成功的呼叫紀錄，正常流程不會出現，check.sql 會擋）
-- 難題怎麼算：同一種落差，而且模型抄下來的廣告文字裡有答案表的那個詞才算抓到，verdict 是 hit／miss／extra／disputed／other／no_call
-- 每個組合每張圖只取最新一筆成功紀錄，只問一次，差一兩格可能只是運氣
-- 這個檔會讀答案表，不呼叫 Gemini，查詢在每月 1 TiB 免費額度內，整張重建，可以重複執行

CREATE OR REPLACE TABLE martech_dw.mart_bench_features
OPTIONS (description = 'Day 20 簡單題對答案：一列＝模型 × 廣告圖 × 欄位，verdict 是 correct／wrong／no_call，counted 是這一格算不算進 95 格的分類成績')
AS
WITH
models AS (
  SELECT model FROM UNNEST(['gemini-3.5-flash-lite', 'gemini-3.6-flash']) AS model
  UNION DISTINCT
  SELECT DISTINCT model FROM martech_dw.mm_bench_log WHERE task = 'features'
),
picked AS (
  SELECT model, creative_id, SAFE.PARSE_JSON(result) AS j
  FROM martech_dw.mm_bench_log
  WHERE task = 'features' AND ok
  QUALIFY ROW_NUMBER() OVER (PARTITION BY model, creative_id ORDER BY created_at DESC) = 1
),
cells AS (
  SELECT m.model, g.creative_id, f.field, f.said, f.spec, p.creative_id IS NOT NULL AS called
  FROM models m
  CROSS JOIN martech_gt.gt_creative_design g
  LEFT JOIN picked p ON p.model = m.model AND p.creative_id = g.creative_id
  CROSS JOIN UNNEST([
    STRUCT('has_person' AS field, JSON_VALUE(p.j, '$.has_person') AS said, CAST(g.has_person AS STRING) AS spec),
    STRUCT('cta_position', JSON_VALUE(p.j, '$.cta_position'), g.cta_position),
    STRUCT('dominant_color', JSON_VALUE(p.j, '$.dominant_color'), g.dominant_color),
    STRUCT('text_density', JSON_VALUE(p.j, '$.text_density'), g.text_density),
    STRUCT('headline', REGEXP_REPLACE(JSON_VALUE(p.j, '$.headline'), r'\s', ''), REGEXP_REPLACE(g.headline, r'\s', ''))
  ]) AS f
)
SELECT c.model, c.creative_id, c.field, c.said, c.spec,
  r.verdict AS review,
  CASE WHEN NOT c.called THEN 'no_call' WHEN IFNULL(c.said = c.spec, FALSE) THEN 'correct' ELSE 'wrong' END AS verdict,
  c.field != 'headline' AND r.verdict IS DISTINCT FROM 'disagree' AS counted,
  CASE c.field
    WHEN 'has_person' THEN c.said IN ('true', 'false')
    WHEN 'cta_position' THEN c.said IN ('center', 'bottom_right', 'none')
    WHEN 'dominant_color' THEN c.said IN ('warm', 'cool', 'neutral')
    WHEN 'text_density' THEN c.said IN ('low', 'high')
  END AS in_option
FROM cells c
LEFT JOIN martech_gt.gt_creative_review r ON r.creative_id = c.creative_id AND r.field = c.field;

CREATE OR REPLACE TABLE martech_dw.mart_bench_gaps
OPTIONS (description = 'Day 20 難題對答案：一列＝模型 × 答案表的每一列，另外 extra 與 other 是模型 × 廣告圖 × 種類一列，verdict 是 hit／miss／extra／disputed／other／no_call')
AS
WITH
models AS (
  SELECT model FROM UNNEST(['gemini-3.5-flash-lite', 'gemini-3.6-flash', 'gemini-3.1-pro-preview']) AS model
  UNION DISTINCT
  SELECT DISTINCT model FROM martech_dw.mm_bench_log WHERE task = 'gaps'
),
ok AS (
  SELECT model, creative_id, SAFE.PARSE_JSON(result) AS j
  FROM martech_dw.mm_bench_log
  WHERE task = 'gaps' AND ok
  QUALIFY ROW_NUMBER() OVER (PARTITION BY model, creative_id ORDER BY created_at DESC) = 1
),
texts AS (
  SELECT model, creative_id,
    ARRAY_TO_STRING(ARRAY(SELECT JSON_VALUE(x) FROM UNNEST(JSON_QUERY_ARRAY(j, '$.ad_texts')) AS x), ' ｜ ') AS ad_texts
  FROM ok
),
found AS (
  SELECT o.model, o.creative_id, pos,
    JSON_VALUE(g, '$.gap_type') AS gap_type,
    IFNULL(JSON_VALUE(g, '$.ad_text'), '') AS ad_text,
    IFNULL(JSON_VALUE(g, '$.page_evidence'), '') AS page_evidence
  FROM ok o, UNNEST(JSON_QUERY_ARRAY(o.j, '$.gaps')) AS g WITH OFFSET AS pos
),
answer AS (
  SELECT m.model, k.creative_id, k.gap_type, k.ad_keyword, k.page_fact, k.disputed
  FROM martech_gt.gt_ad_page_gaps k
  CROSS JOIN models m
),
matched AS (
  SELECT a.model, a.creative_id, a.gap_type, a.ad_keyword, f.pos, f.ad_text, f.page_evidence
  FROM answer a
  JOIN found f
    ON f.model = a.model AND f.creative_id = a.creative_id AND f.gap_type = a.gap_type
   AND STRPOS(f.ad_text, a.ad_keyword) > 0
),
answer_side AS (
  SELECT a.model, a.creative_id, a.gap_type,
    CASE
      WHEN o.creative_id IS NULL THEN 'no_call'
      WHEN a.disputed THEN 'disputed'
      WHEN COUNT(m.pos) > 0 THEN 'hit'
      ELSE 'miss'
    END AS verdict,
    COUNT(m.pos) > 0 AS listed,
    a.ad_keyword, a.page_fact,
    STRING_AGG(m.ad_text, ' ／ ' ORDER BY m.pos) AS ad_text,
    STRING_AGG(m.page_evidence, ' ／ ' ORDER BY m.pos) AS page_evidence
  FROM answer a
  LEFT JOIN ok o ON o.model = a.model AND o.creative_id = a.creative_id
  LEFT JOIN matched m
    ON m.model = a.model AND m.creative_id = a.creative_id AND m.gap_type = a.gap_type AND m.ad_keyword = a.ad_keyword
  GROUP BY a.model, a.creative_id, a.gap_type, a.ad_keyword, a.page_fact, a.disputed, o.creative_id
),
unmatched AS (
  SELECT f.model, f.creative_id, f.gap_type,
    IF(f.gap_type = 'other', 'other', 'extra') AS verdict,
    TRUE AS listed,
    CAST(NULL AS STRING) AS ad_keyword, CAST(NULL AS STRING) AS page_fact,
    STRING_AGG(f.ad_text, ' ／ ' ORDER BY f.pos) AS ad_text,
    STRING_AGG(f.page_evidence, ' ／ ' ORDER BY f.pos) AS page_evidence
  FROM found f
  LEFT JOIN (SELECT DISTINCT model, creative_id, pos FROM matched) m
    ON m.model = f.model AND m.creative_id = f.creative_id AND m.pos = f.pos
  WHERE m.pos IS NULL
  GROUP BY f.model, f.creative_id, f.gap_type
),
unioned AS (
  SELECT * FROM answer_side
  UNION ALL
  SELECT * FROM unmatched
)
SELECT u.model, u.creative_id, c.page_id, c.utm_campaign, c.product_focus,
  u.gap_type, u.verdict, u.listed, u.ad_keyword, u.page_fact,
  IF(u.ad_keyword IS NULL, NULL, STRPOS(IFNULL(t.ad_texts, ''), u.ad_keyword) > 0) AS ad_read,
  u.ad_text, u.page_evidence, t.ad_texts
FROM unioned u
JOIN martech_dw.map_creative_landing c USING (creative_id)
LEFT JOIN texts t ON t.model = u.model AND t.creative_id = u.creative_id;

-- 每次評分留一筆紀錄：三張答案表的指紋，check.sql 用它確認評分之後答案沒有被改過，難題的指紋也要和 Day 19 評分時的一樣
CREATE TABLE IF NOT EXISTS martech_gt.bench_runs (
  scored_at TIMESTAMP,
  design_fingerprint STRING,
  review_fingerprint STRING,
  gaps_fingerprint STRING
)
OPTIONS (description = 'Day 20 每次評分當下三張答案表的指紋，只加不刪');

INSERT INTO martech_gt.bench_runs
SELECT CURRENT_TIMESTAMP(),
  (SELECT TO_HEX(SHA256(STRING_AGG(CONCAT(creative_id, '|', CAST(has_person AS STRING), '|', cta_position, '|', dominant_color, '|', text_density, '|', headline), '\n' ORDER BY creative_id)))
   FROM martech_gt.gt_creative_design),
  (SELECT TO_HEX(SHA256(STRING_AGG(CONCAT(creative_id, '|', field, '|', verdict), '\n' ORDER BY creative_id, field)))
   FROM martech_gt.gt_creative_review),
  (SELECT TO_HEX(SHA256(STRING_AGG(CONCAT(creative_id, '|', gap_type, '|', ad_keyword, '|', page_fact, '|', CAST(disputed AS STRING)), '\n' ORDER BY creative_id, gap_type, ad_keyword)))
   FROM martech_gt.gt_ad_page_gaps);

SELECT 'features' AS task, model, verdict, COUNT(*) AS n FROM martech_dw.mart_bench_features GROUP BY 1, 2, 3
UNION ALL
SELECT 'gaps', model, verdict, COUNT(*) FROM martech_dw.mart_bench_gaps GROUP BY 1, 2, 3
ORDER BY 1, 2, 3;
