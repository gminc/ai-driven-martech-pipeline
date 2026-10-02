-- Day 19：對答案，把 Gemini 列的落差和答案表 martech_gt.gt_ad_page_gaps 比，結果放進 mart_ad_page_gaps
-- 一列＝一種給法 × 一張廣告圖 × 一種落差，verdict 五種：
--   hit      答案表有、Gemini 也列了
--   miss     答案表有、Gemini 沒列
--   extra    答案表沒有、Gemini 列了（五種查得到對錯的落差才算，等於無中生有或看法不同，報表會印原文）
--   disputed 答案表標成有爭議的那一列，不管 Gemini 有沒有列都不計分
--   other    Gemini 填 other 的落差，不計分，報表印原文
-- 同一張圖的同一種落差被列了好幾次只算一次
-- ad_read：Gemini 抄下來的廣告文字（ad_texts）裡有沒有答案表的那個詞，用來分辨「有讀到但沒列」和「根本沒讀到」
-- 這個檔會讀答案表，不呼叫 Gemini，查詢在每月 1 TiB 免費額度內，整張重建，可以重複執行

CREATE OR REPLACE TABLE martech_dw.mart_ad_page_gaps
OPTIONS (description = 'Day 19 廣告與頁面的落差對答案：一列＝給法 × 廣告圖 × 落差種類，verdict 是 hit／miss／extra／disputed／other')
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
found AS (
  SELECT o.mode, o.creative_id, JSON_VALUE(g, '$.gap_type') AS gap_type,
    STRING_AGG(JSON_VALUE(g, '$.ad_text'), ' ／ ') AS ad_text,
    STRING_AGG(JSON_VALUE(g, '$.page_evidence'), ' ／ ') AS page_evidence
  FROM ok o, UNNEST(JSON_QUERY_ARRAY(o.j, '$.gaps')) AS g
  GROUP BY 1, 2, 3
),
answer AS (
  SELECT mode, k.creative_id, k.gap_type, k.ad_keyword, k.page_fact, k.disputed
  FROM martech_gt.gt_ad_page_gaps k
  CROSS JOIN UNNEST(['image', 'text']) AS mode
)
SELECT
  COALESCE(a.mode, f.mode) AS mode,
  COALESCE(a.creative_id, f.creative_id) AS creative_id,
  m.page_id, m.utm_campaign, m.product_focus,
  COALESCE(a.gap_type, f.gap_type) AS gap_type,
  CASE
    WHEN f.gap_type = 'other' THEN 'other'
    WHEN a.disputed THEN 'disputed'
    WHEN a.gap_type IS NOT NULL AND f.gap_type IS NOT NULL THEN 'hit'
    WHEN a.gap_type IS NOT NULL THEN 'miss'
    ELSE 'extra'
  END AS verdict,
  f.gap_type IS NOT NULL AS listed,
  a.ad_keyword, a.page_fact,
  IF(a.ad_keyword IS NULL, NULL, STRPOS(IFNULL(t.ad_texts, ''), a.ad_keyword) > 0) AS ad_read,
  f.ad_text, f.page_evidence, t.ad_texts
FROM answer a
FULL OUTER JOIN found f
  ON f.mode = a.mode AND f.creative_id = a.creative_id AND f.gap_type = a.gap_type
JOIN martech_dw.map_creative_landing m ON m.creative_id = COALESCE(a.creative_id, f.creative_id)
LEFT JOIN texts t ON t.mode = COALESCE(a.mode, f.mode) AND t.creative_id = COALESCE(a.creative_id, f.creative_id);

-- 每次評分留一筆紀錄：答案表的指紋（每一列的內容排序後雜湊），check.sql 用它確認評分之後答案表沒有被改過
CREATE TABLE IF NOT EXISTS martech_gt.ad_page_gaps_runs (
  scored_at TIMESTAMP,
  answer_rows INT64,
  answer_fingerprint STRING
)
OPTIONS (description = 'Day 19 每次評分當下的答案表指紋，只加不刪');

INSERT INTO martech_gt.ad_page_gaps_runs
SELECT CURRENT_TIMESTAMP(), COUNT(*),
  TO_HEX(SHA256(STRING_AGG(CONCAT(creative_id, '|', gap_type, '|', ad_keyword, '|', page_fact, '|', CAST(disputed AS STRING)), '\n' ORDER BY creative_id, gap_type)))
FROM martech_gt.gt_ad_page_gaps;

SELECT mode, verdict, COUNT(*) AS n
FROM martech_dw.mart_ad_page_gaps
GROUP BY 1, 2
ORDER BY 1, 2;
