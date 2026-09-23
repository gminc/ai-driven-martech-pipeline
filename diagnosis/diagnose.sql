-- Day 09 第三步：在 SQL 裡叫 Gemini 判讀每一筆異常，結果落成 martech_dw.mart_diagnosis
-- 每一列異常各呼叫一次，回傳格式用 response_schema 鎖成 JSON，原因只能從六個選項挑
-- thinking_budget 設 0：gemini-3.6-flash 預設會思考，思考 token 也算在 max_output_tokens 裡，
--   實測預設值會把 512 個 token 幾乎用光（約 488 個），JSON 被截斷但 status 仍是空字串（成功）
-- thinking_level 目前會被 BigQuery 的參數檢查擋下，要用 thinking_budget
-- 這一步會產生 Token 費用，執行前先跑 cost.sql 數 Token

-- 遠端模型只是一個「指向 Gemini 的捷徑」，建立本身不收費
CREATE OR REPLACE MODEL martech_dw.gemini_flash_lite
  REMOTE WITH CONNECTION `us.vertex_ai_conn`
  OPTIONS (ENDPOINT = 'gemini-3.5-flash-lite');

CREATE OR REPLACE MODEL martech_dw.gemini_flash
  REMOTE WITH CONNECTION `us.vertex_ai_conn`
  OPTIONS (ENDPOINT = 'gemini-3.6-flash');

-- 主跑：gemini-3.5-flash-lite
CREATE OR REPLACE TABLE martech_dw.mart_diagnosis
OPTIONS (description = 'Day 09 Gemini 對異常摘要的判讀結果，一列＝一筆異常 × 一個模型')
AS
SELECT
  anomaly_id, level, entity, period_start,
  'gemini-3.5-flash-lite' AS model,
  JSON_VALUE(result, '$.cause') AS cause,
  JSON_VALUE(result, '$.evidence') AS evidence,
  SAFE_CAST(JSON_VALUE(result, '$.confidence') AS FLOAT64) AS confidence,
  JSON_VALUE(result, '$.next_check') AS next_check,
  result AS raw_result,
  statistics,
  status,
  CURRENT_TIMESTAMP() AS created_at
FROM AI.GENERATE_TEXT(
  MODEL martech_dw.gemini_flash_lite,
  (SELECT anomaly_id, level, entity, period_start, prompt FROM martech_dw.diag_prompt),
  STRUCT(
    '''{
      "generation_config": {
        "max_output_tokens": 512,
        "thinking_config": {"thinking_budget": 0},
        "response_mime_type": "application/json",
        "response_schema": {
          "type": "OBJECT",
          "properties": {
            "cause": {"type": "STRING", "enum": ["競價變貴", "追蹤碼失效", "素材疲乏", "需求或季節變化", "其他", "資料不足"]},
            "evidence": {"type": "STRING"},
            "confidence": {"type": "NUMBER"},
            "next_check": {"type": "STRING"}
          },
          "required": ["cause", "evidence", "confidence", "next_check"]
        }
      }
    }''' AS model_params
  )
);

-- 對照：同一份摘要交給 gemini-3.6-flash
INSERT INTO martech_dw.mart_diagnosis
SELECT
  anomaly_id, level, entity, period_start,
  'gemini-3.6-flash' AS model,
  JSON_VALUE(result, '$.cause'),
  JSON_VALUE(result, '$.evidence'),
  SAFE_CAST(JSON_VALUE(result, '$.confidence') AS FLOAT64),
  JSON_VALUE(result, '$.next_check'),
  result, statistics, status, CURRENT_TIMESTAMP()
FROM AI.GENERATE_TEXT(
  MODEL martech_dw.gemini_flash,
  (SELECT anomaly_id, level, entity, period_start, prompt FROM martech_dw.diag_prompt),
  STRUCT(
    '''{
      "generation_config": {
        "max_output_tokens": 512,
        "thinking_config": {"thinking_budget": 0},
        "response_mime_type": "application/json",
        "response_schema": {
          "type": "OBJECT",
          "properties": {
            "cause": {"type": "STRING", "enum": ["競價變貴", "追蹤碼失效", "素材疲乏", "需求或季節變化", "其他", "資料不足"]},
            "evidence": {"type": "STRING"},
            "confidence": {"type": "NUMBER"},
            "next_check": {"type": "STRING"}
          },
          "required": ["cause", "evidence", "confidence", "next_check"]
        }
      }
    }''' AS model_params
  )
);
