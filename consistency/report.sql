-- Day 19：報表，Gemini 抓到幾成、漏了哪些、有沒有無中生有，兩種給頁面的方式差在哪
-- 會讀答案表（對答案用），不呼叫 Gemini，查詢在每月 1 TiB 免費額度內

-- ① 哪張廣告對哪個頁面
SELECT m.page_id, p.title, COUNT(*) AS creatives,
  STRING_AGG(m.creative_id, '、' ORDER BY m.creative_id) AS creative_ids
FROM martech_dw.map_creative_landing m
JOIN martech_dw.ref_landing_pages p USING (page_id)
GROUP BY 1, 2
ORDER BY 1;

-- ② 總成績：計分的 21 個落差抓到幾個（recall），列出來的落差（other 與有爭議的不算）有幾成對得上答案表（precision）
--    precision 量的是和答案表一致的比例，多列的不一定是錯的，要看第 ④ 段的原文
--    clean_flagged：6 張沒有任何計分落差的廣告圖裡，被多列的有幾張，decoy：清單上那兩種答案表沒有的落差（gift、warranty）被列了幾次
WITH scored_ads AS (
  SELECT DISTINCT creative_id FROM martech_gt.gt_ad_page_gaps WHERE NOT disputed
)
SELECT mode,
  COUNTIF(verdict IN ('hit', 'miss')) AS answers,
  COUNTIF(verdict = 'hit') AS hit,
  COUNTIF(verdict = 'miss') AS miss,
  COUNTIF(verdict = 'extra') AS extra,
  ROUND(SAFE_DIVIDE(COUNTIF(verdict = 'hit'), COUNTIF(verdict IN ('hit', 'miss'))), 3) AS recall,
  ROUND(SAFE_DIVIDE(COUNTIF(verdict = 'hit'), COUNTIF(verdict IN ('hit', 'extra'))), 3) AS precision,
  COUNT(DISTINCT IF(verdict = 'extra' AND s.creative_id IS NULL, g.creative_id, NULL)) AS clean_flagged,
  COUNTIF(verdict = 'extra' AND gap_type IN ('gift', 'warranty')) AS decoy,
  COUNTIF(verdict = 'disputed' AND listed) AS disputed_listed,
  COUNTIF(verdict = 'other') AS other_rows
FROM martech_dw.mart_ad_page_gaps g
LEFT JOIN scored_ads s USING (creative_id)
GROUP BY mode
ORDER BY mode;

-- ③ 各種落差分開看
SELECT gap_type, mode,
  COUNTIF(verdict IN ('hit', 'miss')) AS answers,
  COUNTIF(verdict = 'hit') AS hit,
  COUNTIF(verdict = 'miss') AS miss,
  COUNTIF(verdict = 'extra') AS extra,
  COUNTIF(verdict = 'miss' AND ad_read) AS miss_but_read,
  COUNTIF(verdict = 'miss' AND NOT ad_read) AS miss_not_read
FROM martech_dw.mart_ad_page_gaps
WHERE verdict IN ('hit', 'miss', 'extra')
GROUP BY 1, 2
ORDER BY 1, 2;

-- ④ 漏掉的與多列的，逐列看原文
SELECT mode, verdict, creative_id, page_id, gap_type, ad_keyword, ad_read, ad_text, page_evidence
FROM martech_dw.mart_ad_page_gaps
WHERE verdict IN ('miss', 'extra')
ORDER BY mode, verdict, gap_type, creative_id;

-- ⑤ 有爭議的 9 列，兩種給法各有沒有列、怎麼說
SELECT mode, creative_id, gap_type, ad_keyword, listed, ad_text, page_evidence, page_fact
FROM martech_dw.mart_ad_page_gaps
WHERE verdict = 'disputed'
ORDER BY mode, gap_type, ad_keyword, creative_id;

-- ⑥ 填 other 的落差原文
SELECT mode, creative_id, page_id, ad_text, page_evidence
FROM martech_dw.mart_ad_page_gaps
WHERE verdict = 'other'
ORDER BY mode, creative_id;

-- ⑦ 兩種給法在同一格的結果有沒有一樣（計分的 21 格，每格只問一次，差一兩格可能只是運氣）
SELECT i.gap_type,
  COUNTIF(i.verdict = 'hit' AND t.verdict = 'hit') AS both_hit,
  COUNTIF(i.verdict = 'hit' AND t.verdict = 'miss') AS image_only,
  COUNTIF(i.verdict = 'miss' AND t.verdict = 'hit') AS text_only,
  COUNTIF(i.verdict = 'miss' AND t.verdict = 'miss') AS both_miss
FROM martech_dw.mart_ad_page_gaps i
JOIN martech_dw.mart_ad_page_gaps t USING (creative_id, gap_type, ad_keyword)
WHERE i.mode = 'image' AND t.mode = 'text' AND i.verdict IN ('hit', 'miss')
GROUP BY ROLLUP(i.gap_type)
ORDER BY i.gap_type NULLS LAST;

-- ⑧ 費用（呼叫紀錄全部算，包含失敗的呼叫），單價是 gemini-3.6-flash 非 global 端點，每百萬 Token 輸入 US$ 0.825、輸出含思考 US$ 4.125，匯率 32
SELECT mode, page_id,
  COUNT(*) AS calls,
  CAST(ROUND(AVG(prompt_tokens)) AS INT64) AS avg_input_tokens,
  CAST(ROUND(AVG(IFNULL(output_tokens, 0) + IFNULL(thoughts_tokens, 0))) AS INT64) AS avg_output_tokens,
  COUNTIF(finish_reason = 'MAX_TOKENS') AS cut_by_cap,
  ROUND(SUM(IFNULL(prompt_tokens, 0) * 0.825
          + (IFNULL(output_tokens, 0) + IFNULL(thoughts_tokens, 0)) * 4.125) / 1e6 * 32, 3) AS cost_twd
FROM martech_dw.mm_gaps_log
GROUP BY ROLLUP(mode, page_id)
ORDER BY mode NULLS LAST, page_id NULLS LAST;
