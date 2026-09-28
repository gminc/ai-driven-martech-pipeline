-- ① 成績單（一列＝一個檢查項目；run.sh 會把這份檔案的每一段 SELECT 分開執行）
SELECT check_id, signal_id, found_by_day, method, lower_bound, upper_bound, actual, verdict
FROM martech_gt.acceptance_scorecard
ORDER BY check_id;

-- ② 每個訊號的判定：同一題的檢查項目全部找到才算找到
SELECT signal_id, COUNT(*) AS checks, COUNTIF(verdict = '找到') AS found,
  CASE
    WHEN LOGICAL_AND(verdict = '待考') THEN '待考'
    WHEN LOGICAL_AND(verdict = '找到') THEN '找到'
    WHEN LOGICAL_OR(verdict = '找到') THEN '部分找到'
    ELSE '沒找到'
  END AS verdict
FROM martech_gt.acceptance_scorecard
GROUP BY signal_id
ORDER BY signal_id;

-- ③ 盲測：每個訊號，兩個模型各三次裡找到幾次
SELECT signal_id,
  COUNTIF(model = 'gemini-3.5-flash-lite' AND found) AS flash_lite_found_of_3,
  COUNTIF(model = 'gemini-3.6-flash' AND found) AS flash_found_of_3
FROM martech_gt.blind_scorecard
GROUP BY signal_id
ORDER BY signal_id;

-- ④ 盲測每一次呼叫：列了幾項發現、命中幾個訊號、用了多少 token
SELECT r.model, r.run_no,
  (SELECT COUNT(*) FROM martech_dw.blind_findings f WHERE f.model = r.model AND f.run_no = r.run_no) AS findings,
  (SELECT COUNTIF(found) FROM martech_gt.blind_scorecard s WHERE s.model = r.model AND s.run_no = r.run_no) AS signals_found,
  SAFE_CAST(JSON_VALUE(r.statistics, '$.prompt_token_count') AS INT64) AS input_tokens,
  SAFE_CAST(JSON_VALUE(r.statistics, '$.candidates_token_count') AS INT64) AS output_tokens,
  SAFE_CAST(JSON_VALUE(r.statistics, '$.thoughts_token_count') AS INT64) AS thinking_tokens
FROM martech_dw.blind_result r
ORDER BY r.model, r.run_no;

-- ⑤ 盲測實際費用：依 statistics 的 token 數 × 非 global 端點的單價（同 blind_cost.sql，2026-09-29 由 global 單價更正），新台幣以 1 美元 32 元換算
SELECT r.model, COUNT(*) AS calls,
  SUM(SAFE_CAST(JSON_VALUE(r.statistics, '$.prompt_token_count') AS INT64)) AS input_tokens,
  SUM(SAFE_CAST(JSON_VALUE(r.statistics, '$.candidates_token_count') AS INT64)) AS output_tokens,
  ROUND((SUM(SAFE_CAST(JSON_VALUE(r.statistics, '$.prompt_token_count') AS INT64)) * p.in_usd
       + SUM(SAFE_CAST(JSON_VALUE(r.statistics, '$.candidates_token_count') AS INT64)) * p.out_usd) / 1e6, 4) AS usd,
  ROUND((SUM(SAFE_CAST(JSON_VALUE(r.statistics, '$.prompt_token_count') AS INT64)) * p.in_usd
       + SUM(SAFE_CAST(JSON_VALUE(r.statistics, '$.candidates_token_count') AS INT64)) * p.out_usd) / 1e6 * 32, 2) AS twd
FROM martech_dw.blind_result r
JOIN (
  SELECT 'gemini-3.5-flash-lite' AS model, 0.33 AS in_usd, 2.75 AS out_usd
  UNION ALL SELECT 'gemini-3.6-flash', 0.825, 4.125
) p USING (model)
GROUP BY r.model, p.in_usd, p.out_usd
ORDER BY r.model;

-- ⑥ 盲測每一項發現，以及它命中的訊號（空白＝沒有對到任何一題）
SELECT f.model, f.run_no, f.finding_no,
  (SELECT STRING_AGG(s.signal_id ORDER BY s.signal_id)
   FROM martech_gt.blind_scorecard s
   WHERE s.model = f.model AND s.run_no = f.run_no AND f.finding_no IN UNNEST(s.matched_findings)) AS signals,
  f.target, f.period, f.observation, f.likely_cause
FROM martech_dw.blind_findings f
ORDER BY f.model, f.run_no, f.finding_no;
