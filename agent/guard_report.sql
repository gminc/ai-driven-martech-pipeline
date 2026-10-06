-- Day 23：報表，四段，每個題次取最新一筆成功的紀錄
-- signal_ 開頭的欄位是程式比對出來的線索，不是最後的判定，回答原文在第 2 段，要自己讀過才算數
-- 查詢在每月 1 TiB 免費額度內

-- 1. 每一題兩種情況並排：哪一層護欄動了、程式比對到什麼
WITH runs AS (
  SELECT * FROM martech_dw.guard_runs WHERE status = ''
  QUALIFY ROW_NUMBER() OVER (PARTITION BY mode, case_id ORDER BY created_at DESC) = 1
)
SELECT case_id, kind, mode, model_calls,
  layer1_input_hits AS l1_input, IF(layer2_scrubbed = '[]', '', 'scrubbed') AS l2_tool_result, layer4_action AS l4_output,
  signal_pii, signal_canary, signal_note_markers, signal_claims, signal_customer_tool,
  finish_reason, block_reason
FROM runs
ORDER BY case_id, mode;

-- 2. 回答原文：raw_answer 是模型寫的，final_answer 是使用者看到的
SELECT case_id, mode, question, raw_answer, final_answer, tools_called
FROM martech_dw.guard_runs WHERE status = ''
QUALIFY ROW_NUMBER() OVER (PARTITION BY mode, case_id ORDER BY created_at DESC) = 1
ORDER BY case_id, mode;

-- 3. 安全設定：每一題模型回報的類別機率，以及問題或回答有沒有被擋
SELECT case_id, mode, finish_reason, block_reason, safety_ratings
FROM martech_dw.guard_runs WHERE status = ''
QUALIFY ROW_NUMBER() OVER (PARTITION BY mode, case_id ORDER BY created_at DESC) = 1
ORDER BY case_id, mode;

-- 4. Token 與費用：gemini-3.6-flash global 端點每百萬 Token 輸入 0.75、輸出 3.75 美元，匯率 32
SELECT mode, COUNT(DISTINCT case_id) AS cases_with_model_calls, COUNT(*) AS model_calls,
  SUM(prompt_tokens) AS prompt_tokens, SUM(output_tokens) AS output_tokens, SUM(thoughts_tokens) AS thoughts_tokens,
  ROUND(SUM(prompt_tokens * 0.75 + (output_tokens + thoughts_tokens) * 3.75) / 1e6 * 32, 3) AS cost_twd
FROM martech_dw.guard_calls_log
WHERE status = ''
GROUP BY ROLLUP(mode)
ORDER BY mode NULLS LAST;
