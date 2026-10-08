-- Day 26：助理服務的問答紀錄表（部署腳本會先跑這一段，服務本身只寫入、不建表）
-- 一列＝一輪問答，只加不刪，誰問了什麼、程式擋了什麼、花了多少都在這裡
-- 問題與回答的原文會留在這張表，要給誰看由 BigQuery 的權限決定
-- caller 是服務從請求標頭讀到的帳號，方便查閱用，要當證據請對照 Cloud Run 自己的請求紀錄
-- 建表不收費

CREATE TABLE IF NOT EXISTS martech_dw.serve_turns (
  session_id STRING,
  turn INT64,
  caller STRING,
  question STRING,
  raw_answer STRING,
  final_answer STRING,
  input_hits STRING,
  scrubbed STRING,
  isolation_refused STRING,
  action STRING,
  tools_called STRING,
  model_calls INT64,
  prompt_tokens INT64,
  output_tokens INT64,
  cost_twd FLOAT64,
  status STRING,
  kept_in_history BOOL,
  created_at TIMESTAMP
)
PARTITION BY DATE(created_at)
OPTIONS (description = 'Day 26 助理服務的問答紀錄：一列＝一輪問答，只加不刪');
