-- Day 25：單價對照表，一列＝一個模型在一種端點、一段期間的每百萬 Token 美元單價
-- 用量表（ops_llm_usage）只存 Token 數，單價放這裡，官方調價時只要加一列，不用回頭改用量
-- 來源：Agent Platform（原 Vertex AI）定價頁 Standard 層，2026-10-08 查
--   https://cloud.google.com/vertex-ai/generative-ai/pricing
-- gemini-3.6-flash 到 2026-12-31 是導入期價格，2027-01-01 起恢復原價（兩倍），
--   但官方已公告這個模型 2026-11-19 停用（建議改用 gemini-3.8-flash），2027 那兩列只是照定價頁記下來
-- gemini-3.1-pro-preview 每次輸入在 20 萬 Token 以內的價格（超過是 4 / 18 美元，這個系列沒有用到）
-- 非 global 端點（區域與多區域）比 global 貴一成
-- 這裡沒有列到的模型，在 view 裡 priced 是 false、費用是 NULL：
--   有 Token 的呼叫，check.sql 第 07 項會指出來
--   不是用 Token 計費的（Day 18 的 Veo 影片按秒計費，用量表裡 Token 是空的）不會被第 07 項指出來，
--   它會出現在 view 的 unpriced_calls 與 report.sql 第 4 段，儀表板的費用合計不含這一筆
-- 查詢在每月 1 TiB 免費額度內

CREATE OR REPLACE TABLE martech_dw.ref_llm_price (
  model STRING,
  endpoint_type STRING,
  valid_from DATE,
  valid_to DATE,
  usd_in_per_m NUMERIC,
  usd_out_per_m NUMERIC,
  note STRING
)
OPTIONS (description = 'Gemini 單價對照表：每百萬 Token 的美元單價，依模型、端點、期間，Day 25 的 view 用');

INSERT INTO martech_dw.ref_llm_price VALUES
  ('gemini-3.6-flash',      'global',     DATE '2026-07-21', DATE '2026-12-31', 0.75,  3.75,  'introductory pricing'),
  ('gemini-3.6-flash',      'non-global', DATE '2026-07-21', DATE '2026-12-31', 0.825, 4.125, 'introductory pricing'),
  ('gemini-3.6-flash',      'global',     DATE '2027-01-01', DATE '9999-12-31', 1.50,  7.50,  'standard pricing'),
  ('gemini-3.6-flash',      'non-global', DATE '2027-01-01', DATE '9999-12-31', 1.65,  8.25,  'standard pricing'),
  ('gemini-3.5-flash-lite', 'global',     DATE '2026-07-21', DATE '9999-12-31', 0.30,  2.50,  ''),
  ('gemini-3.5-flash-lite', 'non-global', DATE '2026-07-21', DATE '9999-12-31', 0.33,  2.75,  ''),
  ('gemini-3.1-pro-preview', 'global',    DATE '2026-01-01', DATE '9999-12-31', 2.00,  12.00, 'input up to 200K tokens');
