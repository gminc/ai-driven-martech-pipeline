-- Day 23：拿 Day 18 的 12 份草稿測宣稱用語的過濾（不呼叫模型，不花錢）
-- 比對前兩邊都先正規化：NFKC（全形轉半形）、去掉空白、英文轉小寫，和 agent/guard.py 的 normalize 幾乎一樣（這裡沒有去掉看不見的字元，草稿是自己產的不會有）
-- lexicon = 'day18' 是原本的 38 個詞，'day18+day23' 再加上讀完草稿才發現的 4 個
-- 查詢在每月 1 TiB 免費額度內

WITH drafts AS (
  SELECT creative_id, version, sample,
    LOWER(REGEXP_REPLACE(NORMALIZE(CONCAT(headline, ' ', IFNULL(subhead, ''), ' ', IFNULL(badge, ''), ' ', cta_text), NFKC), r'\s+', '')) AS txt
  FROM martech_dw.mart_creative_drafts
),
terms AS (
  SELECT 'day18' AS lexicon, term, kind FROM martech_dw.ref_claim_terms
  UNION ALL SELECT 'day18+day23', term, kind FROM martech_dw.ref_claim_terms
  UNION ALL SELECT 'day18+day23', term, kind FROM martech_dw.ref_claim_terms_d23
),
hits AS (
  SELECT t.lexicon, d.creative_id, d.version, d.sample, t.term
  FROM drafts d JOIN terms t
    ON STRPOS(d.txt, LOWER(REGEXP_REPLACE(NORMALIZE(t.term, NFKC), r'\s+', ''))) > 0
)
SELECT l.lexicon, v.version,
  (SELECT COUNT(*) FROM drafts d WHERE d.version = v.version) AS drafts,
  COUNT(DISTINCT CONCAT(h.creative_id, '/', CAST(h.sample AS STRING))) AS drafts_flagged,
  STRING_AGG(DISTINCT h.term, '、' ORDER BY h.term) AS terms_found
FROM (SELECT DISTINCT lexicon FROM terms) l
CROSS JOIN (SELECT DISTINCT version FROM drafts) v
LEFT JOIN hits h ON h.lexicon = l.lexicon AND h.version = v.version
GROUP BY l.lexicon, v.version
ORDER BY l.lexicon, v.version;
