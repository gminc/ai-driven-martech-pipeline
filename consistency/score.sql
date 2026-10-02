-- Day 19：對答案，把 Gemini 列的落差和答案表 martech_gt.gt_ad_page_gaps 比，結果放進 mart_ad_page_gaps
-- 怎樣算抓到：Gemini 列的落差和答案是同一種類，而且它抄下來的廣告文字（ad_text）裡有答案表的那個詞（ad_keyword），
-- 只有種類對、指的不是那幾個字不算（例如把「秋日」列成 limited_offer，不能算抓到「限定」）
-- verdict 六種：
--   hit      答案表有、Gemini 也列了
--   miss     答案表有、Gemini 沒列
--   extra    Gemini 列了、對不到答案表任何一列（other 以外的七種才算，包含清單上的 gift、warranty，報表會印原文）
--   disputed 答案表標成有爭議的列，不管 Gemini 有沒有列都不計分（listed 欄位記它有沒有列）
--   other    Gemini 填 other 的落差，不計分，報表印原文
--   no_call  這個組合沒有成功的呼叫紀錄，不算 miss（正常流程不會出現，check.sql 第 11 項會擋）
-- 一列的單位：答案表的每一列 × 兩種給法各一列，另外 extra 與 other 是每張圖 × 給法 × 種類一列（同種類列了好幾項會併在一起）
-- ad_read：Gemini 抄下來的整張圖文字（ad_texts）裡有沒有答案表的那個詞，用來分辨「有讀到但沒列」和「根本沒讀到」
-- 這個檔會讀答案表，不呼叫 Gemini，查詢在每月 1 TiB 免費額度內，整張重建，可以重複執行

CREATE OR REPLACE TABLE martech_dw.mart_ad_page_gaps
OPTIONS (description = 'Day 19 廣告與頁面的落差對答案：verdict 是 hit／miss／extra／disputed／other／no_call')
AS
WITH
ok AS (
  SELECT mode, creative_id, page_id, SAFE.PARSE_JSON(result) AS j
  FROM martech_dw.mm_gaps_log
  WHERE status = '' AND IFNULL(finish_reason, '') != 'MAX_TOKENS'
    AND JSON_QUERY_ARRAY(SAFE.PARSE_JSON(result), '$.gaps') IS NOT NULL
  QUALIFY ROW_NUMBER() OVER (PARTITION BY creative_id, mode ORDER BY created_at DESC) = 1
),
texts AS (
  SELECT mode, creative_id,
    ARRAY_TO_STRING(ARRAY(SELECT JSON_VALUE(x) FROM UNNEST(JSON_QUERY_ARRAY(j, '$.ad_texts')) AS x), ' ｜ ') AS ad_texts
  FROM ok
),
-- Gemini 列的每一項落差一列
found AS (
  SELECT o.mode, o.creative_id, pos,
    JSON_VALUE(g, '$.gap_type') AS gap_type,
    IFNULL(JSON_VALUE(g, '$.ad_text'), '') AS ad_text,
    IFNULL(JSON_VALUE(g, '$.page_evidence'), '') AS page_evidence
  FROM ok o, UNNEST(JSON_QUERY_ARRAY(o.j, '$.gaps')) AS g WITH OFFSET AS pos
),
answer AS (
  SELECT md AS mode, k.creative_id, k.gap_type, k.ad_keyword, k.page_fact, k.disputed
  FROM martech_gt.gt_ad_page_gaps k
  CROSS JOIN UNNEST(['image', 'text']) AS md
),
-- 對得上的組合：同一種給法、同一張圖、同一種落差，而且抄下來的廣告文字裡有那個詞
matched AS (
  SELECT a.mode, a.creative_id, a.gap_type, a.ad_keyword, f.pos, f.ad_text, f.page_evidence
  FROM answer a
  JOIN found f
    ON f.mode = a.mode AND f.creative_id = a.creative_id AND f.gap_type = a.gap_type
   AND STRPOS(f.ad_text, a.ad_keyword) > 0
),
answer_side AS (
  SELECT a.mode, a.creative_id, a.gap_type,
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
  LEFT JOIN ok o ON o.mode = a.mode AND o.creative_id = a.creative_id
  LEFT JOIN matched m
    ON m.mode = a.mode AND m.creative_id = a.creative_id AND m.gap_type = a.gap_type AND m.ad_keyword = a.ad_keyword
  GROUP BY a.mode, a.creative_id, a.gap_type, a.ad_keyword, a.page_fact, a.disputed, o.creative_id
),
-- 對不到答案表任何一列的落差
unmatched AS (
  SELECT f.mode, f.creative_id, f.gap_type,
    IF(f.gap_type = 'other', 'other', 'extra') AS verdict,
    TRUE AS listed,
    CAST(NULL AS STRING) AS ad_keyword, CAST(NULL AS STRING) AS page_fact,
    STRING_AGG(f.ad_text, ' ／ ' ORDER BY f.pos) AS ad_text,
    STRING_AGG(f.page_evidence, ' ／ ' ORDER BY f.pos) AS page_evidence
  FROM found f
  LEFT JOIN (SELECT DISTINCT mode, creative_id, pos FROM matched) m
    ON m.mode = f.mode AND m.creative_id = f.creative_id AND m.pos = f.pos
  WHERE m.pos IS NULL
  GROUP BY f.mode, f.creative_id, f.gap_type
),
unioned AS (
  SELECT * FROM answer_side
  UNION ALL
  SELECT * FROM unmatched
)
SELECT u.mode, u.creative_id, c.page_id, c.utm_campaign, c.product_focus,
  u.gap_type, u.verdict, u.listed, u.ad_keyword, u.page_fact,
  IF(u.ad_keyword IS NULL, NULL, STRPOS(IFNULL(t.ad_texts, ''), u.ad_keyword) > 0) AS ad_read,
  u.ad_text, u.page_evidence, t.ad_texts
FROM unioned u
JOIN martech_dw.map_creative_landing c USING (creative_id)
LEFT JOIN texts t ON t.mode = u.mode AND t.creative_id = u.creative_id;

-- 每次評分留一筆紀錄：答案表的指紋（每一列的內容排序後雜湊），check.sql 用它確認評分之後答案表沒有被改過
CREATE TABLE IF NOT EXISTS martech_gt.ad_page_gaps_runs (
  scored_at TIMESTAMP,
  answer_rows INT64,
  answer_fingerprint STRING
)
OPTIONS (description = 'Day 19 每次評分當下的答案表指紋，只加不刪');

INSERT INTO martech_gt.ad_page_gaps_runs
SELECT CURRENT_TIMESTAMP(), COUNT(*),
  TO_HEX(SHA256(STRING_AGG(CONCAT(creative_id, '|', gap_type, '|', ad_keyword, '|', page_fact, '|', CAST(disputed AS STRING)), '\n' ORDER BY creative_id, gap_type, ad_keyword)))
FROM martech_gt.gt_ad_page_gaps;

SELECT mode, verdict, COUNT(*) AS n
FROM martech_dw.mart_ad_page_gaps
GROUP BY 1, 2
ORDER BY 1, 2;
