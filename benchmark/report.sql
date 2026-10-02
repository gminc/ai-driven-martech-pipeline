-- Day 20：報表，同一份題目和答案，三個等級的模型各答對幾成、各花多少錢（一批跑多久在 timing.sql）
-- 會讀答案表（對答案用），不呼叫 Gemini，查詢在每月 1 TiB 免費額度內
-- 單價（每百萬 Token，美元，輸出含思考，前兩個是非 global 端點）：gemini-3.5-flash-lite 0.33／2.75、gemini-3.6-flash 0.825／4.125（到 2026 年底的上市優惠價）、
-- gemini-3.1-pro-preview 2／12（預覽版只有 global 端點，官方定價頁也只列這一種價格），實際以帳單為準，匯率 32

-- ① 每個組合的呼叫紀錄從哪裡來：day16／day19 是沿用的舊紀錄，day20 是這次新問的
SELECT task, model, source,
  COUNT(*) AS call_rows, COUNTIF(ok) AS ok_rows, COUNTIF(NOT ok) AS failed,
  COUNTIF(finish_reason = 'MAX_TOKENS') AS cut_by_cap,
  MIN(created_at) AS first_call, MAX(created_at) AS last_call
FROM martech_dw.mm_bench_log
GROUP BY 1, 2, 3
ORDER BY 1, 2, 3;

-- ② 簡單題總成績：四個分類欄位計分的 95 格答對幾格，標題 24 格另外算，off_option 是值不在選項裡的格子
--    沒有成功呼叫紀錄的格子（no_call）會留在分母裡算沒答對，no_call 欄位不是 0 時成績不能直接拿來比
SELECT model,
  COUNTIF(counted) AS cells,
  COUNTIF(counted AND verdict = 'correct') AS correct,
  ROUND(SAFE_DIVIDE(COUNTIF(counted AND verdict = 'correct'), COUNTIF(counted)), 3) AS accuracy,
  COUNTIF(field = 'headline') AS headlines,
  COUNTIF(field = 'headline' AND verdict = 'correct') AS headline_correct,
  COUNTIF(field != 'headline' AND NOT IFNULL(in_option, FALSE)) AS off_option,
  COUNTIF(review = 'borderline') AS borderline_cells,
  COUNTIF(review = 'borderline' AND verdict = 'correct') AS borderline_correct,
  COUNTIF(verdict = 'no_call') AS no_call
FROM martech_dw.mart_bench_features
GROUP BY 1
ORDER BY 1;

-- ③ 簡單題各欄位分開看
SELECT field, model,
  COUNTIF(counted OR field = 'headline') AS cells,
  COUNTIF((counted OR field = 'headline') AND verdict = 'correct') AS correct
FROM martech_dw.mart_bench_features
GROUP BY 1, 2
ORDER BY 1, 2;

-- ④ 簡單題答錯的格子逐一列出（包含不計分的 disagree 那一格，review 欄位看得出來）
SELECT model, creative_id, field, said, spec, review, counted
FROM martech_dw.mart_bench_features
WHERE verdict = 'wrong'
ORDER BY field, creative_id, model;

-- ⑤ 難題總成績：計分的 21 個落差抓到幾個（recall），列出來的落差有幾成對得上答案表（precision，other 與有爭議的不算）
--    clean_flagged：6 張沒有計分落差的廣告圖被多列的有幾張，decoy：清單上那兩種答案表沒有的落差（gift、warranty）被列了幾次
WITH scored_ads AS (
  SELECT DISTINCT creative_id FROM martech_gt.gt_ad_page_gaps WHERE NOT disputed
)
SELECT model,
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
FROM martech_dw.mart_bench_gaps g
LEFT JOIN scored_ads s USING (creative_id)
GROUP BY model
ORDER BY model;

-- ⑥ 難題各種落差分開看
SELECT gap_type, model,
  COUNTIF(verdict IN ('hit', 'miss')) AS answers,
  COUNTIF(verdict = 'hit') AS hit,
  COUNTIF(verdict = 'miss') AS miss,
  COUNTIF(verdict = 'extra') AS extra,
  COUNTIF(verdict = 'miss' AND ad_read) AS miss_but_read,
  COUNTIF(verdict = 'miss' AND NOT ad_read) AS miss_not_read
FROM martech_dw.mart_bench_gaps
WHERE verdict IN ('hit', 'miss', 'extra')
GROUP BY 1, 2
ORDER BY 1, 2;

-- ⑦ 難題漏掉的與多列的，逐列看原文
SELECT model, verdict, creative_id, page_id, gap_type, ad_keyword, ad_read, ad_text, page_evidence
FROM martech_dw.mart_bench_gaps
WHERE verdict IN ('miss', 'extra')
ORDER BY model, verdict, gap_type, creative_id;

-- ⑧ 難題有爭議的 9 列與填 other 的，各模型有沒有列、怎麼說
SELECT model, verdict, creative_id, gap_type, ad_keyword, listed, ad_text, page_evidence
FROM martech_dw.mart_bench_gaps
WHERE verdict IN ('disputed', 'other')
ORDER BY verdict, gap_type, ad_keyword, creative_id, model;

-- ⑨ 費用：avg_* 與 twd_per_1000 只看成功的呼叫，twd_per_1000 是照這次的平均用量問 1,000 張要多少新台幣
--    spent_twd 是紀錄表裡每一列加起來（包含失敗與重問的），沿用的兩個組合只抄了成功的那 24 筆，當天失敗的不在裡面
WITH price AS (
  SELECT * FROM UNNEST([
    STRUCT('gemini-3.5-flash-lite' AS model, 0.33 AS usd_in, 2.75 AS usd_out),
    STRUCT('gemini-3.6-flash', 0.825, 4.125),
    STRUCT('gemini-3.1-pro-preview', 2.0, 12.0)
  ])
)
SELECT l.task, l.model,
  COUNT(*) AS call_rows,
  COUNTIF(l.ok) AS ok_calls,
  CAST(ROUND(AVG(IF(l.ok, l.prompt_tokens, NULL))) AS INT64) AS avg_input,
  CAST(ROUND(AVG(IF(l.ok, IFNULL(l.output_tokens, 0), NULL))) AS INT64) AS avg_output,
  CAST(ROUND(AVG(IF(l.ok, IFNULL(l.thoughts_tokens, 0), NULL))) AS INT64) AS avg_thoughts,
  MAX(IFNULL(l.output_tokens, 0) + IFNULL(l.thoughts_tokens, 0)) AS max_output_and_thoughts,
  ROUND(AVG(IF(l.ok, IFNULL(l.prompt_tokens, 0) * p.usd_in
          + (IFNULL(l.output_tokens, 0) + IFNULL(l.thoughts_tokens, 0)) * p.usd_out, NULL)) / 1e6 * 32 * 1000, 1) AS twd_per_1000,
  ROUND(SUM(IFNULL(l.prompt_tokens, 0) * p.usd_in
          + (IFNULL(l.output_tokens, 0) + IFNULL(l.thoughts_tokens, 0)) * p.usd_out) / 1e6 * 32, 3) AS spent_twd
FROM martech_dw.mm_bench_log l
LEFT JOIN price p USING (model)
GROUP BY 1, 2
ORDER BY 1, 2;

-- ⑩ 一張表看完：答對幾成、問 1,000 張多少錢
WITH price AS (
  SELECT * FROM UNNEST([
    STRUCT('gemini-3.5-flash-lite' AS model, 0.33 AS usd_in, 2.75 AS usd_out),
    STRUCT('gemini-3.6-flash', 0.825, 4.125),
    STRUCT('gemini-3.1-pro-preview', 2.0, 12.0)
  ])
),
cost AS (
  SELECT l.task, l.model,
    ROUND(AVG(IFNULL(l.prompt_tokens, 0) * p.usd_in
            + (IFNULL(l.output_tokens, 0) + IFNULL(l.thoughts_tokens, 0)) * p.usd_out) / 1e6 * 32 * 1000, 1) AS twd_per_1000
  FROM martech_dw.mm_bench_log l
  JOIN price p USING (model)
  WHERE l.ok
  GROUP BY 1, 2
),
score AS (
  SELECT 'features' AS task, model,
    CONCAT(CAST(COUNTIF(counted AND verdict = 'correct') AS STRING), '/', CAST(COUNTIF(counted) AS STRING)) AS score,
    ROUND(SAFE_DIVIDE(COUNTIF(counted AND verdict = 'correct'), COUNTIF(counted)), 3) AS rate
  FROM martech_dw.mart_bench_features GROUP BY 2
  UNION ALL
  SELECT 'gaps', model,
    CONCAT(CAST(COUNTIF(verdict = 'hit') AS STRING), '/', CAST(COUNTIF(verdict IN ('hit', 'miss')) AS STRING)),
    ROUND(SAFE_DIVIDE(COUNTIF(verdict = 'hit'), COUNTIF(verdict IN ('hit', 'miss'))), 3)
  FROM martech_dw.mart_bench_gaps GROUP BY 2
)
SELECT s.task, s.model, s.score, s.rate, c.twd_per_1000
FROM score s
LEFT JOIN cost c USING (task, model)
ORDER BY s.task, c.twd_per_1000;
