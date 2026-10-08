-- Day 25：把用量表變成儀表板讀得懂的兩個 view
--   v_llm_usage_calls  一列＝一次模型呼叫，補上日期（台北時間）、單價與費用
--   v_llm_usage_daily  一列＝一天 × 哪一篇 × 哪支程式 × 模型 × 端點，儀表板接這一個
-- 費用＝輸入 Token × 輸入單價＋輸出 Token × 輸出單價（用量表的 output_tokens 已經含思考 Token）
-- 匯率固定用 1 美元 32 元，和前面每一篇一致，實際金額以帳單為準
-- 用量表裡有記的失敗呼叫（Day 16、18、19、20）照樣算進來，有回報 Token 的就是有被收費
-- Day 21 起的程式只把成功的呼叫抄進用量表，所以那幾天的 failed_calls 一定是 0，不代表沒有失敗過
-- 對不到單價的呼叫（Day 18 的 Veo 影片按秒計費）費用是 NULL，合計不含它，數量看 unpriced_calls
-- view 不存資料、不收儲存費，每次被查才去讀用量表
-- 查詢在每月 1 TiB 免費額度內

CREATE OR REPLACE VIEW martech_dw.v_llm_usage_calls
OPTIONS (description = 'Day 25：一列＝一次模型呼叫，加上台北日期、單價與費用') AS
SELECT
  u.logged_at,
  DATE(u.logged_at, 'Asia/Taipei') AS usage_date,
  u.day,
  u.job,
  u.run_id,
  u.model,
  u.endpoint_type,
  u.media_resolution,
  u.item_id,
  IF(u.status = '', 'ok', 'failed') AS call_result,
  u.status,
  IFNULL(u.prompt_tokens, 0) AS prompt_tokens,
  IFNULL(u.output_tokens, 0) AS output_tokens,
  p.model IS NOT NULL AS priced,
  IFNULL(u.prompt_tokens, 0) * p.usd_in_per_m / 1e6 * 32 AS cost_in_twd,
  IFNULL(u.output_tokens, 0) * p.usd_out_per_m / 1e6 * 32 AS cost_out_twd,
  (IFNULL(u.prompt_tokens, 0) * p.usd_in_per_m + IFNULL(u.output_tokens, 0) * p.usd_out_per_m) / 1e6 AS cost_usd,
  (IFNULL(u.prompt_tokens, 0) * p.usd_in_per_m + IFNULL(u.output_tokens, 0) * p.usd_out_per_m) / 1e6 * 32 AS cost_twd
FROM martech_dw.ops_llm_usage u
LEFT JOIN martech_dw.ref_llm_price p
  ON p.model = u.model
 AND p.endpoint_type = u.endpoint_type
 AND DATE(u.logged_at, 'Asia/Taipei') BETWEEN p.valid_from AND p.valid_to;

CREATE OR REPLACE VIEW martech_dw.v_llm_usage_daily
OPTIONS (description = 'Day 25：儀表板資料來源，一列＝一天 × 哪一篇 × 哪支程式 × 模型 × 端點') AS
SELECT
  usage_date,
  day,
  job,
  model,
  endpoint_type,
  priced,
  COUNT(*) AS calls,
  COUNTIF(call_result = 'failed') AS failed_calls,
  COUNTIF(NOT priced) AS unpriced_calls,
  SUM(prompt_tokens) AS prompt_tokens,
  SUM(output_tokens) AS output_tokens,
  SUM(prompt_tokens + output_tokens) AS total_tokens,
  SUM(cost_in_twd) AS cost_in_twd,
  SUM(cost_out_twd) AS cost_out_twd,
  SUM(cost_usd) AS cost_usd,
  SUM(cost_twd) AS cost_twd
FROM martech_dw.v_llm_usage_calls
GROUP BY usage_date, day, job, model, endpoint_type, priced;
