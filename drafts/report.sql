-- Day 18 報表，八段：
--   ① 對象：新客受眾裡點擊率最低的三張圖，現況（Day 16 AI 讀出來的特徵）
--   ② 草稿一覽：12 份草稿的文案、四個特徵、引用的倍數
--   ③ 照成效改了沒：原圖沒有、草稿加上的人物、右下按鈕、暖色，兩版各幾份
--   ④ 引用的倍數對不對：對到點擊率、對到轉換率、都對不到
--   ⑤ 不能寫的詞：兩版各有幾份草稿冒出來、冒出哪些詞
--   ⑥ 預期效果原文：有沒有承諾轉換或銷售（正規表示式只是初篩，要看原文）
--   ⑦ 費用：輸入、輸出、思考 Token 與新台幣（gemini-3.6-flash 非 global 單價：輸入 0.825、輸出 4.125 美元每百萬 Token，1 美元＝32 元）
--   ⑧ 看完草稿才發現的詞與預期效果裡寫進倍數的份數（描述性，第一輪執行之後加的）
-- 只讀 martech_dw，查詢在每月 1 TiB 免費額度內

-- ① 對象
SELECT p.creative_id, p.channel, ROUND(p.ctr * 100, 2) AS ctr_pct,
  f.has_person, f.cta_position, f.dominant_color, f.text_density, f.headline
FROM martech_dw.mart_creative_perf p
JOIN martech_dw.mart_creative_features f USING (creative_id)
WHERE p.creative_id IN (SELECT DISTINCT creative_id FROM martech_dw.mart_creative_drafts)
ORDER BY p.ctr;

-- ② 草稿一覽
SELECT version, creative_id, sample, headline, subhead, badge, cta_text,
  CHAR_LENGTH(headline) AS h_len, CHAR_LENGTH(subhead) AS s_len,
  has_person AS person, cta_position AS cta, dominant_color AS color, text_density AS text,
  cited_feature AS cited, cited_ratio AS ratio, cited_match AS matched,
  ARRAY_TO_STRING(claim_terms, '、') AS claims
FROM martech_dw.mart_creative_drafts
ORDER BY version, creative_id, sample;

-- ③ 照成效改了沒（分母是原圖本來就沒有這個特徵的草稿數）
SELECT version,
  COUNT(*) AS drafts,
  FORMAT('%d/%d', COUNTIF(added_person), COUNTIF(NOT old_has_person)) AS added_person,
  FORMAT('%d/%d', COUNTIF(moved_cta), COUNTIF(old_cta_position != 'bottom_right')) AS moved_cta,
  FORMAT('%d/%d', COUNTIF(turned_warm), COUNTIF(old_dominant_color != 'warm')) AS turned_warm,
  COUNTIF(text_density = 'high') AS text_high
FROM martech_dw.mart_creative_drafts
GROUP BY version
ORDER BY version;

-- ④ 引用的倍數對不對
SELECT version, cited_feature, cited_match,
  COUNT(*) AS drafts,
  STRING_AGG(DISTINCT CAST(cited_ratio AS STRING), '、') AS cited_values,
  ANY_VALUE(table_ctr) AS table_ctr
FROM martech_dw.mart_creative_drafts
GROUP BY 1, 2, 3
ORDER BY 1, 2, 3;

-- ⑤ 不能寫的詞
WITH
per_version AS (
  SELECT version, COUNT(*) AS drafts, COUNTIF(ARRAY_LENGTH(claim_terms) > 0) AS drafts_with_claims
  FROM martech_dw.mart_creative_drafts
  GROUP BY version
),
term_counts AS (  -- 每個詞出現在幾份草稿
  SELECT d.version, c.kind, t AS term, COUNT(*) AS drafts
  FROM martech_dw.mart_creative_drafts d
  CROSS JOIN UNNEST(d.claim_terms) AS t
  JOIN martech_dw.ref_claim_terms c ON c.term = t
  GROUP BY 1, 2, 3
)
SELECT p.version, p.drafts, p.drafts_with_claims,
  STRING_AGG(FORMAT('%s:%s×%d', tc.kind, tc.term, tc.drafts), '、' ORDER BY tc.drafts DESC, tc.term) AS terms
FROM per_version p
LEFT JOIN term_counts tc USING (version)
GROUP BY 1, 2, 3
ORDER BY 1;

-- ⑥ 預期效果原文
SELECT version, creative_id, sample, mentions_sales, expected_effect
FROM martech_dw.mart_creative_drafts
ORDER BY version, creative_id, sample;

-- ⑦ 費用（呼叫紀錄全部算，包含失敗的呼叫與第一次用 output_schema 試跑的那一輪）
SELECT m AS method, version,
  COUNT(*) AS calls,
  SUM(prompt_tokens) AS input_tokens,
  SUM(output_tokens) AS output_tokens,
  SUM(thoughts_tokens) AS thoughts_tokens,
  COUNTIF(finish_reason = 'MAX_TOKENS') AS cut_by_cap,
  ROUND(SUM(IFNULL(prompt_tokens, 0) * 0.825
          + (IFNULL(output_tokens, 0) + IFNULL(thoughts_tokens, 0)) * 4.125) / 1e6 * 32, 3) AS cost_twd
FROM (SELECT IFNULL(method, 'output_schema') AS m, * EXCEPT (method) FROM martech_dw.mm_drafts_log)
GROUP BY ROLLUP(m, version)
ORDER BY m NULLS LAST, version NULLS LAST;

-- ⑧ 看完草稿才發現的詞（第一次執行之後加的描述性統計，不改第 5 段的判定，詞庫 ref_claim_terms 也沒有動）
--   極致、強效：沒有根據的程度用語，黃金：誇飾，日本級：商品資料裡沒有的事實
--   這幾個詞會在 Day 23 做過濾時再決定要不要收進詞庫
WITH d AS (
  SELECT version, expected_effect, table_ctr,
    REGEXP_EXTRACT_ALL(CONCAT(headline, ' ', IFNULL(subhead, ''), ' ', IFNULL(badge, ''), ' ', cta_text), r'極致|強效|黃金|日本級') AS found
  FROM martech_dw.mart_creative_drafts
),
w AS (
  SELECT version, STRING_AGG(DISTINCT x, '、' ORDER BY x) AS words
  FROM d CROSS JOIN UNNEST(d.found) AS x
  GROUP BY version
)
SELECT d.version,
  COUNT(*) AS drafts,
  COUNTIF(ARRAY_LENGTH(d.found) > 0) AS drafts_with_puffery,
  ANY_VALUE(w.words) AS words,
  -- 預期效果裡出現引用特徵的點擊率倍數（今天是 1.28），數字從倍數表來，不寫死
  COUNTIF(STRPOS(IFNULL(d.expected_effect, ''), FORMAT('%.2f', d.table_ctr)) > 0) AS promises_ratio
FROM d
LEFT JOIN w USING (version)
GROUP BY d.version
ORDER BY d.version;
